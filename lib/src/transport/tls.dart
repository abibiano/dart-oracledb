import 'dart:io';

/// Configuration for TLS/SSL connections to Oracle databases.
///
/// TLS is disabled by default for backward compatibility. Enable TLS
/// for production connections to encrypt data in transit.
///
/// Example usage:
/// ```dart
/// // Enable TLS with certificate validation (recommended for production)
/// final connection = await OracleConnection.connect(
///   'db.example.com:2484/ORCL',  // TLS port typically 2484
///   user: 'system',
///   password: 'password',
///   tls: TlsConfig.enabled(),
/// );
///
/// // Disable certificate validation for self-signed certs (dev only)
/// final devConnection = await OracleConnection.connect(
///   'localhost:2484/ORCL',
///   user: 'system',
///   password: 'password',
///   tls: TlsConfig(enabled: true, verifyCertificate: false),
/// );
/// ```
class TlsConfig {
  /// Creates a TLS configuration.
  ///
  /// By default, TLS is disabled and certificate verification is enabled.
  const TlsConfig({
    this.enabled = false,
    this.verifyCertificate = true,
    this.securityContext,
  });

  /// Creates a TLS configuration with TLS enabled.
  ///
  /// Certificate verification is enabled by default.
  factory TlsConfig.enabled({
    bool verifyCertificate = true,
    SecurityContext? securityContext,
  }) {
    return TlsConfig(
      enabled: true,
      verifyCertificate: verifyCertificate,
      securityContext: securityContext,
    );
  }

  /// Whether TLS is enabled for the connection.
  final bool enabled;

  /// Whether to verify the server's TLS certificate.
  ///
  /// Set to `false` only for development with self-signed certificates.
  /// NEVER disable in production - this defeats the purpose of TLS.
  final bool verifyCertificate;

  /// Custom security context for certificate verification.
  ///
  /// Use this to specify custom CA certificates for enterprise PKI.
  final SecurityContext? securityContext;
}
