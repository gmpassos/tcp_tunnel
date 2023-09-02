# tcp_tunnel

[![pub package](https://img.shields.io/pub/v/tcp_tunnel.svg?logo=dart&logoColor=00b9fc)](https://pub.dartlang.org/packages/tcp_tunnel)
[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![Codecov](https://img.shields.io/codecov/c/github/gmpassos/tcp_tunnel)](https://app.codecov.io/gh/gmpassos/tcp_tunnel)
[![Dart CI](https://github.com/gmpassos/tcp_tunnel/actions/workflows/dart.yml/badge.svg?branch=master)](https://github.com/gmpassos/tcp_tunnel/actions/workflows/dart.yml)
[![GitHub Tag](https://img.shields.io/github/v/tag/gmpassos/tcp_tunnel?logo=git&logoColor=white)](https://github.com/gmpassos/tcp_tunnel/releases)
[![New Commits](https://img.shields.io/github/commits-since/gmpassos/tcp_tunnel/latest?logo=git&logoColor=white)](https://github.com/gmpassos/tcp_tunnel/network)
[![Last Commits](https://img.shields.io/github/last-commit/gmpassos/tcp_tunnel?logo=git&logoColor=white)](https://github.com/gmpassos/tcp_tunnel/commits/master)
[![Pull Requests](https://img.shields.io/github/issues-pr/gmpassos/tcp_tunnel?logo=github&logoColor=white)](https://github.com/gmpassos/tcp_tunnel/pulls)
[![Code size](https://img.shields.io/github/languages/code-size/gmpassos/tcp_tunnel?logo=github&logoColor=white)](https://github.com/gmpassos/tcp_tunnel)
[![License](https://img.shields.io/github/license/gmpassos/tcp_tunnel?logo=open-source-initiative&logoColor=green)](https://github.com/gmpassos/tcp_tunnel/blob/master/LICENSE)

A minimalistic TCP tunnel library, entirely written in Dart,
and equipped with a user-friendly Command Line Interface (CLI)
for seamless usage across diverse platforms.

## Motivation

The primary motivation behind this library is to assist in the development of
servers, clients, and services within intricate network topologies.

During the development process, accessing remote devices or servers can often
be challenging, especially in the initial stages and validation phase.
This difficulty arises when nothing is exposed to a public network,
and there is a need to integrate multiple networks, including cloud resources,
local LAN, and debugging environments.

## Usage

There are three types of tunnels that can be utilized in combination:

- **Local Port Redirect:**

  Links `listenPort` to `localTargetPort` for bidirectional data flow.


- **Bridge Tunneling:**

  Connects `listenPort1` and `listenPort2` for data traffic exchange.


- **Client Tunnel:**

  Links `remoteHost:remotePort` to `localTargetPort` for bidirectional data transfer.


### Local Port Redirect:

To redirect a local port, like 3366 (`listenPort`) to 3306 (`targetPort`):

```dart
Future<void> redirectLocalPort(int listenPort, int targetPort, {String targetHost = 'localhost'}) async {
  await TunnelLocalServer(listenPort, targetPort, targetHost: targetHost).start();
}
```
The `TunnelLocalServer` will listen on `listenPort`, and for each accepted Socket,
it will initiate a connection to the `targetPort` and 
enable bidirectional data traffic redirection between them.

### Bridge Tunneling:

To create a bridhe between 2 ports:

```dart
Future<void> bridgePorts(int listenPort1, int listenPort2) async {
  await TunnelBridge(listenPort1, listenPort2).start();
}
```

The `TunnelBridge` will concurrently listen on `listenPort1` and `listenPort2`.
For each accepted `Socket` on `listenPort1`, it will await for a corresponding
accepted `Socket` on `listenPort2` (and vice versa). Once both `Socket`s are established,
it will enable bidirectional data traffic redirection between them.

### Client Tunnel:

To create a client tunnel:

```dart
Future<void> clientTunnel(String remoteHost, int remotePort, int localTargetPort) async {
  var tunnel = Tunnel.connect(remoteHost, remotePort, localTargetPort);

  tunnel.onClose = (t) {
    // closed, try to reconnect...
  };
}
```

The `Tunnel` establishes a connection to `remoteHost:remotePort`,
after which it connects to `localTargetPort` and enables bidirectional
data traffic redirection between the two connections.

## CLI Tool

You can utilize the CLI tool `tcp_tunnel` with ease on any platform supported by Dart.

To activate the CLI tool just run:

```shell
dart pub global activate tcp_tunnel
```

Then you can create a tunnel for each necessary scenario:  

- **Local Port Redirect:**

    ```shell
    tcp_tunnel local %listenPort %targetPort %targetHost
    ```
    - `%targetHost` is optional. Default: `localhost`


- **Bridge Tunneling:**

    ```shell
    tcp_tunnel bridge %listenPort1 %listenPort2
    ```

- **Client Tunnel:**

    ```shell
    tcp_tunnel client %remoteHost %remotePort %localTargetPort
    ```

## Combined Usage
 
To access the port `3306` (MySQL) inside a remote and private Server X (no public address):

- 1) Establish a Server Bridge in a public Server Y (server-y.domain):

    ```shell
    tcp_tunnel bridge 8035 8036
    ```

- 2) Run the client tunnel at private Server X (the server with the private MySQL DB):

  ```shell
  tcp_tunnel client server-y.domain 8036 3306
  ```

- 3) Run mysql client pointing to the tunnel port:

  ```shell
  mysql -u myuser -p -h server-y.domain -P 8035
  ```

With this setup you can use the remote port `server-y.domain:8035` as the
private MySQL port `3306`.


- 4) If you wish to expand the configuration, you can establish a local port for the redirection above.

  ```shell
  tcp_tunnel local 3306 8035 server-y.domain
  ```
  Now, simply access the local port `3306` as you would with a standard MySQL database. This local port, in reality, connects to a remote private server.
  ```shell
  mysql -u myuser -p -h localhost -P 3306
  ```
  Or just with default settings (same as above):
  ```shell
  mysql -u myuser -p
  ```

## Security

Please be aware that the tunnel communication is **NOT encrypted**,
and any connection made over a public network **may expose its data to potential security risks**.

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/gmpassos/tcp_tunnel/issues

## Author

Graciliano M. Passos: [gmpassos@GitHub][github].

[github]: https://github.com/gmpassos

## Sponsor

Don't be shy, show some love, and become our [GitHub Sponsor][github_sponsors].
Your support means the world to us, and it keeps the code caffeinated! ☕✨

Thanks a million! 🚀😄

[github_sponsors]: https://github.com/sponsors/gmpassos

## License

Dart free & open-source [license](https://github.com/dart-lang/stagehand/blob/master/LICENSE).
