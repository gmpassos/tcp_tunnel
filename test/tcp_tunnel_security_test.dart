import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tcp_tunnel/tcp_tunnel.dart';
import 'package:test/test.dart';

const _certPath = 'test/certs/cert.pem';
const _keyPath = 'test/certs/key.pem';
const _token = 's3cret-token';

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

/// Echoes back everything it receives; the [publish] target service.
class EchoServer {
  final ServerSocket server;
  int connections = 0;

  EchoServer._(this.server) {
    server.listen((socket) {
      connections++;
      socket.listen(
        socket.add,
        onError: (_) {},
        onDone: () => socket.destroy(),
      );
    });
  }

  static Future<EchoServer> bind() async =>
      EchoServer._(await ServerSocket.bind('localhost', 0));

  int get port => server.port;

  Future<void> close() => server.close();
}

/// Connects to [port], sends bytes, and collects what comes back.
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

/// Hub TLS context: the server certificate (signed by `ca.pem`) + key.
SecurityContext _hubContext() => SecurityContext()
  ..useCertificateChain(_certPath)
  ..usePrivateKey(_keyPath);

/// Agent TLS context. The handshake (and thus the encryption layer) is fully
/// exercised; certificate identity is accepted via [_acceptCert] to keep the
/// test independent of platform CA-trust behaviour. Real deployments pin the
/// hub's CA with `--tls-ca`.
SecurityContext _agentContext() => SecurityContext(withTrustedRoots: false);

bool _acceptCert(X509Certificate _) => true;

void main() {
  group('authentication (token)', () {
    test('valid token over TLS: end-to-end pipe works', () async {
      final echo = await EchoServer.bind();
      final controlPort = await freePort();
      final listenPort = await freePort();

      final hub = TunnelHub(
        controlPort,
        securityContext: _hubContext(),
        authToken: _token,
      );
      await hub.start();

      final publisher = TunnelServerAgent(
        'localhost',
        controlPort,
        'svc',
        echo.port,
        securityContext: _agentContext(),
        onBadCertificate: _acceptCert,
        authToken: _token,
      );
      await publisher.start();

      final consumer = TunnelClientAgent(
        'localhost',
        controlPort,
        'svc',
        listenPort,
        securityContext: _agentContext(),
        onBadCertificate: _acceptCert,
        authToken: _token,
      );
      await consumer.start();

      await _wait(200); // let the pool register

      final client = await TestClient.connect(listenPort);
      client.send('ping');
      await waitFor(() => client.text == 'ping');
      expect(client.text, 'ping');

      await client.close();
      consumer.close();
      publisher.close();
      hub.close();
      await echo.close();
    });

    test(
      'wrong token: publisher is rejected, service never registers',
      () async {
        final echo = await EchoServer.bind();
        final controlPort = await freePort();

        final hub = TunnelHub(
          controlPort,
          securityContext: _hubContext(),
          authToken: _token,
        );
        await hub.start();

        String? rejectReason;
        final publisher = TunnelServerAgent(
          'localhost',
          controlPort,
          'svc',
          echo.port,
          securityContext: _agentContext(),
          onBadCertificate: _acceptCert,
          authToken: 'wrong-token',
        );
        publisher.onPublicPortRejected = (reason) => rejectReason = reason;
        await publisher.start();

        final rejected = await waitFor(() => rejectReason != null);
        expect(rejected, isTrue);
        expect(rejectReason, contains('authentication failed'));

        publisher.close();
        hub.close();
        await echo.close();
      },
    );

    test('token without TLS still authenticates', () async {
      final echo = await EchoServer.bind();
      final controlPort = await freePort();
      final listenPort = await freePort();

      final hub = TunnelHub(controlPort, authToken: _token);
      await hub.start();

      final publisher = TunnelServerAgent(
        'localhost',
        controlPort,
        'svc',
        echo.port,
        authToken: _token,
      );
      await publisher.start();

      final consumer = TunnelClientAgent(
        'localhost',
        controlPort,
        'svc',
        listenPort,
        authToken: _token,
      );
      await consumer.start();

      await _wait(200);

      final client = await TestClient.connect(listenPort);
      client.send('hello');
      await waitFor(() => client.text == 'hello');
      expect(client.text, 'hello');

      await client.close();
      consumer.close();
      publisher.close();
      hub.close();
      await echo.close();
    });
  });

  group('transport encryption (TLS)', () {
    test('plaintext publisher against a TLS hub never registers', () async {
      final echo = await EchoServer.bind();
      final controlPort = await freePort();
      final listenPort = await freePort();

      final hub = TunnelHub(
        controlPort,
        securityContext: _hubContext(),
        clientWaitTimeout: const Duration(seconds: 2),
      );
      await hub.start();

      // Publisher dials plaintext: the hub's TLS handshake fails and the
      // connection is dropped, so the service is never registered.
      final publisher = TunnelServerAgent(
        'localhost',
        controlPort,
        'svc',
        echo.port,
      );
      await publisher.start();

      final consumer = TunnelClientAgent(
        'localhost',
        controlPort,
        'svc',
        listenPort,
        securityContext: _agentContext(),
        onBadCertificate: _acceptCert,
      );
      await consumer.start();

      await _wait(300);

      final client = await TestClient.connect(listenPort);
      client.send('nope');
      await _wait(800);
      expect(client.text, isEmpty, reason: 'no tunnel should form');

      await client.close();
      consumer.close();
      publisher.close();
      hub.close();
      await echo.close();
    });
  });
}
