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
    exit(0);
  }

  var mode = args.removeAt(0).trim().toLowerCase();

  var loop = _withFlag(args, 'loop');
  var verbose = _withFlag(args, 'verbose');

  _configureLogging(level: verbose ? logging.Level.ALL : logging.Level.INFO);

  Tunnel.runGuarded(() {
    _run(mode, args, loop, verbose);
  });
}

bool _withFlag(List<String> args, String flag) {
  var idx = args.indexWhere((a) {
    a = a.trim().toLowerCase();
    return a == flag || a == '--$flag' || a == '--$flag';
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

    TunnelLocalServer(
      listenPort,
      targetPort,
      targetHost: targetHost,
      verbose: verbose,
    ).start();
  } else if (mode == 'client') {
    var remoteHost = args[0];
    var remotePort = int.parse(args[1]);
    var localTargetPort = int.parse(args[2]);

    // optional 4th arg
    var maxTunnels = _parseMaxTunnels(args);

    print('-- Loop: $loop');
    print('-- Remote: $remoteHost:$remotePort');
    print('-- Local target port: $localTargetPort');
    print('-- Max tunnels: $maxTunnels');
    print('-- Verbose: $verbose');

    _runModeClient(
      remoteHost,
      remotePort,
      localTargetPort,
      loop,
      maxTunnels,
      verbose,
    );
  } else if (mode == 'bridge') {
    var listenPort1 = int.parse(args[0]);
    var listenPort2 = int.parse(args[1]);

    print('-- Listen port 1: $listenPort1');
    print('-- Listen port 2: $listenPort2');
    print('-- Verbose: $verbose');

    TunnelBridge(listenPort1, listenPort2, verbose: verbose).start();
  } else {
    print('** Unknown mode: $mode');
    exit(1);
  }
}

int _parseMaxTunnels(List<String> args, {int defaultValue = 4}) {
  for (var i = 0; i < args.length; i++) {
    var a = args[i];
    var aLC = a.toLowerCase();

    if (aLC == '--max-tunnels' || aLC == '--maxtunnels') {
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
