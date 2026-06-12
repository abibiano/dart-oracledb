import 'dart:io';

import 'package:oracledb/src/transport/tls.dart';
import 'package:test/test.dart';

void main() {
  group('TlsConfig', () {
    test('default values', () {
      const config = TlsConfig();
      expect(config.enabled, isFalse);
      expect(config.verifyCertificate, isTrue);
      expect(config.securityContext, isNull);
    });

    test('enabled() factory creates enabled config', () {
      final config = TlsConfig.enabled();
      expect(config.enabled, isTrue);
      expect(config.verifyCertificate, isTrue);
      expect(config.securityContext, isNull);
    });

    test('enabled() with verifyCertificate false', () {
      final config = TlsConfig.enabled(verifyCertificate: false);
      expect(config.enabled, isTrue);
      expect(config.verifyCertificate, isFalse);
    });

    test('enabled() with custom securityContext', () {
      final context = SecurityContext();
      final config = TlsConfig.enabled(securityContext: context);
      expect(config.enabled, isTrue);
      expect(config.securityContext, same(context));
    });

    test('constructor with all parameters', () {
      final context = SecurityContext();
      final config = TlsConfig(
        enabled: true,
        verifyCertificate: false,
        securityContext: context,
      );
      expect(config.enabled, isTrue);
      expect(config.verifyCertificate, isFalse);
      expect(config.securityContext, same(context));
    });

    test('disabled by default for backward compatibility', () {
      // TLS disabled by default
      const config = TlsConfig();
      expect(config.enabled, isFalse,
          reason: 'TLS must be disabled by default for backward compatibility');
    });

    test('verifyCertificate true by default', () {
      // Certificate validation by default
      const config = TlsConfig(enabled: true);
      expect(config.verifyCertificate, isTrue,
          reason: 'Certificate validation must be enabled by default');
    });
  });
}
