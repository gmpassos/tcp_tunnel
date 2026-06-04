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

  static Future<RecordingServer> bind(int port, {String host = 'localhost'}) async =>
      RecordingServer._(await ServerSocket.bind(host, port));

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

  group('Connection failures', () {
    test('connect fires onClose when remote is unreachable', () async {
      final deadRemote =
          await freePort(); // bound then released: nothing listening
      final target = await freePort();

      final closed = Completer<void>();
      Tunnel.connect(
        'localhost',
        deadRemote,
        target,
        onClose: (_) {
          if (!closed.isCompleted) closed.complete();
        },
      );

      await closed.future.timeout(Duration(seconds: 5));
      expect(closed.isCompleted, isTrue);
    });

    test('connectAsync fires onClose when target is unreachable', () async {
      // A remote that immediately sends data, triggering the lazy target connect.
      final remotePort = await freePort();
      final remote = await ServerSocket.bind('localhost', remotePort);
      remote.listen((s) => s.add([1, 2, 3]));

      final deadTarget = await freePort(); // nothing listening

      final closed = Completer<void>();
      Tunnel.connectAsync(
        'localhost',
        remotePort,
        deadTarget,
        onClose: (_) {
          if (!closed.isCompleted) closed.complete();
        },
      );

      await closed.future.timeout(Duration(seconds: 5));
      expect(closed.isCompleted, isTrue);

      await remote.close();
    });
  });

  group('Lazy connect (connectAsync)', () {
    test('connects target only after first remote data arrives', () async {
      final remotePort = await freePort();
      final remote = await ServerSocket.bind('localhost', remotePort);
      Socket? remoteSide;
      remote.listen((s) => remoteSide = s);

      var targetConnections = 0;
      final targetPort = await freePort();
      final target = await ServerSocket.bind('localhost', targetPort);
      target.listen((_) => targetConnections++);

      final tunnel = Tunnel.connectAsync('localhost', remotePort, targetPort);
      await _wait(100);

      expect(
        targetConnections,
        equals(0),
        reason: 'target must not be connected before any remote data',
      );

      remoteSide!.add([1, 2, 3]);
      await remoteSide!.flush();
      await _wait(100);

      expect(
        targetConnections,
        equals(1),
        reason: 'target connects after the first remote data',
      );

      tunnel.close();
      await remote.close();
      await target.close();
    });
  });

  group('Backpressure', () {
    test('transfers a large payload intact through a tunnel', () async {
      final echoPort = await freePort();
      final echo = await echoServer(echoPort);

      final localPort = await freePort();
      final tunnel = TunnelLocalServer(localPort, echoPort);
      await tunnel.start();

      const size = 4 * 1024 * 1024; // 4 MiB, well past socket buffers.
      final payload = Uint8List(size);
      for (var i = 0; i < size; i++) {
        payload[i] = i & 0xFF;
      }

      var received = 0;
      var corrupted = false;
      final done = Completer<void>();

      final socket = await Socket.connect('localhost', localPort);
      socket.listen((d) {
        for (var i = 0; i < d.length; i++) {
          if (d[i] != ((received + i) & 0xFF)) corrupted = true;
        }
        received += d.length;
        if (received >= size && !done.isCompleted) done.complete();
      });

      socket.add(payload);
      await socket.flush();
      await done.future.timeout(Duration(seconds: 30));

      expect(received, equals(size));
      expect(corrupted, isFalse, reason: 'payload must arrive byte-for-byte');

      await socket.close();
      tunnel.close();
      await echo.close();
    });
  });

  group('TunnelBridge eviction', () {
    test('a queued socket that closes before pairing is not paired', () async {
      final port1 = await freePort();
      final port2 = await freePort();
      final bridge = TunnelBridge(port1, port2);
      await bridge.start();

      // A connection on side 1 with no peer yet, then closed while queued.
      final dead = await Socket.connect('localhost', port1);
      await _wait();
      await dead.close();
      // Wait past the SocketAsync close delay so the dead socket is evicted.
      await _wait(1300);

      // A fresh live pair: 'a' must pair with 'b', not the evicted dead socket.
      final a = await Socket.connect('localhost', port1);
      final b = await Socket.connect('localhost', port2);
      final bReceived = <int>[];
      b.listen(bReceived.addAll);
      await _wait();

      a.add([42]);
      await a.flush();
      await _wait();

      expect(
        bReceived,
        equals([42]),
        reason: 'live socket must pair with the live peer, not a dead one',
      );

      await a.close();
      await b.close();
      bridge.close();
    });
  });

  group('CLI', () {
    test('prints usage and exits 0 with no args', () async {
      final result = await Process.run('dart', [
        'run',
        'bin/tcp_tunnel.dart',
      ]).timeout(Duration(seconds: 60));

      expect(result.exitCode, equals(0));
      expect(result.stdout.toString(), contains('USAGE'));
    });
  });

  group('connectAsync correctness', () {
    test('forwards the first (triggering) data to the target', () async {
      // Remote sends data on connect; that first data both triggers the lazy
      // target connect AND must be delivered to the target (it is buffered as
      // an unflushed write until the target socket resolves).
      final remotePort = await freePort();
      final remote = await ServerSocket.bind('localhost', remotePort);
      Socket? remoteSide;
      remote.listen((s) {
        remoteSide = s;
        s.add('HELLO'.codeUnits);
      });

      final targetPort = await freePort();
      final target = await RecordingServer.bind(targetPort);

      final tunnel = Tunnel.connectAsync('localhost', remotePort, targetPort);
      await tunnel.onReady.timeout(Duration(seconds: 5));
      await _wait();

      expect(target.firstFlat, equals('HELLO'.codeUnits));

      // A subsequent chunk is forwarded too.
      remoteSide!.add('WORLD'.codeUnits);
      await remoteSide!.flush();
      await _wait();

      expect(target.firstFlat, equals('HELLOWORLD'.codeUnits));

      tunnel.close();
      await remote.close();
      await target.close();
    });

    test('bidirectional round-trip and onReady completes', () async {
      final remotePort = await freePort();
      final remote = await ServerSocket.bind('localhost', remotePort);
      final remoteReceived = <int>[];
      final remoteSideReady = Completer<Socket>();
      remote.listen((s) {
        remoteSideReady.complete(s);
        s.listen(remoteReceived.addAll);
      });

      final echoPort = await freePort();
      final echo = await echoServer(echoPort);

      final tunnel = Tunnel.connectAsync('localhost', remotePort, echoPort);
      final remoteSide = await remoteSideReady.future.timeout(
        Duration(seconds: 5),
      );

      // First data triggers the target connect and round-trips via the echo.
      remoteSide.add([1, 2, 3]);
      await remoteSide.flush();
      await tunnel.onReady.timeout(Duration(seconds: 5));
      await _wait();

      expect(remoteReceived, equals([1, 2, 3]));

      tunnel.close();
      await remote.close();
      await echo.close();
    });
  });

  group('TunnelBridge buffering and isolation', () {
    test('data sent while queued is delivered after pairing', () async {
      final port1 = await freePort();
      final port2 = await freePort();
      final bridge = TunnelBridge(port1, port2);
      await bridge.start();

      // 'a' connects and sends data before any peer exists on side 2.
      final a = await Socket.connect('localhost', port1);
      await _wait();
      a.add([7, 7, 7]);
      await a.flush();
      await _wait();

      // Peer arrives; the buffered data must be replayed to it.
      final b = await Socket.connect('localhost', port2);
      final bReceived = <int>[];
      b.listen(bReceived.addAll);
      await _wait();

      expect(
        bReceived,
        equals([7, 7, 7]),
        reason: 'data buffered while queued must be delivered after pairing',
      );

      await a.close();
      await b.close();
      bridge.close();
    });

    test('many concurrent pairs stay isolated (FIFO)', () async {
      const n = 10;
      final port1 = await freePort();
      final port2 = await freePort();
      final bridge = TunnelBridge(port1, port2);
      await bridge.start();

      // Connect all side-1 sockets first (in order), then all side-2 sockets,
      // so FIFO pairing maps index i on side 1 to index i on side 2.
      final side1 = <Socket>[];
      for (var i = 0; i < n; i++) {
        side1.add(await Socket.connect('localhost', port1));
        await _wait(5);
      }

      final side2 = <Socket>[];
      final received = List.generate(n, (_) => <int>[]);
      for (var i = 0; i < n; i++) {
        final s = await Socket.connect('localhost', port2);
        final idx = i;
        s.listen(received[idx].addAll);
        side2.add(s);
        await _wait(5);
      }
      await _wait();

      for (var i = 0; i < n; i++) {
        side1[i].add([i]);
        await side1[i].flush();
      }
      await _wait(100);

      for (var i = 0; i < n; i++) {
        expect(received[i], equals([i]), reason: 'pair $i must be isolated');
      }

      for (final s in [...side1, ...side2]) {
        await s.close();
      }
      bridge.close();
    });

    test('closing one paired socket tears down its peer', () async {
      final port1 = await freePort();
      final port2 = await freePort();
      final bridge = TunnelBridge(port1, port2);
      await bridge.start();

      final a = await Socket.connect('localhost', port1);
      final b = await Socket.connect('localhost', port2);

      final bDone = Completer<void>();
      b.listen(
        (_) {},
        onDone: () {
          if (!bDone.isCompleted) bDone.complete();
        },
      );
      await _wait();

      await a.close();

      await bDone.future.timeout(Duration(seconds: 5));
      expect(bDone.isCompleted, isTrue);

      await b.close();
      bridge.close();
    });
  });

  group('TunnelLocalServer failure', () {
    test('drops the client connection when the target is unreachable', () async {
      final localPort = await freePort();
      final deadTarget = await freePort(); // nothing listening
      final server = TunnelLocalServer(localPort, deadTarget);
      await server.start();

      final socket = await Socket.connect('localhost', localPort);
      final done = Completer<void>();
      socket.listen(
        (_) {},
        onError: (_) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );

      await done.future.timeout(Duration(seconds: 5));
      expect(done.isCompleted, isTrue);

      server.close();
    });
  });

  group('Callbacks and options', () {
    test('onStart fires once with the tunnel', () async {
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

      var startCount = 0;
      Tunnel? started;
      final tunnel = Tunnel.withSockets(
        await acceptA.future,
        await acceptB.future,
        onStart: (t) {
          startCount++;
          started = t;
        },
      );
      await tunnel.onReady;
      await _wait();

      expect(startCount, equals(1));
      expect(started, same(tunnel));

      tunnel.close();
      await clientA.close();
      await clientB.close();
      await server1.close();
      await server2.close();
    });

    test('verbose tunnel still forwards data', () async {
      final serverPort = await freePort();
      final server = await RecordingServer.bind(serverPort);

      final localPort = await freePort();
      final tunnel = TunnelLocalServer(localPort, serverPort, verbose: true);
      await tunnel.start();

      final socket = await Socket.connect('localhost', localPort);
      socket.add([1, 2, 3]);
      await socket.flush();
      await _wait();

      expect(server.firstFlat, equals([1, 2, 3]));

      await socket.close();
      tunnel.close();
      await server.close();
    });

    test('custom targetHost forwards correctly', () async {
      final serverPort = await freePort();
      // Bind the backend on the same explicit IP the tunnel will target, so the
      // test does not depend on how 'localhost' resolves (IPv4 vs IPv6).
      final server = await RecordingServer.bind(serverPort, host: '127.0.0.1');

      final localPort = await freePort();
      final tunnel = TunnelLocalServer(
        localPort,
        serverPort,
        targetHost: '127.0.0.1',
      );
      await tunnel.start();

      final socket = await Socket.connect('localhost', localPort);
      socket.add([9, 8, 7]);
      await socket.flush();
      await _wait();

      expect(server.firstFlat, equals([9, 8, 7]));

      await socket.close();
      tunnel.close();
      await server.close();
    });
  });

  group('Data edge cases', () {
    test('half-close: data written before close still drains', () async {
      final serverPort = await freePort();
      final server = await RecordingServer.bind(serverPort);

      final localPort = await freePort();
      final tunnel = TunnelLocalServer(localPort, serverPort);
      await tunnel.start();

      final socket = await Socket.connect('localhost', localPort);
      socket.add([1, 2, 3, 4, 5]);
      // Close immediately after queuing data (no explicit drain wait).
      await socket.close();

      await _wait(200);
      expect(
        server.firstFlat,
        equals([1, 2, 3, 4, 5]),
        reason: 'data written before close must be delivered',
      );

      tunnel.close();
      await server.close();
    });

    test('zero-length write is tolerated', () async {
      final serverPort = await freePort();
      final server = await RecordingServer.bind(serverPort);

      final localPort = await freePort();
      final tunnel = TunnelLocalServer(localPort, serverPort);
      await tunnel.start();

      final socket = await Socket.connect('localhost', localPort);
      socket.add(<int>[]); // empty
      await socket.flush();
      await _wait();
      socket.add([1, 2, 3]);
      await socket.flush();
      await _wait();

      expect(server.firstFlat, equals([1, 2, 3]));

      await socket.close();
      tunnel.close();
      await server.close();
    });

    test('withSockets relays in the reverse direction (B to A)', () async {
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

      final tunnel = Tunnel.withSockets(
        await acceptA.future,
        await acceptB.future,
      );
      await tunnel.onReady;

      final aRecv = <int>[];
      clientA.listen(aRecv.addAll);

      clientB.add([3, 2, 1]);
      await clientB.flush();
      await _wait();

      expect(aRecv, equals([3, 2, 1]));

      tunnel.close();
      await clientA.close();
      await clientB.close();
      await server1.close();
      await server2.close();
    });

    test('large bidirectional transfer stays intact', () async {
      final port1 = await freePort();
      final port2 = await freePort();
      final bridge = TunnelBridge(port1, port2);
      await bridge.start();

      final a = await Socket.connect('localhost', port1);
      final b = await Socket.connect('localhost', port2);

      const size = 256 * 1024;
      Uint8List payload(int seed) {
        final u = Uint8List(size);
        for (var i = 0; i < size; i++) {
          u[i] = (i + seed) & 0xFF;
        }
        return u;
      }

      const aSeed = 0;
      const bSeed = 7;

      var aRecv = 0, bRecv = 0;
      var aBad = false, bBad = false;
      final aDone = Completer<void>();
      final bDone = Completer<void>();

      // 'a' receives what 'b' sent (bSeed); 'b' receives what 'a' sent (aSeed).
      a.listen((d) {
        for (var i = 0; i < d.length; i++) {
          if (d[i] != ((aRecv + i + bSeed) & 0xFF)) aBad = true;
        }
        aRecv += d.length;
        if (aRecv >= size && !aDone.isCompleted) aDone.complete();
      });
      b.listen((d) {
        for (var i = 0; i < d.length; i++) {
          if (d[i] != ((bRecv + i + aSeed) & 0xFF)) bBad = true;
        }
        bRecv += d.length;
        if (bRecv >= size && !bDone.isCompleted) bDone.complete();
      });
      await _wait();

      a.add(payload(aSeed));
      b.add(payload(bSeed));
      await a.flush();
      await b.flush();
      await Future.wait([
        aDone.future,
        bDone.future,
      ]).timeout(Duration(seconds: 30));

      expect(aRecv, equals(size));
      expect(bRecv, equals(size));
      expect(aBad, isFalse, reason: 'B to A stream must be intact');
      expect(bBad, isFalse, reason: 'A to B stream must be intact');

      await a.close();
      await b.close();
      bridge.close();
    });
  });

  group('SocketAsync', () {
    test('getters reflect resolved vs unresolved state', () async {
      final p = await freePort();
      final srv = await ServerSocket.bind('localhost', p);
      final acceptC = Completer<Socket>();
      srv.listen(acceptC.complete);
      final client = await Socket.connect('localhost', p);
      final accepted = await acceptC.future;

      final resolved = SocketAsync.from(accepted);
      expect(resolved.isResolved, isTrue);
      expect(resolved.port, greaterThan(0));
      expect(resolved.remoteAddress, isNotEmpty);
      resolved.close();

      final unresolved = SocketAsync.unresolved(Completer<Socket>().future);
      expect(unresolved.isResolved, isFalse);
      unresolved.close();

      await client.close();
      await srv.close();
    });
  });
}
