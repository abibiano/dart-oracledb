/// Common Oracle TNS error codes used in the transport layer.
const int oraNetworkError = 12150; // TNS:unable to send data
const int oraConnectTimeout = 12170; // TNS:Connect timeout occurred
const int oraHostUnreachable = 12541; // TNS:no listener
const int oraConnectionRefused = 12514; // TNS:listener does not know of service
const int oraProtocolError = 12547; // TNS:lost contact

/// TLS/SSL error codes
const int oraTlsHandshakeFailed = 28860; // ORA-28860: Fatal SSL error
const int oraTlsCertificateError = 28862; // ORA-28862: SSL cert verify failed

/// Authentication error codes (ORA-01017, ORA-28000, etc.)
const int oraInvalidCredentials = 1017; // ORA-01017: invalid username/password
const int oraAccountLocked = 28000; // ORA-28000: account is locked
const int oraPasswordExpired = 28001; // ORA-28001: password has expired
const int oraPasswordGracePeriod = 28002; // ORA-28002: password will expire
const int oraAuthProtocolError = 3134; // ORA-03134: auth protocol failure
const int oraConnectionNotAllowed =
    28003; // ORA-28003: password verification failed

/// Exception thrown when Oracle database operations fail.
///
/// This exception wraps Oracle error codes (ORA-XXXXX) and provides
/// a structured way to handle database errors while preserving the
/// original cause for debugging purposes.
///
/// Example usage:
/// ```dart
/// try {
///   await socket.connect(host, port);
/// } catch (e) {
///   throw OracleException(
///     errorCode: oraConnectTimeout,
///     message: 'TNS:Connect timeout occurred',
///     cause: e,
///   );
/// }
/// ```
class OracleException implements Exception {
  /// Creates an Oracle exception with the given error code and message.
  ///
  /// The [errorCode] should be a standard Oracle error code (e.g., 12170).
  /// The [message] provides a human-readable description of the error.
  /// The optional [cause] preserves the original error for debugging.
  const OracleException({
    required this.errorCode,
    required this.message,
    this.cause,
  });

  /// The Oracle error code (e.g., 12170 for TNS:Connect timeout).
  final int errorCode;

  /// A human-readable description of the error.
  final String message;

  /// The original error that caused this exception, if any.
  ///
  /// This preserves the error chain for debugging and allows
  /// access to the underlying system error details.
  final Object? cause;

  @override
  String toString() {
    final buffer = StringBuffer('OracleException: ORA-$errorCode: $message');
    if (cause != null) {
      buffer.write('\nCaused by: $cause');
    }
    return buffer.toString();
  }
}
