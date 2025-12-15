import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/transport/connect_string.dart';
import 'package:test/test.dart';

void main() {
  group('ConnectionInfo', () {
    test('stores host, port, and serviceName', () {
      const info = ConnectionInfo(
        host: 'localhost',
        port: 1521,
        serviceName: 'FREEPDB1',
      );

      expect(info.host, equals('localhost'));
      expect(info.port, equals(1521));
      expect(info.serviceName, equals('FREEPDB1'));
    });

    test('toString returns readable format', () {
      const info = ConnectionInfo(
        host: 'db.example.com',
        port: 1522,
        serviceName: 'ORCL',
      );

      expect(info.toString(), contains('db.example.com'));
      expect(info.toString(), contains('1522'));
      expect(info.toString(), contains('ORCL'));
    });
  });

  group('parseEZConnect', () {
    group('valid formats', () {
      test('parses host:port/service format', () {
        final info = parseEZConnect('localhost:1521/FREEPDB1');

        expect(info.host, equals('localhost'));
        expect(info.port, equals(1521));
        expect(info.serviceName, equals('FREEPDB1'));
      });

      test('parses with default port when port omitted', () {
        final info = parseEZConnect('localhost/FREEPDB1');

        expect(info.host, equals('localhost'));
        expect(info.port, equals(1521)); // Default Oracle port
        expect(info.serviceName, equals('FREEPDB1'));
      });

      test('parses IP address with port', () {
        final info = parseEZConnect('192.168.1.100:1522/ORCL');

        expect(info.host, equals('192.168.1.100'));
        expect(info.port, equals(1522));
        expect(info.serviceName, equals('ORCL'));
      });

      test('parses hostname with subdomain', () {
        final info = parseEZConnect('db.prod.example.com:1521/PRODDB');

        expect(info.host, equals('db.prod.example.com'));
        expect(info.port, equals(1521));
        expect(info.serviceName, equals('PRODDB'));
      });

      test('parses lowercase service name', () {
        final info = parseEZConnect('localhost:1521/freepdb1');

        expect(info.serviceName, equals('freepdb1'));
      });

      test('parses service name with underscore', () {
        final info = parseEZConnect('localhost:1521/my_service');

        expect(info.serviceName, equals('my_service'));
      });

      test('parses service name with dots', () {
        final info = parseEZConnect('localhost:1521/pdb1.localdomain');

        expect(info.serviceName, equals('pdb1.localdomain'));
      });
    });

    group('invalid formats', () {
      test('throws on empty string', () {
        expect(
          () => parseEZConnect(''),
          throwsA(isA<OracleException>()),
        );
      });

      test('throws on missing service name', () {
        expect(
          () => parseEZConnect('localhost:1521'),
          throwsA(isA<OracleException>()),
        );
      });

      test('throws on missing service name with slash only', () {
        expect(
          () => parseEZConnect('localhost:1521/'),
          throwsA(isA<OracleException>()),
        );
      });

      test('throws on invalid port (non-numeric)', () {
        expect(
          () => parseEZConnect('localhost:abc/ORCL'),
          throwsA(isA<OracleException>()),
        );
      });

      test('throws on invalid port (negative)', () {
        expect(
          () => parseEZConnect('localhost:-1/ORCL'),
          throwsA(isA<OracleException>()),
        );
      });

      test('throws on invalid port (too large)', () {
        expect(
          () => parseEZConnect('localhost:99999/ORCL'),
          throwsA(isA<OracleException>()),
        );
      });

      test('throws on invalid port (zero)', () {
        expect(
          () => parseEZConnect('localhost:0/ORCL'),
          throwsA(isA<OracleException>()),
        );
      });

      test('throws on missing host', () {
        expect(
          () => parseEZConnect(':1521/ORCL'),
          throwsA(isA<OracleException>()),
        );
      });

      test('throws on missing host with slash', () {
        expect(
          () => parseEZConnect('/ORCL'),
          throwsA(isA<OracleException>()),
        );
      });

      test('exception includes helpful error message', () {
        try {
          parseEZConnect('invalid');
          fail('Should have thrown');
        } on OracleException catch (e) {
          expect(e.message, contains('EZ Connect'));
        }
      });

      test('exception uses appropriate error code', () {
        try {
          parseEZConnect('invalid');
          fail('Should have thrown');
        } on OracleException catch (e) {
          // Should use a TNS-related error code
          expect(e.errorCode, isPositive);
        }
      });
    });

    group('edge cases', () {
      test('handles whitespace in connection string', () {
        final info = parseEZConnect('  localhost:1521/FREEPDB1  ');

        expect(info.host, equals('localhost'));
        expect(info.port, equals(1521));
        expect(info.serviceName, equals('FREEPDB1'));
      });

      test('handles port at boundary (1)', () {
        final info = parseEZConnect('localhost:1/ORCL');

        expect(info.port, equals(1));
      });

      test('handles port at boundary (65535)', () {
        final info = parseEZConnect('localhost:65535/ORCL');

        expect(info.port, equals(65535));
      });
    });
  });

  group('Default port constant', () {
    test('defaultOraclePort is 1521', () {
      expect(defaultOraclePort, equals(1521));
    });
  });
}
