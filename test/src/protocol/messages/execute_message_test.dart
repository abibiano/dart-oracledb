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

import 'package:oracledb/src/errors.dart';
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

    test('PL/SQL with binds sets BIND+PLSQL_BIND, clears NOT_PLSQL and FETCH',
        () {
      final req = ExecuteRequest(
        sql: 'BEGIN my_proc(:1, :2); END;',
        isQuery: false,
        isPlSql: true,
        bindValues: [1, 'Alice'],
      );
      final bytes = req.toBytes();
      final options = _readOptionsFromHeader(bytes);
      expect(options & ttcExecOptionExecute, isNonZero,
          reason: 'EXECUTE must always be set');
      expect(options & ttcExecOptionBind, isNonZero,
          reason: 'BIND must be set when bind values are present');
      expect(options & ttcExecOptionPlSqlBind, isNonZero,
          reason: 'PLSQL_BIND must be set for PL/SQL with binds');
      expect(options & ttcExecOptionNotPlSql, equals(0),
          reason: 'NOT_PLSQL must be cleared for PL/SQL blocks');
      expect(options & ttcExecOptionFetch, equals(0),
          reason: 'FETCH must not be set for PL/SQL');
    });

    test('PL/SQL with no binds clears NOT_PLSQL and PLSQL_BIND', () {
      final req = ExecuteRequest(
        sql: 'BEGIN simple_proc(); END;',
        isQuery: false,
        isPlSql: true,
      );
      final bytes = req.toBytes();
      final options = _readOptionsFromHeader(bytes);
      expect(options & ttcExecOptionExecute, isNonZero);
      expect(options & ttcExecOptionNotPlSql, equals(0),
          reason: 'NOT_PLSQL must be cleared even without binds');
      expect(options & ttcExecOptionPlSqlBind, equals(0),
          reason: 'PLSQL_BIND must not be set when there are no parameters');
      expect(options & ttcExecOptionBind, equals(0),
          reason: 'BIND must not be set when there are no parameters');
    });

    test('DML NOT_PLSQL bit is unchanged after PL/SQL isPlSql=false default',
        () {
      // Regression: isPlSql defaults to false, so existing DML tests are intact.
      final req = ExecuteRequest(
        sql: 'DELETE FROM t WHERE id = :1',
        isQuery: false,
        bindValues: [5],
      );
      final bytes = req.toBytes();
      final options = _readOptionsFromHeader(bytes);
      expect(options & ttcExecOptionNotPlSql, isNonZero,
          reason:
              'DML must still set NOT_PLSQL when isPlSql defaults to false');
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

    // Story 2.8: preserve SQL error offset on failure responses.
    test('error response exposes SQL error offset from TTC ERROR', () {
      final payload = _buildPayload([
        _errorMessage(
            errorNum: 942,
            errorOffset: 14,
            errorMessage: 'table or view does not exist'),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: false);
      expect(r.isSuccess, isFalse);
      expect(r.errorCode, equals(942));
      expect(r.errorOffset, equals(14),
          reason: 'SB4 error position must be preserved on the response');
    });

    test('successful response has null errorOffset', () {
      final payload = _buildPayload([
        _errorMessage(errorNum: 0, rowCount: 1),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: false);
      expect(r.isSuccess, isTrue);
      expect(r.errorOffset, isNull);
    });
  });

  group('Story 3.2 — OUT bind encoding', () {
    test('PL/SQL with OUT bind writes metadata and null indicator for OUT', () {
      final req = ExecuteRequest(
        sql: 'BEGIN :ret := myfunc(:a); END;',
        isQuery: false,
        isPlSql: true,
        bindValues: [
          BindVariable(
            value: null,
            oraType: oraTypeNumber,
            maxSize: 22,
            dir: BindDir.output,
          ),
          BindVariable(value: 5),
        ],
        bindNames: const ['ret', 'a'],
      );
      // Should not throw and should produce a non-empty payload.
      final bytes = req.toBytes();
      expect(bytes.length, greaterThan(0));
      // PL/SQL+binds: PLSQL_BIND must be set, NOT_PLSQL cleared.
      final buf = ReadBuffer(bytes);
      buf.readUint8(); // msg
      buf.readUint8(); // func
      buf.readUint8(); // seq
      buf.skipUB8(); // token
      final options = buf.readUB4();
      expect(options & ttcExecOptionPlSqlBind, isNonZero);
      expect(options & ttcExecOptionNotPlSql, equals(0));
    });

    test('OUT bind in non-PL/SQL statement throws OracleException', () {
      expect(
        () => ExecuteRequest(
          sql: 'SELECT :ret FROM dual',
          isQuery: true,
          bindValues: [
            BindVariable(
              value: null,
              oraType: oraTypeNumber,
              dir: BindDir.output,
            ),
          ],
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(6502))),
      );
    });

    test('OUT bind: ROW_DATA writes the null-indicator byte (length 0)', () {
      // For pure OUT binds, the input row data carries only a length=0
      // indicator byte — no value bytes follow. This mirrors node-oracledb
      // writeBindParamsColumn for null values.
      final req = ExecuteRequest(
        sql: 'BEGIN :ret := myfunc; END;',
        isQuery: false,
        isPlSql: true,
        bindValues: [
          BindVariable(
            value: null,
            oraType: oraTypeNumber,
            maxSize: 22,
            dir: BindDir.output,
          ),
        ],
        bindNames: const ['ret'],
      );
      final bytes = req.toBytes();
      // Scan for ROW_DATA marker (7). The value byte right after the marker
      // for a NULL/OUT bind must be 0.
      final rowDataIdx = bytes.indexOf(ttcMsgTypeRowData);
      expect(rowDataIdx, greaterThan(0),
          reason: 'ROW_DATA segment must be present for binds');
      // Byte after ROW_DATA marker is the length indicator for the first bind.
      expect(bytes[rowDataIdx + 1], equals(0),
          reason: 'OUT bind must serialize as null-indicator (length 0)');
    });
  });

  group('Story 3.2 — OUT bind decoding', () {
    test('IO_VECTOR + ROW_DATA decodes a NUMBER OUT bind', () {
      // bind 0: OUT NUMBER (return), bind 1: IN NUMBER. Server reports
      // direction 16 for OUT, direction 32 for IN.
      final payload = _buildPayload([
        _ioVector([16, 32]),
        // ROW_DATA for OUT bind: NUMBER (Oracle encodes 0 as a single 0x80
        // byte, but easier to send 5: encoded as [193, 6]). Then SB4 trailer.
        [
          ttcMsgTypeRowData,
          ..._bytesWithLength(_oracleNumberFiveBytes()),
          ..._ub4(0), // SB4 actualNumBytes
        ],
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);

      final r = decodeExecuteResponse(
        payload,
        isQuery: false,
        bindMetadata: const [
          BindMetadata(
              oraType: oraTypeNumber, maxSize: 22, dir: BindDir.output),
          BindMetadata(oraType: oraTypeNumber),
        ],
      );

      expect(r.isSuccess, isTrue);
      expect(r.outBindIndices, equals([0]));
      expect(r.outBindValues, hasLength(1));
      expect(r.outBindValues.first, equals(5));
    });

    test('IO_VECTOR + ROW_DATA decodes a VARCHAR OUT bind', () {
      final payload = _buildPayload([
        _ioVector([16]),
        [
          ttcMsgTypeRowData,
          ..._bytesWithLength('hello'.codeUnits),
          ..._ub4(0),
        ],
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: false,
        bindMetadata: const [
          BindMetadata(
              oraType: oraTypeVarchar, maxSize: 100, dir: BindDir.output),
        ],
      );
      expect(r.outBindValues, equals(['hello']));
    });

    test('NULL OUT bind decodes as null', () {
      final payload = _buildPayload([
        _ioVector([16]),
        [
          ttcMsgTypeRowData,
          0, // length 0 (null indicator)
          ..._ub4(0),
        ],
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: false,
        bindMetadata: const [
          BindMetadata(
              oraType: oraTypeVarchar, maxSize: 100, dir: BindDir.output),
        ],
      );
      expect(r.outBindValues, equals([null]));
    });

    test('no OUT binds: outBindValues stays empty', () {
      // A bind list with only IN binds produces no OUT decode work even when
      // an IO_VECTOR is present (server only reports IN directions).
      final payload = _buildPayload([
        _ioVector([32, 32]),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: false,
        bindMetadata: const [
          BindMetadata(oraType: oraTypeNumber),
          BindMetadata(oraType: oraTypeVarchar),
        ],
      );
      expect(r.outBindIndices, isEmpty);
      expect(r.outBindValues, isEmpty);
    });
  });
}

/// Builds a minimal TTC IO_VECTOR message carrying the supplied directions.
///
/// Wire layout (matches node-oracledb processIOVector):
///   [type=11, flag(UB1), temp16(UB2)=numBinds, temp32(UB4)=0,
///    iters(UB4)=0, uacLen(UB2)=0, fastFetchLen(UB2)=0, rowidLen(UB2)=0,
///    direction(UB1) x numBinds]
List<int> _ioVector(List<int> directions) {
  return [
    ttcMsgTypeIoVector,
    0, // flag
    ..._ub2(directions.length), // temp16 = numBinds (low 16 bits)
    ..._ub4(0), // temp32 = 0 (high bits)
    ..._ub4(0), // num iters this time
    ..._ub2(0), // uac buffer length
    ..._ub2(0), // fast-fetch bitvector length
    ..._ub2(0), // rowid length
    ...directions,
  ];
}

/// Oracle base-100 encoding for the integer 5 (positive, 1 digit).
/// Format: exponent byte = 0xC1, then digit + 1 = 6.
List<int> _oracleNumberFiveBytes() => [0xC1, 6];

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
  int errorOffset = 0,
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
  // error position (SB4 on wire); use _ub4 to match the 4-byte readSB4 read.
  out.addAll(_ub4(errorOffset));
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
