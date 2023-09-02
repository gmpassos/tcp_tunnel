import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart' as logging;

final _log = logging.Logger('Tunnel');

typedef OnSocketData = void Function(Uint8List data);
typedef OnConnectSocket = void Function(Socket socket);

final Zone _zoneGuarded = Zone.current.fork(
    specification:
        ZoneSpecification(handleUncaughtError: _handleUncaughtError));

void _handleUncaughtError(Zone self, ZoneDelegate parent, Zone zone,
    Object error, StackTrace stackTrace) {
  _log.severe('Tunnel UncaughtError: $error', error, stackTrace);
}

/// Helper class to handle tunnel [Sockets].
class SocketAsync {
  static int _idCount = 0;

  final int id = ++_idCount;

  Socket? _socket;

  OnSocketData? _onFirstData;

  SocketAsync._({OnSocketData? onFirstData}) : _onFirstData = onFirstData;

  factory SocketAsync.from(Socket skt,
          {void Function(Uint8List data)? onFirstData}) =>
      SocketAsync._(onFirstData: onFirstData).._setSocket(skt, null);

  factory SocketAsync.connect(String host, int port,
          {OnConnectSocket? onConnect, OnSocketData? onFirstData}) =>
      SocketAsync.unresolved(Socket.connect(host, port),
          onConnect: onConnect, onFirstData: onFirstData);

  factory SocketAsync.unresolved(Future<Socket> socketResolver,
      {OnConnectSocket? onConnect, OnSocketData? onFirstData}) {
    var socket = SocketAsync._(onFirstData: onFirstData);
    socketResolver.then((skt) => socket._setSocket(skt, onConnect));
    return socket;
  }

  /// The handled [Socket].
  Socket get socket => _socket!;

  /// Returns `true` if [socket] is resolved/defined.
  bool get isResolved => _socket != null;

  String? _address;

  /// The [socket] address.
  String get address => _address!;

  /// The [socket] remote address.
  String get remoteAddress => _remoteAddress!;

  String? _remoteAddress;

  int? _port;

  /// The [socket] port.
  int get port => _port!;

  void _setSocket(Socket skt, OnConnectSocket? onConnect) {
    _socket = skt;

    try {
      _address = skt.address.address;
      _remoteAddress = skt.remoteAddress.address;
      _port = skt.port;
    } catch (_) {}

    if (isClosed) {
      skt.close();
      return;
    }

    //skt.

    skt.handleError((e) {
      close();
    });

    var listener = _listener;
    if (listener != null) {
      _registerListener(listener);
    }

    if (onConnect != null) {
      onConnect(skt);
    }

    _flushData();
  }

  void Function(Uint8List data)? _listener;

  void listen(void Function(Uint8List data) listener) {
    if (_listener != null) {
      throw StateError("Already listening!");
    }

    _listener = listener;

    var socket = _socket;
    if (socket != null) {
      _registerListener(listener);
    }
  }

  void _registerListener(void Function(Uint8List data) listener) {
    var resolvedListener = listener;

    if (_onFirstData != null) {
      resolvedListener = (data) {
        var onFirstData = _onFirstData;
        if (onFirstData != null) {
          onFirstData(data);
          _onFirstData = null;
        }

        listener(data);
      };
    }

    _zoneGuarded.runGuarded(() {
      _socket!.listen(resolvedListener,
          onError: (e) => closeAsync(),
          onDone: closeAsync,
          cancelOnError: true);
    });
  }

  List<int>? _unflushedData;

  void _flushData() {
    var unflushedData = _unflushedData;
    var socket = _socket;
    if (unflushedData == null || socket == null) return;

    _unflushedData = null;

    _zoneGuarded.runGuarded(() {
      socket.add(unflushedData);
      //socket.flush();
    });
  }

  /// Add [data] to this [socket].
  /// If the [socket] is NOT resolved yet (![isResolved]) adds to a temporary buffer,
  /// that is automatically flushed once the [socket] is resolved.
  void add(Uint8List data) {
    var socket = _socket;
    if (socket == null) {
      var unflushed = _unflushedData ??= <int>[];
      unflushed.addAll(data);
    } else {
      _flushData();
      var dataCp = Uint8List.fromList(data);

      _zoneGuarded.runGuarded(() {
        socket.add(dataCp);
      });
    }
  }

  /// Flushes [socket] if [isResolved].
  Future<bool> flush() =>
      _socket?.flush().then((_) => true) ?? Future.value(false);

  /// Same as [close] but with a [delay].
  void closeAsync({Duration delay = const Duration(seconds: 1)}) {
    Future.delayed(delay, close);
  }

  void Function(SocketAsync socket)? onClose;

  bool _closed = false;

  bool get isClosed => _closed;

  /// Closes the [socket] (if resolved).
  void close() {
    if (_closed) return;
    _closed = true;

    _log.info("** Closing socket: $this");

    var socket = _socket;
    if (socket == null) return;

    _zoneGuarded.runGuarded(() {
      socket.close();
    });

    _log.info("** Closed socket: $this");

    var onClose = this.onClose;
    if (onClose != null) {
      onClose(this);
    }
  }

  @override
  String toString() {
    if (_socket != null) {
      return '$_remoteAddress@$_port';
    } else {
      return 'Socket:?';
    }
  }
}

typedef TunnelCallback = void Function(Tunnel tunnel)?;

/// A tunnel between 2 sockets ([_socketA] and [_socketB]).
class Tunnel {
  /// Creates a tunnel with asynchronous connections.
  factory Tunnel.connectAsync(String remoteHost, int remotePort, int targetPort,
      {String targetHost = 'localhost',
      TunnelCallback? onStart,
      TunnelCallback? onClose,
      bool verbose = false}) {
    var socket2Completer = Completer<Socket>();

    final socket1 =
        SocketAsync.connect(remoteHost, remotePort, onFirstData: (_) {
      Socket.connect(targetHost, targetPort)
          .then((socket2) => socket2Completer.complete(socket2));
    });

    final socket2 = SocketAsync.unresolved(socket2Completer.future);

    return Tunnel(socket1, socket2,
        onStart: onStart, onClose: onClose, verbose: verbose);
  }

  /// Creates a tunnel with synchronous connections.
  factory Tunnel.connect(String remoteHost, int remotePort, int targetPort,
      {String targetHost = 'localhost',
      TunnelCallback? onStart,
      TunnelCallback? onClose,
      bool verbose = false}) {
    final socket1 = SocketAsync.connect(remoteHost, remotePort);
    final socket2 = SocketAsync.connect(targetHost, targetPort);
    return Tunnel(socket1, socket2,
        onStart: onStart, onClose: onClose, verbose: verbose);
  }

  static Future<Tunnel> targetPort(Socket socketA, int targetPort,
      {String targetHost = 'localhost'}) async {
    final socketB = await Socket.connect(targetHost, targetPort);
    return Tunnel(SocketAsync.from(socketA), SocketAsync.from(socketB));
  }

  /// Creates a tunnel with [socketA] and [socketB].
  factory Tunnel.withSockets(Socket socketA, Socket socketB,
          {TunnelCallback? onStart,
          TunnelCallback? onClose,
          bool verbose = false}) =>
      Tunnel(SocketAsync.from(socketA), SocketAsync.from(socketB),
          onStart: onStart, onClose: onClose, verbose: verbose);

  final SocketAsync _socketA;
  final SocketAsync _socketB;

  /// Called when the tunnel is started (both sockets are ready for data redirection).
  final TunnelCallback? onStart;

  /// If `true` this tunnel will log data redirection.
  final bool verbose;

  Tunnel(this._socketA, this._socketB,
      {this.onStart, this.onClose, this.verbose = false}) {
    _start();
  }

  Future<void> _start() async {
    _zoneGuarded.runGuarded(() {
      _socketA.onClose = _onSocketClose;
      _socketB.onClose = _onSocketClose;

      _socketA.listen((Uint8List data) {
        if (verbose) {
          _log.info('[DATA-A] <<<${latin1.decode(data)}>>>');
        }
        _socketB.add(data);
        //_socketB.flush();
      });

      _socketB.listen((Uint8List data) {
        if (verbose) {
          _log.info('[DATA-B] <<<${latin1.decode(data)}>>>');
        }
        _socketA.add(data);
        //_socketA.flush();
      });
    });

    _log.info("** Started: $this");

    final onStart = this.onStart;

    if (onStart != null) {
      onStart(this);
    }
  }

  void _onSocketClose(SocketAsync socketAsync) {
    closeAsync();
  }

  /// Same as [close] but with a [delay].
  void closeAsync({Duration delay = const Duration(seconds: 1)}) {
    Future.delayed(delay, close);
  }

  /// Called when the tunnel is closed (when one of the [Sockets] is closed or [closed] is called).
  TunnelCallback? onClose;

  bool _closed = false;

  /// Closes the tunnels and its [Sockets].
  void close() {
    if (_closed) return;
    _closed = true;

    try {
      _socketA.close();
    } catch (_) {}

    try {
      _socketB.close();
    } catch (_) {}

    var onClose = this.onClose;
    if (onClose != null) {
      onClose(this);
    }
  }

  @override
  String toString() => 'Tunnel{ $_socketA <--> $_socketB }';
}
