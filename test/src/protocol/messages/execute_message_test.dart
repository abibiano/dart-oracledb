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
      expect(options & ttcExecOptionNotPlSql,
          equals(0)); // queries clear NOT_PLSQL
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
      final r1 =
          ExecuteRequest(sql: 'SELECT 1 FROM dual', isQuery: true, sequence: 7);
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

  group('ExecuteRequest with cached cursorId', () {
    test('nonzero cursorId clears ttcExecOptionParse bit', () {
      final req = ExecuteRequest(
        sql: 'SELECT 1 FROM dual',
        isQuery: true,
        cursorId: 42,
      );
      final bytes = req.toBytes();
      final options = _readOptionsFromHeader(bytes);
      expect(options & ttcExecOptionParse, equals(0),
          reason: 'PARSE bit must be cleared when reusing a cached cursor');
      expect(options & ttcExecOptionExecute, isNonZero);
    });

    test('nonzero cursorId writes zero SQL pointer and zero SQL length', () {
      final req = ExecuteRequest(
        sql: 'SELECT 1 FROM dual',
        isQuery: true,
        cursorId: 7,
      );
      final bytes = req.toBytes();
      // Locate the SQL pointer byte: after header (msgType + funcCode + seq + UB8(9 bytes)) + options UB4 + cursorId UB4
      final buf = ReadBuffer(bytes);
      buf.readUint8(); // msg type
      buf.readUint8(); // func code
      buf.readUint8(); // seq
      buf.skipUB8(); // token number
      buf.readUB4(); // options
      buf.readUB4(); // cursor id value
      final sqlPtr = buf.readUint8(); // pointer to SQL (0 = null = no SQL)
      final sqlLen = buf.readUB4(); // SQL length
      expect(sqlPtr, equals(0), reason: 'SQL pointer must be null for reuse');
      expect(sqlLen, equals(0), reason: 'SQL length must be 0 for reuse');
    });

    test('zero cursorId includes PARSE bit and SQL bytes', () {
      const sql = 'SELECT 1 FROM dual';
      final req = ExecuteRequest(sql: sql, isQuery: true, cursorId: 0);
      final bytes = req.toBytes();
      final options = _readOptionsFromHeader(bytes);
      expect(options & ttcExecOptionParse, isNonZero);
    });
  });

  group('decodeExecuteResponse with expectedColumns', () {
    test('uses expectedColumns when DESCRIBE_INFO is absent', () {
      final payload = _buildPayload([
        // ROW_HEADER (minimal)
        _rowHeader(),
        // ROW_DATA with one VARCHAR column
        [ttcMsgTypeRowData, ..._bytesWithLength('hello'.codeUnits)],
        // ERROR end-of-fetch
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);

      const col = ColumnMetadata(
          name: 'VAL', oracleType: oraTypeVarchar, maxLength: 100);
      final r = decodeExecuteResponse(
        payload,
        isQuery: true,
        expectedColumns: [col],
      );

      expect(r.isSuccess, isTrue);
      expect(r.columnMetadata, hasLength(1));
      expect(r.columnMetadata.first.name, equals('VAL'));
      expect(r.rows, hasLength(1));
      expect(r.rows.first.first, equals('hello'));
    });

    test('DESCRIBE_INFO in response overrides expectedColumns', () {
      // Build a minimal DESCRIBE_INFO + ROW_DATA payload.
      final describePayload = _buildPayload([
        _describeInfo([
          _columnInfo(name: 'FRESH', oraType: oraTypeVarchar, maxSize: 50),
        ]),
        _rowHeader(),
        [ttcMsgTypeRowData, ..._bytesWithLength('world'.codeUnits)],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);

      const stale = ColumnMetadata(
          name: 'STALE', oracleType: oraTypeVarchar, maxLength: 10);
      final r = decodeExecuteResponse(
        describePayload,
        isQuery: true,
        expectedColumns: [stale],
      );

      expect(r.columnMetadata.first.name, equals('FRESH'),
          reason: 'DESCRIBE_INFO must override expectedColumns');
      expect(r.rows.first.first, equals('world'));
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
        _errorMessage(
            errorNum: 942, errorMessage: 'table or view does not exist'),
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

/// Builds a minimal TTC ROW_HEADER message with no bit-vector and no rowid.
List<int> _rowHeader() {
  return [
    ttcMsgTypeRowHeader,
    0, // flags (UB1)
    ..._ub2(0), // num requests
    ..._ub4(0), // iteration number
    ..._ub4(0), // num iters
    ..._ub2(0), // buffer length
    ..._ub4(0), // bitVecLen = 0
    ..._ub4(0), // rxhridLen = 0
  ];
}

/// Builds a TTC DESCRIBE_INFO message containing [columns].
List<int> _describeInfo(List<List<int>> columns) {
  final out = <int>[ttcMsgTypeDescribeInfo];
  out.add(0); // version bytes length = 0 (readBytesWithLength → empty)
  out.addAll(_ub4(0)); // max row size
  out.addAll(_ub4(columns.length)); // numCols
  if (columns.isNotEmpty) out.add(0); // extra byte present when numCols > 0
  for (final col in columns) {
    out.addAll(col);
  }
  out.addAll(_ub4(0)); // dateBytes = 0 (no current-date field)
  out.addAll(_ub4(0)); // dcbflag
  out.addAll(_ub4(0)); // dcbmdbz
  out.addAll(_ub4(0)); // dcbmnpr
  out.addAll(_ub4(0)); // dcbmxpr
  out.addAll(_ub4(0)); // tailBytes = 0
  return out;
}

/// Builds a single column-info entry for DESCRIBE_INFO.
///
/// Matches the layout read by [_processColumnInfo] with ttcFieldVersion = 24
/// (the default used by [decodeExecuteResponse]).
List<int> _columnInfo({
  required String name,
  required int oraType,
  required int maxSize,
}) {
  final nameBytes = name.codeUnits;
  return [
    oraType, // dataType
    0, // flags
    0, // precision
    0, // scale
    ..._ub4(maxSize), // maxSize
    ..._ub4(0), // max num array elements
    ..._ub8(0), // cont flags (UB8)
    ..._ub4(0), // oidLen = 0
    ..._ub2(0), // version
    ..._ub2(0), // charset id
    0, // csfrm
    ..._ub4(maxSize), // size
    ..._ub4(0), // oaccolid (12.2)
    0, // nullable
    0, // v7 name length
    ..._ub4(nameBytes.length), // nameLen
    ..._bytesWithLength(nameBytes), // name with length prefix
    ..._ub4(0), // schema len = 0
    ..._ub4(0), // type name len = 0
    ..._ub2(0), // column position
    ..._ub4(0), // uds flags
    ..._ub4(0), // domain schema len = 0
    ..._ub4(0), // domain name len = 0
    ..._ub4(0), // annotations len = 0
    // ttcFieldVersion >= 24 (23.4) vector fields:
    ..._ub4(0), // dimensions
    0, // format
    0, // flags
  ];
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
  out.addAll(_ub4(0)); // cursor id (decoder reads readUB4)
  out.addAll(
      _ub2(0)); // error position (SB4 in wire; encoded same as UB2 for 0)
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
