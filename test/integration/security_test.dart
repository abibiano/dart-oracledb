/// Security tests (NFR5) - Credential protection validation
///
/// Validates that authentication code NEVER exposes passwords or usernames
/// in logs, error messages, or exceptions.
///
/// Background: Epic 1 had 3 security violations caught in review:
/// - Story 1.4: Password in logs
/// - Story 1.5: Credentials in error messages
/// - Story 1.8: Username exposure
@Tags(['integration', 'security'])
library;

import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:oracledb/dart_oracledb.dart';
import 'package:test/test.dart';

void main() {
  final runIntegrationTests =
      Platform.environment['RUN_INTEGRATION_TESTS'] == 'true';

  if (!runIntegrationTests) {
    test('Security tests require RUN_INTEGRATION_TESTS=true', () {
      Logger.root.info('Skipping security integration tests - set RUN_INTEGRATION_TESTS=true');
    });
    return;
  }

  // Capture all log output
  final logMessages = <String>[];
  late StreamSubscription<LogRecord> logSubscription;

  setUp(() {
    logMessages.clear();
    Logger.root.level = Level.ALL; // Capture everything, including FINE
    logSubscription = Logger.root.onRecord.listen((record) {
      final message =
          '${record.level.name}: ${record.loggerName}: ${record.message}';
      logMessages.add(message);
    });
  });

  tearDown(() async {
    await logSubscription.cancel();
    logMessages.clear();
  });

  group('NFR5: Credential Protection (AC3, AC4)', () {
    const oracleHost = 'localhost';
    const oraclePort = 1521;
    const oracleService = 'FREEPDB1';
    const validUser = 'system';
    const validPassword = 'testpassword';
    const invalidPassword = 'WRONG_PASSWORD';
    const testSecret = 'SECRET_PASSWORD_123';

    test('Password never appears in logs (successful auth)', () async {
      final conn = await OracleConnection.connect(
        '$oracleHost:$oraclePort/$oracleService',
        user: validUser,
        password: validPassword,
      );

      await conn.close();

      // Verify password not in any log message
      for (final logMsg in logMessages) {
        expect(logMsg, isNot(contains(validPassword)),
            reason: 'Password found in log: $logMsg');
      }
    });

    test('Password never appears in logs (failed auth)', () async {
      try {
        await OracleConnection.connect(
          '$oracleHost:$oraclePort/$oracleService',
          user: validUser,
          password: invalidPassword,
        );
        fail('Should have thrown OracleException');
      } on OracleException catch (e) {
        expect(e.errorCode, equals(1017));
      }

      // Verify password not in any log message
      for (final logMsg in logMessages) {
        expect(logMsg, isNot(contains(invalidPassword)),
            reason: 'Password found in log: $logMsg');
      }
    });

    test('Username not exposed in error messages', () async {
      try {
        await OracleConnection.connect(
          '$oracleHost:$oraclePort/$oracleService',
          user: validUser,
          password: invalidPassword,
        );
        fail('Should have thrown OracleException');
      } on OracleException catch (e) {
        // Error message should NOT contain username
        expect(e.message, isNot(contains(validUser)),
            reason: 'Username should not be in error message');

        // Error message should be generic
        expect(e.message, contains('Authentication failed'));
      }
    });

    test('Credentials never in error messages', () async {
      try {
        await OracleConnection.connect(
          '$oracleHost:$oraclePort/$oracleService',
          user: validUser,
          password: testSecret,
        );
        fail('Should have thrown OracleException');
      } on OracleException catch (e) {
        // Verify neither username nor password in error
        expect(e.message, isNot(contains(validUser)),
            reason: 'Username found in error message');
        expect(e.message, isNot(contains(testSecret)),
            reason: 'Password found in error message');
        expect(e.toString(), isNot(contains(testSecret)),
            reason: 'Password found in exception toString');
      }

      // Double-check logs
      for (final logMsg in logMessages) {
        expect(logMsg, isNot(contains(testSecret)),
            reason: 'Password found in log: $logMsg');
      }
    });

    test('Wrong password timeout (~5s) with no credential exposure', () async {
      final stopwatch = Stopwatch()..start();
      late OracleException authError;

      try {
        await OracleConnection.connect(
          '$oracleHost:$oraclePort/$oracleService',
          user: validUser,
          password: testSecret,
        );
        fail('Should have thrown OracleException');
      } on OracleException catch (e) {
        authError = e;
      } finally {
        stopwatch.stop();
      }

      // Assertions run after finally — stopwatch is always stopped before these
      expect(stopwatch.elapsed.inSeconds, inInclusiveRange(4, 6),
          reason: 'Wrong password should timeout in ~5 seconds');
      expect(authError.errorCode, equals(1017));
      expect(authError.message, isNot(contains(testSecret)));
      expect(authError.message, isNot(contains(validUser)));

      for (final logMsg in logMessages) {
        expect(logMsg, isNot(contains(testSecret)),
            reason: 'Password found in log after timeout: $logMsg');
      }
    });

    test('Error message sanitization for authentication failures', () async {
      final testCases = [
        {'user': 'testuser', 'password': 'testpass123'},
        {'user': 'admin', 'password': 'P@ssw0rd!'},
        {'user': 'dbadmin', 'password': 'Secret123'},
      ];

      for (final testCase in testCases) {
        final user = testCase['user']!;
        final password = testCase['password']!;

        try {
          await OracleConnection.connect(
            '$oracleHost:$oraclePort/$oracleService',
            user: user,
            password: password,
          );
          fail(
              'Expected authentication to fail for user "$user" but it succeeded — '
              'credential-protection assertions were skipped');
        } on OracleException catch (e) {
          // Verify credentials NOT in error
          expect(e.message, isNot(contains(password)),
              reason: 'Password "$password" found in error for user "$user"');

          // Generic error message only
          expect(e.message, matches(r'Authentication failed'));
        }
      }

      // Verify no credentials in any logs
      for (final testCase in testCases) {
        final password = testCase['password']!;
        for (final logMsg in logMessages) {
          expect(logMsg, isNot(contains(password)),
              reason: 'Password found in log: $logMsg');
        }
      }
    });
  });
}
