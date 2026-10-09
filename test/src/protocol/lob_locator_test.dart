/// Unit tests for [LobLocator]'s flag-byte decoding (Story 12.2 AC2).
///
/// The temporary-LOB bit drives whether `OracleLob.close()` queues the locator
/// for the transport's `FREE_TEMP | ARRAY` piggyback, and that piggyback rides
/// an unrelated statement's message — so a false positive corrupts an innocent
/// execute. These tests pin the decode exactly: only bit 0x01 of flag byte 4,
/// bounds-guarded, plus the explicit driver-created override.
library;

import 'dart:typed_data';

import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/lob_locator.dart';
import 'package:test/test.dart';

/// A 40-byte locator buffer with [mutations] applied (offset → byte value).
Uint8List _locatorBytes([Map<int, int> mutations = const <int, int>{}]) {
  final bytes = Uint8List(tnsLobLocatorBufferSize);
  mutations.forEach((offset, value) => bytes[offset] = value);
  return bytes;
}

LobLocator _clobFrom(Uint8List bytes, {bool isTemporary = false}) => LobLocator(
  locator: bytes,
  oracleType: oraTypeClob,
  length: 0,
  chunkSize: 0,
  isTemporary: isTemporary,
);

void main() {
  group('LobLocator.isTemporary flag decode', () {
    test('is false for an all-zero (plain fetched) locator', () {
      expect(_clobFrom(_locatorBytes()).isTemporary, isFalse);
    });

    test('is true when flag byte 4 carries the TEMP bit', () {
      final bytes = _locatorBytes({tnsLobLocOffsetFlag4: tnsLobLocFlagsTemp});
      expect(_clobFrom(bytes).isTemporary, isTrue);
    });

    test('is true when the TEMP bit rides alongside other flag-4 bits', () {
      // Real servers set several flag-4 bits; the decode must mask, not compare.
      final bytes = _locatorBytes({
        tnsLobLocOffsetFlag4: tnsLobLocFlagsTemp | 0x20 | 0x80,
      });
      expect(_clobFrom(bytes).isTemporary, isTrue);
    });

    test('is false when flag byte 4 has other bits but not TEMP', () {
      final bytes = _locatorBytes({tnsLobLocOffsetFlag4: 0xFE}); // 0x01 clear
      expect(_clobFrom(bytes).isTemporary, isFalse);
    });

    test('the ABSTRACT bit at flag byte 1 does NOT make a locator temporary '
        "(node's JS operator-precedence clause deliberately not ported)", () {
      final bytes = _locatorBytes({
        tnsLobLocOffsetFlag1: tnsLobLocFlagsAbstract,
      });
      expect(_clobFrom(bytes).isTemporary, isFalse);
    });

    test('the BLOB bit at flag byte 1 does NOT make a locator temporary '
        "(node's clause effectively tests exactly this bit)", () {
      // node-oracledb's `locator[FLAG_1] & ABSTRACT === ABSTRACT` evaluates as
      // `locator[FLAG_1] & 1` — i.e. TNS_LOB_LOC_FLAGS_BLOB — which would mark
      // every fetched BLOB temporary. Porting that would queue innocent BLOB
      // locators for FREE_TEMP on an unrelated statement's piggyback.
      final bytes = _locatorBytes({tnsLobLocOffsetFlag1: tnsLobLocFlagsBlob});
      expect(
        LobLocator(
          locator: bytes,
          oracleType: oraTypeBlob,
          length: 4,
          chunkSize: 0,
        ).isTemporary,
        isFalse,
      );
    });

    test('a locator shorter than the flag-4 offset reports false (bounds '
        'guard, never a range error)', () {
      for (var len = 0; len <= tnsLobLocOffsetFlag4; len++) {
        final short = Uint8List(len);
        if (len > 0) short.fillRange(0, len, 0xFF); // every bit set
        expect(
          _clobFrom(short).isTemporary,
          isFalse,
          reason: 'a $len-byte locator cannot carry flag byte 4',
        );
      }
      // One byte longer: the flag byte now exists and is honored.
      final justLongEnough = Uint8List(tnsLobLocOffsetFlag4 + 1)
        ..fillRange(0, tnsLobLocOffsetFlag4 + 1, 0xFF);
      expect(_clobFrom(justLongEnough).isTemporary, isTrue);
    });

    test('the driver-created override reports true even with zeroed flags', () {
      // A freshly CREATE_TEMP'd locator is known temporary from the REQUEST;
      // it must never depend on how the server echoes its flag bytes.
      expect(_clobFrom(_locatorBytes(), isTemporary: true).isTemporary, isTrue);
      // Even an empty buffer (the bounds guard would otherwise say false).
      expect(
        LobLocator(
          locator: Uint8List(0),
          oracleType: oraTypeClob,
          length: 0,
          chunkSize: 0,
          isTemporary: true,
        ).isTemporary,
        isTrue,
      );
    });

    test('isTemporary is orthogonal to usesVarLengthCharset', () {
      final varLen = _locatorBytes({
        tnsLobLocOffsetFlag3: tnsLobLocFlagsVarLengthCharset,
      });
      final loc = _clobFrom(varLen);
      expect(loc.usesVarLengthCharset, isTrue);
      expect(loc.isTemporary, isFalse);

      final both = _locatorBytes({
        tnsLobLocOffsetFlag3: tnsLobLocFlagsVarLengthCharset,
        tnsLobLocOffsetFlag4: tnsLobLocFlagsTemp,
      });
      final loc2 = _clobFrom(both);
      expect(loc2.usesVarLengthCharset, isTrue);
      expect(loc2.isTemporary, isTrue);
    });

    test('toString reports the temporary state', () {
      expect(
        _clobFrom(_locatorBytes(), isTemporary: true).toString(),
        contains('temporary: true'),
      );
    });
  });

  group('locator flag constants match node-oracledb', () {
    test('offsets and bit values', () {
      // reference/node-oracledb/lib/thin/protocol/constants.js
      expect(tnsLobLocOffsetFlag1, equals(4));
      expect(tnsLobLocOffsetFlag3, equals(6));
      expect(tnsLobLocOffsetFlag4, equals(7));
      expect(tnsLobLocFlagsTemp, equals(0x01));
      expect(tnsLobLocFlagsAbstract, equals(0x40));
    });
  });
}
