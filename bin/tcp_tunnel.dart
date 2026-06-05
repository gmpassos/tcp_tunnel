import 'dart:io';

import 'package:logging/logging.dart' as logging;
import 'package:tcp_tunnel/tcp_tunnel.dart';

void main(List<String> args) {
  args = args.toList();

  if (args.isEmpty) {
    print('USAGE:\n');
    print('  \$> tcp_tunnel local %listenPort %targetPort %targetHost verbose');
    print(
      '  \$> tcp_tunnel client %remoteHost %remotePort %localTargetPort loop --max-tunnels 4',
    );
    print('  \$> tcp_tunnel bridge %listenPort1 %listenPort2\n');
    print('  Hub mode:');
    print(
      '  \$> tcp_tunnel hub --control-port 7000 --map mysql=13306 --map redis=16379',
    );
    print(
      '  \$> tcp_tunnel publish --hub %host:%port --service mysql --target 127.0.0.1:3306 --pool 4',
    );
    print(
      '  \$> tcp_tunnel connect --hub %host:%port --service mysql --listen 3306\n',
    );
    exit(0);
  }

  var mode = args.removeAt(0).trim().toLowerCase();

  var loop = _withFlag(args, 'loop');
  var verbose = _withFlag(args, 'verbose');

  _configureLogging(level: verbose ? logging.Level.ALL : logging.Level.INFO);

  _setupGracefulShutdown();

  Tunnel.runGuarded(() {
    _run(mode, args, loop, verbose);
  });
}

/// Actions to run on shutdown (close active servers/tunnels).
final _shutdownActions = <void Function()>[];

void _setupGracefulShutdown() {
  void shutdown(ProcessSignal signal) {
    print('\n-- Received $signal, shutting down...');
    for (var action in _shutdownActions) {
      try {
        action();
      } catch (_) {}
    }
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  // SIGTERM is not supported on Windows.
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen(shutdown);
  }
}

bool _withFlag(List<String> args, String flag) {
  var idx = args.indexWhere((a) {
    a = a.trim().toLowerCase();
    return a == flag || a == '-$flag' || a == '--$flag';
  });

  if (idx >= 0) {
    args.removeAt(idx);
    return true;
  }
  return false;
}

void _configureLogging({logging.Level level = logging.Level.INFO}) {
  logging.Logger.root.level = level;

  logging.Logger.root.onRecord.listen((record) {
    final time = record.time.toIso8601String();
    final error = record.error != null ? ' | ERROR: ${record.error}' : '';
    final stack = record.stackTrace != null ? '\n${record.stackTrace}' : '';

    print(
      '$time [${record.level.name}] ${record.loggerName}: '
      '${record.message}$error$stack',
    );
  });
}

void _run(String mode, List<String> args, bool loop, bool verbose) {
  print('-- Mode: $mode');

  if (mode == 'local') {
    var listenPort = int.parse(args[0]);
    var targetPort = int.parse(args[1]);
    var targetHost = args.length > 2 ? args[2] : 'localhost';

    print('-- Listen port: $listenPort');
    print('-- Target port: $targetPort');
    print('-- Target host: $targetHost');
    print('-- Verbose: $verbose');

    var localServer = TunnelLocalServer(
      listenPort,
      targetPort,
      targetHost: targetHost,
      verbose: verbose,
    );
    _shutdownActions.add(localServer.close);
    localServer.start();
  } else if (mode == 'client') {
    var remoteHost = args[0];
    var remotePort = int.parse(args[1]);
    var localTargetPort = int.parse(args[2]);

    // optional 4th arg
    var maxTunnels = _parseMaxTunnels(args);
    var parallels = _parseParallels(args, maxTunnels);

    print('-- Loop: $loop');
    print('-- Remote: $remoteHost:$remotePort');
    print('-- Local target port: $localTargetPort');
    print('-- Max tunnels: $maxTunnels');
    print('-- Parallel connections: $parallels');
    print('-- Verbose: $verbose');

    _shutdownActions.add(() {
      for (var tunnel in _tunnels.toList()) {
        tunnel.close();
      }
    });

    for (var i = 0; i < parallels; ++i) {
      _runModeClient(
        remoteHost,
        remotePort,
        localTargetPort,
        loop,
        maxTunnels,
        verbose,
      );
    }
  } else if (mode == 'bridge') {
    var listenPort1 = int.parse(args[0]);
    var listenPort2 = int.parse(args[1]);

    print('-- Listen port 1: $listenPort1');
    print('-- Listen port 2: $listenPort2');
    print('-- Verbose: $verbose');

    var bridge = TunnelBridge(listenPort1, listenPort2, verbose: verbose);
    _shutdownActions.add(bridge.close);
    bridge.start();
  } else if (mode == 'hub') {
    var controlPort = _parseArgInt(args, [
      '--control-port',
      '--controlport',
      '--port',
    ], defaultValue: 7000);
    var servicePorts = _parseMaps(args);

    print('-- Control port: $controlPort');
    print('-- Service ports: $servicePorts');
    print('-- Verbose: $verbose');

    var hub = TunnelHub(
      controlPort,
      servicePorts: servicePorts,
      verbose: verbose,
    );
    _shutdownActions.add(hub.close);
    hub.start();
  } else if (mode == 'publish') {
    var hub = _parseHostPort(args, '--hub');
    var service = _parseArgStr(args, ['--service'], required: true)!;
    var target = _parseHostPort(args, '--target');
    var pool = _parseArgInt(args, ['--pool'], defaultValue: 4);
    if (pool < 1) pool = 1;

    print('-- Hub: ${hub.host}:${hub.port}');
    print('-- Service: $service');
    print('-- Target: ${target.host}:${target.port}');
    print('-- Pool: $pool');
    print('-- Verbose: $verbose');

    var agent = TunnelServerAgent(
      hub.host,
      hub.port,
      service,
      target.port,
      targetHost: target.host,
      poolSize: pool,
      verbose: verbose,
    );
    _shutdownActions.add(agent.close);
    agent.start();
  } else if (mode == 'connect') {
    var hub = _parseHostPort(args, '--hub');
    var service = _parseArgStr(args, ['--service'], required: true)!;
    var listenPort = _parseArgInt(args, ['--listen'], defaultValue: -1);
    if (listenPort < 0) {
      throw ArgumentError('Missing --listen <port>');
    }

    print('-- Hub: ${hub.host}:${hub.port}');
    print('-- Service: $service');
    print('-- Listen port: $listenPort');
    print('-- Verbose: $verbose');

    var agent = TunnelClientAgent(
      hub.host,
      hub.port,
      service,
      listenPort,
      verbose: verbose,
    );
    _shutdownActions.add(agent.close);
    agent.start();
  } else {
    print('** Unknown mode: $mode');
    exit(1);
  }
}

/// A parsed `host:port` pair.
class _HostPort {
  final String host;
  final int port;
  _HostPort(this.host, this.port);
}

/// Parses a required `--flag host:port` argument.
_HostPort _parseHostPort(List<String> args, String flag) {
  var value = _parseArgStr(args, [flag], required: true)!;
  var idx = value.lastIndexOf(':');
  if (idx <= 0 || idx == value.length - 1) {
    throw ArgumentError('Invalid $flag value "$value", expected host:port');
  }
  var host = value.substring(0, idx);
  var port = int.tryParse(value.substring(idx + 1));
  if (port == null) {
    throw ArgumentError('Invalid port in $flag value "$value"');
  }
  return _HostPort(host, port);
}

/// Parses repeatable `--map service=port` flags into a map.
Map<String, int> _parseMaps(List<String> args) {
  var map = <String, int>{};
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i].toLowerCase() == '--map') {
      var spec = args[i + 1];
      var eq = spec.indexOf('=');
      if (eq <= 0 || eq == spec.length - 1) {
        throw ArgumentError(
          'Invalid --map value "$spec", expected service=port',
        );
      }
      var service = spec.substring(0, eq);
      var port = int.tryParse(spec.substring(eq + 1));
      if (port == null) {
        throw ArgumentError('Invalid port in --map value "$spec"');
      }
      map[service] = port;
    }
  }
  return map;
}

String? _parseArgStr(
  List<String> args,
  List<String> names, {
  bool required = false,
  String? defaultValue,
}) {
  for (var i = 0; i < args.length; i++) {
    if (names.contains(args[i].toLowerCase())) {
      if (i + 1 >= args.length) {
        throw ArgumentError('Missing value for ${args[i]}');
      }
      return args[i + 1];
    }
  }
  if (required) {
    throw ArgumentError('Missing required argument ${names.first}');
  }
  return defaultValue;
}

int _parseMaxTunnels(List<String> args, {int defaultValue = 4}) {
  var maxTunnels = _parseArgInt(args, [
    '--max-tunnels',
    '--maxtunnels',
  ], defaultValue: defaultValue);
  // Ensure a sane lower bound so downstream `clamp` calls stay valid.
  return maxTunnels < 1 ? 1 : maxTunnels;
}

int _parseParallels(List<String> args, int maxTunnels, {int defaultValue = 2}) {
  return _parseArgInt(args, [
    '--concurrency',
    '--parallel',
    '--parallels',
  ], defaultValue: defaultValue).clamp(1, maxTunnels);
}

int _parseArgInt(
  List<String> args,
  List<String> names, {
  required int defaultValue,
}) {
  for (var i = 0; i < args.length; i++) {
    var a = args[i];
    var aLC = a.toLowerCase();

    if (names.contains(aLC)) {
      if (i + 1 >= args.length) {
        throw ArgumentError('Missing value for $a');
      }
      return int.tryParse(args[i + 1]) ?? defaultValue;
    }
  }
  return defaultValue;
}

final _tunnels = <Tunnel>[];

void _runModeClient(
  String remoteHost,
  int remotePort,
  int localTargetPort,
  bool loop,
  int maxTunnels,
  bool verbose,
) {
  void onCloseTunnel(Tunnel t) {
    _tunnels.remove(t);
    _runModeClient(
      remoteHost,
      remotePort,
      localTargetPort,
      loop,
      maxTunnels,
      verbose,
    );
  }

  var tunnel = Tunnel.connectAsync(
    remoteHost,
    remotePort,
    localTargetPort,
    verbose: verbose,
    onClose: loop ? onCloseTunnel : null,
  );

  _tunnels.add(tunnel);

  if (loop) {
    tunnel.onReady.then((_) {
      if (_tunnels.length < maxTunnels) {
        _runModeClient(
          remoteHost,
          remotePort,
          localTargetPort,
          loop,
          maxTunnels,
          verbose,
        );
      }
    });
  }
}
