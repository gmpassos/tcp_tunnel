// Tests for the `tcp_tunnel` CLI entry point (bin/tcp_tunnel.dart), run as a
// real child process. The CLI is compiled to a kernel snapshot once, so each
// invocation starts quickly.
@TestOn('vm')
@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tcp_tunnel/tcp_tunnel.dart';
import 'package:test/test.dart';

/// Upper bound for a CLI invocation that is expected to exit on its own.
const _exitTimeout = Duration(seconds: 30);

late Directory _tmp;
late String _snapshot;

/// The result of a CLI run that exited.
class CliResult {
  final int exitCode;
  final String output;

  CliResult(this.exitCode, this.output);

  @override
  String toString() => 'exit=$exitCode\n$output';
}

/// A long-running CLI process whose combined output is captured line by line.
class CliProcess {
  final Process process;
  final List<String> lines = [];
  final StreamController<String> _lineEvents = StreamController.broadcast();
  late final Future<void> _drained;

  CliProcess._(this.process) {
    Future<void> drain(Stream<List<int>> s) => s
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          lines.add(line);
          _lineEvents.add(line);
        });
    _drained = Future.wait([drain(process.stdout), drain(process.stderr)]);
  }

  static Future<CliProcess> start(List<String> args) async => CliProcess._(
    await Process.start(Platform.resolvedExecutable, [_snapshot, ...args]),
  );

  String get output => lines.join('\n');

  /// Waits for an output line matching [pattern] and returns its match.
  Future<RegExpMatch> waitForLine(
    RegExp pattern, {
    Duration timeout = _exitTimeout,
  }) async {
    for (final line in lines) {
      final m = pattern.firstMatch(line);
      if (m != null) return m;
    }
    return _lineEvents.stream
        .map(pattern.firstMatch)
        .firstWhere((m) => m != null)
        .then((m) => m!)
        .timeout(
          timeout,
          onTimeout: () => throw TimeoutException(
            'No line matching $pattern. Output so far:\n$output',
          ),
        );
  }

  /// Waits for the process to exit (killing it on timeout) and returns its
  /// exit code once all its output was read.
  Future<int> waitExit({Duration timeout = _exitTimeout}) async {
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return process.exitCode;
      },
    );
    await _drained;
    await _lineEvents.close();
    return code;
  }

  /// Makes sure the process is gone (for tear-downs).
  Future<void> kill() async {
    process.kill(ProcessSignal.sigkill);
    await waitExit();
  }
}

/// Runs the CLI with [args] and waits for it to exit.
Future<CliResult> runCli(List<String> args) async {
  final p = await CliProcess.start(args);
  final code = await p.waitExit();
  return CliResult(code, p.output);
}

void main() {
  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('tcp_tunnel_cli_test_');
    _snapshot = '${_tmp.path}${Platform.pathSeparator}tcp_tunnel.dill';
    final r = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      'bin/tcp_tunnel.dart',
      '-o',
      _snapshot,
    ]);
    if (r.exitCode != 0) {
      fail('Failed to compile the CLI:\n${r.stdout}\n${r.stderr}');
    }
  });

  tearDownAll(() => _tmp.delete(recursive: true));

  group('usage', () {
    test('no arguments prints the usage and exits 0', () async {
      final r = await runCli([]);
      expect(r.exitCode, 0, reason: '$r');
      expect(r.output, contains('USAGE:'));
      for (final mode in [
        'local',
        'client',
        'bridge',
        'hub',
        'publish',
        'connect',
      ]) {
        expect(r.output, contains('tcp_tunnel $mode'), reason: mode);
      }
    });

    test('an unknown mode exits 1', () async {
      final r = await runCli(['bogus']);
      expect(r.exitCode, 1, reason: '$r');
      expect(r.output, contains('** Unknown mode: bogus'));
    });

    test('the mode is case-insensitive', () async {
      final r = await runCli(['LOCAL']);
      expect(r.output, contains('-- Mode: local'));
    });
  });

  group('invalid arguments exit 1 with a reason (instead of hanging)', () {
    final cases = <List<String>, String>{
      ['local']: 'Missing argument <listenPort>',
      ['local', '1000']: 'Missing argument <targetPort>',
      ['local', 'abc', '1']: 'Invalid <listenPort> "abc"',
      ['client', 'host', '1']: 'Missing argument <localTargetPort>',
      ['client', 'host', 'x', '1']: 'Invalid <remotePort> "x"',
      ['client', 'host', '1', '2', '--max-tunnels', 'x']:
          'Invalid value for --max-tunnels: "x"',
      ['client', 'host', '1', '2', '--max-tunnels']:
          'Missing value for --max-tunnels',
      ['bridge', '1']: 'Missing argument <listenPort2>',
      ['hub', '--control-port']: 'Missing value for --control-port',
      ['hub', '--control-port', 'x']: 'Invalid value for --control-port: "x"',
      ['hub', '--map', 'mysql']: 'Invalid --map value "mysql"',
      ['hub', '--map', 'mysql=abc']: 'Invalid port in --map value "mysql=abc"',
      ['hub', '--port-range', '9-1']: 'Invalid --port-range "9-1"',
      ['hub', '--port-range', '70000']: 'Invalid --port-range "70000"',
      ['hub', '--tls-cert', 'cert.pem']:
          'Hub TLS requires both --tls-cert and --tls-key',
      ['publish']: 'Missing required argument --hub',
      ['publish', '--hub', 'nohost']: 'Invalid --hub value "nohost"',
      ['publish', '--hub', 'h:x']: 'Invalid port in --hub value "h:x"',
      ['publish', '--hub', 'h:1']: 'Missing required argument --service',
      ['publish', '--hub', 'h:1', '--service', 's']:
          'Missing required argument --target',
      [
        'publish',
        '--hub',
        'h:1',
        '--service',
        's',
        '--target',
        'h:2',
        '--public-port',
        '70000',
      ]: 'Invalid --public-port "70000"',
      ['connect', '--hub', 'h:1', '--service', 's']: 'Missing --listen <port>',
    };

    cases.forEach((args, message) {
      test(args.join(' '), () async {
        final r = await runCli(args);
        expect(r.exitCode, 1, reason: '$r');
        expect(r.output, contains('** Error: $message'), reason: '$r');
      });
    });

    test('an empty --token-file is rejected', () async {
      final file = File('${_tmp.path}${Platform.pathSeparator}empty.token');
      await file.writeAsString('\n');
      final r = await runCli(['hub', '--token-file', file.path]);
      expect(r.exitCode, 1, reason: '$r');
      expect(r.output, contains('is empty'));
    });

    test('a missing --token-file is rejected', () async {
      final path = '${_tmp.path}${Platform.pathSeparator}missing.token';
      final r = await runCli(['hub', '--token-file', path]);
      expect(r.exitCode, 1, reason: '$r');
      expect(r.output, contains('** Error:'));
      expect(r.output, contains('missing.token'));
    });
  });

  group('start failures exit 1', () {
    late ServerSocket blocker;

    setUp(() async => blocker = await ServerSocket.bind('0.0.0.0', 0));
    tearDown(() => blocker.close());

    test('local: listen port already in use', () async {
      final r = await runCli(['local', '${blocker.port}', '1']);
      expect(r.exitCode, 1, reason: '$r');
      expect(r.output, contains('** Failed to start local server'));
    });

    test('bridge: listen port already in use', () async {
      final r = await runCli(['bridge', '0', '${blocker.port}']);
      expect(r.exitCode, 1, reason: '$r');
      expect(r.output, contains('** Failed to start bridge'));
    });

    test('hub: control port already in use', () async {
      final r = await runCli(['hub', '--control-port', '${blocker.port}']);
      expect(r.exitCode, 1, reason: '$r');
      expect(r.output, contains('** Failed to start hub'));
    });
  });

  group('running modes', () {
    test('local: forwards both directions and stops on SIGTERM', () async {
      final echo = await ServerSocket.bind('localhost', 0);
      addTearDown(echo.close);
      echo.listen((s) => s.listen(s.add, onError: (_) {}, onDone: s.destroy));

      final cli = await CliProcess.start([
        'local',
        '0',
        '${echo.port}',
        'localhost',
      ]);
      addTearDown(cli.kill);

      final m = await cli.waitForLine(RegExp(r'^-- Listening on port: (\d+)'));
      final port = int.parse(m.group(1)!);
      expect(port, greaterThan(0));
      expect(cli.output, contains('-- Target port: ${echo.port}'));

      final client = await Socket.connect('localhost', port);
      final received = StringBuffer();
      final done = utf8.decoder
          .bind(client)
          .forEach(received.write)
          .catchError((_) {});
      client.write('hello-cli');
      await client.flush();
      await _until(() => received.toString() == 'hello-cli');
      await client.close();
      await done.timeout(_exitTimeout);
      client.destroy();

      cli.process.kill(ProcessSignal.sigterm);
      expect(await cli.waitExit(), 0);
      expect(cli.output, contains('shutting down'));
    }, skip: Platform.isWindows ? 'SIGTERM is not supported on Windows' : null);

    test('bridge: reports both ports and pairs connections', () async {
      final cli = await CliProcess.start(['bridge', '0', '0', 'verbose']);
      addTearDown(cli.kill);

      final m = await cli.waitForLine(
        RegExp(r'^-- Listening on ports: (\d+), (\d+)'),
      );
      expect(cli.output, contains('-- Verbose: true'));
      final a = await Socket.connect('localhost', int.parse(m.group(1)!));
      final b = await Socket.connect('localhost', int.parse(m.group(2)!));
      final fromA = StringBuffer();
      utf8.decoder.bind(b).listen(fromA.write, onError: (_) {});
      a.listen((_) {}, onError: (_) {});

      a.write('over-the-bridge');
      await a.flush();
      await _until(() => fromA.toString() == 'over-the-bridge');

      a.destroy();
      b.destroy();
      cli.process.kill(ProcessSignal.sigint);
      expect(await cli.waitExit(), 0);
    });

    test('bridge: SIGINT with an active tunnel closes it and exits promptly '
        '(0)', () async {
      final cli = await CliProcess.start(['bridge', '0', '0']);
      addTearDown(cli.kill);

      final m = await cli.waitForLine(
        RegExp(r'^-- Listening on ports: (\d+), (\d+)'),
      );
      final a = await Socket.connect('localhost', int.parse(m.group(1)!));
      final b = await Socket.connect('localhost', int.parse(m.group(2)!));
      addTearDown(() {
        a.destroy();
        b.destroy();
      });
      final fromA = StringBuffer();
      final bDone = utf8.decoder
          .bind(b)
          .forEach(fromA.write)
          .catchError((_) {});
      final aDone = a.drain<void>().catchError((_) {});

      a.write('live');
      await a.flush();
      await _until(() => fromA.toString() == 'live');

      cli.process.kill(ProcessSignal.sigint);
      expect(await cli.waitExit(timeout: const Duration(seconds: 10)), 0);
      expect(cli.output, contains('shutting down'));
      await aDone.timeout(_exitTimeout);
      await bDone.timeout(_exitTimeout);
    });

    test(
      'hub: serves a library-published service on its public port',
      () async {
        final echo = await ServerSocket.bind('localhost', 0);
        addTearDown(echo.close);
        echo.listen((s) => s.listen(s.add, onError: (_) {}, onDone: s.destroy));

        final cli = await CliProcess.start([
          'hub',
          '--control-port',
          '0',
          '--map',
          'svc=.',
          '--token',
          'cli-secret',
        ]);
        addTearDown(cli.kill);

        final control = await cli.waitForLine(
          RegExp(r'^-- Listening on control port: (\d+)'),
        );
        final public = await cli.waitForLine(RegExp(r'^\s+svc -> (\d+)'));
        expect(cli.output, contains('-- Auth: token set'));

        final publisher = TunnelServerAgent(
          'localhost',
          int.parse(control.group(1)!),
          'svc',
          echo.port,
          poolSize: 1,
          authToken: 'cli-secret',
        );
        await publisher.start();
        addTearDown(publisher.close);

        final client = await Socket.connect(
          'localhost',
          int.parse(public.group(1)!),
        );
        final received = StringBuffer();
        utf8.decoder.bind(client).listen(received.write, onError: (_) {});
        client.write('via-cli-hub');
        await client.flush();
        await _until(() => received.toString() == 'via-cli-hub');
        client.destroy();

        cli.process.kill(ProcessSignal.sigint);
        expect(await cli.waitExit(), 0);
      },
    );

    test('client loop: opens --parallel connections, grows up to '
        '--max-tunnels as they activate, and replaces a closed one', () async {
      final echo = await ServerSocket.bind('localhost', 0);
      addTearDown(echo.close);
      echo.listen((s) => s.listen(s.add, onError: (_) {}, onDone: s.destroy));

      // Plays the "bridge" side: records every tunnel the CLI dials in.
      final remote = await ServerSocket.bind('localhost', 0);
      addTearDown(remote.close);
      final tunnels = <Socket>[];
      final received = <StringBuffer>[];
      remote.listen((s) {
        final buf = StringBuffer();
        tunnels.add(s);
        received.add(buf);
        utf8.decoder.bind(s).listen(buf.write, onError: (_) {});
      });
      addTearDown(() {
        for (final s in tunnels) {
          s.destroy();
        }
      });

      final cli = await CliProcess.start([
        'client',
        'localhost',
        '${remote.port}',
        '${echo.port}',
        'loop',
        '--max-tunnels',
        '3',
        '--parallel',
        '2',
      ]);
      addTearDown(cli.kill);
      await cli.waitForLine(RegExp(r'^-- Parallel connections: 2'));
      expect(cli.output, contains('-- Max tunnels: 3'));
      expect(cli.output, contains('-- Loop: true'));

      // Activates tunnel [i]: the first remote bytes make the CLI dial the
      // local target, and the echo comes back through the tunnel.
      Future<void> activate(int i) async {
        tunnels[i].write('t$i');
        await tunnels[i].flush();
        await _until(() => received[i].toString() == 't$i');
      }

      await _until(() => tunnels.length == 2);
      await activate(0);
      // An activated tunnel spawns a fresh idle one, up to the maximum.
      await _until(() => tunnels.length == 3);
      await activate(1);
      await activate(2);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(tunnels, hasLength(3), reason: 'must not exceed --max-tunnels');

      // A tunnel that closes is replaced (loop mode reconnects).
      tunnels[0].destroy();
      await _until(() => tunnels.length == 4);
      await activate(3);

      cli.process.kill(ProcessSignal.sigint);
      expect(await cli.waitExit(), 0);
    });

    test('client: --parallel is clamped to --max-tunnels, which is at least '
        '1', () async {
      final remote = await ServerSocket.bind('localhost', 0);
      addTearDown(remote.close);
      final tunnels = <Socket>[];
      remote.listen(tunnels.add);
      addTearDown(() {
        for (final s in tunnels) {
          s.destroy();
        }
      });

      final cli = await CliProcess.start([
        'client',
        'localhost',
        '${remote.port}',
        '1',
        '--max-tunnels',
        '0',
        '--parallel',
        '9',
      ]);
      addTearDown(cli.kill);
      await cli.waitForLine(RegExp(r'^-- Parallel connections: 1'));
      expect(cli.output, contains('-- Max tunnels: 1'));
      expect(cli.output, contains('-- Loop: false'));
      await _until(() => tunnels.length == 1);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(tunnels, hasLength(1));
    });
  });
}

/// Polls [condition] until true, failing after [timeout].
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
