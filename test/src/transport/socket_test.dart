import 'dart:io';
import 'dart:typed_data';

import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/transport/socket.dart';
import 'package:test/test.dart';

void main() {
  group('OracleSocket', () {
    group('constructor', () {
      test('creates unconnected socket', () {
        final socket = OracleSocket();
        expect(socket.isConnected, isFalse);
      });
    });

    group('connect', () {
      test('throws OracleException on connection refused', () async {
        final socket = OracleSocket();

        // Try to connect to a port that should not be listening
        expect(
          () => socket.connect('127.0.0.1', 59999,
              timeout: const Duration(seconds: 1)),
          throwsA(isA<OracleException>()),
        );
      });

      test('throws OracleException with cause on socket error', () async {
        final socket = OracleSocket();

        try {
          await socket.connect('127.0.0.1', 59999,
              timeout: const Duration(seconds: 1));
          fail('Should have thrown');
        } on OracleException catch (e) {
          // Should preserve original error as cause
          expect(e.cause, isNotNull);
          expect(e.errorCode, isPositive);
        }
      });

      test('throws on invalid host', () async {
        final socket = OracleSocket();

        expect(
          () =>
              socket.connect('invalid.host.that.does.not.exist.example', 1521),
          throwsA(isA<OracleException>()),
        );
      });
    });

    group('close', () {
      test('close on unconnected socket does not throw', () async {
        final socket = OracleSocket();
        await socket.close();
        expect(socket.isConnected, isFalse);
      });

      test('isConnected is false after close', () async {
        final socket = OracleSocket();
        await socket.close();
        expect(socket.isConnected, isFalse);
      });
    });

    group('send', () {
      test('throws OracleException when not connected', () async {
        final socket = OracleSocket();

        expect(
          () => socket.send(Uint8List.fromList([0x01, 0x02, 0x03])),
          throwsA(isA<OracleException>()),
        );
      });

      test('exception includes appropriate error code when not connected',
          () async {
        final socket = OracleSocket();

        try {
          await socket.send(Uint8List.fromList([0x01]));
          fail('Should have thrown');
        } on OracleException catch (e) {
          expect(e.errorCode, isPositive);
          expect(e.message, contains('not connected'));
        }
      });
    });

    group('read', () {
      test('throws OracleException when not connected', () async {
        final socket = OracleSocket();

        expect(
          () => socket.read(10),
          throwsA(isA<OracleException>()),
        );
      });

      test('exception includes byte counts when socket closed', () async {
        final socket = OracleSocket();

        try {
          await socket.read(100);
          fail('Should have thrown');
        } on OracleException catch (e) {
          expect(e.message, contains('100'));
          expect(e.message, contains('0'));
        }
      });
    });

    group('integration tests', () {
      late bool shouldRun;

      setUp(() {
        shouldRun = Platform.environment['RUN_INTEGRATION_TESTS'] == 'true';
      });

      test('connects to Oracle 23ai on localhost', () async {
        if (!shouldRun) {
          markTestSkipped('Integration tests disabled');
          return;
        }

        final socket = OracleSocket();
        await socket.connect('localhost', 1521,
            timeout: const Duration(seconds: 10));
        expect(socket.isConnected, isTrue);
        await socket.close();
        expect(socket.isConnected, isFalse);
      });

      test('times out on non-responsive host', () async {
        if (!shouldRun) {
          markTestSkipped('Integration tests disabled');
          return;
        }

        final socket = OracleSocket();
        // Use a non-routable IP to test timeout
        expect(
          () => socket.connect('10.255.255.1', 1521,
              timeout: const Duration(seconds: 2)),
          throwsA(isA<OracleException>()),
        );
      });
    });
  });
}
