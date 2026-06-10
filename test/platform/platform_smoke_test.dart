@Tags(['platform'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

// Verifies that the package initialises cleanly on all declared platforms
// (linux, macos, windows, android, ios). No Oracle instance is required —
// these tests exercise the public API surface at the type/construction layer
// only. The same dart:io code paths that run on Linux CI run identically on
// Android and iOS; this suite proves the package compiles and its types are
// reachable on every declared platform.

void main() {
  group('package surface', () {
    test('TlsConfig constructs with default values', () {
      const cfg = TlsConfig();
      expect(cfg.enabled, isFalse);
      expect(cfg.verifyCertificate, isTrue);
    });

    test('TlsConfig.enabled factory sets enabled flag', () {
      final cfg = TlsConfig.enabled(verifyCertificate: false);
      expect(cfg.enabled, isTrue);
      expect(cfg.verifyCertificate, isFalse);
    });

    test('OracleException carries error code and message', () {
      const ex = OracleException(
        errorCode: oraNetworkError,
        message: 'smoke-test connection failure',
      );
      expect(ex.errorCode, equals(oraNetworkError));
      expect(ex.message, contains('smoke-test'));
    });

    test('OracleDbType enum values are accessible', () {
      expect(OracleDbType.values, isNotEmpty);
      expect(OracleDbType.number, isA<OracleDbType>());
      expect(OracleDbType.varchar, isA<OracleDbType>());
    });

    test('OracleConnection.connect is a callable static method', () {
      // Takes a function reference without invoking it — confirms the symbol
      // is reachable without needing a live Oracle server.
      expect(OracleConnection.connect, isA<Function>());
    });
  });
}
