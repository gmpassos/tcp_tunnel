import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart' as logging;

import 'tcp_tunnel_base.dart';
import 'tcp_tunnel_protocol.dart';

final _log = logging.Logger('TunnelAgent');

/// Dials the hub, upgrading to TLS when [securityContext] is provided.
///
/// Returns a [SecureSocket] (which is a [Socket]) in TLS mode, otherwise a
/// plain [Socket]; either is a drop-in for [FramedConnection]/[SocketAsync].
Future<Socket> _connectHub(
  String host,
  int port, {
  SecurityContext? securityContext,
  bool Function(X509Certificate cert)? onBadCertificate,
}) {
  if (securityContext == null) {
    return Socket.connect(host, port);
  }
  return SecureSocket.connect(
    host,
    port,
    context: securityContext,
    onBadCertificate: onBadCertificate,
  );
}

/// Publishes a local service through a [TunnelHub] (the "server agent" side).
///
/// Runs inside the private LAN where the service lives. It keeps a pool of
/// [poolSize] parked outbound connections to the hub (handshake
/// `HELLO role=server`). When the hub activates one (a client arrived), it
/// acknowledges with a [FrameType.ready] barrier, dials the local
/// [targetHost]:[targetPort], and raw-pipes the two. The pool is refilled so a
/// fresh parked connection is always ready.
class TunnelServerAgent {
  final String hubHost;
  final int hubPort;

  /// Service name advertised to the hub (the routing key).
  final String service;

  final String targetHost;
  final int targetPort;

  /// Number of parked connections kept ready at the hub.
  final int poolSize;

  /// Asks the hub to expose this service on a public port (public port mode):
  /// a positive value requests that fixed port, `0` requests a dynamically
  /// allocated one, and `null` (default) requests none.
  final int? requestPublicPort;

  /// Keepalive interval for parked connections.
  final Duration pingInterval;

  /// Delay before re-establishing a connection after a failure.
  final Duration reconnectDelay;

  /// When non-null, connections to the hub are made over TLS using this context
  /// (e.g. trusting the hub's self-signed CA via [SecurityContext.setTrustedCertificates]).
  final SecurityContext? securityContext;

  /// Certificate-validation override used when [securityContext] is set. Return
  /// `true` to accept an otherwise-rejected certificate (e.g. a self-signed hub
  /// cert in dev). When null, normal verification applies.
  final bool Function(X509Certificate cert)? onBadCertificate;

  /// Shared secret presented to the hub for authentication (sent in the HELLO).
  final String? authToken;

  final bool verbose;

  TunnelServerAgent(
    this.hubHost,
    this.hubPort,
    this.service,
    this.targetPort, {
    this.targetHost = 'localhost',
    this.poolSize = 4,
    this.requestPublicPort,
    this.pingInterval = const Duration(seconds: 20),
    this.reconnectDelay = const Duration(seconds: 3),
    this.securityContext,
    this.onBadCertificate,
    this.authToken,
    this.verbose = false,
  });

  bool _started = false;
  bool _closed = false;

  /// Number of in-flight + parked connections counting toward [poolSize].
  int _liveCount = 0;

  bool _publicPortKnown = false;
  int? _publicPort;

  /// The public port the hub currently maps to [service] (public port mode), or
  /// `null` if unknown yet or the service has no public port (local port mode
  /// only). Reported by the hub shortly after the agent connects.
  int? get publicPort => _publicPort;

  bool _rejected = false;

  /// Called (once) if the hub rejects the registration — e.g. a requested
  /// [requestPublicPort] is already in use or cannot be allocated. The agent is
  /// closed before this fires. Lets the CLI fail with a clear reason.
  void Function(String reason)? onPublicPortRejected;

  final Set<FramedConnection> _parked = {};

  /// Starts the agent and fills the parked-connection pool.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _log.info('** Started: $this');
    _refill();
  }

  void _refill() {
    if (_closed) return;
    while (_liveCount < poolSize) {
      _liveCount++;
      _openParked();
    }
  }

  void _onGone({bool backoff = false}) {
    _liveCount--;
    if (_closed) return;
    if (backoff) {
      Timer(reconnectDelay, _refill);
    } else {
      _refill();
    }
  }

  Future<void> _openParked() async {
    final Socket socket;
    try {
      socket = await _connectHub(
        hubHost,
        hubPort,
        securityContext: securityContext,
        onBadCertificate: onBadCertificate,
      );
    } catch (e) {
      if (verbose) _log.warning('** Hub connect $hubHost:$hubPort failed: $e');
      _onGone(backoff: true);
      return;
    }

    if (_closed) {
      socket.destroy();
      _onGone();
      return;
    }

    final conn = FramedConnection(socket, zone: Tunnel.zoneGuarded);
    conn.writeFrame(
      Frame.hello(
        role: 'server',
        service: service,
        publicPort: requestPublicPort,
        token: authToken,
      ),
    );
    _parked.add(conn);

    final pingTimer = Timer.periodic(pingInterval, (_) {
      if (!conn.isAdopted) conn.writeFrame(Frame.pingFrame);
    });

    var settled = false;
    void settle({bool backoff = false}) {
      if (settled) return;
      settled = true;
      pingTimer.cancel();
      _parked.remove(conn);
      _onGone(backoff: backoff);
    }

    // A parked conn that dies before activation must refill the pool.
    conn.onClosed = () => settle(backoff: true);

    while (true) {
      final Frame frame;
      try {
        frame = await conn.readFrame();
      } catch (_) {
        settle(backoff: true);
        return;
      }

      if (frame.type == FrameType.activate) {
        // Consumed: refill immediately (no backoff) and serve the client.
        settle();
        await _activate(conn, frame.peer);
        return;
      }

      if (frame.type == FrameType.reject) {
        _onReject(frame.reason);
        return; // fatal: the agent is closed by _onReject
      }

      if (frame.type == FrameType.welcome) {
        _onWelcome(frame.publicPort);
      }
      // PONG and anything else: ignore while parked.
    }
  }

  /// Handles a hub rejection (e.g. requested public port unavailable): logs the
  /// reason, closes the agent, and notifies [onPublicPortRejected] once.
  void _onReject(String? reason) {
    if (_rejected) return;
    _rejected = true;

    final msg = reason ?? 'registration rejected by hub';
    _log.severe('** Hub rejected publishing "$service": $msg');

    final cb = onPublicPortRejected;
    close(); // stop the pool / reconnects
    if (cb != null) cb(msg);
  }

  /// Reports the public port the hub mapped to [service], logging once (and
  /// again only if it changes).
  void _onWelcome(int? port) {
    if (_publicPortKnown && _publicPort == port) return;
    _publicPortKnown = true;
    _publicPort = port;

    if (port != null) {
      _log.info(
        '-- Service "$service" is publicly mapped at $hubHost:$port '
        '(public port mode)',
      );
    } else {
      _log.info(
        '-- Service "$service" has no public port (local port mode only): '
        'tcp_tunnel connect --hub $hubHost:$hubPort --service $service '
        '--listen <localPort>',
      );
    }
  }

  /// Dials the local target and pipes it to the activated hub connection.
  Future<void> _activate(FramedConnection conn, String? peer) async {
    final Socket target;
    try {
      target = await Socket.connect(targetHost, targetPort);
    } catch (e, s) {
      _log.warning(
        '** Target $targetHost:$targetPort connect failed: $e',
        e,
        s,
      );
      conn.close(); // not adopted: destroys the hub socket so the hub gives up
      return;
    }

    // READY is the last framed message; everything after it is raw payload.
    conn.writeFrame(Frame.readyFrame);

    final hubSide = SocketAsync.adopt(conn);
    final targetSide = SocketAsync.from(target);
    final tunnel = Tunnel.pair(hubSide, targetSide, verbose: verbose);

    _log.info(
      '-- Activated "$service" -> $targetHost:$targetPort'
      '${peer != null ? ' for $peer' : ''}'
      '${verbose ? ': $tunnel' : ''}',
    );
  }

  /// Closes the agent and its idle parked connections.
  void close() {
    if (_closed) return;
    _closed = true;
    for (var conn in _parked.toList()) {
      conn.close();
    }
    _parked.clear();
  }

  @override
  String toString() =>
      'TunnelServerAgent{ hub: $hubHost:$hubPort, '
      'service: "$service" -> $targetHost:$targetPort, pool: $poolSize }';
}

/// Consumes a hub-published service via a local listen port (the "client agent"
/// side, local port mode).
///
/// Opens a local [listenPort]; for each accepted application socket it dials the
/// hub control port, handshakes `HELLO role=client service=...`, and raw-pipes
/// the application socket through the hub to the remote service. The hub never
/// needs a public port per service in this mode.
class TunnelClientAgent {
  final String hubHost;
  final int hubPort;

  /// Service name requested from the hub.
  final String service;

  /// Local port applications connect to.
  final int listenPort;

  /// Local address to bind ([listenPort]).
  final String listenHost;

  /// When non-null, connections to the hub are made over TLS using this context.
  final SecurityContext? securityContext;

  /// Certificate-validation override used when [securityContext] is set (see
  /// [TunnelServerAgent.onBadCertificate]).
  final bool Function(X509Certificate cert)? onBadCertificate;

  /// Shared secret presented to the hub for authentication (sent in the HELLO).
  final String? authToken;

  final bool verbose;

  TunnelClientAgent(
    this.hubHost,
    this.hubPort,
    this.service,
    this.listenPort, {
    this.listenHost = '0.0.0.0',
    this.securityContext,
    this.onBadCertificate,
    this.authToken,
    this.verbose = false,
  });

  ServerSocket? _server;
  bool _started = false;

  /// Starts listening for local application connections.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    final server = _server = await ServerSocket.bind(listenHost, listenPort);
    server.listen(_onAppSocket);

    _log.info('** Started: $this');
  }

  Future<void> _onAppSocket(Socket appSocket) async {
    final Socket hubSocket;
    try {
      hubSocket = await _connectHub(
        hubHost,
        hubPort,
        securityContext: securityContext,
        onBadCertificate: onBadCertificate,
      );
    } catch (e) {
      _log.warning('** Hub connect $hubHost:$hubPort failed: $e');
      appSocket.destroy();
      return;
    }

    final conn = FramedConnection(hubSocket, zone: Tunnel.zoneGuarded);
    conn.writeFrame(
      Frame.hello(role: 'client', service: service, token: authToken),
    );

    final hubSide = SocketAsync.adopt(conn);
    final appSide = SocketAsync.from(appSocket);
    final tunnel = Tunnel.pair(hubSide, appSide, verbose: verbose);

    if (verbose) _log.info('-- Connecting "$service": $tunnel');
  }

  /// Closes the local listen socket.
  void close() {
    _server?.close();
  }

  @override
  String toString() =>
      'TunnelClientAgent{ listen: $listenHost:$listenPort '
      '-> hub $hubHost:$hubPort, service: "$service" }';
}
