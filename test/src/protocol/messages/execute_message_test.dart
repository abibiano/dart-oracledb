/// Unit tests for ExecuteRequest / ExecuteResponse / FetchRequest using the
/// real Oracle TTC EXECUTE wire format introduced in Story 6.3.
///
/// These tests validate the structural shape of encoded requests and the
/// decoder's response loop against hand-crafted fixtures. Behavioral
/// validation against an actual Oracle 23ai server lives in
/// `test/integration/query_integration_test.dart`.
library;

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';

void main() {
  group('ExecuteRequest encoding', () {
    test('writes function header with TTC RPC EXECUTE (funcCode 94)', () {
      final req = ExecuteRequest(sql: 'SELECT 1 FROM dual', isQuery: true);
      final bytes = req.toBytes();

      // Header: msgType (3), funcCode (94), seqNum (1 byte), tokenNumber UB8
      expect(bytes[0], equals(ttcMsgTypeFunction));
      expect(bytes[1], equals(ttcFuncExecute));
      expect(bytes[2], equals(1)); // default sequence
    });

    test('SELECT sets EXECUTE+FETCH+PARSE option bits', () {
      final req = ExecuteRequest(sql: 'SELECT 1 FROM dual', isQuery: true);
      final bytes = req.toBytes();
      final options = _readOptionsFromHeader(bytes);
      expect(options & ttcExecOptionExecute, isNonZero);
      expect(options & ttcExecOptionFetch, isNonZero);
      expect(options & ttcExecOptionParse, isNonZero);
      expect(options & ttcExecOptionNotPlSql, equals(0)); // queries clear NOT_PLSQL
    });

    test('DML sets NOT_PLSQL flag and clears FETCH bit', () {
      final req = ExecuteRequest(
        sql: 'INSERT INTO t VALUES (1)',
        isQuery: false,
      );
      final bytes = req.toBytes();
      final options = _readOptionsFromHeader(bytes);
      expect(options & ttcExecOptionExecute, isNonZero);
      expect(options & ttcExecOptionParse, isNonZero);
      expect(options & ttcExecOptionFetch, equals(0));
      expect(options & ttcExecOptionNotPlSql, isNonZero);
    });

    test('sets BIND flag when bind values are provided', () {
      final req = ExecuteRequest(
        sql: 'SELECT * FROM t WHERE id = :1',
        isQuery: true,
        bindValues: [42],
      );
      final bytes = req.toBytes();
      final options = _readOptionsFromHeader(bytes);
      expect(options & ttcExecOptionBind, isNonZero);
    });

    test('passes a unique sequence number to the wire', () {
      final r1 = ExecuteRequest(
          sql: 'SELECT 1 FROM dual', isQuery: true, sequence: 7);
      expect(r1.toBytes()[2], equals(7));
    });

    test('encodes token number UB8 only when ttcFieldVersion >= 18', () {
      final headerSize23 = ExecuteRequest(
        sql: 'SELECT 1 FROM dual',
        isQuery: true,
        ttcFieldVersion: 24,
      ).toBytes();
      final headerSizeOld = ExecuteRequest(
        sql: 'SELECT 1 FROM dual',
        isQuery: true,
        ttcFieldVersion: 17,
      ).toBytes();
      expect(
        headerSize23.length,
        greaterThan(headerSizeOld.length),
        reason: 'v23 should include extra token-number bytes',
      );
    });
  });

  group('FetchRequest encoding', () {
    test('uses TTC RPC FETCH (funcCode 5)', () {
      final req = FetchRequest(cursorId: 42, numRows: 10);
      final bytes = req.toBytes();
      expect(bytes[0], equals(ttcMsgTypeFunction));
      expect(bytes[1], equals(ttcFuncFetch));
      expect(bytes[2], equals(1));
    });
  });

  group('decodeExecuteResponse', () {
    test('reports success on END_OF_REQUEST with no error message', () {
      final payload = _buildPayload([
        // ERROR message: success (errorNum=0)
        _errorMessage(errorNum: 0, rowCount: 0),
        // STATUS message
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: false);
      expect(r.isSuccess, isTrue);
      expect(r.errorCode, isNull);
    });

    test('DML success exposes rowsAffected', () {
      final payload = _buildPayload([
        _errorMessage(errorNum: 0, rowCount: 3),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: false);
      expect(r.isSuccess, isTrue);
      expect(r.rowsAffected, equals(3));
    });

    test('Oracle error number is surfaced with message', () {
      final payload = _buildPayload([
        _errorMessage(errorNum: 942, errorMessage: 'table or view does not exist'),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: false);
      expect(r.isSuccess, isFalse);
      expect(r.errorCode, equals(942));
      expect(r.errorMessage, contains('table or view'));
    });

    test('ORA-01403 end-of-fetch is not treated as an error for queries', () {
      final payload = _buildPayload([
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: true);
      expect(r.isSuccess, isTrue);
      expect(r.moreRowsToFetch, isFalse);
    });
  });
}

/// Reads the EXECUTE options UB4 from a request that begins with the standard
/// function header (msg=3, func=94, seq=1 byte) followed by either a UB8 token
/// number (for ttcFieldVersion >= 18) or nothing.
int _readOptionsFromHeader(Uint8List bytes) {
  final buf = ReadBuffer(bytes);
  buf.readUint8(); // msg type
  buf.readUint8(); // func code
  buf.readUint8(); // seq
  // Token number UB8 (default ttcFieldVersion is 24 in tests).
  buf.skipUB8();
  return buf.readUB4();
}

Uint8List _buildPayload(List<List<int>> messages) {
  final out = <int>[];
  for (final m in messages) {
    out.addAll(m);
  }
  return Uint8List.fromList(out);
}

List<int> _ub4(int v) {
  if (v == 0) return [0];
  if (v <= 0xff) return [1, v];
  if (v <= 0xffff) return [2, (v >> 8) & 0xff, v & 0xff];
  return [
    4,
    (v >> 24) & 0xff,
    (v >> 16) & 0xff,
    (v >> 8) & 0xff,
    v & 0xff,
  ];
}

List<int> _ub2(int v) {
  if (v == 0) return [0];
  if (v <= 0xff) return [1, v];
  return [2, (v >> 8) & 0xff, v & 0xff];
}

List<int> _ub8(int v) => _ub4(v);

List<int> _bytesWithLength(List<int> data) {
  if (data.isEmpty) return [0];
  return [data.length, ...data];
}

/// Builds a complete TTC ERROR (type 4) message body that mirrors the layout
/// node-oracledb writes/reads. Optional [errorNum] selects success (0) or a
/// specific Oracle code; [rowCount] supplies the DML row count field.
List<int> _errorMessage({
  int errorNum = 0,
  int rowCount = 0,
  String? errorMessage,
}) {
  final out = <int>[ttcMsgTypeError];
  out.addAll(_ub4(0)); // end of call status
  out.addAll(_ub2(0)); // end-to-end seq num
  out.addAll(_ub4(0)); // current row
  out.addAll(_ub2(0)); // err num short
  out.addAll(_ub2(0)); // array elem
  out.addAll(_ub2(0)); // array elem
  out.addAll(_ub2(0)); // cursor id
  out.addAll(_ub2(0)); // error position (SB2 in wire; encoded same as UB2 for 0)
  out.add(0); // sql type
  out.add(0); // fatal
  out.add(0); // flags
  out.add(0); // user cursor opts
  out.add(0); // UPI param
  out.add(0); // warning
  // rowID: UB4 rba + UB2 partitionID + UB1 + UB4 blockNum + UB2 slotNum (all zero)
  out.addAll(_ub4(0));
  out.addAll(_ub2(0));
  out.add(0);
  out.addAll(_ub4(0));
  out.addAll(_ub2(0));
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
  out.addAll(_ub8(rowCount)); // extended row count
  out.addAll(_ub4(0)); // 20.1 sql type
  out.addAll(_ub4(0)); // 20.1 checksum
  if (errorNum != 0) {
    final msg = errorMessage ?? 'ORA-${errorNum.toString().padLeft(5, '0')}';
    out.addAll(_bytesWithLength(msg.codeUnits));
  }
  return out;
}
