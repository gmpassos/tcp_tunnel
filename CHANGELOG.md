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
