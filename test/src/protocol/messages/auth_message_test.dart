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

import 'package:oracledb/src/crypto/verifier.dart';
import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/messages/auth_message.dart';
import 'package:test/test.dart';

/// Returns true if [key]'s UTF-8 bytes appear anywhere in [bytes].
bool _containsKey(Uint8List bytes, String key) {
  final needle = utf8.encode(key);
  for (var i = 0; i <= bytes.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

/// Decodes the key-value pair count from an AUTH_PHASE_TWO message built with
/// the default `use23aiFormat: true` (so an 8-byte token field is present).
int _decodeNumPairs(Uint8List bytes) {
  final buf = ReadBuffer(bytes);
  buf.readUint8(); // message type (3)
  buf.readUint8(); // function code (0x73)
  buf.readUint8(); // sequence
  buf.readUB8(); // 23ai token number (0)
  buf.readUint8(); // username-present flag
  buf.readUB4(); // username byte length
  buf.readUB4(); // auth mode flags
  buf.readUint8(); // unknown (1)
  return buf.readUB4(); // number of key-value pairs
}

/// Builds a minimal AUTH_PHASE_ONE TTC ERROR (0x04) body with the given
/// extended error code and no trailing message.
Uint8List _buildPhaseOneError({required int errorCode}) {
  final buffer = WriteBuffer();
  buffer.writeUint8(ttcMsgTypeError); // 4
  buffer.writeUB4(0); // call status
  buffer.writeUB2(0); // end-to-end seq
  buffer.writeUB4(0); // current row
  buffer.writeUB2(0); // error number (short)
  buffer.writeUB2(0); // array elem error
  buffer.writeUB2(0); // array elem error
  buffer.writeUB2(0); // cursor id
  buffer.writeUint16BE(0); // error position
  buffer.writeUint8(0); // sql type
  buffer.writeUint8(0); // fatal
  buffer.writeUint8(0); // flags
  buffer.writeUint8(0); // user cursor options
  buffer.writeUint8(0); // UPI parameter
  buffer.writeUint8(0); // warning flag
  buffer.writeUB4(errorCode); // extended error code
  return buffer.toBytes();
}

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

      test('use23aiFormat=true produces larger output than use23aiFormat=false',
          () {
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
        expect(found, isTrue,
            reason: 'AUTH_PBKDF2_SPEEDY_KEY must be in 12c request');
      });

      test('12c verifier type with speedyKey=null omits AUTH_PBKDF2_SPEEDY_KEY',
          () {
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
            reason:
                'AUTH_PBKDF2_SPEEDY_KEY must not appear when speedyKey is null');
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
        expect(found, isTrue,
            reason: 'AUTH_SESSKEY must be in AUTH_PHASE_TWO request');
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
        expect(found, isTrue,
            reason: 'AUTH_PASSWORD must be in AUTH_PHASE_TWO request');
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
        expect(found, isTrue,
            reason: 'Username must appear in AUTH_PHASE_TWO request');
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

    test(
        'toVerifierParams extracts mixing iterations from AUTH_PBKDF2_SDER_COUNT',
        () {
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

  group('Speedy-key wire encoding (AC6)', () {
    final mockSessionKey = Uint8List.fromList(utf8.encode('A' * 64));
    final mockProof = Uint8List.fromList(utf8.encode('B' * 64));
    final mockSpeedyKey = Uint8List.fromList(utf8.encode('C' * 160));

    test('12c verifier (0x4815) writes the speedy key and counts 7 pairs', () {
      final request = AuthPhaseTwoRequest(
        encryptedProof: mockProof,
        sessionKey: mockSessionKey,
        speedyKey: mockSpeedyKey,
        sequence: 2,
        verifierType: ttcVerifierType12c, // 0x4815
      );
      final bytes = request.toBytes();
      expect(_containsKey(bytes, 'AUTH_PBKDF2_SPEEDY_KEY'), isTrue);
      expect(_decodeNumPairs(bytes), equals(7),
          reason: 'base 6 pairs + the speedy key pair');
    });

    test(
        '0xB92 omits the speedy key and counts 6 pairs even if one is supplied',
        () {
      // Decision (AC6): 0xB92 (verifierTypePbkdf2) is an internal key-derivation
      // routing flag, NOT a wire verifier type. node-oracledb only emits the
      // speedy key for the 12c verifier (0x4815), so 0xB92 must omit it. A
      // speedyKey is deliberately supplied here to prove it is ignored.
      final request = AuthPhaseTwoRequest(
        encryptedProof: mockProof,
        sessionKey: mockSessionKey,
        speedyKey: mockSpeedyKey,
        sequence: 2,
        verifierType: verifierTypePbkdf2, // 0xB92
      );
      final bytes = request.toBytes();
      expect(_containsKey(bytes, 'AUTH_PBKDF2_SPEEDY_KEY'), isFalse);
      expect(_decodeNumPairs(bytes), equals(6),
          reason: 'pair count must match the pairs actually written');
    });

    test('12c verifier with null speedy key counts 6 pairs (no desync)', () {
      final request = AuthPhaseTwoRequest(
        encryptedProof: mockProof,
        sessionKey: mockSessionKey,
        sequence: 2,
        verifierType: ttcVerifierType12c,
        // speedyKey omitted
      );
      final bytes = request.toBytes();
      expect(_containsKey(bytes, 'AUTH_PBKDF2_SPEEDY_KEY'), isFalse);
      expect(_decodeNumPairs(bytes), equals(6));
    });
  });

  group('AuthPhaseOneResponse TTC ERROR fail-loud (AC9)', () {
    test('decode raises OracleException carrying the parsed Oracle error code',
        () {
      final data = _buildPhaseOneError(errorCode: oraAccountLocked); // 28000
      expect(
        () => AuthPhaseOneResponse.decode(data),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraAccountLocked)),
        reason: 'AC9: a TTC ERROR in AUTH_PHASE_ONE must fail loud, not return '
            'empty session data',
      );
    });

    test('decode error with extended code 0 defaults to ORA-01017', () {
      final data = _buildPhaseOneError(errorCode: 0);
      expect(
        () => AuthPhaseOneResponse.decode(data),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraInvalidCredentials)),
      );
    });

    test('decode error message names the phase and leaks no secrets', () {
      final data = _buildPhaseOneError(errorCode: oraInvalidCredentials);
      try {
        AuthPhaseOneResponse.decode(data);
        fail('expected OracleException');
      } on OracleException catch (e) {
        expect(e.message, contains('AUTH_PHASE_ONE'));
        expect(e.message, contains('ORA-$oraInvalidCredentials'));
      }
    });
  });

  group('Verifier parameter fallbacks are length-safe (AC5)', () {
    test('missing AUTH_VFR_DATA → 16-byte salt fallback', () {
      const response =
          AuthPhaseOneResponse(sessionData: {}, verifierType: 0x4815);
      final params = response.toVerifierParams();
      expect(params.salt.length, equals(16));
    });

    test('missing AUTH_SESSKEY → 16-byte serverNonce fallback', () {
      const response =
          AuthPhaseOneResponse(sessionData: {}, verifierType: 0x4815);
      final params = response.toVerifierParams();
      expect(params.serverNonce.length, equals(16));
    });

    test('malformed AUTH_SESSKEY hex → 16-byte serverNonce fallback, no leak',
        () {
      const response = AuthPhaseOneResponse(
        sessionData: {'AUTH_SESSKEY': 'ZZZZ_not_hex'},
        verifierType: 0x4815,
      );
      final params = response.toVerifierParams();
      expect(params.serverNonce.length, equals(16),
          reason:
              'malformed server key must fall back, not throw a parse error');
    });

    test('malformed AUTH_PBKDF2_CSK_SALT hex → mixingSalt stays null', () {
      const response = AuthPhaseOneResponse(
        sessionData: {'AUTH_PBKDF2_CSK_SALT': 'GG_not_hex'},
        verifierType: 0x4815,
      );
      final params = response.toVerifierParams();
      expect(params.mixingSalt, isNull);
    });

    test('mixingSalt and mixingIterations are null unless supplied', () {
      const response =
          AuthPhaseOneResponse(sessionData: {}, verifierType: 0x4815);
      final params = response.toVerifierParams();
      expect(params.mixingSalt, isNull);
      expect(params.mixingIterations, isNull);
    });

    test('valid AUTH_PBKDF2_CSK_SALT decodes to its byte length', () {
      const response = AuthPhaseOneResponse(
        sessionData: {
          'AUTH_PBKDF2_CSK_SALT': '0102030405060708090a0b0c0d0e0f10',
        },
        verifierType: 0x4815,
      );
      final params = response.toVerifierParams();
      expect(params.mixingSalt, isNotNull);
      expect(params.mixingSalt!.length, equals(16));
    });
  });
}
