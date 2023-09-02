import 'dart:io';
import 'dart:typed_data';

import 'package:tcp_tunnel/tcp_tunnel.dart';
import 'package:test/test.dart';

void main() {
  group('TCP Tunnel', () {
    test('redirectLocalPort', () async {
      final serverPort = 5540;

      var server = await ServerSocket.bind('localhost', serverPort);

      final clientsData = <Socket, List<Uint8List>>{};

      server.listen((socket) {
        socket.listen((data) {
          var list = clientsData[socket] ??= [];
          list.add(data);
        });
      });

      final localListenPort = serverPort + 1;

      await redirectLocalPort(localListenPort, serverPort);

      var socket = await Socket.connect("localhost", localListenPort);

      socket.add([1, 2, 3, 4, 5]);
      socket.flush();
      await Future.delayed(Duration(milliseconds: 20));

      socket.add([6, 7, 8, 9, 10]);
      socket.flush();
      await Future.delayed(Duration(milliseconds: 20));

      socket.close();
      await Future.delayed(Duration(milliseconds: 20));

      expect(clientsData.length, equals(1));

      var clientData = clientsData.values.first;
      expect(
          clientData,
          equals([
            [1, 2, 3, 4, 5],
            [6, 7, 8, 9, 10],
          ]));

      server.close();
    });

    test('redirectLocalPort', () async {
      final serverPort = 5550;

      var server = await ServerSocket.bind('localhost', serverPort);

      final clientsData = <Socket, List<Uint8List>>{};

      server.listen((socket) {
        socket.listen((data) {
          var list = clientsData[socket] ??= [];
          list.add(data);
        });
      });

      final bridgeListenPort1 = serverPort + 1;
      final bridgeListenPort2 = serverPort + 2;
      final localListenPort = serverPort + 3;

      await bridgePorts(bridgeListenPort1, bridgeListenPort2);

      await clientTunnel('localhost', bridgeListenPort1, serverPort);

      await redirectLocalPort(localListenPort, bridgeListenPort2);

      var socket = await Socket.connect("localhost", localListenPort);

      socket.add([1, 2, 3, 4, 5]);
      socket.flush();
      await Future.delayed(Duration(milliseconds: 20));

      socket.add([6, 7, 8, 9, 10]);
      socket.flush();
      await Future.delayed(Duration(milliseconds: 20));

      socket.close();
      await Future.delayed(Duration(milliseconds: 20));

      expect(clientsData.length, equals(1));

      var clientData = clientsData.values.first;
      expect(
          clientData,
          equals([
            [1, 2, 3, 4, 5],
            [6, 7, 8, 9, 10],
          ]));

      server.close();
    });
  });
}

Future<TunnelLocalServer> redirectLocalPort(int listenPort, int targetPort,
    {String targetHost = 'localhost'}) async {
  var tunnelLocalServer =
      TunnelLocalServer(listenPort, targetPort, targetHost: targetHost);
  await tunnelLocalServer.start();
  return tunnelLocalServer;
}

Future<TunnelBridge> bridgePorts(int listenPort1, int listenPort2) async {
  var tunnelBridge = TunnelBridge(listenPort1, listenPort2);
  await tunnelBridge.start();
  return tunnelBridge;
}

Future<Tunnel> clientTunnel(
    String remoteHost, int remotePort, int localTargetPort,
    {TunnelCallback? onStart, TunnelCallback? onClose}) async {
  var tunnel =
      Tunnel.connect(remoteHost, remotePort, localTargetPort, onStart: onStart);
  tunnel.onClose = onClose;
  return tunnel;
}
