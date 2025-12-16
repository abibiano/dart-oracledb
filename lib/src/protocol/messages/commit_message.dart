/// TTC COMMIT message for transaction management.
///
/// Sends a commit request to Oracle to persist all pending changes
/// in the current transaction.
library;

import 'dart:typed_data';

import '../../errors.dart';
import '../buffer.dart';
import '../constants.dart';
import 'base.dart';

/// TTC COMMIT request message (function code 0x0E).
///
/// Commits the current transaction, making all pending changes
/// permanent and visible to other database sessions.
///
/// Example:
/// ```dart
/// final commit = CommitRequest();
/// final bytes = commit.toBytes();
/// // Send bytes to server and await CommitResponse
/// ```
class CommitRequest extends Message {
  /// Creates a commit request with an optional sequence number.
  CommitRequest({super.sequence}) : super(messageType: ttcCommit);

  @override
  void encode(WriteBuffer buffer) {
    // Commit message format: single byte function code
    buffer.writeUint8(messageType);
  }
}

/// TTC COMMIT response from server.
///
/// Contains the result of a commit operation, indicating success
/// or failure with error details.
class CommitResponse {
  /// Creates a commit response with the given fields.
  const CommitResponse({
    required this.isSuccess,
    this.errorCode,
    this.errorMessage,
  });

  /// Whether the commit succeeded.
  final bool isSuccess;

  /// Oracle error code if the commit failed.
  final int? errorCode;

  /// Oracle error message if the commit failed.
  final String? errorMessage;

  /// Decodes a commit response from raw bytes.
  ///
  /// Throws [OracleException] if decoding fails.
  static CommitResponse decode(Uint8List data) {
    try {
      final buffer = ReadBuffer(data);

      // Status byte (0 = success)
      final status = buffer.readUint8();

      if (status != 0) {
        // Error response
        final errorCode = buffer.readUint16BE();
        final msgLen = buffer.readUint8();
        final errorMessage = msgLen > 0 ? buffer.readString(msgLen) : null;

        return CommitResponse(
          isSuccess: false,
          errorCode: errorCode,
          errorMessage: errorMessage,
        );
      }

      // Success response
      return const CommitResponse(isSuccess: true);
    } catch (e) {
      if (e is OracleException) rethrow;
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'Failed to decode commit response',
        cause: e,
      );
    }
  }
}
