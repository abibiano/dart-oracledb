/// TLS negotiation for secure Oracle connections.
library;

import 'dart:io';

/// TLS configuration for Oracle connections.
///
/// Oracle thin mode requires PEM format wallets (ewallet.pem).
class TlsConfig {
  const TlsConfig({
    this.walletPath,
    this.verifyServerCertificate = true,
    this.serverNameIndication,
  });

  /// Path to Oracle wallet directory containing ewallet.pem
  final String? walletPath;

  /// Whether to verify server certificate
  final bool verifyServerCertificate;

  /// Server Name Indication (SNI) for TLS
  final String? serverNameIndication;

  /// Create a SecurityContext from this configuration.
  SecurityContext? createContext() {
    if (walletPath == null) return null;

    final context = SecurityContext();

    // Load certificate chain from PEM wallet
    final pemPath = '$walletPath/ewallet.pem';
    if (File(pemPath).existsSync()) {
      context.useCertificateChain(pemPath);
      context.usePrivateKey(pemPath);
    }

    // Load trusted certificates
    final caPath = '$walletPath/ca-bundle.crt';
    if (File(caPath).existsSync()) {
      context.setTrustedCertificates(caPath);
    }

    return context;
  }
}

/// TLS cipher suites supported by Oracle.
abstract final class OracleTlsCiphers {
  /// Default cipher suites for Oracle connections
  static const List<String> defaultCiphers = [
    'TLS_AES_256_GCM_SHA384',
    'TLS_AES_128_GCM_SHA256',
    'TLS_CHACHA20_POLY1305_SHA256',
    'ECDHE-RSA-AES256-GCM-SHA384',
    'ECDHE-RSA-AES128-GCM-SHA256',
    'DHE-RSA-AES256-GCM-SHA384',
    'DHE-RSA-AES128-GCM-SHA256',
  ];
}
