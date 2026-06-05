## 1.0.3

- `lib/src/tcp_tunnel_base.dart`:
  - Added end-to-end backpressure: `SocketAsync` now owns its stream
    subscription and pauses reading until the destination's flush completes,
    preventing unbounded memory growth when one peer is slower than the other.
  - Connection failures no longer hang: `SocketAsync.unresolved` closes on a
    failed connect, and `close()` now always notifies `onClose` even when the
    socket was never resolved.
  - `Tunnel.connectAsync`: a failed target connection now closes the tunnel
    (and fires `onClose`) instead of hanging forever.
  - Removed a dead `Socket.handleError(...)` handler whose result was discarded;
    error handling lives in the subscription's `onError`.
  - Added `Tunnel.pair(SocketAsync, SocketAsync)` factory; `withSockets` and
    `targetPort` now delegate to it.
  - `Tunnel.targetPort` now returns `Future<Tunnel?>` and destroys the inbound
    socket when the target connection fails.
  - Verbose data logging now logs byte counts instead of `latin1`-decoding
    payloads; removed the now-unused `dart:convert` import.

- `bin/tcp_tunnel.dart`:
  - Fixed `_withFlag` to correctly detect single-dash flags.
  - `_parseMaxTunnels`: added lower bound check to ensure minimum value of 1.
  - Added graceful shutdown: `SIGINT`/`SIGTERM` now close active servers and
    tunnels before exiting (`SIGTERM` skipped on Windows).

- `lib/src/tcp_tunnel_bridge.dart`:
  - Changed `_server1` and `_server2` fields to nullable `ServerSocket?`.
  - Added null-aware calls to `_server1?.close()` and `_server2?.close()` in `close()`.
  - Queues now hold `SocketAsync` instances; a queued socket that closes before
    being paired is evicted via `onClose` and skipped during pairing, so it is
    never paired into a dead tunnel.

- `lib/src/tcp_tunnel_server.dart`:
  - Changed `_server` field to nullable `ServerSocket?`.
  - Added null-aware call to `_server?.close()` in `close()`.
  - Updated to the nullable `Tunnel.targetPort` result (logs only on success).

- `pubspec.yaml`:
  - Updated `test` dependency from `^1.31.0` to `^1.31.1`.

- `test/tcp_tunnel_test.dart`:
  - Rewrote tests extensively:
    - Added utility functions `freePort()`, `_wait()`.
    - Added `RecordingServer` helper class to record socket data.
    - Added `echoServer` helper for echoing data.
    - Added comprehensive tests for:
      - `TunnelLocalServer` forwarding data one and both directions.
      - Multiple concurrent clients support.
      - `TunnelBridge` connecting queued sockets, FIFO pairing, and close idempotency.
      - `Tunnel.withSockets` relaying data and close notification.
      - Full chain integration test with bridge, client tunnel, and local server.
      - Connection failures firing `onClose` for `connect` and `connectAsync`.
      - `connectAsync` lazy connect (target connects only after first remote data).
      - Backpressure: large payload (4 MiB) transferred byte-for-byte.
      - `TunnelBridge` eviction of a queued socket closed before pairing.
      - CLI usage smoke test.
      - `connectAsync` forwarding the first (triggering) data to the target and
        bidirectional round-trip with `onReady` completing.
      - `TunnelBridge` buffering data sent while a socket is queued, isolating
        many concurrent pairs, and tearing down a peer when one side closes.
      - `TunnelLocalServer` dropping the client when the target is unreachable.
      - `onStart` callback, `verbose` data path, and custom `targetHost`.
      - Edge cases: half-close drain, zero-length writes, reverse-direction
        relay, large bidirectional transfer, and `SocketAsync` state getters.
    - Removed old `redirectLocalPort`, `bridgePorts`, and `clientTunnel` helper functions.
    - Improved test reliability with explicit waits and socket flushes.

## 1.0.2

- `bin/tcp_tunnel.dart`:
  - Added support for `verbose` flag in CLI.
  - Added support for `loop` flag and `--max-tunnels` option in client mode.
  - Added structured logging using `package:logging`.
  - Updated `_configureLogging` to always configure logging with level `ALL` if verbose, otherwise `INFO`.
  - Changed default logging level in `_configureLogging` from `ALL` to `INFO`.
  - Refactored main logic to `_run` with verbose and loop parameters.
  - Added `_withFlag` helper to parse boolean flags.
 - Client mode:
    - Added support for parallel connections with a new `_parseParallels` method.
    - Run multiple client tunnels in parallel based on the parsed parallel count.
    - Managed multiple tunnels with `_tunnels` list and recursive connection logic in client mode.
  - Argument parsing:
    - Added `_parseParallels` to parse concurrency-related flags (`--concurrency`, `--parallel`, `--parallels`) with clamping between 2 and max tunnels.
    - Refactored argument parsing into `_parseArgInt` helper method used by `_parseMaxTunnels` and `_parseParallels`.

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
