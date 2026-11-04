// Integration and edge-case tests: protocol framing (split/coalesced reads,
// maximum sizes, malformed headers), injected socket errors, large payload
// integrity through the hub, many concurrent tunnels, half-close, abrupt peer
// disconnects, multiple agents per hub, pool exhaustion, keepalive/reaping and
// server agent reconnection.
//
// Everything runs on loopback with port 0 listeners and bounded waits; no test
// asserts on how long something took.
@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tcp_tunnel/tcp_tunnel.dart';
import 'package:test/test.dart';

/// Upper bound for any single wait in these tests.
const _timeout = Duration(seconds: 20);

/// Polls [condition] until true, failing the test after [timeout].
Future<void> until(
  bool Function() condition, {
  Duration timeout = _timeout,
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'Condition not met within $timeout${reason != null ? ': $reason' : ''}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Lets in-flight socket events settle for [ms] milliseconds. Only used to give
/// something the chance to happen before asserting that it did NOT happen.
Future<void> settle([int ms = 300]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// A port that was free a moment ago (bound to `0`, then released).
Future<int> releasedPort() async {
  final s = await ServerSocket.bind('0.0.0.0', 0);
  final port = s.port;
  await s.close();
  return port;
}

/// Deterministic pseudo-random bytes (an LCG seeded by [seed]).
Uint8List pattern(int size, int seed) {
  final out = Uint8List(size);
  var x = (seed * 2654435761 + 1) & 0x7FFFFFFF;
  for (var i = 0; i < size; i++) {
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF;
    out[i] = x >> 16;
  }
  return out;
}

/// FNV-1a (32-bit) checksum.
int checksum(List<int> bytes) {
  var h = 0x811C9DC5;
  for (final b in bytes) {
    h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// Asserts [actual] is byte-identical to [expected], reporting the first
/// mismatching offset instead of dumping megabytes.
void expectSameBytes(List<int> actual, List<int> expected) {
  expect(actual.length, expected.length, reason: 'length');
  for (var i = 0; i < expected.length; i++) {
    if (actual[i] != expected[i]) {
      fail('First mismatch at byte $i: ${actual[i]} != ${expected[i]}');
    }
  }
  expect(checksum(actual), checksum(expected), reason: 'checksum');
}

/// A write racing the peer's reset (e.g. an echo or a frame sent while the
/// other side tears down) fails the socket's `done` future; unobserved, that is
/// an uncaught error in the test zone. Reads still report errors via `onError`
/// and an awaited `flush()` still throws, so nothing a test checks is hidden.
void ignoreWriteErrors(Socket socket) => socket.done.ignore();

/// One end of a TCP connection that records what it receives and when the
/// other end closes it. With [echo] it also writes every chunk back.
class Peer {
  final Socket socket;
  final bool echo;
  final BytesBuilder _rx = BytesBuilder();
  final Completer<void> _done = Completer<void>();

  Peer(this.socket, {this.echo = false}) {
    ignoreWriteErrors(socket);
    socket.listen(
      (data) {
        _rx.add(data);
        if (echo) socket.add(data);
      },
      onError: (_) => _finish(),
      onDone: _finish,
    );
  }

  void _finish() {
    if (!_done.isCompleted) _done.complete();
  }

  static Future<Peer> connect(int port) async =>
      Peer(await Socket.connect('localhost', port));

  int get length => _rx.length;

  Uint8List get bytes => _rx.toBytes();

  String get text => utf8.decode(bytes, allowMalformed: true);

  Future<void> get done => _done.future.timeout(_timeout);

  bool get isDone => _done.isCompleted;

  Future<void> send(List<int> data) async {
    socket.add(data);
    await socket.flush();
  }

  Future<void> sendText(String s) => send(utf8.encode(s));

  void destroy() => socket.destroy();
}

/// A local target service recording each accepted connection as a [Peer].
class Target {
  final ServerSocket server;
  final bool echo;
  final List<int>? greeting;
  final List<Peer> peers = [];

  Target._(this.server, this.echo, this.greeting) {
    server.listen((s) {
      final g = greeting;
      if (g != null) s.add(g);
      peers.add(Peer(s, echo: echo));
    });
  }

  static Future<Target> bind({bool echo = false, List<int>? greeting}) async =>
      Target._(await ServerSocket.bind('localhost', 0), echo, greeting);

  int get port => server.port;

  Future<void> close() async {
    for (final p in peers) {
      p.destroy();
    }
    await server.close();
  }
}

/// A hand-driven agent connection speaking the control protocol directly, so
/// tests can control exactly which frames (or bytes) reach the hub and when.
class RawConn {
  final Socket socket;
  final FramedConnection conn;

  RawConn(this.socket) : conn = FramedConnection(socket) {
    ignoreWriteErrors(socket);
  }

  static Future<RawConn> connect(int port) async =>
      RawConn(await Socket.connect('localhost', port));

  void send(Frame frame) => conn.writeFrame(frame);

  Future<Frame> read() => conn.readFrame().timeout(_timeout);

  /// Completes the activation handshake (expects ACTIVATE, replies READY) and
  /// echoes the raw-piped bytes back. Returns the activation's `peer`.
  Future<String?> serveEcho() async {
    final activate = await read();
    expect(activate.type, FrameType.activate);
    send(Frame.readyFrame);
    final raw = SocketAsync.adopt(conn);
    raw.listen((data) {
      raw.add(data);
      return raw.flush();
    });
    return activate.peer;
  }

  void destroy() {
    conn.close();
    socket.destroy();
  }
}

/// A [Socket] whose inbound stream is driven by the test, to inject exact read
/// boundaries and socket errors that a real loopback socket cannot produce on
/// demand.
class FakeSocket extends Stream<Uint8List> implements Socket {
  final StreamController<Uint8List> input = StreamController<Uint8List>();
  final List<List<int>> written = [];
  bool throwOnAdd = false;
  bool closed = false;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => input.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  void feed(List<int> bytes) => input.add(Uint8List.fromList(bytes));

  @override
  void add(List<int> data) {
    if (throwOnAdd) throw StateError('StreamSink is closed');
    written.add(data);
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async => closed = true;

  @override
  void destroy() => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<int> frameBytes(int type, List<int> payload) => [
  ...kFrameMagic,
  type,
  (payload.length >> 8) & 0xFF,
  payload.length & 0xFF,
  ...payload,
];

/// A HELLO payload padded so its JSON encoding is exactly [size] bytes.
Map<String, dynamic> paddedHello(int size) {
  Map<String, dynamic> build(int n) => {
    'role': 'server',
    'service': 'svc',
    'pad': 'x' * n,
  };
  final base = utf8.encode(json.encode(build(0))).length;
  return build(size - base);
}

void main() {
  group('protocol framing edge cases', () {
    test('a payload of exactly 0xFFFF bytes round-trips', () {
      final payload = paddedHello(0xFFFF);
      final bytes = encodeFrame(Frame(FrameType.hello, payload));
      expect(bytes.length, kFrameHeaderSize + 0xFFFF);
      expect(bytes.sublist(5, 7), [0xFF, 0xFF]);

      final decoded = decodeFrame(bytes)!;
      expect(decoded.consumed, bytes.length);
      expect(decoded.frame.service, 'svc');
      expect(decoded.frame.payload['pad'], payload['pad']);

      // One byte more no longer fits the 16-bit length.
      expect(
        () => encodeFrame(Frame(FrameType.hello, paddedHello(0x10000))),
        throwsArgumentError,
      );
    });

    test('every strict prefix of a frame decodes as incomplete', () {
      final bytes = encodeFrame(Frame.hello(role: 'client', service: 'svc'));
      for (var i = 0; i < bytes.length; i++) {
        expect(decodeFrame(bytes.sublist(0, i)), isNull, reason: 'prefix $i');
      }
      expect(decodeFrame(bytes)!.consumed, bytes.length);
    });

    test('a header announcing more bytes than buffered is incomplete', () {
      final bytes = frameBytes(FrameType.hello.code, []);
      bytes[5] = 0x01; // announces 256 payload bytes, none present
      expect(decodeFrame(bytes), isNull);
      expect(decodeFrame([...bytes, ...List.filled(255, 0x20)]), isNull);
    });

    test('magic is only validated once a full header is buffered', () {
      expect(decodeFrame([0, 1, 2, 3, 4, 5]), isNull);
      expect(() => decodeFrame([0, 1, 2, 3, 4, 5, 6]), throwsFormatException);
    });

    test('malformed payloads throw FormatException', () {
      final hello = FrameType.hello.code;
      // Not JSON.
      expect(
        () => decodeFrame(frameBytes(hello, utf8.encode('abc'))),
        throwsFormatException,
      );
      // Not UTF-8.
      expect(
        () => decodeFrame(frameBytes(hello, [0xFF, 0xFE])),
        throwsFormatException,
      );
      // Valid JSON, but not an object.
      for (final notAnObject in ['[1,2]', '42', '"svc"', 'null']) {
        expect(
          () => decodeFrame(frameBytes(hello, utf8.encode(notAnObject))),
          throwsFormatException,
          reason: notAnObject,
        );
      }
    });
  });

  group('FramedConnection over a scripted socket', () {
    late FakeSocket fake;
    late FramedConnection conn;

    setUp(() {
      fake = FakeSocket();
      conn = FramedConnection(fake);
    });

    tearDown(() => conn.close());

    test('a frame split into single-byte reads completes only when whole, and '
        'coalesced frames plus raw bytes are split back apart', () async {
      final hello = encodeFrame(Frame.hello(role: 'client', service: 'svc'));
      final rest = [
        ...encodeFrame(Frame.pingFrame),
        ...encodeFrame(Frame.welcome(publicPort: 1234)),
        ...utf8.encode('raw-tail'),
      ];

      Frame? first;
      final read = conn.readFrame()..then((f) => first = f);
      for (var i = 0; i < hello.length - 1; i++) {
        fake.feed([hello[i]]);
        await pumpEventQueue(times: 2);
        expect(first, isNull, reason: 'completed after ${i + 1} bytes');
      }

      // Last HELLO byte, two whole frames and raw payload in a single read.
      fake.feed([hello.last, ...rest]);
      expect((await read).service, 'svc');
      expect((await conn.readFrame()).type, FrameType.ping);
      expect((await conn.readFrame()).publicPort, 1234);
      expect(utf8.decode(conn.takeLeftover()), 'raw-tail');
      expect(conn.takeLeftover(), isEmpty);
    });

    test('a socket error fails the pending read, notifies onClosed once, and '
        'keeps failing later reads with the same error', () async {
      var closedCount = 0;
      conn.onClosed = () => closedCount++;

      final read = conn.readFrame();
      fake.feed(encodeFrame(Frame.pingFrame).sublist(0, 4));
      fake.input.addError(const SocketException('connection reset'));

      await expectLater(read, throwsA(isA<SocketException>()));
      expect(conn.isClosed, isTrue);
      expect(closedCount, 1);
      await expectLater(conn.readFrame(), throwsA(isA<SocketException>()));
      expect(closedCount, 1);
    });

    test(
      'a socket error with no read pending is reported by the next read',
      () async {
        fake.input.addError(const SocketException('connection reset'));
        await pumpEventQueue();
        expect(conn.isClosed, isTrue);
        await expectLater(conn.readFrame(), throwsA(isA<SocketException>()));
      },
    );

    test('a decode error fails only that read', () async {
      final read = conn.readFrame();
      fake.feed(frameBytes(FrameType.hello.code, utf8.encode('[]')));
      await expectLater(read, throwsFormatException);
      expect(conn.isClosed, isFalse);
    });

    test('writeFrame encodes to the socket and swallows write errors', () {
      conn.writeFrame(Frame.pingFrame);
      expect(fake.written.single, encodeFrame(Frame.pingFrame));

      fake.throwOnAdd = true;
      expect(() => conn.writeFrame(Frame.pongFrame), returnsNormally);
      expect(fake.written, hasLength(1));
    });

    test('close() before adoption destroys the socket', () {
      conn.close();
      expect(fake.closed, isTrue);
    });
  });

  group('SocketAsync', () {
    late Target target;

    setUp(() async => target = await Target.bind(echo: true));
    tearDown(() => target.close());

    test('getters expose the resolved socket and its addresses', () async {
      final client = await Socket.connect('localhost', target.port);
      addTearDown(client.destroy);
      final s = SocketAsync.from(client);
      addTearDown(s.close);

      expect(s.isResolved, isTrue);
      expect(s.socket, same(client));
      expect(s.address, client.address.address);
      expect(s.remoteAddress, client.remoteAddress.address);
      expect(s.port, client.port);
      expect(s.toString(), '${client.remoteAddress.address}@${client.port}');
    });

    test('only one listener may be attached', () async {
      final client = await Socket.connect('localhost', target.port);
      addTearDown(client.destroy);
      final s = SocketAsync.from(client);
      addTearDown(s.close);

      s.listen((_) => null);
      expect(() => s.listen((_) => null), throwsStateError);
    });

    test(
      'data added before the socket resolves is flushed once it does',
      () async {
        final s = SocketAsync.unresolved(
          Socket.connect('localhost', target.port),
        );
        addTearDown(s.close);
        expect(s.isResolved, isFalse);
        expect(s.toString(), 'Socket:?');

        s.add(utf8.encode('early-'));
        s.add(utf8.encode('bytes'));
        expect(await s.flush(), isFalse); // nothing to flush yet

        await until(() => target.peers.isNotEmpty);
        await until(() => target.peers.first.text == 'early-bytes');
        expect(s.isResolved, isTrue);
      },
    );

    test('closed before resolving: the late socket is closed, onClose fires '
        'once', () async {
      final resolver = Completer<Socket>();
      final s = SocketAsync.unresolved(resolver.future);
      var closes = 0;
      s.onClose = (_) => closes++;

      s.close();
      expect(s.isClosed, isTrue);
      expect(closes, 1);

      final lateSocket = await Socket.connect('localhost', target.port);
      addTearDown(lateSocket.destroy);
      resolver.complete(lateSocket);

      await until(() => target.peers.isNotEmpty);
      await target.peers.first.done; // the late socket was closed
      expect(s.isResolved, isTrue);
      expect(closes, 1);
    });

    test('a socket error closes it and notifies onClose', () async {
      final fake = FakeSocket();
      final s = SocketAsync.from(fake);
      final closed = Completer<SocketAsync>();
      s.onClose = closed.complete;

      fake.input.addError(const SocketException('connection reset'));

      expect(await closed.future.timeout(_timeout), same(s));
      expect(s.isClosed, isTrue);
      expect(fake.closed, isTrue);
    });

    test('keeps reading while unconsumed (so EOF is seen), then delivers the '
        'buffered chunks once, in order', () async {
      final fake = FakeSocket();
      final s = SocketAsync.from(fake);
      addTearDown(s.close);

      fake.feed([1, 2]);
      fake.feed([3]);
      await fake.input.close();
      await pumpEventQueue();
      expect(s.isInputDone, isTrue);
      expect(s.isClosed, isFalse, reason: 'closes after a delay');

      final chunks = <List<int>>[];
      s.listen((d) => chunks.add(d));
      expect(chunks, [
        [1, 2, 3],
      ]);
    });

    test('adopting a connection that already ended carries the EOF over, '
        'after replaying its leftover bytes', () async {
      final fake = FakeSocket();
      final conn = FramedConnection(fake);
      fake.feed([
        ...encodeFrame(Frame.hello(role: 'client', service: 'svc')),
        ...utf8.encode('tail'),
      ]);
      await fake.input.close();
      expect((await conn.readFrame()).service, 'svc');
      expect(conn.isClosed, isTrue);

      final s = SocketAsync.adopt(conn);
      addTearDown(s.close);
      expect(s.isInputDone, isTrue);

      final rx = <int>[];
      s.listen((d) => rx.addAll(d));
      expect(utf8.decode(rx), 'tail');
    });

    test('FramedConnection.close() fails a pending read', () async {
      final fake = FakeSocket();
      final conn = FramedConnection(fake);
      final read = conn.readFrame();
      conn.close();
      await expectLater(read, throwsStateError);
      expect(conn.isClosed, isTrue);
      await expectLater(conn.readFrame(), throwsStateError);
    });
  });

  group('Tunnel', () {
    test('runGuarded runs the action and contains its errors', () {
      var ran = false;
      Tunnel.runGuarded(() => ran = true);
      expect(ran, isTrue);
      expect(
        () => Tunnel.runGuarded(() => throw StateError('boom')),
        returnsNormally,
      );
      expect(Tunnel.zoneGuarded, isNot(Zone.current));
    });

    test(
      'verbose withSockets relays both ways and reports the close',
      () async {
        final server = await ServerSocket.bind('localhost', 0);
        addTearDown(server.close);
        final accepted = StreamIterator(server);

        final a = await Peer.connect(server.port);
        expect(await accepted.moveNext(), isTrue);
        final sideA = accepted.current;
        final b = await Peer.connect(server.port);
        expect(await accepted.moveNext(), isTrue);
        final sideB = accepted.current;
        addTearDown(() {
          a.destroy();
          b.destroy();
        });

        final closed = Completer<Tunnel>();
        Tunnel.withSockets(
          sideA,
          sideB,
          verbose: true,
          onClose: closed.complete,
        );

        await b.sendText('from-b');
        await until(() => a.text == 'from-b');
        await a.sendText('from-a');
        await until(() => b.text == 'from-a');

        b.destroy();
        await closed.future.timeout(_timeout);
        await a.done;
      },
    );

    test('half-close: the target sees the request then EOF, and the reply '
        'still reaches the client before the tunnel closes', () async {
      final server = await ServerSocket.bind('localhost', 0);
      addTearDown(server.close);
      final targetSide = Completer<Peer>();
      server.listen((s) => targetSide.complete(Peer(s)));

      final local = TunnelLocalServer(0, server.port);
      await local.start();
      addTearDown(local.close);

      final client = await Peer.connect(local.boundPort!);
      addTearDown(client.destroy);
      await client.sendText('request');
      await client.socket.close(); // half-close: no more writes from the client

      final target = await targetSide.future.timeout(_timeout);
      addTearDown(target.destroy);
      await until(() => target.text == 'request');
      target.socket.add(utf8.encode('reply'));

      await until(() => client.text == 'reply');
      // The tunnel does not keep half-open connections: both ends get closed.
      await target.done;
      await client.done;
    });
  });

  group('close() of a listener', () {
    /// Expects [port] to refuse connections. `ServerSocket.close()` completes
    /// asynchronously, so a connect issued right after `close()` may still be
    /// accepted (and then dropped by the closed listener): retry until refused.
    Future<void> expectRefused(int port) async {
      final deadline = DateTime.now().add(_timeout);
      while (true) {
        final Socket socket;
        try {
          socket = await Socket.connect('localhost', port);
        } on SocketException {
          return;
        }
        socket.destroy();
        if (DateTime.now().isAfter(deadline)) {
          fail('Port $port still accepts connections after close()');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    /// An echo tunnel through a [TunnelLocalServer], proven live.
    Future<(TunnelLocalServer, Peer, Target)> localTunnel() async {
      final echo = await Target.bind(echo: true);
      addTearDown(echo.close);
      final local = TunnelLocalServer(0, echo.port);
      await local.start();
      addTearDown(local.close);

      final client = await Peer.connect(local.boundPort!);
      addTearDown(client.destroy);
      await client.sendText('before ');
      await until(() => client.text == 'before ');
      return (local, client, echo);
    }

    /// A tunnel through a [TunnelBridge], proven live in one direction.
    Future<(TunnelBridge, Peer, Peer)> bridgeTunnel() async {
      final bridge = TunnelBridge(0, 0, verbose: true);
      await bridge.start();
      addTearDown(bridge.close);

      final a = await Peer.connect(bridge.boundPort1!);
      final b = await Peer.connect(bridge.boundPort2!);
      addTearDown(() {
        a.destroy();
        b.destroy();
      });
      await a.sendText('ping');
      await until(() => b.text == 'ping');
      return (bridge, a, b);
    }

    /// An echo tunnel through a [TunnelHub] public port, served by a
    /// [TunnelServerAgent], proven live.
    Future<(TunnelHub, Peer, Target, TunnelServerAgent)> hubTunnel() async {
      final echo = await Target.bind(echo: true);
      addTearDown(echo.close);
      final hub = TunnelHub(0, servicePorts: {'svc': 0});
      await hub.start();
      addTearDown(hub.close);

      final agent = TunnelServerAgent(
        'localhost',
        hub.boundControlPort!,
        'svc',
        echo.port,
        poolSize: 1,
      );
      await agent.start();
      addTearDown(agent.close);
      await until(() => agent.publicPort != null);

      final client = await Peer.connect(hub.boundPorts['svc']!);
      addTearDown(client.destroy);
      await client.sendText('before ');
      await until(() => client.text == 'before ');
      return (hub, client, echo, agent);
    }

    /// A tunnel through a [TunnelClientAgent] to a stand-in hub (a plain
    /// listener recording each agent connection), proven live: the stand-in
    /// sees the agent's HELLO followed by the application's bytes.
    Future<(TunnelClientAgent, Peer, Target)> clientAgentTunnel() async {
      final fakeHub = await Target.bind();
      addTearDown(fakeHub.close);
      final agent = TunnelClientAgent('localhost', fakeHub.port, 'svc', 0);
      await agent.start();
      addTearDown(agent.close);

      final app = await Peer.connect(agent.boundListenPort!);
      addTearDown(app.destroy);
      await app.sendText('before');
      await until(
        () =>
            fakeHub.peers.length == 1 &&
            fakeHub.peers.single.text.endsWith('before'),
      );
      return (agent, app, fakeHub);
    }

    test(
      'TunnelLocalServer closes the listener and its active tunnels',
      () async {
        final (local, client, echo) = await localTunnel();
        final port = local.boundPort!;

        local.close();
        await expectRefused(port);
        await client.done;
        await echo.peers.single.done;
      },
    );

    test('TunnelLocalServer close(closeActiveTunnels: false) keeps them '
        'until a later close()', () async {
      final (local, client, echo) = await localTunnel();
      final port = local.boundPort!;

      local.close(closeActiveTunnels: false);
      await expectRefused(port);

      await client.sendText('after');
      await until(() => client.text == 'before after');
      expect(client.isDone, isFalse);

      local.close();
      await client.done;
      await echo.peers.single.done;
    });

    test('TunnelBridge closes the listeners and its active tunnels', () async {
      final (bridge, a, b) = await bridgeTunnel();
      final port1 = bridge.boundPort1!;
      final port2 = bridge.boundPort2!;

      bridge.close();
      await expectRefused(port1);
      await expectRefused(port2);
      await a.done;
      await b.done;
    });

    test('TunnelBridge close(closeActiveTunnels: false) keeps them until a '
        'later close()', () async {
      final (bridge, a, b) = await bridgeTunnel();
      final port1 = bridge.boundPort1!;

      bridge.close(closeActiveTunnels: false);
      await expectRefused(port1);

      await b.sendText('pong');
      await until(() => a.text == 'pong');
      expect(a.isDone || b.isDone, isFalse);

      bridge.close();
      await a.done;
      await b.done;
    });

    test('TunnelHub closes the listeners, parked agent connections, waiting '
        'clients and active tunnels', () async {
      final (hub, client, echo, _) = await hubTunnel();
      final controlPort = hub.boundControlPort!;
      final publicPort = hub.boundPorts['svc']!;

      // A raw parked server conn (no agent to refill it) and a client waiting
      // on a service that has no server.
      final parked = await RawConn.connect(controlPort);
      addTearDown(parked.destroy);
      parked.send(Frame.hello(role: 'server', service: 'other'));
      expect((await parked.read()).type, FrameType.welcome);

      final waiting = await RawConn.connect(controlPort);
      addTearDown(waiting.destroy);
      waiting.send(Frame.hello(role: 'client', service: 'nobody'));

      // A connection that never sends its HELLO.
      final silent = await Peer.connect(controlPort);
      addTearDown(silent.destroy);

      // Give the hub time to accept/register both.
      await settle();

      // The hub sends nothing more to these until it closes them, so a read
      // fails only when the connection is closed (a read timeout would be a
      // TimeoutException instead).
      final closedRead = throwsA(
        anyOf(isA<StateError>(), isA<SocketException>()),
      );
      final parkedClosed = expectLater(parked.read(), closedRead);
      final waitingClosed = expectLater(waiting.read(), closedRead);

      hub.close();
      await expectRefused(controlPort);
      await expectRefused(publicPort);

      await client.done;
      await echo.peers.single.done;
      await parkedClosed;
      await waitingClosed;
      await silent.done;
    });

    test('TunnelHub closes a pairing still waiting for its READY', () async {
      final hub = TunnelHub(0, servicePorts: {'svc': 0});
      await hub.start();
      addTearDown(hub.close);

      final server = await RawConn.connect(hub.boundControlPort!);
      addTearDown(server.destroy);
      server.send(Frame.hello(role: 'server', service: 'svc'));
      expect((await server.read()).type, FrameType.welcome);

      final client = await Peer.connect(hub.boundPorts['svc']!);
      addTearDown(client.destroy);
      // The agent never answers the ACTIVATE with READY.
      expect((await server.read()).type, FrameType.activate);

      final serverClosed = expectLater(
        server.read(),
        throwsA(anyOf(isA<StateError>(), isA<SocketException>())),
      );
      hub.close();
      await client.done;
      await serverClosed;
      expect(client.length, 0);
    });

    test('TunnelHub close(closeActiveTunnels: false) keeps them until a later '
        'close()', () async {
      final (hub, client, echo, _) = await hubTunnel();
      final controlPort = hub.boundControlPort!;

      hub.close(closeActiveTunnels: false);
      await expectRefused(controlPort);

      await client.sendText('after');
      await until(() => client.text == 'before after');
      expect(client.isDone, isFalse);

      hub.close();
      await client.done;
      await echo.peers.single.done;
    });

    test('TunnelClientAgent closes the listener and its active tunnels, '
        'idempotently', () async {
      final (agent, app, fakeHub) = await clientAgentTunnel();
      final port = agent.boundListenPort!;

      agent.close();
      agent.close(); // a second close is a no-op
      await expectRefused(port);
      await app.done;
      await fakeHub.peers.single.done;
      // Nothing new was dialed after close().
      expect(fakeHub.peers, hasLength(1));
    });

    test('TunnelClientAgent close(closeActiveTunnels: false) keeps them '
        'until a later close()', () async {
      final (agent, app, fakeHub) = await clientAgentTunnel();
      final port = agent.boundListenPort!;

      agent.close(closeActiveTunnels: false);
      await expectRefused(port);

      await fakeHub.peers.single.sendText('pong');
      await until(() => app.text == 'pong');
      expect(app.isDone || fakeHub.peers.single.isDone, isFalse);

      agent.close();
      await app.done;
      await fakeHub.peers.single.done;
    });

    test('TunnelClientAgent closes an app connection still dialing the hub, '
        'and drops the hub connection once that connect completes', () async {
      // A stand-in TLS hub that holds the handshake until told to finish it,
      // so the agent's hub connect is pending when close() runs.
      final rawHub = await ServerSocket.bind('localhost', 0);
      addTearDown(rawHub.close);
      final accepted = <Socket>[];
      rawHub.listen(accepted.add);
      addTearDown(() {
        for (final s in accepted) {
          s.destroy();
        }
      });

      final agent = TunnelClientAgent(
        'localhost',
        rawHub.port,
        'svc',
        0,
        securityContext: SecurityContext(withTrustedRoots: false),
        onBadCertificate: (_) => true,
      );
      await agent.start();
      addTearDown(agent.close);

      final app = await Peer.connect(agent.boundListenPort!);
      addTearDown(app.destroy);
      await until(() => accepted.length == 1);

      agent.close();
      await app.done;

      // Finish the handshake: the agent must drop the late hub connection
      // without sending its HELLO. (A reset racing the handshake's last
      // message fails it instead, which also means the agent dropped it.)
      final hubContext = SecurityContext()
        ..useCertificateChain('test/certs/cert.pem')
        ..usePrivateKey('test/certs/key.pem');
      final SecureSocket secure;
      try {
        secure = await SecureSocket.secureServer(
          accepted.single,
          hubContext,
        ).timeout(_timeout);
      } on TimeoutException {
        rethrow;
      } catch (_) {
        return;
      }
      final hubSide = Peer(secure);
      addTearDown(hubSide.destroy);
      await hubSide.done;
      expect(hubSide.length, 0);
    });

    test('TunnelServerAgent closes its activated tunnels', () async {
      final (_, client, echo, agent) = await hubTunnel();

      agent.close();
      agent.close(); // a second close is a no-op
      await client.done;
      await echo.peers.single.done;
    });

    test('TunnelServerAgent close(closeActiveTunnels: false) keeps them until '
        'a later close()', () async {
      final (_, client, echo, agent) = await hubTunnel();

      agent.close(closeActiveTunnels: false);
      await client.sendText('after');
      await until(() => client.text == 'before after');
      expect(client.isDone, isFalse);

      agent.close();
      await client.done;
      await echo.peers.single.done;
    });

    test('close() while start() is still binding releases the ports', () async {
      // Known ports (free a moment ago), so the test can check they are
      // released even though the bound port getters stay `null`.
      final ports = [for (var i = 0; i < 5; i++) await releasedPort()];
      final local = TunnelLocalServer(ports[0], 1);
      final bridge = TunnelBridge(ports[1], ports[2]);
      final hub = TunnelHub(ports[3], servicePorts: {'svc': 0});
      final agent = TunnelClientAgent('localhost', 1, 'svc', ports[4]);

      final starts = [
        local.start(),
        bridge.start(),
        hub.start(),
        agent.start(),
      ];
      local.close();
      bridge.close();
      hub.close();
      agent.close();
      await Future.wait(starts);

      for (final port in ports) {
        await expectRefused(port);
      }
      expect(local.boundPort, isNull);
      expect(bridge.boundPort1, isNull);
      expect(bridge.boundPort2, isNull);
      expect(hub.boundControlPort, isNull);
      expect(agent.boundListenPort, isNull);
      // The hub stopped before binding its public ports.
      expect(hub.boundPorts, isEmpty);
    });
  });

  group('hub control protocol (raw agent connections)', () {
    late TunnelHub hub;
    final raws = <RawConn>[];

    Future<RawConn> raw() async {
      final r = await RawConn.connect(hub.boundControlPort!);
      raws.add(r);
      return r;
    }

    setUp(() async {
      hub = TunnelHub(
        0,
        servicePorts: {'svc': 0},
        clientWaitTimeout: const Duration(seconds: 10),
        parkedIdleTimeout: const Duration(seconds: 30),
      );
      await hub.start();
    });

    tearDown(() {
      for (final r in raws) {
        r.destroy();
      }
      raws.clear();
      hub.close();
    });

    test('a HELLO written one byte at a time registers, and coalesced PINGs '
        'each get a PONG', () async {
      final agent = await raw();
      final hello = encodeFrame(Frame.hello(role: 'server', service: 'svc'));
      for (final b in hello) {
        agent.socket.add([b]);
        await agent.socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }

      final welcome = await agent.read();
      expect(welcome.type, FrameType.welcome);
      expect(welcome.publicPort, hub.boundPorts['svc']);

      agent.socket.add([
        ...encodeFrame(Frame.pingFrame),
        ...encodeFrame(Frame.pingFrame),
        ...encodeFrame(Frame.pingFrame),
      ]);
      for (var i = 0; i < 3; i++) {
        expect((await agent.read()).type, FrameType.pong);
      }
    });

    test('a maximum-size (64 KiB payload) HELLO is accepted', () async {
      final agent = await raw();
      agent.send(Frame(FrameType.hello, paddedHello(0xFFFF)));
      expect((await agent.read()).type, FrameType.welcome);
    });

    test('unexpected frames while parked are ignored', () async {
      final agent = await raw();
      agent.send(Frame.hello(role: 'server', service: 'svc'));
      expect((await agent.read()).type, FrameType.welcome);

      agent.send(Frame.welcome(publicPort: 1));
      agent.send(Frame.hello(role: 'client', service: 'other'));
      agent.send(Frame.pongFrame);
      agent.send(Frame.pingFrame);
      expect((await agent.read()).type, FrameType.pong);

      // Still parked and usable.
      final client = await Peer.connect(hub.boundPorts['svc']!);
      addTearDown(client.destroy);
      final peer = await agent.serveEcho();
      expect(peer, endsWith(':${client.socket.port}'));
      await client.sendText('still-parked');
      await until(() => client.text == 'still-parked');
    });

    test(
      'malformed handshakes are dropped and the hub keeps serving',
      () async {
        final malformed = <String, List<int>>{
          'truncated payload': [
            ...frameBytes(FrameType.hello.code, []).sublist(0, 5),
            0x03, 0xE8, // announces 1000 bytes
            ...List.filled(10, 0x20),
          ],
          'payload not JSON': frameBytes(
            FrameType.hello.code,
            utf8.encode('{nope'),
          ),
          'payload not UTF-8': frameBytes(FrameType.hello.code, [0xC3, 0x28]),
          'payload not an object': frameBytes(
            FrameType.hello.code,
            utf8.encode('["svc"]'),
          ),
          'unknown frame type': frameBytes(0x7F, []),
        };

        for (final entry in malformed.entries) {
          final p = await Peer.connect(hub.boundControlPort!);
          addTearDown(p.destroy);
          p.socket.add(entry.value);
          await p.socket.flush();
          // A truncated frame only fails once the peer stops sending.
          if (entry.key == 'truncated payload') await p.socket.close();
          await p.done;
          expect(p.length, 0, reason: entry.key);
        }

        final agent = await raw();
        agent.send(Frame.hello(role: 'server', service: 'svc'));
        expect((await agent.read()).type, FrameType.welcome);
      },
    );

    test('a client HELLO coalesced with payload bytes delivers the payload '
        '(leftover replay)', () async {
      final agent = await raw();
      agent.send(Frame.hello(role: 'server', service: 'svc'));
      expect((await agent.read()).type, FrameType.welcome);

      final client = await Peer.connect(hub.boundControlPort!);
      addTearDown(client.destroy);
      client.socket.add([
        ...encodeFrame(Frame.hello(role: 'client', service: 'svc')),
        ...utf8.encode('coalesced-payload'),
      ]);
      await client.socket.flush();

      await agent.serveEcho();
      await until(() => client.text == 'coalesced-payload');
    });

    test(
      'pool exhaustion: a client beyond the parked connections waits, is '
      'closed after clientWaitTimeout, and paired tunnels are unaffected',
      () async {
        hub.close();
        hub = TunnelHub(
          0,
          servicePorts: {'svc': 0},
          clientWaitTimeout: const Duration(milliseconds: 600),
        );
        await hub.start();

        final agent = await raw(); // a single parked conn that never refills
        agent.send(Frame.hello(role: 'server', service: 'svc'));
        expect((await agent.read()).type, FrameType.welcome);

        final first = await Peer.connect(hub.boundPorts['svc']!);
        addTearDown(first.destroy);
        await agent.serveEcho();
        await first.sendText('one');
        await until(() => first.text == 'one');

        final second = await Peer.connect(hub.boundPorts['svc']!);
        addTearDown(second.destroy);
        await second.sendText('two');
        await second.done;
        expect(second.length, 0);

        await first.sendText('-still-up');
        await until(() => first.text == 'one-still-up');
      },
    );

    test(
      'clients queued before any server registers are paired FIFO',
      () async {
        final clients = <Peer>[];
        for (var i = 0; i < 3; i++) {
          final c = await Peer.connect(hub.boundPorts['svc']!);
          addTearDown(c.destroy);
          clients.add(c);
          await c.sendText('client-$i');
        }
        // Let the hub register all three before any server conn shows up.
        await settle(200);

        for (var i = 0; i < 3; i++) {
          final agent = await raw();
          agent.send(Frame.hello(role: 'server', service: 'svc'));
          expect((await agent.read()).type, FrameType.welcome);
          final peer = await agent.serveEcho();
          expect(
            peer,
            endsWith(':${clients[i].socket.port}'),
            reason: 'conn $i',
          );
          // The bytes it sent while queued are delivered (and echoed back).
          await until(
            () => clients[i].text == 'client-$i',
            reason: 'client $i',
          );
        }
      },
    );

    test('an idle parked conn is reaped after parkedIdleTimeout', () async {
      hub.close();
      hub = TunnelHub(0, parkedIdleTimeout: const Duration(milliseconds: 200));
      await hub.start();

      final agent = await raw();
      agent.send(Frame.hello(role: 'server', service: 'svc'));
      expect((await agent.read()).type, FrameType.welcome);
      // No keepalive: the hub drops the connection.
      await expectLater(agent.read(), throwsStateError);
    });

    test('a READY arriving after parkedIdleTimeout still completes the '
        'activation (a taken conn is not reaped)', () async {
      hub.close();
      hub = TunnelHub(
        0,
        servicePorts: {'svc': 0},
        parkedIdleTimeout: const Duration(milliseconds: 100),
        clientWaitTimeout: const Duration(seconds: 10),
      );
      await hub.start();

      final agent = await raw();
      agent.send(Frame.hello(role: 'server', service: 'svc'));
      expect((await agent.read()).type, FrameType.welcome);

      final client = await Peer.connect(hub.boundPorts['svc']!);
      addTearDown(client.destroy);
      final activate = await agent.read();
      expect(activate.type, FrameType.activate);

      // Several idle timeouts pass while the activation is in progress.
      await settle(500);
      agent.send(Frame.readyFrame);
      final raw2 = SocketAsync.adopt(agent.conn);
      raw2.listen((data) {
        raw2.add(data);
        return raw2.flush();
      });

      await client.sendText('late-ready');
      await until(() => client.text == 'late-ready');
      expect(client.isDone, isFalse);
    });
  });

  group('hub failure paths', () {
    test('an operator-mapped public port already in use leaves the service '
        'in local port mode (start() still succeeds)', () async {
      final blocker = await ServerSocket.bind('0.0.0.0', 0);
      addTearDown(blocker.close);
      final echo = await Target.bind(echo: true);
      addTearDown(echo.close);

      final hub = TunnelHub(0, servicePorts: {'svc': blocker.port});
      await hub.start();
      addTearDown(hub.close);
      expect(hub.boundPorts, isEmpty);

      final raw = await RawConn.connect(hub.boundControlPort!);
      addTearDown(raw.destroy);
      raw.send(Frame.hello(role: 'server', service: 'svc'));
      final welcome = await raw.read();
      expect(welcome.type, FrameType.welcome);
      expect(welcome.publicPort, isNull);
    });

    test('an exhausted dynamicPortRange rejects a dynamic request', () async {
      final blocker = await ServerSocket.bind('0.0.0.0', 0);
      addTearDown(blocker.close);

      final hub = TunnelHub(
        0,
        dynamicPublicPorts: true,
        dynamicPortRange: PortRange(blocker.port, blocker.port),
      );
      await hub.start();
      addTearDown(hub.close);

      final agent = TunnelServerAgent(
        'localhost',
        hub.boundControlPort!,
        'svc',
        1,
        poolSize: 1,
        requestPublicPort: 0,
      );
      final rejected = Completer<String>();
      agent.onPublicPortRejected = rejected.complete;
      await agent.start();
      addTearDown(agent.close);

      expect(
        await rejected.future.timeout(_timeout),
        contains('no free public port in range ${blocker.port}'),
      );
      expect(hub.boundPorts, isEmpty);
    });

    test('an unreachable agent target fails the activation: the client is '
        'closed after clientWaitTimeout', () async {
      final hub = TunnelHub(
        0,
        servicePorts: {'svc': 0},
        clientWaitTimeout: const Duration(milliseconds: 500),
      );
      await hub.start();
      addTearDown(hub.close);

      final agent = TunnelServerAgent(
        'localhost',
        hub.boundControlPort!,
        'svc',
        await releasedPort(),
        poolSize: 1,
      );
      await agent.start();
      addTearDown(agent.close);
      await until(() => agent.publicPort != null);

      final client = await Peer.connect(hub.boundPorts['svc']!);
      addTearDown(client.destroy);
      await client.sendText('anyone?');
      await client.done;
      expect(client.length, 0);
    });

    test(
      'a client agent that cannot reach the hub drops the app connection',
      () async {
        final agent = TunnelClientAgent(
          'localhost',
          await releasedPort(),
          'svc',
          0,
          listenHost: 'localhost',
        );
        await agent.start();
        addTearDown(agent.close);

        final app = await Peer.connect(agent.boundListenPort!);
        addTearDown(app.destroy);
        await app.done;
        expect(app.length, 0);
      },
    );

    /// Connects a client that waits for "svc" (no server yet), optionally sends
    /// [data], then disconnects; then lets the hub observe the EOF for
    /// [settleMs] and starts a publisher.
    Future<Target> clientGoneBeforeServer({
      required bool verbose,
      String? data,
      int settleMs = 1500,
    }) async {
      final echo = await Target.bind(echo: true);
      addTearDown(echo.close);
      final hub = TunnelHub(
        0,
        servicePorts: {'svc': 0},
        dynamicPublicPorts: true,
        verbose: verbose,
      );
      await hub.start();
      addTearDown(hub.close);

      final gone = await Peer.connect(hub.boundPorts['svc']!);
      if (data != null) await gone.sendText(data);
      gone.destroy();
      await settle(settleMs);

      final agent = TunnelServerAgent(
        'localhost',
        hub.boundControlPort!,
        'svc',
        echo.port,
        poolSize: 1,
        verbose: verbose,
      );
      await agent.start();
      addTearDown(agent.close);
      await until(() => agent.publicPort != null);

      final client = await Peer.connect(hub.boundPorts['svc']!);
      addTearDown(client.destroy);
      await client.sendText('served');
      await until(() => client.text == 'served');
      return echo;
    }

    test('verbose hub: a waiting client that disconnects is evicted and is '
        'never paired', () async {
      final echo = await clientGoneBeforeServer(verbose: true);
      await settle();
      // Only the live client ever reached the service.
      expect(echo.peers.map((p) => p.text), ['served']);
    });

    // Regression: the waiting client's socket used to be paused as soon as it
    // sent data, hiding its EOF; it then took the next parked connection and
    // its bytes reached the service after it had disconnected.
    for (final settleMs in [1500, 200]) {
      test(
        'a waiting client that sent data before disconnecting is evicted '
        'and its bytes never reach the service (settle ${settleMs}ms)',
        () async {
          final echo = await clientGoneBeforeServer(
            // Covers the verbose eviction log too.
            verbose: settleMs < 1000,
            data: 'sent-then-gone',
            settleMs: settleMs,
          );
          await settle();
          expect(echo.peers.map((p) => p.text), ['served']);
        },
      );
    }

    test(
      'bytes a live client sends while waiting (beyond the buffering '
      'limit) are delivered intact and in order once a server arrives',
      () async {
        final echo = await Target.bind(echo: true);
        addTearDown(echo.close);
        final hub = TunnelHub(0, servicePorts: {'svc': 0});
        await hub.start();
        addTearDown(hub.close);

        final client = await Peer.connect(hub.boundPorts['svc']!);
        addTearDown(client.destroy);

        // Many small writes, then one large one, all before any server exists:
        // more than [SocketAsync.maxBufferedInput] in total.
        final expected = BytesBuilder();
        for (var i = 0; i < 64; i++) {
          final chunk = pattern(97, i);
          expected.add(chunk);
          await client.send(chunk);
          // Let each write arrive as its own read (several buffered chunks).
          await settle(10);
        }
        final big = pattern(SocketAsync.maxBufferedInput * 4, 999);
        expected.add(big);
        client.socket.add(big); // not awaited: the hub stops reading at the cap
        await settle();

        final agent = TunnelServerAgent(
          'localhost',
          hub.boundControlPort!,
          'svc',
          echo.port,
          poolSize: 1,
        );
        await agent.start();
        addTearDown(agent.close);

        final want = expected.toBytes();
        await until(() => client.length >= want.length);
        expectSameBytes(client.bytes, want);
        expectSameBytes(echo.peers.single.bytes, want);
      },
    );

    test(
      'a client agent whose HELLO is followed by its EOF is not paired',
      () async {
        final echo = await Target.bind(echo: true);
        addTearDown(echo.close);
        final hub = TunnelHub(0);
        await hub.start();
        addTearDown(hub.close);

        // HELLO, a payload and the EOF can all be seen by the hub while the
        // connection is still framed (before the client is adopted).
        final gone = await Socket.connect('localhost', hub.boundControlPort!);
        ignoreWriteErrors(gone);
        gone.add([
          ...encodeFrame(Frame.hello(role: 'client', service: 'svc')),
          ...utf8.encode('stale'),
        ]);
        await gone.close();
        gone.destroy();
        await settle();

        final agent = TunnelServerAgent(
          'localhost',
          hub.boundControlPort!,
          'svc',
          echo.port,
          poolSize: 1,
        );
        await agent.start();
        addTearDown(agent.close);

        final app = await RawConn.connect(hub.boundControlPort!);
        addTearDown(app.destroy);
        app.send(Frame.hello(role: 'client', service: 'svc'));
        final raw = SocketAsync.adopt(app.conn);
        final rx = BytesBuilder();
        raw.listen((d) => rx.add(d));
        raw.add(utf8.encode('served'));
        await until(() => rx.length == 6);
        await settle();
        expect(echo.peers.map((p) => p.text), ['served']);
      },
    );
  });

  group('server agent lifecycle (scripted hub)', () {
    late ServerSocket fakeHub;
    final conns = <FramedConnection>[];

    setUp(() async {
      fakeHub = await ServerSocket.bind('localhost', 0);
      fakeHub.listen((s) {
        ignoreWriteErrors(s);
        conns.add(FramedConnection(s));
      });
    });

    tearDown(() async {
      for (final c in conns) {
        c.close();
      }
      conns.clear();
      await fakeHub.close();
    });

    test('close() right after start() drops the connections being dialed '
        'without sending a HELLO', () async {
      final peers = <Peer>[];
      await fakeHub.close();
      fakeHub = await ServerSocket.bind('localhost', 0);
      fakeHub.listen((s) => peers.add(Peer(s)));

      final agent = TunnelServerAgent(
        'localhost',
        fakeHub.port,
        'svc',
        1,
        poolSize: 2,
      );
      await agent.start();
      agent.close();

      await until(() => peers.length == 2 && peers.every((p) => p.isDone));
      for (final p in peers) {
        expect(p.length, 0);
      }
    });

    test('parked connections send HELLO then keepalive PINGs', () async {
      final agent = TunnelServerAgent(
        'localhost',
        fakeHub.port,
        'svc',
        1,
        poolSize: 1,
        authToken: 'tok',
        pingInterval: const Duration(milliseconds: 50),
      );
      await agent.start();
      addTearDown(agent.close);

      await until(() => conns.length == 1);
      final hello = await conns[0].readFrame().timeout(_timeout);
      expect(hello.type, FrameType.hello);
      expect(hello.role, 'server');
      expect(hello.service, 'svc');
      expect(hello.token, 'tok');
      expect(hello.publicPort, isNull);
      for (var i = 0; i < 2; i++) {
        expect(
          (await conns[0].readFrame().timeout(_timeout)).type,
          FrameType.ping,
        );
      }
    });

    test('reconnects after the hub drops a parked connection, and stops after '
        'close()', () async {
      final agent = TunnelServerAgent(
        'localhost',
        fakeHub.port,
        'svc',
        1,
        poolSize: 1,
        reconnectDelay: const Duration(milliseconds: 50),
      );
      await agent.start();

      await until(() => conns.length == 1);
      expect(
        (await conns[0].readFrame().timeout(_timeout)).type,
        FrameType.hello,
      );
      conns[0].close(); // the hub drops it

      await until(() => conns.length == 2);
      expect(
        (await conns[1].readFrame().timeout(_timeout)).type,
        FrameType.hello,
      );

      agent.close();
      await until(() => conns[1].isClosed);
      await settle();
      expect(conns, hasLength(2));
    });

    test('a REJECT closes the agent once and stops reconnecting', () async {
      final agent = TunnelServerAgent(
        'localhost',
        fakeHub.port,
        'svc',
        1,
        poolSize: 2,
        reconnectDelay: const Duration(milliseconds: 50),
      );
      final reasons = <String>[];
      agent.onPublicPortRejected = reasons.add;
      await agent.start();

      await until(() => conns.length == 2);
      for (final c in conns) {
        expect((await c.readFrame().timeout(_timeout)).type, FrameType.hello);
      }
      // Both parked conns are rejected; the agent closes on the first.
      for (final c in conns) {
        c.writeFrame(Frame.reject('go away'));
      }
      await until(() => conns.every((c) => c.isClosed));
      await settle();
      expect(reasons, ['go away']);
      expect(conns, hasLength(2));
    });
  });

  test('server agent keeps retrying an unreachable hub and registers once it '
      'is up', () async {
    final echo = await Target.bind(echo: true);
    addTearDown(echo.close);
    final hubPort = await releasedPort();

    final agent = TunnelServerAgent(
      'localhost',
      hubPort,
      'svc',
      echo.port,
      poolSize: 1,
      reconnectDelay: const Duration(milliseconds: 50),
      verbose: true,
    );
    await agent.start();
    addTearDown(agent.close);
    await settle(); // several failed attempts

    final hub = TunnelHub(hubPort);
    await hub.start();
    addTearDown(hub.close);

    final consumer = TunnelClientAgent(
      'localhost',
      hubPort,
      'svc',
      0,
      listenHost: 'localhost',
    );
    await consumer.start();
    addTearDown(consumer.close);

    final app = await Peer.connect(consumer.boundListenPort!);
    addTearDown(app.destroy);
    await app.sendText('hub-is-back');
    await until(() => app.text == 'hub-is-back');
  });

  group('data through the hub', () {
    late Target echo;
    late TunnelHub hub;
    late TunnelServerAgent publisher;

    setUp(() async {
      echo = await Target.bind(echo: true);
      hub = TunnelHub(
        0,
        servicePorts: {'svc': 0},
        clientWaitTimeout: const Duration(seconds: 30),
      );
      await hub.start();
      publisher = TunnelServerAgent(
        'localhost',
        hub.boundControlPort!,
        'svc',
        echo.port,
        poolSize: 4,
      );
      await publisher.start();
      await until(() => publisher.publicPort != null);
    });

    tearDown(() async {
      publisher.close();
      hub.close();
      await echo.close();
    });

    test('4 MiB echoed through the public port arrives intact', () async {
      final data = pattern(4 << 20, 1);
      final client = await Peer.connect(hub.boundPorts['svc']!);
      addTearDown(client.destroy);

      await client.send(data);
      await until(
        () => client.length >= data.length,
        timeout: const Duration(seconds: 60),
      );
      expectSameBytes(client.bytes, data);
    });

    test('4 MiB in each direction at once through a client agent arrive '
        'intact', () async {
      final up = pattern(4 << 20, 2);
      final down = pattern(4 << 20, 3);

      final target = await Target.bind(greeting: down);
      addTearDown(target.close);
      final publisher2 = TunnelServerAgent(
        'localhost',
        hub.boundControlPort!,
        'bulk',
        target.port,
        poolSize: 1,
      );
      await publisher2.start();
      addTearDown(publisher2.close);

      final consumer = TunnelClientAgent(
        'localhost',
        hub.boundControlPort!,
        'bulk',
        0,
        listenHost: 'localhost',
      );
      await consumer.start();
      addTearDown(consumer.close);

      final app = await Peer.connect(consumer.boundListenPort!);
      addTearDown(app.destroy);
      await app.send(up);

      const big = Duration(seconds: 60);
      await until(() => app.length >= down.length, timeout: big);
      await until(() => target.peers.isNotEmpty);
      await until(() => target.peers.single.length >= up.length, timeout: big);
      expectSameBytes(app.bytes, down);
      expectSameBytes(target.peers.single.bytes, up);
    });

    test(
      '40 concurrent tunnels through a client agent stay isolated',
      () async {
        final consumer = TunnelClientAgent(
          'localhost',
          hub.boundControlPort!,
          'svc',
          0,
          listenHost: 'localhost',
        );
        await consumer.start();
        addTearDown(consumer.close);

        const n = 40;
        final payloads = [
          for (var i = 0; i < n; i++) pattern(32 * 1024 + i, 100 + i),
        ];
        final apps = await Future.wait([
          for (var i = 0; i < n; i++) Peer.connect(consumer.boundListenPort!),
        ]);
        addTearDown(() {
          for (final a in apps) {
            a.destroy();
          }
        });

        await Future.wait([
          for (var i = 0; i < n; i++) apps[i].send(payloads[i]),
        ]);
        for (var i = 0; i < n; i++) {
          await until(
            () => apps[i].length >= payloads[i].length,
            reason: 'app $i',
          );
          expectSameBytes(apps[i].bytes, payloads[i]);
        }
        expect(echo.peers.length, n);
      },
    );

    test('an abrupt client disconnect mid-transfer closes the target side '
        'and the service keeps working', () async {
      final client = await Peer.connect(hub.boundPorts['svc']!);
      await client.send(pattern(256 * 1024, 4));
      await until(() => client.length > 0);
      client.destroy();

      await until(() => echo.peers.isNotEmpty);
      await echo.peers.first.done;

      final next = await Peer.connect(hub.boundPorts['svc']!);
      addTearDown(next.destroy);
      await next.sendText('next-one');
      await until(() => next.text == 'next-one');
    });

    test(
      'multiple client agents and services are routed independently',
      () async {
        final a = await Target.bind(greeting: utf8.encode('hello-from-A'));
        final b = await Target.bind(greeting: utf8.encode('hello-from-B'));
        addTearDown(a.close);
        addTearDown(b.close);

        final control = hub.boundControlPort!;
        for (final (name, t) in [('A', a), ('B', b)]) {
          final p = TunnelServerAgent(
            'localhost',
            control,
            name,
            t.port,
            poolSize: 2,
          );
          await p.start();
          addTearDown(p.close);
        }

        final consumers = <(String, TunnelClientAgent)>[];
        for (final name in ['A', 'A', 'B']) {
          final c = TunnelClientAgent(
            'localhost',
            control,
            name,
            0,
            listenHost: 'localhost',
          );
          await c.start();
          addTearDown(c.close);
          consumers.add((name, c));
        }

        for (final (name, c) in consumers) {
          for (var i = 0; i < 3; i++) {
            final app = await Peer.connect(c.boundListenPort!);
            addTearDown(app.destroy);
            await until(() => app.length >= 12, reason: '$name #$i');
            expect(app.text, 'hello-from-$name');
          }
        }
        expect(a.peers.length, 6);
        expect(b.peers.length, 3);
      },
    );
  });
}
