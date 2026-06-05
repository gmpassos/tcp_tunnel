import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tcp_tunnel/tcp_tunnel.dart';
import 'package:test/test.dart';

Future<int> freePort() async {
  var s = await ServerSocket.bind('localhost', 0);
  var port = s.port;
  await s.close();
  return port;
}

Future<void> _wait([int ms = 30]) => Future.delayed(Duration(milliseconds: ms));

/// Polls [condition] until true or [timeoutMs] elapses.
Future<bool> waitFor(bool Function() condition, {int timeoutMs = 5000}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await _wait(20);
  }
  return condition();
}

/// A connected (client, accepted) socket pair on localhost.
Future<List<Socket>> socketPair() async {
  final server = await ServerSocket.bind('localhost', 0);
  final acceptedFuture = server.first;
  final client = await Socket.connect('localhost', server.port);
  final accepted = await acceptedFuture;
  await server.close();
  return [client, accepted];
}

/// Echoes back everything received, optionally sending a [greeting] on connect
/// (to exercise server-speaks-first protocols).
class EchoServer {
  final ServerSocket server;
  final String? greeting;
  int connections = 0;

  EchoServer._(this.server, this.greeting) {
    server.listen((socket) {
      connections++;
      final g = greeting;
      if (g != null) socket.add(utf8.encode(g));
      socket.listen(
        socket.add,
        onError: (_) {},
        onDone: () => socket.destroy(),
      );
    });
  }

  static Future<EchoServer> bind({String? greeting}) async =>
      EchoServer._(await ServerSocket.bind('localhost', 0), greeting);

  int get port => server.port;

  Future<void> close() => server.close();
}

/// Connects to [port], sends [send], and collects received bytes.
class TestClient {
  final Socket socket;
  final BytesBuilder _received = BytesBuilder();

  TestClient._(this.socket) {
    socket.listen(_received.add, onError: (_) {}, onDone: () {});
  }

  static Future<TestClient> connect(int port) async =>
      TestClient._(await Socket.connect('localhost', port));

  void send(String s) => socket.add(utf8.encode(s));

  String get text => utf8.decode(_received.toBytes(), allowMalformed: true);

  Future<void> close() async => socket.destroy();
}

void main() {
  group('protocol frames', () {
    test('encode/decode round-trip', () {
      final frame = Frame.hello(role: 'server', service: 'mysql');
      final bytes = encodeFrame(frame);
      final decoded = decodeFrame(bytes)!;
      expect(decoded.consumed, bytes.length);
      expect(decoded.frame.type, FrameType.hello);
      expect(decoded.frame.role, 'server');
      expect(decoded.frame.service, 'mysql');
    });

    test('empty-payload frames (ping/pong/ready)', () {
      for (var f in [Frame.pingFrame, Frame.pongFrame, Frame.readyFrame]) {
        final decoded = decodeFrame(encodeFrame(f))!;
        expect(decoded.frame.type, f.type);
        expect(decoded.frame.payload, isEmpty);
      }
    });

    test('returns null on incomplete buffer', () {
      final bytes = encodeFrame(Frame.activate(peer: '1.2.3.4:5'));
      for (var n = 0; n < bytes.length; n++) {
        expect(decodeFrame(bytes.sublist(0, n)), isNull, reason: 'len=$n');
      }
      expect(decodeFrame(bytes), isNotNull);
    });

    test('throws on bad magic', () {
      expect(
        () => decodeFrame([0, 1, 2, 3, 4, 0, 0]),
        throwsA(isA<FormatException>()),
      );
    });

    test('two frames plus trailing raw bytes', () {
      final raw = utf8.encode('RAWDATA');
      final buffer = <int>[
        ...encodeFrame(Frame.pingFrame),
        ...encodeFrame(Frame.hello(role: 'client', service: 'x')),
        ...raw,
      ];

      final first = decodeFrame(buffer)!;
      expect(first.frame.type, FrameType.ping);

      final rest = buffer.sublist(first.consumed);
      final second = decodeFrame(rest)!;
      expect(second.frame.type, FrameType.hello);
      expect(second.frame.service, 'x');

      final leftover = rest.sublist(second.consumed);
      expect(leftover, equals(raw));
    });
  });

  group('FramedConnection + adopt', () {
    test('reads a frame split across multiple writes', () async {
      final pair = await socketPair();
      final writer = pair[0];
      final conn = FramedConnection(pair[1]);

      final frameBytes = encodeFrame(Frame.hello(role: 'server', service: 's'));
      // Feed one byte at a time.
      for (var b in frameBytes) {
        writer.add([b]);
        await writer.flush();
        await _wait(2);
      }

      final frame = await conn.readFrame();
      expect(frame.type, FrameType.hello);
      expect(frame.service, 's');

      conn.close();
      await writer.close();
    });

    test('adopt replays leftover then delivers live bytes in order', () async {
      final pair = await socketPair();
      final writer = pair[0];
      final conn = FramedConnection(pair[1]);

      // HELLO frame coalesced with raw payload that follows the handshake.
      writer.add(encodeFrame(Frame.hello(role: 'client', service: 's')));
      writer.add(utf8.encode('LEFTOVER'));
      await writer.flush();

      final frame = await conn.readFrame();
      expect(frame.type, FrameType.hello);

      final adopted = SocketAsync.adopt(conn);
      final got = BytesBuilder();
      adopted.listen((d) {
        got.add(d);
        return null;
      });

      await _wait();
      writer.add(utf8.encode('-LIVE'));
      await writer.flush();

      await waitFor(() => utf8.decode(got.toBytes()).contains('LIVE'));
      expect(utf8.decode(got.toBytes()), 'LEFTOVER-LIVE');

      adopted.close();
      await writer.close();
    });
  });

  group('hub integration', () {
    test(
      'public port mode: plain client via public port round-trips',
      () async {
        final echo = await EchoServer.bind();
        final controlPort = await freePort();
        final publicPort = await freePort();

        final hub = TunnelHub(controlPort, servicePorts: {'svc': publicPort});
        await hub.start();

        final agent = TunnelServerAgent(
          'localhost',
          controlPort,
          'svc',
          echo.port,
          poolSize: 2,
        );
        await agent.start();
        await _wait(150); // warm the pool

        final client = await TestClient.connect(publicPort);
        client.send('ping-mode1');

        expect(await waitFor(() => client.text == 'ping-mode1'), isTrue);

        await client.close();
        agent.close();
        hub.close();
        await echo.close();
      },
    );

    test('public port mode: dynamic port (servicePorts=0) is allocated and '
        'round-trips', () async {
      final echo = await EchoServer.bind();
      final controlPort = await freePort();

      // Port 0 => OS-allocated ephemeral public port.
      final hub = TunnelHub(controlPort, servicePorts: {'svc': 0});
      await hub.start();

      final publicPort = hub.boundPorts['svc']!;
      expect(publicPort, greaterThan(0));

      final agent = TunnelServerAgent(
        'localhost',
        controlPort,
        'svc',
        echo.port,
        poolSize: 2,
      );
      await agent.start();
      await _wait(150);

      final client = await TestClient.connect(publicPort);
      client.send('ping-dyn');
      expect(await waitFor(() => client.text == 'ping-dyn'), isTrue);

      await client.close();
      agent.close();
      hub.close();
      await echo.close();
    });

    test('--map-dynamic: any published service gets a public port', () async {
      final echo = await EchoServer.bind();
      final controlPort = await freePort();

      final hub = TunnelHub(controlPort, dynamicPublicPorts: true);
      await hub.start();

      // No public port for "anysvc" until an agent publishes it.
      expect(hub.boundPorts, isEmpty);

      final agent = TunnelServerAgent(
        'localhost',
        controlPort,
        'anysvc',
        echo.port,
        poolSize: 2,
      );
      await agent.start();

      // The hub auto-allocates a public port on first registration.
      expect(await waitFor(() => hub.boundPorts.containsKey('anysvc')), isTrue);
      final publicPort = hub.boundPorts['anysvc']!;
      expect(publicPort, greaterThan(0));

      await _wait(100);
      final client = await TestClient.connect(publicPort);
      client.send('ping-anysvc');
      expect(await waitFor(() => client.text == 'ping-anysvc'), isTrue);

      await client.close();
      agent.close();
      hub.close();
      await echo.close();
    });

    test('local port mode: client agent local port round-trips', () async {
      final echo = await EchoServer.bind();
      final controlPort = await freePort();
      final localPort = await freePort();

      final hub = TunnelHub(controlPort);
      await hub.start();

      final server = TunnelServerAgent(
        'localhost',
        controlPort,
        'svc',
        echo.port,
        poolSize: 2,
      );
      await server.start();

      final client = TunnelClientAgent(
        'localhost',
        controlPort,
        'svc',
        localPort,
      );
      await client.start();
      await _wait(150);

      final app = await TestClient.connect(localPort);
      app.send('ping-mode2');

      expect(await waitFor(() => app.text == 'ping-mode2'), isTrue);

      await app.close();
      client.close();
      server.close();
      hub.close();
      await echo.close();
    });

    test('server-speaks-first: greeting reaches client', () async {
      final echo = await EchoServer.bind(greeting: 'WELCOME\n');
      final controlPort = await freePort();
      final publicPort = await freePort();

      final hub = TunnelHub(controlPort, servicePorts: {'svc': publicPort});
      await hub.start();
      final agent = TunnelServerAgent(
        'localhost',
        controlPort,
        'svc',
        echo.port,
        poolSize: 2,
      );
      await agent.start();
      await _wait(150);

      final client = await TestClient.connect(publicPort);
      // Do NOT send anything first: the greeting must arrive on its own.
      expect(await waitFor(() => client.text == 'WELCOME\n'), isTrue);

      client.send('echo-me');
      expect(await waitFor(() => client.text == 'WELCOME\necho-me'), isTrue);

      await client.close();
      agent.close();
      hub.close();
      await echo.close();
    });

    test('pool refill: sequential connections all succeed', () async {
      final echo = await EchoServer.bind();
      final controlPort = await freePort();
      final publicPort = await freePort();

      final hub = TunnelHub(controlPort, servicePorts: {'svc': publicPort});
      await hub.start();
      final agent = TunnelServerAgent(
        'localhost',
        controlPort,
        'svc',
        echo.port,
        poolSize: 2,
      );
      await agent.start();
      await _wait(150);

      for (var i = 0; i < 5; i++) {
        final client = await TestClient.connect(publicPort);
        final msg = 'seq-$i';
        client.send(msg);
        expect(
          await waitFor(() => client.text == msg),
          isTrue,
          reason: 'iteration $i',
        );
        await client.close();
        await _wait(50); // allow refill
      }

      agent.close();
      hub.close();
      await echo.close();
    });

    test('pool refill: concurrent connections all succeed', () async {
      final echo = await EchoServer.bind();
      final controlPort = await freePort();
      final publicPort = await freePort();

      final hub = TunnelHub(controlPort, servicePorts: {'svc': publicPort});
      await hub.start();
      final agent = TunnelServerAgent(
        'localhost',
        controlPort,
        'svc',
        echo.port,
        poolSize: 2,
      );
      await agent.start();
      await _wait(150);

      final clients = await Future.wait([
        for (var i = 0; i < 4; i++) TestClient.connect(publicPort),
      ]);
      for (var i = 0; i < clients.length; i++) {
        clients[i].send('c$i');
      }

      for (var i = 0; i < clients.length; i++) {
        expect(
          await waitFor(() => clients[i].text == 'c$i'),
          isTrue,
          reason: 'client $i',
        );
      }

      for (var c in clients) {
        await c.close();
      }
      agent.close();
      hub.close();
      await echo.close();
    });

    test('client times out when no server is registered', () async {
      final controlPort = await freePort();
      final publicPort = await freePort();

      final hub = TunnelHub(
        controlPort,
        servicePorts: {'svc': publicPort},
        clientWaitTimeout: const Duration(milliseconds: 300),
      );
      await hub.start();

      final client = await Socket.connect('localhost', publicPort);
      var closed = false;
      client.listen((_) {}, onDone: () => closed = true, onError: (_) {});

      expect(await waitFor(() => closed, timeoutMs: 2000), isTrue);

      hub.close();
    });

    test('dead parked conns are evicted (no hang on stale pool)', () async {
      final echo = await EchoServer.bind();
      final controlPort = await freePort();
      final publicPort = await freePort();

      final hub = TunnelHub(
        controlPort,
        servicePorts: {'svc': publicPort},
        clientWaitTimeout: const Duration(milliseconds: 400),
      );
      await hub.start();

      final agent = TunnelServerAgent(
        'localhost',
        controlPort,
        'svc',
        echo.port,
        poolSize: 2,
      );
      await agent.start();
      await _wait(150);

      // Kill the agent: its parked conns close and must be evicted from the pool.
      agent.close();
      await _wait(150);

      // A new client should not be handed a dead conn; it times out cleanly.
      final client = await Socket.connect('localhost', publicPort);
      var closed = false;
      client.listen((_) {}, onDone: () => closed = true, onError: (_) {});

      expect(await waitFor(() => closed, timeoutMs: 2000), isTrue);

      hub.close();
      await echo.close();
    });
  });
}
