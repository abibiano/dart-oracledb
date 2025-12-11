/// Transport layer abstraction for TCP/TLS socket handling.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../errors.dart';

/// Transport layer for network communication.
///
/// Handles TCP socket and TLS negotiation for Oracle Database connections.
class Transport {
  Transport._({
    required Socket socket,
    bool useTls = false,
  })  : _socket = socket,
        _useTls = useTls,
        _isClosed = false;

  Socket _socket;
  // ignore: unused_field
  final bool _useTls;
  bool _isClosed;

  /// Receive buffer
  final _receiveBuffer = <int>[];

  /// Stream subscription for socket data
  StreamSubscription<Uint8List>? _subscription;

  /// Completer for pending reads
  Completer<void>? _readCompleter;

  /// Connect to the database server.
  static Future<Transport> connect({
    required String host,
    required int port,
    Duration? timeout,
    bool useTls = false,
    String? walletPath,
  }) async {
    try {
      // ignore: close_sinks
      final socket = await Socket.connect(
        host,
        port,
        timeout: timeout ?? const Duration(seconds: 30),
      );

      final transport = Transport._(socket: socket, useTls: useTls);
      transport._setupSocketListener();

      // Upgrade to TLS if requested
      if (useTls) {
        await transport._upgradeTls(walletPath: walletPath);
      }

      return transport;
    } on SocketException catch (e) {
      if (e.osError?.errorCode == 61 || e.osError?.errorCode == 111) {
        throw ConnectionError.refused(host, port);
      }
      throw ConnectionError.hostUnreachable(host, port);
    } on TimeoutException {
      throw ConnectionError.timeout(timeout ?? const Duration(seconds: 30));
    }
  }

  /// Setup socket data listener.
  void _setupSocketListener() {
    _subscription = _socket.listen(
      (data) {
        _receiveBuffer.addAll(data);
        _readCompleter?.complete();
        _readCompleter = null;
      },
      onError: (Object error) {
        _readCompleter?.completeError(
          ConnectionError('Socket error: $error'),
        );
        _readCompleter = null;
      },
      onDone: () {
        _isClosed = true;
        _readCompleter?.completeError(ConnectionError.closed());
        _readCompleter = null;
      },
    );
  }

  /// Upgrade to TLS connection.
  Future<void> _upgradeTls({String? walletPath}) async {
    await _subscription?.cancel();

    SecurityContext? context;
    if (walletPath != null) {
      context = SecurityContext()
        ..useCertificateChain('$walletPath/ewallet.pem')
        ..usePrivateKey('$walletPath/ewallet.pem');
    }

    _socket = await SecureSocket.secure(
      _socket,
      context: context,
      onBadCertificate: (_) =>
          walletPath == null, // Allow self-signed if no wallet
    );

    _setupSocketListener();
  }

  /// Whether the transport is closed.
  bool get isClosed => _isClosed;

  /// Local address.
  InternetAddress get localAddress => _socket.address;

  /// Local port.
  int get localPort => _socket.port;

  /// Remote address.
  InternetAddress get remoteAddress => _socket.remoteAddress;

  /// Remote port.
  int get remotePort => _socket.remotePort;

  /// Send data to the server.
  Future<void> send(Uint8List data) async {
    if (_isClosed) {
      throw ConnectionError.closed();
    }
    _socket.add(data);
    await _socket.flush();
  }

  /// Receive exactly [length] bytes from the server.
  Future<Uint8List> receive(int length, {Duration? timeout}) async {
    if (_isClosed) {
      throw ConnectionError.closed();
    }

    while (_receiveBuffer.length < length) {
      _readCompleter = Completer<void>();
      if (timeout != null) {
        await _readCompleter!.future.timeout(
          timeout,
          onTimeout: () {
            _readCompleter = null;
            throw ConnectionError.timeout(timeout);
          },
        );
      } else {
        await _readCompleter!.future;
      }

      if (_isClosed) {
        throw ConnectionError.closed();
      }
    }

    final result = Uint8List.fromList(_receiveBuffer.sublist(0, length));
    _receiveBuffer.removeRange(0, length);
    return result;
  }

  /// Peek at the next [length] bytes without consuming them.
  Future<Uint8List> peek(int length, {Duration? timeout}) async {
    if (_isClosed) {
      throw ConnectionError.closed();
    }

    while (_receiveBuffer.length < length) {
      _readCompleter = Completer<void>();
      if (timeout != null) {
        await _readCompleter!.future.timeout(
          timeout,
          onTimeout: () {
            _readCompleter = null;
            throw ConnectionError.timeout(timeout);
          },
        );
      } else {
        await _readCompleter!.future;
      }

      if (_isClosed) {
        throw ConnectionError.closed();
      }
    }

    return Uint8List.fromList(_receiveBuffer.sublist(0, length));
  }

  /// Number of bytes available in the receive buffer.
  int get available => _receiveBuffer.length;

  /// Clear the receive buffer.
  void clearBuffer() => _receiveBuffer.clear();

  /// Close the transport.
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;

    await _subscription?.cancel();
    _subscription = null;

    try {
      await _socket.close();
    } catch (_) {
      // Ignore close errors
    }
  }
}
