import 'dart:convert';
import 'dart:typed_data';

import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/messages/base.dart';
import 'package:oracledb/src/protocol/messages/protocol_message.dart';
import 'package:test/test.dart';

void main() {
  group('ProtocolRequest.encode', () {
    test('emits type, version, terminator, driver name, null terminator', () {
      final bytes = ProtocolRequest().toBytes();
      final driverBytes = utf8.encode(driverName);

      expect(bytes[0], equals(ttcMsgTypeProtocol));
      expect(bytes[1], equals(ttcProtocolVersion));
      expect(bytes[2], equals(0), reason: 'pre-driver terminator');
      expect(
        bytes.sublist(3, 3 + driverBytes.length),
        equals(driverBytes),
      );
      expect(bytes.last, equals(0), reason: 'driver string null terminator');
      expect(bytes.length, equals(3 + driverBytes.length + 1));
    });

    test('messageType is ttcMsgTypeProtocol', () {
      expect(ProtocolRequest().messageType, equals(ttcMsgTypeProtocol));
    });

    test('sequence defaults to 0 and accepts a custom value', () {
      expect(ProtocolRequest().sequence, equals(0));
      expect(ProtocolRequest(sequence: 7).sequence, equals(7));
    });
  });

  group('ProtocolResponse.decode', () {
    // Builds a well-formed protocol response payload. nCharsetId is derived
    // from the FDO: ix = 6 + fdo[5] + fdo[6]; nCharsetId = (fdo[ix+3] << 8) +
    // fdo[ix+4]. With fdo[5]=fdo[6]=0, ix=6, so fdo[9] and fdo[10] drive it.
    Uint8List buildResponse({
      int serverVersion = 6,
      String banner = 'Oracle Database 23ai',
      int charsetId = 873,
      int serverFlags = 1,
      int numElem = 0,
      Uint8List? fdo,
      Uint8List? compileCaps,
      Uint8List? runtimeCaps,
    }) {
      final wb = WriteBuffer();
      wb.writeUint8(ttcMsgTypeProtocol);
      wb.writeUint8(serverVersion);
      wb.writeUint8(0); // skipped byte
      wb.writeBytes(Uint8List.fromList(utf8.encode(banner)));
      wb.writeUint8(0); // banner null terminator
      wb.writeUint16LE(charsetId);
      wb.writeUint8(serverFlags);
      wb.writeUint16LE(numElem);
      if (numElem > 0) {
        wb.writeBytes(Uint8List(numElem * 5));
      }
      // nCharsetId = (fdo[9] << 8) + fdo[10] = (2 << 8) + 0 = 512.
      final fdoBytes = fdo ?? (Uint8List(12)..[9] = 0x02);
      wb.writeUint16BE(fdoBytes.length);
      wb.writeBytes(fdoBytes);
      if (compileCaps != null) {
        wb.writeUint8(compileCaps.length);
        wb.writeBytes(compileCaps);
      }
      if (runtimeCaps != null) {
        wb.writeUint8(runtimeCaps.length);
        wb.writeBytes(runtimeCaps);
      }
      return wb.toBytes();
    }

    test('decodes all fields of a well-formed response', () {
      final data = buildResponse(
        compileCaps: Uint8List.fromList([1, 2, 3]),
        runtimeCaps: Uint8List.fromList([9, 8]),
      );

      final resp = ProtocolResponse.decode(data);

      expect(resp.serverVersion, equals(6));
      expect(resp.serverBanner, equals('Oracle Database 23ai'));
      expect(resp.charsetId, equals(873));
      expect(resp.serverFlags, equals(1));
      expect(resp.nCharsetId, equals(512));
      expect(resp.compileCaps, equals(Uint8List.fromList([1, 2, 3])));
      expect(resp.runtimeCaps, equals(Uint8List.fromList([9, 8])));
    });

    test('skips per-element block when numElem > 0', () {
      final data = buildResponse(numElem: 3);
      final resp = ProtocolResponse.decode(data);
      // Decoding past the numElem*5 skip still lands on the FDO correctly.
      expect(resp.nCharsetId, equals(512));
      expect(resp.charsetId, equals(873));
    });

    test('leaves caps null when the payload ends before them', () {
      final data = buildResponse(); // no caps appended
      final resp = ProtocolResponse.decode(data);
      expect(resp.compileCaps, isNull);
      expect(resp.runtimeCaps, isNull);
    });

    test('caps with a zero length byte are treated as absent', () {
      final data = buildResponse(
        compileCaps: Uint8List(0),
        runtimeCaps: Uint8List(0),
      );
      final resp = ProtocolResponse.decode(data);
      expect(resp.compileCaps, isNull);
      expect(resp.runtimeCaps, isNull);
    });

    test('nCharsetId defaults to 0 when FDO is too short', () {
      final data = buildResponse(fdo: Uint8List(4));
      final resp = ProtocolResponse.decode(data);
      expect(resp.nCharsetId, equals(0));
    });

    test('caps the banner at 48 bytes when no null terminator is present', () {
      // 50 non-zero banner bytes: the decoder stops at 48 and resumes reading
      // the fixed fields from byte 48 onward.
      final wb = WriteBuffer();
      wb.writeUint8(ttcMsgTypeProtocol);
      wb.writeUint8(6);
      wb.writeUint8(0);
      wb.writeBytes(Uint8List.fromList(List<int>.filled(48, 0x41))); // 'A' * 48
      // Fixed fields begin here (no null terminator consumed).
      wb.writeUint16LE(873);
      wb.writeUint8(1);
      wb.writeUint16LE(0);
      final fdo = Uint8List(12)
        ..[9] = 0x02
        ..[10] = 0x00;
      wb.writeUint16BE(fdo.length);
      wb.writeBytes(fdo);

      final resp = ProtocolResponse.decode(wb.toBytes());
      expect(resp.serverBanner, equals('A' * 48));
      expect(resp.charsetId, equals(873));
    });

    test('throws MessageException on wrong message type', () {
      final bad = Uint8List.fromList([ttcMsgTypeDataTypes, 0, 0, 0]);
      expect(
        () => ProtocolResponse.decode(bad),
        throwsA(isA<MessageException>()),
      );
    });
  });

  group('DataTypesRequest.encode', () {
    test('emits type then length-prefixed compile and runtime caps', () {
      final compile = Uint8List.fromList([0xAA, 0xBB]);
      final runtime = Uint8List.fromList([0xCC]);
      final bytes = DataTypesRequest(
        compileCaps: compile,
        runtimeCaps: runtime,
      ).toBytes();

      expect(bytes[0], equals(ttcMsgTypeDataTypes));
      expect(bytes[1], equals(2)); // compile length
      expect(bytes.sublist(2, 4), equals(compile));
      expect(bytes[4], equals(1)); // runtime length
      expect(bytes.sublist(5, 6), equals(runtime));
      expect(bytes.length, equals(6));
    });

    test('messageType is ttcMsgTypeDataTypes', () {
      final req = DataTypesRequest(
        compileCaps: Uint8List(0),
        runtimeCaps: Uint8List(0),
      );
      expect(req.messageType, equals(ttcMsgTypeDataTypes));
    });
  });

  group('DataTypesResponse.decode', () {
    Uint8List build(Uint8List compile, Uint8List runtime) {
      final wb = WriteBuffer();
      wb.writeUint8(ttcMsgTypeDataTypes);
      wb.writeUint8(compile.length);
      wb.writeBytes(compile);
      wb.writeUint8(runtime.length);
      wb.writeBytes(runtime);
      return wb.toBytes();
    }

    test('decodes length-prefixed server caps', () {
      final resp = DataTypesResponse.decode(
        build(Uint8List.fromList([1, 2, 3]), Uint8List.fromList([4, 5])),
      );
      expect(resp.serverCompileCaps, equals(Uint8List.fromList([1, 2, 3])));
      expect(resp.serverRuntimeCaps, equals(Uint8List.fromList([4, 5])));
    });

    test('zero-length caps decode to empty buffers', () {
      final resp = DataTypesResponse.decode(build(Uint8List(0), Uint8List(0)));
      expect(resp.serverCompileCaps, isEmpty);
      expect(resp.serverRuntimeCaps, isEmpty);
    });

    test('throws MessageException on wrong message type', () {
      final bad = Uint8List.fromList([ttcMsgTypeProtocol, 0, 0]);
      expect(
        () => DataTypesResponse.decode(bad),
        throwsA(isA<MessageException>()),
      );
    });
  });
}
