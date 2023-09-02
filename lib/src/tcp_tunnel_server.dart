import 'dart:async';
import 'dart:io';

import 'tcp_tunnel_base.dart';
import 'package:logging/logging.dart' as logging;

final _log = logging.Logger('TunnelLocalServer');

/// A tunnel that listens to a local port and redirects to a [targetPort].
class TunnelLocalServer {
  /// The local port to listen.
  final int listenPort;

  /// The target port to connect when a [Socket] is accepted (at [listenPort]).
  final int targetPort;

  /// The target host to connect when a [Socket] is accepted (at [listenPort]).
  final String targetHost;

  TunnelLocalServer(this.listenPort, this.targetPort,
      {this.targetHost = 'localhost'});

  late final ServerSocket _server;

  bool _started = false;

  /// Starts the tunnel server.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    final server = _server = await ServerSocket.bind('0.0.0.0', listenPort);

    server.listen((Socket socket) {
      Tunnel.targetPort(socket, targetPort, targetHost: targetHost);
    });

    _log.info('** Started: $this');
  }

  /// Closes the tunnel server.
  void close() {
    _server.close();
  }

  @override
  String toString() {
    return 'TunnelLocalServer{ listenPort: $listenPort, targetPort: $targetPort }';
  }
}
