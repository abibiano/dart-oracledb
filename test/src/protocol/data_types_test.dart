import 'dart:typed_data';

import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/oracle_timestamp_tz.dart';
import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/data_types.dart';
import 'package:test/test.dart';

void main() {
  group('Oracle NUMBER encoding', () {
    test('encodes zero', () {
      final encoded = encodeNumber(0);
      expect(encoded, equals(Uint8List.fromList([0x80])));
    });

    test('encodes positive single digit', () {
      final encoded = encodeNumber(1);
      expect(encoded.isNotEmpty, isTrue);

      final decoded = decodeNumber(ReadBuffer(encoded));
      expect(decoded, equals(1));
    });

    test('encodes negative single digit', () {
      final encoded = encodeNumber(-1);
      expect(encoded.isNotEmpty, isTrue);

      final decoded = decodeNumber(ReadBuffer(encoded));
      expect(decoded, equals(-1));
    });

    test('round-trips positive integers', () {
      final values = [0, 1, 10, 99, 100, 123, 999, 1234, 9999, 12345, 99999];

      for (final value in values) {
        final encoded = encodeNumber(value);
        final decoded = decodeNumber(ReadBuffer(encoded));
        expect(decoded, equals(value), reason: 'Failed for value: $value');
      }
    });

    test('round-trips negative integers', () {
      final values = [-1, -10, -99, -100, -123, -999, -1234, -9999];

      for (final value in values) {
        final encoded = encodeNumber(value);
        final decoded = decodeNumber(ReadBuffer(encoded));
        expect(decoded, equals(value), reason: 'Failed for value: $value');
      }
    });

    test('encodes large numbers', () {
      const value = 1234567890;
      final encoded = encodeNumber(value);
      final decoded = decodeNumber(ReadBuffer(encoded));
      expect(decoded, equals(value));
    });

    test('encodes positive decimal 0.5', () {
      final encoded = encodeNumber(0.5);
      expect(encoded.isNotEmpty, isTrue);

      final decoded = decodeNumber(ReadBuffer(encoded));
      expect(decoded, equals(0.5));
      expect(decoded, isA<double>());
    });

    test('encodes positive decimal 1.23', () {
      final encoded = encodeNumber(1.23);
      expect(encoded.isNotEmpty, isTrue);

      final decoded = decodeNumber(ReadBuffer(encoded));
      expect(decoded, closeTo(1.23, 0.001));
      expect(decoded, isA<double>());
    });

    test('encodes positive decimal 123.45', () {
      final encoded = encodeNumber(123.45);
      expect(encoded.isNotEmpty, isTrue);

      final decoded = decodeNumber(ReadBuffer(encoded));
      expect(decoded, closeTo(123.45, 0.001));
      expect(decoded, isA<double>());
    });

    test('encodes negative decimal -1.5', () {
      final encoded = encodeNumber(-1.5);
      expect(encoded.isNotEmpty, isTrue);

      final decoded = decodeNumber(ReadBuffer(encoded));
      expect(decoded, closeTo(-1.5, 0.001));
      expect(decoded, isA<double>());
    });

    test('encodes very small decimal 0.0001', () {
      final encoded = encodeNumber(0.0001);
      expect(encoded.isNotEmpty, isTrue);

      final decoded = decodeNumber(ReadBuffer(encoded));
      expect(decoded, closeTo(0.0001, 0.00001));
      expect(decoded, isA<double>());
    });

    test('round-trips positive decimals', () {
      final values = [0.5, 1.23, 99.99, 123.456, 0.000001];

      for (final value in values) {
        final encoded = encodeNumber(value);
        final decoded = decodeNumber(ReadBuffer(encoded));
        expect(decoded, closeTo(value, 0.00001),
            reason: 'Failed for value: $value');
        expect(decoded, isA<double>());
      }
    });

    test('round-trips negative decimals', () {
      final values = [-0.5, -1.23, -99.99, -123.456];

      for (final value in values) {
        final encoded = encodeNumber(value);
        final decoded = decodeNumber(ReadBuffer(encoded));
        expect(decoded, closeTo(value, 0.00001),
            reason: 'Failed for value: $value');
        expect(decoded, isA<double>());
      }
    });

    test('decodes integer as int type, not double', () {
      final encoded = encodeNumber(123);
      final decoded = decodeNumber(ReadBuffer(encoded));
      expect(decoded, equals(123));
      expect(decoded, isA<int>());
    });

    test('decodes decimal as double type, not int', () {
      final encoded = encodeNumber(123.45);
      final decoded = decodeNumber(ReadBuffer(encoded));
      expect(decoded, isA<double>());
      expect(decoded is int, isFalse);
    });

    test('rejects double.nan', () {
      expect(
        () => encodeNumber(double.nan),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraDataTypeNotSupported)),
      );
    });

    test('rejects double.infinity', () {
      expect(
        () => encodeNumber(double.infinity),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraDataTypeNotSupported)),
      );
    });

    test('rejects double.negativeInfinity', () {
      expect(
        () => encodeNumber(double.negativeInfinity),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraDataTypeNotSupported)),
      );
    });

    test('encodes 678.90 without trailing-9 mantissa artifacts', () {
      // Regression: the old toStringAsFixed(20) path produced a mantissa
      // ending in 9 because 678.9 has no exact IEEE 754 representation.
      //
      // 678.9 splits to integer "678" (padded to "0678" for even pairs) and
      // fractional "9" (padded to "90"), giving base-100 digits 6, 78, 90 and
      // exponent 2. Positive encoding adds 1 to each digit:
      //   exponent: 192 + 2 = 0xC2
      //   digits:   6+1=0x07, 78+1=0x4F, 90+1=0x5B
      final encoded = encodeNumber(678.90);
      expect(encoded, equals(Uint8List.fromList([0xC2, 0x07, 0x4F, 0x5B])));
      // Decode must round-trip exactly.
      expect(decodeNumber(ReadBuffer(encoded)), equals(678.9));
    });

    test('encodes 0.1 + 0.2 without precision artifacts', () {
      // 0.1 + 0.2 = 0.30000000000000004 in IEEE 754. num.toString() reports
      // the shortest round-trip, so the encoded value must match that exact
      // double when decoded back.
      const v = 0.1 + 0.2;
      final encoded = encodeNumber(v);
      expect(decodeNumber(ReadBuffer(encoded)), closeTo(v, 1e-15));
    });

    test('encodes integer-valued double without collapsing trailing zeros', () {
      // Regression guard: stripping trailing zeros from the full numeric
      // string would turn 100 into 1. The trim is fractional only.
      for (final v in <num>[100, 1000, 1234567890, 100.0, 100.50]) {
        final encoded = encodeNumber(v);
        final decoded = decodeNumber(ReadBuffer(encoded));
        expect(decoded, equals(v), reason: 'Failed for $v');
      }
    });

    test('encodes large integer-valued double 123456789012345.67', () {
      const v = 123456789012345.67;
      final encoded = encodeNumber(v);
      final decoded = decodeNumber(ReadBuffer(encoded));
      expect(decoded, closeTo(v, 0.01));
    });

    test('encodes 1.005 without binary-rounding artifacts', () {
      // 1.005 is the canonical IEEE-754 binary-rounding surprise — it stores
      // as ~1.00499999999999989. num.toString() reports the shortest
      // round-trip ("1.005"), so the encoded mantissa must reflect that
      // value, not the underlying bit pattern.
      const v = 1.005;
      final encoded = encodeNumber(v);
      final decoded = decodeNumber(ReadBuffer(encoded));
      expect(decoded, closeTo(v, 1e-15));
    });

    test('decodeNumber with explicit length stops at field boundary', () {
      // Encode -100 (negative number whose encoding may omit the 0x66
      // terminator at the declared length) followed by garbage bytes that
      // belong to a hypothetical next field on the wire.
      final encoded = encodeNumber(-100);
      final fieldLen = encoded.length;
      final wire = Uint8List.fromList([
        ...encoded,
        0xDE, 0xAD, 0xBE, 0xEF, 0x01, // trailing field bytes
      ]);
      final buf = ReadBuffer(wire);
      final value = decodeNumber(buf, length: fieldLen);
      expect(value, equals(-100));
      // Exactly the encoded bytes were consumed; the trailing bytes are
      // available for the next field's decoder.
      expect(buf.position, equals(fieldLen));
      expect(buf.remaining, equals(5));
    });

    test('decodeNumber length stops decoding even without terminator', () {
      // Hand-build a negative NUMBER without the 0x66 sentinel — Oracle
      // omits it when the encoded byte count fills the declared field.
      // Value: -1, encoded as exponent 0x3E (≈ ~(192+0) & 0xFF) and digit
      // byte 100 (= 101 - 1).
      final fieldBytes = encodeNumber(-1);
      // Strip the trailing 0x66 if present, to simulate Oracle's truncation.
      Uint8List trimmed = fieldBytes;
      if (fieldBytes.last == 0x66) {
        trimmed = Uint8List.fromList(
          fieldBytes.sublist(0, fieldBytes.length - 1),
        );
      }
      // Append unrelated bytes after.
      final wire = Uint8List.fromList([...trimmed, 0x42, 0x42]);
      final buf = ReadBuffer(wire);
      final value = decodeNumber(buf, length: trimmed.length);
      expect(value, equals(-1));
      expect(buf.remaining, equals(2));
    });
  });

  group('NUMBER codec', () {
    // forceDouble for declared fixed-scale columns.
    test('forceDouble returns double for integer-valued NUMBERs', () {
      // 42 → [0xC1, 43]; 0 → [0x80]; -5 → [0x3E, 96, 102].
      final fortyTwo = decodeNumber(
        ReadBuffer(Uint8List.fromList([0xC1, 43])),
        forceDouble: true,
      );
      expect(fortyTwo, isA<double>());
      expect(fortyTwo, equals(42.0));

      final zero = decodeNumber(
        ReadBuffer(Uint8List.fromList([0x80])),
        forceDouble: true,
      );
      expect(zero, isA<double>(),
          reason: 'the special 0x80 zero must also honor forceDouble');
      expect(zero, equals(0));

      final negFive = decodeNumber(
        ReadBuffer(Uint8List.fromList([0x3E, 96, 102])),
        forceDouble: true,
      );
      expect(negFive, isA<double>());
      expect(negFive, equals(-5));
    });

    test('default (no forceDouble) keeps the int heuristic — backward compat',
        () {
      final v = decodeNumber(ReadBuffer(Uint8List.fromList([0xC1, 43])));
      expect(v, isA<int>());
      expect(v, equals(42));
    });

    test('forceDouble does not alter fractional decode', () {
      // 123.45 → [0xC2, 2, 24, 46] — double either way.
      final v = decodeNumber(
        ReadBuffer(Uint8List.fromList([0xC2, 2, 24, 46])),
        forceDouble: true,
      );
      expect(v, isA<double>());
      expect(v as double, closeTo(123.45, 1e-9));
    });

    // Exact boundaries of the magnitude guard (the far-out-of-range
    // cases double.minPositive / 1e200 are pinned in the encode group above).
    test('encodeNumber accepts 1e-130 and rejects 1e126 at the boundary', () {
      expect(() => encodeNumber(1e-130), returnsNormally);
      expect(
        () => encodeNumber(1e126),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraDataTypeNotSupported)),
      );
    });

    // Canonical mantissa: trailing zero base-100 pairs are stripped,
    // matching reference/node-oracledb/lib/impl/datahandlers/buffer.js
    // writeOracleNumber ("strip any trailing zeroes", exponent adjusted).
    test('encodeNumber emits the canonical short form for 10000', () {
      // 10000 = 1 × 100² → exponent byte 0xC3, single digit 1 → byte 0x02.
      expect(encodeNumber(10000), equals([0xC3, 0x02]));
    });

    test('encodeNumber canonical form covers more trailing-zero shapes', () {
      // 100 = 1 × 100¹; 1000000 = 1 × 100³; 120000 = 12 × 100²
      expect(encodeNumber(100), equals([0xC2, 0x02]));
      expect(encodeNumber(1000000), equals([0xC4, 0x02]));
      expect(encodeNumber(120000), equals([0xC3, 0x0D]));
    });

    test('encodeNumber canonical form for negatives keeps the terminator', () {
      // -10000: exponent ~(192+3) = 0x3C, digit 101-1 = 100 = 0x64, 0x66.
      expect(encodeNumber(-10000), equals([0x3C, 0x64, 0x66]));
    });

    test('canonicalized values still round-trip exactly', () {
      for (final v in <num>[100, 10000, -10000, 1000000, 120000, 100.5]) {
        final decoded = decodeNumber(ReadBuffer(encodeNumber(v)));
        expect(decoded, equals(v), reason: 'round-trip failed for $v');
      }
      // Guard: integer-part zeros must never collapse 100 → 1.
      expect(decodeNumber(ReadBuffer(encodeNumber(100))), isNot(equals(1)));
    });

    // >2^53 precision-loss contract pinned at the wire level.
    test('decodeNumber pins the 2^53+1 precision-loss contract', () {
      // 9007199254740993 (2^53 + 1) on the wire: exponent 8 → 0xC8, base-100
      // pairs [90,07,19,92,54,74,09,93] each +1.
      final bytes = Uint8List.fromList([0xC8, 91, 8, 20, 93, 55, 75, 10, 94]);
      final v = decodeNumber(ReadBuffer(bytes));
      // The true value is exactly halfway between the two nearest doubles
      // (2^53 and 2^53+2); IEEE-754 ties-to-even rounds DOWN to 2^53, which
      // the int-vs-double heuristic then returns as an int. The loss is
      // bounded (±1) and predictable — this pin locks the contract.
      expect(v, isA<int>());
      expect(v, equals(9007199254740992));
    });
  });

  group('Oracle TIMESTAMP encoding', () {
    test('encodes timestamp to 11 bytes', () {
      final dt = DateTime(2025, 12, 16, 14, 30, 45, 123, 456);
      final encoded = encodeTimestamp(dt);
      expect(encoded.length, equals(11));
    });

    test('encodes timestamp with milliseconds', () {
      final dt = DateTime(2025, 12, 16, 14, 30, 45, 123);
      final encoded = encodeTimestamp(dt);
      expect(encoded.isNotEmpty, isTrue);

      final decoded = decodeTimestamp(ReadBuffer(encoded));
      expect(decoded.millisecond, equals(123));
    });

    test('encodes timestamp with microseconds', () {
      final dt = DateTime(2025, 12, 16, 14, 30, 45, 123, 456);
      final encoded = encodeTimestamp(dt);
      expect(encoded.isNotEmpty, isTrue);

      final decoded = decodeTimestamp(ReadBuffer(encoded));
      expect(decoded.microsecond, equals(456));
    });

    test('round-trips timestamp with subsecond precision', () {
      final timestamps = [
        DateTime(2025, 12, 16, 14, 30, 45, 123, 456),
        DateTime(2025, 1, 1, 0, 0, 0, 0, 0),
        DateTime(2025, 6, 15, 12, 30, 15, 500, 250),
      ];

      for (final ts in timestamps) {
        final encoded = encodeTimestamp(ts);
        final decoded = decodeTimestamp(ReadBuffer(encoded));
        expect(decoded, equals(ts), reason: 'Failed for timestamp: $ts');
      }
    });

    test('decodes truncated 7-byte TIMESTAMP (zero fractional seconds)', () {
      // Oracle truncates trailing zero bytes on the wire — a TIMESTAMP with
      // zero fractional seconds arrives as 7 bytes (DATE portion only).
      final dt = DateTime(2024, 3, 15, 10, 30, 0);
      final dateBytes = encodeDate(dt);
      expect(dateBytes.length, equals(7));

      final decoded = decodeTimestamp(ReadBuffer(dateBytes));
      expect(decoded, equals(dt));
      expect(decoded.millisecond, equals(0));
      expect(decoded.microsecond, equals(0));
    });

    test('decodes 13-byte TIMESTAMP WITH TZ payload', () {
      // 7 DATE bytes + 4 nano bytes + 2 TZ bytes. TZ bytes are currently
      // discarded — locks in the new branch semantics.
      final dt = DateTime(2024, 3, 15, 10, 30, 45, 123);
      final tsBytes = encodeTimestamp(dt);
      expect(tsBytes.length, equals(11));
      final wire = Uint8List.fromList([...tsBytes, 32, 60]); // TZ +0:00 region
      final decoded = decodeTimestamp(ReadBuffer(wire));
      expect(decoded.millisecond, equals(123));
    });

    test('tolerates 8/9/10-byte payloads as zero fractional seconds', () {
      // node-oracledb parseOracleDate parity: a total length < 11 carries no
      // fractional-second field (trailing-zero-compressed form), so the extra
      // 1-3 bytes are ignored and fseconds is 0. The driver must decode the
      // date rather than reject the length.
      final dt = DateTime(2024, 3, 15, 10, 30, 45);
      final base = encodeDate(dt);
      expect(base.length, equals(7));
      for (final trailer in [
        [0x12], // 8 bytes
        [0x12, 0x34], // 9 bytes
        [0x12, 0x34, 0x56], // 10 bytes
      ]) {
        final wire = Uint8List.fromList([...base, ...trailer]);
        final decoded = decodeTimestamp(ReadBuffer(wire));
        expect(decoded, equals(dt),
            reason: 'length ${wire.length} must decode the date');
        expect(decoded.millisecond, equals(0));
        expect(decoded.microsecond, equals(0));
      }
    });

    test('tolerates a 12-byte payload: fseconds read, trailing byte ignored',
        () {
      // Total length >= 11 ⇒ the 4 fractional-second bytes (offset 7-10) are
      // read; the lone 12th byte is below the 13-byte TZ form and is ignored.
      final dt = DateTime(2024, 3, 15, 10, 30, 45, 123);
      final tsBytes = encodeTimestamp(dt);
      expect(tsBytes.length, equals(11));
      final wire = Uint8List.fromList([...tsBytes, 0x77]); // 12 bytes
      final decoded = decodeTimestamp(ReadBuffer(wire));
      expect(decoded, equals(dt));
      expect(decoded.millisecond, equals(123));
    });

    test('decodeTimestampTz still rejects a 12-byte payload (no zone bytes)',
        () {
      // Tolerance applies to the plain TIMESTAMP path; a TSTZ payload missing
      // its two zone bytes (never zero-truncated) remains a protocol error.
      final tsBytes = encodeTimestamp(DateTime.utc(2024, 3, 15, 10, 30, 45));
      final wire = Uint8List.fromList([...tsBytes, 0x77]); // 12 bytes
      expect(
        () => decodeTimestampTz(ReadBuffer(wire)),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
      );
    });

    test('a payload shorter than 7 bytes underflows (genuine truncation)', () {
      // Below the DATE-shaped minimum the base-byte reads run out — this must
      // surface as the underflow subtype so the completion probe keeps its
      // "need more packets" semantics, NOT a tolerant decode.
      final wire = Uint8List(5)..[0] = 120;
      expect(
        () => decodeTimestamp(ReadBuffer(wire)),
        throwsA(isA<BufferUnderflowException>()),
      );
    });

    test('distinguishes TIMESTAMP (11 bytes) from DATE (7 bytes)', () {
      final dt = DateTime(2025, 12, 16, 14, 30, 45, 123, 456);
      final timestampEncoded = encodeTimestamp(dt);
      final dateEncoded = encodeDate(dt);

      expect(timestampEncoded.length, equals(11));
      expect(dateEncoded.length, equals(7));
    });

    // TSTZ decodes to a UTC DateTime.
    // The server sends the date/time fields already normalized to UTC
    // (verified live + against
    // node-oracledb parseOracleDate); the offset bytes are presentation
    // metadata. The old `fields - offset` arithmetic double-applied the
    // offset and shifted every TSTZ instant.
    test('decodes 13-byte TZ payload: fields ARE the UTC instant (+05:30)',
        () {
      // Fields 05:00:45.123 + zone bytes +05:30 == instant 05:00:45.123 UTC
      // (rendered by Oracle as wall-clock 10:30:45.123 at +05:30).
      final dateBytes = encodeTimestamp(
        DateTime.utc(2024, 3, 15, 5, 0, 45, 123),
      );
      final wire = Uint8List.fromList([
        ...dateBytes,
        20 + 5, // byte 11: hour offset +5
        60 + 30, // byte 12: minute offset +30
      ]);
      final decoded = decodeTimestamp(ReadBuffer(wire));
      expect(decoded.isUtc, isTrue);
      expect(
        decoded,
        equals(DateTime.utc(2024, 3, 15, 5, 0, 45, 123)),
        reason: 'offset bytes must not be re-applied to UTC fields',
      );
    });

    test('decodes 13-byte TZ payload: fields ARE the UTC instant (-08:00)',
        () {
      final dateBytes = encodeTimestamp(
        DateTime.utc(2024, 3, 15, 18, 30, 45),
      );
      // -8:00 means hour byte = 20 + (-8) = 12, minute byte = 60 + 0 = 60.
      final wire = Uint8List.fromList([...dateBytes, 12, 60]);
      final decoded = decodeTimestamp(ReadBuffer(wire));
      expect(decoded.isUtc, isTrue);
      expect(decoded, equals(DateTime.utc(2024, 3, 15, 18, 30, 45)));
    });

    test('decodes 13-byte TZ payload with +00:00 offset', () {
      final dateBytes = encodeTimestamp(
        DateTime.utc(2024, 3, 15, 10, 30, 45),
      );
      final wire = Uint8List.fromList([...dateBytes, 20, 60]);
      final decoded = decodeTimestamp(ReadBuffer(wire));
      expect(decoded.isUtc, isTrue);
      expect(decoded, equals(DateTime.utc(2024, 3, 15, 10, 30, 45)));
    });

    test('rejects TZ region-id payload (byte11 high bit set)', () {
      final dateBytes = encodeTimestamp(
        DateTime.utc(2024, 3, 15, 10, 30, 45),
      );
      // 0x80 set on byte 11 = region id, not a numeric offset.
      final wire = Uint8List.fromList([...dateBytes, 0x80, 0x01]);
      expect(
        () => decodeTimestamp(ReadBuffer(wire)),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)),
      );
    });

    test('truncates sub-microsecond fractional seconds toward zero', () {
      // Build an 11-byte TIMESTAMP whose nanosecond field is 123_456_789ns.
      // Expected: microseconds == 123_456 (floor). The rounding contract is
      // explicitly floor (`nanos ~/ 1000`), not banker's rounding.
      const nanos = 123456789;
      final wire = Uint8List.fromList([
        120, // century 2000s (20 + 100)
        124, // year 24 (24 + 100)
        3, // month
        15, // day
        11, // hour 10 (10 + 1)
        31, // minute 30 (30 + 1)
        46, // second 45 (45 + 1)
        (nanos >> 24) & 0xFF,
        (nanos >> 16) & 0xFF,
        (nanos >> 8) & 0xFF,
        nanos & 0xFF,
      ]);
      final decoded = decodeTimestamp(ReadBuffer(wire));
      expect(decoded.millisecond * 1000 + decoded.microsecond, equals(123456));
    });

    test('rejects BCE TIMESTAMP (century byte < 100)', () {
      // Oracle encodes BCE century as 100 - abs(century). Any byte < 100 is BCE.
      final wire = Uint8List.fromList([
        99, // BCE century
        100,
        1, 1, 1, 1, 1, // DATE portion fillers (encoded values, +1 offset)
      ]);
      expect(
        () => decodeTimestamp(ReadBuffer(wire)),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)),
      );
    });
  });

  // Opt-in TZ-preserving wrapper codec.
  group('OracleTimestampTz codec', () {
    Uint8List tzWire(DateTime wallClockUtc, int tzByte11, int tzByte12) =>
        Uint8List.fromList(
            [...encodeTimestamp(wallClockUtc), tzByte11, tzByte12]);

    test('decodeTimestampTz preserves a +05:30 offset and the UTC instant',
        () {
      // The wire fields are the UTC instant; the zone bytes are metadata.
      // Instant 05:00:45.123 UTC at zone +05:30 == wall-clock 10:30:45.123.
      final wire =
          tzWire(DateTime.utc(2024, 3, 15, 5, 0, 45, 123), 20 + 5, 60 + 30);
      final decoded = decodeTimestampTz(ReadBuffer(wire));
      expect(decoded.utc, equals(DateTime.utc(2024, 3, 15, 5, 0, 45, 123)));
      expect(decoded.tzHourOffset, equals(5));
      expect(decoded.tzMinuteOffset, equals(30));
      expect(decoded.timeZoneOffset,
          equals(const Duration(hours: 5, minutes: 30)));
      expect(decoded.wallClock,
          equals(DateTime.utc(2024, 3, 15, 10, 30, 45, 123)));
    });

    test('decodeTimestampTz preserves a -08:00 offset', () {
      final wire = tzWire(DateTime.utc(2024, 3, 15, 18, 30, 45), 20 - 8, 60);
      final decoded = decodeTimestampTz(ReadBuffer(wire));
      expect(decoded.utc, equals(DateTime.utc(2024, 3, 15, 18, 30, 45)));
      expect(decoded.tzHourOffset, equals(-8));
      expect(decoded.tzMinuteOffset, equals(0));
      expect(decoded.wallClock, equals(DateTime.utc(2024, 3, 15, 10, 30, 45)));
    });

    test('decodeTimestampTz agrees with decodeTimestamp on the instant', () {
      final wire =
          tzWire(DateTime.utc(2024, 3, 15, 10, 30, 45, 123), 20 + 5, 60 + 30);
      final viaDefault = decodeTimestamp(ReadBuffer(wire));
      final viaWrapper = decodeTimestampTz(ReadBuffer(wire));
      expect(viaWrapper.utc, equals(viaDefault));
    });

    // TSTZ zone bytes encode +20/+60 and are never zero (even for
    // +00:00 → bytes 20/60), so Oracle's trailing-zero truncation can never
    // remove them. A 7/11-byte payload on this decoder means stream
    // misalignment — fail loud instead of fabricating a +00:00 offset.
    test('decodeTimestampTz rejects a short 7-byte payload', () {
      final wire = encodeDate(DateTime.utc(2024, 3, 15, 10, 30, 45));
      expect(wire.length, equals(7));
      expect(
        () => decodeTimestampTz(ReadBuffer(wire)),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
      );
    });

    test('decodeTimestampTz rejects a short 11-byte payload', () {
      final wire = encodeTimestamp(DateTime.utc(2024, 3, 15, 10, 30, 45, 123));
      expect(wire.length, equals(11));
      expect(
        () => decodeTimestampTz(ReadBuffer(wire)),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
      );
    });

    // Malformed zone-byte combinations must surface as protocol errors —
    // never as the OracleTimestampTz constructor's ArgumentError leaking out
    // of a decode path.
    test('decodeTimestampTz rejects bytes 34/90 (+14:30 — past the ceiling)',
        () {
      final wire = tzWire(DateTime.utc(2024, 3, 15, 10, 30, 45), 34, 90);
      expect(
        () => decodeTimestampTz(ReadBuffer(wire)),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
      );
    });

    test('decodeTimestampTz rejects mixed-sign zone bytes 25/30 (+5:-30)', () {
      final wire = tzWire(DateTime.utc(2024, 3, 15, 10, 30, 45), 25, 30);
      expect(
        () => decodeTimestampTz(ReadBuffer(wire)),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
      );
    });

    test('decodeTimestamp rejects the same malformed zone bytes', () {
      // The shared parser guards both decode paths identically.
      for (final bytes in [
        [34, 90], // +14:30
        [25, 30], // +5:-30 mixed sign
        [15, 90], // -5:+30 mixed sign
      ]) {
        final wire =
            tzWire(DateTime.utc(2024, 3, 15, 10, 30, 45), bytes[0], bytes[1]);
        expect(
          () => decodeTimestamp(ReadBuffer(wire)),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
          reason: 'zone bytes $bytes must be a protocol error',
        );
      }
    });

    test('decodeTimestampTz accepts the +00:00 zone bytes 20/60', () {
      final wire = tzWire(DateTime.utc(2024, 3, 15, 10, 30, 45), 20, 60);
      final decoded = decodeTimestampTz(ReadBuffer(wire));
      expect(decoded.utc, equals(DateTime.utc(2024, 3, 15, 10, 30, 45)));
      expect(decoded.offsetMinutes, equals(0));
    });

    test('decodeTimestampTz rejects region-id zones like decodeTimestamp', () {
      final wire = tzWire(DateTime.utc(2024, 3, 15, 10, 30, 45), 0x80, 0x01);
      expect(
        () => decodeTimestampTz(ReadBuffer(wire)),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)),
      );
    });

    test('encodeTimestampTz writes 13 bytes with the original offset', () {
      final value = OracleTimestampTz.fromHourMinute(
        DateTime.utc(2024, 3, 15, 5, 0, 45, 123),
        5,
        30,
      );
      final wire = encodeTimestampTz(value);
      expect(wire.length, equals(13));
      expect(wire[11], equals(20 + 5));
      expect(wire[12], equals(60 + 30));
    });

    test('decode → re-encode reproduces identical wire bytes (re-bind)', () {
      final original =
          tzWire(DateTime.utc(2024, 3, 15, 10, 30, 45, 123), 20 + 5, 60 + 30);
      final decoded = decodeTimestampTz(ReadBuffer(original));
      final reEncoded = encodeTimestampTz(decoded);
      expect(reEncoded, equals(original),
          reason: 'a SELECT → bind round-trip must not shift the zone');
    });

    test('encode → decode round-trips a negative offset value', () {
      final value = OracleTimestampTz.fromHourMinute(
        DateTime.utc(2024, 6, 1, 18, 30, 0),
        -8,
        0,
      );
      final decoded = decodeTimestampTz(ReadBuffer(encodeTimestampTz(value)));
      expect(decoded, equals(value));
    });

    // Migrated from the deleted `encodeValue` dispatch: the live bind
    // path encodes through `encodeTimestampTz` directly.
    test('encodeTimestampTz emits the +20/+60 zone bytes for +05:30', () {
      final value = OracleTimestampTz.fromHourMinute(
        DateTime.utc(2024, 3, 15, 5, 0, 45),
        5,
        30,
      );
      final wire = encodeTimestampTz(value);
      expect(wire.length, equals(13));
      expect(wire[11], equals(25));
      expect(wire[12], equals(90));
    });

    // Migrated from the deleted `decodeValue` dispatch: the live
    // column path picks decodeTimestamp vs decodeTimestampTz by the
    // connection's preserveTimestampTimeZone flag.
    test('decodeTimestamp vs decodeTimestampTz: wrapper only when opted in',
        () {
      final wire =
          tzWire(DateTime.utc(2024, 3, 15, 10, 30, 45), 20 + 5, 60 + 30);
      final byDefault = decodeTimestamp(ReadBuffer(wire));
      expect(byDefault, isA<DateTime>(),
          reason: 'default decode contract is unchanged');
      final optedIn = decodeTimestampTz(ReadBuffer(wire));
      expect(optedIn.utc, equals(byDefault));
      expect(optedIn.offsetMinutes, equals(330));
    });
  });

  group('Oracle DATE encoding', () {
    test('encodes date to 7 bytes', () {
      final dt = DateTime(2025, 12, 15, 14, 30, 45);
      final encoded = encodeDate(dt);
      expect(encoded.length, equals(7));
    });

    test('encodes century correctly', () {
      final dt = DateTime(2025, 1, 1);
      final encoded = encodeDate(dt);
      expect(encoded[0], equals(120)); // 20 + 100 = 120
    });

    test('encodes year correctly', () {
      final dt = DateTime(2025, 1, 1);
      final encoded = encodeDate(dt);
      expect(encoded[1], equals(125)); // 25 + 100 = 125
    });

    test('encodes month correctly', () {
      final dt = DateTime(2025, 12, 1);
      final encoded = encodeDate(dt);
      expect(encoded[2], equals(12));
    });

    test('encodes day correctly', () {
      final dt = DateTime(2025, 1, 15);
      final encoded = encodeDate(dt);
      expect(encoded[3], equals(15));
    });

    test('encodes hour correctly', () {
      final dt = DateTime(2025, 1, 1, 14);
      final encoded = encodeDate(dt);
      expect(encoded[4], equals(15)); // 14 + 1 = 15
    });

    test('encodes minute correctly', () {
      final dt = DateTime(2025, 1, 1, 0, 30);
      final encoded = encodeDate(dt);
      expect(encoded[5], equals(31)); // 30 + 1 = 31
    });

    test('encodes second correctly', () {
      final dt = DateTime(2025, 1, 1, 0, 0, 45);
      final encoded = encodeDate(dt);
      expect(encoded[6], equals(46)); // 45 + 1 = 46
    });

    test('round-trips DateTime values', () {
      final dates = [
        DateTime(2025, 12, 15, 14, 30, 45),
        DateTime(2000, 1, 1, 0, 0, 0),
        DateTime(1999, 6, 15, 12, 0, 0),
        DateTime(2030, 12, 31, 23, 59, 59),
      ];

      for (final dt in dates) {
        final encoded = encodeDate(dt);
        final decoded = decodeDate(ReadBuffer(encoded));
        expect(decoded, equals(dt), reason: 'Failed for date: $dt');
      }
    });

    test('rejects BCE DATE (century byte < 100)', () {
      final wire = Uint8List.fromList([99, 100, 1, 1, 1, 1, 1]);
      expect(
        () => decodeDate(ReadBuffer(wire)),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)),
      );
    });
  });

  group('VARCHAR2 encoding', () {
    test('encodes empty string', () {
      final encoded = encodeVarchar('');
      expect(encoded, isA<Uint8List>());
    });

    test('encodes ASCII string', () {
      final encoded = encodeVarchar('Hello');
      expect(encoded.isNotEmpty, isTrue);

      final decoded = decodeVarchar(ReadBuffer(encoded), encoded.length);
      expect(decoded, equals('Hello'));
    });

    test('encodes UTF-8 string', () {
      final encoded = encodeVarchar('日本語');
      expect(encoded.isNotEmpty, isTrue);
    });

    test('round-trips various strings', () {
      final strings = [
        '',
        'a',
        'Hello World',
        'Special chars: !@#\$%^&*()',
        '日本語テスト',
        'Mixed 日本語 and English',
      ];

      for (final str in strings) {
        final encoded = encodeVarchar(str);
        final decoded = decodeVarchar(ReadBuffer(encoded), encoded.length);
        expect(decoded, equals(str), reason: 'Failed for: "$str"');
      }
    });
  });

  group('NULL value handling', () {
    test('encodes NULL', () {
      final encoded = encodeNull();
      expect(encoded, isA<Uint8List>());
    });

    test('isNull returns true for NULL encoded value', () {
      final encoded = encodeNull();
      expect(isNullValue(encoded), isTrue);
    });

    test('isNull returns false for non-NULL value', () {
      final encoded = encodeNumber(42);
      expect(isNullValue(encoded), isFalse);
    });
  });

  // Migrated from the deleted `encodeValue`/`decodeValue` test-only dispatch:
  // the same contracts pinned against the direct codec functions the
  // live bind/column paths actually use.
  group('direct codec round-trips (former encodeValue/decodeValue)', () {
    test('encodes int as NUMBER and decodes it back', () {
      final encoded = encodeNumber(123);
      expect(encoded.isNotEmpty, isTrue);
      expect(decodeNumber(ReadBuffer(encoded)), equals(123));
    });

    test('encodes String as VARCHAR and decodes it back', () {
      final encoded = encodeVarchar('Hello');
      expect(encoded.isNotEmpty, isTrue);
      expect(decodeVarchar(ReadBuffer(encoded), encoded.length),
          equals('Hello'));
    });

    test('encodes DateTime as 7-byte DATE and decodes it back', () {
      final dt = DateTime(2025, 12, 15, 10, 30, 0);
      final encoded = encodeDate(dt);
      expect(encoded.length, equals(7));
      expect(decodeDate(ReadBuffer(encoded)), equals(dt));
    });

    test('encodeNull emits the NULL marker', () {
      expect(isNullValue(encodeNull()), isTrue);
    });

    test('decodes NUMBER to int via the bounded-length form', () {
      final encoded = encodeNumber(42);
      final value = decodeNumber(ReadBuffer(encoded), length: encoded.length);
      expect(value, equals(42));
    });
  });

  group('inferOraTypeForValue (shared bind inference)', () {
    test('maps every supported Dart type to its wire type', () {
      expect(inferOraTypeForValue(null), equals(oraTypeVarchar));
      expect(inferOraTypeForValue('text'), equals(oraTypeVarchar));
      expect(inferOraTypeForValue(42), equals(oraTypeNumber));
      expect(inferOraTypeForValue(3.14), equals(oraTypeNumber));
      expect(inferOraTypeForValue(DateTime(2024, 3, 15)), equals(oraTypeDate),
          reason: 'DateTime deliberately maps to DATE, not TIMESTAMP — both '
              'pre-existing tables agreed on this');
      expect(
          inferOraTypeForValue(OracleTimestampTz(DateTime.utc(2024),
              offsetMinutes: 0)),
          equals(oraTypeTimestampTz));
      expect(inferOraTypeForValue(Uint8List.fromList([1, 2])),
          equals(oraTypeRaw));
    });

    test('returns null for unsupported Dart types', () {
      expect(inferOraTypeForValue(Object()), isNull);
      expect(inferOraTypeForValue(const Duration(seconds: 1)), isNull);
      // Top-level bool binds stay unsupported: Oracle has no SQL BOOLEAN
      // bind in this driver's scope (bools are valid JSON *members* only).
      expect(inferOraTypeForValue(true), isNull);
    });

    test('Map and List bind values infer native JSON', () {
      expect(inferOraTypeForValue(<String, Object?>{'a': 1}),
          equals(oraTypeJson));
      expect(inferOraTypeForValue(<Object?>[1, 2, 3]), equals(oraTypeJson));
      // Regression trap: Uint8List is a List<int> but must stay RAW.
      expect(inferOraTypeForValue(Uint8List(3)), equals(oraTypeRaw));
    });
  });

  group('Review patches — encode/decode symmetry hardening', () {
    test('encodeDate rejects BCE years symmetrically with decode', () {
      expect(
        () => encodeDate(DateTime(-44, 3, 15)),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)),
      );
      expect(
        () => encodeDate(DateTime(0, 1, 1)),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)),
      );
    });

    test('encodeTimestamp rejects BCE years symmetrically with decode', () {
      expect(
        () => encodeTimestamp(DateTime(-1, 1, 1, 12)),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)),
      );
    });

    test('encodeNumber rejects magnitudes outside Oracle NUMBER range', () {
      // double.minPositive ≈ 5e-324 — below Oracle's 1e-130 floor.
      expect(
        () => encodeNumber(double.minPositive),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraDataTypeNotSupported)),
      );
      // 1e200 — above Oracle's 1e126 ceiling.
      expect(
        () => encodeNumber(1e200),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraDataTypeNotSupported)),
      );
    });

    test('decodeNumber rejects zero-length wire field', () {
      // A NUMBER with length=0 (not the NULL-indicator path) is a stream
      // misalignment, not a legal Oracle response. Bail before consuming a
      // byte we have no right to.
      final buffer = ReadBuffer(Uint8List.fromList([0xC1, 6]));
      expect(
        () => decodeNumber(buffer, length: 0),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
      );
    });

    test(
        'decodeTimestamp rejects out-of-range TZ offset bytes (corrupted '
        'wire payload)', () {
      // 13-byte TIMESTAMP with byte11=0 (→ -20h, well below the legal -12h
      // floor). Must surface as a protocol error rather than silently
      // constructing a wildly wrong UTC instant.
      final bytes = Uint8List.fromList([
        120, 126, 3, 15, 11, 31, 46, // DATE portion (2026-03-15 10:30:45)
        0, 0, 0, 0, // nanos=0
        0, 60, // byte11=0 → -20h, byte12=60 → 0 minutes
      ]);
      expect(
        () => decodeTimestamp(ReadBuffer(bytes)),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
      );
    });
  });
}
