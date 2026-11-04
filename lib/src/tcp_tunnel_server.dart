import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart' as logging;

import 'tcp_tunnel_base.dart';

final _log = logging.Logger('TunnelLocalServer');

/// A tunnel that listens to a local port and redirects to a [targetPort].
class TunnelLocalServer {
  /// The local port to listen.
  final int listenPort;

  /// The target port to connect when a [Socket] is accepted (at [listenPort]).
  final int targetPort;

  /// The target host to connect when a [Socket] is accepted (at [listenPort]).
  final String targetHost;

  final bool verbose;

  TunnelLocalServer(
    this.listenPort,
    this.targetPort, {
    this.targetHost = 'localhost',
    this.verbose = false,
  });

  ServerSocket? _server;

  /// The port actually bound (after [start]), or `null` if not started.
  /// Differs from [listenPort] when it is `0` (OS-chosen ephemeral port).
  int? get boundPort => _server?.port;

  bool _started = false;

  /// Starts the tunnel server.
  ///
  /// If [listenPort] cannot be bound the error is rethrown and [start] may be
  /// retried.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    final ServerSocket server;
    try {
      server = _server = await ServerSocket.bind('0.0.0.0', listenPort);
    } catch (_) {
      _started = false;
      rethrow;
    }

    // [close] ran while binding: release the port instead of serving
    // ([boundPort] stays `null`).
    if (_closed) {
      _server = null;
      await server.close();
      return;
    }

    server.listen(_onAccept);

    _log.info('** Started: $this');
  }

  /// Tunnels currently running (removed when they close).
  final Set<Tunnel> _tunnels = {};

  /// Set by [close]: stop accepting.
  bool _closed = false;

  /// Set by [close] unless `closeActiveTunnels` was `false`: a tunnel whose
  /// target connect completes afterwards is closed at once.
  bool _tunnelsClosed = false;

  Future<void> _onAccept(Socket socket) async {
    // Accepted while [close] was running (the listener closes asynchronously).
    if (_closed) return socket.destroy();

    final tunnel = await Tunnel.targetPort(
      socket,
      targetPort,
      targetHost: targetHost,
      verbose: verbose,
    );
    if (tunnel == null) return;
    // [close] ran while the target connect was pending.
    if (_tunnelsClosed) return tunnel.close();

    _tunnels.add(tunnel);
    tunnel.onClose = _tunnels.remove;
    _log.info("-- Connected: $tunnel");
  }

  /// Closes the tunnel server: stops listening and, by default, closes every
  /// tunnel it accepted (one still connecting to the target is closed as soon
  /// as that connect completes).
  ///
  /// With [closeActiveTunnels] `false` only the listener is closed and running
  /// tunnels are left to finish on their own (graceful shutdown); a later
  /// [close] call closes whatever is still running.
  void close({bool closeActiveTunnels = true}) {
    _closed = true;
    _server?.close();

    if (!closeActiveTunnels) return;
    _tunnelsClosed = true;

    // Closing a tunnel removes it from [_tunnels] (via `onClose`): iterate a
    // copy.
    for (var tunnel in _tunnels.toList()) {
      tunnel.close();
    }
    _tunnels.clear();
  }

  @override
  String toString() {
    return 'TunnelLocalServer{ listenPort: $listenPort, targetPort: $targetPort }';
  }
}
