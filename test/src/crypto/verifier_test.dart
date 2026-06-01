import 'dart:convert';
import 'dart:typed_data';

import 'package:oracledb/src/crypto/verifier.dart';
import 'package:test/test.dart';

void main() {
  group('SHA512 verifier', () {
    test('sha512Hash produces 64-byte hash', () {
      final input = utf8.encode('test input');
      final hash = sha512Hash(Uint8List.fromList(input));

      expect(hash.length, equals(64)); // 512 bits = 64 bytes
    });

    test('sha512Hash is deterministic', () {
      final input = Uint8List.fromList(utf8.encode('consistent input'));
      final hash1 = sha512Hash(input);
      final hash2 = sha512Hash(input);

      expect(hash1, equals(hash2));
    });

    test('sha512Hash produces different output for different input', () {
      final input1 = Uint8List.fromList(utf8.encode('input one'));
      final input2 = Uint8List.fromList(utf8.encode('input two'));
      final hash1 = sha512Hash(input1);
      final hash2 = sha512Hash(input2);

      expect(hash1, isNot(equals(hash2)));
    });

    test('sha512Hash handles empty input', () {
      final hash = sha512Hash(Uint8List(0));
      expect(hash.length, equals(64));
    });
  });

  group('PBKDF2 verifier', () {
    test('pbkdf2Sha512 derives key of specified length', () {
      final password = Uint8List.fromList(utf8.encode('password'));
      final salt = Uint8List.fromList(utf8.encode('salt'));

      final key = pbkdf2Sha512(
        password: password,
        salt: salt,
        iterations: 1000,
        keyLength: 64,
      );

      expect(key.length, equals(64));
    });

    test('pbkdf2Sha512 is deterministic with same parameters', () {
      final password = Uint8List.fromList(utf8.encode('password'));
      final salt = Uint8List.fromList(utf8.encode('salt'));

      final key1 = pbkdf2Sha512(
        password: password,
        salt: salt,
        iterations: 1000,
        keyLength: 32,
      );

      final key2 = pbkdf2Sha512(
        password: password,
        salt: salt,
        iterations: 1000,
        keyLength: 32,
      );

      expect(key1, equals(key2));
    });

    test('pbkdf2Sha512 produces different keys with different salt', () {
      final password = Uint8List.fromList(utf8.encode('password'));
      final salt1 = Uint8List.fromList(utf8.encode('salt1'));
      final salt2 = Uint8List.fromList(utf8.encode('salt2'));

      final key1 = pbkdf2Sha512(
        password: password,
        salt: salt1,
        iterations: 1000,
        keyLength: 32,
      );

      final key2 = pbkdf2Sha512(
        password: password,
        salt: salt2,
        iterations: 1000,
        keyLength: 32,
      );

      expect(key1, isNot(equals(key2)));
    });

    test('pbkdf2Sha512 produces different keys with different iterations', () {
      final password = Uint8List.fromList(utf8.encode('password'));
      final salt = Uint8List.fromList(utf8.encode('salt'));

      final key1 = pbkdf2Sha512(
        password: password,
        salt: salt,
        iterations: 1000,
        keyLength: 32,
      );

      final key2 = pbkdf2Sha512(
        password: password,
        salt: salt,
        iterations: 2000,
        keyLength: 32,
      );

      expect(key1, isNot(equals(key2)));
    });
  });

  group('Oracle verifier types', () {
    test('verifierTypeSha512 constant is correct', () {
      expect(verifierTypeSha512, equals(0x939)); // 2361
    });

    test('verifierTypePbkdf2 constant is correct', () {
      expect(verifierTypePbkdf2, equals(0xB92)); // 2962
    });
  });

  group('Utility functions', () {
    test('xorBytes produces correct XOR of two byte arrays', () {
      final a = Uint8List.fromList([0xFF, 0x00, 0xAA]);
      final b = Uint8List.fromList([0x0F, 0xF0, 0x55]);
      final result = xorBytes(a, b);

      expect(result, equals(Uint8List.fromList([0xF0, 0xF0, 0xFF])));
    });

    test('xorBytes with equal length arrays', () {
      final a = Uint8List.fromList([1, 2, 3, 4]);
      final b = Uint8List.fromList([4, 3, 2, 1]);
      final result = xorBytes(a, b);

      expect(result.length, equals(4));
      expect(result, equals(Uint8List.fromList([5, 1, 1, 5])));
    });

    // AC2: the length-mismatch guard (verifier.dart lines 51-54) was the
    // uncovered defensive branch flagged by LCOV. Exercise it directly.
    test('xorBytes throws ArgumentError when lengths differ', () {
      final a = Uint8List.fromList([1, 2, 3]);
      final b = Uint8List.fromList([1, 2]);
      expect(() => xorBytes(a, b), throwsA(isA<ArgumentError>()));
    });

    test('xorBytes mismatch error message reports both lengths', () {
      final a = Uint8List(5);
      final b = Uint8List(3);
      try {
        xorBytes(a, b);
        fail('expected ArgumentError');
      } on ArgumentError catch (e) {
        expect(e.message.toString(), contains('5'));
        expect(e.message.toString(), contains('3'));
      }
    });

    test('xorBytes mismatch is symmetric (shorter first)', () {
      expect(() => xorBytes(Uint8List(2), Uint8List(8)),
          throwsA(isA<ArgumentError>()));
    });
  });
}
