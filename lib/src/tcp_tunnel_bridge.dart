import 'dart:async';
import 'dart:io';

import 'tcp_tunnel_base.dart';

import 'package:logging/logging.dart' as logging;

final _log = logging.Logger('TunnelBridge');

class TunnelBridge {
  final int listenPort1;
  final int listenPort2;

  TunnelBridge(this.listenPort1, this.listenPort2);

  late final ServerSocket _server1;
  late final ServerSocket _server2;

  bool _started = false;

  final List<Socket> _server1SocketsQueue = <Socket>[];
  final List<Socket> _server2SocketsQueue = <Socket>[];

  Future<void> start() async {
    if (_started) return;
    _started = true;

    final server1 = _server1 = await ServerSocket.bind('0.0.0.0', listenPort1);
    final server2 = _server2 = await ServerSocket.bind('0.0.0.0', listenPort2);

    server1.listen((Socket socket) {
      _server1SocketsQueue.add(socket);
      _connectTunnels();
    });

    server2.listen((Socket socket) {
      _server2SocketsQueue.add(socket);
      _connectTunnels();
    });

    _log.info('** Started: $this');
  }

  void close() {
    _server1.close();
    _server2.close();
  }

  void _connectTunnels() {
    if (_server1SocketsQueue.isEmpty || _server2SocketsQueue.isEmpty) return;

    var socket1 = _server1SocketsQueue.removeAt(0);
    var socket2 = _server2SocketsQueue.removeAt(0);

    Tunnel.withSockets(socket1, socket2);
  }

  @override
  String toString() {
    return 'TunnelBridge{ listenPort1: $listenPort1, listenPort2: $listenPort2 }';
  }
}
