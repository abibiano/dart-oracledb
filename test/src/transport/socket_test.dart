import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/transport/socket.dart';
import 'package:test/test.dart';

import '../../integration/test_helper.dart';

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

    group('liveness (Story 7.4 AC3)', () {
      test('isConnected becomes false after remote close', () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        // Accept then immediately tear the peer down so the client observes a
        // remote close/error via its onDone/onError listeners.
        server.listen((s) => s.destroy());

        final socket = OracleSocket();
        await socket.connect('127.0.0.1', server.port,
            timeout: const Duration(seconds: 2));

        // Let the event loop deliver the close event; liveness is event-driven,
        // not polled, so it flips without us issuing a read.
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (socket.isConnected && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(socket.isConnected, isFalse,
            reason: 'remote close must be reflected without a failed read');
        await socket.close();
        await server.close();
      });

      test('destroy() makes the socket not connected immediately', () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((s) => s.listen((_) {}));

        final socket = OracleSocket();
        await socket.connect('127.0.0.1', server.port,
            timeout: const Duration(seconds: 2));
        expect(socket.isConnected, isTrue);

        socket.destroy();
        expect(socket.isConnected, isFalse);

        // destroy() is idempotent and safe after close.
        socket.destroy();
        await socket.close();
        await server.close();
      });
    });

    // AC13 (Story 7.8): tagged at group level — not file level — so the
    // pure unit tests above stay in the `quality` CI job's
    // `--exclude-tags=integration` run while these Oracle-backed tests are
    // cleanly excluded. The group-level env skip replaces the previous
    // per-test markTestSkipped pattern (AC2 single source of truth).
    group('integration tests',
        tags: 'integration',
        skip: !integrationEnabled ? 'Integration tests disabled' : null, () {
      test('connects to Oracle on the configured host/port', () async {
        final socket = OracleSocket();
        await socket.connect(testHost, testPort,
            timeout: const Duration(seconds: 10));
        expect(socket.isConnected, isTrue);
        await socket.close();
        expect(socket.isConnected, isFalse);
      });

      test('times out on non-responsive host', () async {
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
