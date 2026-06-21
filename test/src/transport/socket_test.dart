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

    // Deterministic coverage for the socket-error → Oracle-code mapping. Uses
    // the `mapSocketError` test seam with synthetic SocketExceptions so we can
    // pin the OSError errno precisely (a live failure cannot guarantee which
    // errno the OS/VM surfaces). Platform-robust: the errno cases assert the
    // whole EHOSTUNREACH/ENETUNREACH union (BSD/macOS + Linux), so the test is
    // valid regardless of host OS or Dart's errno normalization.
    group('mapSocketError', () {
      // EHOSTUNREACH = 65 (BSD/macOS) / 113 (Linux) / 10065 (Windows WSA);
      // ENETUNREACH  = 51 (BSD/macOS) / 101 (Linux) / 10051 (Windows WSA).
      // The full union is asserted so the mapping is correct on every supported
      // platform regardless of which OS the test happens to run on.
      for (final errno in [65, 113, 10065, 51, 101, 10051]) {
        test('errno $errno (host/network unreachable) -> oraHostUnreachable',
            () {
          final e = SocketException(
            'No route to host',
            osError: OSError('No route to host', errno),
          );
          expect(OracleSocket.mapSocketError(e), oraHostUnreachable);
        });
      }

      test('errno-based mapping ignores case of the message', () {
        // Message that matches none of the string branches, errno carries the
        // signal.
        const e = SocketException(
          'NETWORK IS UNREACHABLE',
          osError: OSError('Network is unreachable', 101),
        );
        expect(OracleSocket.mapSocketError(e), oraHostUnreachable);
      });

      test('"timed out" message wins even if errno present -> oraConnectTimeout',
          () {
        // dart:io reports connect timeouts as "Connection timed out…" with an
        // errno (110 Linux / 60 macOS) that is NOT in the unreachable set, so
        // the message branch must keep returning the timeout code.
        const e = SocketException(
          'Connection timed out, host: 10.255.255.1, port: 1521',
          osError: OSError('Connection timed out', 110),
        );
        expect(OracleSocket.mapSocketError(e), oraConnectTimeout);
      });

      test(
          'message branch wins over an unreachable errno '
          '(precedence guard) -> oraConnectTimeout', () {
        // Guards the ordering invariant directly: even when the errno IS in the
        // unreachable set, an explicit "timed out" message must NOT be
        // re-classified as host-unreachable. Catches an accidental reorder of
        // the message vs errno checks.
        const e = SocketException(
          'Connection timed out',
          osError: OSError('Connection timed out', 113), // EHOSTUNREACH (Linux)
        );
        expect(OracleSocket.mapSocketError(e), oraConnectTimeout);
      });

      test('"connection refused" message -> oraHostUnreachable (unchanged)', () {
        // Existing behavior: refused errno (61 macOS / 111 Linux) is not in the
        // unreachable set, message match drives the result.
        const e = SocketException(
          'Connection refused',
          osError: OSError('Connection refused', 61),
        );
        expect(OracleSocket.mapSocketError(e), oraHostUnreachable);
      });

      test('host-not-found message -> oraConnectionRefused (unchanged)', () {
        const e = SocketException(
          'Failed host lookup: bad.host (No address associated with hostname)',
        );
        expect(OracleSocket.mapSocketError(e), oraConnectionRefused);
      });

      test('connection reset message -> oraProtocolError (unchanged)', () {
        const e = SocketException(
          'Connection reset by peer',
          osError: OSError('Connection reset by peer', 54),
        );
        expect(OracleSocket.mapSocketError(e), oraProtocolError);
      });

      test('unknown message with no errno -> oraNetworkError (fallback)', () {
        const e = SocketException('Something unexpected happened');
        expect(OracleSocket.mapSocketError(e), oraNetworkError);
      });

      test('unrelated errno (not unreachable) -> oraNetworkError (fallback)',
          () {
        // An errno outside the unreachable set must not be misclassified.
        const e = SocketException(
          'Some other socket failure',
          osError: OSError('Some other socket failure', 22), // EINVAL
        );
        expect(OracleSocket.mapSocketError(e), oraNetworkError);
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

    group('liveness', () {
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

    // Tagged at group level — not file level — so the pure unit tests above
    // stay in the `quality` CI job's `--exclude-tags=integration` run while
    // these Oracle-backed tests are cleanly excluded. The group-level env skip
    // replaces the previous per-test markTestSkipped pattern (single source of
    // truth).
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
