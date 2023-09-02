import 'dart:io';

import 'package:tcp_tunnel/tcp_tunnel.dart';

void main(List<String> args) {
  args = args.toList();

  if (args.isEmpty) {
    print('USAGE:\n');
    print('  \$> tcp_tunnel local %listenPort %targetPort %targetHost');
    print('  \$> tcp_tunnel client %remoteHost %remotePort %localTargetPort');
    print('  \$> tcp_tunnel bridge %listenPort1 %listenPort2\n');
    exit(0);
  }

  var mode = args.removeAt(0).trim().toLowerCase();

  var loop = false;
  {
    var idx = args.indexWhere((a) => a.trim().toLowerCase() == 'loop');
    if (idx >= 0) {
      args.removeAt(idx);
      loop = true;
    }
  }

  _run(mode, args, loop);
}

void _run(String mode, List<String> args, bool loop) {
  print('-- Mode: $mode');

  if (mode == 'local') {
    var listenPort = int.parse(args[0]);
    var targetPort = int.parse(args[1]);
    var targetHost = args.length > 2 ? args[2] : 'localhost';

    print('-- Listen port: $listenPort');
    print('-- Target port: $targetPort');
    print('-- Target host: $targetHost');

    TunnelLocalServer(listenPort, targetPort, targetHost: targetHost).start();
  } else if (mode == 'client') {
    var remoteHost = args[0];
    var remotePort = int.parse(args[1]);
    var localTargetPort = int.parse(args[2]);

    print('-- Loop: $loop');
    print('-- Remote: $remoteHost:$remotePort');
    print('-- Local target port: $localTargetPort');

    _runModeClient(remoteHost, remotePort, localTargetPort, loop);
  } else if (mode == 'bridge') {
    var listenPort1 = int.parse(args[0]);
    var listenPort2 = int.parse(args[1]);

    print('-- Listen port 1: $listenPort1');
    print('-- Listen port 2: $listenPort2');

    TunnelBridge(listenPort1, listenPort2).start();
  } else {
    print('** Unknown mode: $mode');
    exit(1);
  }
}

void _runModeClient(
    String remoteHost, int remotePort, int localTargetPort, bool loop) {
  var tunnel = Tunnel.connect(remoteHost, remotePort, localTargetPort);

  if (loop) {
    tunnel.onClose = (t) {
      _runModeClient(remoteHost, remotePort, localTargetPort, loop);
    };
  }
}
