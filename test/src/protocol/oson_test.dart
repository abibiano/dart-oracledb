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

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/oracle_timestamp_tz.dart';
import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/constants.dart' show oraUnsupportedType;
import 'package:oracledb/src/protocol/data_types.dart' as dt;
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

/// Wraps one tree node in an OSON scalar document exactly as Oracle 21c and
/// 23ai send it: magic, version 1, flags `INLINE_LEAF | LEN_IN_PCODE |
/// IS_SCALAR` (0x0016), uint16 tree-segment size, then the node bytes.
Uint8List _scalarDoc(String nodeHex) {
  final node = _hex(nodeHex);
  return _hex(
    'ff4a5a01 0016 ${node.length.toRadixString(16).padLeft(4, '0')} '
    '$nodeHex',
  );
}

/// Builds an OSON document that embeds hand-built Oracle-specific scalar
/// nodes verbatim — including kinds the encoder never emits (DATE,
/// BINARY_FLOAT, intervals, JsonId, VECTOR) and server-captured byte forms.
///
/// [build] receives one placeholder string per entry of [nodesHex] and
/// returns a standard-JSON document using them. The document is encoded,
/// then each placeholder's string node (`0x33`, uint8 length, bytes) is
/// overwritten in place with the matching scalar node. Every placeholder is
/// sized so its string node spans exactly as many bytes as the scalar node
/// it stands for, so all tree offsets stay valid.
Uint8List _embedNodes(
  List<String> nodesHex,
  Object? Function(List<String> slots) build,
) {
  final nodes = [for (final n in nodesHex) _hex(n)];
  final slots = <String>[
    for (var i = 0; i < nodes.length; i++)
      // Tag char (A, B, ...) keeps slots distinct; pad to node length - 2.
      String.fromCharCode(0x41 + i) + 'z' * (nodes[i].length - 3),
  ];
  final out = Uint8List.fromList(encodeOson(build(slots)));
  for (var i = 0; i < nodes.length; i++) {
    final needle = [0x33, slots[i].length, ...slots[i].codeUnits];
    final hits = <int>[];
    for (var p = 0; p + needle.length <= out.length; p++) {
      var match = true;
      for (var k = 0; k < needle.length && match; k++) {
        match = out[p + k] == needle[k];
      }
      if (match) hits.add(p);
    }
    expect(hits, hasLength(1), reason: 'placeholder ${slots[i]} not unique');
    out.setRange(hits.single, hits.single + nodes[i].length, nodes[i]);
  }
  return out;
}

/// Matches an [OracleException] carrying [code] (and, optionally, a message
/// containing [message]).
Matcher _throwsOracle(int code, [String? message]) {
  var matcher = isA<OracleException>().having(
    (e) => e.errorCode,
    'errorCode',
    code,
  );
  if (message != null) {
    matcher = matcher.having((e) => e.message, 'message', contains(message));
  }
  return throwsA(matcher);
}

/// IEEE single-precision rounding of [value], as a BINARY_FLOAT stores it.
double _float32(double value) => Float32List.fromList([value])[0];

// Scalar nodes captured from live servers (byte-identical on Oracle 23ai and
// 21c for the SQL value noted on each) unless marked hand-built.

/// `DATE '2024-03-15'` with time 10:20:30 (DATE node 0x3c, 7 bytes).
const _dateNode = '3c 787c030f0b151f';

/// `TIMESTAMP '2024-03-15 10:20:30'` — zero fraction, so Oracle sends the
/// 7-byte TIMESTAMP7 node (0x7d).
const _timestamp7Node = '7d 787c030f0b151f';

/// `TIMESTAMP '2024-03-15 10:20:30.123456'` (TIMESTAMP node 0x39, 11 bytes:
/// DATE part + big-endian nanoseconds 123456000).
const _timestampNode = '39 787c030f0b151f 075bca00';

/// `TIMESTAMP '2024-03-15 10:20:30.5 +05:30'` (TSTZ node 0x7c, 13 bytes):
/// the fields are the UTC instant 04:50:30.5, then tzHour+20 / tzMinute+60.
const _timestampTzNode = '7c 787c030f05331f 1dcd6500 195a';

/// `TO_BINARY_FLOAT(0.5)` (BINARY_FLOAT node 0x7f, 4 bytes).
const _binaryFloatNode = '7f bf000000';

/// `TO_BINARY_DOUBLE(1.5)` (BINARY_DOUBLE node 0x36, 8 bytes).
const _binaryDoubleNode = '36 bff8000000000000';

/// `HEXTORAW('00FF10')` (binary node 0x3a, uint16 length).
const _binary16Node = '3a 0003 00ff10';

/// Hand-built uint32-length binary node (0x3b) carrying `CAFE`.
const _binary32Node = '3b 00000002 cafe';

void main() {
  group('OSON encode — reference-backed fixtures (node-oracledb parity)', () {
    test('scalar null', () {
      expect(_toHex(encodeOson(null)), equals('ff4a5a010012000130'));
    });

    test('scalar true', () {
      expect(_toHex(encodeOson(true)), equals('ff4a5a010012000131'));
    });

    test('empty object', () {
      expect(
        _toHex(encodeOson(<String, Object?>{})),
        equals('ff4a5a01210200000000020000a400'),
      );
    });

    test('empty array', () {
      expect(
        _toHex(encodeOson(<Object?>[])),
        equals('ff4a5a01210200000000020000e000'),
      );
    });

    test('single int field {a: 1}', () {
      expect(
        _toHex(encodeOson(<String, Object?>{'a': 1})),
        equals('ff4a5a012102010002000b00002c00000161a40101000000073402c102'),
      );
    });

    test('string field {greeting: hello}', () {
      expect(
        _toHex(encodeOson(<String, Object?>{'greeting': 'hello'})),
        equals(
          'ff4a5a012102010009000e0000b60000086772656574696e67'
          'a4010100000007330568656c6c6f',
        ),
      );
    });

    test('nested object/array with mixed scalars', () {
      // {a: {b: [1, 2.5, 'x', null, false]}, c: true} — exercises the
      // hash-ordered field-id table (hash a=0x2c < c=0x52 < b=0xe5, so the
      // segment lists a, c, b while values stay in insertion order).
      expect(
        _toHex(
          encodeOson(<String, Object?>{
            'a': <String, Object?>{
              'b': <Object?>[1, 2.5, 'x', null, false],
            },
            'c': true,
          }),
        ),
        equals(
          'ff4a5a012102030006003800002c52e5000000040002016101620163'
          'a40201020000000c00000037a4010300000013e005000000290000002d'
          '0000003200000035000000363402c1023403c10333330178303231',
        ),
      );
    });

    test('unicode field name and supplementary-plane string value', () {
      expect(
        _toHex(encodeOson(<String, Object?>{'é': '€ 🚀'})),
        equals(
          'ff4a5a01210201000300110000c1000002c3a9'
          'a40101000000073308e282ac20f09f9a80',
        ),
      );
    });

    test('top-level array', () {
      expect(
        _toHex(encodeOson(<Object?>[1, 'two', null])),
        equals(
          'ff4a5a01210200000000180000'
          'e0030000000e000000120000001734'
          '02c102330374776f30',
        ),
      );
    });

    test('negative decimal {n: -12.34}', () {
      expect(
        _toHex(encodeOson(<String, Object?>{'n': -12.34})),
        equals(
          'ff4a5a012102010002000d0000310000016ea401010000000734043e594366',
        ),
      );
    });

    test('2^53 integer round-trips through Oracle NUMBER node', () {
      expect(
        _toHex(encodeOson(<String, Object?>{'n': 9007199254740992})),
        equals(
          'ff4a5a01210201000200120000310000016e'
          'a40101000000073409c85b08145d374b0a5d',
        ),
      );
    });

    test('empty string value', () {
      expect(
        _toHex(encodeOson(<String, Object?>{'s': ''})),
        equals('ff4a5a012102010002000900008200000173a40101000000073300'),
      );
    });

    test('zero number value', () {
      expect(
        _toHex(encodeOson(<String, Object?>{'z': 0})),
        equals('ff4a5a012102010002000a0000ad0000017aa4010100000007340180'),
      );
    });
  });

  group('OSON encode — input validation', () {
    test('rejects unsupported member types', () {
      for (final bad in <Object>[
        <int>{1, 2}, // Set
        #symbol,
        Duration.zero, // arbitrary object
        Object(),
      ]) {
        expect(
          () => encodeOson(<Object?>[bad]),
          _throwsOracle(oraUnsupportedType, 'Unsupported JSON member type'),
          reason: '${bad.runtimeType}',
        );
        expect(
          () => encodeOson(bad),
          _throwsOracle(oraUnsupportedType),
          reason: 'scalar root ${bad.runtimeType}',
        );
      }
    });

    test('rejects dates outside years 1..9999 without echoing the year', () {
      for (final bad in <Object>[
        DateTime(-44, 3, 15),
        DateTime(0),
        DateTime(10000),
        DateTime(25600), // would wrap the century byte silently
        OracleTimestampTz(DateTime.utc(-1), offsetMinutes: 0),
        OracleTimestampTz(DateTime.utc(10000), offsetMinutes: 60),
      ]) {
        expect(
          () => encodeOson(<String, Object?>{'when': bad}),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
                .having((e) => e.message, 'message', contains('year'))
                .having(
                  (e) => e.message,
                  'message',
                  isNot(anyOf(contains('-44'), contains('10000'))),
                ),
          ),
          reason: '$bad',
        );
      }
      // The boundaries themselves encode.
      expect(encodeOson(DateTime(1)), isA<Uint8List>());
      expect(encodeOson(DateTime(9999, 12, 31, 23, 59, 59)), isA<Uint8List>());
    });

    test('rejects non-String map keys', () {
      expect(
        () => encodeOson(<Object, Object?>{1: 'x'}),
        throwsA(isA<OracleException>()),
      );
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
        throwsA(
          isA<OracleException>().having(
            (e) => e.message,
            'message',
            contains('255'),
          ),
        ),
      );
    });
  });

  group('OSON round-trip (encode → decode)', () {
    Object? roundTrip(Object? value) => decodeOson(encodeOson(value));

    test('NUMBER values at the reported range extremes round-trip', () {
      for (final value in [1e-129, 9.99e125]) {
        expect(roundTrip(value), equals(value), reason: 'value $value');
      }
    });

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
          <String, Object?>{
            'deep': <Object?>[true, null, 'x'],
          },
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
        0,
        1,
        -1,
        42,
        -42,
        12.34,
        -12.34,
        0.001,
        -0.001,
        9007199254740992,
        -9007199254740992,
        1e10,
        123456789.987654,
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
      final namesSegBytes = doc.keys.fold<int>(
        0,
        (sum, k) => sum + 1 + k.length,
      );
      expect(
        namesSegBytes,
        greaterThan(65535),
        reason: 'fixture must cross the uint16 segment-size boundary',
      );
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

    test('zero-length number node with explicit uint8 length decodes to 0', () {
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
      final fixture = _hex(
        [
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
        ].join(),
      );
      expect(decodeOson(fixture), equals(<String, Object?>{longName: 'v'}));
    });
  });

  group('OSON decode — error handling', () {
    test('rejects bad magic bytes', () {
      expect(
        () => decodeOson(_hex('ff4a59010012000130')),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            oraProtocolError,
          ),
        ),
      );
    });

    test('rejects unsupported version byte', () {
      expect(
        () => decodeOson(_hex('ff4a5a020012000130')),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            oraUnsupportedType,
          ),
        ),
      );
    });

    test('rejects truncated payloads', () {
      final full = encodeOson(<String, Object?>{'a': 1});
      for (final cut in [3, 8, full.length - 1]) {
        expect(
          () => decodeOson(Uint8List.sublistView(full, 0, cut)),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              oraProtocolError,
            ),
          ),
          reason: 'truncated at $cut bytes',
        );
      }
    });

    test('empty payload fails loud', () {
      expect(
        () => decodeOson(Uint8List(0)),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            oraProtocolError,
          ),
        ),
      );
    });

    test('Oracle-specific scalar nodes without a driver type fail loud', () {
      // Scalar-document payloads with the node type set to each kind that
      // still has no Dart representation (intervals and VECTOR arrive with
      // Epics 14/15). Header: magic, v1, flags INLINE_LEAF|IS_SCALAR, uint16
      // tree size, then the node. Generous trailing zero bytes ensure a
      // fixed-length read could never underrun before the type check fires.
      const unsupportedNodes = {
        0x3d: 'INTERVAL YEAR TO MONTH',
        0x3e: 'INTERVAL DAY TO SECOND',
        0x7e: 'JsonId',
        0x7b: 'extended (VECTOR)',
        // Unassigned node types fall through every decoder branch.
        0x35: 'unknown',
        0x3f: 'unknown',
        0x70: 'unknown',
        0x7a: 'unknown',
      };
      for (final entry in unsupportedNodes.entries) {
        final node = entry.key.toRadixString(16).padLeft(2, '0');
        final payload = _hex(
          'ff4a5a010012 0010 $node 0000000000000000000000000000',
        );
        expect(
          () => decodeOson(payload),
          _throwsOracle(oraUnsupportedType, '0x$node (${entry.value})'),
          reason: 'expected fail-loud for ${entry.value}',
        );
      }
    });

    test('server-captured interval scalars fail loud with the new scope '
        'message', () {
      // JSON_SCALAR(INTERVAL '1-2' YEAR TO MONTH) and
      // JSON_SCALAR(INTERVAL '3 04:05:06' DAY TO SECOND), byte-identical on
      // Oracle 23ai and 21c.
      final cases = {
        'ff4a5a01001600063d800000013e': 'INTERVAL YEAR TO MONTH',
        'ff4a5a010016000c3e8000000340414280000000': 'INTERVAL DAY TO SECOND',
      };
      for (final entry in cases.entries) {
        expect(
          () => decodeOson(_hex(entry.key)),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
                .having((e) => e.message, 'message', contains(entry.value))
                .having(
                  (e) => e.message,
                  'message',
                  contains(
                    'Oracle-specific JSON scalars beyond date/time, binary '
                    'and float/double',
                  ),
                ),
          ),
        );
      }
    });

    test('an unsupported scalar nested deep in a document fails the whole '
        'decode (nothing returned partially)', () {
      // Interval YM (6 bytes), JsonId (4 bytes) and extended (3 bytes)
      // nodes, each placed after supported members inside a nested object.
      const nested = {
        '3d 800000013e': 'INTERVAL YEAR TO MONTH',
        '7e 02 aabb': 'JsonId',
        '7b 01 00': 'extended (VECTOR)',
      };
      for (final entry in nested.entries) {
        final fixture = _embedNodes(
          [_dateNode, entry.key],
          (s) => <String, Object?>{
            'ok': 'standard',
            'inner': <Object?>[
              1,
              <String, Object?>{'when': s[0], 'bad': s[1]},
            ],
          },
        );
        expect(
          () => decodeOson(fixture),
          _throwsOracle(oraUnsupportedType, entry.value),
        );
      }
    });

    test(
      'truncated Oracle-specific scalar payloads raise oraProtocolError',
      () {
        // Each node declares (or implies) more bytes than the payload holds:
        // the short read underflows into the BufferException path.
        const truncated = {
          'DATE (3 of 7 bytes)': '3c 787c03',
          'TIMESTAMP7 (6 of 7 bytes)': '7d 787c030f0b15',
          'TIMESTAMP (10 of 11 bytes)': '39 787c030f0b151f 075bca',
          'TIMESTAMP WITH TIME ZONE (12 of 13 bytes)':
              '7c 787c030f05331f 1dcd6500 19',
          'BINARY_FLOAT (3 of 4 bytes)': '7f bf0000',
          'BINARY_DOUBLE (7 of 8 bytes)': '36 bff80000000000',
          'binary uint16 (2 of 4 bytes)': '3a 0004 dead',
          'binary uint16 (length cut)': '3a 00',
          'binary uint32 (3 of 5 bytes)': '3b 00000005 010203',
          'binary uint32 (length cut)': '3b 0000',
          'binary uint32 (4 GiB length)': '3b ffffffff 00',
        };
        for (final entry in truncated.entries) {
          expect(
            () => decodeOson(_scalarDoc(entry.value)),
            _throwsOracle(
              oraProtocolError,
              'Truncated or corrupt OSON payload',
            ),
            reason: entry.key,
          );
        }
      },
    );
  });

  group('OSON decode — Oracle-specific scalars', () {
    group('DATE / TIMESTAMP', () {
      test('DATE node decodes to the same DateTime as decodeDate', () {
        // JSON_SCALAR(DATE '2024-03-15') and JSON_SCALAR(TO_DATE(
        // '2024-03-15 10:20:30', ...)), captured from both servers.
        final dateOnly = decodeOson(_scalarDoc('3c 787c030f010101'));
        expect(dateOnly, equals(DateTime(2024, 3, 15)));
        final withTime = decodeOson(_scalarDoc(_dateNode));
        expect(withTime, equals(DateTime(2024, 3, 15, 10, 20, 30)));
        expect(
          withTime,
          equals(dt.decodeDate(ReadBuffer(_hex('787c030f0b151f')))),
        );
        // Local wall clock, exactly like a DATE column.
        expect((withTime! as DateTime).isUtc, isFalse);
      });

      test('TIMESTAMP7 node decodes to the same DateTime as decodeDate', () {
        final value = decodeOson(_scalarDoc(_timestamp7Node));
        expect(value, isA<DateTime>());
        expect(
          value,
          equals(dt.decodeDate(ReadBuffer(_hex('787c030f0b151f')))),
        );
        expect((value! as DateTime).isUtc, isFalse);
      });

      test('TIMESTAMP node keeps fractional seconds like decodeTimestamp', () {
        final value = decodeOson(_scalarDoc(_timestampNode));
        expect(value, equals(DateTime(2024, 3, 15, 10, 20, 30, 123, 456)));
        expect(
          value,
          equals(
            dt.decodeTimestamp(ReadBuffer(_hex('787c030f0b151f075bca00'))),
          ),
        );
        expect((value! as DateTime).isUtc, isFalse);
      });

      test('TIMESTAMP node truncates nanoseconds toward zero', () {
        // .123456789 → nanos 0x075BCD15; Dart keeps microseconds only.
        final value = decodeOson(_scalarDoc('39 787c030f0b151f 075bcd15'));
        expect(value, equals(DateTime(2024, 3, 15, 10, 20, 30, 123, 456)));
      });

      test('BCE dates and timestamps raise oraUnsupportedType', () {
        // Century byte 99 (< 100) marks a BCE year — same rejection as
        // DATE/TIMESTAMP columns. The message pins which codec ran: DATE
        // nodes use decodeDate, every TIMESTAMP form the timestamp parser.
        const bce = {
          'DATE': ('3c 6364010101 0101', 'BCE DATE'),
          'TIMESTAMP7': ('7d 6364010101 0101', 'BCE TIMESTAMP'),
          'TIMESTAMP': ('39 6364010101 0101 00000000', 'BCE TIMESTAMP'),
          'TIMESTAMP WITH TIME ZONE': (
            '7c 6364010101 0101 00000000 143c',
            'BCE TIMESTAMP',
          ),
        };
        for (final MapEntry(key: kind, value: (node, message)) in bce.entries) {
          expect(
            () => decodeOson(_scalarDoc(node)),
            _throwsOracle(oraUnsupportedType, message),
            reason: kind,
          );
        }
      });
    });

    group('TIMESTAMP WITH TIME ZONE', () {
      test('decodes to OracleTimestampTz like decodeTimestampTz', () {
        final value = decodeOson(_scalarDoc(_timestampTzNode));
        expect(value, isA<OracleTimestampTz>());
        final tz = value! as OracleTimestampTz;
        expect(tz.utc, equals(DateTime.utc(2024, 3, 15, 4, 50, 30, 500)));
        expect(tz.offsetMinutes, equals(330));
        expect(
          tz,
          equals(
            dt.decodeTimestampTz(
              ReadBuffer(_hex('787c030f05331f1dcd6500195a')),
            ),
          ),
        );
      });

      test('negative and zero offsets survive', () {
        // TIMESTAMP '2024-03-15 10:20:30 -08:00' → UTC 18:20:30, 12/60.
        final minus8 = decodeOson(
          _scalarDoc('7c 787c030f13151f 00000000 0c3c'),
        );
        expect(
          minus8,
          equals(
            OracleTimestampTz(
              DateTime.utc(2024, 3, 15, 18, 20, 30),
              offsetMinutes: -480,
            ),
          ),
        );
        // +00:00 → zone bytes 20/60.
        final utc = decodeOson(_scalarDoc('7c 787c030f0b151f 0ee6b280 143c'));
        expect(
          utc,
          equals(
            OracleTimestampTz(
              DateTime.utc(2024, 3, 15, 10, 20, 30, 250),
              offsetMinutes: 0,
            ),
          ),
        );
      });

      test('region-id zone raises the existing oraUnsupportedType', () {
        // JSON_SCALAR(TO_TIMESTAMP_TZ('2024-03-15 10:20:30 US/Pacific',
        // ... TZR)), captured from both servers: byte 11 has its high bit set.
        expect(
          () =>
              decodeOson(_hex('ff4a5a010016000e7c787c030f12151f00000000899c')),
          _throwsOracle(oraUnsupportedType, 'region-id'),
        );
      });

      test('malformed zone bytes raise the existing oraProtocolError', () {
        // byte11 = 0 → -20h, outside Oracle's offset band.
        expect(
          () => decodeOson(_scalarDoc('7c 787c030f05331f 00000000 003c')),
          _throwsOracle(oraProtocolError, 'TIMESTAMP TZ offset out of range'),
        );
      });
    });

    group('BINARY_FLOAT / BINARY_DOUBLE', () {
      test('BINARY_DOUBLE: positive, negative, zero, extremes', () {
        final cases = <String, double>{
          // Server-captured: TO_BINARY_DOUBLE(1.5) / (-2.25).
          '36 bff8000000000000': 1.5,
          '36 3ffdffffffffffff': -2.25,
          '36 c000000000000000': 2.0,
          '36 8000000000000000': 0.0,
          // Largest finite double and the smallest subnormal.
          '36 ffefffffffffffff': double.maxFinite,
          '36 8000000000000001': double.minPositive,
          '36 0010000000000000': -double.maxFinite,
        };
        for (final entry in cases.entries) {
          final value = decodeOson(_scalarDoc(entry.key));
          expect(value, isA<double>(), reason: entry.key);
          expect(value, equals(entry.value), reason: entry.key);
        }
        // Negative zero: Oracle inverts every bit of 0x8000... → 0x7fff....
        final negZero =
            decodeOson(_scalarDoc('36 7fffffffffffffff'))! as double;
        expect(negZero, equals(0.0));
        expect(negZero.isNegative, isTrue);
      });

      test('BINARY_DOUBLE: NaN and ±Infinity (server-captured)', () {
        expect(decodeOson(_hex('ff4a5a010016000936fff8000000000000')), isNaN);
        expect(
          decodeOson(_hex('ff4a5a010016000936fff0000000000000')),
          equals(double.infinity),
        );
        expect(
          decodeOson(_hex('ff4a5a010016000936000fffffffffffff')),
          equals(double.negativeInfinity),
        );
      });

      test('BINARY_FLOAT: positive, negative, zero, single-precision '
          'rounding', () {
        // Server-captured: TO_BINARY_FLOAT(3.14) / (-0.25) / (0.5).
        final pi = decodeOson(_hex('ff4a5a01001600057fc048f5c3'));
        expect(pi, isA<double>());
        expect(pi, equals(_float32(3.14)));
        expect(pi, isNot(equals(3.14)));
        expect(decodeOson(_hex('ff4a5a01001600057f417fffff')), equals(-0.25));
        expect(decodeOson(_scalarDoc(_binaryFloatNode)), equals(0.5));
        expect(decodeOson(_scalarDoc('7f 80000000')), equals(0.0));
        final negZero = decodeOson(_scalarDoc('7f 7fffffff'))! as double;
        expect(negZero, equals(0.0));
        expect(negZero.isNegative, isTrue);
      });

      test('BINARY_FLOAT: NaN and ±Infinity', () {
        // IEEE 0x7fc00000 / 0x7f800000 → sign bit set; 0xff800000 → inverted.
        expect(decodeOson(_scalarDoc('7f ffc00000')), isNaN);
        expect(decodeOson(_scalarDoc('7f ff800000')), equals(double.infinity));
        expect(
          decodeOson(_scalarDoc('7f 007fffff')),
          equals(double.negativeInfinity),
        );
      });
    });

    group('binary (RAW)', () {
      test('uint16 length form (server-captured HEXTORAW)', () {
        final value = decodeOson(_hex('ff4a5a01001600073a0004deadbeef'));
        expect(value, isA<Uint8List>());
        expect(value, equals([0xde, 0xad, 0xbe, 0xef]));
      });

      test('uint32 length form, including a > 65535-byte payload', () {
        expect(decodeOson(_scalarDoc(_binary32Node)), equals([0xca, 0xfe]));
        final big = Uint8List.fromList(
          List<int>.generate(70000, (i) => i % 251),
        );
        // Oracle sends a 70,000-byte JSON_SCALAR(blob) as a scalar document
        // with a uint32 tree segment (flags 0x1016) and a uint32 binary node.
        final header = _hex('ff4a5a01 1016 00011175 3b 00011170');
        final doc = Uint8List(header.length + big.length)
          ..setRange(0, header.length, header)
          ..setRange(header.length, header.length + big.length, big);
        final value = decodeOson(doc);
        expect(value, isA<Uint8List>());
        expect(value, equals(big));
      });

      test('empty binary decodes to an empty Uint8List, not null', () {
        for (final node in ['3a 0000', '3b 00000000']) {
          final value = decodeOson(_scalarDoc(node));
          expect(value, isA<Uint8List>(), reason: node);
          expect(value, isEmpty, reason: node);
        }
      });

      test('returns a copy, not a view of the OSON payload', () {
        final payload = _hex('ff4a5a01001600073a0004deadbeef');
        final value = decodeOson(payload)! as Uint8List;
        payload.fillRange(0, payload.length, 0);
        expect(value, equals([0xde, 0xad, 0xbe, 0xef]));
        expect(value.lengthInBytes, equals(value.buffer.lengthInBytes));
      });
    });

    group('documents', () {
      test('server-captured mixed object keeps member types and key order '
          '(21c and 23ai header variants)', () {
        // JSON_OBJECT('s' VALUE 'x', 'n' VALUE 42, 'd' VALUE DATE
        // '2024-03-15', 'ts' VALUE TIMESTAMP '2024-03-15 10:20:30.123',
        // 'tz' VALUE TIMESTAMP '2024-03-15 10:20:30 -08:00',
        // 'bd' VALUE TO_BINARY_DOUBLE(1.5), 'bf' VALUE TO_BINARY_FLOAT(0.5),
        // 'r' VALUE HEXTORAW('00FF10') RETURNING JSON). 21c sends a uint16
        // tree segment size (flags 0x2106); 23ai a uint32 one (0x3106).
        const body =
            '0000131531397073829b000c00120002000f00060004000000090173016e0164'
            '02747302747a026264026266017284080703060508010402001a001c001f0027'
            '00330041004a004f017821c12b3c787c030f01010139787c030f0b151f0754d4'
            'c07c787c030f13151f000000000c3c36bff80000000000007fbf0000003a0003'
            '00ff10';
        final fixtures = {
          '21c': _hex('ff4a5a01 2106 08 0014 0055 $body'),
          '23ai': _hex('ff4a5a01 3106 08 0014 00000055 $body'),
        };
        for (final entry in fixtures.entries) {
          final decoded = decodeOson(entry.value);
          expect(decoded, isA<Map<String, Object?>>(), reason: entry.key);
          final doc = decoded! as Map<String, Object?>;
          expect(
            doc.keys.toList(),
            equals(['s', 'n', 'd', 'ts', 'tz', 'bd', 'bf', 'r']),
            reason: entry.key,
          );
          expect(doc['s'], equals('x'));
          expect(doc['n'], equals(42));
          expect(doc['d'], equals(DateTime(2024, 3, 15)));
          expect(doc['ts'], equals(DateTime(2024, 3, 15, 10, 20, 30, 123)));
          expect(
            doc['tz'],
            equals(
              OracleTimestampTz(
                DateTime.utc(2024, 3, 15, 18, 20, 30),
                offsetMinutes: -480,
              ),
            ),
          );
          expect(doc['bd'], equals(1.5));
          expect(doc['bf'], equals(0.5));
          expect(doc['r'], isA<Uint8List>());
          expect(doc['r'], equals([0x00, 0xff, 0x10]));
        }
      });

      test('server-captured array of date, binary and double', () {
        // JSON_ARRAY(DATE '2024-03-15', HEXTORAW('ABCD'),
        // TO_BINARY_DOUBLE(2) RETURNING JSON), both servers.
        final decoded = decodeOson(
          _hex(
            'ff4a5a012006000000001e0000c0030008001000153c787c030f010101'
            '3a0002abcd36c000000000000000',
          ),
        );
        expect(decoded, isA<List<Object?>>());
        final list = decoded! as List<Object?>;
        expect(list, hasLength(3));
        expect(list[0], equals(DateTime(2024, 3, 15)));
        expect(list[1], isA<Uint8List>());
        expect(list[1], equals([0xab, 0xcd]));
        expect(list[2], equals(2.0));
      });

      test('every supported kind nested in objects and arrays, alongside '
          'standard members, in order', () {
        final fixture = _embedNodes(
          [
            _dateNode,
            _timestamp7Node,
            _timestampNode,
            _timestampTzNode,
            _binaryFloatNode,
            _binaryDoubleNode,
            _binary16Node,
            _binary32Node,
          ],
          (s) => <String, Object?>{
            'name': 'mixed',
            'temporal': <String, Object?>{
              'date': s[0],
              'ts7': s[1],
              'ts': s[2],
              'tstz': s[3],
            },
            'count': 3,
            'numbers': <Object?>[s[4], 7, s[5], null],
            'blobs': <Object?>[
              <String, Object?>{'short': s[6]},
              <Object?>[s[7], true],
            ],
            'tail': 'kept',
          },
        );
        final decoded = decodeOson(fixture)! as Map<String, Object?>;
        expect(
          decoded.keys.toList(),
          equals(['name', 'temporal', 'count', 'numbers', 'blobs', 'tail']),
        );
        expect(decoded['name'], equals('mixed'));
        expect(decoded['count'], equals(3));
        expect(decoded['tail'], equals('kept'));

        final temporal = decoded['temporal']! as Map<String, Object?>;
        expect(temporal.keys.toList(), equals(['date', 'ts7', 'ts', 'tstz']));
        expect(temporal['date'], equals(DateTime(2024, 3, 15, 10, 20, 30)));
        expect(temporal['ts7'], equals(DateTime(2024, 3, 15, 10, 20, 30)));
        expect(
          temporal['ts'],
          equals(DateTime(2024, 3, 15, 10, 20, 30, 123, 456)),
        );
        expect(
          temporal['tstz'],
          equals(
            OracleTimestampTz(
              DateTime.utc(2024, 3, 15, 4, 50, 30, 500),
              offsetMinutes: 330,
            ),
          ),
        );

        expect(decoded['numbers'], equals(<Object?>[0.5, 7, 1.5, null]));
        final numbers = decoded['numbers']! as List<Object?>;
        expect(numbers[0], isA<double>());
        expect(numbers[1], isA<int>());

        final blobs = decoded['blobs']! as List<Object?>;
        final short = (blobs[0]! as Map<String, Object?>)['short'];
        expect(short, isA<Uint8List>());
        expect(short, equals([0x00, 0xff, 0x10]));
        final inner = blobs[1]! as List<Object?>;
        expect(inner[0], isA<Uint8List>());
        expect(inner[0], equals([0xca, 0xfe]));
        expect(inner[1], isTrue);
      });

      test('a BCE date nested in a document fails the whole decode', () {
        final fixture = _embedNodes(
          ['3c 6364010101 0101'],
          (s) => <String, Object?>{
            'ok': 1,
            'list': <Object?>[s[0]],
          },
        );
        expect(
          () => decodeOson(fixture),
          _throwsOracle(oraUnsupportedType, 'BCE'),
        );
      });
    });
  });

  // ==========================================================================
  // Story 13.3 — bind/fetch symmetry: every Oracle-specific scalar the decoder
  // produces encodes back (node-oracledb oson.js `encodeNode`), as a member or
  // as a scalar root.
  // ==========================================================================
  group('OSON encode — Oracle-specific scalars', () {
    /// The tree-segment node bytes of an encoded scalar document (everything
    /// after the 8-byte scalar header: magic, version, flags, uint16 size).
    String scalarNode(Object? value) {
      final bytes = encodeOson(value);
      // INLINE_LEAF | IS_SCALAR with a uint16 tree segment size.
      expect(_toHex(bytes.sublist(0, 6)), equals('ff4a5a010012'));
      final size = (bytes[6] << 8) | bytes[7];
      expect(bytes.length, equals(8 + size));
      return _toHex(bytes.sublist(8));
    }

    String hex(String spaced) => spaced.replaceAll(' ', '');

    group('reference-backed fixtures (node-oracledb parity)', () {
      // Generated with the bundled node-oracledb encoder (see the library
      // comment) under TZ=UTC so a JS Date's local fields equal the Dart
      // DateTime constructor arguments used here.
      test('Date without milliseconds → TIMESTAMP7 scalar document', () {
        expect(
          _toHex(encodeOson(DateTime(2024, 3, 15, 10, 20, 30))),
          equals('ff4a5a01001200087d787c030f0b151f'),
        );
      });

      test('Date with milliseconds → TIMESTAMP scalar document', () {
        expect(
          _toHex(encodeOson(DateTime(2024, 3, 15, 10, 20, 30, 123))),
          equals('ff4a5a010012000c39787c030f0b151f0754d4c0'),
        );
      });

      test('Buffer → binary (uint16 length) scalar document, empty too', () {
        expect(
          _toHex(encodeOson(Uint8List.fromList([0x00, 0xff, 0x10]))),
          equals('ff4a5a01001200063a000300ff10'),
        );
        expect(
          _toHex(encodeOson(Uint8List(0))),
          equals('ff4a5a01001200033a0000'),
        );
      });

      test('NaN → BINARY_DOUBLE scalar document', () {
        expect(
          _toHex(encodeOson(double.nan)),
          equals('ff4a5a010012000936fff8000000000000'),
        );
      });

      test('document mixing dates, buffers, NaN and a NUMBER', () {
        expect(
          _toHex(
            encodeOson(<String, Object?>{
              'd': DateTime(2024, 3, 15, 10, 20, 30),
              'ts': DateTime(2024, 3, 15, 10, 20, 30, 500),
              'b': Uint8List.fromList([1, 2]),
              'n': double.nan,
              'list': <Object?>[
                Uint8List.fromList([0xca, 0xfe]),
                DateTime(2000),
                7,
              ],
            }),
          ),
          equals(
            'ff4a5a01210205000e005c000031707381e5000700020000000900050164'
            '0274730162016e046c697374a40503020501040000001b000000230000002f'
            '000000340000003d7d787c030f0b151f39787c030f0b151f1dcd65003a0002'
            '010236fff8000000000000e0030000004b00000050000000583a0002cafe7d'
            '786401010101013402c108',
          ),
        );
      });

      test('65535-byte buffer keeps the uint16 length node; 65536 bytes '
          'switches to uint32 (and a uint32 tree segment)', () {
        final b65535 = encodeOson(Uint8List(65535)..fillRange(0, 65535, 0xab));
        expect(
          _toHex(b65535.sublist(0, 13)),
          equals('ff4a5a011012000100023affff'),
        );
        final b65536 = encodeOson(Uint8List(65536)..fillRange(0, 65536, 0xab));
        expect(
          _toHex(b65536.sublist(0, 15)),
          equals('ff4a5a011012000100053b00010000'),
        );
        expect(b65536.length, equals(15 + 65536));
      });
    });

    group('DateTime', () {
      test('no sub-second part → TIMESTAMP7 carrying encodeDate bytes', () {
        final value = DateTime(2024, 3, 15, 10, 20, 30);
        expect(scalarNode(value), equals(hex('7d 787c030f0b151f')));
        expect(scalarNode(value), equals('7d${_toHex(dt.encodeDate(value))}'));
        // Midnight and the AD/9999 boundaries.
        expect(
          scalarNode(DateTime(2024, 3, 15)),
          equals(hex('7d 787c030f010101')),
        );
        expect(scalarNode(DateTime(1)), equals(hex('7d 6465010101 0101')));
        expect(
          scalarNode(DateTime(9999, 12, 31, 23, 59, 59)),
          equals(hex('7d c7c70c1f18 3c3c')),
        );
      });

      test('a sub-second part → 11-byte TIMESTAMP carrying encodeTimestamp '
          'bytes (milliseconds and microseconds alike)', () {
        final millis = DateTime(2024, 3, 15, 10, 20, 30, 123, 456);
        expect(scalarNode(millis), equals(hex('39 787c030f0b151f 075bca00')));
        expect(
          scalarNode(millis),
          equals('39${_toHex(dt.encodeTimestamp(millis))}'),
        );
        // One microsecond alone is enough to need the fractional form.
        expect(
          scalarNode(DateTime(2024, 3, 15, 10, 20, 30, 0, 1)),
          equals(hex('39 787c030f0b151f 000003e8')),
        );
      });

      test('local and UTC DateTimes both write their own wall-clock fields, '
          'exactly like a DATE / TIMESTAMP column bind', () {
        expect(
          scalarNode(DateTime.utc(2024, 3, 15, 10, 20, 30)),
          equals(scalarNode(DateTime(2024, 3, 15, 10, 20, 30))),
        );
      });
    });

    group('OracleTimestampTz', () {
      test('→ 13-byte TIMESTAMP_TZ, byte-identical to the server-captured '
          'nodes the decoder reads', () {
        // TIMESTAMP '2024-03-15 10:20:30.5 +05:30' (server capture).
        expect(
          scalarNode(
            OracleTimestampTz(
              DateTime.utc(2024, 3, 15, 4, 50, 30, 500),
              offsetMinutes: 330,
            ),
          ),
          equals(hex(_timestampTzNode)),
        );
        // TIMESTAMP '2024-03-15 10:20:30 -08:00' (server capture): the
        // zero fraction still travels — TSTZ is always 13 bytes.
        expect(
          scalarNode(
            OracleTimestampTz(
              DateTime.utc(2024, 3, 15, 18, 20, 30),
              offsetMinutes: -480,
            ),
          ),
          equals(hex('7c 787c030f13151f 00000000 0c3c')),
        );
        // -09:30: hour and minute parts share the sign (11 / 30).
        final minusHalf = OracleTimestampTz(
          DateTime.utc(2024, 3, 15, 19, 50, 30),
          offsetMinutes: -570,
        );
        expect(
          scalarNode(minusHalf),
          equals('7c${_toHex(dt.encodeTimestampTz(minusHalf))}'),
        );
        expect(scalarNode(minusHalf), endsWith('0b1e'));
      });
    });

    group('BINARY_DOUBLE', () {
      test('NaN and ±Infinity match the server-captured nodes', () {
        expect(scalarNode(double.nan), equals(hex('36 fff8000000000000')));
        expect(scalarNode(double.infinity), equals(hex('36 fff0000000000000')));
        expect(
          scalarNode(double.negativeInfinity),
          equals(hex('36 000fffffffffffff')),
        );
      });

      test('any NaN bit pattern is canonicalized (x64 computes 0.0 / 0.0 as '
          'a negative NaN)', () {
        for (final bits in [
          (0xfff80000, 0x00000000), // negative quiet NaN
          (0x7ff00000, 0x00000001), // signaling NaN payload
          (0xffffffff, 0xffffffff),
        ]) {
          final data = ByteData(8)
            ..setUint32(0, bits.$1)
            ..setUint32(4, bits.$2);
          final nan = data.getFloat64(0);
          expect(nan.isNaN, isTrue);
          expect(scalarNode(nan), equals(hex('36 fff8000000000000')));
        }
      });

      test('finite doubles NUMBER cannot hold travel as BINARY_DOUBLE; '
          'everything NUMBER can hold stays NUMBER', () {
        expect(
          scalarNode(double.maxFinite),
          equals(hex('36 ffefffffffffffff')),
        );
        expect(
          scalarNode(-double.maxFinite),
          equals(hex('36 0010000000000000')),
        );
        expect(
          scalarNode(double.minPositive),
          equals(hex('36 8000000000000001')),
        );
        for (final value in [1e126, -1e126, 1e-131, 5e-200]) {
          expect(scalarNode(value), startsWith('36'), reason: '$value');
          expect(
            decodeOson(encodeOson(value)),
            equals(value),
            reason: '$value',
          );
        }
        // In range (and zero, and every int): the NUMBER node, unchanged.
        for (final value in <num>[
          0,
          0.0,
          -0.0,
          1.5,
          9.99e125,
          -9.99e125,
          1e-130,
          9223372036854775807,
        ]) {
          expect(scalarNode(value), startsWith('34'), reason: '$value');
        }
      });
    });

    group('binary (RAW)', () {
      test('uint16 length up to 65535 bytes, uint32 from 65536', () {
        expect(
          scalarNode(Uint8List.fromList([0x00, 0xff, 0x10])),
          equals(hex(_binary16Node)),
        );
        expect(scalarNode(Uint8List(0)), equals('3a0000'));
        final at65535 = encodeOson(<Object?>[Uint8List(65535)]);
        final at65536 = encodeOson(<Object?>[Uint8List(65536)]);
        // Tree segment after the 13-byte container header + 4-byte offset.
        expect(_toHex(at65535).contains('3affff'), isTrue);
        expect(_toHex(at65536).contains('3b00010000'), isTrue);
        expect(decodeOson(at65536), equals(<Object?>[Uint8List(65536)]));
      });

      test('a Uint8List view encodes only its own bytes', () {
        final backing = Uint8List.fromList([9, 9, 1, 2, 3, 9]);
        final view = Uint8List.sublistView(backing, 2, 5);
        expect(scalarNode(view), equals(hex('3a 0003 010203')));
      });
    });

    group('round-trip (encode → decode) as the same Dart type and value', () {
      Object? roundTrip(Object? value) => decodeOson(encodeOson(value));

      test('every Oracle scalar as a scalar root', () {
        final local = DateTime(2024, 3, 15, 10, 20, 30);
        final fractional = DateTime(2024, 3, 15, 10, 20, 30, 123, 456);
        final tz = OracleTimestampTz(
          DateTime.utc(2024, 3, 15, 4, 50, 30, 500),
          offsetMinutes: 330,
        );
        final bytes = Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]);
        expect(roundTrip(local), equals(local));
        expect(roundTrip(local), isA<DateTime>());
        expect((roundTrip(local)! as DateTime).isUtc, isFalse);
        expect(roundTrip(fractional), equals(fractional));
        expect(roundTrip(tz), equals(tz));
        expect(roundTrip(tz), isA<OracleTimestampTz>());
        expect(roundTrip(bytes), equals(bytes));
        expect(roundTrip(bytes), isA<Uint8List>());
        expect(roundTrip(Uint8List(0)), isA<Uint8List>());
        expect(roundTrip(Uint8List(0)), isEmpty);
        expect(roundTrip(double.nan), isNaN);
        expect(roundTrip(double.infinity), equals(double.infinity));
        expect(
          roundTrip(double.negativeInfinity),
          equals(double.negativeInfinity),
        );
        // Standard scalar roots.
        expect(roundTrip('s'), equals('s'));
        expect(roundTrip(''), equals(''));
        expect(roundTrip(3), equals(3));
        expect(roundTrip(3), isA<int>());
        expect(roundTrip(2.5), equals(2.5));
        expect(roundTrip(true), isTrue);
      });

      test('every Oracle scalar nested in objects and arrays, in order', () {
        final doc = <String, Object?>{
          'd': DateTime(2024, 3, 15, 10, 20, 30),
          'ts': DateTime(2024, 3, 15, 10, 20, 30, 123, 456),
          'tz': OracleTimestampTz(
            DateTime.utc(2024, 3, 15, 18, 20, 30),
            offsetMinutes: -480,
          ),
          'b': Uint8List.fromList([1, 2, 3]),
          'inf': double.infinity,
          'ninf': double.negativeInfinity,
          'n': 42,
          'list': <Object?>[
            Uint8List(0),
            DateTime(2000),
            <String, Object?>{
              'deep': Uint8List.fromList([0xff]),
              'x': null,
            },
            'tail',
          ],
        };
        final decoded =
            roundTrip(<String, Object?>{...doc, 'nan': double.nan})!
                as Map<String, Object?>;
        expect(decoded['nan'], isNaN);
        decoded.remove('nan');
        expect(decoded, equals(doc));
        expect(decoded.keys.toList(), equals(doc.keys.toList()));
        expect(decoded['b'], isA<Uint8List>());
        expect(decoded['tz'], isA<OracleTimestampTz>());
        final list = decoded['list']! as List<Object?>;
        expect(list[0], isA<Uint8List>());
        expect(list[1], isA<DateTime>());
      });

      test('a decoded server document re-encodes and decodes to an equal '
          'value (fetched-document re-bind)', () {
        // The server-captured mixed object from the decode group: DATE,
        // TIMESTAMP, TSTZ, BINARY_DOUBLE, BINARY_FLOAT and RAW members.
        const body =
            '0000131531397073829b000c00120002000f00060004000000090173016e0164'
            '02747302747a026264026266017284080703060508010402001a001c001f0027'
            '00330041004a004f017821c12b3c787c030f01010139787c030f0b151f0754d4'
            'c07c787c030f13151f000000000c3c36bff80000000000007fbf0000003a0003'
            '00ff10';
        final fetched = decodeOson(_hex('ff4a5a01 2106 08 0014 0055 $body'));
        final again = roundTrip(fetched)! as Map<String, Object?>;
        expect(again, equals(fetched));
        expect(
          again.keys.toList(),
          equals((fetched! as Map<String, Object?>).keys.toList()),
        );
        expect(again['tz'], isA<OracleTimestampTz>());
        expect(again['r'], isA<Uint8List>());
        expect(again['d'], isA<DateTime>());
      });
    });
  });

  group('assertValidJsonBindValue', () {
    Matcher throwsArgument(Object? message) => throwsA(
      isA<ArgumentError>().having((e) => e.message, 'message', message),
    );

    test('accepts every kind the decoder produces, as members', () {
      final doc = <String, Object?>{
        'd': DateTime(2024, 3, 15),
        'utc': DateTime.utc(2024, 3, 15, 1, 2, 3, 4, 5),
        'tz': OracleTimestampTz(DateTime.utc(2024), offsetMinutes: -570),
        'b': Uint8List.fromList([1, 2]),
        'nan': double.nan,
        'inf': double.infinity,
        'ninf': double.negativeInfinity,
        'huge': 1e300,
        'list': <Object?>[
          Uint8List(0),
          'x',
          1,
          true,
          null,
          <String, Object?>{},
        ],
      };
      expect(() => assertValidJsonBindValue(doc, 'v'), returnsNormally);
      expect(
        () => assertValidJsonBindValue(doc.values.toList(), 'v'),
        returnsNormally,
      );
    });

    test('scalar roots need allowScalarRoot (an explicitly JSON-typed '
        'bind); null and containers never do', () {
      final scalars = <Object>[
        'x',
        '',
        3,
        2.5,
        double.nan,
        true,
        false,
        DateTime(2024),
        OracleTimestampTz(DateTime.utc(2024), offsetMinutes: 0),
        Uint8List.fromList([1]),
      ];
      for (final value in scalars) {
        expect(
          () => assertValidJsonBindValue(value, 'v'),
          throwsArgument(contains('OracleDbType.json')),
          reason: '${value.runtimeType} without allowScalarRoot',
        );
        expect(
          () => assertValidJsonBindValue(value, 'v', allowScalarRoot: true),
          returnsNormally,
          reason: '${value.runtimeType} with allowScalarRoot',
        );
      }
      for (final value in <Object?>[null, <String, Object?>{}, <Object?>[]]) {
        expect(() => assertValidJsonBindValue(value, 'v'), returnsNormally);
      }
    });

    test('still rejects Set, Symbol, arbitrary objects, non-String keys, '
        'out-of-range dates and over-long field names — members and '
        'scalar roots alike', () {
      final cases = <Object, String>{
        <String, Object?>{
          'a': 1,
          's': <int>{1},
        }: 'v[member #2]',
        <Object?>[#sym]: 'Symbol',
        <Object?>[Duration.zero]: 'Duration',
        <String, Object?>{
          'deep': <Object?>[
            <String, Object?>{'o': Object()},
          ],
        }: 'v[member #1][0][member #1]',
        <Object, Object?>{1: 'x'}: 'keys must be String',
        <String, Object?>{'d': DateTime(-44)}: 'BCE',
        <Object?>[DateTime(0)]: 'BCE',
        <Object?>[DateTime(10000)]: '9999',
        <Object?>[OracleTimestampTz(DateTime.utc(-1), offsetMinutes: 0)]: 'BCE',
        <String, Object?>{'k' * 256: 1}: '256 bytes',
        // 128 two-byte characters: 128 code units but 256 UTF-8 bytes.
        <String, Object?>{'é' * 128: 1}: '256 bytes',
        <String, Object?>{
          'outer': <String, Object?>{'🚀' * 64: 1},
        }: 'at v[member #1])',
      };
      for (final MapEntry(key: value, value: message) in cases.entries) {
        for (final allowScalarRoot in [false, true]) {
          expect(
            () => assertValidJsonBindValue(
              value,
              'v',
              allowScalarRoot: allowScalarRoot,
            ),
            throwsArgument(contains(message)),
            reason: '$message (allowScalarRoot: $allowScalarRoot)',
          );
        }
      }
      for (final root in <Object>[
        <int>{1},
        #sym,
        Object(),
        DateTime(-44),
        DateTime(10000),
      ]) {
        expect(
          () => assertValidJsonBindValue(root, 'v', allowScalarRoot: true),
          throwsA(isA<ArgumentError>()),
          reason: '${root.runtimeType} scalar root',
        );
      }
      // The 255-byte boundary itself is accepted, multi-byte included.
      expect(
        () => assertValidJsonBindValue(<String, Object?>{
          'k' * 255: 1,
          '${'é' * 127}k': 2,
        }, 'v'),
        returnsNormally,
      );
    });

    test('errors never carry the bind value (OracleBind redaction policy)', () {
      const secret = 'hunter2-top-secret';
      for (final doc in <Object>[
        <String, Object?>{
          'password': secret,
          'bad': <int>{1},
        },
        <String, Object?>{'password': secret, 'd': DateTime(-44)},
        <String, Object?>{'password': secret, 'k' * 300: 1},
        <Object, Object?>{'password': secret, 1: 2},
        secret, // scalar root without allowScalarRoot
      ]) {
        try {
          assertValidJsonBindValue(doc, 'v');
          fail('expected an ArgumentError for $doc');
        } on ArgumentError catch (e) {
          expect(e.invalidValue, isNull);
          expect(e.toString(), isNot(contains(secret)));
          expect('${e.message}', isNot(contains(secret)));
          expect(e.toString(), isNot(contains('-44')));
        }
      }
    });

    test('paths name object members by position, never by key — keys are '
        'document content too', () {
      const secretKey = 'alice@example.com';
      for (final (doc, path) in <(Object, String)>[
        (
          <String, Object?>{
            'ok': 1,
            secretKey: <int>{1},
          },
          'v[member #2]',
        ),
        (
          <String, Object?>{
            secretKey: <Object?>[
              0,
              <String, Object?>{secretKey: DateTime(-1)},
            ],
          },
          'v[member #1][1][member #1]',
        ),
        (
          <String, Object?>{
            secretKey: <String, Object?>{'k' * 256: 1},
          },
          'at v[member #1])',
        ),
        (
          <String, Object?>{
            secretKey: <Object, Object?>{1: 'x'},
          },
          'at v[member #1])',
        ),
      ]) {
        for (final allowScalarRoot in [false, true]) {
          try {
            assertValidJsonBindValue(
              doc,
              'v',
              allowScalarRoot: allowScalarRoot,
            );
            fail('expected an ArgumentError for $path');
          } on ArgumentError catch (e) {
            expect(e.toString(), contains(path));
            expect(e.toString(), isNot(contains(secretKey)));
            expect(e.toString(), isNot(contains('alice')));
          }
        }
      }
    });
  });

  // ==========================================================================
  // Story 13.2 — JSON stored in a BLOB (the Oracle 12c `IS JSON` pattern).
  // `decodeJsonBlobBytes` is what the transport runs on every materialized
  // cell of a BLOB column the describe flags IS JSON / IS OSON.
  // ==========================================================================
  group('decodeJsonBlobBytes (BLOB IS JSON)', () {
    Uint8List utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));

    Uint8List utf16Bytes(
      String text, {
      required bool bigEndian,
      bool bom = false,
    }) {
      final units = <int>[if (bom) 0xfeff, ...text.codeUnits];
      final out = Uint8List(units.length * 2);
      for (var i = 0; i < units.length; i++) {
        final hi = (units[i] >> 8) & 0xff;
        final lo = units[i] & 0xff;
        out[i * 2] = bigEndian ? hi : lo;
        out[i * 2 + 1] = bigEndian ? lo : hi;
      }
      return out;
    }

    Matcher throwsUnsupported([String? message]) =>
        _throwsOracle(oraUnsupportedType, message);

    test(
      'object / array / scalar documents decode to Map / List / scalars',
      () {
        expect(
          decodeJsonBlobBytes(utf8Bytes('{"a":1}')),
          equals(<String, Object?>{'a': 1}),
        );
        expect(
          decodeJsonBlobBytes(utf8Bytes('[1,2]')),
          equals(<Object?>[1, 2]),
        );
        expect(decodeJsonBlobBytes(utf8Bytes('"s"')), equals('s'));
        expect(decodeJsonBlobBytes(utf8Bytes('3')), equals(3));
        expect(decodeJsonBlobBytes(utf8Bytes('3')), isA<int>());
        expect(decodeJsonBlobBytes(utf8Bytes('-2.5')), equals(-2.5));
        expect(decodeJsonBlobBytes(utf8Bytes('true')), isTrue);
        expect(decodeJsonBlobBytes(utf8Bytes('false')), isFalse);
        // A JSON `null` document is a value, not SQL NULL — it still decodes.
        expect(decodeJsonBlobBytes(utf8Bytes('null')), isNull);
      },
    );

    test('containers are Map<String, Object?> / List<Object?> like native '
        'JSON, keep member order, and nest', () {
      final decoded = decodeJsonBlobBytes(
        utf8Bytes(
          '{"zebra":1,"apple":[{"deep":[true,false,null,"x"]},2.5],'
          '"mango":{"k1":"v1"}}',
        ),
      );
      expect(decoded, isA<Map<String, Object?>>());
      final map = decoded! as Map<String, Object?>;
      expect(map.keys.toList(), equals(['zebra', 'apple', 'mango']));
      expect(map['apple'], isA<List<Object?>>());
      expect(
        map,
        equals(<String, Object?>{
          'zebra': 1,
          'apple': <Object?>[
            <String, Object?>{
              'deep': <Object?>[true, false, null, 'x'],
            },
            2.5,
          ],
          'mango': <String, Object?>{'k1': 'v1'},
        }),
      );
    });

    test('surrounding JSON whitespace is accepted', () {
      expect(
        decodeJsonBlobBytes(utf8Bytes(' \t\r\n [1] \n')),
        equals(<Object?>[1]),
      );
    });

    group('text encodings decode identically', () {
      // Multi-byte UTF-8, BMP non-Latin and a supplementary-plane character
      // (a UTF-16 surrogate pair) in both a key and a value.
      const text = '{"ké":"é€ \u{1F680}","n":[1,2.5,null,true]}';
      final expected = <String, Object?>{
        'ké': 'é€ \u{1F680}',
        'n': <Object?>[1, 2.5, null, true],
      };

      test('UTF-8 without BOM', () {
        expect(decodeJsonBlobBytes(utf8Bytes(text)), equals(expected));
      });

      test('UTF-8 with BOM (EF BB BF)', () {
        final bytes = Uint8List.fromList([
          0xef,
          0xbb,
          0xbf,
          ...utf8Bytes(text),
        ]);
        expect(decodeJsonBlobBytes(bytes), equals(expected));
      });

      test('UTF-16LE with BOM (FF FE)', () {
        final bytes = utf16Bytes(text, bigEndian: false, bom: true);
        expect(bytes.sublist(0, 2), equals([0xff, 0xfe]));
        expect(decodeJsonBlobBytes(bytes), equals(expected));
      });

      test('UTF-16BE with BOM (FE FF)', () {
        final bytes = utf16Bytes(text, bigEndian: true, bom: true);
        expect(bytes.sublist(0, 2), equals([0xfe, 0xff]));
        expect(decodeJsonBlobBytes(bytes), equals(expected));
      });

      test('BOM-less UTF-16LE / UTF-16BE (accepted by Oracle IS JSON) are '
          'detected from the NUL pattern', () {
        expect(
          decodeJsonBlobBytes(utf16Bytes(text, bigEndian: false)),
          equals(expected),
        );
        expect(
          decodeJsonBlobBytes(utf16Bytes(text, bigEndian: true)),
          equals(expected),
        );
        // Single-character scalar documents: the shortest UTF-16 form.
        expect(decodeJsonBlobBytes(_hex('3100')), equals(1));
        expect(decodeJsonBlobBytes(_hex('0031')), equals(1));
      });

      test('the bytes measured live from Oracle 23ai and 21c decode', () {
        // Exactly what `SELECT` returned for rows inserted with HEXTORAW on
        // both servers (the IS JSON constraint accepted every one).
        expect(decodeJsonBlobBytes(_hex('fffe5b0031005d00')), equals([1]));
        expect(decodeJsonBlobBytes(_hex('feff005b0031005d')), equals([1]));
        expect(decodeJsonBlobBytes(_hex('efbbbf5b315d')), equals([1]));
        expect(decodeJsonBlobBytes(_hex('5b0031005d00')), equals([1]));
      });
    });

    group('OSON bytes (IS JSON FORMAT OSON)', () {
      test('bytes starting FF 4A 5A decode exactly like decodeOson', () {
        final doc = <String, Object?>{
          'a': 1,
          'list': <Object?>['x', null, true, 2.5],
          'nested': <String, Object?>{'b': false},
        };
        final oson = encodeOson(doc);
        expect(decodeJsonBlobBytes(oson), equals(doc));
        expect(decodeJsonBlobBytes(oson), equals(decodeOson(oson)));
      });

      test('OSON scalar documents and Oracle-specific scalars decode', () {
        expect(decodeJsonBlobBytes(_scalarDoc(_dateNode)), isA<DateTime>());
        expect(
          decodeJsonBlobBytes(_scalarDoc(_dateNode)),
          equals(decodeOson(_scalarDoc(_dateNode))),
        );
      });

      test('the OSON bytes measured live in a FORMAT OSON column decode', () {
        // `{"o":2}` inserted as text into `BLOB CHECK (bo IS JSON FORMAT
        // OSON)`, read back raw (byte-identical on 23ai and 21c).
        final bytes = _hex(
          'ff4a5a01 2106 01 0002 0008 0000 9e 0000 016f '
          '84 01 01 0005 21 c103',
        );
        expect(decodeJsonBlobBytes(bytes), equals(<String, Object?>{'o': 2}));
      });

      test('corrupt / truncated OSON keeps the existing oraProtocolError', () {
        final full = encodeOson(<String, Object?>{'a': 1});
        expect(
          () => decodeJsonBlobBytes(Uint8List.sublistView(full, 0, 3)),
          _throwsOracle(oraProtocolError),
        );
        expect(
          () => decodeJsonBlobBytes(
            Uint8List.sublistView(full, 0, full.length - 1),
          ),
          _throwsOracle(oraProtocolError),
        );
      });

      test('unsupported OSON nodes keep the existing oraUnsupportedType', () {
        expect(
          () => decodeJsonBlobBytes(_scalarDoc('3d 800000013e')),
          throwsUnsupported('INTERVAL YEAR TO MONTH'),
        );
      });

      test('a partial magic prefix is NOT treated as OSON', () {
        // FF 4A alone: not the 3-byte magic, so it is text — and 0xFF can
        // never start valid UTF-8, so it fails loud as an encoding error.
        expect(
          () => decodeJsonBlobBytes(_hex('ff4a')),
          throwsUnsupported('UTF-8'),
        );
      });
    });

    group('fail loud — never raw bytes, never a silent null', () {
      test('zero-length value (EMPTY_BLOB(), accepted by IS JSON) throws', () {
        expect(
          () => decodeJsonBlobBytes(Uint8List(0)),
          throwsUnsupported('empty'),
        );
      });

      test('a byte-order mark with no document throws', () {
        for (final hex in ['efbbbf', 'fffe', 'feff']) {
          expect(
            () => decodeJsonBlobBytes(_hex(hex)),
            throwsUnsupported('not strict JSON'),
            reason: hex,
          );
        }
      });

      test('malformed and Oracle-lax JSON text throws (lax syntax is accepted '
          'by a default IS JSON constraint, not by this decoder)', () {
        for (final text in [
          '{nope',
          '{a:1}', // unquoted field name (lax)
          "{'a':1}", // single-quoted string (lax)
          '[TRUE]', // upper-case literal (lax)
          '[1] x', // trailing garbage
          '[1,]', // trailing comma
          '{"a":1}{"b":2}', // two documents
        ]) {
          expect(
            () => decodeJsonBlobBytes(utf8Bytes(text)),
            throwsUnsupported('not strict JSON'),
            reason: text,
          );
        }
        // A trailing NUL (measured: Oracle IS JSON accepts `[1]` + 00).
        expect(
          () => decodeJsonBlobBytes(_hex('5b315d00')),
          throwsUnsupported('not strict JSON'),
        );
      });

      test('invalid encodings throw naming the encoding', () {
        // Truncated 2-byte UTF-8 sequence inside a string.
        expect(
          () => decodeJsonBlobBytes(_hex('225b c3 22')),
          throwsUnsupported('UTF-8'),
        );
        // Odd UTF-16 byte count (BOM'd and BOM-less).
        expect(
          () => decodeJsonBlobBytes(_hex('fffe 5b00 3100 5d')),
          throwsUnsupported('UTF-16LE'),
        );
        expect(
          () => decodeJsonBlobBytes(_hex('005b 0031 00')),
          throwsUnsupported('UTF-16BE'),
        );
        // Unpaired surrogates: a high half at the end, a lone low half, and a
        // high half followed by a non-surrogate.
        expect(
          () => decodeJsonBlobBytes(_hex('feff 0022 d83d')),
          throwsUnsupported('unpaired high surrogate'),
        );
        expect(
          () => decodeJsonBlobBytes(_hex('fffe 2200 00de 2200')),
          throwsUnsupported('unpaired low surrogate'),
        );
        expect(
          () => decodeJsonBlobBytes(_hex('feff 0022 d83d 0022')),
          throwsUnsupported('unpaired high surrogate'),
        );
        // A UTF-32LE document is not a supported encoding: read as BOM-less
        // UTF-16LE its NUL code units are not JSON.
        expect(
          () => decodeJsonBlobBytes(_hex('5b000000310000005d000000')),
          throwsUnsupported('not strict JSON'),
        );
      });

      test('error messages never echo the document content', () {
        const secret = 'hunter2-top-secret';
        for (final bytes in [
          utf8Bytes('{"password":"$secret"'),
          utf8Bytes('{password:"$secret"}'),
          Uint8List.fromList([...utf8Bytes('{"p":"$secret'), 0xc3]),
        ]) {
          try {
            decodeJsonBlobBytes(bytes);
            fail('expected an OracleException');
          } on OracleException catch (e) {
            expect(e.message, isNot(contains(secret)));
            expect(e.toString(), isNot(contains(secret)));
            // Both opt-outs are named: the raw Uint8List and the OracleLob.
            expect(e.message, contains('rawJsonBlobs: true'));
            expect(e.message, contains('fetchLobs: true'));
          }
        }
      });
    });
  });
}
