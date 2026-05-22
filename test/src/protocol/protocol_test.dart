import 'dart:typed_data';

import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/capabilities.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/protocol.dart';
import 'package:oracledb/src/protocol/ttc_packet.dart';
import 'package:test/test.dart';

void main() {
  group('TtcProtocol', () {
    group('constructor', () {
      test('creates with default state', () {
        final protocol = TtcProtocol();

        expect(protocol.state, equals(ProtocolState.disconnected));
      });

      test('initial sequence is 0', () {
        final protocol = TtcProtocol();

        expect(protocol.currentSequence, equals(0));
      });

      test('has null capabilities initially', () {
        final protocol = TtcProtocol();

        expect(protocol.negotiatedCapabilities, isNull);
      });
    });

    group('nextSequence', () {
      test('returns incrementing sequence numbers', () {
        final protocol = TtcProtocol();

        expect(protocol.nextSequence(), equals(0));
        expect(protocol.nextSequence(), equals(1));
        expect(protocol.nextSequence(), equals(2));
      });

      test('wraps around at 255', () {
        final protocol = TtcProtocol();

        // Advance to 255
        for (var i = 0; i < 255; i++) {
          protocol.nextSequence();
        }

        expect(protocol.nextSequence(), equals(255));
        expect(protocol.nextSequence(), equals(0)); // Wrap around
      });
    });

    group('state transitions', () {
      test('transitions to negotiating', () {
        final protocol = TtcProtocol();

        protocol.beginNegotiation();

        expect(protocol.state, equals(ProtocolState.negotiating));
      });

      test('transitions to connected', () {
        final protocol = TtcProtocol();

        protocol.beginNegotiation();
        protocol.completeNegotiation(Capabilities());

        expect(protocol.state, equals(ProtocolState.connected));
      });

      test('stores negotiated capabilities', () {
        final protocol = TtcProtocol();
        final caps = Capabilities(protocolVersion: 315);

        protocol.beginNegotiation();
        protocol.completeNegotiation(caps);

        expect(protocol.negotiatedCapabilities?.protocolVersion, equals(315));
      });

      test('transitions to disconnected', () {
        final protocol = TtcProtocol();

        protocol.beginNegotiation();
        protocol.completeNegotiation(Capabilities());
        protocol.disconnect();

        expect(protocol.state, equals(ProtocolState.disconnected));
      });

      test('disconnect clears capabilities', () {
        final protocol = TtcProtocol();

        protocol.beginNegotiation();
        protocol.completeNegotiation(Capabilities());
        protocol.disconnect();

        expect(protocol.negotiatedCapabilities, isNull);
      });
    });

    group('createPacket', () {
      test('creates packet with auto-assigned sequence', () {
        final protocol = TtcProtocol();
        final payload = Uint8List.fromList([1, 2, 3]);

        final packet = protocol.createPacket(
          functionCode: ttcExecute,
          payload: payload,
        );

        expect(packet.functionCode, equals(ttcExecute));
        expect(packet.sequence, equals(0));
        expect(packet.payload, equals(payload));
      });

      test('increments sequence for each packet', () {
        final protocol = TtcProtocol();
        final payload = Uint8List(0);

        final packet1 = protocol.createPacket(
          functionCode: ttcPing,
          payload: payload,
        );
        final packet2 = protocol.createPacket(
          functionCode: ttcPing,
          payload: payload,
        );

        expect(packet1.sequence, equals(0));
        expect(packet2.sequence, equals(1));
      });

      test('allows data flags', () {
        final protocol = TtcProtocol();

        final packet = protocol.createPacket(
          functionCode: ttcFetch,
          payload: Uint8List(0),
          dataFlags: ttcDataFlagEof,
        );

        expect(packet.dataFlags, equals(ttcDataFlagEof));
      });
    });

    group('createPingPacket', () {
      test('creates ping packet', () {
        final protocol = TtcProtocol();

        final packet = protocol.createPingPacket();

        expect(packet.functionCode, equals(ttcPing));
      });
    });

    group('createClosePacket', () {
      test('creates close packet', () {
        final protocol = TtcProtocol();

        final packet = protocol.createClosePacket();

        expect(packet.functionCode, equals(ttcClose));
      });
    });

    group('isConnected', () {
      test('returns false when disconnected', () {
        final protocol = TtcProtocol();

        expect(protocol.isConnected, isFalse);
      });

      test('returns false when negotiating', () {
        final protocol = TtcProtocol();
        protocol.beginNegotiation();

        expect(protocol.isConnected, isFalse);
      });

      test('returns true when connected', () {
        final protocol = TtcProtocol();
        protocol.beginNegotiation();
        protocol.completeNegotiation(Capabilities());

        expect(protocol.isConnected, isTrue);
      });
    });

    group('validateResponse', () {
      test('returns true for matching sequence', () {
        final protocol = TtcProtocol();
        final request = protocol.createPacket(
          functionCode: ttcPing,
          payload: Uint8List(0),
        );
        final response = TtcPacket(
          functionCode: ttcPing,
          payload: Uint8List(0),
          sequence: 0,
        );

        expect(protocol.validateResponse(request, response), isTrue);
      });

      test('returns false for mismatched sequence', () {
        final protocol = TtcProtocol();
        final request = protocol.createPacket(
          functionCode: ttcPing,
          payload: Uint8List(0),
        );
        final response = TtcPacket(
          functionCode: ttcPing,
          payload: Uint8List(0),
          sequence: 99, // Wrong sequence
        );

        expect(protocol.validateResponse(request, response), isFalse);
      });
    });
  });

  group('ProtocolState', () {
    test('has disconnected state', () {
      expect(ProtocolState.disconnected, isNotNull);
    });

    test('has negotiating state', () {
      expect(ProtocolState.negotiating, isNotNull);
    });

    test('has connected state', () {
      expect(ProtocolState.connected, isNotNull);
    });
  });

  group('state validation', () {
    test('beginNegotiation throws if not disconnected', () {
      final protocol = TtcProtocol();
      protocol.beginNegotiation();

      expect(
        () => protocol.beginNegotiation(),
        throwsA(isA<OracleException>()),
      );
    });

    test('completeNegotiation throws if not negotiating', () {
      final protocol = TtcProtocol();

      expect(
        () => protocol.completeNegotiation(Capabilities()),
        throwsA(isA<OracleException>()),
      );
    });

    test('state error has correct error code', () {
      final protocol = TtcProtocol();

      try {
        protocol.completeNegotiation(Capabilities());
        fail('Should have thrown OracleException');
      } on OracleException catch (e) {
        expect(e.errorCode, equals(oraProtocolError));
        expect(e.message, contains('disconnected'));
      }
    });
  });
}
