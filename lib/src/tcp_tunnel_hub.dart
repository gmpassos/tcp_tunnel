import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart' as logging;

import 'tcp_tunnel_base.dart';
import 'tcp_tunnel_protocol.dart';

final _log = logging.Logger('TunnelHub');

/// An inclusive TCP port range `[start, end]`.
///
/// Used to constrain dynamically allocated public ports so they stay within a
/// range that a firewall is configured to allow.
class PortRange {
  final int start;
  final int end;

  const PortRange(this.start, this.end)
    : assert(start > 0 && start <= 65535, 'start out of range'),
      assert(end >= start && end <= 65535, 'end out of range');

  /// Parses a `start-end` (or single `port`) string, e.g. `20000-20100`.
  factory PortRange.parse(String spec) {
    final dash = spec.indexOf('-');
    if (dash < 0) {
      final p = int.parse(spec.trim());
      return PortRange(p, p);
    }
    final start = int.parse(spec.substring(0, dash).trim());
    final end = int.parse(spec.substring(dash + 1).trim());
    return PortRange(start, end);
  }

  bool contains(int port) => port >= start && port <= end;

  @override
  String toString() => start == end ? '$start' : '$start-$end';
}

/// A parked server-agent connection awaiting a client to serve.
class _ParkedServer {
  final FramedConnection conn;

  /// Completes once the agent has acknowledged [FrameType.activate] with a
  /// [FrameType.ready] barrier, meaning the connection is ready for raw piping.
  final Completer<void> ready = Completer<void>();

  bool taken = false;

  /// Whether a [FrameType.welcome] (public port info) was already sent.
  bool welcomed = false;

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

  /// When `true`, any published service that has no public port yet is
  /// automatically given a dynamically allocated (ephemeral) public port the
  /// first time a server agent registers it. The chosen port is logged and
  /// recorded in [boundPorts].
  final bool dynamicPublicPorts;

  /// Restricts dynamically allocated public ports (a `--map svc=.` entry or a
  /// [dynamicPublicPorts] service) to this inclusive range, for compatibility
  /// with firewall filters. When `null`, the OS picks any free ephemeral port.
  final PortRange? dynamicPortRange;

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
    this.dynamicPublicPorts = false,
    this.dynamicPortRange,
    this.clientWaitTimeout = const Duration(seconds: 10),
    this.parkedIdleTimeout = const Duration(seconds: 60),
    this.verbose = false,
  }) : servicePorts = Map.unmodifiable(servicePorts ?? const {});

  final Map<String, _ServiceRegistry> _registries = {};

  ServerSocket? _controlServer;
  final List<ServerSocket> _publicServers = [];

  /// Public port mode: service name → the port actually bound. Differs from
  /// [servicePorts] when a service requested a dynamic port (`0`), which the OS
  /// resolves to a concrete ephemeral port at [start].
  final Map<String, int> _boundPorts = {};

  /// Services whose public port is currently being bound, to avoid allocating
  /// twice when multiple agents register the same service at once.
  final Set<String> _allocatingPublicPort = {};

  /// Ports within [dynamicPortRange] already handed out, so a subsequent
  /// allocation skips them instead of re-failing on the same taken port.
  final Set<int> _rangeAllocated = {};

  /// Resolved public port for each service (after [start]). A dynamically
  /// allocated port (requested as `0`) appears here as its concrete value.
  Map<String, int> get boundPorts => Map.unmodifiable(_boundPorts);

  bool _started = false;

  _ServiceRegistry _registry(String service) =>
      _registries.putIfAbsent(service, () => _ServiceRegistry(service));

  /// Starts the hub: binds the control port and every configured public port.
  ///
  /// A service mapped to port `0` is bound to a dynamically allocated ephemeral
  /// port; the resolved value is recorded in [boundPorts].
  Future<void> start() async {
    if (_started) return;
    _started = true;

    final controlServer = _controlServer = await ServerSocket.bind(
      '0.0.0.0',
      controlPort,
    );
    controlServer.listen(_onControlSocket);

    for (var entry in servicePorts.entries) {
      // A configured port of 0 means "allocate dynamically".
      await _openPublicPort(
        entry.key,
        dynamic: entry.value == 0,
        fixedPort: entry.value,
        requested: false,
      );
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
          _registerServer(service, conn, requestedPublicPort: frame.publicPort);
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

  void _registerServer(
    String service,
    FramedConnection conn, {
    int? requestedPublicPort,
  }) {
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

    // Decide whether a public port should be ensured for this service: an
    // explicit agent request takes precedence, otherwise the hub-wide
    // [dynamicPublicPorts] setting applies.
    if (requestedPublicPort != null) {
      _ensurePublicPort(
        service,
        dynamic: requestedPublicPort == 0,
        fixedPort: requestedPublicPort,
        requested: true,
      );
    } else if (dynamicPublicPorts) {
      _ensurePublicPort(service, dynamic: true, requested: false);
    }

    _maybeWelcome(parked, service);
    _keepParked(parked);
    _pair(reg);
  }

  /// Tells a parked server conn its service's public port, once known.
  ///
  /// Sent immediately when the port is already bound, or when no public port
  /// will ever be assigned (local port mode only). When a port is still being
  /// bound, [_openPublicPort] sends it after the bind completes.
  void _maybeWelcome(_ParkedServer parked, String service) {
    if (parked.welcomed) return;

    final port = _boundPorts[service];
    if (port != null) {
      parked.welcomed = true;
      parked.conn.writeFrame(Frame.welcome(publicPort: port));
    } else if (!_allocatingPublicPort.contains(service)) {
      // No public port now and none coming: local port mode only.
      parked.welcomed = true;
      parked.conn.writeFrame(Frame.welcome());
    }
  }

  /// Ensures [service] has a public port, binding one if needed (deduplicated
  /// against a bind already in progress). [dynamic] allocates automatically
  /// (honoring [dynamicPortRange]); otherwise [fixedPort] is bound. When
  /// [requested] (the agent asked via HELLO), a bind failure rejects the agent
  /// instead of silently leaving it in local port mode.
  void _ensurePublicPort(
    String service, {
    required bool dynamic,
    int fixedPort = 0,
    required bool requested,
  }) {
    if (_boundPorts.containsKey(service)) return;
    if (!_allocatingPublicPort.add(service)) return; // already allocating

    _openPublicPort(
      service,
      dynamic: dynamic,
      fixedPort: fixedPort,
      requested: requested,
    ).whenComplete(() => _allocatingPublicPort.remove(service));
  }

  /// Binds a public port for [service] and starts accepting plain TCP clients.
  ///
  /// When [dynamic] the port is allocated automatically — within
  /// [dynamicPortRange] if set, otherwise an OS-chosen ephemeral port.
  /// Otherwise [fixedPort] is bound. Returns `true` on success.
  Future<bool> _openPublicPort(
    String service, {
    required bool dynamic,
    int fixedPort = 0,
    required bool requested,
  }) async {
    final ServerSocket server;
    try {
      if (dynamic) {
        final bound = await _bindDynamic();
        if (bound == null) {
          final reason = 'no free public port in range $dynamicPortRange';
          _log.severe('** $reason for service "$service"');
          _failPublicPort(service, requested, reason);
          return false;
        }
        server = bound;
      } else {
        server = await ServerSocket.bind('0.0.0.0', fixedPort);
      }
    } catch (e, s) {
      final reason = _bindFailureReason(dynamic, fixedPort, e);
      _log.severe(
        '** Failed to bind public port for "$service": $reason',
        e,
        s,
      );
      _failPublicPort(service, requested, reason);
      return false;
    }

    server.listen((socket) => _onPublicSocket(service, socket));
    _publicServers.add(server);
    _boundPorts[service] = server.port;
    _log.info(
      '** Public port ${server.port}${dynamic ? ' (dynamic)' : ''} '
      '-> service "$service"',
    );

    // Inform any server conns that registered before the port was bound.
    _broadcastWelcome(service, server.port);
    return true;
  }

  /// Sends a WELCOME with [port] (null = none) to every not-yet-welcomed parked
  /// server conn of [service].
  void _broadcastWelcome(String service, int? port) {
    final reg = _registries[service];
    if (reg == null) return;
    for (final parked in reg.parked) {
      if (!parked.welcomed) {
        parked.welcomed = true;
        parked.conn.writeFrame(Frame.welcome(publicPort: port));
      }
    }
  }

  /// Handles a public-port bind failure: rejects the agent with [reason] when it
  /// [requested] the port, otherwise leaves it in local port mode (WELCOME none).
  void _failPublicPort(String service, bool requested, String reason) {
    if (requested) {
      _broadcastReject(service, reason);
    } else {
      _broadcastWelcome(service, null);
    }
  }

  /// Sends a REJECT with [reason] to every not-yet-welcomed parked server conn
  /// of [service].
  void _broadcastReject(String service, String reason) {
    final reg = _registries[service];
    if (reg == null) return;
    for (final parked in reg.parked.toList()) {
      if (!parked.welcomed) {
        parked.welcomed = true;
        parked.conn.writeFrame(Frame.reject(reason));
      }
    }
  }

  /// Builds a human-readable reason for a public-port bind failure.
  String _bindFailureReason(bool dynamic, int fixedPort, Object e) {
    if (dynamic) {
      return 'could not allocate a dynamic public port: $e';
    }

    // Identify a conflicting service already mapped to this port, if any.
    String? owner;
    for (final entry in _boundPorts.entries) {
      if (entry.value == fixedPort) {
        owner = entry.key;
        break;
      }
    }

    final String detail;
    if (owner != null) {
      detail = 'already mapped to service "$owner"';
    } else if (e is SocketException) {
      detail = e.osError?.message ?? e.message;
    } else {
      detail = e.toString();
    }
    return 'public port $fixedPort is unavailable ($detail)';
  }

  /// Binds a dynamically allocated [ServerSocket], honoring [dynamicPortRange].
  ///
  /// With no range, the OS picks any free ephemeral port. With a range, the
  /// first free port in `[start, end]` (skipping ports already handed out) is
  /// used; returns `null` if the range is exhausted.
  Future<ServerSocket?> _bindDynamic() async {
    final range = dynamicPortRange;
    if (range == null) {
      return ServerSocket.bind('0.0.0.0', 0);
    }

    for (var port = range.start; port <= range.end; port++) {
      if (_rangeAllocated.contains(port)) continue;
      try {
        final server = await ServerSocket.bind('0.0.0.0', port);
        _rangeAllocated.add(port);
        return server;
      } catch (_) {
        // Port unavailable (in use by us or another process): try the next.
      }
    }
    return null;
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
