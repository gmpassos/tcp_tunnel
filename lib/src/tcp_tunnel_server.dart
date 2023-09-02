import 'dart:async';
import 'dart:io';

import 'tcp_tunnel_base.dart';
import 'package:logging/logging.dart' as logging;

final _log = logging.Logger('TunnelLocalServer');

class TunnelLocalServer {
  final int listenPort;
  final int targetPort;
  final String targetHost;

  TunnelLocalServer(this.listenPort, this.targetPort,
      {this.targetHost = 'localhost'});

  late final ServerSocket _server;

  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    final server = _server = await ServerSocket.bind('0.0.0.0', listenPort);

    server.listen((Socket socket) {
      Tunnel.targetPort(socket, targetPort, targetHost: targetHost);
    });

    _log.info('** Started: $this');
  }

  void close() {
    _server.close();
  }

  @override
  String toString() {
    return 'TunnelLocalServer{ listenPort: $listenPort, targetPort: $targetPort }';
  }
}
