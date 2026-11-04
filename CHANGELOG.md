## 2.3.1

- `TunnelClientAgent.close()` now closes everything it owns, like the other
  listeners since 2.3.0: its listening socket, every tunnel it opened and any
  application connection whose hub connect is still pending (that hub
  connection, which cannot be aborted, is dropped as soon as it completes). It
  used to only stop listening, leaving tunnels running. New
  `close(closeActiveTunnels: false)` for graceful shutdown; a later `close()`
  closes whatever is still running. Repeated calls are no-ops.
- `TunnelServerAgent.close()` now also closes its activated connections:
  running tunnels and hub connections whose local target is still being dialed
  (the target socket is dropped once that connect completes). It also cancels
  pending reconnect timers, which kept the process alive for up to
  `reconnectDelay`. Same `closeActiveTunnels` option. A hub `REJECT` still only
  stops the pool and leaves active tunnels running.
- `TunnelLocalServer`, `TunnelBridge`, `TunnelHub`, `TunnelClientAgent`: a
  `close()` issued while `start()` was still binding left the port listening.
  The port is now released as soon as the bind completes, and the bound port
  getters stay `null`.
- `TunnelHub`: the 2.3.0 fix "a pairing whose server-agent connection closes
  before its `READY` now fails at once" did not work for public port clients.
  Their listener ran outside the hub's guarded zone, so the activation's error
  never reached them (a future's error is not delivered across error zones),
  and they waited out `clientWaitTimeout`. Public ports now accept in the
  guarded zone, like the control port.
- Tests: `close()` of both agents (active tunnels, graceful variant,
  idempotency, a hub connect or a target connect still pending at `close()`),
  and `close()` during `start()` for all four listeners. All on port 0
  listeners.

## 2.3.0

- **Behaviour change — `close()` now closes everything it owns.**
  `TunnelLocalServer.close()`, `TunnelBridge.close()` and `TunnelHub.close()`
  used to only stop listening, leaving already paired tunnels (and, for the
  hub, parked server-agent connections and waiting clients) running. They now
  close their listeners, every queued/parked/waiting connection and every
  active tunnel (a `TunnelLocalServer` connection still connecting to its
  target is closed as soon as that connect completes; a hub pairing still
  being activated is closed at once).
  - New opt-in for graceful shutdown: `close(closeActiveTunnels: false)` stops
    listening and drops queued/parked/waiting connections but leaves active
    tunnels to finish on their own; a later `close()` closes whatever is still
    running. Same signature on all three classes.
  - Connections accepted after `close()` (already in flight) are dropped. A
    hub control connection still in its TLS handshake (which cannot be
    aborted) is dropped as soon as the handshake ends.
  - The CLI's SIGINT/SIGTERM shutdown uses the new `close()`, so peers see
    their tunnels closed, and the process exits right away.
- `TunnelHub`: fixed a waiting client that sent data and then disconnected
  being paired with the next parked server-agent connection (its bytes reached
  the service after it was gone). Its socket was paused as soon as it sent
  data, which hid its EOF. A disconnected waiting client is now evicted before
  pairing. The same applies to `TunnelBridge` queued sockets, and to a client
  agent whose HELLO arrived together with its EOF.
  - `SocketAsync` keeps reading while no consumer is attached, buffering up to
    `SocketAsync.maxBufferedInput` (64 KiB), and only pauses beyond that; the
    buffered bytes are delivered intact and in order once a consumer attaches,
    as a single chunk (delivering several chunks back to back would `add` to
    the destination while its previous `flush` was pending, which an `IOSink`
    rejects, losing data). A peer that closes after filling the buffer is only
    noticed once reading resumes (after pairing).
  - New `SocketAsync.isInputDone`: the peer's EOF/error was seen.
  - Note: a waiting client that half-closes (sends, then shuts down its write
    side) is treated as disconnected and is not paired.
- `TunnelHub`: a pairing whose server-agent connection closes before its
  `READY` now fails at once instead of waiting out `clientWaitTimeout`.
- `FramedConnection.close()` fails a pending `readFrame()` (with a
  `StateError`) instead of leaving it pending forever. This also stops the
  keepalive timer of a `TunnelServerAgent` parked connection closed by
  `TunnelServerAgent.close()`.
- Tests:
  - every test listener binds port `0` and reads the real port back
    (`boundPort`, `boundPort1`/`boundPort2`, `boundControlPort`,
    `boundListenPort`, `ServerSocket.port`); `freePort()` (bind, release,
    re-bind) is gone. Only ports that must stay unreachable, or must be named
    before anything binds them (an agent-requested fixed public port, which
    retries on a conflict, and a port range), still come from a released port;
  - regression tests for the stale waiting client and for `close()` (the
    pinned 2.2.1 behaviour tests were replaced);
  - CLI: SIGINT with an active bridge tunnel closes it and exits `0` promptly.

## 2.2.1

- `TunnelHub`: fixed an activation that could fail when the server agent's
  `READY` arrived after `parkedIdleTimeout`. The parked-connection loop timed
  out its read and then started a second `readFrame()` while the first was
  still pending, which throws; the loop exited, the `READY` was never seen, and
  the client was dropped after `clientWaitTimeout`. The pending read is now
  kept and awaited again while the connection is being activated.
- `decodeFrame`: a payload that is valid JSON but not an object (e.g. `[1,2]`)
  now throws a `FormatException`, like every other malformed frame, instead of
  a `TypeError`. The hub already dropped such connections; only the error type
  changes.
- Tests: new `test/tcp_tunnel_integration_test.dart`:
  - framing edge cases: 64 KiB (maximum) payloads, every partial prefix,
    frames split into single-byte reads and coalesced with raw bytes, malformed
    headers/payloads (also sent to a live hub, which keeps serving);
  - injected socket errors (`FramedConnection`, `SocketAsync`);
  - 4 MiB transfers through the hub in both directions (checksummed),
    40 concurrent tunnels, several services and client agents on one hub,
    abrupt client disconnects, half-close;
  - pool exhaustion, FIFO pairing of queued clients, keepalive `PING`/`PONG`,
    idle reaping, unreachable targets/hubs, server agent reconnection;
  - pins that `close()` of `TunnelLocalServer`, `TunnelBridge` and `TunnelHub`
    only stops listening and leaves already paired tunnels running.
- CLI tests: `client` mode `loop` grows up to `--max-tunnels` and replaces a
  closed tunnel; `--parallel` is clamped to `--max-tunnels` (at least `1`).
- Tests in `test/tcp_tunnel_test.dart` now poll for in-flight data instead of
  asserting right after a fixed 30 ms sleep, which flaked on a loaded machine.
- Line coverage of `lib`: ~92.3% → ~99.3%.

## 2.2.0

- Updated SDK constraint to `^3.13.0`.
- Updated dependencies (all were already on their latest major; lower bounds
  raised to the current versions):
  - `dependency_validator` to ^5.1.0
  - `test` to ^1.33.0
- **Ephemeral (port `0`) listeners:** the actually bound port is now exposed,
  so any listener can be started on an OS-chosen port:
  `TunnelLocalServer.boundPort`, `TunnelBridge.boundPort1`/`boundPort2`,
  `TunnelHub.boundControlPort` and `TunnelClientAgent.boundListenPort`.
- `TunnelBridge.start()`: if the second port cannot be bound, the first one is
  released again instead of being left listening; a failed `start()` (bridge or
  `TunnelLocalServer`) can now be retried.
- `TunnelBridge.close()` now also closes accepted sockets still queued waiting
  for a peer (already paired tunnels are left running).
- `PortRange.parse` validates the range (`1..65535`, `start <= end`) and throws a
  `FormatException`; before, only the constructor's asserts checked it, which
  are disabled in a compiled (AOT) CLI.
- CLI (`bin/tcp_tunnel.dart`):
  - Invalid arguments now print `** Error: <reason>` and exit with status `1`.
    Previously the error was only logged by the guarded zone and the process
    stayed alive (idle) forever. Missing/non-numeric positional arguments get a
    clear message (e.g. `Missing argument <targetPort>`), and a non-numeric
    value for an integer option (`--control-port`, `--max-tunnels`, `--pool`,
    `--listen`, ...) is now an error instead of silently using the default.
  - A listener that fails to start (e.g. port already in use) in `local`,
    `bridge`, `hub` or `connect` mode prints `** Failed to start ...` and exits
    with status `1`.
  - Ports can be `0`: the real bound port is printed (`-- Listening on port: N`,
    `-- Listening on control port: N`, ...) and used in the "How to use" output.
- Internal: `SocketAsync` uses a private named initializing formal
  (`prefer_initializing_formals`, new in the 3.13 lints); `dart format` with the
  3.13 formatter.
- Tests: new `test/tcp_tunnel_ephemeral_test.dart` (port-0 integration tests for
  data flow in both directions, close propagation, bind failures, hub
  handshake rejection, protocol and `FramedConnection` error paths) and
  `test/tcp_tunnel_cli_test.dart` (runs the CLI as a child process: usage,
  argument errors, start failures, and `local`/`bridge`/`hub` modes end to end).
- CI: `actions/checkout@v7`, `codecov/codecov-action@v7`; tests also run on the
  minimum SDK (3.13.0).

## 2.1.0

- **Security layer for hub-mode connections (opt-in, two independent layers):**
  - **TLS** on the agent↔hub links. The hub can serve its control port over TLS
    (`hub --tls-cert <pem> --tls-key <pem>` / `TunnelHub.securityContext`); each
    accepted connection is upgraded with `SecureSocket.secureServer` before its
    handshake. Agents connect over TLS with `publish`/`connect --tls`, trusting a
    custom CA with `--tls-ca <pem>` or accepting any certificate (dev only) with
    `--tls-insecure` (`TunnelServerAgent`/`TunnelClientAgent.securityContext` and
    `onBadCertificate`). Encrypts both the control frames and the raw-piped
    payload as it crosses the network. No new dependency — `dart:io` TLS.
  - **Shared-secret authentication.** Agents present a token in their `HELLO`,
    constant-time compared by the hub (`TunnelHub.authToken`,
    `TunnelServerAgent`/`TunnelClientAgent.authToken`); a mismatch is rejected
    with a `REJECT` frame. The token is resolved (in priority order) from
    `--token-file <path>` (keeps it out of shell history and the process arg
    list), the `TCP_TUNNEL_TOKEN` env var, or `--token <secret>`. The `HELLO`
    frame now carries an optional `token` field; adds `constantTimeEquals`.
  - Both layers are optional and independent; existing plaintext deployments are
    unaffected. The hub's control-accept loop now runs in the guarded zone so a
    stray socket error during a TLS handshake or rejection teardown is logged
    rather than left unhandled.

## 2.0.1

- `publish` can request a public port from the hub (default off):
  `--public-port <n>` (fixed), `--public-port any` / `--public-port .`
  (dynamic), or `--public` (alias for `--public-port any`). Exposed as
  `TunnelServerAgent.requestPublicPort`. If the request cannot be satisfied —
  the port is already in use by another service/process, it is unallocatable, or
  a dynamic request reaches a hub started without `--map-dynamic` — the hub sends
  a `REJECT` control frame and `publish` exits non-zero with the reason
  (`TunnelServerAgent.onPublicPortRejected`). Adds `FrameType.reject`; the
  `HELLO` frame now carries the agent's public-port request.
- **Changed `--map-dynamic` semantics:** it no longer auto-allocates a public
  port for every published service. It now only *permits* publishers to request
  a dynamic public port via `--public-port any`; without the flag such requests
  are rejected with a reason. Operator-configured dynamic ports (`--map svc=.`)
  are unaffected, and a service whose agent requests no port stays in local port
  mode (`TunnelHub.dynamicPublicPorts`).

## 2.0.0

- **Hub mode:** a single public hub that routes named services
  from private LANs (NAT-friendly on both ends) to remote consumers, using a
  pre-warmed pool of parked connections. Two consumer modes share the same hub:
  - **Mode 1 — public port mode:** the hub binds a public TCP port per service
    (`--map svc=port`); plain TCP clients connect directly. The port may be
    dynamically allocated with `--map svc=.` (per service) or `--map-dynamic`
    (auto-allocate a port for any published service); the chosen port is logged.
    Dynamic allocation can be constrained to a firewall-friendly range via
    `--port-range start-end` (`TunnelHub.dynamicPortRange` / `PortRange`).
  - **Mode 2 — local port mode:** a client agent opens a local listen port and
    uses the hub purely as a rendezvous (no public per-service port needed).
- Every CLI command prints a "How to use" block on startup explaining how to
  publish to / consume from it (the hub block lists allocated public ports).
- The hub now tells each connecting server agent its service's public port (a
  `WELCOME` control frame); `publish` logs where the service is publicly mapped
  (or that it is local port mode only). Exposed as `TunnelServerAgent.publicPort`.
- New library APIs:
  - `lib/src/tcp_tunnel_protocol.dart`: length-prefixed control frames
    (`HELLO`/`ACTIVATE`/`PING`/`PONG`/`READY`), `encodeFrame`/`decodeFrame`, and
    `FramedConnection` (reads frames across fragmented/coalesced TCP reads).
  - `lib/src/tcp_tunnel_hub.dart`: `TunnelHub`.
  - `lib/src/tcp_tunnel_agent.dart`: `TunnelServerAgent` (publish) and
    `TunnelClientAgent` (connect).
- `lib/src/tcp_tunnel_base.dart`: added `SocketAsync.adopt(FramedConnection)` to
  hand a connection off from the framed handshake to raw piping by reusing the
  existing single subscription (no re-listen) and replaying leftover bytes.
- CLI: new `hub`, `publish`, and `connect` modes. Existing `local`, `bridge`,
  and `client` modes are unchanged.
- Activation uses an explicit `ACTIVATE`/`READY` barrier so server-speaks-first
  protocols (MySQL/SSH/SMTP banners) work and in-flight keepalive frames never
  leak into the raw stream.
- Not included (same posture as before): encryption/TLS, authentication,
  dynamic public-port allocation, client-specified target addressing.

## 1.0.2

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

## 1.0.2+

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
