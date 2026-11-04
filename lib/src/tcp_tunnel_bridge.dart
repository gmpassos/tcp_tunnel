import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart' as logging;

import 'tcp_tunnel_base.dart';

final _log = logging.Logger('TunnelBridge');

/// Creates a tunnel bridge between 2 listening ports ([listenPort1] and [listenPort2]).
class TunnelBridge {
  final int listenPort1;
  final int listenPort2;

  final bool verbose;

  TunnelBridge(this.listenPort1, this.listenPort2, {this.verbose = false});

  ServerSocket? _server1;
  ServerSocket? _server2;

  /// The port actually bound for [listenPort1] (after [start]), or `null` if
  /// not started. Differs from [listenPort1] when it is `0` (OS-chosen port).
  int? get boundPort1 => _server1?.port;

  /// The port actually bound for [listenPort2] (after [start]), or `null` if
  /// not started. Differs from [listenPort2] when it is `0` (OS-chosen port).
  int? get boundPort2 => _server2?.port;

  bool _started = false;

  final List<SocketAsync> _server1SocketsQueue = <SocketAsync>[];
  final List<SocketAsync> _server2SocketsQueue = <SocketAsync>[];

  /// Starts the bridge.
  ///
  /// If either port cannot be bound, the other one is released and the error
  /// is rethrown, so a failed start leaves no listening socket behind (and
  /// [start] may be retried).
  Future<void> start() async {
    if (_started) return;
    _started = true;

    final ServerSocket server1;
    final ServerSocket server2;
    try {
      server1 = _server1 = await ServerSocket.bind('0.0.0.0', listenPort1);
      server2 = _server2 = await ServerSocket.bind('0.0.0.0', listenPort2);
    } catch (_) {
      await _server1?.close();
      _server1 = null;
      _server2 = null;
      _started = false;
      rethrow;
    }

    server1.listen((socket) => _enqueue(_server1SocketsQueue, socket));
    server2.listen((socket) => _enqueue(_server2SocketsQueue, socket));

    _log.info('** Started: $this');
  }

  void _enqueue(List<SocketAsync> queue, Socket socket) {
    final socketAsync = SocketAsync.from(socket);
    queue.add(socketAsync);

    // If a queued socket closes before it is paired, evict it so it is never
    // paired into a dead tunnel.
    socketAsync.onClose = queue.remove;

    _connectTunnels();
  }

  /// Closes the bridge: its listening sockets and any accepted socket still
  /// waiting in a queue for a peer. Already paired tunnels are left running.
  void close() {
    _server1?.close();
    _server2?.close();

    // Closing a queued socket evicts it from its queue (via `onClose`), so
    // iterate over copies.
    for (var socket in [..._server1SocketsQueue, ..._server2SocketsQueue]) {
      socket.close();
    }
    _server1SocketsQueue.clear();
    _server2SocketsQueue.clear();
  }

  void _connectTunnels() {
    while (_server1SocketsQueue.isNotEmpty && _server2SocketsQueue.isNotEmpty) {
      var socket1 = _server1SocketsQueue.removeAt(0);
      if (socket1.isClosed) continue;

      var socket2 = _server2SocketsQueue.removeAt(0);
      if (socket2.isClosed) {
        // Put socket1 back; it still needs a peer.
        _server1SocketsQueue.insert(0, socket1);
        continue;
      }

      var tunnel = Tunnel.pair(socket1, socket2, verbose: verbose);

      if (verbose) {
        _log.info('-- Connected: $tunnel');
      }
    }
  }

  @override
  String toString() {
    return 'TunnelBridge{ listenPort1: $listenPort1, listenPort2: $listenPort2 }';
  }
}
