/// Common Oracle TNS error codes used in the transport layer.
const int oraNetworkError = 12150; // TNS:unable to send data
const int oraConnectTimeout = 12170; // TNS:Connect timeout occurred
const int oraHostUnreachable = 12541; // TNS:no listener
const int oraConnectionRefused = 12514; // TNS:listener does not know of service
const int oraProtocolError = 12547; // TNS:lost contact

/// TLS/SSL error codes
const int oraTlsHandshakeFailed = 28860; // ORA-28860: Fatal SSL error
const int oraTlsCertificateError = 28862; // ORA-28862: SSL cert verify failed

/// Connection lifecycle error codes
const int oraConnectionClosed =
    3113; // ORA-03113: end-of-file on communication channel

/// Bind parameter error codes
const int oraBindMismatch = 1008; // ORA-01008: Not all variables bound
const int oraBindTypeError = 6502; // ORA-06502: PL/SQL: numeric or value error

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
  /// The [errorCode] should be a standard Oracle error code (e.g., 12170) —
  /// valid Oracle codes are non-negative, and the driver only ever
  /// constructs non-negative codes. A negative code (a caller bug) is
  /// tolerated rather than rejected: [code] and [toString] render it as
  /// `ORA-invalid(<code>)` instead of throwing, so error reporting never
  /// fails mid-flight. There is deliberately no assert rejecting negative
  /// codes: negative sentinel codes must remain constructible — tests and
  /// the documented `ORA-invalid(<code>)` rendering rely on it.
  /// The [message] provides a human-readable description of the error.
  /// The optional [cause] preserves the original error for debugging.
  /// The optional [sql] and [offset] carry query-error context for
  /// server-side failures surfaced via TTC ERROR messages.
  const OracleException({
    required this.errorCode,
    required this.message,
    this.cause,
    this.sql,
    this.offset,
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

  /// The full SQL text (with bind placeholders) when the error originated from
  /// a server-side query execution. Null for non-query errors.
  ///
  /// Stores the raw SQL with placeholders (`:name`, `:1`) — bind values are
  /// never substituted. [message] carries a length-bounded snippet (≤200 chars)
  /// suitable for log lines; this field carries the complete text for callers
  /// that need programmatic access.
  final String? sql;

  /// The character offset into [sql] where Oracle reports the error, when
  /// the server returns a SQL error position. Null otherwise.
  final int? offset;

  /// Canonical Oracle error code formatted as `ORA-NNNNN` with five-digit
  /// zero padding (e.g., `ORA-00942`, `ORA-12170`).
  ///
  /// Total over all inputs: valid Oracle error codes are non-negative, so a
  /// negative [errorCode] renders as the unambiguous sentinel
  /// `ORA-invalid(<code>)` (e.g. `ORA-invalid(-1)`) instead of a malformed
  /// string such as `ORA-000-1` — and never throws, so error-reporting paths
  /// cannot fail while formatting an error. Codes of 100000 or above (never
  /// produced by Oracle servers, which use at most five digits) are emitted
  /// with their full digits (e.g., `ORA-100000`) — the five-digit padding is
  /// a floor, not a cap.
  String get code {
    if (errorCode < 0) {
      return 'ORA-invalid($errorCode)';
    }
    return 'ORA-${errorCode.toString().padLeft(5, '0')}';
  }

  @override
  String toString() {
    final buffer = StringBuffer('OracleException: $code: $message');
    if (offset != null) {
      buffer.write(' [offset=$offset]');
    }
    if (cause != null) {
      buffer.write('\nCaused by: $cause');
    }
    return buffer.toString();
  }
}
