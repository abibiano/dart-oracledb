import 'dart:typed_data';

import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/ttc_packet.dart';
import 'package:test/test.dart';

void main() {
  group('TtcPacket', () {
    group('constructor', () {
      test('creates packet with function code and payload', () {
        final payload = Uint8List.fromList([0x01, 0x02, 0x03]);
        final packet = TtcPacket(
          functionCode: ttcProtocol,
          payload: payload,
        );

        expect(packet.functionCode, equals(ttcProtocol));
        expect(packet.payload, equals(payload));
      });

      test('defaults sequence to 0', () {
        final packet = TtcPacket(
          functionCode: ttcExecute,
          payload: Uint8List(0),
        );

        expect(packet.sequence, equals(0));
      });

      test('accepts custom sequence number', () {
        final packet = TtcPacket(
          functionCode: ttcFetch,
          payload: Uint8List(0),
          sequence: 42,
        );

        expect(packet.sequence, equals(42));
      });

      test('defaults dataFlags to 0', () {
        final packet = TtcPacket(
          functionCode: ttcCommit,
          payload: Uint8List(0),
        );

        expect(packet.dataFlags, equals(0));
      });

      test('accepts custom dataFlags', () {
        final packet = TtcPacket(
          functionCode: ttcCommit,
          payload: Uint8List(0),
          dataFlags: ttcDataFlagEof,
        );

        expect(packet.dataFlags, equals(ttcDataFlagEof));
      });
    });

    group('encode', () {
      test('encodes empty payload packet', () {
        final packet = TtcPacket(
          functionCode: ttcPing,
          payload: Uint8List(0),
          sequence: 1,
        );

        final encoded = packet.encode();

        // Should have at least function code and sequence
        expect(encoded.isNotEmpty, isTrue);
        expect(encoded[0], equals(ttcPing));
      });

      test('encodes packet with payload', () {
        final payload = Uint8List.fromList([0xAA, 0xBB, 0xCC]);
        final packet = TtcPacket(
          functionCode: ttcExecute,
          payload: payload,
          sequence: 5,
        );

        final encoded = packet.encode();

        // Should contain function code, sequence, and payload
        expect(encoded.length, greaterThan(payload.length));
        expect(encoded[0], equals(ttcExecute));
      });

      test('includes data flags in encoded packet', () {
        final packet = TtcPacket(
          functionCode: ttcFetch,
          payload: Uint8List(0),
          dataFlags: ttcDataFlagEof | ttcDataFlagContinue,
        );

        final encoded = packet.encode();
        expect(encoded.isNotEmpty, isTrue);
      });
    });

    group('decode', () {
      test('decodes encoded packet back to original values', () {
        final originalPayload = Uint8List.fromList([0x11, 0x22, 0x33, 0x44]);
        final original = TtcPacket(
          functionCode: ttcAuthPhaseOne,
          payload: originalPayload,
          sequence: 10,
          dataFlags: ttcDataFlagNoRowsAffected,
        );

        final encoded = original.encode();
        final decoded = TtcPacket.decode(encoded);

        expect(decoded.functionCode, equals(original.functionCode));
        expect(decoded.sequence, equals(original.sequence));
        expect(decoded.dataFlags, equals(original.dataFlags));
        expect(decoded.payload, equals(original.payload));
      });

      test('throws on insufficient data', () {
        final shortData = Uint8List.fromList([0x01]); // Too short

        expect(
          () => TtcPacket.decode(shortData),
          throwsA(isA<OracleException>()),
        );
      });

      test('throws on empty data', () {
        expect(
          () => TtcPacket.decode(Uint8List(0)),
          throwsA(isA<OracleException>()),
        );
      });
    });

    group('round-trip', () {
      test('encode-decode preserves all fields for various function codes', () {
        final functionCodes = [
          ttcProtocol,
          ttcDataTypes,
          ttcAuthPhaseOne,
          ttcAuthPhaseTwo,
          ttcExecute,
          ttcFetch,
          ttcCommit,
          ttcRollback,
          ttcPing,
          ttcLobOp,
        ];

        for (final funcCode in functionCodes) {
          final payload = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
          final original = TtcPacket(
            functionCode: funcCode,
            payload: payload,
            sequence: funcCode, // Use funcCode as sequence for variety
            dataFlags: funcCode % 8,
          );

          final encoded = original.encode();
          final decoded = TtcPacket.decode(encoded);

          expect(decoded.functionCode, equals(original.functionCode),
              reason: 'Function code mismatch for $funcCode');
          expect(decoded.sequence, equals(original.sequence),
              reason: 'Sequence mismatch for $funcCode');
          expect(decoded.payload, equals(original.payload),
              reason: 'Payload mismatch for $funcCode');
        }
      });

      test('handles large payloads', () {
        final largePayload = Uint8List(1000);
        for (var i = 0; i < largePayload.length; i++) {
          largePayload[i] = i & 0xFF;
        }

        final original = TtcPacket(
          functionCode: ttcExecute,
          payload: largePayload,
          sequence: 255,
        );

        final encoded = original.encode();
        final decoded = TtcPacket.decode(encoded);

        expect(decoded.payload, equals(original.payload));
      });

      test('handles zero payload', () {
        final original = TtcPacket(
          functionCode: ttcPing,
          payload: Uint8List(0),
        );

        final encoded = original.encode();
        final decoded = TtcPacket.decode(encoded);

        expect(decoded.payload.isEmpty, isTrue);
        expect(decoded.functionCode, equals(ttcPing));
      });
    });

    group('toString', () {
      test('returns descriptive string', () {
        final packet = TtcPacket(
          functionCode: ttcExecute,
          payload: Uint8List.fromList([1, 2, 3]),
          sequence: 7,
        );

        final str = packet.toString();

        expect(str, contains('TtcPacket'));
        expect(str, contains('functionCode'));
        expect(str, contains('$ttcExecute'));
      });
    });
  });
}
