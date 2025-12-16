/// TTC ROLLBACK message for transaction management.
///
/// Sends a rollback request to Oracle to undo all pending changes
/// in the current transaction.
library;

import 'dart:typed_data';

import '../../errors.dart';
import '../buffer.dart';
import '../constants.dart';
import 'base.dart';

/// TTC ROLLBACK request message (function code 0x0F).
///
/// Rolls back the current transaction, undoing all pending changes
/// since the last commit.
///
/// Example:
/// ```dart
/// final rollback = RollbackRequest();
/// final bytes = rollback.toBytes();
/// // Send bytes to server and await RollbackResponse
/// ```
class RollbackRequest extends Message {
  /// Creates a rollback request with an optional sequence number.
  RollbackRequest({super.sequence}) : super(messageType: ttcRollback);

  @override
  void encode(WriteBuffer buffer) {
    // Rollback message format: single byte function code
    buffer.writeUint8(messageType);
  }
}

/// TTC ROLLBACK response from server.
///
/// Contains the result of a rollback operation, indicating success
/// or failure with error details.
class RollbackResponse {
  /// Creates a rollback response with the given fields.
  const RollbackResponse({
    required this.isSuccess,
    this.errorCode,
    this.errorMessage,
  });

  /// Whether the rollback succeeded.
  final bool isSuccess;

  /// Oracle error code if the rollback failed.
  final int? errorCode;

  /// Oracle error message if the rollback failed.
  final String? errorMessage;

  /// Decodes a rollback response from raw bytes.
  ///
  /// Throws [OracleException] if decoding fails.
  static RollbackResponse decode(Uint8List data) {
    try {
      final buffer = ReadBuffer(data);

      // Status byte (0 = success)
      final status = buffer.readUint8();

      if (status != 0) {
        // Error response
        final errorCode = buffer.readUint16BE();
        final msgLen = buffer.readUint8();
        final errorMessage = msgLen > 0 ? buffer.readString(msgLen) : null;

        return RollbackResponse(
          isSuccess: false,
          errorCode: errorCode,
          errorMessage: errorMessage,
        );
      }

      // Success response
      return const RollbackResponse(isSuccess: true);
    } catch (e) {
      if (e is OracleException) rethrow;
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'Failed to decode rollback response',
        cause: e,
      );
    }
  }
}
