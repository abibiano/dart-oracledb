import 'package:test/test.dart';
import 'package:oracledb/src/protocol/constants.dart';

void main() {
  group('TTC Function Codes', () {
    test('protocol negotiation constants are defined correctly', () {
      expect(ttcProtocol, equals(1));
      expect(ttcDataTypes, equals(2));
    });

    test('authentication constants are defined correctly', () {
      expect(ttcAuthPhaseOne, equals(0x76)); // 118
      expect(ttcAuthPhaseTwo, equals(0x73)); // 115
      expect(ttcClose, equals(0x09)); // 9
    });

    test('query operation constants are defined correctly', () {
      expect(ttcExecute, equals(0x03)); // 3
      expect(ttcFetch, equals(0x05)); // 5
      expect(ttcCommit, equals(0x0E)); // 14
      expect(ttcRollback, equals(0x0F)); // 15
      expect(ttcPing, equals(0x93)); // 147
    });

    test('LOB operation constant is defined correctly', () {
      expect(ttcLobOp, equals(0x60)); // 96
    });
  });

  group('Oracle Data Type Indicators', () {
    test('basic data types are defined correctly', () {
      expect(oraTypeVarchar, equals(1));
      expect(oraTypeNumber, equals(2));
      expect(oraTypeInteger, equals(3));
      expect(oraTypeFloat, equals(4));
      expect(oraTypeString, equals(5));
      expect(oraTypeVarnum, equals(6));
      expect(oraTypeLong, equals(8));
      expect(oraTypeVarchar2, equals(9));
    });

    test('date and row types are defined correctly', () {
      expect(oraTypeRowid, equals(11));
      expect(oraTypeDate, equals(12));
    });

    test('binary data types are defined correctly', () {
      expect(oraTypeRaw, equals(23));
      expect(oraTypeLongRaw, equals(24));
    });

    test('advanced data types are defined correctly', () {
      expect(oraTypeURowid, equals(104));
      expect(oraTypeClob, equals(112));
      expect(oraTypeBlob, equals(113));
      expect(oraTypeJson, equals(119));
    });

    test('timestamp types are defined correctly', () {
      expect(oraTypeTimestamp, equals(180));
      expect(oraTypeTimestampTz, equals(181));
      expect(oraTypeTimestampLtz, equals(231));
    });
  });

  group('Protocol Capability Flags', () {
    test('capability flags are defined as non-zero values', () {
      expect(capabilityEndOfCallStatus, isNonZero);
      expect(capabilityOci8Lob, isNonZero);
      expect(capabilitySessionState, isNonZero);
    });

    test('capability flags are distinct', () {
      final caps = {
        capabilityEndOfCallStatus,
        capabilityOci8Lob,
        capabilitySessionState,
      };
      expect(caps.length, equals(3),
          reason: 'All capability flags should be distinct');
    });
  });

  group('Protocol Error Codes', () {
    test('protocol-level error codes are defined', () {
      expect(oraMalformedPacket, equals(12571));
      expect(oraProtocolViolation, equals(12585));
      expect(oraUnsupportedType, equals(3115));
      expect(oraDataTypeNotSupported, equals(932));
    });
  });

  group('TTC Packet Flags', () {
    test('data flags are defined', () {
      expect(ttcDataFlagNoRowsAffected, isNonZero);
      expect(ttcDataFlagContinue, isNonZero);
      expect(ttcDataFlagEof, isNonZero);
    });
  });
}
