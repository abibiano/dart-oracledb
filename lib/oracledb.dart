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
        // Bind parameter error codes
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
export 'src/connection.dart' show OracleConnection, OracleExecuteOptions;

// Charset capability detection (Story 10.1)
export 'src/oracle_charset_info.dart' show OracleCharsetInfo;

// Connection pooling
export 'src/pool.dart' show OraclePool, PoolSessionCallback;

// Query Results
export 'src/result.dart' show OracleResult, OracleRow;
export 'src/result_set.dart' show OracleResultSet;
export 'src/protocol/messages/execute_message.dart' show ColumnMetadata;

// Output bind API
export 'src/oracle_bind.dart' show OracleBind, OracleDbType, OracleOutBinds;

// Time-zone-preserving TIMESTAMP WITH TIME ZONE wrapper
export 'src/oracle_timestamp_tz.dart' show OracleTimestampTz;

// TLS/SSL Configuration
export 'src/transport/tls.dart' show TlsConfig;
