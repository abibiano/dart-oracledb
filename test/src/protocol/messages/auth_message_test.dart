/// Unit tests for AUTH_PHASE_ONE and AUTH_PHASE_TWO message encoding/decoding.
///
/// Tests cover:
/// - AuthPhaseOneRequest.toBytes() structure validation
/// - AuthPhaseTwoRequest.toBytes() for both 11g and 12c verifier types
/// - AuthPhaseTwoResponse properties
/// - AuthPhaseOneResponse.decode() edge cases (extended from error path tests)
@Tags(['unit', 'protocol'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/messages/auth_message.dart';
import 'package:test/test.dart';

void main() {
  group('AuthPhaseOneRequest', () {
    group('toBytes() structure', () {
      test('starts with function header (type=3, code=0x76, sequence)', () {
        final request = AuthPhaseOneRequest(
          username: 'testuser',
          clientNonce: Uint8List(16),
          sequence: 1,
        );
        final bytes = request.toBytes();

        expect(bytes[0], equals(ttcMsgTypeFunction),
            reason: 'First byte must be function message type (3)');
        expect(bytes[1], equals(ttcAuthPhaseOne),
            reason: 'Second byte must be AUTH_PHASE_ONE function code (0x76)');
        expect(bytes[2], equals(1),
            reason: 'Third byte must be sequence number');
      });

      test('sequence number is correctly embedded', () {
        final request = AuthPhaseOneRequest(
          username: 'user',
          clientNonce: Uint8List(16),
          sequence: 7,
        );
        final bytes = request.toBytes();
        expect(bytes[2], equals(7));
      });

      test('username bytes are present in output', () {
        const username = 'mytestuser';
        final request = AuthPhaseOneRequest(
          username: username,
          clientNonce: Uint8List(16),
          sequence: 1,
        );
        final bytes = request.toBytes();

        final usernameBytes = utf8.encode(username);
        bool found = false;
        for (int i = 0; i <= bytes.length - usernameBytes.length; i++) {
          bool match = true;
          for (int j = 0; j < usernameBytes.length; j++) {
            if (bytes[i + j] != usernameBytes[j]) {
              match = false;
              break;
            }
          }
          if (match) {
            found = true;
            break;
          }
        }
        expect(found, isTrue, reason: 'Username must be encoded in bytes');
      });

      test('produces non-empty output', () {
        final request = AuthPhaseOneRequest(
          username: 'user',
          clientNonce: Uint8List(16),
          sequence: 1,
        );
        final bytes = request.toBytes();
        expect(bytes.length, greaterThan(10));
      });

      test('different usernames produce different bytes', () {
        final req1 = AuthPhaseOneRequest(
          username: 'alice',
          clientNonce: Uint8List(16),
          sequence: 1,
        );
        final req2 = AuthPhaseOneRequest(
          username: 'bob',
          clientNonce: Uint8List(16),
          sequence: 1,
        );
        expect(req1.toBytes(), isNot(equals(req2.toBytes())));
      });

      test('different sequences produce different bytes', () {
        final clientNonce = Uint8List(16);
        final req1 = AuthPhaseOneRequest(
          username: 'user',
          clientNonce: clientNonce,
          sequence: 1,
        );
        final req2 = AuthPhaseOneRequest(
          username: 'user',
          clientNonce: clientNonce,
          sequence: 2,
        );
        expect(req1.toBytes(), isNot(equals(req2.toBytes())));
      });

      test('empty username produces valid output', () {
        final request = AuthPhaseOneRequest(
          username: '',
          clientNonce: Uint8List(16),
          sequence: 1,
        );
        final bytes = request.toBytes();
        expect(bytes.length, greaterThan(3));
        expect(bytes[0], equals(ttcMsgTypeFunction));
      });

      test('use23aiFormat=false still produces valid function header', () {
        final request = AuthPhaseOneRequest(
          username: 'user',
          clientNonce: Uint8List(16),
          sequence: 1,
        );
        final bytes = request.toBytes(use23aiFormat: false);
        expect(bytes[0], equals(ttcMsgTypeFunction));
        expect(bytes[1], equals(ttcAuthPhaseOne));
      });
    });
  });

  group('AuthPhaseTwoRequest', () {
    final mockSessionKey = Uint8List.fromList(
      utf8.encode('A' * 64), // 64-char hex string
    );
    final mockProof = Uint8List.fromList(
      utf8.encode('B' * 64), // 64-char hex-encoded proof
    );
    final mockSpeedyKey = Uint8List.fromList(
      utf8.encode('C' * 160), // 160-char hex string
    );

    group('toBytes() structure', () {
      test('starts with function header (type=3, code=0x73, sequence)', () {
        final request = AuthPhaseTwoRequest(
          encryptedProof: mockProof,
          sessionKey: mockSessionKey,
          sequence: 2,
        );
        final bytes = request.toBytes();

        expect(bytes[0], equals(ttcMsgTypeFunction),
            reason: 'First byte must be function message type (3)');
        expect(bytes[1], equals(ttcAuthPhaseTwo),
            reason: 'Second byte must be AUTH_PHASE_TWO function code (0x73)');
        expect(bytes[2], equals(2),
            reason: 'Third byte must be sequence number');
      });

      test('sequence number is correctly embedded', () {
        final request = AuthPhaseTwoRequest(
          encryptedProof: mockProof,
          sessionKey: mockSessionKey,
          sequence: 3,
        );
        final bytes = request.toBytes();
        expect(bytes[2], equals(3));
      });

      test('produces non-empty output', () {
        final request = AuthPhaseTwoRequest(
          encryptedProof: mockProof,
          sessionKey: mockSessionKey,
          sequence: 2,
        );
        final bytes = request.toBytes();
        expect(bytes.length, greaterThan(20));
      });

      test('use23aiFormat=true produces larger output than use23aiFormat=false', () {
        final request = AuthPhaseTwoRequest(
          encryptedProof: mockProof,
          sessionKey: mockSessionKey,
          sequence: 2,
        );
        final with23ai = request.toBytes(use23aiFormat: true);
        final without23ai = request.toBytes(use23aiFormat: false);
        expect(with23ai.length, greaterThan(without23ai.length),
            reason: 'Oracle 23.1+ format includes 8-byte token number field');
      });

      test('12c verifier type includes AUTH_PBKDF2_SPEEDY_KEY', () {
        final request = AuthPhaseTwoRequest(
          encryptedProof: mockProof,
          sessionKey: mockSessionKey,
          speedyKey: mockSpeedyKey,
          sequence: 2,
          verifierType: ttcVerifierType12c,
        );
        final bytes = request.toBytes();

        final keyName = utf8.encode('AUTH_PBKDF2_SPEEDY_KEY');
        bool found = false;
        for (int i = 0; i <= bytes.length - keyName.length; i++) {
          bool match = true;
          for (int j = 0; j < keyName.length; j++) {
            if (bytes[i + j] != keyName[j]) {
              match = false;
              break;
            }
          }
          if (match) {
            found = true;
            break;
          }
        }
        expect(found, isTrue, reason: 'AUTH_PBKDF2_SPEEDY_KEY must be in 12c request');
      });

      test('12c verifier type with speedyKey=null omits AUTH_PBKDF2_SPEEDY_KEY', () {
        // Regression test: numPairs must not be incremented when speedyKey is null.
        // Previously, numPairs was set to 7 unconditionally for is12c=true, but only
        // 6 pairs were written when speedyKey==null — causing a wire format desync.
        final request = AuthPhaseTwoRequest(
          encryptedProof: mockProof,
          sessionKey: mockSessionKey,
          sequence: 2,
          verifierType: ttcVerifierType12c,
          // speedyKey intentionally omitted (null)
        );
        final bytes = request.toBytes();

        final keyName = utf8.encode('AUTH_PBKDF2_SPEEDY_KEY');
        bool found = false;
        for (int i = 0; i <= bytes.length - keyName.length; i++) {
          bool match = true;
          for (int j = 0; j < keyName.length; j++) {
            if (bytes[i + j] != keyName[j]) {
              match = false;
              break;
            }
          }
          if (match) {
            found = true;
            break;
          }
        }
        expect(found, isFalse,
            reason: 'AUTH_PBKDF2_SPEEDY_KEY must not appear when speedyKey is null');
      });

      test('AUTH_SESSKEY key name is present in output', () {
        final request = AuthPhaseTwoRequest(
          encryptedProof: mockProof,
          sessionKey: mockSessionKey,
          sequence: 2,
        );
        final bytes = request.toBytes();

        final keyName = utf8.encode('AUTH_SESSKEY');
        bool found = false;
        for (int i = 0; i <= bytes.length - keyName.length; i++) {
          bool match = true;
          for (int j = 0; j < keyName.length; j++) {
            if (bytes[i + j] != keyName[j]) {
              match = false;
              break;
            }
          }
          if (match) {
            found = true;
            break;
          }
        }
        expect(found, isTrue, reason: 'AUTH_SESSKEY must be in AUTH_PHASE_TWO request');
      });

      test('AUTH_PASSWORD key name is present in output', () {
        final request = AuthPhaseTwoRequest(
          encryptedProof: mockProof,
          sessionKey: mockSessionKey,
          sequence: 2,
        );
        final bytes = request.toBytes();

        final keyName = utf8.encode('AUTH_PASSWORD');
        bool found = false;
        for (int i = 0; i <= bytes.length - keyName.length; i++) {
          bool match = true;
          for (int j = 0; j < keyName.length; j++) {
            if (bytes[i + j] != keyName[j]) {
              match = false;
              break;
            }
          }
          if (match) {
            found = true;
            break;
          }
        }
        expect(found, isTrue, reason: 'AUTH_PASSWORD must be in AUTH_PHASE_TWO request');
      });

      test('username bytes appear in output when non-empty', () {
        const username = 'oracleuser';
        final request = AuthPhaseTwoRequest(
          encryptedProof: mockProof,
          sessionKey: mockSessionKey,
          username: username,
          sequence: 2,
        );
        final bytes = request.toBytes();

        final usernameBytes = utf8.encode(username);
        bool found = false;
        for (int i = 0; i <= bytes.length - usernameBytes.length; i++) {
          bool match = true;
          for (int j = 0; j < usernameBytes.length; j++) {
            if (bytes[i + j] != usernameBytes[j]) {
              match = false;
              break;
            }
          }
          if (match) {
            found = true;
            break;
          }
        }
        expect(found, isTrue, reason: 'Username must appear in AUTH_PHASE_TWO request');
      });

      test('different session keys produce different output', () {
        final key1 = Uint8List.fromList(utf8.encode('A' * 64));
        final key2 = Uint8List.fromList(utf8.encode('B' * 64));

        final req1 = AuthPhaseTwoRequest(
          encryptedProof: mockProof,
          sessionKey: key1,
          sequence: 2,
        );
        final req2 = AuthPhaseTwoRequest(
          encryptedProof: mockProof,
          sessionKey: key2,
          sequence: 2,
        );
        expect(req1.toBytes(), isNot(equals(req2.toBytes())));
      });
    });
  });

  group('AuthPhaseTwoResponse', () {
    test('successful response isSuccess=true', () {
      const response = AuthPhaseTwoResponse(isSuccess: true);
      expect(response.isSuccess, isTrue);
      expect(response.errorCode, isNull);
      expect(response.errorMessage, isNull);
    });

    test('failed response isSuccess=false with error code', () {
      const response = AuthPhaseTwoResponse(
        isSuccess: false,
        errorCode: 1017,
        errorMessage: 'invalid username/password',
      );
      expect(response.isSuccess, isFalse);
      expect(response.errorCode, equals(1017));
      expect(response.errorMessage, contains('invalid'));
    });

    test('can have sessionData on success', () {
      const response = AuthPhaseTwoResponse(
        isSuccess: true,
        sessionData: {'AUTH_SESSION_ID': 'abc123'},
      );
      expect(response.sessionData, isNotNull);
      expect(response.sessionData!['AUTH_SESSION_ID'], equals('abc123'));
    });

    test('decode returns failed response for error message type', () {
      final data = Uint8List.fromList([
        0x04, // ttcMsgTypeError (4)
        // Minimal error structure (all zeros for required fields)
        0x00, 0x00, 0x00, 0x00, // call status (UB4)
        0x00, 0x00, // end to end seq (UB2)
        0x00, 0x00, 0x00, 0x00, // current row (UB4)
        0x00, 0x00, // error number (UB2)
        0x00, 0x00, // array elem error 1 (UB2)
        0x00, 0x00, // array elem error 2 (UB2)
        0x00, 0x00, // cursor id (UB2)
        0x00, 0x00, // error position (uint16BE)
        0x00, // sql type
        0x00, // fatal
        0x00, // flags
        0x00, // user cursor options
        0x00, // UPI parameter
        0x00, // warning flag
        0x00, 0x00, 0x00, 0x00, // errorCode (UB4) = 0 → defaults to 1017
      ]);
      final response = AuthPhaseTwoResponse.decode(data);
      expect(response.isSuccess, isFalse);
      expect(response.errorCode, equals(1017),
          reason: 'Error code 0 defaults to 1017 (invalid credentials)');
    });

    test('decode returns success for empty data (no error messages)', () {
      final data = Uint8List(0);
      final response = AuthPhaseTwoResponse.decode(data);
      expect(response.isSuccess, isTrue,
          reason: 'Empty response with no error message type means success');
    });
  });

  group('AuthPhaseOneResponse', () {
    test('toVerifierParams extracts salt correctly from AUTH_VFR_DATA', () {
      const saltHex = '0102030405060708090a0b0c0d0e0f10'; // 16 bytes
      const response = AuthPhaseOneResponse(
        sessionData: {'AUTH_VFR_DATA': saltHex},
        verifierType: 0x4815,
      );
      final params = response.toVerifierParams();
      expect(params.salt.length, equals(16));
      expect(params.salt[0], equals(0x01));
      expect(params.salt[15], equals(0x10));
    });

    test('isPbkdf2 returns true for ttcVerifierType12c (0x4815)', () {
      const response = AuthPhaseOneResponse(
        sessionData: {},
        verifierType: 0x4815,
      );
      final params = response.toVerifierParams();
      expect(params.isPbkdf2, isTrue);
    });

    test('isPbkdf2 returns false for SHA512 verifier', () {
      const response = AuthPhaseOneResponse(
        sessionData: {},
        verifierType: 0x939, // verifierTypeSha512
      );
      final params = response.toVerifierParams();
      expect(params.isSha512, isTrue);
      expect(params.isPbkdf2, isFalse);
    });

    test('toVerifierParams extracts mixing iterations from AUTH_PBKDF2_SDER_COUNT', () {
      const response = AuthPhaseOneResponse(
        sessionData: {
          'AUTH_VFR_DATA': '00000000000000000000000000000000',
          'AUTH_PBKDF2_SDER_COUNT': '3',
        },
        verifierType: 0x4815,
      );
      final params = response.toVerifierParams();
      expect(params.mixingIterations, equals(3));
    });

    test('toVerifierParams handles missing mixing salt gracefully', () {
      const response = AuthPhaseOneResponse(
        sessionData: {'AUTH_VFR_DATA': '00000000000000000000000000000000'},
        verifierType: 0x4815,
      );
      final params = response.toVerifierParams();
      expect(params.mixingSalt, isNull);
    });
  });
}
