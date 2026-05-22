import 'dart:typed_data';

import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/capabilities.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:test/test.dart';

void main() {
  group('Capabilities', () {
    group('constructor', () {
      test('creates default capabilities', () {
        final caps = Capabilities();
        expect(caps, isNotNull);
      });

      test('default capabilities include standard client flags', () {
        final caps = Capabilities();
        expect(caps.hasCapability(capabilityEndOfCallStatus), isTrue);
      });
    });

    group('hasCapability', () {
      test('returns true for set capabilities', () {
        final caps = Capabilities(
          flags: capabilityEndOfCallStatus | capabilityOci8Lob,
        );

        expect(caps.hasCapability(capabilityEndOfCallStatus), isTrue);
        expect(caps.hasCapability(capabilityOci8Lob), isTrue);
      });

      test('returns false for unset capabilities', () {
        final caps = Capabilities(flags: capabilityEndOfCallStatus);

        expect(caps.hasCapability(capabilityOci8Lob), isFalse);
        expect(caps.hasCapability(capabilitySessionState), isFalse);
      });
    });

    group('protocolVersion', () {
      test('stores protocol version', () {
        final caps = Capabilities(protocolVersion: 312);
        expect(caps.protocolVersion, equals(312));
      });

      test('defaults to reasonable version', () {
        final caps = Capabilities();
        expect(caps.protocolVersion, greaterThan(0));
      });
    });

    group('charset', () {
      test('stores charset code', () {
        final caps = Capabilities(charset: 873); // AL32UTF8
        expect(caps.charset, equals(873));
      });

      test('defaults to UTF8 charset', () {
        final caps = Capabilities();
        expect(caps.charset, greaterThan(0));
      });
    });

    group('encode', () {
      test('encodes capabilities to bytes', () {
        final caps = Capabilities(
          flags: capabilityEndOfCallStatus | capabilityOci8Lob,
          protocolVersion: 312,
          charset: 873,
        );

        final encoded = caps.encode();

        expect(encoded, isA<Uint8List>());
        expect(encoded.isNotEmpty, isTrue);
      });

      test('encodes default capabilities', () {
        final caps = Capabilities();
        final encoded = caps.encode();

        expect(encoded.isNotEmpty, isTrue);
      });
    });

    group('decode', () {
      test('decodes server capabilities from bytes', () {
        final caps = Capabilities(
          flags: capabilityEndOfCallStatus | capabilitySessionState,
          protocolVersion: 315,
          charset: 873,
        );

        final encoded = caps.encode();
        final decoded = Capabilities.decode(encoded);

        expect(decoded.flags, equals(caps.flags));
        expect(decoded.protocolVersion, equals(caps.protocolVersion));
        expect(decoded.charset, equals(caps.charset));
      });

      test('throws on invalid data', () {
        expect(
          () => Capabilities.decode(Uint8List(0)),
          throwsA(isA<OracleException>()),
        );
      });

      test('throws on insufficient data', () {
        final shortData = Uint8List.fromList([0x01, 0x02]);

        expect(
          () => Capabilities.decode(shortData),
          throwsA(isA<OracleException>()),
        );
      });
    });

    group('round-trip', () {
      test('encode-decode preserves all fields', () {
        final original = Capabilities(
          flags: capabilityEndOfCallStatus |
              capabilityOci8Lob |
              capabilitySessionState,
          protocolVersion: 320,
          charset: 873,
        );

        final encoded = original.encode();
        final decoded = Capabilities.decode(encoded);

        expect(decoded.flags, equals(original.flags));
        expect(decoded.protocolVersion, equals(original.protocolVersion));
        expect(decoded.charset, equals(original.charset));
      });

      test('preserves capability flags through encode-decode', () {
        final original = Capabilities(
          flags: capabilityEndOfCallStatus | capabilityOci8Lob,
        );

        final encoded = original.encode();
        final decoded = Capabilities.decode(encoded);

        expect(decoded.hasCapability(capabilityEndOfCallStatus), isTrue);
        expect(decoded.hasCapability(capabilityOci8Lob), isTrue);
        expect(decoded.hasCapability(capabilitySessionState), isFalse);
      });
    });

    group('negotiate', () {
      test('returns intersection of client and server capabilities', () {
        final client = Capabilities(
          flags: capabilityEndOfCallStatus |
              capabilityOci8Lob |
              capabilitySessionState,
        );

        final server = Capabilities(
          flags: capabilityEndOfCallStatus | capabilityOci8Lob,
        );

        final negotiated = client.negotiate(server);

        expect(negotiated.hasCapability(capabilityEndOfCallStatus), isTrue);
        expect(negotiated.hasCapability(capabilityOci8Lob), isTrue);
        expect(negotiated.hasCapability(capabilitySessionState), isFalse);
      });

      test('uses server protocol version', () {
        final client = Capabilities(protocolVersion: 320);
        final server = Capabilities(protocolVersion: 315);

        final negotiated = client.negotiate(server);

        // Should use lower version (server's)
        expect(negotiated.protocolVersion, equals(315));
      });

      test('uses server charset', () {
        final client = Capabilities(charset: 873);
        final server = Capabilities(charset: 871);

        final negotiated = client.negotiate(server);

        expect(negotiated.charset, equals(server.charset));
      });
    });

    group('toString', () {
      test('returns descriptive string', () {
        final caps = Capabilities(
          flags: capabilityEndOfCallStatus,
          protocolVersion: 312,
          charset: 873,
        );

        final str = caps.toString();

        expect(str, contains('Capabilities'));
        expect(str, contains('protocolVersion'));
      });
    });
  });
}
