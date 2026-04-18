## 1.0.2

- `bin/tcp_tunnel.dart`:
  - Added support for `verbose` flag in CLI.
  - Added support for `loop` flag and `--max-tunnels` option in client mode.
  - Added structured logging using `package:logging`.
  - Refactored main logic to `_run` with verbose and loop parameters.
  - Added `_withFlag` helper to parse boolean flags.
  - Added `_parseMaxTunnels` helper to parse max tunnels option.
  - Managed multiple tunnels with `_tunnels` list and recursive connection logic in client mode.

- `lib/src/tcp_tunnel_base.dart`:
  - Added guarded zone support with `Tunnel.zoneGuarded` and `Tunnel.runGuarded`.
  - Added `onReady` future to `Tunnel` to notify when tunnel is fully established.
  - Added `connectAsync` factory for two-phase lazy connection (remote connect → first data → target connect).
  - Updated `connect` factory to complete `onReady` after both sockets connect.
  - Updated `targetPort` and `withSockets` factories to complete `onReady`.
  - Added `verbose` parameter to `Tunnel` constructors and logging on close.
  - Improved internal connection and ready notification logic.

- `lib/src/tcp_tunnel_bridge.dart`:
  - Added `verbose` parameter to `TunnelBridge`.
  - Tunnel creation now passes `verbose` flag.
  - Added logging on tunnel connection when verbose enabled.

- `lib/src/tcp_tunnel_server.dart`:
  - Added `verbose` parameter to `TunnelLocalServer`.
  - Tunnel creation now passes `verbose` flag.
  - Added logging on new tunnel connection when verbose enabled.

## 1.0.1

- Updated SDK constraint to `>=3.10.0 <4.0.0`.
- Updated dependencies:
  - `logging` to ^1.3.0
  - `lints` to ^6.1.0
  - `dependency_validator` to ^5.0.5
  - `test` to ^1.31.0
- Added executable entry for `tcp_tunnel` in `pubspec.yaml`.
- Changed module type in `tcp_tunnel.iml` from `JAVA_MODULE` to `WEB_MODULE`.
- `bin/tcp_tunnel.dart`:
  - Fixed trailing comma in `_runModeClient` parameters.
- `lib/src/tcp_tunnel_base.dart`:
  - Improved code style in `SocketAsync` and `Tunnel` classes.
- `lib/tcp_tunnel.dart`:
  - Removed library name declaration (`library tcp_tunnel;`) to default unnamed library.

## 1.0.0

- Initial version.
