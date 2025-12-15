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

  /// Whether the socket is currently connected.
  bool get isConnected => _socket != null;

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
          errorCode: oraProtocolError,
          message: 'Socket closed while waiting for data: '
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

  /// Closes the socket connection.
  ///
  /// This method is safe to call on an already closed or unconnected socket.
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

  void _cleanup() {
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
