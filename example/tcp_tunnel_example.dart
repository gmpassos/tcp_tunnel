import 'dart:io';

import 'package:tcp_tunnel/tcp_tunnel.dart';

void main() async {
  // Bridge: 8035 <-> 8036
  await bridgePorts(8035, 8036);

  // Client: 8036 <-> 3306
  await clientTunnel('localhost', 8036, 3306);

  // Client: 3307 <-> 8035
  await redirectLocalPort(3307, 8035);

  ///// Final tunnel:
  // 3307 <-> 8035 <-> 8036 <-> 3306
}

Future<void> redirectLocalPort(int listenPort, int targetPort,
    {String targetHost = 'localhost'}) async {
  await TunnelLocalServer(listenPort, targetPort, targetHost: targetHost)
      .start();
}

Future<void> bridgePorts(int listenPort1, int listenPort2) async {
  await TunnelBridge(listenPort1, listenPort2).start();
}

Future<void> clientTunnel(
    String remoteHost, int remotePort, int localTargetPort) async {
  var tunnel = Tunnel.connect(remoteHost, remotePort, localTargetPort);

  tunnel.onClose = (t) {
    print('** Tunnel Closed');
    exit(1);
  };
}
