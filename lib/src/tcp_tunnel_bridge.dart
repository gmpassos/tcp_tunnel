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

  /// Paired tunnels currently running (removed when they close).
  final Set<Tunnel> _tunnels = {};

  bool _closed = false;

  void _enqueue(List<SocketAsync> queue, Socket socket) {
    if (_closed) {
      socket.destroy();
      return;
    }

    final socketAsync = SocketAsync.from(socket);
    queue.add(socketAsync);

    // If a queued socket closes before it is paired, evict it so it is never
    // paired into a dead tunnel.
    socketAsync.onClose = queue.remove;

    _connectTunnels();
  }

  /// Closes the bridge: its listening sockets, any accepted socket still
  /// waiting in a queue for a peer and, by default, every paired tunnel.
  ///
  /// With [closeActiveTunnels] `false` already paired tunnels are left to
  /// finish on their own (graceful shutdown); a later [close] call closes
  /// whatever is still running.
  void close({bool closeActiveTunnels = true}) {
    _closed = true;
    _server1?.close();
    _server2?.close();

    // Closing a queued socket evicts it from its queue (via `onClose`), so
    // iterate over copies.
    for (var socket in [..._server1SocketsQueue, ..._server2SocketsQueue]) {
      socket.close();
    }
    _server1SocketsQueue.clear();
    _server2SocketsQueue.clear();

    if (!closeActiveTunnels) return;

    // Closing a tunnel removes it from [_tunnels] (via `onClose`): iterate a
    // copy.
    for (var tunnel in _tunnels.toList()) {
      tunnel.close();
    }
    _tunnels.clear();
  }

  /// Whether a queued [socket] can no longer be paired: closed, or its peer
  /// already finished sending (EOF/error seen while it waited; it is about to
  /// close). Such a socket is closed and dropped instead of being paired.
  static bool _isGone(SocketAsync socket) {
    if (socket.isClosed) return true;
    if (socket.isInputDone) {
      socket.close();
      return true;
    }
    return false;
  }

  void _connectTunnels() {
    while (_server1SocketsQueue.isNotEmpty && _server2SocketsQueue.isNotEmpty) {
      var socket1 = _server1SocketsQueue.removeAt(0);
      if (_isGone(socket1)) continue;

      var socket2 = _server2SocketsQueue.removeAt(0);
      if (_isGone(socket2)) {
        // Put socket1 back; it still needs a peer.
        _server1SocketsQueue.insert(0, socket1);
        continue;
      }

      var tunnel = Tunnel.pair(
        socket1,
        socket2,
        onClose: _tunnels.remove,
        verbose: verbose,
      );
      _tunnels.add(tunnel);

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
