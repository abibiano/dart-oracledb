import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../errors.dart';

final _log = Logger('OracleSocket');

/// A TCP socket wrapper for Oracle database connections.
///
/// This class wraps `dart:io` Socket to provide Oracle-specific error handling
/// and connection management. All socket errors are wrapped in [OracleException]
/// with the original error preserved as `cause` for debugging.
class OracleSocket {
  /// Creates an unconnected Oracle socket.
  OracleSocket();

  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  final _pendingData = <int>[];
  Completer<void>? _dataAvailable;

  /// Known-liveness flag for the connection.
  ///
  /// Set `true` once a socket is established and cleared the moment a remote
  /// close (`onDone`), socket error (`onError`), or a local [close]/[destroy]
  /// has been observed. This is event-driven — no polling — so [isConnected]
  /// reflects a peer disconnect as soon as the stream event is delivered,
  /// rather than only after the next failed read/write.
  bool _alive = false;

  /// Whether the socket is currently connected and known to be alive.
  ///
  /// Returns `false` after a remote close/error has been observed, even though
  /// teardown of the underlying socket is asynchronous. Callers can use this as
  /// a cheap local guard before attempting an RPC instead of waiting for a long
  /// receive timeout.
  bool get isConnected => _alive;

  /// Connects to the specified host and port.
  ///
  /// Throws [OracleException] if the connection fails. The original socket
  /// error is preserved in the exception's `cause` property.
  ///
  /// The [timeout] parameter specifies how long to wait for the connection
  /// to be established. Defaults to 60 seconds.
  Future<void> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (isConnected) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message: 'Socket is already connected',
      );
    }

    _log.fine('Connecting to $host:$port with timeout ${timeout.inSeconds}s');

    try {
      _socket = await Socket.connect(host, port, timeout: timeout);
      _alive = true;
      _log.info('Connected to $host:$port');

      // Set up data listener
      _subscription = _socket!.listen(
        (Uint8List data) {
          _log.fine('Received ${data.length} bytes');
          _pendingData.addAll(data);
          // Signal that data is available
          if (_dataAvailable != null && !_dataAvailable!.isCompleted) {
            _dataAvailable!.complete();
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          _log.warning('Socket error', error, stackTrace);
          _handleError(error);
        },
        onDone: () {
          _log.fine('Socket closed by remote');
          _cleanup();
        },
      );
    } on SocketException catch (e) {
      _log.warning('Connection failed: $e');
      throw OracleException(
        errorCode: _mapSocketError(e),
        message: 'Failed to connect to $host:$port: ${e.message}',
        cause: e,
      );
    } on TimeoutException catch (e) {
      _log.warning('Connection timeout: $e');
      throw OracleException(
        errorCode: oraConnectTimeout,
        message:
            'Connection to $host:$port timed out after ${timeout.inSeconds}s',
        cause: e,
      );
    } catch (e) {
      _log.severe('Unexpected connection error', e);
      throw OracleException(
        errorCode: oraNetworkError,
        message: 'Failed to connect to $host:$port: $e',
        cause: e,
      );
    }
  }

  /// Sends data to the connected socket.
  ///
  /// Throws [OracleException] if the socket is not connected or if sending fails.
  Future<void> send(Uint8List data) async {
    if (!isConnected) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message: 'Cannot send data: socket is not connected',
      );
    }

    _log.fine('Sending ${data.length} bytes');

    try {
      _socket!.add(data);
      await _socket!.flush();
    } on SocketException catch (e) {
      _log.warning('Send failed: $e');
      throw OracleException(
        errorCode: oraNetworkError,
        message: 'Failed to send data: ${e.message}',
        cause: e,
      );
    } catch (e) {
      _log.severe('Unexpected send error', e);
      throw OracleException(
        errorCode: oraNetworkError,
        message: 'Failed to send data: $e',
        cause: e,
      );
    }
  }

  /// Reads the specified number of bytes from the socket.
  ///
  /// This method blocks until the requested number of bytes is available
  /// or the socket is closed.
  ///
  /// Throws [OracleException] if the socket is closed before enough data arrives.
  Future<Uint8List> read(int length,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);

    while (_pendingData.length < length) {
      // Check connection status inside the loop to catch disconnects during wait
      if (!isConnected) {
        throw OracleException(
          errorCode: oraNetworkError,
          message: 'Connection closed by server while waiting for data: '
              'need $length bytes, have ${_pendingData.length}',
        );
      }

      // Calculate remaining timeout
      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) {
        throw OracleException(
          errorCode: oraConnectTimeout,
          message:
              'Timeout waiting for data: need $length bytes, have ${_pendingData.length}',
        );
      }

      // Create a new completer to wait for data
      _dataAvailable = Completer<void>();

      try {
        await _dataAvailable!.future.timeout(remaining);
      } on TimeoutException {
        throw OracleException(
          errorCode: oraConnectTimeout,
          message:
              'Timeout waiting for data: need $length bytes, have ${_pendingData.length}',
        );
      }
    }

    final result = Uint8List.fromList(_pendingData.sublist(0, length));
    _pendingData.removeRange(0, length);
    return result;
  }

  /// Checks if data is available for reading.
  bool get hasData => _pendingData.isNotEmpty;

  /// Returns the number of bytes available for reading.
  int get available => _pendingData.length;

  /// Upgrades the current TCP connection to TLS.
  ///
  /// This must be called BEFORE any TNS protocol communication.
  /// The upgrade replaces the underlying socket with a SecureSocket.
  ///
  /// The [host] parameter is used for certificate hostname verification.
  /// Set [verifyCertificate] to `false` only for development with self-signed
  /// certificates. NEVER disable in production.
  /// Use [securityContext] to specify custom CA certificates for enterprise PKI.
  ///
  /// Throws [OracleException] if TLS handshake fails.
  Future<void> upgradeToTls({
    required String host,
    bool verifyCertificate = true,
    SecurityContext? securityContext,
  }) async {
    if (!isConnected) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message: 'Cannot upgrade to TLS: socket is not connected',
      );
    }

    _log.fine('Upgrading connection to TLS');

    try {
      // Cancel existing subscription before upgrade
      await _subscription?.cancel();
      _subscription = null;

      // Upgrade to TLS - assign directly to _socket so close() can clean it up
      _socket = await SecureSocket.secure(
        _socket!,
        host: host,
        context: securityContext,
        onBadCertificate: verifyCertificate
            ? null
            : (X509Certificate cert) {
                _log.warning(
                    'Accepting unverified certificate: ${cert.subject}');
                return true;
              },
      );
      _log.info('TLS upgrade successful');

      // Re-establish data listener on secure socket
      _subscription = _socket!.listen(
        (Uint8List data) {
          _log.fine('Received ${data.length} bytes (TLS)');
          _pendingData.addAll(data);
          if (_dataAvailable != null && !_dataAvailable!.isCompleted) {
            _dataAvailable!.complete();
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          _log.warning('TLS socket error', error, stackTrace);
          _handleError(error);
        },
        onDone: () {
          _log.fine('TLS socket closed by remote');
          _cleanup();
        },
      );
    } on HandshakeException catch (e) {
      _log.warning('TLS handshake failed: $e');
      await close(); // Clean up socket on failure
      throw OracleException(
        errorCode: oraTlsHandshakeFailed,
        message: 'TLS handshake failed: ${e.message}',
        cause: e,
      );
    } on CertificateException catch (e) {
      _log.warning('TLS certificate error: $e');
      await close(); // Clean up socket on failure
      throw OracleException(
        errorCode: oraTlsCertificateError,
        message: 'TLS certificate verification failed: ${e.message}',
        cause: e,
      );
    } catch (e) {
      if (e is OracleException) {
        await close(); // Clean up socket on failure
        rethrow;
      }
      _log.severe('Unexpected TLS error', e);
      await close(); // Clean up socket on failure
      throw OracleException(
        errorCode: oraTlsHandshakeFailed,
        message: 'Failed to establish TLS connection: $e',
        cause: e,
      );
    }
  }

  /// Closes the socket connection.
  ///
  /// This method is safe to call on an already closed or unconnected socket.
  /// [close] performs a graceful shutdown (the outbound direction is closed and
  /// the socket is allowed to drain). To guarantee no further inbound bytes can
  /// arrive — for example after an RPC timeout left an orphaned response on the
  /// wire — use [destroy] instead.
  Future<void> close() async {
    if (_socket != null) {
      _log.fine('Closing socket');
      try {
        await _socket!.close();
      } catch (e) {
        _log.warning('Error closing socket: $e');
      }
    }
    _cleanup();
  }

  /// Forcibly destroys the socket in both directions immediately.
  ///
  /// Unlike [close], which only shuts down the outbound direction and lets the
  /// inbound side drain, [destroy] tears the connection down so that no further
  /// bytes can be delivered. This is the correct primitive after an RPC timeout:
  /// `Future.timeout` does not cancel the pending socket read, so the server's
  /// (late) response could otherwise be delivered and misread as the reply to a
  /// subsequent RPC. Safe to call when already closed or never connected.
  void destroy() {
    if (_socket != null) {
      _log.fine('Destroying socket');
      try {
        _socket!.destroy();
      } catch (e) {
        _log.warning('Error destroying socket: $e');
      }
    }
    _cleanup();
  }

  void _cleanup() {
    _alive = false;
    _subscription?.cancel();
    _subscription = null;
    _socket = null;
    _pendingData.clear();
    // Complete any pending read with an error by leaving the completer incomplete
    // The read() method will detect !isConnected and throw
    if (_dataAvailable != null && !_dataAvailable!.isCompleted) {
      _dataAvailable!.complete();
    }
    _dataAvailable = null;
  }

  void _handleError(Object error) {
    _cleanup();
  }

  /// Maps socket exception types to Oracle error codes.
  int _mapSocketError(SocketException e) {
    final message = e.message.toLowerCase();

    if (message.contains('connection refused')) {
      return oraHostUnreachable;
    }
    if (message.contains('host not found') ||
        message.contains('no address associated') ||
        message.contains('name or service not known')) {
      return oraConnectionRefused;
    }
    if (message.contains('timed out')) {
      return oraConnectTimeout;
    }
    if (message.contains('connection reset') ||
        message.contains('broken pipe')) {
      return oraProtocolError;
    }

    return oraNetworkError;
  }
}
