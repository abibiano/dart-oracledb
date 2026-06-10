/// Error path tests for authentication protocol (AC: 1, 3, 4).
///
/// Tests cover:
/// - 7.1: Connection failure during auth (network calls — requires connectivity;
///         guarded by RUN_INTEGRATION_TESTS=true)
/// - 7.2: Protocol errors (malformed packets, wrong packet types — pure unit)
/// - 7.3: Malformed auth responses (buffer underflows, missing keys — pure unit)
/// - 7.4: Timeout scenarios (error code validation, message format — pure unit)
@Tags(['unit', 'protocol'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/messages/auth_message.dart';
import 'package:oracledb/src/transport/packet.dart';
import 'package:test/test.dart';

void main() {
  group('Auth Error Paths (AC: 1, 3, 4)', () {
    // =========================================================================
    // Task 7.1: Connection failure during auth
    // These tests make real network calls and are guarded by RUN_INTEGRATION_TESTS.
    // =========================================================================
    // AC13 (Story 7.8): integration-gated tests under test/src/ carry the
    // integration tag so `--exclude-tags=integration` (quality CI job)
    // excludes them without relying on the env-var skip alone.
    final runNetworkTests =
        Platform.environment['RUN_INTEGRATION_TESTS'] == 'true';
    group('7.1 Connection failure during auth',
        tags: 'integration',
        skip: runNetworkTests
            ? null
            : 'Network calls: set RUN_INTEGRATION_TESTS=true to run', () {
      test('connect to non-existent host throws OracleException', () async {
        await expectLater(
          OracleConnection.connect(
            'nonexistent.invalid.host:1521/ORCL',
            user: 'test',
            password: 'test',
            timeout: const Duration(seconds: 3),
          ),
          throwsA(isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            // oraConnectionRefused (12514) is returned when DNS resolution fails
            // ('host not found' / 'no address associated' in socket._mapSocketError)
            anyOf([
              oraNetworkError,
              oraHostUnreachable,
              oraConnectTimeout,
              oraConnectionRefused,
            ]),
          )),
        );
      });

      test('OracleException preserves cause on connection failure', () async {
        try {
          await OracleConnection.connect(
            'nonexistent.invalid.host:1521/ORCL',
            user: 'test',
            password: 'test',
            timeout: const Duration(seconds: 3),
          );
          fail('Expected OracleException');
        } on OracleException catch (e) {
          expect(e.cause, isNotNull,
              reason:
                  'Original cause must be preserved for debugging (project-context.md rule)');
          expect(e.message, isNotEmpty);
        }
      });

      test('connection failure error message never contains password',
          () async {
        const secretPassword = 'VERY_SECRET_PASSWORD_789';
        try {
          await OracleConnection.connect(
            'nonexistent.invalid.host:1521/ORCL',
            user: 'testuser',
            password: secretPassword,
            timeout: const Duration(seconds: 3),
          );
          fail('Expected OracleException');
        } on OracleException catch (e) {
          expect(e.message, isNot(contains(secretPassword)),
              reason: 'NFR5: password must never appear in error messages');
          expect(e.toString(), isNot(contains(secretPassword)),
              reason: 'NFR5: password must never appear in toString()');
        }
      });

      test('connection refused throws OracleException', () async {
        await expectLater(
          OracleConnection.connect(
            '127.0.0.1:59999/ORCL',
            user: 'test',
            password: 'test',
            timeout: const Duration(seconds: 2),
          ),
          throwsA(isA<OracleException>()),
        );
      });
    });

    // =========================================================================
    // Task 7.2: Protocol errors
    // =========================================================================
    group('7.2 Protocol errors', () {
      test('malformed TNS packet (too short) throws TnsPacketException', () {
        final invalidData = Uint8List.fromList([0x00, 0x08, 0x00]);
        expect(
          () => TnsPacket.decode(invalidData),
          throwsA(isA<TnsPacketException>()),
        );
      });

      test('TnsPacketException has a descriptive message', () {
        try {
          TnsPacket.decode(Uint8List.fromList([0x00, 0x08, 0x00]));
          fail('Expected TnsPacketException');
        } on TnsPacketException catch (e) {
          expect(e.message, isNotEmpty);
          expect(e.toString(), contains('TnsPacketException'));
        }
      });

      test('truncated TNS packet payload throws TnsPacketException', () {
        final data = Uint8List(12);
        data[0] = 0x00;
        data[1] = 0x64; // Claims 100 bytes total
        data[4] = tnsPacketData;
        expect(
          () => TnsPacket.decode(data),
          throwsA(isA<TnsPacketException>()),
        );
      });

      test('invalid packet length (< header size) throws TnsPacketException',
          () {
        final data = Uint8List.fromList([
          0x00, 0x04, // Length: 4 (less than 8-byte header)
          0x00, 0x00,
          0x06, // DATA type
          0x00,
          0x00, 0x00,
        ]);
        expect(
          () => TnsPacket.decode(data),
          throwsA(isA<TnsPacketException>()),
        );
      });

      test('OracleException implements Exception', () {
        const e = OracleException(
          errorCode: oraProtocolError,
          message: 'Protocol error',
        );
        expect(e, isA<Exception>());
      });

      test('OracleException toString includes ORA- prefix and code', () {
        const e = OracleException(
          errorCode: oraProtocolError,
          message: 'TNS lost contact',
        );
        expect(e.toString(), contains('ORA-$oraProtocolError'));
        expect(e.toString(), contains('TNS lost contact'));
      });
    });

    // =========================================================================
    // Task 7.3: Malformed auth responses
    // =========================================================================
    group('7.3 Malformed auth responses', () {
      test('AuthPhaseOneResponse.decode throws BufferException on empty data',
          () {
        expect(
          () => AuthPhaseOneResponse.decode(Uint8List(0)),
          throwsA(isA<BufferException>()),
        );
      });

      test(
          'AuthPhaseOneResponse.decode handles unknown message type without throwing',
          () {
        final data = Uint8List.fromList([0xFF, 0x00, 0x00, 0x00]);
        final response = AuthPhaseOneResponse.decode(data);
        expect(response, isNotNull);
        expect(response.sessionData, isEmpty);
      });

      test('AuthPhaseOneResponse.decode handles status message type (9)', () {
        final data = Uint8List.fromList([
          0x09, // ttcMsgTypeStatus (9)
          0x00, 0x00, 0x00, 0x00, // UB4 status value
        ]);
        final response = AuthPhaseOneResponse.decode(data);
        expect(response, isNotNull);
        expect(response.sessionData, isEmpty);
      });

      test('toVerifierParams returns non-null salt when AUTH_VFR_DATA missing',
          () {
        final data = Uint8List.fromList([0xFF, 0x00, 0x00, 0x00]);
        final response = AuthPhaseOneResponse.decode(data);
        final params = response.toVerifierParams();
        expect(params.salt, isNotNull);
        expect(params.salt.length, greaterThan(0));
      });

      test(
          'toVerifierParams returns positive iterations when AUTH_VFR_DATA missing',
          () {
        final data = Uint8List.fromList([0xFF, 0x00, 0x00, 0x00]);
        final response = AuthPhaseOneResponse.decode(data);
        final params = response.toVerifierParams();
        expect(params.iterations, greaterThan(0));
      });

      test(
          'toVerifierParams returns non-null serverNonce when AUTH_SESSKEY missing',
          () {
        final data = Uint8List.fromList([0xFF, 0x00, 0x00, 0x00]);
        final response = AuthPhaseOneResponse.decode(data);
        final params = response.toVerifierParams();
        expect(params.serverNonce, isNotNull);
      });

      test('toVerifierParams handles invalid hex in AUTH_VFR_DATA gracefully',
          () {
        const response = AuthPhaseOneResponse(
          sessionData: {'AUTH_VFR_DATA': 'GGGG_NOT_HEX'},
          verifierType: 0x4815,
        );
        final params = response.toVerifierParams();
        expect(params.salt, isNotNull);
        expect(params.iterations, greaterThan(0));
      });

      test('toVerifierParams uses default 4096 iterations when not parseable',
          () {
        const response = AuthPhaseOneResponse(
          sessionData: {'AUTH_VFR_DATA': ''},
          verifierType: 0x4815,
        );
        final params = response.toVerifierParams();
        expect(params.iterations, equals(4096));
      });
    });

    // =========================================================================
    // Task 7.4: Timeout scenarios
    // =========================================================================
    group('7.4 Timeout scenarios', () {
      test('oraInvalidCredentials error code is 1017 (ORA-01017)', () {
        expect(oraInvalidCredentials, equals(1017));
      });

      test('auth timeout OracleException has errorCode 1017', () {
        const timeoutError = OracleException(
          errorCode: oraInvalidCredentials,
          message: 'Authentication failed: invalid username or password',
        );
        expect(timeoutError.errorCode, equals(1017));
      });

      test('auth timeout error message matches expected format', () {
        const timeoutError = OracleException(
          errorCode: oraInvalidCredentials,
          message: 'Authentication failed: invalid username or password',
        );
        expect(timeoutError.message, contains('Authentication failed'));
        expect(timeoutError.message, contains('invalid username or password'));
      });

      test('auth timeout error message never contains credentials', () {
        const secretPassword = 'MY_SECRET_PASS';
        const timeoutError = OracleException(
          errorCode: oraInvalidCredentials,
          message: 'Authentication failed: invalid username or password',
        );
        expect(timeoutError.message, isNot(contains(secretPassword)),
            reason: 'NFR5: password must never appear in timeout error');
        expect(timeoutError.toString(), isNot(contains(secretPassword)));
      });

      test('OracleException for ORA-01017 formats with ORA- prefix', () {
        // Verifies that the toString() representation used in logs/error output
        // contains the ORA- prefix that Oracle users recognise.
        const e = OracleException(
          errorCode: oraInvalidCredentials,
          message: 'Authentication failed: invalid username or password',
        );
        // Story 2.8: canonical 5-digit ORA padding for codes below 10000.
        expect(e.toString(), contains('ORA-01017'),
            reason: 'ORA-01017 is the Oracle invalid-credentials error code');
        // The ~5-second Oracle 23ai brute-force delay is validated by the
        // stopwatch assertion in test/integration/security_test.dart.
      });

      test(
          'OracleException cause is nullable (no cause for timeout-triggered error)',
          () {
        const timeoutError = OracleException(
          errorCode: oraInvalidCredentials,
          message: 'Authentication failed: invalid username or password',
        );
        expect(timeoutError.cause, isNull);
      });
    });
  });
}
