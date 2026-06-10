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

  // Story 7.9 AC3: ExecuteResponse is immutable — list fields are
  // unmodifiable and the constructor takes defensive copies, so decode
  // state (or any caller-held list) is never aliased into the response.
  group('ExecuteResponse immutability (Story 7.9 AC3)', () {
    test('decoded response list fields are unmodifiable', () {
      final payload = _buildPayload([
        _rowHeader(),
        [ttcMsgTypeRowData, ..._bytesWithLength('hello'.codeUnits)],
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

      expect(() => r.rows.add(<Object?>[]), throwsUnsupportedError);
      expect(() => r.columnMetadata.add(col), throwsUnsupportedError);
      expect(() => r.outBindValues.add(null), throwsUnsupportedError);
      expect(() => r.outBindIndices.add(0), throwsUnsupportedError);
    });

    test('constructor takes defensive copies of caller-held lists', () {
      final rows = <List<Object?>>[
        <Object?>['a'],
      ];
      final cols = <ColumnMetadata>[
        const ColumnMetadata(
            name: 'VAL', oracleType: oraTypeVarchar, maxLength: 100),
      ];
      final response = ExecuteResponse(
        isSuccess: true,
        rows: rows,
        columnMetadata: cols,
      );

      rows.add(<Object?>['b']);
      cols.clear();

      expect(response.rows, hasLength(1),
          reason: 'mutating the source list must not leak into the response');
      expect(response.columnMetadata, hasLength(1),
          reason: 'mutating the source list must not leak into the response');
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

    // Story 7.9 AC3: ERROR num=0 on a query is a batch boundary — the cursor
    // is still open and more rows are pending (node-oracledb thin only
    // clears moreRowsToFetch on ORA-01403).
    test('query batch boundary (num=0, open cursor) signals more rows', () {
      final payload = _buildPayload([
        _errorMessage(errorNum: 0, cursorId: 7),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: true);
      expect(r.isSuccess, isTrue);
      expect(r.cursorId, equals(7));
      expect(r.moreRowsToFetch, isTrue,
          reason: 'num=0 with an open cursor means the prefetch window was '
              'filled — the transport must keep FETCHing');
    });

    // F1: a cached-cursor re-execute legitimately echoes cursorId == 0 while
    // the original cursor stays open, so the batch-boundary signal must NOT
    // be gated on the echoed id (node-oracledb clears moreRowsToFetch only on
    // ORA-01403). The transport supplies the request's own cursor id.
    test('query batch boundary with a zero cursor echo still signals more '
        'rows', () {
      final payload = _buildPayload([
        _errorMessage(errorNum: 0, cursorId: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: true);
      expect(r.isSuccess, isTrue);
      expect(r.moreRowsToFetch, isTrue,
          reason: 'only ORA-01403 ends the fetch — a zero cursor echo on a '
              're-executed cached statement must not truncate the drain');
    });

    // The no-ERROR-message default branch: a successful query batch can end
    // without ANY ERROR message (no end-of-fetch marker at all). The decoder
    // must default to moreRowsToFetch == true — "fetch when unsure" costs one
    // round trip answered by ORA-01403; "don't fetch" silently loses rows.
    test('successful query payload with row data but NO error message '
        'defaults moreRowsToFetch to true', () {
      const cols = [
        ColumnMetadata(name: 'C0', oracleType: oraTypeVarchar, maxLength: 100),
      ];
      final payload = _buildPayload([
        _rowHeader(),
        [ttcMsgTypeRowData, ..._bytesWithLength('hello'.codeUnits)],
        // Terminal STATUS only — no ERROR message arrived.
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: true,
        expectedColumns: cols,
      );
      expect(r.isSuccess, isTrue);
      expect(r.rows.single, equals(['hello']));
      expect(r.moreRowsToFetch, isTrue,
          reason: 'a batch that ended without an end-of-fetch marker must '
              'be reported as having more rows pending');
    });

    test('ORA-01403 with open cursor still ends the fetch', () {
      final payload = _buildPayload([
        _errorMessage(errorNum: 1403, cursorId: 7),
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

  // Story 7.7 AC1, AC2: column-metadata decode gates must mirror what each
  // negotiated TTC field version actually sends. A fixture built for version V
  // must decode without buffer misalignment when decoded at version V.
  group('Story 7.8 — real UB8 test helper (AC5)', () {
    test('_ub8 emits identical bytes to WriteBuffer.writeUB8 per size class',
        () {
      const values = [
        0,
        1,
        0xff,
        0x100,
        0xffff,
        0x10000,
        0xffffffff,
        0x100000000, // 2^32 — first value requiring the 8-byte form
        9007199254740993, // 2^53 + 1
        0x7fffffffffffffff,
      ];
      for (final v in values) {
        final wb = WriteBuffer();
        wb.writeUB8(v);
        expect(_ub8(v), equals(wb.toBytes()),
            reason: 'helper and production writer must agree for $v');
      }
    });

    test('a >2^32 value round-trips through the helper and ReadBuffer.readUB8',
        () {
      const value = 0x1234567890; // > 0xFFFFFFFF
      final bytes = _ub8(value);
      expect(bytes.first, equals(8),
          reason: 'values above 2^32 must use the 8-byte form');
      expect(ReadBuffer(Uint8List.fromList(bytes)).readUB8(), equals(value));
    });

    test('a >2^32 extended row count decodes through the real ERROR path', () {
      // Proves the fixture and decodeExecuteResponse agree on the UB8 wire
      // shape end-to-end (the pre-fix _ub8 alias could not represent this).
      const bigCount = 0x100000001; // 4294967297
      final payload = _buildPayload([
        _errorMessage(errorNum: 0, rowCount: bigCount),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: false);
      expect(r.rowsAffected, equals(bigCount));
    });
  });

  group('Story 7.8 — decodeExecuteResponse coverage (AC6)', () {
    test('NUMBER column variants decode through ROW_DATA (a)', () {
      // 42 → [0xC1, 43]; 123.45 → exp 1, digits [1,23,45] → [0xC2, 2, 24, 46];
      // -5 → complement digit 101-5=96, exp ~0xC1=0x3E, 0x66 terminator;
      // 0 → special single byte 0x80.
      final payload = _buildPayload([
        _rowHeader(),
        [
          ttcMsgTypeRowData,
          ..._bytesWithLength([0xC1, 43]),
          ..._bytesWithLength([0xC2, 2, 24, 46]),
          ..._bytesWithLength([0x3E, 96, 102]),
          ..._bytesWithLength([0x80]),
        ],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      const numberCol =
          ColumnMetadata(name: 'N', oracleType: oraTypeNumber, maxLength: 0);
      final r = decodeExecuteResponse(
        payload,
        isQuery: true,
        expectedColumns: const [numberCol, numberCol, numberCol, numberCol],
      );
      final row = r.rows.single;
      expect(row[0], equals(42));
      expect(row[0], isA<int>(),
          reason: 'bare integer-valued NUMBER keeps the int heuristic');
      expect(row[1], isA<double>());
      expect(row[1] as double, closeTo(123.45, 1e-9));
      expect(row[2], equals(-5));
      expect(row[3], equals(0));
    });

    test('mixed-type OUT/IN/IN OUT binds decode into correct slots (b)', () {
      // Directions [OUT DATE, IN NUMBER, IN OUT VARCHAR]: ROW_DATA carries
      // values only for the OUT and IN OUT slots, in SQL order. Distinct
      // types prove value↔slot pairing, not just index ordering.
      // DATE 2024-03-15 00:00:00 → [century+100, year+100, m, d, h+1, m+1, s+1].
      final payload = _buildPayload([
        _ioVector([16, 32, 48]),
        [
          ttcMsgTypeRowData,
          ..._bytesWithLength([120, 124, 3, 15, 1, 1, 1]),
          ..._ub4(0), // SB4 actualNumBytes trailer
          ..._bytesWithLength('xyz'.codeUnits),
          ..._ub4(0),
        ],
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: false,
        bindMetadata: const [
          BindMetadata(oraType: oraTypeDate, maxSize: 7, dir: BindDir.output),
          BindMetadata(oraType: oraTypeNumber, dir: BindDir.input),
          BindMetadata(
              oraType: oraTypeVarchar, maxSize: 100, dir: BindDir.inputOutput),
        ],
      );
      expect(r.outBindIndices, equals([0, 2]));
      expect(r.outBindValues, hasLength(2));
      expect(r.outBindValues[0], equals(DateTime(2024, 3, 15)));
      expect(r.outBindValues[1], equals('xyz'));
    });

    test('multi-column DESCRIBE_INFO parses names, types, precision, scale (c)',
        () {
      final payload = _buildPayload([
        _describeInfo([
          _columnInfo(name: 'NAME', oraType: oraTypeVarchar, maxSize: 50),
          _columnInfo(
            name: 'PRICE',
            oraType: oraTypeNumber,
            maxSize: 0,
            precisionByte: 10,
            scaleByte: 2,
          ),
          _columnInfo(name: 'CREATED', oraType: oraTypeDate, maxSize: 0),
        ]),
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: true);
      expect(r.columnMetadata, hasLength(3));
      expect(r.columnMetadata.map((c) => c.name),
          equals(['NAME', 'PRICE', 'CREATED']));
      expect(r.columnMetadata[0].oracleType, equals(oraTypeVarchar));
      expect(r.columnMetadata[0].maxLength, equals(50));
      expect(r.columnMetadata[1].oracleType, equals(oraTypeNumber));
      expect(r.columnMetadata[1].precision, equals(10));
      expect(r.columnMetadata[1].scale, equals(2));
      expect(r.columnMetadata[2].oracleType, equals(oraTypeDate));
      expect(r.columnMetadata[2].precision, isNull);
      expect(r.columnMetadata[2].scale, isNull);
    });

    test('chunked (0xFE) VARCHAR payload reassembles across chunks (d)', () {
      // 300 bytes split into 200 + 100 chunks via the long-length indicator;
      // the chunk loop ends on a zero-length UB4.
      final chunkA = List.filled(200, 0x41); // 'A'
      final chunkB = List.filled(100, 0x42); // 'B'
      final payload = _buildPayload([
        _rowHeader(),
        [
          ttcMsgTypeRowData,
          0xFE, // TNS long-length indicator
          ..._ub4(chunkA.length),
          ...chunkA,
          ..._ub4(chunkB.length),
          ...chunkB,
          ..._ub4(0), // end of chunks
        ],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: true,
        expectedColumns: const [
          ColumnMetadata(
              name: 'BIG', oracleType: oraTypeVarchar, maxLength: 4000),
        ],
      );
      final value = r.rows.single.single;
      expect(value, equals('A' * 200 + 'B' * 100));
      expect((value as String).length, equals(300));
    });

    test('DML rowsAffected decodes single and large non-trivial counts (e)',
        () {
      for (final count in [1, 100000]) {
        final payload = _buildPayload([
          _errorMessage(errorNum: 0, rowCount: count),
          [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
        ]);
        final r = decodeExecuteResponse(payload, isQuery: false);
        expect(r.rowsAffected, equals(count), reason: 'count $count');
      }
    });
  });

  group('Story 7.8 — fixed-scale NUMBER decode (AC7)', () {
    List<int> numberColumnPayload({required int scaleByte}) => _buildPayload([
          _describeInfo([
            _columnInfo(
              name: 'N',
              oraType: oraTypeNumber,
              maxSize: 0,
              precisionByte: 10,
              scaleByte: scaleByte,
            ),
          ]),
          _rowHeader(),
          [
            ttcMsgTypeRowData,
            ..._bytesWithLength([0xC1, 43])
          ], // 42
          _errorMessage(errorNum: 1403),
          [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
        ]);

    test('declared scale > 0 forces double for an integer-valued NUMBER', () {
      final r = decodeExecuteResponse(
        Uint8List.fromList(numberColumnPayload(scaleByte: 2)),
        isQuery: true,
      );
      expect(r.columnMetadata.single.scale, equals(2));
      final value = r.rows.single.single;
      expect(value, isA<double>(),
          reason: 'NUMBER(10,2) must decode integer-valued 42 as 42.0 '
              '(node-oracledb always-Number contract)');
      expect(value, equals(42.0));
    });

    test('bare NUMBER (wire scale -127 sentinel) keeps the int heuristic', () {
      // Oracle reports scale as a SIGNED Int8: bare NUMBER / FLOAT send -127
      // (0x81) meaning "no declared scale" — node-oracledb base.js reads it
      // with readInt8(). It must surface as scale == null, not 129.
      final r = decodeExecuteResponse(
        Uint8List.fromList(numberColumnPayload(scaleByte: 0x81)),
        isQuery: true,
      );
      expect(r.columnMetadata.single.scale, isNull,
          reason: '-127 is the no-scale sentinel, not a declared scale');
      final value = r.rows.single.single;
      expect(value, isA<int>(),
          reason: 'bare NUMBER keeps the int-vs-double heuristic');
      expect(value, equals(42));
    });

    test('NUMBER(10,0) (declared scale 0) keeps the int heuristic', () {
      final r = decodeExecuteResponse(
        Uint8List.fromList(numberColumnPayload(scaleByte: 0)),
        isQuery: true,
      );
      expect(r.columnMetadata.single.scale, isNull);
      expect(r.rows.single.single, isA<int>());
    });
  });

  group('Story 7.7 — column metadata version gating (AC1, AC2)', () {
    // Decodes a single-column DESCRIBE_INFO built for [version] and asserts the
    // column survived round-trip intact (a misaligned gate corrupts the name or
    // throws). Uses a query response terminated by ORA-01403 + STATUS.
    void expectColumnDecodes(int version) {
      final payload = _buildPayload([
        _describeInfo([
          _columnInfo(
              name: 'C1',
              oraType: oraTypeVarchar,
              maxSize: 10,
              ttcFieldVersion: version),
        ]),
        _errorMessage(errorNum: 1403, ttcFieldVersion: version),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload,
          isQuery: true, ttcFieldVersion: version);
      expect(r.isSuccess, isTrue);
      expect(r.columnMetadata, hasLength(1));
      expect(r.columnMetadata.single.name, equals('C1'),
          reason: 'column name must survive decode at field version $version');
      expect(r.columnMetadata.single.oracleType, equals(oraTypeVarchar));
    }

    test('AC2: pre-12.2 server sends no oaccolid — decode stays aligned', () {
      // Field version 7 is below the 12.2 threshold (8); the server omits
      // oaccolid. The decoder must skip the oaccolid read or it over-reads.
      expectColumnDecodes(7);
    });

    test('AC2: 12.2 server sends oaccolid — decode consumes it', () {
      expectColumnDecodes(ttcCcapFieldVersion12_2); // 8
    });

    test('AC1: pre-23.4 server sends no vector tail — decode stays aligned',
        () {
      // Version 23 has 12.2 + 23.1 + 23.1-ext3 fields but NOT the 23.4 vector
      // tail; reading the vector bytes here would misalign the buffer.
      expectColumnDecodes(23);
    });

    test('AC1: 23.4 server sends the vector tail — decode consumes it', () {
      expectColumnDecodes(ttcCcapFieldVersion23_4); // 24
    });
  });

  // Story 7.7 AC3: fast-fetch and rowid lengths in IO_VECTOR are UB2
  // variable-length integers; their payloads must be skipped exactly before
  // the direction bytes are read.
  group('Story 7.7 — IO_VECTOR fast-fetch / rowid skip (AC3)', () {
    test('non-zero fast-fetch and rowid payloads are skipped before directions',
        () {
      // One OUT NUMBER bind. Inject a 3-byte fast-fetch payload and a 2-byte
      // rowid payload via UB2 length prefixes. If the decoder mis-reads those
      // lengths (e.g. as fixed 2-byte raw) or fails to skip the payloads, the
      // single direction byte and the ROW_DATA value will misalign and the OUT
      // bind will not decode to 5.
      final payload = _buildPayload([
        _ioVector([16],
            fastFetch: const [0xAA, 0xBB, 0xCC], rowid: const [0x01, 0x02]),
        [
          ttcMsgTypeRowData,
          ..._bytesWithLength(_oracleNumberFiveBytes()),
          ..._ub4(0), // SB4 actualNumBytes trailer
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
        ],
      );
      expect(r.outBindIndices, equals([0]));
      expect(r.outBindValues, equals([5]),
          reason: 'fast-fetch and rowid payloads must be skipped exactly');
    });
  });

  // Story 7.7 AC5: LONG / LONG RAW are not supported until Epic 4. Decoding one
  // must surface a clear unsupported-type error, not silently corrupt via the
  // 0xFF-as-null length heuristic.
  group('Story 7.7 — LONG / LONG RAW unsupported (AC5)', () {
    Uint8List longColumnResponse(int oraType) => _buildPayload([
          _describeInfo([
            _columnInfo(name: 'BODY', oraType: oraType, maxSize: 0),
          ]),
          _rowHeader(),
          [ttcMsgTypeRowData, ..._bytesWithLength('payload'.codeUnits)],
          _errorMessage(errorNum: 1403),
          [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
        ]);

    test('LONG column decode raises an unsupported-type OracleException', () {
      expect(
        () => decodeExecuteResponse(longColumnResponse(oraTypeLong),
            isQuery: true),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
            .having((e) => e.message, 'message', contains('LONG'))),
      );
    });

    test('LONG RAW column decode raises an unsupported-type OracleException',
        () {
      expect(
        () => decodeExecuteResponse(longColumnResponse(oraTypeLongRaw),
            isQuery: true),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)),
      );
    });

    test('ttcStreamIsComplete still reaches the terminal past a LONG column',
        () {
      // The completion probe must NOT throw on an unsupported type — it decodes
      // leniently so it can locate the terminal STATUS. (The real decode pass
      // raises the error, asserted above.)
      final payload = longColumnResponse(oraTypeLong);
      expect(ttcStreamIsComplete(payload), isTrue);
    });
  });

  // Story 7.7 AC8: a pre-12.2 server sends no extended row-count field, so an
  // absent count must surface as null (distinct from a confirmed 0).
  group('Story 7.7 — pre-12.2 DML row-count is null (AC8)', () {
    test('pre-12.2 DML success leaves rowsAffected null, not 0', () {
      final payload = _buildPayload([
        _errorMessage(errorNum: 0, ttcFieldVersion: 7),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r =
          decodeExecuteResponse(payload, isQuery: false, ttcFieldVersion: 7);
      expect(r.isSuccess, isTrue);
      expect(r.rowsAffected, isNull,
          reason: 'absent pre-12.2 row count must be null, not 0');
    });

    test('12.2 DML success still returns the decoded UB8 row count', () {
      final payload = _buildPayload([
        _errorMessage(
            errorNum: 0, rowCount: 5, ttcFieldVersion: ttcCcapFieldVersion12_2),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload,
          isQuery: false, ttcFieldVersion: ttcCcapFieldVersion12_2);
      expect(r.rowsAffected, equals(5));
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
          BindMetadata(oraType: oraTypeNumber, dir: BindDir.input),
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

    test('Story 3.3 — IN OUT bind writes input value into ROW_DATA', () {
      // For an IN OUT bind, the input value must appear in ROW_DATA (unlike
      // an OUT-only bind, which writes only the null-indicator byte). Use
      // the integer 5, which Oracle encodes as bytes [0xC1, 6] (2 bytes).
      // The ROW_DATA segment for a NUMBER IN OUT bind containing the value 5
      // looks like: [length=2, 0xC1, 0x06].
      final req = ExecuteRequest(
        sql: 'BEGIN myproc(:v); END;',
        isQuery: false,
        isPlSql: true,
        bindValues: [
          BindVariable(
            value: 5,
            oraType: oraTypeNumber,
            maxSize: 22,
            dir: BindDir.inputOutput,
          ),
        ],
        bindNames: const ['v'],
      );
      final bytes = req.toBytes();
      final rowDataIdx = bytes.indexOf(ttcMsgTypeRowData);
      expect(rowDataIdx, greaterThan(0));
      // Byte after marker is length=2, then the Oracle base-100 NUMBER bytes.
      expect(bytes[rowDataIdx + 1], equals(2),
          reason: 'IN OUT bind must serialize the input value, not a NULL '
              'indicator');
      expect(bytes[rowDataIdx + 2], equals(0xC1));
      expect(bytes[rowDataIdx + 3], equals(0x06));
    });

    test('Story 3.3 — OUT bind still writes the null-indicator byte', () {
      // Regression for Story 3.2 OUT-only behavior: a pure OUT bind must not
      // write input bytes, only the length=0 null indicator. This guards
      // against the IN OUT change above touching OUT-only emission.
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
      final rowDataIdx = bytes.indexOf(ttcMsgTypeRowData);
      expect(rowDataIdx, greaterThan(0));
      expect(bytes[rowDataIdx + 1], equals(0));
    });

    test('Story 3.3 — IN OUT in non-PL/SQL statement throws OracleException',
        () {
      expect(
        () => ExecuteRequest(
          sql: 'SELECT :v FROM dual',
          isQuery: true,
          bindValues: [
            BindVariable(
              value: 1,
              oraType: oraTypeNumber,
              dir: BindDir.inputOutput,
            ),
          ],
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(6502))),
      );
    });

    test('Story 3.3 — IO_VECTOR with mixed OUT (16) and IN OUT (48) directions',
        () {
      // Server reports directions [OUT, IN, IN OUT] for three binds.
      // Both OUT and IN OUT must show up in outBindIndices, in SQL order,
      // and values are decoded in returned order.
      final payload = _buildPayload([
        _ioVector([16, 32, 48]),
        // ROW_DATA: bind 0 (OUT NUMBER = 5), bind 2 (IN OUT NUMBER = 6).
        // Oracle base-100 6 → [0xC1, 0x07].
        [
          ttcMsgTypeRowData,
          ..._bytesWithLength(_oracleNumberFiveBytes()),
          ..._ub4(0), // SB4 trailer
          ..._bytesWithLength([0xC1, 0x07]),
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
              oraType: oraTypeNumber, maxSize: 22, dir: BindDir.output),
          BindMetadata(oraType: oraTypeNumber, dir: BindDir.input),
          BindMetadata(
              oraType: oraTypeNumber, maxSize: 22, dir: BindDir.inputOutput),
        ],
      );
      expect(r.isSuccess, isTrue);
      expect(r.outBindIndices, equals([0, 2]),
          reason: 'Both OUT (16) and IN OUT (48) directions surface as '
              'outputs in SQL order');
      expect(r.outBindValues, equals([5, 6]));
    });

    test('Story 3.3 — IN OUT alone (direction 48) decodes returned value', () {
      final payload = _buildPayload([
        _ioVector([48]),
        [
          ttcMsgTypeRowData,
          ..._bytesWithLength('updated'.codeUnits),
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
              oraType: oraTypeVarchar, maxSize: 100, dir: BindDir.inputOutput),
        ],
      );
      expect(r.outBindIndices, equals([0]));
      expect(r.outBindValues, equals(['updated']));
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
          BindMetadata(oraType: oraTypeNumber, dir: BindDir.input),
          BindMetadata(oraType: oraTypeVarchar, dir: BindDir.input),
        ],
      );
      expect(r.outBindIndices, isEmpty);
      expect(r.outBindValues, isEmpty);
    });
  });

  group('Story 7.2 — IO_VECTOR and OUT-bind hardening', () {
    test('AC1 — unknown direction byte raises OracleException', () {
      // Synthesize an IO_VECTOR with a direction byte (99) that is neither
      // tnsBindDirInput (32), tnsBindDirOutput (16), nor tnsBindDirInputOutput
      // (48). The decoder must surface a protocol error rather than treat
      // 99 as an output direction.
      final payload = _buildPayload([
        _ioVector([99]),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(
        () => decodeExecuteResponse(
          payload,
          isQuery: false,
          bindMetadata: const [
            BindMetadata(oraType: oraTypeNumber, dir: BindDir.input),
          ],
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))),
      );
    });

    test('AC2 — server OUT for client-declared IN raises mismatch', () {
      // Client declared bind 0 as IN; server reports direction 16 (OUT).
      // The two views disagree —
      // raise a protocol error rather than silently follow the server.
      final payload = _buildPayload([
        _ioVector([16]),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(
        () => decodeExecuteResponse(
          payload,
          isQuery: false,
          bindMetadata: const [
            BindMetadata(oraType: oraTypeNumber, dir: BindDir.input),
          ],
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
            .having(
                (e) => e.message, 'message', contains('client declared IN'))),
      );
    });

    test('AC2 — server OUT vs client IN OUT raises mismatch', () {
      final payload = _buildPayload([
        _ioVector([16]),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(
        () => decodeExecuteResponse(
          payload,
          isQuery: false,
          bindMetadata: const [
            BindMetadata(
                oraType: oraTypeNumber, maxSize: 22, dir: BindDir.inputOutput),
          ],
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
            .having((e) => e.message, 'message',
                contains('client declared inputOutput'))),
      );
    });

    test('AC2 — server IN OUT vs client OUT raises mismatch', () {
      final payload = _buildPayload([
        _ioVector([48]),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(
        () => decodeExecuteResponse(
          payload,
          isQuery: false,
          bindMetadata: const [
            BindMetadata(
                oraType: oraTypeNumber, maxSize: 22, dir: BindDir.output),
          ],
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
            .having((e) => e.message, 'message',
                contains('client declared output'))),
      );
    });

    test(
        'AC3 — all-null OUT-bind decode does not re-enable decoding on '
        'subsequent ROW_DATA-style state transitions', () {
      // Pre-Story-7.2 the double-decode guard used `outBindValues.isEmpty`.
      // After this story it uses an explicit `outBindsDecoded` flag, so the
      // first decode is the authoritative one regardless of whether every
      // decoded value happened to be null. We exercise this by running the
      // same payload through ttcStreamIsComplete (one decode pass) and then
      // decodeExecuteResponse (a second pass on the same bytes) — both
      // produce the same single-null result without one influencing the
      // other. Pre-fix, swapping the guard to `outBindValues.isEmpty` after
      // a true zero-output decode would have re-entered the loop on the
      // second pass and shifted bytes; this test pins the new contract.
      final payload = _buildPayload([
        _ioVector([16]),
        [
          ttcMsgTypeRowData,
          0, // null indicator (length 0)
          ..._ub4(0), // SB4 trailer
        ],
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      const meta = [
        BindMetadata(oraType: oraTypeNumber, maxSize: 22, dir: BindDir.output),
      ];
      expect(ttcStreamIsComplete(payload, bindMetadata: meta), isTrue);
      final r = decodeExecuteResponse(
        payload,
        isQuery: false,
        bindMetadata: meta,
      );
      expect(r.isSuccess, isTrue);
      expect(r.outBindValues, equals([null]));
    });

    test('AC9 — numBinds > 65535 raises OracleException', () {
      // Hand-craft an IO_VECTOR whose temp32 high field is 256, producing
      // numBinds = 256 * 256 + 0 = 65536 (just over the Oracle bind ceiling).
      // The decoder must reject this rather than try to iterate that many
      // direction bytes.
      final ioVector = <int>[
        ttcMsgTypeIoVector,
        0, // flag
        ..._ub2(0), // temp16
        ..._ub4(256), // temp32 — produces 65536 when multiplied by 256
        ..._ub4(0), // num iters this time
        ..._ub2(0), // uac buffer length
        ..._ub2(0), // fast-fetch
        ..._ub2(0), // rowid
        // No direction bytes — decoder must throw before reading any.
      ];
      final payload = _buildPayload([
        ioVector,
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(
        () => decodeExecuteResponse(payload, isQuery: false),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
            .having((e) => e.message, 'message', contains('implausible'))),
      );
    });

    test('AC2 — server IN for client-declared OUT raises mismatch', () {
      // Review patch: the previous implementation `continue`d on direction 32
      // before running the consistency check, silently dropping a server-IN
      // for a bind the client declared OUT. The fix moves the consistency
      // check ahead of the input-direction shortcut so this asymmetric case
      // is caught too.
      final payload = _buildPayload([
        _ioVector([32]),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(
        () => decodeExecuteResponse(
          payload,
          isQuery: false,
          bindMetadata: const [
            BindMetadata(
                oraType: oraTypeNumber, maxSize: 22, dir: BindDir.output),
          ],
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
            .having((e) => e.message, 'message',
                contains('client declared output'))),
      );
    });

    test('AC2 — server IN for client-declared IN OUT raises mismatch', () {
      final payload = _buildPayload([
        _ioVector([32]),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(
        () => decodeExecuteResponse(
          payload,
          isQuery: false,
          bindMetadata: const [
            BindMetadata(
                oraType: oraTypeNumber, maxSize: 22, dir: BindDir.inputOutput),
          ],
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
            .having((e) => e.message, 'message',
                contains('client declared inputOutput'))),
      );
    });

    test('AC2 — missing metadata leaves stream alignment to ROW_DATA', () {
      // When `bindMetadata.length` is smaller than the server-reported bind
      // count, the consistency check has nothing to compare against; the
      // decoder should fall through to the conservative ROW_DATA branch
      // that consumes bytes and emits null for those slots. This keeps the
      // legacy stream-alignment behavior intact for unknown trailing binds.
      final payload = _buildPayload([
        _ioVector([16, 16]),
        [
          ttcMsgTypeRowData,
          ..._bytesWithLength('hi'.codeUnits),
          ..._ub4(0),
          // Second slot: no metadata means the decoder reads bytes
          // conservatively and emits null.
          ..._bytesWithLength('world'.codeUnits),
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
      expect(r.outBindIndices, equals([0, 1]));
      expect(r.outBindValues, hasLength(2));
      expect(r.outBindValues[0], equals('hi'));
      // Trailing bind without metadata: bytes consumed, value null.
      expect(r.outBindValues[1], isNull);
    });
  });

  // F2 / F3: duplicate-column bit-vector lifecycle. A bit vector describes
  // exactly one row (node-oracledb withData.js:252 clears it after each
  // processRowData); the duplicate source for the first row of a FETCH
  // continuation is the last row of the previous round.
  group('duplicate-column bit vector lifecycle (F2, F3)', () {
    const cols = [
      ColumnMetadata(name: 'C0', oracleType: oraTypeVarchar, maxLength: 100),
      ColumnMetadata(name: 'C1', oracleType: oraTypeVarchar, maxLength: 100),
    ];

    test('stale bit vector: the row after a duplicate-marked row decodes all '
        'columns from the wire', () {
      // Row 1 ships both columns; a BIT_VECTOR marks column 0 of row 2 as a
      // duplicate (row 2 ships only column 1); row 3 carries NO new vector
      // and ships both columns. Pre-fix the stale vector made row 3 copy
      // column 0 and mis-decode the remaining wire bytes (silent shear).
      final payload = _buildPayload([
        _rowHeader(),
        [
          ttcMsgTypeRowData,
          ..._bytesWithLength('aa'.codeUnits),
          ..._bytesWithLength('b1'.codeUnits),
        ],
        // Bit 0 clear = column 0 duplicate; bit 1 set = column 1 on the wire.
        _bitVector(2, [0x02]),
        [ttcMsgTypeRowData, ..._bytesWithLength('b2'.codeUnits)],
        [
          ttcMsgTypeRowData,
          ..._bytesWithLength('cc'.codeUnits),
          ..._bytesWithLength('b3'.codeUnits),
        ],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: true,
        expectedColumns: cols,
      );
      expect(r.rows, hasLength(3));
      expect(r.rows[0], equals(['aa', 'b1']));
      expect(r.rows[1], equals(['aa', 'b2']),
          reason: 'duplicate bit copies column 0 from the previous row');
      expect(r.rows[2], equals(['cc', 'b3']),
          reason: 'the vector must be cleared after row 2 — row 3 ships '
              'both columns on the wire');
    });

    test('cross-round duplicate copies from previousRoundLastRow', () {
      // First row of a FETCH continuation references the last row of the
      // previous round (which lives in the transport accumulator, not in
      // this response).
      final payload = _buildPayload([
        _rowHeader(),
        _bitVector(2, [0x02]),
        [ttcMsgTypeRowData, ..._bytesWithLength('x1'.codeUnits)],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: true,
        expectedColumns: cols,
        previousRoundLastRow: const <Object?>['prev0', 'prev1'],
      );
      expect(r.rows.single, equals(['prev0', 'x1']),
          reason: 'column 0 must be copied from the previous round\'s row');
    });

    test('cross-round duplicate with no prior row anywhere is a protocol '
        'error', () {
      final payload = _buildPayload([
        _rowHeader(),
        _bitVector(2, [0x02]),
        [ttcMsgTypeRowData, ..._bytesWithLength('x1'.codeUnits)],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(
        () => decodeExecuteResponse(
          payload,
          isQuery: true,
          expectedColumns: cols,
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
            .having((e) => e.message, 'message', contains('Duplicate'))),
        reason: 'silently decoding a duplicate column from the wire would '
            'shear every later column — must fail loud instead',
      );
    });

    test('cross-round duplicate against a too-short previousRoundLastRow is '
        'a protocol error (not a RangeError)', () {
      // Column 1 is marked duplicate ([0x01]: bit 0 set = col 0 on the wire,
      // bit 1 clear = col 1 duplicate), but the supplied prior row only has
      // one column — priorRow[1] would throw a raw RangeError.
      final payload = _buildPayload([
        _rowHeader(),
        _bitVector(2, [0x01]),
        [ttcMsgTypeRowData, ..._bytesWithLength('x0'.codeUnits)],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(
        () => decodeExecuteResponse(
          payload,
          isQuery: true,
          expectedColumns: cols,
          previousRoundLastRow: const <Object?>['prev0'],
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
            .having((e) => e.message, 'message',
                contains('prior-row length mismatch'))),
        reason: 'a RangeError escaping the decoder would lose all protocol '
            'context — fail loud with an OracleException instead',
      );
    });

    test('completion probe stays byte-accurate past a first-row duplicate',
        () {
      // ttcStreamIsComplete never receives a previous-round row; it must
      // skip the duplicate column WITHOUT consuming bytes and still locate
      // the terminal STATUS.
      final payload = _buildPayload([
        _rowHeader(),
        _bitVector(2, [0x02]),
        [ttcMsgTypeRowData, ..._bytesWithLength('x1'.codeUnits)],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(ttcStreamIsComplete(payload, expectedColumns: cols), isTrue);
    });

    test('bit vector with numColsSent < column count is a protocol error', () {
      // The server declares only 1 column in the bit-vector header but the
      // decode state has 2 columns. The truncated vector would leave the
      // second column's duplicate bit unset, silently shearing the row decode.
      // _processBitVector must catch this and throw oraProtocolError.
      final payload = _buildPayload([
        _rowHeader(),
        _bitVector(1, [0x02]), // numColsSent=1 but cols has 2 columns
        [ttcMsgTypeRowData, ..._bytesWithLength('x1'.codeUnits)],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(
        () => decodeExecuteResponse(
          payload,
          isQuery: true,
          expectedColumns: cols,
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
            .having((e) => e.message, 'message',
                contains('bit vector covers'))),
        reason: 'a truncated bit vector must fail loud rather than '
            'silently shearing the row decode',
      );
    });
  });

  // F14b: empty list inputs reuse canonical const empty lists (no per-DML
  // allocations) while staying unmodifiable.
  group('ExecuteResponse empty-list canonicalization (F14b)', () {
    test('empty list fields are canonical const instances', () {
      final a = ExecuteResponse(isSuccess: true);
      final b = ExecuteResponse(isSuccess: true);
      expect(identical(a.rows, b.rows), isTrue);
      expect(identical(a.columnMetadata, b.columnMetadata), isTrue);
      expect(identical(a.outBindValues, b.outBindValues), isTrue);
      expect(identical(a.outBindIndices, b.outBindIndices), isTrue);
    });

    test('empty list fields remain unmodifiable', () {
      final r = ExecuteResponse(isSuccess: true);
      expect(() => r.rows.add(<Object?>[]), throwsUnsupportedError);
      expect(
          () => r.columnMetadata.add(const ColumnMetadata(
              name: 'X', oracleType: oraTypeVarchar, maxLength: 1)),
          throwsUnsupportedError);
      expect(() => r.outBindValues.add(null), throwsUnsupportedError);
      expect(() => r.outBindIndices.add(0), throwsUnsupportedError);
    });
  });
}

/// Builds a minimal TTC IO_VECTOR message carrying the supplied directions.
///
/// Wire layout (matches node-oracledb processIOVector):
///   [type=11, flag(UB1), temp16(UB2)=numBinds, temp32(UB4)=0,
///    iters(UB4)=0, uacLen(UB2)=0, fastFetchLen(UB2), fastFetch bytes,
///    rowidLen(UB2), rowid bytes, direction(UB1) x numBinds]
///
/// [fastFetch] and [rowid] inject non-zero variable-length (UB2) payloads so a
/// test can prove `_processIoVector` skips exactly those bytes before reading
/// the direction bytes (AC3). Both default to empty (UB2 length 0).
List<int> _ioVector(List<int> directions,
    {List<int> fastFetch = const [], List<int> rowid = const []}) {
  return [
    ttcMsgTypeIoVector,
    0, // flag
    ..._ub2(directions.length), // temp16 = numBinds (low 16 bits)
    ..._ub4(0), // temp32 = 0 (high bits)
    ..._ub4(0), // num iters this time
    ..._ub2(0), // uac buffer length
    ..._ub2(fastFetch.length), // fast-fetch bitvector length (UB2)
    ...fastFetch,
    ..._ub2(rowid.length), // rowid length (UB2)
    ...rowid,
    ...directions,
  ];
}

/// Oracle base-100 encoding for the integer 5 (positive, 1 digit).
/// Format: exponent byte = 0xC1, then digit + 1 = 6.
List<int> _oracleNumberFiveBytes() => [0xC1, 6];

/// Builds a TTC BIT_VECTOR message: UB2 column count, then the raw vector
/// bytes (the decoder sizes the read from the known column count — bit SET
/// means "column is on the wire", bit CLEAR means "duplicate of the previous
/// row's column").
List<int> _bitVector(int numColsSent, List<int> vectorBytes) {
  return [ttcMsgTypeBitVector, ..._ub2(numColsSent), ...vectorBytes];
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
/// Emits exactly the fields a server at [ttcFieldVersion] would send, so the
/// fixture stays byte-aligned with what [_processColumnInfo] reads at that
/// negotiated version: the 12.2 `oaccolid` (>= 8), 23.1 domain schema/name
/// (>= 17), 23.1-ext3 annotations (>= 20), and 23.4 vector tail (>= 24) are
/// each present only at or above their threshold. Defaults to 24 (the value
/// [decodeExecuteResponse] uses unless told otherwise). When overriding
/// [ttcFieldVersion] here, pass the same value to [decodeExecuteResponse].
List<int> _columnInfo({
  required String name,
  required int oraType,
  required int maxSize,
  int ttcFieldVersion = 24,
  int precisionByte = 0,
  int scaleByte = 0,
}) {
  final nameBytes = name.codeUnits;
  return [
    oraType, // dataType
    0, // flags
    precisionByte, // precision (signed Int8 on the wire)
    scaleByte, // scale (signed Int8 on the wire; 0x81 = -127 bare sentinel)
    ..._ub4(maxSize), // maxSize
    ..._ub4(0), // max num array elements
    ..._ub8(0), // cont flags (UB8)
    ..._ub4(0), // oidLen = 0
    ..._ub2(0), // version
    ..._ub2(0), // charset id
    0, // csfrm
    ..._ub4(maxSize), // size
    if (ttcFieldVersion >= ttcCcapFieldVersion12_2) ..._ub4(0), // oaccolid
    0, // nullable
    0, // v7 name length
    ..._ub4(nameBytes.length), // nameLen
    ..._bytesWithLength(nameBytes), // name with length prefix
    ..._ub4(0), // schema len = 0
    ..._ub4(0), // type name len = 0
    ..._ub2(0), // column position
    ..._ub4(0), // uds flags
    if (ttcFieldVersion >= ttcCcapFieldVersion23_1) ...[
      ..._ub4(0), // domain schema len = 0
      ..._ub4(0), // domain name len = 0
    ],
    if (ttcFieldVersion >= ttcCcapFieldVersion23_1Ext3)
      ..._ub4(0), // annotations len = 0
    if (ttcFieldVersion >= ttcCcapFieldVersion23_4) ...[
      ..._ub4(0), // dimensions
      0, // vector format
      0, // vector flags
    ],
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

/// Emits a real variable-length UB8 mirroring `WriteBuffer.writeUB8`:
/// size byte 0/1/2/4/8 followed by that many big-endian payload bytes,
/// including the 8-byte form for values above 2³² (Story 7.8 AC5).
/// Deliberately decoupled from [_ub4], which caps at the 4-byte form.
List<int> _ub8(int v) {
  if (v == 0) return [0];
  if (v <= 0xff) return [1, v];
  if (v <= 0xffff) return [2, (v >> 8) & 0xff, v & 0xff];
  if (v <= 0xffffffff) {
    return [
      4,
      (v >> 24) & 0xff,
      (v >> 16) & 0xff,
      (v >> 8) & 0xff,
      v & 0xff,
    ];
  }
  return [
    8,
    (v >> 56) & 0xff,
    (v >> 48) & 0xff,
    (v >> 40) & 0xff,
    (v >> 32) & 0xff,
    (v >> 24) & 0xff,
    (v >> 16) & 0xff,
    (v >> 8) & 0xff,
    v & 0xff,
  ];
}

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
  int ttcFieldVersion = 24,
  int cursorId = 0,
}) {
  final out = <int>[ttcMsgTypeError];
  out.addAll(_ub4(0)); // end of call status
  out.addAll(_ub2(0)); // end-to-end seq num
  out.addAll(_ub4(0)); // current row
  out.addAll(_ub2(0)); // err num short
  out.addAll(_ub2(0)); // array elem
  out.addAll(_ub2(0)); // array elem
  out.addAll(_ub4(cursorId)); // cursor id (decoder reads readUB4)
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
  // Extended row count (UB8) is only sent by 12.2+ servers; 20.1+ adds the
  // sql-type + checksum pair. A pre-12.2 fixture omits both, matching what an
  // older server would send (AC8).
  if (ttcFieldVersion >= ttcCcapFieldVersion12_2) {
    out.addAll(_ub8(rowCount)); // extended row count
    if (ttcFieldVersion >= ttcCcapFieldVersion20_1) {
      out.addAll(_ub4(0)); // 20.1 sql type
      out.addAll(_ub4(0)); // 20.1 checksum
    }
  }
  if (errorNum != 0) {
    final msg = errorMessage ?? 'ORA-${errorNum.toString().padLeft(5, '0')}';
    out.addAll(_bytesWithLength(msg.codeUnits));
  }
  return out;
}
