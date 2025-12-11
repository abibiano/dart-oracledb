/// Exception classes and error codes for Oracle Database driver.
library;

/// Base class for all Oracle database exceptions.
///
/// Uses Dart 3.0 sealed classes for exhaustive pattern matching.
sealed class OracleException implements Exception {
  const OracleException(this.message, [this.code]);

  /// Error message
  final String message;

  /// Oracle error code (ORA-XXXXX) if applicable
  final int? code;

  @override
  String toString() {
    if (code != null) {
      return 'OracleException(ORA-$code): $message';
    }
    return 'OracleException: $message';
  }
}

/// General Oracle error with ORA code.
final class OracleError extends OracleException {
  const OracleError(super.message, [super.code]);

  @override
  String toString() {
    if (code != null) {
      return 'ORA-${code.toString().padLeft(5, '0')}: $message';
    }
    return 'OracleError: $message';
  }
}

/// Connection-related errors.
final class ConnectionError extends OracleException {
  const ConnectionError(super.message, [super.code]);

  /// Connection timeout
  factory ConnectionError.timeout(Duration duration) =>
      ConnectionError('Connection timeout after ${duration.inSeconds} seconds');

  /// Host unreachable
  factory ConnectionError.hostUnreachable(String host, int port) =>
      ConnectionError('Cannot connect to $host:$port');

  /// Connection refused
  factory ConnectionError.refused(String host, int port) =>
      ConnectionError('Connection refused by $host:$port');

  /// Connection closed
  factory ConnectionError.closed() =>
      const ConnectionError('Connection is closed');

  @override
  String toString() => 'ConnectionError: $message';
}

/// Protocol-level errors during TNS/TTC communication.
final class ProtocolError extends OracleException {
  const ProtocolError(super.message, [super.code]);

  /// Invalid packet received
  factory ProtocolError.invalidPacket(int type) =>
      ProtocolError('Invalid packet type: 0x${type.toRadixString(16)}');

  /// Unexpected response
  factory ProtocolError.unexpectedResponse(String expected, String actual) =>
      ProtocolError('Expected $expected but received $actual');

  /// Protocol version mismatch
  factory ProtocolError.versionMismatch(int expected, int actual) =>
      ProtocolError(
          'Protocol version mismatch: expected $expected, got $actual');

  /// Packet size exceeded
  factory ProtocolError.packetSizeExceeded(int size, int max) =>
      ProtocolError('Packet size $size exceeds maximum $max');

  @override
  String toString() => 'ProtocolError: $message';
}

/// Authentication failures.
final class AuthenticationError extends OracleException {
  const AuthenticationError(super.message, [super.code]);

  /// Invalid credentials
  factory AuthenticationError.invalidCredentials() =>
      const AuthenticationError('Invalid username or password', 1017);

  /// Account locked
  factory AuthenticationError.accountLocked() =>
      const AuthenticationError('Account is locked', 28000);

  /// Password expired
  factory AuthenticationError.passwordExpired() =>
      const AuthenticationError('Password has expired', 28001);

  /// Unsupported authentication protocol
  factory AuthenticationError.unsupportedProtocol(String protocol) =>
      AuthenticationError('Unsupported authentication protocol: $protocol');

  @override
  String toString() {
    if (code != null) {
      return 'AuthenticationError(ORA-$code): $message';
    }
    return 'AuthenticationError: $message';
  }
}

/// Data type conversion errors.
final class DataTypeError extends OracleException {
  const DataTypeError(super.message, [super.code]);

  /// Cannot convert value
  factory DataTypeError.conversionFailed(String from, String to) =>
      DataTypeError('Cannot convert $from to $to');

  /// Invalid format
  factory DataTypeError.invalidFormat(String type, String value) =>
      DataTypeError('Invalid $type format: $value');

  /// Value out of range
  factory DataTypeError.outOfRange(String type, dynamic value) =>
      DataTypeError('Value $value is out of range for $type');

  /// Null value not allowed
  factory DataTypeError.nullNotAllowed(String column) =>
      DataTypeError('NULL value not allowed for column: $column');

  @override
  String toString() => 'DataTypeError: $message';
}

/// Pool-related errors.
final class PoolError extends OracleException {
  const PoolError(super.message, [super.code]);

  /// Pool exhausted
  factory PoolError.exhausted() => const PoolError('Connection pool exhausted');

  /// Pool closed
  factory PoolError.closed() => const PoolError('Connection pool is closed');

  /// Acquire timeout
  factory PoolError.acquireTimeout(Duration duration) =>
      PoolError('Failed to acquire connection within ${duration.inSeconds}s');

  @override
  String toString() => 'PoolError: $message';
}

/// LOB operation errors.
final class LobError extends OracleException {
  const LobError(super.message, [super.code]);

  /// LOB locator invalid
  factory LobError.invalidLocator() =>
      const LobError('LOB locator is invalid or has been freed');

  /// LOB operation failed
  factory LobError.operationFailed(String operation) =>
      LobError('LOB $operation operation failed');

  @override
  String toString() => 'LobError: $message';
}

/// SQL statement errors.
final class StatementError extends OracleException {
  const StatementError(super.message, [super.code]);

  /// SQL syntax error
  factory StatementError.syntaxError(int position) =>
      StatementError('SQL syntax error at position $position', 900);

  /// Invalid bind variable
  factory StatementError.invalidBind(String name) =>
      StatementError('Invalid bind variable: $name', 1036);

  /// Cursor not open
  factory StatementError.cursorNotOpen() =>
      const StatementError('Cursor is not open', 1001);

  @override
  String toString() {
    if (code != null) {
      return 'StatementError(ORA-$code): $message';
    }
    return 'StatementError: $message';
  }
}
