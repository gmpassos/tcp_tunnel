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

    server.listen(_onAccept);

    _log.info('** Started: $this');
  }

  /// Accepted sockets whose target connection is still being established.
  final Set<Socket> _connecting = {};

  /// Tunnels currently running (removed when they close).
  final Set<Tunnel> _tunnels = {};

  bool _closed = false;

  Future<void> _onAccept(Socket socket) async {
    if (_closed) {
      socket.destroy();
      return;
    }

    _connecting.add(socket);
    final tunnel = await Tunnel.targetPort(
      socket,
      targetPort,
      targetHost: targetHost,
      verbose: verbose,
    );
    // Not in [_connecting] anymore: [close] dropped it while connecting.
    final owned = _connecting.remove(socket);
    if (tunnel == null) return;

    if (!owned || tunnel.isClosed) {
      tunnel.close();
      return;
    }

    _tunnels.add(tunnel);
    tunnel.onClose = _tunnels.remove;
    _log.info("-- Connected: $tunnel");
  }

  /// Closes the tunnel server: stops listening and, by default, closes every
  /// tunnel it accepted (including those still connecting to the target).
  ///
  /// With [closeActiveTunnels] `false` only the listener is closed and running
  /// tunnels are left to finish on their own (graceful shutdown); a later
  /// [close] call closes whatever is still running.
  void close({bool closeActiveTunnels = true}) {
    _closed = true;
    _server?.close();

    if (!closeActiveTunnels) return;

    for (var socket in _connecting) {
      try {
        socket.destroy();
      } catch (_) {}
    }
    _connecting.clear();

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
