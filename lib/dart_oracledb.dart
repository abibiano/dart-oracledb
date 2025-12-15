/// Pure Dart Oracle Database driver implementing thin-mode TNS/TTC wire protocol.
///
/// This library provides Oracle database connectivity for Dart applications
/// without requiring Oracle Client installation.
library;

// Errors and error codes
export 'src/errors.dart'
    show
        OracleException,
        oraNetworkError,
        oraConnectTimeout,
        oraHostUnreachable,
        oraConnectionRefused,
        oraConnectionClosed,
        oraProtocolError,
        oraInvalidCredentials,
        oraTlsHandshakeFailed,
        oraTlsCertificateError,
        // Bind parameter error codes (Story 2.3)
        oraBindMismatch,
        oraBindTypeError;

// Protocol error codes (from TTC layer)
export 'src/protocol/constants.dart'
    show
        oraMalformedPacket,
        oraProtocolViolation,
        oraUnsupportedType,
        oraDataTypeNotSupported;

// Connection API
export 'src/connection.dart' show OracleConnection;

// Query Results
export 'src/result.dart' show OracleResult, OracleRow;
export 'src/protocol/messages/execute_message.dart' show ColumnMetadata;

// TLS/SSL Configuration
export 'src/transport/tls.dart' show TlsConfig;
