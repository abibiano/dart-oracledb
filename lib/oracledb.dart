/// Pure Dart Oracle Database driver implementing thin-mode TNS/TTC wire protocol.
///
/// This library provides Oracle database connectivity for Dart applications
/// without requiring Oracle Client installation.
library;

// Errors and error codes
export 'src/errors.dart'
    show
        OracleException,
        OracleBatchError,
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
export 'src/connection.dart'
    show
        OracleConnection,
        OracleExecuteOptions,
        OracleExecuteManyOptions,
        // Fetch type handler (Story 14.4)
        OracleFetchConverter,
        OracleFetchTypeHandler;

// Charset capability detection (Story 10.1)
export 'src/oracle_charset_info.dart' show OracleCharsetInfo;

// Connection pooling
export 'src/pool.dart' show OraclePool, PoolSessionCallback;

// Query Results
export 'src/result.dart' show OracleResult, OracleRow;
export 'src/result_set.dart' show OracleResultSet;
// The fallback stream piece size is `OracleLob.defaultStreamPieceSize`. The
// top-level `defaultLobStreamPieceSize` is a @Deprecated alias kept only so
// 1.4.0 code keeps compiling; drop it from this `show` list at the next major
// release.
export 'src/oracle_lob.dart' show OracleLob, defaultLobStreamPieceSize;
export 'src/protocol/messages/execute_message.dart' show ColumnMetadata;

// Output bind API
export 'src/oracle_bind.dart'
    show OracleBind, OracleBindDef, OracleDbType, OracleOutBinds;

// Time-zone-preserving TIMESTAMP WITH TIME ZONE wrapper
export 'src/oracle_timestamp_tz.dart' show OracleTimestampTz;

// INTERVAL DAY TO SECOND (Story 15.1) and YEAR TO MONTH (Story 15.2) wrappers
export 'src/oracle_interval.dart' show OracleIntervalDS, OracleIntervalYM;

// TLS/SSL Configuration
export 'src/transport/tls.dart' show TlsConfig;
