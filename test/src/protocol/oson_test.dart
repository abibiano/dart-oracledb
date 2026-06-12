/// Unit tests for the OSON (Oracle binary JSON) codec.
///
/// Reference fixture bytes were generated with the bundled node-oracledb
/// encoder (the source of truth). Generation command, run from
/// `reference/node-oracledb/`:
///
/// ```bash
/// node -e "
/// const oson = require('./lib/impl/datahandlers/oson.js');
/// function t(v) { // minimal transformer: objects -> {fields, values}
///   if (Array.isArray(v)) return v.map(t);
///   if (v !== null && typeof v === 'object' && !(v instanceof Buffer)) {
///     return { fields: Object.keys(v), values: Object.values(v).map(t) };
///   }
///   return v;
/// }
/// function enc(label, v) {
///   const e = new oson.OsonEncoder();
///   console.log(label, e.encode(t(v), 255).toString('hex'));
/// }
/// enc('null:', null);
/// enc('emptyObj:', {});
/// // ... one call per fixture below
/// "
/// ```
library;

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/constants.dart' show oraUnsupportedType;
import 'package:oracledb/src/protocol/oson.dart';

Uint8List _hex(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _toHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('OSON encode — reference-backed fixtures (node-oracledb parity)', () {
    test('scalar null', () {
      expect(_toHex(encodeOson(null)), equals('ff4a5a010012000130'));
    });

    test('scalar true', () {
      expect(_toHex(encodeOson(true)), equals('ff4a5a010012000131'));
    });

    test('empty object', () {
      expect(_toHex(encodeOson(<String, Object?>{})),
          equals('ff4a5a01210200000000020000a400'));
    });

    test('empty array', () {
      expect(_toHex(encodeOson(<Object?>[])),
          equals('ff4a5a01210200000000020000e000'));
    });

    test('single int field {a: 1}', () {
      expect(_toHex(encodeOson(<String, Object?>{'a': 1})),
          equals('ff4a5a012102010002000b00002c00000161a40101000000073402c102'));
    });

    test('string field {greeting: hello}', () {
      expect(
          _toHex(encodeOson(<String, Object?>{'greeting': 'hello'})),
          equals('ff4a5a012102010009000e0000b60000086772656574696e67'
              'a4010100000007330568656c6c6f'));
    });

    test('nested object/array with mixed scalars', () {
      // {a: {b: [1, 2.5, 'x', null, false]}, c: true} — exercises the
      // hash-ordered field-id table (hash a=0x2c < c=0x52 < b=0xe5, so the
      // segment lists a, c, b while values stay in insertion order).
      expect(
          _toHex(encodeOson(<String, Object?>{
            'a': <String, Object?>{
              'b': <Object?>[1, 2.5, 'x', null, false],
            },
            'c': true,
          })),
          equals('ff4a5a012102030006003800002c52e5000000040002016101620163'
              'a40201020000000c00000037a4010300000013e005000000290000002d'
              '0000003200000035000000363402c1023403c10333330178303231'));
    });

    test('unicode field name and supplementary-plane string value', () {
      expect(
          _toHex(encodeOson(<String, Object?>{'é': '€ 🚀'})),
          equals('ff4a5a01210201000300110000c1000002c3a9'
              'a40101000000073308e282ac20f09f9a80'));
    });

    test('top-level array', () {
      expect(
          _toHex(encodeOson(<Object?>[1, 'two', null])),
          equals('ff4a5a01210200000000180000'
              'e0030000000e000000120000001734'
              '02c102330374776f30'));
    });

    test('negative decimal {n: -12.34}', () {
      expect(_toHex(encodeOson(<String, Object?>{'n': -12.34})),
          equals('ff4a5a012102010002000d0000310000016ea401010000000734043e594366'));
    });

    test('2^53 integer round-trips through Oracle NUMBER node', () {
      expect(
          _toHex(encodeOson(<String, Object?>{'n': 9007199254740992})),
          equals('ff4a5a01210201000200120000310000016e'
              'a40101000000073409c85b08145d374b0a5d'));
    });

    test('empty string value', () {
      expect(_toHex(encodeOson(<String, Object?>{'s': ''})),
          equals('ff4a5a012102010002000900008200000173a40101000000073300'));
    });

    test('zero number value', () {
      expect(_toHex(encodeOson(<String, Object?>{'z': 0})),
          equals('ff4a5a012102010002000a0000ad0000017aa4010100000007340180'));
    });
  });

  group('OSON encode — input validation', () {
    test('rejects non-finite doubles', () {
      expect(() => encodeOson(<Object?>[double.nan]),
          throwsA(isA<OracleException>()));
      expect(() => encodeOson(<Object?>[double.infinity]),
          throwsA(isA<OracleException>()));
    });

    test('rejects unsupported member types', () {
      expect(() => encodeOson(<Object?>[DateTime.utc(2026)]),
          throwsA(isA<OracleException>()));
      expect(() => encodeOson(<String, Object?>{'b': Uint8List(2)}),
          throwsA(isA<OracleException>()));
    });

    test('rejects non-String map keys', () {
      expect(() => encodeOson(<Object, Object?>{1: 'x'}),
          throwsA(isA<OracleException>()));
    });

    test('rejects field names longer than 255 UTF-8 bytes', () {
      // 255 bytes is fine (works on both 21c and 23ai); 256 fails loud. The
      // codec stays on OSON version 1 (short field names) deliberately —
      // version 3 long names are unsupported on pre-23 servers.
      final ok = 'k' * 255;
      final tooLong = 'k' * 256;
      expect(encodeOson(<String, Object?>{ok: 1}), isA<Uint8List>());
      expect(
        () => encodeOson(<String, Object?>{tooLong: 1}),
        throwsA(isA<OracleException>()
            .having((e) => e.message, 'message', contains('255'))),
      );
    });
  });

  group('OSON round-trip (encode → decode)', () {
    Object? roundTrip(Object? value) => decodeOson(encodeOson(value));

    test('scalars', () {
      expect(roundTrip(null), isNull);
      expect(roundTrip(true), isTrue);
      expect(roundTrip(false), isFalse);
    });

    test('empty containers', () {
      expect(roundTrip(<String, Object?>{}), equals(<String, Object?>{}));
      expect(roundTrip(<Object?>[]), equals(<Object?>[]));
    });

    test('preserves member order and shape of nested documents', () {
      final doc = <String, Object?>{
        'zebra': 1,
        'apple': <Object?>[
          <String, Object?>{'deep': <Object?>[true, null, 'x']},
          2.25,
        ],
        'mango': <String, Object?>{'k1': 'v1', 'k2': 'v2'},
      };
      final decoded = roundTrip(doc)! as Map<String, Object?>;
      expect(decoded, equals(doc));
      // Insertion order survives the hash-sorted field-name segment.
      expect(decoded.keys.toList(), equals(['zebra', 'apple', 'mango']));
    });

    test('numbers: ints, decimals, negatives, boundaries', () {
      final doc = <Object?>[
        0, 1, -1, 42, -42, 12.34, -12.34, 0.001, -0.001,
        9007199254740992, -9007199254740992, 1e10, 123456789.987654,
      ];
      expect(roundTrip(doc), equals(doc));
    });

    test('strings: empty, unicode, supplementary plane, long', () {
      final doc = <Object?>[
        '',
        'plain ascii',
        'çédille €',
        '🚀🎉 emoji',
        'x' * 300, // forces STRING_LENGTH_UINT16 node
        'y' * 70000, // forces STRING_LENGTH_UINT32 node
      ];
      expect(roundTrip(doc), equals(doc));
    });

    test('duplicate field names across sibling objects share one entry', () {
      final doc = <Object?>[
        <String, Object?>{'id': 1, 'name': 'a'},
        <String, Object?>{'id': 2, 'name': 'b'},
      ];
      expect(roundTrip(doc), equals(doc));
    });

    test('object with >255 distinct field names (uint16 field ids)', () {
      final doc = <String, Object?>{
        for (var i = 0; i < 300; i++) 'field_$i': i,
      };
      expect(roundTrip(doc), equals(doc));
    });

    test('field name at the 255-byte boundary', () {
      final doc = <String, Object?>{'k' * 255: 'edge'};
      expect(roundTrip(doc), equals(doc));
    });

    test('field-names segment beyond 65535 bytes round-trips '
        '(uint32 segment size and offsets)', () {
      // 300 unique 250-byte names → a ~75,300-byte field-names segment,
      // past the uint16 boundary: the encoder must set FNAMES_SEG_UINT32
      // and write uint32 name offsets, and the decoder must honor both.
      final doc = <String, Object?>{
        for (var i = 0; i < 300; i++)
          '${'f' * 246}${i.toString().padLeft(4, '0')}': i,
      };
      final namesSegBytes =
          doc.keys.fold<int>(0, (sum, k) => sum + 1 + k.length);
      expect(namesSegBytes, greaterThan(65535),
          reason: 'fixture must cross the uint16 segment-size boundary');
      final decoded = roundTrip(doc)! as Map<String, Object?>;
      expect(decoded, equals(doc));
      expect(decoded.keys.toList(), equals(doc.keys.toList()));
    });
  });

  group('OSON decode — hand-crafted fixtures', () {
    test('zero-length integer node (0x40 / 0x50) decodes to 0', () {
      // Scalar document: magic, version 1, flags INLINE_LEAF|IS_SCALAR,
      // uint16 tree segment size, then the bare node byte. The length
      // nibble is 0, so no NUMBER bytes follow (reference oson.js parity).
      expect(decodeOson(_hex('ff4a5a010012000140')), equals(0));
      expect(decodeOson(_hex('ff4a5a010012000150')), equals(0));
    });

    test('zero-length number node with explicit uint8 length decodes to 0',
        () {
      // Same parity rule for the 0x34 node, whose length travels in a
      // separate uint8 byte instead of the type nibble.
      expect(decodeOson(_hex('ff4a5a01001200023400')), equals(0));
    });

    test('version 3 document with a >255-byte (long) field name decodes', () {
      // The encoder only emits version 1, so this v3 fixture is hand-built
      // along the decoder's own field walk: primary header with zero short
      // field names, a secondary (v3) header declaring one long field name,
      // a long-names segment with uint16 hash ids, uint32 name offsets and
      // 2-byte name length prefixes, then a one-field object tree.
      final longName = 'a' * 260;
      final fixture = _hex([
        'ff4a5a', // magic
        '03', // version 3 (max field name 65535 bytes)
        '0002', // primary flags: INLINE_LEAF
        '00', // number of short field names (uint8)
        '0000', // short field-names segment size (uint16)
        '0000', // secondary flags (v3 only)
        '00000001', // number of long field names (uint32)
        '00000106', // long field-names segment size: 2 + 260 (uint32)
        '0008', // tree segment size (uint16)
        '0000', // tiny nodes statistic
        '0000', // long-name hash id array (1 × uint16, skipped)
        '00000000', // long-name offset array (1 × uint32)
        '0104', // long name length prefix (uint16): 260
        '61' * 260, // the 260-byte field name ('a' × 260)
        '84', // object node, uint8 child count, uint16 offsets
        '01', // one child
        '01', // field id 1 → the long field name
        '0005', // child offset within the tree segment
        '330176', // string node, length 1, 'v'
      ].join());
      expect(decodeOson(fixture), equals(<String, Object?>{longName: 'v'}));
    });
  });

  group('OSON decode — error handling', () {
    test('rejects bad magic bytes', () {
      expect(
        () => decodeOson(_hex('ff4a59010012000130')),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
      );
    });

    test('rejects unsupported version byte', () {
      expect(
        () => decodeOson(_hex('ff4a5a020012000130')),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)),
      );
    });

    test('rejects truncated payloads', () {
      final full = encodeOson(<String, Object?>{'a': 1});
      for (final cut in [3, 8, full.length - 1]) {
        expect(
          () => decodeOson(Uint8List.sublistView(full, 0, cut)),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
          reason: 'truncated at $cut bytes',
        );
      }
    });

    test('empty payload fails loud', () {
      expect(
        () => decodeOson(Uint8List(0)),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
      );
    });

    test('unsupported Oracle-specific scalar nodes fail loud', () {
      // Scalar-document payloads with the node type swapped to each
      // unsupported Oracle-specific kind. Header: magic, v1, flags
      // INLINE_LEAF|IS_SCALAR, uint16 tree size, then the node.
      const unsupportedNodes = {
        0x3c: 'DATE',
        0x7d: 'TIMESTAMP7',
        0x39: 'TIMESTAMP',
        0x7c: 'TIMESTAMP_TZ',
        0x7f: 'BINARY_FLOAT',
        0x36: 'BINARY_DOUBLE',
        0x3d: 'INTERVAL_YM',
        0x3e: 'INTERVAL_DS',
        0x7e: 'ID (JsonId)',
        0x3a: 'BINARY_LENGTH_UINT16',
        0x3b: 'BINARY_LENGTH_UINT32',
        0x7b: 'EXTENDED (vector)',
      };
      for (final entry in unsupportedNodes.entries) {
        final node = entry.key.toRadixString(16).padLeft(2, '0');
        // Pad generous trailing zero bytes so fixed-length scalar reads do
        // not underrun before the type check fires.
        final payload =
            _hex('ff4a5a010012 0010 $node 0000000000000000000000000000');
        expect(
          () => decodeOson(payload),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)),
          reason: 'expected fail-loud for ${entry.value}',
        );
      }
    });
  });
}
