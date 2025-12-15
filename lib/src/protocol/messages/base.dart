/// Base message class for TTC protocol messages.
///
/// Provides the abstract interface for encoding/decoding TTC messages
/// sent between client and server.
library;

import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../buffer.dart';

final _log = Logger('Message');

/// Exception thrown when message operations fail.
///
/// This exception is designed for internal use within the message layer.
/// When caught at higher levels, it should be wrapped in [OracleException]
/// to preserve the cause chain.
class MessageException implements Exception {
  /// Creates a message exception with the given message and optional cause.
  const MessageException(this.message, {this.cause});

  /// The error message describing what went wrong.
  final String message;

  /// The original error that caused this exception, if any.
  final Object? cause;

  @override
  String toString() {
    final buffer = StringBuffer('MessageException: $message');
    if (cause != null) {
      buffer.write('\nCaused by: $cause');
    }
    return buffer.toString();
  }
}

/// Abstract base class for TTC protocol messages.
///
/// All TTC messages extend this class and implement the [encode] method
/// to serialize themselves for transmission.
///
/// Example usage:
/// ```dart
/// class PingMessage extends Message {
///   PingMessage({int sequence = 0})
///       : super(messageType: ttcPing, sequence: sequence);
///
///   @override
///   void encode(WriteBuffer buffer) {
///     buffer.writeUint8(messageType);
///     buffer.writeUint8(sequence);
///   }
/// }
/// ```
abstract class Message {
  /// Creates a message with the given type and optional sequence number.
  Message({
    required this.messageType,
    this.sequence = 0,
  });

  /// The TTC message type code (e.g., EXECUTE, FETCH, PING).
  final int messageType;

  /// The request/response sequence number for matching.
  ///
  /// Sequence numbers help correlate requests with responses and
  /// detect out-of-order or missing messages.
  final int sequence;

  /// Encodes this message into the given [WriteBuffer].
  ///
  /// Subclasses must implement this to serialize their specific
  /// message format. The buffer will be converted to bytes for
  /// transmission.
  void encode(WriteBuffer buffer);

  /// Encodes this message to bytes for transmission.
  ///
  /// Convenience method that creates a buffer, calls [encode],
  /// and returns the resulting bytes.
  Uint8List toBytes() {
    final buffer = WriteBuffer();
    encode(buffer);
    final bytes = buffer.toBytes();
    _log.fine('Encoded message: type=$messageType, seq=$sequence, '
        'size=${bytes.length} bytes');
    return bytes;
  }
}
