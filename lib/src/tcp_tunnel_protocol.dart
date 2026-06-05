import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart' as logging;

final _log = logging.Logger('TunnelProtocol');

/// Wire magic prefixing every control frame: ASCII `TTN1`.
const List<int> kFrameMagic = [0x54, 0x54, 0x4E, 0x31];

/// Fixed header size: magic(4) + type(1) + length(2, big-endian).
const int kFrameHeaderSize = 7;

/// Types of control frames exchanged before a connection switches to raw piping.
enum FrameType {
  /// Agent → hub. payload: `{role: "server"|"client", service: "<name>"}`.
  hello(1),

  /// Hub → parked server conn at pairing. payload: `{peer: "ip:port"}`.
  activate(2),

  /// Keepalive request on a parked (idle) server conn.
  ping(3),

  /// Keepalive reply.
  pong(4),

  /// Server agent → hub, sent right after it reads [activate]. It is the last
  /// framed message on the connection: everything after it is raw payload. The
  /// barrier lets the hub discard any keepalive frames still in flight before
  /// switching the connection to raw piping.
  ready(5),

  /// Hub → server agent, sent once after a server HELLO, informing the public
  /// port currently mapped to the service (public port mode). Payload:
  /// `{publicPort: <port>}`, or empty when the service has no public port
  /// (local port mode only).
  welcome(6);

  final int code;

  const FrameType(this.code);

  static FrameType fromCode(int code) {
    for (var t in FrameType.values) {
      if (t.code == code) return t;
    }
    throw FormatException('Unknown frame type code: $code');
  }
}

/// A single control frame: a [type] plus a small JSON [payload].
class Frame {
  final FrameType type;
  final Map<String, dynamic> payload;

  const Frame(this.type, [this.payload = const {}]);

  /// `role` field of a [FrameType.hello] frame (`"server"` or `"client"`).
  String? get role => payload['role'] as String?;

  /// `service` field of a [FrameType.hello] frame.
  String? get service => payload['service'] as String?;

  /// `peer` field of a [FrameType.activate] frame.
  String? get peer => payload['peer'] as String?;

  /// `publicPort` field of a [FrameType.welcome] frame (null = no public port).
  int? get publicPort => payload['publicPort'] as int?;

  factory Frame.hello({required String role, required String service}) =>
      Frame(FrameType.hello, {'role': role, 'service': service});

  factory Frame.activate({String? peer}) =>
      Frame(FrameType.activate, peer != null ? {'peer': peer} : const {});

  factory Frame.welcome({int? publicPort}) => Frame(
    FrameType.welcome,
    publicPort != null ? {'publicPort': publicPort} : const {},
  );

  static const Frame pingFrame = Frame(FrameType.ping);
  static const Frame pongFrame = Frame(FrameType.pong);
  static const Frame readyFrame = Frame(FrameType.ready);

  @override
  String toString() => 'Frame{${type.name}, $payload}';
}

/// Encodes [frame] into a length-prefixed, binary-safe byte sequence.
Uint8List encodeFrame(Frame frame) {
  final payloadBytes = frame.payload.isEmpty
      ? const <int>[]
      : utf8.encode(json.encode(frame.payload));

  final len = payloadBytes.length;
  if (len > 0xFFFF) {
    throw ArgumentError('Frame payload too large: $len');
  }

  final out = Uint8List(kFrameHeaderSize + len);
  out.setRange(0, 4, kFrameMagic);
  out[4] = frame.type.code;
  out[5] = (len >> 8) & 0xFF;
  out[6] = len & 0xFF;
  out.setRange(kFrameHeaderSize, out.length, payloadBytes);
  return out;
}

/// Result of [decodeFrame]: the parsed [frame] and how many bytes it consumed.
class DecodedFrame {
  final Frame frame;
  final int consumed;

  DecodedFrame(this.frame, this.consumed);
}

/// Attempts to decode one [Frame] from the start of [buffer].
///
/// Returns `null` if [buffer] does not yet hold a complete frame (caller should
/// read more bytes). Throws [FormatException] if the magic does not match
/// (wrong protocol / corrupt stream).
DecodedFrame? decodeFrame(List<int> buffer) {
  if (buffer.length < kFrameHeaderSize) return null;

  for (var i = 0; i < kFrameMagic.length; ++i) {
    if (buffer[i] != kFrameMagic[i]) {
      throw FormatException('Invalid frame magic at byte $i: ${buffer[i]}');
    }
  }

  final type = FrameType.fromCode(buffer[4]);
  final len = (buffer[5] << 8) | buffer[6];
  final total = kFrameHeaderSize + len;

  if (buffer.length < total) return null;

  final Map<String, dynamic> payload;
  if (len == 0) {
    payload = const {};
  } else {
    final payloadBytes = buffer.sublist(kFrameHeaderSize, total);
    final decoded = json.decode(utf8.decode(payloadBytes));
    payload = decoded is Map<String, dynamic>
        ? decoded
        : Map<String, dynamic>.from(decoded as Map);
  }

  return DecodedFrame(Frame(type, payload), total);
}

/// Owns the single subscription of a [Socket] during its handshake phase.
///
/// Reads complete [Frame]s across fragmented/coalesced TCP reads and keeps any
/// bytes that arrive past the last consumed frame as [leftover]. Once the
/// protocol phase is done, the same live subscription is handed off to a
/// `SocketAsync` (see `SocketAsync.adopt`) so the connection can switch to raw
/// piping without re-listening.
class FramedConnection {
  final Socket socket;
  late final StreamSubscription<Uint8List> subscription;

  /// Buffered bytes not yet consumed by [readFrame]. After the handshake this
  /// holds raw payload bytes that arrived coalesced with the last frame.
  final List<int> _buffer = <int>[];

  Completer<Frame>? _pendingRead;
  Object? _terminalError;
  bool _done = false;
  bool _adopted = false;
  bool _closedNotified = false;

  /// Called once when the connection closes/errors while still framed (i.e.
  /// before [markAdopted]). After adoption, close is handled by the adopter.
  void Function()? onClosed;

  /// `true` if the connection has closed/errored while still framed.
  bool get isClosed => _done && !_adopted;

  /// Creates a framed connection over [socket]. If [zone] is provided the
  /// underlying subscription is created within it, so callbacks (including the
  /// raw-piping handlers installed after handoff) run in that zone and uncaught
  /// errors are routed to its handler.
  FramedConnection(this.socket, {Zone? zone}) {
    final z = zone ?? Zone.current;
    subscription = z.run(
      () => socket.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: true,
      ),
    );
  }

  void _onData(Uint8List data) {
    _buffer.addAll(data);
    _tryCompletePendingRead();
  }

  void _onError(Object error, StackTrace stackTrace) {
    _terminalError = error;
    _done = true;
    final pending = _pendingRead;
    if (pending != null && !pending.isCompleted) {
      _pendingRead = null;
      pending.completeError(error, stackTrace);
    }
    _notifyClosed();
  }

  void _onDone() {
    _done = true;
    final pending = _pendingRead;
    if (pending != null && !pending.isCompleted) {
      _pendingRead = null;
      pending.completeError(
        StateError('Connection closed before a full frame was read'),
      );
    }
    _notifyClosed();
  }

  void _notifyClosed() {
    if (_closedNotified || _adopted) return;
    _closedNotified = true;
    final cb = onClosed;
    if (cb != null) cb();
  }

  void _tryCompletePendingRead() {
    final pending = _pendingRead;
    if (pending == null || pending.isCompleted) return;

    final DecodedFrame? decoded;
    try {
      decoded = decodeFrame(_buffer);
    } catch (e, s) {
      _pendingRead = null;
      pending.completeError(e, s);
      return;
    }

    if (decoded == null) return;

    _buffer.removeRange(0, decoded.consumed);
    _pendingRead = null;
    pending.complete(decoded.frame);
  }

  /// Reads the next complete [Frame]. Only one read may be pending at a time.
  Future<Frame> readFrame() {
    if (_pendingRead != null) {
      throw StateError('A readFrame() is already pending');
    }
    if (_adopted) {
      throw StateError('Connection already adopted for raw piping');
    }

    final terminalError = _terminalError;
    if (terminalError != null) {
      return Future.error(terminalError);
    }

    // Satisfy immediately if a full frame is already buffered.
    final completer = Completer<Frame>();
    _pendingRead = completer;
    _tryCompletePendingRead();

    if (!completer.isCompleted && _done) {
      _pendingRead = null;
      return Future.error(
        StateError('Connection closed before a full frame was read'),
      );
    }

    return completer.future;
  }

  /// Writes [frame] to the socket.
  void writeFrame(Frame frame) {
    try {
      socket.add(encodeFrame(frame));
    } catch (e, s) {
      _log.warning('** Error writing frame $frame: $e', e, s);
    }
  }

  /// Removes and returns any bytes buffered past the last consumed frame.
  Uint8List takeLeftover() {
    if (_buffer.isEmpty) return Uint8List(0);
    final leftover = Uint8List.fromList(_buffer);
    _buffer.clear();
    return leftover;
  }

  /// `true` once the connection has been handed off for raw piping.
  bool get isAdopted => _adopted;

  /// Marks this connection as adopted; callers must stop using [readFrame]
  /// afterwards. The live [subscription] is reused by the adopter.
  void markAdopted() {
    _adopted = true;
  }

  void close() {
    if (!_adopted) {
      subscription.cancel();
      try {
        socket.destroy();
      } catch (_) {}
    }
  }
}
