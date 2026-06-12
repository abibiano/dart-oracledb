/// Unit tests for FAST_AUTH protocol message construction.
///
/// Validates that FastAuthRequest correctly embeds:
/// 1. Protocol negotiation (includes message type byte — spec text was incorrect)
/// 2. DataTypes negotiation (includes message type byte — spec text was incorrect)
/// 3. AUTH_PHASE_ONE (WITH full function header)
/// 4. Sequence counter handling (sequence=1 for FAST_AUTH)
/// 5. Complete message body structure (150-500 bytes; full TNS packet is ~2780 bytes)
@Tags(['unit', 'protocol'])
library;

import 'dart:typed_data';

import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/messages/fast_auth_message.dart';
import 'package:test/test.dart';

void main() {
  group('FAST_AUTH Protocol Message Construction', () {
    late FastAuthRequest fastAuthMessage;
    late Uint8List clientNonce;
    late Uint8List compileCaps;
    late Uint8List runtimeCaps;
    late List<List<int>> dataTypes;

    setUp(() {
      // Typical FAST_AUTH parameters
      clientNonce = Uint8List.fromList(List.generate(16, (i) => i + 1));
      compileCaps = Uint8List.fromList(List.generate(48, (i) => 0));
      runtimeCaps = Uint8List.fromList(List.generate(48, (i) => 0));
      dataTypes = [
        [2, 1, 0], // VARCHAR2
        [96, 1, 0], // NUMBER
      ];

      fastAuthMessage = FastAuthRequest(
        username: 'testuser',
        clientNonce: clientNonce,
        compileCaps: compileCaps,
        runtimeCaps: runtimeCaps,
        dataTypes: dataTypes,
        ttcFieldVersion: 13,
        sequence: 1, // FAST_AUTH uses sequence=1
      );
    });

    test('Protocol negotiation embedded (includes message type byte)', () {
      final buffer = WriteBuffer();
      fastAuthMessage.encode(buffer);
      final bytes = buffer.toBytes();

      expect(bytes.length, greaterThan(4),
          reason: 'Message should have FAST_AUTH header + Protocol content');

      // Search for Protocol header as a two-byte pattern [type=1, version=6]
      // to avoid false matches on capability or length bytes that happen to be 1.
      var protocolTypeIndex = -1;
      for (int i = 0; i < bytes.length - 1; i++) {
        if (bytes[i] == ttcMsgTypeProtocol && bytes[i + 1] == 6) {
          protocolTypeIndex = i;
          break;
        }
      }
      expect(protocolTypeIndex, greaterThan(0),
          reason: 'Protocol header [type=1, version=6] should be embedded');
      expect(protocolTypeIndex, lessThan(50),
          reason:
              'Protocol message should be near start after FAST_AUTH header');
    });

    test('DataTypes negotiation embedded (includes message type byte)', () {
      final buffer = WriteBuffer();
      fastAuthMessage.encode(buffer);
      final bytes = buffer.toBytes();

      // Find DataTypes message type (0x02) after Protocol message
      final dataTypesIndex = bytes.indexOf(ttcMsgTypeDataTypes);
      expect(dataTypesIndex, greaterThan(0),
          reason: 'DataTypes message type (2) should be embedded');

      // DataTypes should come after Protocol
      final protocolIndex = bytes.indexOf(ttcMsgTypeProtocol);
      expect(dataTypesIndex, greaterThan(protocolIndex),
          reason: 'DataTypes should follow Protocol');
    });

    test('AUTH_PHASE_ONE embedded with full function header', () {
      final buffer = WriteBuffer();
      fastAuthMessage.encode(buffer);
      final bytes = buffer.toBytes();

      // Find AUTH_PHASE_ONE function header
      // Function header: [ttcMsgTypeFunction(3), ttcAuthPhaseOne(0x76), sequence]
      // Look for ttcAuthPhaseOne (0x76 = 118 decimal)
      const authPhaseOneCode = 0x76;
      var functionIndex = -1;
      for (int i = 0; i < bytes.length - 1; i++) {
        if (bytes[i] == ttcMsgTypeFunction &&
            bytes[i + 1] == authPhaseOneCode) {
          functionIndex = i;
          break;
        }
      }

      expect(functionIndex, greaterThan(0),
          reason:
              'Function message type (3) with AUTH_PHASE_ONE (0x76) should be embedded');

      // Verify sequence byte follows
      expect(bytes[functionIndex + 2], equals(1),
          reason: 'Sequence byte should follow AUTH_PHASE_ONE code');

      // AUTH_PHASE_ONE should come after DataTypes
      final dataTypesIndex = bytes.indexOf(ttcMsgTypeDataTypes);
      expect(functionIndex, greaterThan(dataTypesIndex),
          reason: 'AUTH_PHASE_ONE should follow DataTypes');
    });

    test('Sequence counter initialized to 1 for FAST_AUTH', () {
      final buffer = WriteBuffer();
      final messageWithSeq1 = FastAuthRequest(
        username: 'testuser',
        clientNonce: clientNonce,
        compileCaps: compileCaps,
        runtimeCaps: runtimeCaps,
        dataTypes: dataTypes,
        ttcFieldVersion: 13,
        sequence: 1, // FAST_AUTH uses sequence=1
      );

      messageWithSeq1.encode(buffer);
      final bytes = buffer.toBytes();

      // Find AUTH_PHASE_ONE function header (0x76)
      const authPhaseOneCode = 0x76;
      var functionIndex = -1;
      for (int i = 0; i < bytes.length - 2; i++) {
        if (bytes[i] == ttcMsgTypeFunction &&
            bytes[i + 1] == authPhaseOneCode) {
          functionIndex = i;
          break;
        }
      }

      expect(functionIndex, greaterThan(0));
      final sequenceByte = bytes[functionIndex + 2]; // Sequence is 3rd byte
      expect(sequenceByte, equals(1),
          reason: 'FAST_AUTH should use sequence=1');
    });

    test('Complete message structure is reasonable size', () {
      final buffer = WriteBuffer();
      fastAuthMessage.encode(buffer);
      final bytes = buffer.toBytes();

      // FAST_AUTH message body is ~200-300 bytes (without TNS packet wrapper)
      // The ~2780 bytes for the full packet includes TNS packet headers and padding
      // This test validates just the message construction, not the full packet
      expect(bytes.length, greaterThan(150),
          reason:
              'FAST_AUTH message should contain all three embedded messages');
      expect(bytes.length, lessThan(500),
          reason:
              'FAST_AUTH message body should be under 500 bytes (actual: ${bytes.length})');
    });

    test('Message type is ttcMsgTypeFastAuth (34)', () {
      final buffer = WriteBuffer();
      fastAuthMessage.encode(buffer);
      final bytes = buffer.toBytes();

      // First byte should be FAST_AUTH message type (34)
      expect(bytes[0], equals(ttcMsgTypeFastAuth),
          reason: 'First byte should be FAST_AUTH message type (34)');
    });

    test('Protocol version is 6 (Oracle 8.1+)', () {
      final buffer = WriteBuffer();
      fastAuthMessage.encode(buffer);
      final bytes = buffer.toBytes();

      // FAST_AUTH header: [msgType(34), version(1), flag1(1), flag2(0)]
      // Then Protocol message: [type(1), version(6), terminator(0), driver...]
      // Look for the pattern [1, 6] which uniquely identifies Protocol type + version
      var protocolIndex = -1;
      for (int i = 0; i < bytes.length - 1; i++) {
        if (bytes[i] == ttcMsgTypeProtocol && bytes[i + 1] == 6) {
          protocolIndex = i;
          break;
        }
      }

      expect(protocolIndex, greaterThan(0),
          reason: 'Protocol message (type=1, version=6) should be embedded');
      expect(bytes[protocolIndex + 1], equals(6),
          reason: 'Protocol version should be 6 (Oracle 8.1+)');
    });

    test('Driver name "dart-oracledb" is embedded', () {
      final buffer = WriteBuffer();
      fastAuthMessage.encode(buffer);
      final bytes = buffer.toBytes();

      final driverBytes = Uint8List.fromList('dart-oracledb'.codeUnits);
      bool found = false;
      for (int i = 0; i <= bytes.length - driverBytes.length; i++) {
        bool match = true;
        for (int j = 0; j < driverBytes.length; j++) {
          if (bytes[i + j] != driverBytes[j]) {
            match = false;
            break;
          }
        }
        if (match) {
          found = true;
          break;
        }
      }
      expect(found, isTrue, reason: 'Driver name "dart-oracledb" not found');
    });

    test('DataTypes message includes UTF-8 charset (873)', () {
      final buffer = WriteBuffer();
      fastAuthMessage.encode(buffer);
      final bytes = buffer.toBytes();

      final dataTypesIndex = bytes.indexOf(ttcMsgTypeDataTypes);
      expect(dataTypesIndex, greaterThan(-1),
          reason: 'DataTypes message type (2) must be present in message');

      // UTF-8 charset (873 = 0x0369) is written as little-endian uint16
      final charsetBytes = <int>[873 & 0xFF, (873 >> 8) & 0xFF];

      // Search 30 bytes from DataTypes type byte with bounds protection
      bool foundCharset = false;
      final charsetSearchEnd = (dataTypesIndex + 30).clamp(0, bytes.length - 1);
      for (int i = dataTypesIndex; i < charsetSearchEnd; i++) {
        if (i + 1 < bytes.length &&
            bytes[i] == charsetBytes[0] &&
            bytes[i + 1] == charsetBytes[1]) {
          foundCharset = true;
          break;
        }
      }
      expect(foundCharset, isTrue,
          reason: 'UTF-8 charset (873) should be in DataTypes message');
    });

    test('Username is embedded in AUTH_PHASE_ONE', () {
      final buffer = WriteBuffer();
      fastAuthMessage.encode(buffer);
      final bytes = buffer.toBytes();

      // Username "testuser" should be present
      final usernameBytes = Uint8List.fromList('testuser'.codeUnits);
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
      expect(found, isTrue, reason: 'Username "testuser" should be embedded');
    });

    test('Message structure has all three components in order', () {
      final buffer = WriteBuffer();
      fastAuthMessage.encode(buffer);
      final bytes = buffer.toBytes();

      // Verify order: FAST_AUTH header → Protocol → DataTypes → AUTH_PHASE_ONE
      // Use two-byte patterns to avoid collisions with data bytes that share the same value.
      const fastAuthIndex = 0;

      var protocolIndex = -1;
      for (int i = 0; i < bytes.length - 1; i++) {
        if (bytes[i] == ttcMsgTypeProtocol && bytes[i + 1] == 6) {
          protocolIndex = i;
          break;
        }
      }

      final dataTypesIndex = bytes.indexOf(ttcMsgTypeDataTypes);

      var functionIndex = -1;
      const authPhaseOneCode = 0x76;
      for (int i = 0; i < bytes.length - 1; i++) {
        if (bytes[i] == ttcMsgTypeFunction &&
            bytes[i + 1] == authPhaseOneCode) {
          functionIndex = i;
          break;
        }
      }

      expect(fastAuthIndex, equals(0));
      expect(protocolIndex, greaterThan(fastAuthIndex));
      expect(dataTypesIndex, greaterThan(-1),
          reason: 'DataTypes message type (2) must be present');
      expect(dataTypesIndex, greaterThan(protocolIndex));
      expect(functionIndex, greaterThan(-1),
          reason: 'AUTH_PHASE_ONE function header [3, 0x76] must be present');
      expect(functionIndex, greaterThan(dataTypesIndex));
    });

    test(
        'Capabilities are trimmed (trailing zeros removed) in DataTypes',
        () {
      // Create caps with trailing zeros
      final capsWithZeros = Uint8List(48);
      capsWithZeros[0] = 0x01;
      capsWithZeros[1] = 0x02;
      capsWithZeros[2] = 0x03;
      // Rest are zeros (should be trimmed)

      final messageWithTrim = FastAuthRequest(
        username: 'testuser',
        clientNonce: clientNonce,
        compileCaps: capsWithZeros,
        runtimeCaps: capsWithZeros,
        dataTypes: dataTypes,
        ttcFieldVersion: 13,
        sequence: 1,
      );

      final buffer = WriteBuffer();
      messageWithTrim.encode(buffer);
      final bytes = buffer.toBytes();

      final dataTypesIndex = bytes.indexOf(ttcMsgTypeDataTypes);
      expect(dataTypesIndex, greaterThan(-1),
          reason: 'DataTypes message type (2) must be present');

      // DataTypes layout from fast_auth_message.dart encode():
      //   [0] type byte (ttcMsgTypeDataTypes=2)
      //   [1-2] charset uint16LE (2 bytes)
      //   [3-4] ncharset uint16LE (2 bytes)
      //   [5] compile caps length byte
      final capsLengthIndex = dataTypesIndex + 1 + 2 + 2;
      final compileCapsLength = bytes[capsLengthIndex];

      expect(compileCapsLength, equals(3),
          reason: 'Trailing zeros should be trimmed from capabilities');
    });
  });

  group('FAST_AUTH Message Variations', () {
    test('Different usernames produce different messages', () {
      final buffer1 = WriteBuffer();
      final msg1 = FastAuthRequest(
        username: 'user1',
        clientNonce: Uint8List(16),
        compileCaps: Uint8List(48),
        runtimeCaps: Uint8List(48),
        dataTypes: [
          [2, 1, 0]
        ],
        ttcFieldVersion: 13,
        sequence: 1,
      );
      msg1.encode(buffer1);

      final buffer2 = WriteBuffer();
      final msg2 = FastAuthRequest(
        username: 'user2',
        clientNonce: Uint8List(16),
        compileCaps: Uint8List(48),
        runtimeCaps: Uint8List(48),
        dataTypes: [
          [2, 1, 0]
        ],
        ttcFieldVersion: 13,
        sequence: 1,
      );
      msg2.encode(buffer2);

      expect(buffer1.toBytes(), isNot(equals(buffer2.toBytes())),
          reason: 'Different usernames should produce different messages');
    });

    test('Sequence counter is embedded correctly', () {
      final buffer = WriteBuffer();
      final msgSeq5 = FastAuthRequest(
        username: 'testuser',
        clientNonce: Uint8List(16),
        compileCaps: Uint8List(48),
        runtimeCaps: Uint8List(48),
        dataTypes: [
          [2, 1, 0]
        ],
        ttcFieldVersion: 13,
        sequence: 5,
      );
      msgSeq5.encode(buffer);
      final bytes = buffer.toBytes();

      // Find AUTH_PHASE_ONE function header (0x76)
      const authPhaseOneCode = 0x76;
      var functionIndex = -1;
      for (int i = 0; i < bytes.length - 2; i++) {
        if (bytes[i] == ttcMsgTypeFunction &&
            bytes[i + 1] == authPhaseOneCode) {
          functionIndex = i;
          break;
        }
      }

      expect(functionIndex, greaterThan(0));
      expect(bytes[functionIndex + 2], equals(5),
          reason: 'Sequence counter should be embedded in function header');
    });
  });
}
