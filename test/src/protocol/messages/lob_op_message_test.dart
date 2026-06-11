/// Unit tests for LobOpRequest / decodeLobOpResponse (Story 4.1).
///
/// Encode fixtures mirror node-oracledb's thin `LobOpMessage`
/// (reference/node-oracledb/lib/thin/protocol/messages/lobOp.js); decode
/// fixtures are hand-built from the same shape (LOB_DATA + RETURN_PARAMETER
/// + STATUS / ERROR). Behavioral validation against real Oracle servers
/// lives in `test/integration/clob_integration_test.dart`.
library;

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/lob_locator.dart';
import 'package:oracledb/src/protocol/messages/lob_op_message.dart';

void main() {
  group('LobOpRequest encoding', () {
    test('READ op: full field walk matches the lobOp.js layout', () {
      final locator = Uint8List.fromList(List.filled(40, 0xAB));
      final req = LobOpRequest(
        operation: tnsLobOpRead,
        sourceLocator: locator,
        sourceOffset: 1,
        sendAmount: true,
        amount: 8060,
        sequence: 5,
      );
      final buf = ReadBuffer(req.toBytes());

      expect(buf.readUint8(), equals(ttcMsgTypeFunction));
      expect(buf.readUint8(), equals(ttcLobOp));
      expect(buf.readUint8(), equals(5)); // sequence
      buf.skipUB8(); // token number (default field version 24 >= 18)
      expect(buf.readUint8(), equals(1), reason: 'source locator pointer');
      expect(buf.readUB4(), equals(40), reason: 'source locator length');
      expect(buf.readUint8(), equals(0), reason: 'dest locator pointer');
      expect(buf.readUB4(), equals(0), reason: 'dest locator length');
      expect(buf.readUB4(), equals(0), reason: 'short source offset');
      expect(buf.readUB4(), equals(0), reason: 'short dest offset');
      expect(buf.readUint8(), equals(0), reason: 'charset pointer (not temp)');
      expect(buf.readUint8(), equals(0), reason: 'short amount pointer');
      expect(buf.readUint8(), equals(0), reason: 'boolean-out pointer');
      expect(buf.readUB4(), equals(tnsLobOpRead), reason: 'operation');
      expect(buf.readUint8(), equals(0), reason: 'SCN pointer');
      expect(buf.readUint8(), equals(0), reason: 'SCN array length');
      expect(buf.readUB8(), equals(1), reason: 'UB8 source offset');
      expect(buf.readUB8(), equals(0), reason: 'UB8 dest offset');
      expect(buf.readUint8(), equals(1), reason: 'amount pointer (sendAmount)');
      expect(buf.readUint16BE(), equals(0));
      expect(buf.readUint16BE(), equals(0));
      expect(buf.readUint16BE(), equals(0));
      expect(buf.readBytes(40), equals(locator), reason: 'raw locator bytes');
      expect(buf.readUB8(), equals(8060), reason: 'trailing UB8 amount');
      expect(buf.hasRemaining, isFalse, reason: 'no stray trailing bytes');
    });

    test('WRITE op: data rides a LOB_DATA marker, no trailing amount', () {
      final locator = Uint8List.fromList(List.filled(40, 0x01));
      final data = Uint8List.fromList('hello'.codeUnits);
      final req = LobOpRequest(
        operation: tnsLobOpWrite,
        sourceLocator: locator,
        sourceOffset: 1,
        data: data,
      );
      final bytes = req.toBytes();
      final buf = ReadBuffer(bytes);
      buf.readUint8(); // msg type
      buf.readUint8(); // func code
      buf.readUint8(); // seq
      buf.skipUB8(); // token
      buf.readUint8(); // src locator ptr
      buf.readUB4(); // src locator len
      buf.readUint8(); // dest locator ptr
      buf.readUB4(); // dest len
      buf.readUB4(); // short src offset
      buf.readUB4(); // short dest offset
      buf.readUint8(); // charset ptr
      buf.readUint8(); // short amount ptr
      buf.readUint8(); // boolean-out ptr
      expect(buf.readUB4(), equals(tnsLobOpWrite));
      buf.readUint8(); // SCN ptr
      buf.readUint8(); // SCN len
      expect(buf.readUB8(), equals(1));
      buf.readUB8(); // dest offset
      expect(buf.readUint8(), equals(0), reason: 'sendAmount false');
      buf.readUint16BE();
      buf.readUint16BE();
      buf.readUint16BE();
      buf.readBytes(40); // locator
      expect(buf.readUint8(), equals(ttcMsgTypeLobData),
          reason: 'write data is preceded by the LOB_DATA message-type byte');
      expect(buf.readBytesWithLength(), equals(data));
      expect(buf.hasRemaining, isFalse,
          reason: 'no amount is written when sendAmount is false');
    });

    test('CREATE_TEMP op: charset/boolean pointers, duration, UTF-8 charset',
        () {
      final req = LobOpRequest(
        operation: tnsLobOpCreateTemp,
        sourceLocator: Uint8List(tnsLobLocatorBufferSize),
        sourceOffset: ttcCsfrmImplicit,
        destOffset: oraTypeClob,
        destLength: tnsDurationSession,
      );
      final buf = ReadBuffer(req.toBytes());
      buf.readUint8(); // msg type
      buf.readUint8(); // func code
      buf.readUint8(); // seq
      buf.skipUB8(); // token
      expect(buf.readUint8(), equals(1));
      expect(buf.readUB4(), equals(tnsLobLocatorBufferSize));
      buf.readUint8(); // dest locator ptr
      expect(buf.readUB4(), equals(tnsDurationSession),
          reason: 'dest length carries the temp-LOB duration');
      buf.readUB4(); // short src offset
      buf.readUB4(); // short dest offset
      expect(buf.readUint8(), equals(1), reason: 'charset pointer set');
      buf.readUint8(); // short amount ptr
      expect(buf.readUint8(), equals(1), reason: 'boolean-out pointer set');
      expect(buf.readUB4(), equals(tnsLobOpCreateTemp));
      buf.readUint8(); // SCN ptr
      buf.readUint8(); // SCN len
      expect(buf.readUB8(), equals(ttcCsfrmImplicit),
          reason: 'source offset carries the charset form');
      expect(buf.readUB8(), equals(oraTypeClob),
          reason: 'dest offset carries the Oracle type');
      expect(buf.readUint8(), equals(0), reason: 'sendAmount false');
      buf.readUint16BE();
      buf.readUint16BE();
      buf.readUint16BE();
      buf.readBytes(tnsLobLocatorBufferSize); // zeroed locator
      expect(buf.readUB4(), equals(ttcCharsetUtf8),
          reason: 'CREATE_TEMP appends the implicit charset id');
      expect(buf.hasRemaining, isFalse);
    });

    test('token number UB8 only written when ttcFieldVersion >= 18', () {
      final v24 = LobOpRequest(operation: tnsLobOpRead, ttcFieldVersion: 24)
          .toBytes();
      final v17 = LobOpRequest(operation: tnsLobOpRead, ttcFieldVersion: 17)
          .toBytes();
      expect(v24.length, greaterThan(v17.length));
    });
  });

  group('decodeLobOpResponse', () {
    test('READ response: LOB_DATA + RETURN_PARAMETER + STATUS', () {
      final locatorEcho = List.filled(40, 0x42);
      final payload = Uint8List.fromList([
        ttcMsgTypeLobData,
        ..._bytesWithLength('clob data'.codeUnits),
        ttcMsgTypeParameter,
        ...locatorEcho, // raw locator bytes (source locator length)
        ..._sb8(9), // SB8 amount (sendAmount true)
        ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0),
      ]);
      final r = decodeLobOpResponse(payload,
          operation: tnsLobOpRead, sourceLocatorLength: 40, sendAmount: true);
      expect(r.isSuccess, isTrue);
      expect(r.data, equals('clob data'.codeUnits));
      expect(r.updatedLocator, equals(locatorEcho));
      expect(r.amount, equals(9));
    });

    test('multiple LOB_DATA messages concatenate in order', () {
      final payload = Uint8List.fromList([
        ttcMsgTypeLobData,
        ..._bytesWithLength('first '.codeUnits),
        ttcMsgTypeLobData,
        ..._bytesWithLength('second'.codeUnits),
        ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0),
      ]);
      final r = decodeLobOpResponse(payload,
          operation: tnsLobOpRead, sourceLocatorLength: 0, sendAmount: false);
      expect(String.fromCharCodes(r.data!), equals('first second'));
    });

    test('CREATE_TEMP response: locator echo + charset UB2 + flags UB1', () {
      final newLocator = List.generate(40, (i) => i);
      final payload = Uint8List.fromList([
        ttcMsgTypeParameter,
        ...newLocator,
        ..._ub2(873), // charset
        7, // trailing flags byte
        ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0),
      ]);
      final r = decodeLobOpResponse(payload,
          operation: tnsLobOpCreateTemp,
          sourceLocatorLength: 40,
          sendAmount: false);
      expect(r.isSuccess, isTrue);
      expect(r.updatedLocator, equals(newLocator));
      expect(r.amount, isNull);
    });

    test('ERROR response surfaces the Oracle code and message', () {
      final payload = Uint8List.fromList([
        ..._errorMessage(errorNum: 22922, errorMessage: 'no such temp LOB'),
        ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0),
      ]);
      final r = decodeLobOpResponse(payload,
          operation: tnsLobOpRead, sourceLocatorLength: 0, sendAmount: false);
      expect(r.isSuccess, isFalse);
      expect(r.errorCode, equals(22922));
      expect(r.errorMessage, contains('no such temp LOB'));
    });

    test('pre-23.4: ERROR terminates the response without STATUS', () {
      final payload = Uint8List.fromList(
          _errorMessage(errorNum: 1031, errorMessage: 'insufficient privs'));
      final r = decodeLobOpResponse(payload,
          operation: tnsLobOpRead,
          sourceLocatorLength: 0,
          sendAmount: false,
          endOfRequestSupport: false);
      expect(r.isSuccess, isFalse);
      expect(r.errorCode, equals(1031));
    });

    test('unknown TTC message type fails loud', () {
      final payload = Uint8List.fromList([99, 0, 0, 0]);
      expect(
        () => decodeLobOpResponse(payload,
            operation: tnsLobOpRead, sourceLocatorLength: 0, sendAmount: false),
        throwsA(isA<OracleException>().having(
            (e) => e.message, 'message', contains('Unknown TTC message'))),
      );
    });

    test('buffer underrun wraps in OracleException with cause', () {
      // RETURN_PARAMETER promising a 40-byte locator with only 3 bytes left.
      final payload = Uint8List.fromList([ttcMsgTypeParameter, 1, 2, 3]);
      expect(
        () => decodeLobOpResponse(payload,
            operation: tnsLobOpRead, sourceLocatorLength: 40, sendAmount: true),
        throwsA(isA<OracleException>()
            .having((e) => e.cause, 'cause', isA<BufferException>())),
      );
    });
  });

  group('lobOpStreamIsComplete', () {
    test('complete response returns true', () {
      final payload = Uint8List.fromList([
        ttcMsgTypeLobData,
        ..._bytesWithLength('x'.codeUnits),
        ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0),
      ]);
      expect(
          lobOpStreamIsComplete(payload,
              operation: tnsLobOpRead,
              sourceLocatorLength: 0,
              sendAmount: false),
          isTrue);
    });

    test('truncated response returns false (more packets needed)', () {
      final payload = Uint8List.fromList([
        ttcMsgTypeParameter,
        1, 2, 3, // 3 of 40 promised locator bytes
      ]);
      expect(
          lobOpStreamIsComplete(payload,
              operation: tnsLobOpRead,
              sourceLocatorLength: 40,
              sendAmount: true),
          isFalse);
    });

    test('response without terminal message returns false', () {
      final payload = Uint8List.fromList([
        ttcMsgTypeLobData,
        ..._bytesWithLength('x'.codeUnits),
      ]);
      expect(
          lobOpStreamIsComplete(payload,
              operation: tnsLobOpRead,
              sourceLocatorLength: 0,
              sendAmount: false),
          isFalse);
    });
  });

  group('LobLocator', () {
    test('usesVarLengthCharset reads flag byte 3 bit 0x80', () {
      final nclobLocator = Uint8List(40);
      nclobLocator[tnsLobLocOffsetFlag3] = tnsLobLocFlagsVarLengthCharset;
      expect(
          LobLocator(
                  locator: nclobLocator, lengthInChars: 1, chunkSize: 0)
              .usesVarLengthCharset,
          isTrue);
      expect(
          LobLocator(locator: Uint8List(40), lengthInChars: 1, chunkSize: 0)
              .usesVarLengthCharset,
          isFalse);
    });
  });

  group('UTF-16BE LOB data codec (variable-length-charset locators)', () {
    test('round-trips BMP and supplementary characters', () {
      const text = 'héllo 日本語 😀';
      final bytes = encodeUtf16Be(text);
      expect(bytes.length, equals(text.length * 2),
          reason: '2 bytes per UTF-16 code unit (surrogates included)');
      expect(decodeUtf16Be(bytes), equals(text));
    });

    test('encodes big-endian byte order', () {
      final bytes = encodeUtf16Be('A'); // U+0041
      expect(bytes, equals([0x00, 0x41]));
    });

    test('decode rejects an odd byte count', () {
      expect(() => decodeUtf16Be(Uint8List.fromList([0x00, 0x41, 0x00])),
          throwsFormatException);
    });
  });
}

List<int> _bytesWithLength(List<int> data) {
  if (data.isEmpty) return [0];
  return [data.length, ...data];
}

List<int> _ub4(int v) {
  if (v == 0) return [0];
  if (v <= 0xff) return [1, v];
  if (v <= 0xffff) return [2, (v >> 8) & 0xff, v & 0xff];
  return [4, (v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
}

List<int> _ub2(int v) {
  if (v == 0) return [0];
  if (v <= 0xff) return [1, v];
  return [2, (v >> 8) & 0xff, v & 0xff];
}

/// Variable-length signed integer (positive values only) matching readSB8.
List<int> _sb8(int v) => _ub4(v);

/// Minimal TTC ERROR (type 4) message body — same layout the EXECUTE decoder
/// fixtures use (see execute_message_test.dart `_errorMessage`).
List<int> _errorMessage({int errorNum = 0, String? errorMessage}) {
  final out = <int>[ttcMsgTypeError];
  out.addAll(_ub4(0)); // end of call status
  out.addAll(_ub2(0)); // end-to-end seq num
  out.addAll(_ub4(0)); // current row
  out.addAll(_ub2(0)); // err num short
  out.addAll(_ub2(0)); // array elem
  out.addAll(_ub2(0)); // array elem
  out.addAll(_ub4(0)); // cursor id
  out.addAll(_ub4(0)); // error position
  out.addAll([0, 0, 0, 0, 0, 0]); // sql type..warning flags (6 x UB1)
  out.addAll(_ub4(0)); // rowID rba
  out.addAll(_ub2(0)); // partition id
  out.add(0);
  out.addAll(_ub4(0)); // block num
  out.addAll(_ub2(0)); // slot num
  out.addAll(_ub4(0)); // OS error
  out.add(0); // statement error
  out.add(0); // call number
  out.addAll(_ub2(0)); // padding
  out.addAll(_ub4(0)); // success iters
  out.addAll(_ub4(0)); // oerrdd length
  out.addAll(_ub2(0)); // batch error codes count
  out.addAll(_ub4(0)); // batch error offsets count
  out.addAll(_ub2(0)); // batch error messages count
  out.addAll(_ub4(errorNum)); // extended error number
  out.addAll(_ub4(0)); // extended row count (UB8, zero form)
  out.addAll(_ub4(0)); // 20.1 sql type
  out.addAll(_ub4(0)); // 20.1 checksum
  if (errorNum != 0) {
    final msg = errorMessage ?? 'ORA-$errorNum';
    out.addAll(_bytesWithLength(msg.codeUnits));
  }
  return out;
}
