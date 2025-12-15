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
        oraProtocolError,
        oraInvalidCredentials,
        oraTlsHandshakeFailed,
        oraTlsCertificateError;

// Protocol error codes (from TTC layer)
export 'src/protocol/constants.dart'
    show
        oraMalformedPacket,
        oraProtocolViolation,
        oraUnsupportedType,
        oraDataTypeNotSupported;

// Connection API
export 'src/connection.dart' show OracleConnection;

// TLS/SSL Configuration
export 'src/transport/tls.dart' show TlsConfig;

// Public API exports will be added as implementation progresses
// export 'src/pool.dart' show OraclePool;
// export 'src/result.dart' show OracleResult, OracleRow;
