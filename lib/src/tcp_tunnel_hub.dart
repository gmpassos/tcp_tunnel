import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart' as logging;

import 'tcp_tunnel_base.dart';
import 'tcp_tunnel_protocol.dart';

final _log = logging.Logger('TunnelHub');

/// A parked server-agent connection awaiting a client to serve.
class _ParkedServer {
  final FramedConnection conn;

  /// Completes once the agent has acknowledged [FrameType.activate] with a
  /// [FrameType.ready] barrier, meaning the connection is ready for raw piping.
  final Completer<void> ready = Completer<void>();

  bool taken = false;

  _ParkedServer(this.conn);

  bool get isClosed => conn.isClosed;
}

/// A client awaiting a server-agent connection.
///
/// Unifies public port mode (a plain public-port socket) and local port mode (a
/// client agent connection adopted after its HELLO): both are just a
/// [SocketAsync] ready to be piped.
class _WaitingClient {
  final SocketAsync socket;
  final String peer;
  Timer? timeout;

  _WaitingClient(this.socket, this.peer);

  bool get isClosed => socket.isClosed;
}

/// Per-service registry of parked server conns and waiting clients, paired FIFO.
class _ServiceRegistry {
  final String name;
  final List<_ParkedServer> parked = <_ParkedServer>[];
  final List<_WaitingClient> waiting = <_WaitingClient>[];

  _ServiceRegistry(this.name);
}

/// A public hub that connects private "server agents" (which publish a named
/// service from inside their LAN) to "clients" in other networks.
///
/// Both ends dial *out* to the hub, so the hub works even when both LANs are
/// fully NATed. Server agents pre-warm a pool of parked connections; each
/// arriving client is paired with one parked connection (activated via an
/// [FrameType.activate] frame) and the two are raw-piped.
///
/// Clients reach a service either by connecting to a per-service public port
/// ([servicePorts], public port mode) or via a client agent that dials the
/// [controlPort] with a HELLO (local port mode).
class TunnelHub {
  /// Port where agents (server and client) connect and handshake.
  final int controlPort;

  /// Public port mode mapping: service name → public TCP port. Plain TCP clients
  /// connect straight to these ports.
  final Map<String, int> servicePorts;

  /// How long a waiting client is held before being closed when no parked
  /// server connection is available (service offline / pool exhausted).
  final Duration clientWaitTimeout;

  /// A parked connection idle (no frame, including keepalive) for longer than
  /// this is reaped.
  final Duration parkedIdleTimeout;

  final bool verbose;

  TunnelHub(
    this.controlPort, {
    Map<String, int>? servicePorts,
    this.clientWaitTimeout = const Duration(seconds: 10),
    this.parkedIdleTimeout = const Duration(seconds: 60),
    this.verbose = false,
  }) : servicePorts = Map.unmodifiable(servicePorts ?? const {});

  final Map<String, _ServiceRegistry> _registries = {};

  ServerSocket? _controlServer;
  final List<ServerSocket> _publicServers = [];

  bool _started = false;

  _ServiceRegistry _registry(String service) =>
      _registries.putIfAbsent(service, () => _ServiceRegistry(service));

  /// Starts the hub: binds the control port and every configured public port.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    final controlServer = _controlServer = await ServerSocket.bind(
      '0.0.0.0',
      controlPort,
    );
    controlServer.listen(_onControlSocket);

    for (var entry in servicePorts.entries) {
      final service = entry.key;
      final port = entry.value;
      final server = await ServerSocket.bind('0.0.0.0', port);
      server.listen((socket) => _onPublicSocket(service, socket));
      _publicServers.add(server);
      _log.info('** Public port $port -> service "$service"');
    }

    _log.info('** Started: $this');
  }

  /// Handles a connection on the control port: reads its HELLO and routes it.
  void _onControlSocket(Socket socket) {
    final conn = FramedConnection(socket, zone: Tunnel.zoneGuarded);

    conn.readFrame().then(
      (frame) {
        if (frame.type != FrameType.hello) {
          _log.warning('** Expected HELLO, got ${frame.type}; closing');
          conn.close();
          return;
        }

        final service = frame.service;
        final role = frame.role;
        if (service == null || service.isEmpty || role == null) {
          _log.warning('** Invalid HELLO: $frame; closing');
          conn.close();
          return;
        }

        if (role == 'server') {
          _registerServer(service, conn);
        } else if (role == 'client') {
          _registerClient(service, SocketAsync.adopt(conn), _peerOf(socket));
        } else {
          _log.warning('** Unknown role "$role"; closing');
          conn.close();
        }
      },
      onError: (e, s) {
        _log.warning('** Error reading HELLO: $e', e, s);
        conn.close();
      },
    );
  }

  /// Handles a public port mode plain TCP client on a public service port.
  void _onPublicSocket(String service, Socket socket) {
    _registerClient(service, SocketAsync.from(socket), _peerOf(socket));
  }

  void _registerServer(String service, FramedConnection conn) {
    final reg = _registry(service);
    final parked = _ParkedServer(conn);

    conn.onClosed = () {
      reg.parked.remove(parked);
      if (verbose) _log.info('-- Parked server conn closed for "$service"');
    };

    reg.parked.add(parked);
    if (verbose) {
      _log.info(
        '-- Registered server conn for "$service" '
        '(pool: ${reg.parked.length})',
      );
    }

    _keepParked(parked);
    _pair(reg);
  }

  /// Reads keepalive frames from a parked conn until it is taken or closes.
  /// Replies PONG to PING and reaps the conn if it goes idle too long.
  Future<void> _keepParked(_ParkedServer parked) async {
    final conn = parked.conn;
    // Reads until READY (post-activation barrier) or close; must keep reading
    // even after the conn is taken so an in-flight PING can't end the loop
    // before READY arrives.
    while (true) {
      final Frame frame;
      try {
        frame = await conn.readFrame().timeout(parkedIdleTimeout);
      } on TimeoutException {
        if (parked.taken) continue; // activation in progress; keep waiting
        _log.info('-- Reaping idle parked conn');
        conn.close();
        return;
      } catch (_) {
        return; // closed; onClosed already evicted it
      }

      switch (frame.type) {
        case FrameType.ping:
          conn.writeFrame(Frame.pongFrame);
        case FrameType.ready:
          // Acknowledges an ACTIVATE we sent; the connection is now raw.
          if (!parked.ready.isCompleted) parked.ready.complete();
          return;
        default:
          // Ignore unexpected frames while parked.
          break;
      }
    }
  }

  void _registerClient(String service, SocketAsync socket, String peer) {
    final reg = _registry(service);
    final client = _WaitingClient(socket, peer);

    socket.onClose = (_) {
      if (reg.waiting.remove(client)) {
        client.timeout?.cancel();
        if (verbose) _log.info('-- Waiting client closed for "$service"');
      }
    };

    client.timeout = Timer(clientWaitTimeout, () {
      if (reg.waiting.remove(client)) {
        _log.warning(
          '** No server connection for "$service" within $clientWaitTimeout; '
          'closing client $peer',
        );
        socket.close();
      }
    });

    reg.waiting.add(client);
    if (verbose) {
      _log.info(
        '-- Client $peer waiting for "$service" '
        '(queue: ${reg.waiting.length})',
      );
    }

    _pair(reg);
  }

  /// Pairs parked server conns with waiting clients FIFO, evicting any that
  /// closed before pairing (mirrors `TunnelBridge._connectTunnels`).
  void _pair(_ServiceRegistry reg) {
    while (reg.parked.isNotEmpty && reg.waiting.isNotEmpty) {
      final parked = reg.parked.removeAt(0);
      if (parked.isClosed) continue;

      final client = reg.waiting.removeAt(0);
      if (client.isClosed) {
        reg.parked.insert(0, parked); // server conn still needs a client
        continue;
      }

      parked.taken = true;
      client.timeout?.cancel();
      _activateAndPipe(reg, parked, client);
    }
  }

  /// Activates a parked server conn for [client] and raw-pipes them.
  Future<void> _activateAndPipe(
    _ServiceRegistry reg,
    _ParkedServer parked,
    _WaitingClient client,
  ) async {
    final conn = parked.conn;

    conn.writeFrame(Frame.activate(peer: client.peer));

    try {
      await parked.ready.future.timeout(clientWaitTimeout);
    } catch (e) {
      // Agent never acknowledged (died/slow): drop both ends and let the
      // client side reconnect if it wants to.
      _log.warning('** Activation failed for "${reg.name}": $e');
      conn.close();
      client.socket.close();
      return;
    }

    final serverSocket = SocketAsync.adopt(conn);
    final tunnel = Tunnel.pair(serverSocket, client.socket, verbose: verbose);

    if (verbose) {
      _log.info('-- Connected "${reg.name}": ${client.peer} <-> $tunnel');
    } else {
      _log.info('-- Connected "${reg.name}" for ${client.peer}');
    }
  }

  static String _peerOf(Socket socket) {
    try {
      return '${socket.remoteAddress.address}:${socket.remotePort}';
    } catch (_) {
      return '?';
    }
  }

  /// Closes the hub and all its listening sockets.
  void close() {
    _controlServer?.close();
    for (var server in _publicServers) {
      server.close();
    }
    _publicServers.clear();
  }

  @override
  String toString() {
    final ports = servicePorts.entries
        .map((e) => '${e.key}=${e.value}')
        .join(', ');
    return 'TunnelHub{ controlPort: $controlPort, servicePorts: {$ports} }';
  }
}
