import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:tcp_tunnel/tcp_tunnel.dart';
import 'package:test/test.dart';

/// Binds an ephemeral port, then releases it so it can be reused by a tunnel.
Future<int> freePort() async {
  var s = await ServerSocket.bind('localhost', 0);
  var port = s.port;
  await s.close();
  return port;
}

Future<void> _wait([int ms = 30]) => Future.delayed(Duration(milliseconds: ms));

/// Collects every chunk received per accepted socket.
class RecordingServer {
  final ServerSocket server;
  final List<Socket> sockets = [];
  final Map<Socket, List<Uint8List>> data = {};

  RecordingServer._(this.server) {
    server.listen((socket) {
      sockets.add(socket);
      socket.listen((d) => (data[socket] ??= []).add(Uint8List.fromList(d)));
    });
  }

  static Future<RecordingServer> bind(int port) async =>
      RecordingServer._(await ServerSocket.bind('localhost', port));

  /// All received bytes for the first connection, flattened.
  List<int> get firstFlat =>
      data.isEmpty ? [] : data.values.first.expand((e) => e).toList();

  Future<void> close() => server.close().then((_) {});
}

/// Echoes back every byte it receives.
Future<ServerSocket> echoServer(int port) async {
  var server = await ServerSocket.bind('localhost', port);
  server.listen((socket) {
    socket.listen(socket.add, onError: (_) {}, onDone: socket.close);
  });
  return server;
}

void main() {
  group('TunnelLocalServer', () {
    test('forwards client data to target (one direction)', () async {
      final serverPort = await freePort();
      final server = await RecordingServer.bind(serverPort);

      final localPort = await freePort();
      final tunnel = TunnelLocalServer(localPort, serverPort);
      await tunnel.start();

      final socket = await Socket.connect('localhost', localPort);
      socket.add([1, 2, 3, 4, 5]);
      await socket.flush();
      await _wait();
      socket.add([6, 7, 8, 9, 10]);
      await socket.flush();
      await _wait();
      await socket.close();
      await _wait();

      expect(server.data.length, equals(1));
      expect(server.firstFlat, equals([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]));

      tunnel.close();
      await server.close();
    });

    test('forwards data in both directions (echo target)', () async {
      final echoPort = await freePort();
      final echo = await echoServer(echoPort);

      final localPort = await freePort();
      final tunnel = TunnelLocalServer(localPort, echoPort);
      await tunnel.start();

      final received = <int>[];
      final socket = await Socket.connect('localhost', localPort);
      socket.listen(received.addAll);

      socket.add([10, 20, 30]);
      await socket.flush();
      await _wait();
      socket.add([40, 50]);
      await socket.flush();
      await _wait();

      expect(received, equals([10, 20, 30, 40, 50]));

      await socket.close();
      tunnel.close();
      await echo.close();
    });

    test('close() before start() does not throw', () async {
      final tunnel = TunnelLocalServer(await freePort(), await freePort());
      expect(tunnel.close, returnsNormally);
    });

    test('supports multiple concurrent clients', () async {
      final serverPort = await freePort();
      final server = await RecordingServer.bind(serverPort);

      final localPort = await freePort();
      final tunnel = TunnelLocalServer(localPort, serverPort);
      await tunnel.start();

      final s1 = await Socket.connect('localhost', localPort);
      final s2 = await Socket.connect('localhost', localPort);
      s1.add([1, 1, 1]);
      s2.add([2, 2, 2]);
      await s1.flush();
      await s2.flush();
      await _wait();

      expect(server.data.length, equals(2));
      final allBytes = server.data.values
          .expand((e) => e)
          .expand((e) => e)
          .toList();
      expect(allBytes..sort(), equals([1, 1, 1, 2, 2, 2]));

      await s1.close();
      await s2.close();
      tunnel.close();
      await server.close();
    });
  });

  group('TunnelBridge', () {
    test('connects two queued sockets and relays both directions', () async {
      final port1 = await freePort();
      final port2 = await freePort();
      final bridge = TunnelBridge(port1, port2);
      await bridge.start();

      final a = await Socket.connect('localhost', port1);
      final b = await Socket.connect('localhost', port2);

      final aReceived = <int>[];
      final bReceived = <int>[];
      a.listen(aReceived.addAll);
      b.listen(bReceived.addAll);
      await _wait();

      a.add([1, 2, 3]);
      await a.flush();
      await _wait();
      b.add([9, 8, 7]);
      await b.flush();
      await _wait();

      expect(bReceived, equals([1, 2, 3]));
      expect(aReceived, equals([9, 8, 7]));

      await a.close();
      await b.close();
      bridge.close();
    });

    test('close() before start() does not throw', () async {
      final bridge = TunnelBridge(await freePort(), await freePort());
      expect(bridge.close, returnsNormally);
    });

    test('pairs sockets in arrival order (FIFO queues)', () async {
      final port1 = await freePort();
      final port2 = await freePort();
      final bridge = TunnelBridge(port1, port2);
      await bridge.start();

      // Two connections on side 1 before any on side 2.
      final a1 = await Socket.connect('localhost', port1);
      final a2 = await Socket.connect('localhost', port1);
      await _wait();
      final b1 = await Socket.connect('localhost', port2);
      final b2 = await Socket.connect('localhost', port2);

      final b1Recv = <int>[];
      final b2Recv = <int>[];
      b1.listen(b1Recv.addAll);
      b2.listen(b2Recv.addAll);
      await _wait();

      // a1 should pair with b1, a2 with b2.
      a1.add([11]);
      a2.add([22]);
      await a1.flush();
      await a2.flush();
      await _wait();

      expect(b1Recv, equals([11]));
      expect(b2Recv, equals([22]));

      await a1.close();
      await a2.close();
      await b1.close();
      await b2.close();
      bridge.close();
    });
  });

  group('Tunnel', () {
    test('withSockets relays data between two live sockets', () async {
      final p1 = await freePort();
      final server1 = await ServerSocket.bind('localhost', p1);
      final acceptA = Completer<Socket>();
      server1.listen(acceptA.complete);

      final p2 = await freePort();
      final server2 = await ServerSocket.bind('localhost', p2);
      final acceptB = Completer<Socket>();
      server2.listen(acceptB.complete);

      final clientA = await Socket.connect('localhost', p1);
      final clientB = await Socket.connect('localhost', p2);

      final socketA = await acceptA.future;
      final socketB = await acceptB.future;

      final tunnel = Tunnel.withSockets(socketA, socketB);
      await tunnel.onReady;

      final bRecv = <int>[];
      clientB.listen(bRecv.addAll);

      clientA.add([5, 6, 7]);
      await clientA.flush();
      await _wait();

      expect(bRecv, equals([5, 6, 7]));

      tunnel.close();
      await clientA.close();
      await clientB.close();
      await server1.close();
      await server2.close();
    });

    test('close() is idempotent and notifies onClose once', () async {
      final p1 = await freePort();
      final server1 = await ServerSocket.bind('localhost', p1);
      final acceptA = Completer<Socket>();
      server1.listen(acceptA.complete);

      final p2 = await freePort();
      final server2 = await ServerSocket.bind('localhost', p2);
      final acceptB = Completer<Socket>();
      server2.listen(acceptB.complete);

      final clientA = await Socket.connect('localhost', p1);
      final clientB = await Socket.connect('localhost', p2);

      var closeCount = 0;
      final tunnel = Tunnel.withSockets(
        await acceptA.future,
        await acceptB.future,
        onClose: (_) => closeCount++,
      );
      await tunnel.onReady;

      tunnel.close();
      tunnel.close();
      tunnel.close();
      await _wait();

      expect(closeCount, equals(1));

      await clientA.close();
      await clientB.close();
      await server1.close();
      await server2.close();
    });
  });

  group('Full chain (bridge + client + local)', () {
    test('relays data through bridge both directions', () async {
      final echoPort = await freePort();
      final echo = await echoServer(echoPort);

      final bridgePort1 = await freePort();
      final bridgePort2 = await freePort();
      final localPort = await freePort();

      final bridge = TunnelBridge(bridgePort1, bridgePort2);
      await bridge.start();

      // Client connects bridge side 1 to the echo server.
      final clientTunnel = Tunnel.connect('localhost', bridgePort1, echoPort);
      await clientTunnel.onReady;

      // Local server exposes bridge side 2 locally.
      final local = TunnelLocalServer(localPort, bridgePort2);
      await local.start();
      await _wait();

      final received = <int>[];
      final socket = await Socket.connect('localhost', localPort);
      socket.listen(received.addAll);

      socket.add([1, 2, 3, 4, 5]);
      await socket.flush();
      await _wait();
      socket.add([6, 7, 8, 9, 10]);
      await socket.flush();
      await _wait();

      // Echo server bounces the bytes back through the whole chain.
      expect(received, equals([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]));

      await socket.close();
      clientTunnel.close();
      local.close();
      bridge.close();
      await echo.close();
    });
  });
}
