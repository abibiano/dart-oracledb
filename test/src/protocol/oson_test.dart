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
/// nodes, which the encoder (standard JSON only) refuses to produce.
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
    test('rejects non-finite doubles', () {
      expect(
        () => encodeOson(<Object?>[double.nan]),
        throwsA(isA<OracleException>()),
      );
      expect(
        () => encodeOson(<Object?>[double.infinity]),
        throwsA(isA<OracleException>()),
      );
    });

    test('rejects unsupported member types', () {
      expect(
        () => encodeOson(<Object?>[DateTime.utc(2026)]),
        throwsA(isA<OracleException>()),
      );
      expect(
        () => encodeOson(<String, Object?>{'b': Uint8List(2)}),
        throwsA(isA<OracleException>()),
      );
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

    test('encode/bind still reject the decoded Oracle scalar types '
        '(bind support is Story 13.3)', () {
      final decodedOnly = <Object>[
        DateTime(2024, 3, 15),
        OracleTimestampTz(DateTime.utc(2024), offsetMinutes: 0),
        Uint8List.fromList([1, 2]),
        double.nan,
        double.infinity,
      ];
      for (final value in decodedOnly) {
        expect(
          () => encodeOson(<String, Object?>{'v': value}),
          throwsA(isA<OracleException>()),
          reason: 'encodeOson must reject ${value.runtimeType}',
        );
        expect(
          () => assertValidJsonBindValue(<Object?>[value], 'doc'),
          throwsA(isA<ArgumentError>()),
          reason: 'bind validation must reject ${value.runtimeType}',
        );
      }
    });
  });
}
