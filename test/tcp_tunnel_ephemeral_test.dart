// Integration and unit tests that bind every listener to port 0 (OS-chosen
// ephemeral ports, read back via the `bound*` getters), so they never race
// another process for a pre-picked port.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tcp_tunnel/tcp_tunnel.dart';
import 'package:test/test.dart';

const _closeTimeout = Duration(seconds: 10);

/// Polls [condition] until true or [timeout] elapses.
Future<bool> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return condition();
}

/// A client socket that records everything it receives and when it is closed
/// by the peer.
class Peer {
  final Socket socket;
  final BytesBuilder _received = BytesBuilder();
  final Completer<void> _done = Completer<void>();

  Peer(this.socket) {
    socket.listen(
      _received.add,
      onError: (_) {
        if (!_done.isCompleted) _done.complete();
      },
      onDone: () {
        if (!_done.isCompleted) _done.complete();
      },
    );
  }

  static Future<Peer> connect(int port) async =>
      Peer(await Socket.connect('localhost', port));

  String get text => utf8.decode(_received.toBytes(), allowMalformed: true);

  /// Completes when the remote end closes this connection.
  Future<void> get done => _done.future;

  bool get isDone => _done.isCompleted;

  Future<void> send(String s) async {
    socket.add(utf8.encode(s));
    await socket.flush();
  }

  void destroy() => socket.destroy();
}

/// A target service that records each accepted connection as a [Peer].
class TargetServer {
  final ServerSocket server;
  final List<Peer> peers = [];

  TargetServer._(this.server) {
    server.listen((s) => peers.add(Peer(s)));
  }

  static Future<TargetServer> bind() async =>
      TargetServer._(await ServerSocket.bind('localhost', 0));

  int get port => server.port;

  Future<void> close() async {
    for (final p in peers) {
      p.destroy();
    }
    await server.close();
  }
}

/// Echoes back every byte it receives.
Future<ServerSocket> echoServer() async {
  final server = await ServerSocket.bind('localhost', 0);
  server.listen((socket) {
    socket.listen(socket.add, onError: (_) {}, onDone: socket.destroy);
  });
  return server;
}

void main() {
  group('TunnelLocalServer on an ephemeral port', () {
    late TargetServer target;
    late TunnelLocalServer local;

    setUp(() async {
      target = await TargetServer.bind();
      local = TunnelLocalServer(0, target.port);
    });

    tearDown(() async {
      local.close();
      await target.close();
    });

    test('boundPort is null before start and the real port after', () async {
      expect(local.boundPort, isNull);
      await local.start();
      expect(local.boundPort, isNotNull);
      expect(local.boundPort, greaterThan(0));
      expect(local.listenPort, 0);
    });

    test('start() is idempotent', () async {
      await local.start();
      final port = local.boundPort;
      await local.start();
      expect(local.boundPort, port);
    });

    test('relays data in both directions', () async {
      await local.start();
      final client = await Peer.connect(local.boundPort!);

      await client.send('client->target');
      expect(await waitFor(() => target.peers.length == 1), isTrue);
      final server = target.peers.single;
      expect(await waitFor(() => server.text == 'client->target'), isTrue);

      await server.send('target->client');
      expect(await waitFor(() => client.text == 'target->client'), isTrue);

      client.destroy();
    });

    test('client closing propagates to the target connection', () async {
      await local.start();
      final client = await Peer.connect(local.boundPort!);
      await client.send('x');
      expect(await waitFor(() => target.peers.length == 1), isTrue);

      await client.socket.close();
      await target.peers.single.done.timeout(_closeTimeout);
      expect(target.peers.single.isDone, isTrue);
      client.destroy();
    });

    test('target closing propagates to the client connection', () async {
      await local.start();
      final client = await Peer.connect(local.boundPort!);
      await client.send('x');
      expect(await waitFor(() => target.peers.length == 1), isTrue);

      await target.peers.single.socket.close();
      await client.done.timeout(_closeTimeout);
      expect(client.isDone, isTrue);
    });

    test('an unreachable target closes the accepted client', () async {
      // Bind then release a port so nothing listens on it.
      final dead = await ServerSocket.bind('localhost', 0);
      final deadPort = dead.port;
      await dead.close();

      final broken = TunnelLocalServer(0, deadPort);
      await broken.start();
      try {
        final client = await Peer.connect(broken.boundPort!);
        await client.done.timeout(_closeTimeout);
        expect(client.isDone, isTrue);
        expect(client.text, isEmpty);
      } finally {
        broken.close();
      }
    });

    test('start() fails when the port is in use, and can be retried', () async {
      final blocker = await ServerSocket.bind('0.0.0.0', 0);
      final busy = TunnelLocalServer(blocker.port, target.port);
      try {
        await expectLater(busy.start(), throwsA(isA<SocketException>()));
        expect(busy.boundPort, isNull);
      } finally {
        await blocker.close();
      }
      // The failed start must not leave the server marked as started.
      await busy.start();
      expect(busy.boundPort, blocker.port);
      busy.close();
    });
  });

  group('TunnelBridge on ephemeral ports', () {
    test('boundPort1/boundPort2 report the real ports', () async {
      final bridge = TunnelBridge(0, 0);
      expect(bridge.boundPort1, isNull);
      expect(bridge.boundPort2, isNull);
      await bridge.start();
      addTearDown(bridge.close);

      expect(bridge.boundPort1, greaterThan(0));
      expect(bridge.boundPort2, greaterThan(0));
      expect(bridge.boundPort1, isNot(bridge.boundPort2));
    });

    test('pairs a socket from each side and relays both ways', () async {
      final bridge = TunnelBridge(0, 0);
      await bridge.start();
      addTearDown(bridge.close);

      final a = await Peer.connect(bridge.boundPort1!);
      final b = await Peer.connect(bridge.boundPort2!);
      addTearDown(a.destroy);
      addTearDown(b.destroy);

      await a.send('from-a');
      expect(await waitFor(() => b.text == 'from-a'), isTrue);
      await b.send('from-b');
      expect(await waitFor(() => a.text == 'from-b'), isTrue);
    });

    test('closing one side of a paired tunnel closes the other', () async {
      final bridge = TunnelBridge(0, 0);
      await bridge.start();
      addTearDown(bridge.close);

      final a = await Peer.connect(bridge.boundPort1!);
      final b = await Peer.connect(bridge.boundPort2!);
      addTearDown(b.destroy);
      await a.send('hi');
      expect(await waitFor(() => b.text == 'hi'), isTrue);

      await a.socket.close();
      await b.done.timeout(_closeTimeout);
      expect(b.isDone, isTrue);
      a.destroy();
    });

    test('close() closes accepted sockets still waiting for a peer', () async {
      final bridge = TunnelBridge(0, 0);
      await bridge.start();

      final waiting = await Peer.connect(bridge.boundPort1!);
      addTearDown(waiting.destroy);
      // Give the bridge time to accept and queue it.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      bridge.close();
      await waiting.done.timeout(_closeTimeout);
      expect(waiting.isDone, isTrue);
    });

    test('a failed start releases the first port and can be retried', () async {
      final blocker = await ServerSocket.bind('0.0.0.0', 0);
      final bridge = TunnelBridge(0, blocker.port);
      try {
        await expectLater(bridge.start(), throwsA(isA<SocketException>()));
        // The first (successfully bound) port was released again.
        expect(bridge.boundPort1, isNull);
        expect(bridge.boundPort2, isNull);
      } finally {
        await blocker.close();
      }

      await bridge.start();
      addTearDown(bridge.close);
      expect(bridge.boundPort1, greaterThan(0));
      expect(bridge.boundPort2, blocker.port);
    });
  });

  group('Tunnel', () {
    test('connectAsync relays a server-speaks-first remote to the target '
        'and back', () async {
      // remote: a bridge-like listener whose accepted socket we control.
      final remote = await ServerSocket.bind('localhost', 0);
      final echo = await echoServer();
      final accepted = remote.first;

      final closed = Completer<void>();
      final tunnel = Tunnel.connectAsync(
        'localhost',
        remote.port,
        echo.port,
        onClose: (_) {
          if (!closed.isCompleted) closed.complete();
        },
      );

      final remoteSide = Peer(await accepted);
      // The target is only dialed after the first remote byte.
      await remoteSide.send('ping');
      await tunnel.onReady.timeout(_closeTimeout);
      expect(await waitFor(() => remoteSide.text == 'ping'), isTrue);

      tunnel.close();
      await closed.future.timeout(_closeTimeout);
      await remoteSide.done.timeout(_closeTimeout);

      await remote.close();
      await echo.close();
    });

    test('toString describes both endpoints', () async {
      final server = await ServerSocket.bind('localhost', 0);
      final acceptedF = server.first;
      final a = await Socket.connect('localhost', server.port);
      final b = await acceptedF;
      final tunnel = Tunnel.withSockets(a, b);
      expect(tunnel.toString(), startsWith('Tunnel{ '));
      expect(tunnel.toString(), contains('<-->'));
      tunnel.close();
      await server.close();
    });
  });

  group('hub with ephemeral ports', () {
    test('boundControlPort/boundListenPort report the real ports and the '
        'local port mode pipe works end to end', () async {
      final echo = await echoServer();
      addTearDown(echo.close);

      final hub = TunnelHub(0);
      expect(hub.boundControlPort, isNull);
      await hub.start();
      addTearDown(hub.close);
      final controlPort = hub.boundControlPort!;
      expect(controlPort, greaterThan(0));

      final publisher = TunnelServerAgent(
        'localhost',
        controlPort,
        'svc',
        echo.port,
        poolSize: 1,
      );
      await publisher.start();
      addTearDown(publisher.close);

      final consumer = TunnelClientAgent(
        'localhost',
        controlPort,
        'svc',
        0,
        listenHost: 'localhost',
      );
      expect(consumer.boundListenPort, isNull);
      await consumer.start();
      addTearDown(consumer.close);
      expect(consumer.boundListenPort, greaterThan(0));

      final app = await Peer.connect(consumer.boundListenPort!);
      addTearDown(app.destroy);
      await app.send('through-the-hub');
      expect(await waitFor(() => app.text == 'through-the-hub'), isTrue);
    });
  });

  group('hub control port rejects malformed handshakes', () {
    late TunnelHub hub;

    setUp(() async {
      hub = TunnelHub(0);
      await hub.start();
    });

    tearDown(() => hub.close());

    Future<void> expectClosedAfter(List<int> bytes) async {
      final peer = await Peer.connect(hub.boundControlPort!);
      addTearDown(peer.destroy);
      peer.socket.add(bytes);
      await peer.socket.flush();
      await peer.done.timeout(_closeTimeout);
      expect(peer.isDone, isTrue);
    }

    test('a non-HELLO first frame', () async {
      await expectClosedAfter(encodeFrame(Frame.pingFrame));
    });

    test('a HELLO without a service', () async {
      await expectClosedAfter(
        encodeFrame(const Frame(FrameType.hello, {'role': 'server'})),
      );
    });

    test('a HELLO with an unknown role', () async {
      await expectClosedAfter(
        encodeFrame(Frame.hello(role: 'observer', service: 'svc')),
      );
    });

    test('bytes that are not a frame', () async {
      await expectClosedAfter(utf8.encode('GET / HTTP/1.1\r\n\r\n'));
    });
  });

  group('PortRange.parse validation', () {
    test('rejects out-of-range and inverted ranges', () {
      for (final spec in ['0', '0-10', '10-5', '70000', '1-65536']) {
        expect(
          () => PortRange.parse(spec),
          throwsA(isA<FormatException>()),
          reason: spec,
        );
      }
    });

    test('rejects non-numeric specs', () {
      expect(() => PortRange.parse('abc'), throwsFormatException);
      expect(() => PortRange.parse('1-x'), throwsFormatException);
    });

    test('accepts the full valid range and trims spaces', () {
      final r = PortRange.parse(' 1 - 65535 ');
      expect(r.start, 1);
      expect(r.end, 65535);
      expect(r.contains(1), isTrue);
      expect(r.contains(65535), isTrue);
      expect(r.contains(0), isFalse);
    });
  });

  group('protocol units', () {
    test('FrameType.fromCode rejects unknown codes', () {
      for (final t in FrameType.values) {
        expect(FrameType.fromCode(t.code), t);
      }
      expect(() => FrameType.fromCode(99), throwsFormatException);
    });

    test('decodeFrame rejects an unknown frame type', () {
      final bytes = Uint8List.fromList([...kFrameMagic, 99, 0, 0]);
      expect(() => decodeFrame(bytes), throwsFormatException);
    });

    test('encodeFrame rejects payloads larger than 64 KiB', () {
      final frame = Frame(FrameType.hello, {'big': 'x' * 0x10000});
      expect(() => encodeFrame(frame), throwsArgumentError);
    });

    test('frame factories and getters round-trip', () {
      DecodedFrame rt(Frame f) => decodeFrame(encodeFrame(f))!;

      final hello = rt(
        Frame.hello(role: 'server', service: 's', publicPort: 0, token: 't'),
      ).frame;
      expect(hello.role, 'server');
      expect(hello.service, 's');
      expect(hello.publicPort, 0);
      expect(hello.token, 't');

      final bare = Frame.hello(role: 'client', service: 's');
      expect(bare.payload.containsKey('token'), isFalse);
      expect(bare.payload.containsKey('publicPort'), isFalse);

      expect(rt(Frame.activate(peer: '1.2.3.4:5')).frame.peer, '1.2.3.4:5');
      expect(Frame.activate().payload, isEmpty);
      expect(rt(Frame.welcome(publicPort: 1234)).frame.publicPort, 1234);
      expect(Frame.welcome().publicPort, isNull);
      expect(rt(Frame.reject('nope')).frame.reason, 'nope');
      expect(Frame.readyFrame.toString(), contains('ready'));
    });

    test('constantTimeEquals', () {
      expect(constantTimeEquals('secret', 'secret'), isTrue);
      expect(constantTimeEquals('secret', 'secreT'), isFalse);
      expect(constantTimeEquals('secret', 'secret!'), isFalse);
      expect(constantTimeEquals('', ''), isTrue);
      expect(constantTimeEquals('ção', 'ção'), isTrue);
    });
  });

  group('FramedConnection error paths', () {
    late ServerSocket server;
    late Socket writer;
    late FramedConnection conn;

    setUp(() async {
      server = await ServerSocket.bind('localhost', 0);
      final acceptedF = server.first;
      writer = await Socket.connect('localhost', server.port);
      conn = FramedConnection(await acceptedF);
    });

    tearDown(() async {
      conn.close();
      writer.destroy();
      await server.close();
    });

    test('only one readFrame may be pending', () {
      final first = conn.readFrame();
      expect(conn.readFrame, throwsStateError);
      // Let the pending read fail when the connection closes.
      first.ignore();
    });

    test('readFrame fails when the peer closes before a full frame', () async {
      final read = conn.readFrame();
      writer.add(encodeFrame(Frame.pingFrame).sublist(0, 3));
      await writer.flush();
      await writer.close();
      await expectLater(read, throwsStateError);
      // A closed connection keeps failing fast.
      await expectLater(conn.readFrame(), throwsStateError);
    });

    test('onClosed fires once when the peer closes', () async {
      var closedCount = 0;
      conn.onClosed = () => closedCount++;
      await writer.close();
      expect(await waitFor(() => conn.isClosed), isTrue);
      expect(closedCount, 1);
    });

    test('readFrame fails on bad magic', () async {
      final read = conn.readFrame();
      writer.add([1, 2, 3, 4, 5, 6, 7]);
      await writer.flush();
      await expectLater(read, throwsFormatException);
    });

    test('readFrame is rejected after adoption', () async {
      writer.add(encodeFrame(Frame.readyFrame));
      await writer.flush();
      expect((await conn.readFrame()).type, FrameType.ready);
      expect(conn.isAdopted, isFalse);
      conn.markAdopted();
      expect(conn.isAdopted, isTrue);
      expect(conn.readFrame, throwsStateError);
      expect(conn.takeLeftover(), isEmpty);
      // An adopted connection is owned by its adopter: close() is a no-op.
      conn.close();
      conn.socket.destroy();
    });
  });
}
