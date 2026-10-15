/// Unit tests for [LobLocator]'s flag-byte decoding (Story 12.2 AC2, DW-122).
///
/// The temporary-LOB decision drives whether `OracleLob.close()` and the
/// materialize path queue the locator for the transport's `FREE_TEMP | ARRAY`
/// piggyback, and that piggyback rides an unrelated statement's message. These
/// tests pin the decode exactly: bit 0x01 of flag byte 4 (TEMP) OR bit 0x40 of
/// flag byte 1 (ABSTRACT — a server-expression LOB, DW-122), each
/// bounds-guarded, plus the explicit driver-created override. The BLOB
/// storage bit (0x01 of flag byte 1, which node-oracledb's precedence bug
/// effectively tests) never counts.
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

    test('the ABSTRACT bit at flag byte 1 makes a locator temporary (DW-122, '
        'python-oracledb free_lob parity)', () {
      final bytes = _locatorBytes({
        tnsLobLocOffsetFlag1: tnsLobLocFlagsAbstract,
      });
      expect(_clobFrom(bytes).isTemporary, isTrue);
    });

    test('the MEASURED server-expression flag bytes are temporary and the '
        'measured table-row / EMPTY_CLOB bytes are not', () {
      // Flag byte 1 / flag byte 4 exactly as dumped live on Oracle 23ai AND
      // 21c (DW-122). Each expression value held one
      // V$TEMPORARY_LOBS.ABSTRACT_LOBS entry until freed; the others held none.
      const cases = <(String, int, int, int, bool)>[
        ('TO_CLOB / inline-VARCHAR CLOB OUT', oraTypeClob, 0xC2, 0x00, true),
        ('TO_BLOB / inline-RAW BLOB OUT', oraTypeBlob, 0xC1, 0x00, true),
        ('TO_NCLOB expression', oraTypeClob, 0xC4, 0x00, true),
        ('created temporary CLOB (23ai echo)', oraTypeClob, 0x82, 0x03, true),
        ('p_out := p_in echo of a temp LOB', oraTypeClob, 0x02, 0x03, true),
        ('table-row CLOB', oraTypeClob, 0x02, 0x00, false),
        ('table-row BLOB', oraTypeBlob, 0x01, 0x00, false),
        ('EMPTY_CLOB() value', oraTypeClob, 0x00, 0x00, false),
      ];
      for (final (name, type, flag1, flag4, expected) in cases) {
        final loc = LobLocator(
          locator: _locatorBytes({
            tnsLobLocOffsetFlag1: flag1,
            tnsLobLocOffsetFlag4: flag4,
          }),
          oracleType: type,
          length: 1,
          chunkSize: 0,
        );
        expect(loc.isTemporary, expected, reason: name);
      }
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

    test('each flag read is bounds-guarded independently (never a range '
        'error)', () {
      // Too short for EITHER flag byte: false even with every bit set.
      for (var len = 0; len <= tnsLobLocOffsetFlag1; len++) {
        final short = Uint8List(len);
        if (len > 0) short.fillRange(0, len, 0xFF);
        expect(
          _clobFrom(short).isTemporary,
          isFalse,
          reason: 'a $len-byte locator carries neither flag byte',
        );
      }
      // Long enough for flag byte 1 but not flag byte 4: only ABSTRACT counts.
      for (
        var len = tnsLobLocOffsetFlag1 + 1;
        len <= tnsLobLocOffsetFlag4;
        len++
      ) {
        final abstractOnly = Uint8List(len)
          ..[tnsLobLocOffsetFlag1] = tnsLobLocFlagsAbstract;
        expect(_clobFrom(abstractOnly).isTemporary, isTrue, reason: '$len');
        // Every bit EXCEPT 0x40 of flag byte 1 set, and flag byte 4 absent.
        final noAbstract = Uint8List(len)
          ..fillRange(0, len, 0xFF)
          ..[tnsLobLocOffsetFlag1] = 0xFF & ~tnsLobLocFlagsAbstract;
        expect(
          _clobFrom(noAbstract).isTemporary,
          isFalse,
          reason: 'a $len-byte locator cannot carry flag byte 4',
        );
      }
      // One byte longer: flag byte 4 now exists and its TEMP bit is honored.
      final justLongEnough = Uint8List(tnsLobLocOffsetFlag4 + 1)
        ..[tnsLobLocOffsetFlag4] = tnsLobLocFlagsTemp;
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
