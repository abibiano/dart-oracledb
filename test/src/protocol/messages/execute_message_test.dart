/// Unit tests for ExecuteRequest / ExecuteResponse / FetchRequest using the
/// real Oracle TTC EXECUTE wire format.
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
import 'package:oracledb/src/protocol/lob_locator.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/protocol/oson.dart' show encodeOson;

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
      expect(
        options & ttcExecOptionNotPlSql,
        equals(0),
      ); // queries clear NOT_PLSQL
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

    test(
      'PL/SQL with binds sets BIND+PLSQL_BIND, clears NOT_PLSQL and FETCH',
      () {
        final req = ExecuteRequest(
          sql: 'BEGIN my_proc(:1, :2); END;',
          isQuery: false,
          isPlSql: true,
          bindValues: [1, 'Alice'],
        );
        final bytes = req.toBytes();
        final options = _readOptionsFromHeader(bytes);
        expect(
          options & ttcExecOptionExecute,
          isNonZero,
          reason: 'EXECUTE must always be set',
        );
        expect(
          options & ttcExecOptionBind,
          isNonZero,
          reason: 'BIND must be set when bind values are present',
        );
        expect(
          options & ttcExecOptionPlSqlBind,
          isNonZero,
          reason: 'PLSQL_BIND must be set for PL/SQL with binds',
        );
        expect(
          options & ttcExecOptionNotPlSql,
          equals(0),
          reason: 'NOT_PLSQL must be cleared for PL/SQL blocks',
        );
        expect(
          options & ttcExecOptionFetch,
          equals(0),
          reason: 'FETCH must not be set for PL/SQL',
        );
      },
    );

    test('PL/SQL with no binds clears NOT_PLSQL and PLSQL_BIND', () {
      final req = ExecuteRequest(
        sql: 'BEGIN simple_proc(); END;',
        isQuery: false,
        isPlSql: true,
      );
      final bytes = req.toBytes();
      final options = _readOptionsFromHeader(bytes);
      expect(options & ttcExecOptionExecute, isNonZero);
      expect(
        options & ttcExecOptionNotPlSql,
        equals(0),
        reason: 'NOT_PLSQL must be cleared even without binds',
      );
      expect(
        options & ttcExecOptionPlSqlBind,
        equals(0),
        reason: 'PLSQL_BIND must not be set when there are no parameters',
      );
      expect(
        options & ttcExecOptionBind,
        equals(0),
        reason: 'BIND must not be set when there are no parameters',
      );
    });

    test('DML NOT_PLSQL bit is unchanged after PL/SQL isPlSql=false default', () {
      // Regression: isPlSql defaults to false, so existing DML tests are intact.
      final req = ExecuteRequest(
        sql: 'DELETE FROM t WHERE id = :1',
        isQuery: false,
        bindValues: [5],
      );
      final bytes = req.toBytes();
      final options = _readOptionsFromHeader(bytes);
      expect(
        options & ttcExecOptionNotPlSql,
        isNonZero,
        reason: 'DML must still set NOT_PLSQL when isPlSql defaults to false',
      );
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
        sql: 'SELECT 1 FROM dual',
        isQuery: true,
        sequence: 7,
      );
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
      expect(
        options & ttcExecOptionParse,
        equals(0),
        reason: 'PARSE bit must be cleared when reusing a cached cursor',
      );
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
        name: 'VAL',
        oracleType: oraTypeVarchar,
        maxLength: 100,
      );
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
        name: 'STALE',
        oracleType: oraTypeVarchar,
        maxLength: 10,
      );
      final r = decodeExecuteResponse(
        describePayload,
        isQuery: true,
        expectedColumns: [stale],
      );

      expect(
        r.columnMetadata.first.name,
        equals('FRESH'),
        reason: 'DESCRIBE_INFO must override expectedColumns',
      );
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

  // ExecuteResponse is immutable — list fields are unmodifiable and the
  // constructor takes defensive copies, so decode state (or any caller-held
  // list) is never aliased into the response.
  group('ExecuteResponse immutability', () {
    test('decoded response list fields are unmodifiable', () {
      final payload = _buildPayload([
        _rowHeader(),
        [ttcMsgTypeRowData, ..._bytesWithLength('hello'.codeUnits)],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      const col = ColumnMetadata(
        name: 'VAL',
        oracleType: oraTypeVarchar,
        maxLength: 100,
      );
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
          name: 'VAL',
          oracleType: oraTypeVarchar,
          maxLength: 100,
        ),
      ];
      final response = ExecuteResponse(
        isSuccess: true,
        rows: rows,
        columnMetadata: cols,
      );

      rows.add(<Object?>['b']);
      cols.clear();

      expect(
        response.rows,
        hasLength(1),
        reason: 'mutating the source list must not leak into the response',
      );
      expect(
        response.columnMetadata,
        hasLength(1),
        reason: 'mutating the source list must not leak into the response',
      );
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
          errorNum: 942,
          errorMessage: 'table or view does not exist',
        ),
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

    // ERROR num=0 on a query is a batch boundary — the cursor is still open
    // and more rows are pending (node-oracledb thin only clears
    // moreRowsToFetch on ORA-01403).
    test('query batch boundary (num=0, open cursor) signals more rows', () {
      final payload = _buildPayload([
        _errorMessage(errorNum: 0, cursorId: 7),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: true);
      expect(r.isSuccess, isTrue);
      expect(r.cursorId, equals(7));
      expect(
        r.moreRowsToFetch,
        isTrue,
        reason:
            'num=0 with an open cursor means the prefetch window was '
            'filled — the transport must keep FETCHing',
      );
    });

    // A cached-cursor re-execute legitimately echoes cursorId == 0 while the
    // original cursor stays open, so the batch-boundary signal must NOT
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
      expect(
        r.moreRowsToFetch,
        isTrue,
        reason:
            'only ORA-01403 ends the fetch — a zero cursor echo on a '
            're-executed cached statement must not truncate the drain',
      );
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
      expect(
        r.moreRowsToFetch,
        isTrue,
        reason:
            'a batch that ended without an end-of-fetch marker must '
            'be reported as having more rows pending',
      );
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

    // Preserve SQL error offset on failure responses.
    test('error response exposes SQL error offset from TTC ERROR', () {
      final payload = _buildPayload([
        _errorMessage(
          errorNum: 942,
          errorOffset: 14,
          errorMessage: 'table or view does not exist',
        ),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: false);
      expect(r.isSuccess, isFalse);
      expect(r.errorCode, equals(942));
      expect(
        r.errorOffset,
        equals(14),
        reason: 'SB4 error position must be preserved on the response',
      );
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

  // Column-metadata decode gates must mirror what each negotiated TTC field
  // version actually sends. A fixture built for version V must decode without
  // buffer misalignment when decoded at version V.
  group('real UB8 test helper', () {
    test(
      '_ub8 emits identical bytes to WriteBuffer.writeUB8 per size class',
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
          expect(
            _ub8(v),
            equals(wb.toBytes()),
            reason: 'helper and production writer must agree for $v',
          );
        }
      },
    );

    test(
      'a >2^32 value round-trips through the helper and ReadBuffer.readUB8',
      () {
        const value = 0x1234567890; // > 0xFFFFFFFF
        final bytes = _ub8(value);
        expect(
          bytes.first,
          equals(8),
          reason: 'values above 2^32 must use the 8-byte form',
        );
        expect(ReadBuffer(Uint8List.fromList(bytes)).readUB8(), equals(value));
      },
    );

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

  group('decodeExecuteResponse coverage', () {
    test('NUMBER column variants decode through ROW_DATA', () {
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
      const numberCol = ColumnMetadata(
        name: 'N',
        oracleType: oraTypeNumber,
        maxLength: 0,
      );
      final r = decodeExecuteResponse(
        payload,
        isQuery: true,
        expectedColumns: const [numberCol, numberCol, numberCol, numberCol],
      );
      final row = r.rows.single;
      expect(row[0], equals(42));
      expect(
        row[0],
        isA<int>(),
        reason: 'bare integer-valued NUMBER keeps the int heuristic',
      );
      expect(row[1], isA<double>());
      expect(row[1] as double, closeTo(123.45, 1e-9));
      expect(row[2], equals(-5));
      expect(row[3], equals(0));
    });

    test('mixed-type OUT/IN/IN OUT binds decode into correct slots', () {
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
            oraType: oraTypeVarchar,
            maxSize: 100,
            dir: BindDir.inputOutput,
          ),
        ],
      );
      expect(r.outBindIndices, equals([0, 2]));
      expect(r.outBindValues, hasLength(2));
      expect(r.outBindValues[0], equals(DateTime(2024, 3, 15)));
      expect(r.outBindValues[1], equals('xyz'));
    });

    test(
      'multi-column DESCRIBE_INFO parses names, types, precision, scale',
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
        expect(
          r.columnMetadata.map((c) => c.name),
          equals(['NAME', 'PRICE', 'CREATED']),
        );
        expect(r.columnMetadata[0].oracleType, equals(oraTypeVarchar));
        expect(r.columnMetadata[0].maxLength, equals(50));
        expect(r.columnMetadata[1].oracleType, equals(oraTypeNumber));
        expect(r.columnMetadata[1].precision, equals(10));
        expect(r.columnMetadata[1].scale, equals(2));
        expect(r.columnMetadata[2].oracleType, equals(oraTypeDate));
        expect(r.columnMetadata[2].precision, isNull);
        expect(r.columnMetadata[2].scale, isNull);
      },
    );

    test('chunked (0xFE) VARCHAR payload reassembles across chunks', () {
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
            name: 'BIG',
            oracleType: oraTypeVarchar,
            maxLength: 4000,
          ),
        ],
      );
      final value = r.rows.single.single;
      expect(value, equals('A' * 200 + 'B' * 100));
      expect((value as String).length, equals(300));
    });

    test('DML rowsAffected decodes single and large non-trivial counts', () {
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

  group('fixed-scale NUMBER decode', () {
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
        ..._bytesWithLength([0xC1, 43]),
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
      expect(
        value,
        isA<double>(),
        reason:
            'NUMBER(10,2) must decode integer-valued 42 as 42.0 '
            '(node-oracledb always-Number contract)',
      );
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
      expect(
        r.columnMetadata.single.scale,
        isNull,
        reason: '-127 is the no-scale sentinel, not a declared scale',
      );
      final value = r.rows.single.single;
      expect(
        value,
        isA<int>(),
        reason: 'bare NUMBER keeps the int-vs-double heuristic',
      );
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

  group('column metadata version gating', () {
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
            ttcFieldVersion: version,
          ),
        ]),
        _errorMessage(errorNum: 1403, ttcFieldVersion: version),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: true,
        ttcFieldVersion: version,
      );
      expect(r.isSuccess, isTrue);
      expect(r.columnMetadata, hasLength(1));
      expect(
        r.columnMetadata.single.name,
        equals('C1'),
        reason: 'column name must survive decode at field version $version',
      );
      expect(r.columnMetadata.single.oracleType, equals(oraTypeVarchar));
    }

    test('pre-12.2 server sends no oaccolid — decode stays aligned', () {
      // Field version 7 is below the 12.2 threshold (8); the server omits
      // oaccolid. The decoder must skip the oaccolid read or it over-reads.
      expectColumnDecodes(7);
    });

    test('12.2 server sends oaccolid — decode consumes it', () {
      expectColumnDecodes(ttcCcapFieldVersion12_2); // 8
    });

    test('pre-23.4 server sends no vector tail — decode stays aligned', () {
      // Version 23 has 12.2 + 23.1 + 23.1-ext3 fields but NOT the 23.4 vector
      // tail; reading the vector bytes here would misalign the buffer.
      expectColumnDecodes(23);
    });

    test('23.4 server sends the vector tail — decode consumes it', () {
      expectColumnDecodes(ttcCcapFieldVersion23_4); // 24
    });
  });

  // Fast-fetch and rowid lengths in IO_VECTOR are UB2 variable-length
  // integers; their payloads must be skipped exactly before the direction
  // bytes are read.
  group('IO_VECTOR fast-fetch / rowid skip', () {
    test(
      'non-zero fast-fetch and rowid payloads are skipped before directions',
      () {
        // One OUT NUMBER bind. Inject a 3-byte fast-fetch payload and a 2-byte
        // rowid payload via UB2 length prefixes. If the decoder mis-reads those
        // lengths (e.g. as fixed 2-byte raw) or fails to skip the payloads, the
        // single direction byte and the ROW_DATA value will misalign and the OUT
        // bind will not decode to 5.
        final payload = _buildPayload([
          _ioVector(
            [16],
            fastFetch: const [0xAA, 0xBB, 0xCC],
            rowid: const [0x01, 0x02],
          ),
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
              oraType: oraTypeNumber,
              maxSize: 22,
              dir: BindDir.output,
            ),
          ],
        );
        expect(r.outBindIndices, equals([0]));
        expect(
          r.outBindValues,
          equals([5]),
          reason: 'fast-fetch and rowid payloads must be skipped exactly',
        );
      },
    );
  });

  // LONG / LONG RAW are not yet supported. Decoding one must surface a clear
  // unsupported-type error, not silently corrupt via the 0xFF-as-null length
  // heuristic.
  group('LONG / LONG RAW unsupported', () {
    Uint8List longColumnResponse(int oraType) => _buildPayload([
      _describeInfo([_columnInfo(name: 'BODY', oraType: oraType, maxSize: 0)]),
      _rowHeader(),
      [ttcMsgTypeRowData, ..._bytesWithLength('payload'.codeUnits)],
      _errorMessage(errorNum: 1403),
      [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
    ]);

    test('LONG column decode raises an unsupported-type OracleException', () {
      expect(
        () => decodeExecuteResponse(
          longColumnResponse(oraTypeLong),
          isQuery: true,
        ),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
              .having((e) => e.message, 'message', contains('LONG')),
        ),
      );
    });

    test(
      'LONG RAW column decode raises an unsupported-type OracleException',
      () {
        expect(
          () => decodeExecuteResponse(
            longColumnResponse(oraTypeLongRaw),
            isQuery: true,
          ),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              oraUnsupportedType,
            ),
          ),
        );
      },
    );

    test('ttcStreamIsComplete still reaches the terminal past a LONG column', () {
      // The completion probe must NOT throw on an unsupported type — it decodes
      // leniently so it can locate the terminal STATUS. (The real decode pass
      // raises the error, asserted above.)
      final payload = longColumnResponse(oraTypeLong);
      expect(ttcStreamIsComplete(payload), isTrue);
    });
  });

  // A pre-12.2 server sends no extended row-count field, so an absent count
  // must surface as null (distinct from a confirmed 0).
  group('pre-12.2 DML row-count is null', () {
    test('pre-12.2 DML success leaves rowsAffected null, not 0', () {
      final payload = _buildPayload([
        _errorMessage(errorNum: 0, ttcFieldVersion: 7),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: false,
        ttcFieldVersion: 7,
      );
      expect(r.isSuccess, isTrue);
      expect(
        r.rowsAffected,
        isNull,
        reason: 'absent pre-12.2 row count must be null, not 0',
      );
    });

    test('12.2 DML success still returns the decoded UB8 row count', () {
      final payload = _buildPayload([
        _errorMessage(
          errorNum: 0,
          rowCount: 5,
          ttcFieldVersion: ttcCcapFieldVersion12_2,
        ),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: false,
        ttcFieldVersion: ttcCcapFieldVersion12_2,
      );
      expect(r.rowsAffected, equals(5));
    });
  });

  group('OUT bind encoding', () {
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
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(6502),
          ),
        ),
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
      expect(
        rowDataIdx,
        greaterThan(0),
        reason: 'ROW_DATA segment must be present for binds',
      );
      // Byte after ROW_DATA marker is the length indicator for the first bind.
      expect(
        bytes[rowDataIdx + 1],
        equals(0),
        reason: 'OUT bind must serialize as null-indicator (length 0)',
      );
    });
  });

  group('OUT bind decoding', () {
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
            oraType: oraTypeNumber,
            maxSize: 22,
            dir: BindDir.output,
          ),
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
        [ttcMsgTypeRowData, ..._bytesWithLength('hello'.codeUnits), ..._ub4(0)],
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: false,
        bindMetadata: const [
          BindMetadata(
            oraType: oraTypeVarchar,
            maxSize: 100,
            dir: BindDir.output,
          ),
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
            oraType: oraTypeVarchar,
            maxSize: 100,
            dir: BindDir.output,
          ),
        ],
      );
      expect(r.outBindValues, equals([null]));
    });

    test('IN OUT bind writes input value into ROW_DATA', () {
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
      expect(
        bytes[rowDataIdx + 1],
        equals(2),
        reason:
            'IN OUT bind must serialize the input value, not a NULL '
            'indicator',
      );
      expect(bytes[rowDataIdx + 2], equals(0xC1));
      expect(bytes[rowDataIdx + 3], equals(0x06));
    });

    test('OUT bind still writes the null-indicator byte', () {
      // Regression for OUT-only behavior: a pure OUT bind must not write
      // input bytes, only the length=0 null indicator. This guards
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

    test('IN OUT in non-PL/SQL statement throws OracleException', () {
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
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(6502),
          ),
        ),
      );
    });

    test('IO_VECTOR with mixed OUT (16) and IN OUT (48) directions', () {
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
            oraType: oraTypeNumber,
            maxSize: 22,
            dir: BindDir.output,
          ),
          BindMetadata(oraType: oraTypeNumber, dir: BindDir.input),
          BindMetadata(
            oraType: oraTypeNumber,
            maxSize: 22,
            dir: BindDir.inputOutput,
          ),
        ],
      );
      expect(r.isSuccess, isTrue);
      expect(
        r.outBindIndices,
        equals([0, 2]),
        reason:
            'Both OUT (16) and IN OUT (48) directions surface as '
            'outputs in SQL order',
      );
      expect(r.outBindValues, equals([5, 6]));
    });

    test('IN OUT alone (direction 48) decodes returned value', () {
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
            oraType: oraTypeVarchar,
            maxSize: 100,
            dir: BindDir.inputOutput,
          ),
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

  group('IO_VECTOR and OUT-bind hardening', () {
    test('unknown direction byte raises OracleException', () {
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
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(oraProtocolError),
          ),
        ),
      );
    });

    test('server OUT for client-declared IN raises mismatch', () {
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
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
              .having(
                (e) => e.message,
                'message',
                contains('client declared IN'),
              ),
        ),
      );
    });

    test('server OUT vs client IN OUT raises mismatch', () {
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
              oraType: oraTypeNumber,
              maxSize: 22,
              dir: BindDir.inputOutput,
            ),
          ],
        ),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
              .having(
                (e) => e.message,
                'message',
                contains('client declared inputOutput'),
              ),
        ),
      );
    });

    test('server IN OUT vs client OUT raises mismatch', () {
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
              oraType: oraTypeNumber,
              maxSize: 22,
              dir: BindDir.output,
            ),
          ],
        ),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
              .having(
                (e) => e.message,
                'message',
                contains('client declared output'),
              ),
        ),
      );
    });

    test('all-null OUT-bind decode does not re-enable decoding on '
        'subsequent ROW_DATA-style state transitions', () {
      // The double-decode guard used to use `outBindValues.isEmpty`. It now
      // uses an explicit `outBindsDecoded` flag, so the first decode is the
      // authoritative one regardless of whether every
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

    test('numBinds > 65535 raises OracleException', () {
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
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
              .having((e) => e.message, 'message', contains('implausible')),
        ),
      );
    });

    test('server IN for client-declared OUT raises mismatch', () {
      // A previous implementation `continue`d on direction 32 before running
      // the consistency check, silently dropping a server-IN
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
              oraType: oraTypeNumber,
              maxSize: 22,
              dir: BindDir.output,
            ),
          ],
        ),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
              .having(
                (e) => e.message,
                'message',
                contains('client declared output'),
              ),
        ),
      );
    });

    test('server IN for client-declared IN OUT raises mismatch', () {
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
              oraType: oraTypeNumber,
              maxSize: 22,
              dir: BindDir.inputOutput,
            ),
          ],
        ),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
              .having(
                (e) => e.message,
                'message',
                contains('client declared inputOutput'),
              ),
        ),
      );
    });

    test('missing metadata leaves stream alignment to ROW_DATA', () {
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
            oraType: oraTypeVarchar,
            maxSize: 100,
            dir: BindDir.output,
          ),
        ],
      );
      expect(r.outBindIndices, equals([0, 1]));
      expect(r.outBindValues, hasLength(2));
      expect(r.outBindValues[0], equals('hi'));
      // Trailing bind without metadata: bytes consumed, value null.
      expect(r.outBindValues[1], isNull);
    });
  });

  // Duplicate-column bit-vector lifecycle. A bit vector describes exactly one
  // row (node-oracledb withData.js:252 clears it after each processRowData);
  // the duplicate source for the first row of a FETCH continuation is the
  // last row of the previous round.
  group('duplicate-column bit vector lifecycle', () {
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
      expect(
        r.rows[1],
        equals(['aa', 'b2']),
        reason: 'duplicate bit copies column 0 from the previous row',
      );
      expect(
        r.rows[2],
        equals(['cc', 'b3']),
        reason:
            'the vector must be cleared after row 2 — row 3 ships '
            'both columns on the wire',
      );
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
      expect(
        r.rows.single,
        equals(['prev0', 'x1']),
        reason: 'column 0 must be copied from the previous round\'s row',
      );
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
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
              .having((e) => e.message, 'message', contains('Duplicate')),
        ),
        reason:
            'silently decoding a duplicate column from the wire would '
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
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', equals(oraProtocolError))
              .having(
                (e) => e.message,
                'message',
                contains('prior-row length mismatch'),
              ),
        ),
        reason:
            'a RangeError escaping the decoder would lose all protocol '
            'context — fail loud with an OracleException instead',
      );
    });

    test('completion probe stays byte-accurate past a first-row duplicate', () {
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
  });

  // Empty list inputs reuse canonical const empty lists (no per-DML
  // allocations) while staying unmodifiable.
  group('ExecuteResponse empty-list canonicalization', () {
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
        () => r.columnMetadata.add(
          const ColumnMetadata(
            name: 'X',
            oracleType: oraTypeVarchar,
            maxLength: 1,
          ),
        ),
        throwsUnsupportedError,
      );
      expect(() => r.outBindValues.add(null), throwsUnsupportedError);
      expect(() => r.outBindIndices.add(0), throwsUnsupportedError);
    });
  });

  // CLOB locator decode. The LOB-prefetch wire shape is UB4 locator length
  // (0 ⇒ SQL NULL), UB8 LOB length, UB4 chunk size, then the locator as
  // length-prefixed bytes.
  group('CLOB locator decode', () {
    final clobColumn = [
      _columnInfo(name: 'DOC', oraType: oraTypeClob, maxSize: 4000, csfrm: 1),
    ];
    final locatorBytes = List<int>.generate(40, (i) => 0xA0 + (i % 16));

    List<int> clobValue({int length = 11, int chunkSize = 8060}) => [
      ..._ub4(40), // locator length (> 0 ⇒ non-null)
      ..._ub8(length), // LOB length in chars
      ..._ub4(chunkSize), // chunk size
      ..._bytesWithLength(locatorBytes),
    ];

    test('CLOB column decodes to a LobLocator, not null and not a String', () {
      final payload = _buildPayload([
        _describeInfo(clobColumn),
        _rowHeader(),
        [ttcMsgTypeRowData, ...clobValue()],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: true);
      expect(r.isSuccess, isTrue);
      final value = r.rows.single.single;
      expect(value, isA<LobLocator>());
      final loc = value! as LobLocator;
      expect(loc.length, equals(11));
      expect(loc.oracleType, equals(oraTypeClob));
      expect(loc.chunkSize, equals(8060));
      expect(loc.locator, equals(locatorBytes));
      // ColumnMetadata survives decode for CLOB columns.
      expect(r.columnMetadata.single.oracleType, equals(oraTypeClob));
      expect(r.columnMetadata.single.csfrm, equals(1));
      expect(r.columnMetadata.single.name, equals('DOC'));
    });

    test('NULL CLOB (locator length 0) decodes to null, byte-accurately', () {
      // A trailing VARCHAR column proves no stray locator bytes were read.
      final payload = _buildPayload([
        _describeInfo([
          ...clobColumn,
          _columnInfo(name: 'TAG', oraType: oraTypeVarchar, maxSize: 10),
        ]),
        _rowHeader(),
        [
          ttcMsgTypeRowData,
          ..._ub4(0), // NULL CLOB — nothing follows for this column
          ..._bytesWithLength('ok'.codeUnits),
        ],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: true);
      expect(r.rows.single[0], isNull);
      expect(r.rows.single[1], equals('ok'));
    });

    test('EMPTY_CLOB() decodes to a locator with zero length', () {
      final payload = _buildPayload([
        _describeInfo(clobColumn),
        _rowHeader(),
        [ttcMsgTypeRowData, ...clobValue(length: 0)],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: true);
      final loc = r.rows.single.single! as LobLocator;
      expect(loc.length, equals(0));
    });

    test('CLOB OUT bind decodes through the locator shape', () {
      final payload = _buildPayload([
        _ioVector([16]),
        [
          ttcMsgTypeRowData,
          ...clobValue(length: 5, chunkSize: 4000),
          ..._ub4(0), // SB4 actualNumBytes trailer (non-fetch path)
        ],
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: false,
        bindMetadata: const [
          BindMetadata(oraType: oraTypeClob, maxSize: 100, dir: BindDir.output),
        ],
      );
      expect(r.outBindIndices, equals([0]));
      final loc = r.outBindValues.single! as LobLocator;
      expect(loc.length, equals(5));
      expect(loc.chunkSize, equals(4000));
    });

    test('BLOB column decodes to a byte-typed LobLocator', () {
      final payload = _buildPayload([
        _describeInfo([
          _columnInfo(name: 'B', oraType: oraTypeBlob, maxSize: 4000),
        ]),
        _rowHeader(),
        [ttcMsgTypeRowData, ...clobValue(length: 17, chunkSize: 8132)],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: true);
      expect(r.isSuccess, isTrue);
      final loc = r.rows.single.single! as LobLocator;
      expect(loc.oracleType, equals(oraTypeBlob));
      expect(loc.length, equals(17)); // bytes, not characters
      expect(loc.chunkSize, equals(8132));
      expect(loc.locator, equals(locatorBytes));
      // The lenient completion probe consumes the identical locator bytes
      // and still finds the terminal STATUS message.
      expect(ttcStreamIsComplete(payload), isTrue);
    });

    test('BLOB OUT bind decodes through the locator shape', () {
      final payload = _buildPayload([
        _ioVector([16]),
        [
          ttcMsgTypeRowData,
          ...clobValue(length: 9, chunkSize: 8132),
          ..._ub4(0), // SB4 actualNumBytes trailer (non-fetch path)
        ],
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: false,
        bindMetadata: const [
          BindMetadata(oraType: oraTypeBlob, maxSize: 100, dir: BindDir.output),
        ],
      );
      expect(r.outBindIndices, equals([0]));
      final loc = r.outBindValues.single! as LobLocator;
      expect(loc.oracleType, equals(oraTypeBlob));
      expect(loc.length, equals(9));
    });

    test('BFILE column still fails loud in the strict pass', () {
      final payload = _buildPayload([
        _describeInfo([
          _columnInfo(name: 'F', oraType: oraTypeBfile, maxSize: 4000),
        ]),
        _rowHeader(),
        [
          ttcMsgTypeRowData,
          // BFILE prefetch shape: locator length + locator only (no UB8
          // length / UB4 chunk size).
          ..._ub4(40),
          ..._bytesWithLength(locatorBytes),
        ],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(
        () => decodeExecuteResponse(payload, isQuery: true),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
              .having((e) => e.message, 'message', contains('BFILE')),
        ),
      );
      // The lenient completion probe consumes the identical BFILE bytes and
      // still finds the terminal STATUS message.
      expect(ttcStreamIsComplete(payload), isTrue);
    });

    test('NCLOB column (csfrm NCHAR) fails loud in the strict pass', () {
      final payload = _buildPayload([
        _describeInfo([
          _columnInfo(name: 'N', oraType: oraTypeClob, maxSize: 4000, csfrm: 2),
        ]),
        _rowHeader(),
        [ttcMsgTypeRowData, ...clobValue()],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(
        () => decodeExecuteResponse(payload, isQuery: true),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
              .having((e) => e.message, 'message', contains('NCLOB')),
        ),
      );
      expect(ttcStreamIsComplete(payload), isTrue);
    });
  });

  // JSON (type 119) decode: the wire shape is the LOB-prefetch form with the
  // OSON document inline (node-oracledb packet.js readOson): UB4 locator-ish
  // length (0 ⇒ SQL NULL, nothing follows), UB8 size and UB4 chunk size (both
  // unused), length-prefixed OSON data, length-prefixed locator (unused). No
  // LOB READ round trips and no LobLocator.
  group('JSON column decode (type 119)', () {
    List<int> jsonValue(Object? doc) {
      final oson = encodeOson(doc);
      return [
        ..._ub4(40), // non-null marker
        ..._ub8(oson.length), // size (unused)
        ..._ub4(8132), // chunk size (unused)
        ..._bytesWithLength(oson),
        ..._bytesWithLength(List.filled(40, 0xAB)), // locator (skipped)
      ];
    }

    test('JSON object column decodes to Map<String, Object?>', () {
      final doc = <String, Object?>{
        'name': 'rocket',
        'count': 3,
        'ratio': 2.5,
        'ok': true,
        'missing': null,
        'tags': <Object?>['a', 'b'],
        'nested': <String, Object?>{
          'deep': <Object?>[1, null],
        },
      };
      final payload = _buildPayload([
        _describeInfo([
          _columnInfo(name: 'DOC', oraType: oraTypeJson, maxSize: 0),
        ]),
        _rowHeader(),
        [ttcMsgTypeRowData, ...jsonValue(doc)],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: true);
      expect(r.isSuccess, isTrue);
      final value = r.rows.single.single;
      expect(value, isA<Map<String, Object?>>());
      expect(value, equals(doc));
      // The lenient completion probe consumes the identical JSON bytes and
      // still finds the terminal STATUS message.
      expect(ttcStreamIsComplete(payload), isTrue);
    });

    test('JSON array column decodes to List<Object?>', () {
      final doc = <Object?>[1, 'two', null, false];
      final payload = _buildPayload([
        _describeInfo([
          _columnInfo(name: 'DOC', oraType: oraTypeJson, maxSize: 0),
        ]),
        _rowHeader(),
        [ttcMsgTypeRowData, ...jsonValue(doc)],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: true);
      final value = r.rows.single.single;
      expect(value, isA<List<Object?>>());
      expect(value, equals(doc));
    });

    test('SQL NULL JSON column decodes to null (zero locator length)', () {
      final payload = _buildPayload([
        _describeInfo([
          _columnInfo(name: 'DOC', oraType: oraTypeJson, maxSize: 0),
        ]),
        _rowHeader(),
        // A NULL JSON value is exactly one UB4 zero — nothing follows.
        [ttcMsgTypeRowData, ..._ub4(0)],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: true);
      expect(r.rows.single.single, isNull);
      expect(ttcStreamIsComplete(payload), isTrue);
    });

    test(
      'unsupported OSON scalar node still fails loud in the strict pass',
      () {
        // Scalar OSON document whose node is BINARY_DOUBLE (0x36) — outside
        // the supported standard-JSON scope.
        final badOson = [
          0xff, 0x4a, 0x5a, 0x01, // magic + version
          0x00, 0x12, // flags: INLINE_LEAF | IS_SCALAR
          0x00, 0x09, // tree segment size
          0x36, 1, 2, 3, 4, 5, 6, 7, 8, // BINARY_DOUBLE node
        ];
        final payload = _buildPayload([
          _describeInfo([
            _columnInfo(name: 'DOC', oraType: oraTypeJson, maxSize: 0),
          ]),
          _rowHeader(),
          [
            ttcMsgTypeRowData,
            ..._ub4(40),
            ..._ub8(badOson.length),
            ..._ub4(8132),
            ..._bytesWithLength(badOson),
            ..._bytesWithLength(List.filled(40, 0xAB)),
          ],
          _errorMessage(errorNum: 1403),
          [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
        ]);
        expect(
          () => decodeExecuteResponse(payload, isQuery: true),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
                .having((e) => e.message, 'message', contains('BINARY_DOUBLE')),
          ),
        );
        // The lenient probe consumes the bytes without decoding the document.
        expect(ttcStreamIsComplete(payload), isTrue);
      },
    );

    test('JSON OUT bind decodes through outBinds', () {
      final doc = <String, Object?>{
        'result': <Object?>[1, 2, 3],
      };
      final payload = _buildPayload([
        _ioVector([16]),
        [
          ttcMsgTypeRowData,
          ...jsonValue(doc),
          ..._ub4(0), // SB4 actualNumBytes trailer (non-fetch path)
        ],
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: false,
        bindMetadata: const [
          BindMetadata(
            oraType: oraTypeJson,
            maxSize: 4000,
            dir: BindDir.output,
          ),
        ],
      );
      expect(r.outBindIndices, equals([0]));
      expect(r.outBindValues.single, equals(doc));
    });

    test('JSON OUT bind SQL NULL decodes to null', () {
      final payload = _buildPayload([
        _ioVector([16]),
        [ttcMsgTypeRowData, ..._ub4(0), ..._ub4(0)],
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: false,
        bindMetadata: const [
          BindMetadata(
            oraType: oraTypeJson,
            maxSize: 4000,
            dir: BindDir.output,
          ),
        ],
      );
      expect(r.outBindValues.single, isNull);
    });

    test(
      'JSON OUT bind enforces maxSize against returned OSON byte length',
      () {
        final doc = <String, Object?>{'big': 'x' * 100};
        final osonLength = encodeOson(doc).length;
        final payload = _buildPayload([
          _ioVector([16]),
          [ttcMsgTypeRowData, ...jsonValue(doc), ..._ub4(0)],
          _errorMessage(errorNum: 0),
          [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
        ]);
        expect(
          () => decodeExecuteResponse(
            payload,
            isQuery: false,
            bindMetadata: [
              BindMetadata(
                oraType: oraTypeJson,
                maxSize: osonLength - 1, // one byte too small — fail loud
                dir: BindDir.output,
              ),
            ],
          ),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              contains('maxSize'),
            ),
          ),
        );
      },
    );
  });

  group('JSON bind encode', () {
    test(
      'JSON bind metadata: type 119, prefetch flag, 32MB sizes, csfrm 0',
      () {
        final req = ExecuteRequest(
          sql: 'BEGIN p(:1); END;',
          isQuery: false,
          isPlSql: true,
          bindValues: [
            BindVariable(
              value: null,
              oraType: oraTypeJson,
              maxSize: 4000,
              dir: BindDir.output,
            ),
          ],
        );
        final bytes = req.toBytes();
        // Reference parity (node-oracledb writeColumnMetadata, DB_TYPE_JSON):
        // contFlag = TNS_LOB_PREFETCH_FLAG and maxSize = lobPrefetchLength =
        // TNS_JSON_MAX_LENGTH (32 MB) regardless of the user's maxSize, which
        // only guards the materialized value client-side. No charset (csfrm 0)
        // and NO locator buffer size — JSON is not a locator bind.
        final expectedMetadata = [
          oraTypeJson, ttcBindUseIndicators, 0, 0,
          4, 0x02, 0x00, 0x00, 0x00, // UB4 maxSize = 33554432 (32 MB)
          0, // UB4 max num elements
          4, 0x02, 0x00, 0x00, 0x00, // UB4 contFlag = TNS_LOB_PREFETCH_FLAG
          0, // UB4 OID
          0, // UB2 version
          0, // UB2 charset = 0 (no charset form)
          0, // csfrm = 0
          4, 0x02, 0x00, 0x00, 0x00, // UB4 lob prefetch length = 32 MB
          0, // UB4 oaccolid
        ];
        expect(
          _indexOfSub(bytes, expectedMetadata),
          greaterThanOrEqualTo(0),
          reason: 'JSON bind metadata block not found in encoded request',
        );
      },
    );

    test('JSON bind value writes QLocator + length-prefixed OSON bytes', () {
      final doc = <String, Object?>{'a': 1};
      final oson = encodeOson(doc);
      final req = ExecuteRequest(
        sql: 'INSERT INTO t VALUES (:1)',
        isQuery: false,
        bindValues: [doc],
      );
      final bytes = req.toBytes();
      // QLocator: UB4(40), then the 40-byte locator as length-prefixed
      // bytes. Body starts 0x0026 (internal length 38), 0x0004 (QLocator
      // version), 0x61 (value-based | abstract | blob), 0x08 (init), zeros,
      // 0x0001, then the OSON byte length as UInt64BE.
      final expectedValue = [
        1, 40, // UB4 QLocator length
        40, // length prefix of the locator bytes
        0x00, 0x26, 0x00, 0x04, 0x61, 0x08, 0x00, 0x00, 0x00, 0x01,
        ..._u64be(oson.length), // UInt64BE payload length (full 8-byte BE)
        ...List.filled(22, 0), // unused trailer fields
        ..._bytesWithLength(oson),
      ];
      expect(
        _indexOfSub(bytes, expectedValue),
        greaterThanOrEqualTo(0),
        reason: 'JSON QLocator + OSON value bytes not found',
      );
    });

    test('JSON bind QLocator payload length is big-endian across all 8 bytes', () {
      // The small-doc fixtures above keep the high 7 length bytes zero, so they
      // cannot tell a big-endian writer from a little-endian one for the
      // multi-byte case. Force OSON > 255 bytes (a long string member) so the
      // payload length spans two bytes, then assert the UInt64BE encoding
      // explicitly — a byte-swapped writer would now fail.
      final doc = <String, Object?>{'s': 'x' * 400};
      final oson = encodeOson(doc);
      expect(
        oson.length,
        greaterThan(255),
        reason: 'fixture must exercise the multi-byte length field',
      );
      final req = ExecuteRequest(
        sql: 'INSERT INTO t VALUES (:1)',
        isQuery: false,
        bindValues: [doc],
      );
      final bytes = req.toBytes();
      final lengthField = _u64be(oson.length);
      // The high bytes are zero but byte 6 (second-least-significant) is now
      // non-zero, so order matters: confirm the exact BE field is present.
      expect(
        lengthField[6],
        isNot(0),
        reason: 'length must span >1 byte to test endianness',
      );
      // Assert only the 40-byte QLocator (which carries the payload-length
      // field); the trailing OSON bytes use chunked length prefixing above 255
      // bytes and are covered by the round-trip tests, not this endianness pin.
      final expectedLocator = [
        1,
        40,
        40,
        0x00,
        0x26,
        0x00,
        0x04,
        0x61,
        0x08,
        0x00,
        0x00,
        0x00,
        0x01,
        ...lengthField,
        ...List.filled(22, 0),
      ];
      expect(
        _indexOfSub(bytes, expectedLocator),
        greaterThanOrEqualTo(0),
        reason:
            'big-endian UInt64BE payload length not found for >255-byte '
            'OSON',
      );
    });

    test(
      'JSON null bind writes an OSON null payload, not a null indicator',
      () {
        final req = ExecuteRequest(
          sql: 'BEGIN p(:1); END;',
          isQuery: false,
          isPlSql: true,
          bindValues: [
            BindVariable(
              value: null,
              oraType: oraTypeJson,
              maxSize: 4000,
              dir: BindDir.inputOutput,
            ),
          ],
        );
        final bytes = req.toBytes();
        // node-oracledb excludes JSON from the null-indicator shortcut: a null
        // JSON bind ships writeOson(null) — QLocator + OSON scalar null.
        final osonNull = encodeOson(null);
        final expectedTail = [
          1, 40, // UB4 QLocator length — present even for null
          40,
          0x00, 0x26, 0x00, 0x04, 0x61, 0x08, 0x00, 0x00, 0x00, 0x01,
          ..._u64be(
            osonNull.length,
          ), // UInt64BE payload length (full 8-byte BE)
          ...List.filled(22, 0),
          ..._bytesWithLength(osonNull),
        ];
        expect(
          _indexOfSub(bytes, expectedTail),
          greaterThanOrEqualTo(0),
          reason: 'null JSON bind must ship an OSON null payload',
        );
      },
    );

    test('Map and List bind values infer oraTypeJson; Uint8List stays RAW', () {
      expect(
        BindVariable(value: <String, Object?>{'a': 1}).oraType,
        equals(oraTypeJson),
      );
      expect(BindVariable(value: <Object?>[1, 2]).oraType, equals(oraTypeJson));
      // Regression traps: bytes stay RAW, strings stay VARCHAR.
      expect(BindVariable(value: Uint8List(3)).oraType, equals(oraTypeRaw));
      expect(BindVariable(value: '{"a":1}').oraType, equals(oraTypeVarchar));
    });

    test('invalid nested JSON values fail at BindVariable construction', () {
      expect(
        () => BindVariable(value: <String, Object?>{'t': DateTime.utc(2026)}),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => BindVariable(value: <Object?>[double.nan]),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => BindVariable(value: <Object, Object?>{1: 'bad key'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('JSON binds are not deferred in SQL long-data ordering', () {
      // The 32 MB metadata maxSize must NOT push JSON values into the
      // deferred long-data section: node-oracledb classifies long binds by
      // the variable's own maxSize, which stays small for JSON.
      final doc = <String, Object?>{'k': 'v'};
      final oson = encodeOson(doc);
      final req = ExecuteRequest(
        sql: 'INSERT INTO t VALUES (:1, :2)',
        isQuery: false,
        bindValues: [doc, 'abc'],
      );
      final bytes = req.toBytes();
      final jsonIdx = _indexOfSub(bytes, [..._bytesWithLength(oson)]);
      final shortIdx = _indexOfSub(bytes, [3, 0x61, 0x62, 0x63]);
      expect(jsonIdx, greaterThanOrEqualTo(0));
      expect(
        shortIdx,
        greaterThan(jsonIdx),
        reason:
            'JSON (bind :1) must be written before abc (bind :2) — '
            'in bind order, not deferred',
      );
    });
  });

  // CLOB bind encode: locator-sized metadata with the LOB prefetch
  // cont-flag, locator value writes, and SQL long-data ordering.
  group('CLOB bind encode', () {
    test(
      'CLOB bind metadata: type 112, prefetch flag, locator buffer size',
      () {
        final req = ExecuteRequest(
          sql: 'BEGIN p(:1); END;',
          isQuery: false,
          isPlSql: true,
          bindValues: [
            BindVariable(
              value: null,
              oraType: oraTypeClob,
              maxSize: 100000,
              dir: BindDir.output,
            ),
          ],
        );
        final bytes = req.toBytes();
        // Expected metadata block: oraType(112), flags(1), precision(0),
        // scale(0), UB4 maxSize=112 (locator buffer, NOT the user's 100000),
        // UB4 maxNumElements=0, UB4 contFlag=0x2000000, UB4 OID=0,
        // UB2 version=0, UB2 charset=873, csfrm=1, UB4 lobPrefetch=0,
        // UB4 oaccolid=0.
        final expectedMetadata = [
          oraTypeClob, ttcBindUseIndicators, 0, 0,
          1, 112, // UB4 maxSize = 112
          0, // UB4 max num elements
          4, 0x02, 0x00, 0x00, 0x00, // UB4 contFlag = TNS_LOB_PREFETCH_FLAG
          0, // UB4 OID
          0, // UB2 version
          2, 0x03, 0x69, // UB2 charset = 873
          1, // csfrm implicit
          0, // UB4 lob prefetch length
          0, // UB4 oaccolid
        ];
        expect(
          _indexOfSub(bytes, expectedMetadata),
          greaterThanOrEqualTo(0),
          reason: 'CLOB bind metadata block not found in encoded request',
        );
      },
    );

    test('CLOB bind value writes UB4 locator length + locator bytes', () {
      final locator = Uint8List.fromList(List.filled(40, 0xCD));
      final req = ExecuteRequest(
        sql: 'BEGIN p(:1); END;',
        isQuery: false,
        isPlSql: true,
        bindValues: [
          BindVariable(
            value: LobLocator(
              locator: locator,
              oracleType: oraTypeClob,
              length: 3,
              chunkSize: 0,
            ),
            oraType: oraTypeClob,
            dir: BindDir.input,
          ),
        ],
      );
      final bytes = req.toBytes();
      final expectedValue = [
        1, 40, // UB4 locator length
        40, ...locator, // bytes-with-length locator
      ];
      expect(
        _indexOfSub(bytes, expectedValue),
        greaterThanOrEqualTo(0),
        reason: 'locator bind value bytes not found in encoded request',
      );
    });

    test('a raw String under a CLOB bind type fails loud (internal guard)', () {
      final req = ExecuteRequest(
        sql: 'BEGIN p(:1); END;',
        isQuery: false,
        isPlSql: true,
        bindValues: [
          BindVariable(
            value: 'not converted',
            oraType: oraTypeClob,
            dir: BindDir.input,
          ),
        ],
      );
      expect(
        req.toBytes,
        throwsA(
          isA<OracleException>().having(
            (e) => e.message,
            'message',
            contains('LOB locator'),
          ),
        ),
      );
    });

    test('SQL DML writes >32767-byte string values after all other binds', () {
      final long = 'X' * 40000;
      final req = ExecuteRequest(
        sql: 'INSERT INTO t VALUES (:1, :2)',
        isQuery: false,
        bindValues: [long, 'abc'],
      );
      final bytes = req.toBytes();
      // Deferred ordering: even though the long string is bind :1, its bytes
      // are written last — the message ends with the chunked-encoding
      // terminator (UB4 0) right after the 'X' run, not with 'abc'.
      expect(
        bytes.last,
        equals(0),
        reason: 'message must end with the long chunk terminator',
      );
      expect(
        bytes[bytes.length - 2],
        equals(0x58),
        reason: 'the long X-run must be the final value written',
      );
      final shortIdx = _indexOfSub(bytes, [3, 0x61, 0x62, 0x63]);
      final chunkIdx = _indexOfSub(bytes, [0xFE, 2, 0x9C, 0x40]);
      expect(shortIdx, greaterThanOrEqualTo(0));
      expect(
        chunkIdx,
        greaterThan(shortIdx),
        reason: 'long value must be written after the short value',
      );
    });

    test('PL/SQL keeps bind-order value writes (no long-data deferral)', () {
      final long = 'X' * 40000;
      final req = ExecuteRequest(
        sql: 'BEGIN p(:1, :2); END;',
        isQuery: false,
        isPlSql: true,
        bindValues: [long, 'abc'],
      );
      final bytes = req.toBytes();
      // In-place ordering: the message ends with the 'abc' value bytes.
      expect(
        bytes.sublist(bytes.length - 4),
        equals([3, 0x61, 0x62, 0x63]),
        reason: 'PL/SQL writes values in bind order — abc is last',
      );
    });
  });

  // BLOB bind encode: locator-sized metadata with the LOB prefetch
  // cont-flag, no character set form, and locator value writes.
  group('BLOB bind encode', () {
    test(
      'BLOB bind metadata: type 113, prefetch flag, locator buffer size',
      () {
        final req = ExecuteRequest(
          sql: 'BEGIN p(:1); END;',
          isQuery: false,
          isPlSql: true,
          bindValues: [
            BindVariable(
              value: null,
              oraType: oraTypeBlob,
              maxSize: 100000,
              dir: BindDir.output,
            ),
          ],
        );
        final bytes = req.toBytes();
        // Expected metadata block: oraType(113), flags(1), precision(0),
        // scale(0), UB4 maxSize=112 (locator buffer, NOT the user's 100000),
        // UB4 maxNumElements=0, UB4 contFlag=0x2000000, UB4 OID=0,
        // UB2 version=0, UB2 charset=0 (BLOB has no charset), csfrm=0,
        // UB4 lobPrefetch=0, UB4 oaccolid=0.
        final expectedMetadata = [
          oraTypeBlob, ttcBindUseIndicators, 0, 0,
          1, 112, // UB4 maxSize = 112
          0, // UB4 max num elements
          4, 0x02, 0x00, 0x00, 0x00, // UB4 contFlag = TNS_LOB_PREFETCH_FLAG
          0, // UB4 OID
          0, // UB2 version
          0, // UB2 charset = 0 (binary)
          0, // csfrm = 0 (no character set form)
          0, // UB4 lob prefetch length
          0, // UB4 oaccolid
        ];
        expect(
          _indexOfSub(bytes, expectedMetadata),
          greaterThanOrEqualTo(0),
          reason: 'BLOB bind metadata block not found in encoded request',
        );
      },
    );

    test('BLOB bind value writes UB4 locator length + locator bytes', () {
      final locator = Uint8List.fromList(List.filled(40, 0xB7));
      final req = ExecuteRequest(
        sql: 'BEGIN p(:1); END;',
        isQuery: false,
        isPlSql: true,
        bindValues: [
          BindVariable(
            value: LobLocator(
              locator: locator,
              oracleType: oraTypeBlob,
              length: 5,
              chunkSize: 0,
            ),
            oraType: oraTypeBlob,
            dir: BindDir.input,
          ),
        ],
      );
      final bytes = req.toBytes();
      final expectedValue = [
        1, 40, // UB4 locator length
        40, ...locator, // bytes-with-length locator
      ];
      expect(
        _indexOfSub(bytes, expectedValue),
        greaterThanOrEqualTo(0),
        reason: 'locator bind value bytes not found in encoded request',
      );
    });

    test('raw Uint8List reaching the BLOB encoder is an internal error', () {
      final req = ExecuteRequest(
        sql: 'BEGIN p(:1); END;',
        isQuery: false,
        isPlSql: true,
        bindValues: [
          BindVariable(
            value: Uint8List.fromList([1, 2, 3]),
            oraType: oraTypeBlob,
            dir: BindDir.input,
          ),
        ],
      );
      expect(
        req.toBytes,
        throwsA(
          isA<OracleException>().having(
            (e) => e.message,
            'message',
            contains('LOB locator'),
          ),
        ),
      );
    });

    test('BLOB define block carries the prefetch flag and locator size', () {
      const blobCol = ColumnMetadata(
        name: 'B',
        oracleType: oraTypeBlob,
        maxLength: 4000,
      );
      const numberCol = ColumnMetadata(
        name: 'ID',
        oracleType: oraTypeNumber,
        maxLength: 0,
      );
      final req = ExecuteRequest(
        sql: 'SELECT id, b FROM t',
        isQuery: true,
        cursorId: 9,
        defineColumns: [numberCol, blobCol],
      );
      final bytes = req.toBytes();
      // BLOB define: type 113, locator buffer size 112 (not
      // ColumnMetadata.maxLength), LOB prefetch cont-flag, charset 0,
      // csfrm 0.
      final blobDefine = [
        oraTypeBlob, ttcBindUseIndicators, 0, 0,
        1, 112, // UB4 buffer size (locator allocation)
        0, // max num elements
        4, 0x02, 0x00, 0x00, 0x00, // UB4 contFlag = TNS_LOB_PREFETCH_FLAG
        0, // OID
        0, // version
        0, // UB2 charset = 0
        0, // csfrm = 0
        0, // prefetch length
        0, // oaccolid
      ];
      expect(
        _indexOfSub(bytes, blobDefine),
        greaterThanOrEqualTo(0),
        reason: 'BLOB define block not found in encoded request',
      );
    });
  });

  // RAW stays a length-prefixed scalar (type 23): no LOB locator, no
  // prefetch cont-flag, no temporary-LOB conversion. These tests pin the
  // wire shape so future LOB work cannot silently route RAW through the
  // LOB locator path.
  group('RAW scalar encode/decode', () {
    test('plain Uint8List bind infers oraTypeRaw, not BLOB', () {
      final bind = BindVariable(value: Uint8List.fromList([1, 2, 3]));
      expect(bind.oraType, equals(oraTypeRaw));
    });

    test('RAW column decode returns Uint8List preserving 0x00 and 0xFF', () {
      final bytes = [0x00, 0xDE, 0xAD, 0xFF, 0x00];
      final payload = _buildPayload([
        _rowHeader(),
        [ttcMsgTypeRowData, ..._bytesWithLength(bytes)],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: true,
        expectedColumns: const [
          ColumnMetadata(name: 'R', oracleType: oraTypeRaw, maxLength: 16),
        ],
      );
      final value = r.rows.single.single;
      expect(value, isA<Uint8List>());
      expect(value, equals(Uint8List.fromList(bytes)));
    });

    test('zero-length RAW field decodes as null (Oracle NULL convention)', () {
      final payload = _buildPayload([
        _rowHeader(),
        [
          ttcMsgTypeRowData,
          0, // zero-length indicator = SQL NULL
        ],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: true,
        expectedColumns: const [
          ColumnMetadata(name: 'R', oracleType: oraTypeRaw, maxLength: 16),
        ],
      );
      expect(r.rows.single.single, isNull);
    });

    test('RAW bind metadata: type 23, no LOB prefetch cont-flag', () {
      final req = ExecuteRequest(
        sql: 'INSERT INTO t (r) VALUES (:1)',
        isQuery: false,
        bindValues: [
          BindVariable(
            value: Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]),
            oraType: oraTypeRaw,
            dir: BindDir.input,
          ),
        ],
      );
      final bytes = req.toBytes();
      // Expected metadata block: oraType(23), flags(1), precision(0),
      // scale(0), UB4 maxSize=4 (value length), UB4 maxNumElements=0,
      // UB4 contFlag=0 (NOT TNS_LOB_PREFETCH_FLAG — that is CLOB/BLOB
      // only), UB4 OID=0, UB2 version=0, UB2 charset=0 (binary), csfrm=0,
      // UB4 lobPrefetchLen=0, UB4 oaccolid=0.
      final expectedMetadata = [
        oraTypeRaw, ttcBindUseIndicators, 0, 0,
        1, 4, // UB4 maxSize = 4 (value byte length)
        0, // UB4 max num elements
        0, // UB4 contFlag = 0 — no LOB prefetch flag for RAW
        0, // UB4 OID
        0, // UB2 version
        0, // UB2 charset = 0 (binary, no character set)
        0, // csfrm = 0
        0, // UB4 lob prefetch length
        0, // UB4 oaccolid
      ];
      expect(
        _indexOfSub(bytes, expectedMetadata),
        greaterThanOrEqualTo(0),
        reason: 'RAW bind metadata block not found in encoded request',
      );
    });

    test('RAW bind value encodes as length-prefixed bytes (no locator)', () {
      final req = ExecuteRequest(
        sql: 'INSERT INTO t (r) VALUES (:1)',
        isQuery: false,
        bindValues: [
          BindVariable(
            value: Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]),
            oraType: oraTypeRaw,
            dir: BindDir.input,
          ),
        ],
      );
      final bytes = req.toBytes();
      final expectedValue = [4, 0xDE, 0xAD, 0xBE, 0xEF];
      expect(
        _indexOfSub(bytes, expectedValue),
        greaterThanOrEqualTo(0),
        reason: 'length-prefixed RAW value bytes not found in request',
      );
    });

    test('RAW define block uses column maxLength, no LOB locator size', () {
      const rawCol = ColumnMetadata(
        name: 'R',
        oracleType: oraTypeRaw,
        maxLength: 16,
      );
      final req = ExecuteRequest(
        sql: 'SELECT r FROM t',
        isQuery: true,
        cursorId: 9,
        defineColumns: const [rawCol],
      );
      final bytes = req.toBytes();
      // RAW define: type 23, buffer size = declared byte width 16 (NOT the
      // 112-byte locator allocation), contFlag 0 (no LOB prefetch).
      final rawDefine = [
        oraTypeRaw, ttcBindUseIndicators, 0, 0,
        1, 16, // UB4 buffer size = ColumnMetadata.maxLength
        0, // max num elements
        0, // UB4 contFlag = 0 — BLOB locator metadata not applied to RAW
        0, // OID
        0, // version
        0, // UB2 charset = 0
        0, // csfrm = 0
        0, // prefetch length
        0, // oaccolid
      ];
      expect(
        _indexOfSub(bytes, rawDefine),
        greaterThanOrEqualTo(0),
        reason: 'RAW define block not found in encoded request',
      );
      // Negative assertion: a locator-style define for this column — same
      // metadata prefix but the 112-byte LOB locator allocation as the
      // buffer size — must be absent anywhere in the request.
      final locatorStyleDefine = [
        oraTypeRaw, ttcBindUseIndicators, 0, 0,
        1, 112, // UB4 buffer size = LOB locator allocation
      ];
      expect(
        _indexOfSub(bytes, locatorStyleDefine),
        equals(-1),
        reason:
            'RAW define must never use the 112-byte LOB locator '
            'buffer size',
      );
      // A regression could also retype the column to BLOB outright, so the
      // BLOB-typed locator define must be absent too.
      final blobLocatorDefine = [
        oraTypeBlob, ttcBindUseIndicators, 0, 0,
        1, 112, // UB4 buffer size = LOB locator allocation
      ];
      expect(
        _indexOfSub(bytes, blobLocatorDefine),
        equals(-1),
        reason: 'RAW column must never be defined as a BLOB locator',
      );
    });

    test('RAW OUT bind decodes through outBindValues as Uint8List', () {
      final raw = [0xCA, 0xFE, 0x00, 0xBA, 0xBE];
      final payload = _buildPayload([
        _ioVector([16]), // single OUT bind
        [
          ttcMsgTypeRowData,
          ..._bytesWithLength(raw),
          ..._ub4(0), // SB4 actualNumBytes trailer
        ],
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: false,
        bindMetadata: const [
          BindMetadata(oraType: oraTypeRaw, maxSize: 16, dir: BindDir.output),
        ],
      );
      expect(r.outBindValues.single, isA<Uint8List>());
      expect(r.outBindValues.single, equals(Uint8List.fromList(raw)));
    });

    test('RAW DESCRIBE_INFO maxLength comes from the wire maxSize field', () {
      // RAW is the one type whose declared width arrives in the maxSize
      // field rather than the size field (node-oracledb processColumnInfo).
      // Send different values in the two fields to prove the RAW branch
      // reads maxSize.
      final payload = _buildPayload([
        _describeInfo([
          _columnInfo(
            name: 'R',
            oraType: oraTypeRaw,
            maxSize: 16,
            sizeField: 99,
          ),
        ]),
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: true);
      final col = r.columnMetadata.single;
      expect(col.oracleType, equals(oraTypeRaw));
      expect(
        col.maxLength,
        equals(16),
        reason: 'RAW maxLength must come from maxSize, not size',
      );
    });
  });

  group('cursor (SYS_REFCURSOR) bind encode', () {
    test('cursor OUT bind metadata uses buffer size 4, no charset/prefetch', () {
      final req = ExecuteRequest(
        sql: 'BEGIN p(:1); END;',
        isQuery: false,
        isPlSql: true,
        bindValues: [
          BindVariable(
            value: null,
            oraType: oraTypeCursor,
            dir: BindDir.output,
          ),
        ],
      );
      final bytes = req.toBytes();
      // Reference parity (node-oracledb writeColumnMetadata, DB_TYPE_CURSOR):
      // bufferSizeFactor = 4, no charset form, no LOB/JSON prefetch cont-flag,
      // no lob prefetch length. Output direction is carried by the IO_VECTOR
      // round trip, not the metadata block.
      final expectedMetadata = [
        oraTypeCursor, ttcBindUseIndicators, 0, 0,
        ..._ub4(4), // UB4 maxSize = 4 (bufferSizeFactor)
        ..._ub4(0), // UB4 max num elements
        ..._ub4(0), // UB4 contFlag = 0 (NO LOB/JSON prefetch flag)
        ..._ub4(0), // UB4 OID
        ..._ub2(0), // UB2 version
        ..._ub2(0), // UB2 charset = 0 (no charset form)
        0, // csfrm = 0
        ..._ub4(0), // UB4 lob prefetch length = 0
        ..._ub4(0), // UB4 oaccolid (>= 12.2)
      ];
      expect(
        _indexOfSub(bytes, expectedMetadata),
        greaterThanOrEqualTo(0),
        reason: 'cursor bind metadata block not found in encoded request',
      );
    });

    test('cursor OUT bind value writes the ref-cursor placeholder [1, 0]', () {
      // node-oracledb writeBindParamsColumn (cursor branch, cursorId == 0):
      // writeUInt8(1) then writeUInt8(0). Crucially NOT a zero-length null
      // indicator — the cursor escapes the generic null/string/LOB/JSON paths.
      final req = ExecuteRequest(
        sql: 'BEGIN p(:1); END;',
        isQuery: false,
        isPlSql: true,
        bindValues: [
          BindVariable(
            value: null,
            oraType: oraTypeCursor,
            dir: BindDir.output,
          ),
        ],
      );
      final bytes = req.toBytes();
      // The single bind value follows the ROW_DATA marker: [marker, 1, 0].
      expect(
        _indexOfSub(bytes, [ttcMsgTypeRowData, 1, 0]),
        greaterThanOrEqualTo(0),
        reason: 'cursor OUT placeholder (1, 0) not found after ROW_DATA marker',
      );
      // A generic null OUT bind would write [marker, 0]; prove that did NOT
      // happen (the byte after the marker is 1, not 0).
      final markerIdx = _indexOfSub(bytes, [ttcMsgTypeRowData, 1, 0]);
      expect(
        bytes[markerIdx + 1],
        equals(1),
        reason: 'cursor must not be encoded as a zero-length null indicator',
      );
    });
  });

  group('cursor (SYS_REFCURSOR) OUT bind decode', () {
    test('valid cursor descriptor decodes into a DecodedCursorResult', () {
      final payload = _buildPayload([
        _ioVector([16]), // one OUT bind (direction OUT)
        [
          ttcMsgTypeRowData,
          ..._cursorOutBindValue([
            _columnInfo(name: 'ID', oraType: oraTypeNumber, maxSize: 0),
            _columnInfo(name: 'NAME', oraType: oraTypeVarchar, maxSize: 50),
          ], 42),
          ..._ub4(0), // SB4 actualNumBytes trailer
        ],
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: false,
        bindMetadata: const [
          BindMetadata(oraType: oraTypeCursor, dir: BindDir.output),
        ],
      );
      expect(r.outBindIndices, equals([0]));
      expect(r.outBindValues, hasLength(1));
      final decoded = r.outBindValues.single;
      expect(decoded, isA<DecodedCursorResult>());
      final cursor = decoded! as DecodedCursorResult;
      expect(cursor.cursorId, equals(42));
      expect(cursor.columns.map((c) => c.name), equals(['ID', 'NAME']));
      expect(cursor.columns[0].oracleType, equals(oraTypeNumber));
      expect(cursor.columns[1].oracleType, equals(oraTypeVarchar));
      expect(cursor.columns[1].maxLength, equals(50));
      // The cursor is NOT eager-materialized into rows.
      expect(r.rows, isEmpty);
    });

    test('cursor id 0 fails loud (invalid server cursor)', () {
      final payload = _buildPayload([
        _ioVector([16]),
        [
          ttcMsgTypeRowData,
          ..._cursorOutBindValue(
            [_columnInfo(name: 'ID', oraType: oraTypeNumber, maxSize: 0)],
            0, // invalid cursor id
          ),
          ..._ub4(0),
        ],
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(
        () => decodeExecuteResponse(
          payload,
          isQuery: false,
          bindMetadata: const [
            BindMetadata(oraType: oraTypeCursor, dir: BindDir.output),
          ],
        ),
        throwsA(
          isA<OracleException>().having(
            (e) => e.message,
            'message',
            contains('cursor id = 0'),
          ),
        ),
      );
    });

    test('a bad describe takes fail-loud priority over the id-0 check', () {
      // Fail-loud IDENTITY preserved: an unsupported embedded-describe column
      // throws its OWN validation error (the SAME error the inline strict
      // describe threw before the id was read), NOT the id-0 error, even when
      // the trailing id is 0. cursorId 0 is carried but harmless (filtered when
      // queued). Regression guard against re-introducing an id-0-wins ordering.
      // LONG (type 8) is the unsupported column here — nested CURSOR columns are
      // now supported and materialized, so they no longer drive this fail-loud.
      final payload = _buildPayload([
        _ioVector([16]),
        [
          ttcMsgTypeRowData,
          ..._cursorOutBindValue([
            _columnInfo(name: 'L', oraType: oraTypeLong, maxSize: 4000),
          ], 0), // unsupported column AND id 0
          ..._ub4(0),
        ],
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(
        () => decodeExecuteResponse(
          payload,
          isQuery: false,
          bindMetadata: const [
            BindMetadata(oraType: oraTypeCursor, dir: BindDir.output),
          ],
        ),
        throwsA(
          isA<EmbeddedCursorDecodeException>()
              .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
              .having((e) => e.message, 'message', contains('column type 8'))
              .having((e) => e.cursorId, 'cursorId', 0),
        ),
      );
    });

    test('zero-column cursor descriptor fails loud as malformed', () {
      final payload = _buildPayload([
        _ioVector([16]),
        [ttcMsgTypeRowData, ..._cursorOutBindValue(const [], 42), ..._ub4(0)],
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      // Fail-loud preserved AND the server cursor id is reaped (B1): the
      // describe is parsed leniently far enough to reach the trailing UB2 id,
      // so the thrown EmbeddedCursorDecodeException carries cursorId 42 for the
      // close-cursor piggyback. Proven-to-fail before the fix: the old decoder
      // threw a plain OracleException with no id (the leak this resolves).
      expect(
        () => decodeExecuteResponse(
          payload,
          isQuery: false,
          bindMetadata: const [
            BindMetadata(oraType: oraTypeCursor, dir: BindDir.output),
          ],
        ),
        throwsA(
          isA<EmbeddedCursorDecodeException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('zero columns'))
              .having((e) => e.cursorId, 'cursorId', 42),
        ),
      );
      expect(
        ttcStreamIsComplete(
          payload,
          bindMetadata: const [
            BindMetadata(oraType: oraTypeCursor, dir: BindDir.output),
          ],
        ),
        isTrue,
        reason: 'the completion probe consumes malformed descriptors leniently',
      );
    });

    test('unsupported embedded cursor column type fails during OUT decode', () {
      final payload = _buildPayload([
        _ioVector([16]),
        [
          ttcMsgTypeRowData,
          ..._cursorOutBindValue([
            _columnInfo(name: 'L', oraType: oraTypeLong, maxSize: 4000),
          ], 42),
          ..._ub4(0),
        ],
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      // Fail-loud preserved (oraUnsupportedType, "column type 8") AND the
      // cursor id (42) is carried for reaping — see the zero-column test.
      expect(
        () => decodeExecuteResponse(
          payload,
          isQuery: false,
          bindMetadata: const [
            BindMetadata(oraType: oraTypeCursor, dir: BindDir.output),
          ],
        ),
        throwsA(
          isA<EmbeddedCursorDecodeException>()
              .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
              .having((e) => e.message, 'message', contains('column type 8'))
              .having((e) => e.cursorId, 'cursorId', 42),
        ),
      );
      expect(
        ttcStreamIsComplete(
          payload,
          bindMetadata: const [
            BindMetadata(oraType: oraTypeCursor, dir: BindDir.output),
          ],
        ),
        isTrue,
        reason: 'unsupported metadata fails only in the strict decode pass',
      );
    });

    test(
      'a NULL cursor slot (length 0) decodes to null without a describe',
      () {
        final payload = _buildPayload([
          _ioVector([16]),
          [
            ttcMsgTypeRowData,
            0, // numBytes = 0 → SQL NULL / empty cursor slot
            ..._ub4(0), // SB4 actualNumBytes trailer
          ],
          _errorMessage(errorNum: 0),
          [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
        ]);
        final r = decodeExecuteResponse(
          payload,
          isQuery: false,
          bindMetadata: const [
            BindMetadata(oraType: oraTypeCursor, dir: BindDir.output),
          ],
        );
        expect(r.outBindValues, equals([null]));
      },
    );

    // Nested cursor columns inside embedded cursor describes are now SUPPORTED
    // (materialized) on both 23ai and 21c — the per-row value carries the inline
    // describe at the negotiated field version (node-oracledb parity; see
    // spec-nested-cursor-materialization.md "S0 RECONCILIATION"). The REF CURSOR
    // OUT bind decode therefore yields a DecodedCursorResult whose describe
    // includes the nested CURSOR(102) column; the rows (and each row's nested
    // cursor) are materialized lazily on FETCH, not in the execute response.
    test(
      'a nested cursor column inside a REF CURSOR OUT bind decodes to a '
      'DecodedCursorResult (no longer fails loud)',
      () {
        final payload = _buildPayload([
          _ioVector([16]),
          [
            ttcMsgTypeRowData,
            ..._cursorOutBindValue([
              _columnInfo(name: 'ID', oraType: oraTypeNumber, maxSize: 0),
              _columnInfo(name: 'NC', oraType: oraTypeCursor, maxSize: 0),
            ], 42),
            ..._ub4(0),
          ],
          _errorMessage(errorNum: 0),
          [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
        ]);
        final r = decodeExecuteResponse(
          payload,
          isQuery: false,
          bindMetadata: const [
            BindMetadata(oraType: oraTypeCursor, dir: BindDir.output),
          ],
        );
        final decoded = r.outBindValues.single;
        expect(decoded, isA<DecodedCursorResult>());
        final cursor = decoded! as DecodedCursorResult;
        expect(cursor.cursorId, equals(42));
        expect(cursor.columns.map((c) => c.name), equals(['ID', 'NC']));
        expect(cursor.columns[1].oracleType, equals(oraTypeCursor),
            reason: 'the nested CURSOR(102) column is kept in the describe');
        // Rows (and the nested cursor) are materialized lazily on FETCH, not
        // eagerly in the execute response.
        expect(r.rows, isEmpty);
      },
    );
  });

  // Implicit result sets (Story 9.3): a PL/SQL block that calls
  // DBMS_SQL.RETURN_RESULT ships a TTC message type 27 carrying a UB4 result
  // count and, per result, a skipped byte segment, an embedded cursor describe
  // (same shape as a REF CURSOR OUT bind, no version preamble), and a UB2
  // server cursor id. Each becomes a DecodedCursorResult on the response.
  group('implicit result set decode (DBMS_SQL.RETURN_RESULT, type 27)', () {
    test('a single implicit result decodes into one DecodedCursorResult', () {
      final payload = _buildPayload([
        _ioVector([16]), // a scalar OUT bind coexists with implicit results
        [
          ttcMsgTypeRowData,
          ..._bytesWithLength(_oracleNumberFiveBytes()), // OUT bind = 5
          ..._ub4(0), // SB4 actualNumBytes trailer
        ],
        _implicitResultSet([
          (
            columns: [
              _columnInfo(name: 'ID', oraType: oraTypeNumber, maxSize: 0),
              _columnInfo(name: 'NAME', oraType: oraTypeVarchar, maxSize: 40),
            ],
            cursorId: 101,
          ),
        ]),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: false,
        bindMetadata: const [
          BindMetadata(oraType: oraTypeNumber, dir: BindDir.output),
        ],
      );
      // Scalar OUT bind coexists with the implicit result (AC6).
      expect(r.outBindValues, equals([5]));
      expect(r.implicitResults, hasLength(1));
      final cursor = r.implicitResults.single;
      expect(cursor.cursorId, equals(101));
      expect(cursor.columns.map((c) => c.name), equals(['ID', 'NAME']));
      expect(cursor.columns[1].oracleType, equals(oraTypeVarchar));
      expect(cursor.columns[1].maxLength, equals(40));
      // Implicit cursors are NOT eager-decoded into rows by the decoder.
      expect(r.rows, isEmpty);
    });

    test('two implicit results decode in server-returned order', () {
      final payload = _buildPayload([
        _implicitResultSet([
          (
            columns: [
              _columnInfo(name: 'A', oraType: oraTypeNumber, maxSize: 0),
            ],
            cursorId: 201,
          ),
          (
            columns: [
              _columnInfo(name: 'B', oraType: oraTypeVarchar, maxSize: 10),
            ],
            cursorId: 202,
          ),
        ]),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: false);
      expect(r.implicitResults.map((c) => c.cursorId), equals([201, 202]));
      expect(r.implicitResults[0].columns.single.name, equals('A'));
      expect(r.implicitResults[1].columns.single.name, equals('B'));
    });

    test('skipped per-result byte segment is consumed (non-zero numBytes)', () {
      final payload = _buildPayload([
        _implicitResultSet([
          (
            columns: [
              _columnInfo(name: 'A', oraType: oraTypeNumber, maxSize: 0),
            ],
            cursorId: 301,
          ),
        ], skipBytes: 5),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: false);
      expect(r.implicitResults.single.cursorId, equals(301));
    });

    test('zero implicit results yields an empty list (canonical const)', () {
      final payload = _buildPayload([
        _implicitResultSet(const []),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: false);
      expect(r.implicitResults, isEmpty);
    });

    test('cursor id 0 fails loud, carrying prior cursor ids for cleanup', () {
      final payload = _buildPayload([
        _implicitResultSet([
          (
            columns: [
              _columnInfo(name: 'A', oraType: oraTypeNumber, maxSize: 0),
            ],
            cursorId: 401, // decoded successfully before the bad one
          ),
          (
            columns: [
              _columnInfo(name: 'B', oraType: oraTypeNumber, maxSize: 0),
            ],
            cursorId: 0, // invalid → fail loud
          ),
        ]),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      Object? thrown;
      try {
        decodeExecuteResponse(payload, isQuery: false);
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<ImplicitResultDecodeException>());
      final ex = thrown! as ImplicitResultDecodeException;
      expect(ex.errorCode, equals(oraProtocolError));
      expect(ex.message, contains('cursor id = 0'));
      expect(
        ex.cursorIds,
        equals([401]),
        reason: 'the cursor decoded before the bad descriptor is reapable',
      );
    });

    test('malformed descriptor (zero columns) fails loud, carries own id', () {
      final payload = _buildPayload([
        _implicitResultSet([(columns: const [], cursorId: 501)]),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      // Fail-loud preserved AND the failing descriptor's own cursor id (501) is
      // now carried for reaping (B2): the describe is parsed leniently so the
      // trailing UB2 id is reached before the error is raised. Proven-to-fail
      // before the fix: the old decoder threw before reading the id, so
      // cursorIds was empty (the leak this resolves).
      expect(
        () => decodeExecuteResponse(payload, isQuery: false),
        throwsA(
          isA<ImplicitResultDecodeException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('zero columns'))
              .having((e) => e.cursorIds, 'cursorIds', [501]),
        ),
      );
    });

    test(
      'unsupported embedded column type fails loud, carries own id',
      () {
        final payload = _buildPayload([
          _implicitResultSet([
            (
              columns: [
                _columnInfo(name: 'L', oraType: oraTypeLong, maxSize: 4000),
              ],
              cursorId: 601,
            ),
          ]),
          _errorMessage(errorNum: 0),
          [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
        ]);
        // Fail-loud preserved AND the failing descriptor's id (601) reaped.
        expect(
          () => decodeExecuteResponse(payload, isQuery: false),
          throwsA(
            isA<ImplicitResultDecodeException>()
                .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
                .having((e) => e.message, 'message', contains('column type 8'))
                .having((e) => e.cursorIds, 'cursorIds', [601]),
          ),
        );
      },
    );

    test(
      'a bad descriptor after a good one carries BOTH ids (prior + current)',
      () {
        // First result decodes cleanly (id 701); the second fails strict
        // validation (unsupported LONG column, id 702). Both ids must be queued
        // for close so neither leaks. Proven-to-fail before the fix: the old
        // decoder carried only the prior id [701] and dropped the current 702.
        // (LONG is the unsupported type — nested CURSOR columns are now
        // supported and materialized, so they no longer drive this fail-loud.)
        final payload = _buildPayload([
          _implicitResultSet([
            (
              columns: [
                _columnInfo(name: 'A', oraType: oraTypeNumber, maxSize: 0),
              ],
              cursorId: 701,
            ),
            (
              columns: [
                _columnInfo(name: 'L', oraType: oraTypeLong, maxSize: 4000),
              ],
              cursorId: 702,
            ),
          ]),
          _errorMessage(errorNum: 0),
          [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
        ]);
        expect(
          () => decodeExecuteResponse(payload, isQuery: false),
          throwsA(
            isA<ImplicitResultDecodeException>()
                .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
                .having(
                  (e) => e.message,
                  'message',
                  contains('column type 8'),
                )
                .having((e) => e.cursorIds, 'cursorIds', [701, 702]),
          ),
        );
      },
    );

    test('a bad describe takes fail-loud priority over the id-0 check; a 0 own '
        'id is omitted from the carried ids', () {
      // Fail-loud IDENTITY preserved: a malformed describe (here zero columns)
      // throws its OWN validation error — exactly what the inline strict
      // describe threw before the id was read — NOT the id-0 error, even when
      // the trailing id happens to be 0. The 0 own-id is nothing to reap, so
      // only the prior id (801) is carried.
      final payload = _buildPayload([
        _implicitResultSet([
          (
            columns: [
              _columnInfo(name: 'A', oraType: oraTypeNumber, maxSize: 0),
            ],
            cursorId: 801,
          ),
          (
            columns: const [], // zero columns AND id 0
            cursorId: 0,
          ),
        ]),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(
        () => decodeExecuteResponse(payload, isQuery: false),
        throwsA(
          isA<ImplicitResultDecodeException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('zero columns'))
              .having((e) => e.cursorIds, 'cursorIds', [801]),
        ),
      );
    });

    test('completion probe consumes the implicit-result message leniently', () {
      final payload = _buildPayload([
        _implicitResultSet([
          (
            columns: [
              _columnInfo(name: 'A', oraType: oraTypeNumber, maxSize: 0),
            ],
            cursorId: 0, // would fail the strict pass, but the probe skips it
          ),
        ]),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      expect(
        ttcStreamIsComplete(payload),
        isTrue,
        reason: 'the probe locates the terminal message despite a bad id',
      );
    });

    // A nested CURSOR(SELECT ...) column inside an implicit result is now
    // SUPPORTED: the describe accepts the CURSOR(102) column and accumulates the
    // descriptor; the per-row cursor value (carrying its own inline describe at
    // the negotiated field version on both 23ai and 21c — node-oracledb parity)
    // is materialized lazily/eagerly on FETCH by the connection layer, not in
    // this decode pass. See spec-nested-cursor-materialization.md.
    test('a nested cursor column inside an implicit result is accepted in the '
        'describe (materialized on FETCH)', () {
      final payload = _buildPayload([
        _implicitResultSet([
          (
            columns: [
              _columnInfo(name: 'ID', oraType: oraTypeNumber, maxSize: 0),
              _columnInfo(name: 'NC', oraType: oraTypeCursor, maxSize: 0),
            ],
            cursorId: 701,
          ),
        ]),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: false);
      expect(r.implicitResults, hasLength(1));
      final descriptor = r.implicitResults.single;
      expect(descriptor.cursorId, equals(701));
      expect(descriptor.columns.map((c) => c.name), equals(['ID', 'NC']));
      expect(descriptor.columns[1].oracleType, equals(oraTypeCursor),
          reason: 'the nested CURSOR(102) column is kept in the describe');
      expect(cursorColumnIndicesOf(descriptor.columns), equals([1]),
          reason: 'the cursor column is flagged for FETCH-time materialization');
    });
  });

  // Cursor-VALUED SELECT columns (Story 9.2 nested cursors): a
  // `SELECT ..., CURSOR(SELECT ...) AS nc FROM ...` query ships the cursor
  // column with oraTypeNum 102 in DESCRIBE_INFO and the same embedded-cursor
  // byte shape as a REF CURSOR OUT bind in each ROW_DATA. Unlike the OUT bind
  // path, a cursor id 0 on a column is a NULL value, not a programming error.
  group('cursor (SYS_REFCURSOR) SELECT column decode (nested cursors)', () {
    test('cursorColumnIndicesOf reports cursor column positions', () {
      const columns = [
        ColumnMetadata(name: 'ID', oracleType: oraTypeNumber, maxLength: 0),
        ColumnMetadata(name: 'NC', oracleType: oraTypeCursor, maxLength: 0),
        ColumnMetadata(name: 'NAME', oracleType: oraTypeVarchar, maxLength: 50),
        ColumnMetadata(name: 'NC2', oracleType: oraTypeCursor, maxLength: 0),
      ];
      expect(cursorColumnIndicesOf(columns), equals([1, 3]));
    });

    test('cursorColumnIndicesOf is empty when no cursor columns exist', () {
      const columns = [
        ColumnMetadata(name: 'ID', oracleType: oraTypeNumber, maxLength: 0),
        ColumnMetadata(name: 'NAME', oracleType: oraTypeVarchar, maxLength: 50),
      ];
      expect(cursorColumnIndicesOf(columns), isEmpty);
    });

    test('describe with a cursor column produces a DecodedCursorResult row '
        'value (column path, id 0 allowed)', () {
      final payload = _buildPayload([
        _describeInfo([
          _columnInfo(name: 'ID', oraType: oraTypeNumber, maxSize: 0),
          _columnInfo(name: 'NC', oraType: oraTypeCursor, maxSize: 0),
        ]),
        _rowHeader(),
        [
          ttcMsgTypeRowData,
          ..._bytesWithLength(_oracleNumberFiveBytes()), // ID = 5
          // Cursor column value: same wire shape as the OUT-bind value but
          // WITHOUT the SB4 trailer (that trailer is OUT-bind only).
          ..._cursorOutBindValue([
            _columnInfo(name: 'X', oraType: oraTypeNumber, maxSize: 0),
          ], 77),
        ],
        _errorMessage(errorNum: 1403), // end of fetch
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: true);
      expect(r.columnMetadata[1].oracleType, equals(oraTypeCursor));
      expect(r.columnMetadata[1].name, equals('NC'));
      expect(
        r.columnMetadata[1].maxLength,
        equals(4),
        reason:
            'a cursor column reports the wire buffer size 4 '
            '(node-oracledb bufferSizeFactor), not the server-sent size 0',
      );
      expect(
        cursorColumnIndicesOf(r.columnMetadata),
        equals([1]),
        reason: 'the describe pass must flag column 1 as a cursor column',
      );
      expect(r.rows, hasLength(1));
      final row = r.rows.single;
      expect(row[0], equals(5));
      expect(row[1], isA<DecodedCursorResult>());
      final cursor = row[1]! as DecodedCursorResult;
      expect(cursor.cursorId, equals(77));
      expect(cursor.columns.single.name, equals('X'));
    });

    test('cursor column with server cursor id 0 decodes to null (NOT a '
        'programming error like the OUT-bind path)', () {
      final payload = _buildPayload([
        _describeInfo([
          _columnInfo(name: 'NC', oraType: oraTypeCursor, maxSize: 0),
        ]),
        _rowHeader(),
        [
          ttcMsgTypeRowData,
          // Full describe present, but cursor id 0 → NULL nested cursor.
          ..._cursorOutBindValue([
            _columnInfo(name: 'X', oraType: oraTypeNumber, maxSize: 0),
          ], 0),
        ],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: true);
      expect(
        r.rows.single,
        equals([null]),
        reason: 'a column cursor id 0 is a null value, not an exception',
      );
    });

    test(
      'NULL cursor column (numBytes 0) decodes to null with no describe',
      () {
        final payload = _buildPayload([
          _describeInfo([
            _columnInfo(name: 'ID', oraType: oraTypeNumber, maxSize: 0),
            _columnInfo(name: 'NC', oraType: oraTypeCursor, maxSize: 0),
          ]),
          _rowHeader(),
          [
            ttcMsgTypeRowData,
            ..._bytesWithLength(_oracleNumberFiveBytes()), // ID = 5
            0, // cursor column numBytes = 0 → SQL NULL, no describe follows
          ],
          _errorMessage(errorNum: 1403),
          [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
        ]);
        final r = decodeExecuteResponse(payload, isQuery: true);
        expect(r.rows.single, equals([5, null]));
      },
    );

    test('cursor column embedded describe is parsed at the negotiated TTC '
        'field version, not the default 24 (pre-23 / Oracle 21c regression)', () {
      // ttcFieldVersion 14 (20.1) is >= 12.2 (oaccolid present) but < 23.1
      // (no domain), < 23.1-ext3 (no annotations), and < 23.4 (no vector
      // tail). Decoding the embedded cursor describe at the default 24 would
      // read those absent fields and shear the row stream — the exact ORA-12547
      // "malformed TTC stream" failure this driver hit on Oracle 21c before the
      // column decode path threaded the negotiated version through.
      const v = ttcCcapFieldVersion20_1; // 14
      final payload = _buildPayload([
        _describeInfo([
          _columnInfo(
            name: 'ID',
            oraType: oraTypeNumber,
            maxSize: 0,
            ttcFieldVersion: v,
          ),
          _columnInfo(
            name: 'NC',
            oraType: oraTypeCursor,
            maxSize: 0,
            ttcFieldVersion: v,
          ),
        ]),
        _rowHeader(),
        [
          ttcMsgTypeRowData,
          ..._bytesWithLength(_oracleNumberFiveBytes()), // ID = 5
          ..._cursorOutBindValue([
            _columnInfo(
              name: 'X',
              oraType: oraTypeNumber,
              maxSize: 0,
              ttcFieldVersion: v,
            ),
          ], 88),
        ],
        _errorMessage(errorNum: 1403, ttcFieldVersion: v),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(
        payload,
        isQuery: true,
        ttcFieldVersion: v,
      );
      expect(r.rows, hasLength(1));
      final cursor = r.rows.single[1]! as DecodedCursorResult;
      expect(cursor.cursorId, equals(88));
      expect(cursor.columns.single.name, equals('X'));
    });

    test('scalar-only SELECT rows are unaffected (no cursor columns)', () {
      final payload = _buildPayload([
        _describeInfo([
          _columnInfo(name: 'ID', oraType: oraTypeNumber, maxSize: 0),
          _columnInfo(name: 'NAME', oraType: oraTypeVarchar, maxSize: 50),
        ]),
        _rowHeader(),
        [
          ttcMsgTypeRowData,
          ..._bytesWithLength(_oracleNumberFiveBytes()),
          ..._bytesWithLength('hi'.codeUnits),
        ],
        _errorMessage(errorNum: 1403),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: true);
      expect(cursorColumnIndicesOf(r.columnMetadata), isEmpty);
      expect(r.rows.single, equals([5, 'hi']));
    });
  });

  // Define-mode ExecuteRequest (the DEFINE call sent for open CLOB query
  // cursors, mirroring node-oracledb `_handleDefines`).
  group('define-mode ExecuteRequest', () {
    const clobCol = ColumnMetadata(
      name: 'DOC',
      oracleType: oraTypeClob,
      maxLength: 4000,
      csfrm: 1,
    );
    const numberCol = ColumnMetadata(
      name: 'ID',
      oracleType: oraTypeNumber,
      maxLength: 0,
    );

    test('sets DEFINE and clears EXECUTE/FETCH/PARSE', () {
      final req = ExecuteRequest(
        sql: 'SELECT id, doc FROM t',
        isQuery: true,
        cursorId: 9,
        defineColumns: [numberCol, clobCol],
      );
      final options = _readOptionsFromHeader(req.toBytes());
      expect(options & ttcExecOptionDefine, isNonZero);
      expect(
        options & ttcExecOptionExecute,
        equals(0),
        reason: 'DEFINE replaces EXECUTE',
      );
      expect(
        options & ttcExecOptionFetch,
        equals(0),
        reason: 'rows come from later FETCH RPCs',
      );
      expect(
        options & ttcExecOptionParse,
        equals(0),
        reason: 'the cursor is already open',
      );
      expect(options & ttcExecOptionNotPlSql, isNonZero);
    });

    test('writes one define block per column with the CLOB prefetch flag', () {
      final req = ExecuteRequest(
        sql: 'SELECT id, doc FROM t',
        isQuery: true,
        cursorId: 9,
        defineColumns: [numberCol, clobCol],
      );
      final bytes = req.toBytes();
      // NUMBER define: type 2, flags 1, prec/scale 0, UB4 size=22, UB4 0,
      // UB4 contFlag=0, OID 0, version 0, charset 0, csfrm 0, prefetch 0,
      // oaccolid 0.
      final numberDefine = [
        oraTypeNumber,
        ttcBindUseIndicators,
        0,
        0,
        1,
        22,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ];
      // CLOB define: type 112, locator buffer size 112, LOB prefetch
      // cont-flag, charset 873, csfrm 1.
      final clobDefine = [
        oraTypeClob, ttcBindUseIndicators, 0, 0,
        1, 112, // UB4 buffer size (locator allocation)
        0, // max num elements
        4, 0x02, 0x00, 0x00, 0x00, // UB4 contFlag = TNS_LOB_PREFETCH_FLAG
        0, // OID
        0, // version
        2, 0x03, 0x69, // UB2 charset = 873
        1, // csfrm implicit
        0, // prefetch length
        0, // oaccolid
      ];
      final numberIdx = _indexOfSub(bytes, numberDefine);
      final clobIdx = _indexOfSub(bytes, clobDefine);
      expect(numberIdx, greaterThanOrEqualTo(0));
      expect(
        clobIdx,
        greaterThan(numberIdx),
        reason: 'defines are written in column order',
      );
    });

    test('cursor-typed column define uses buffer size 4 (Story 9.2)', () {
      const cursorCol = ColumnMetadata(
        name: 'NC',
        oracleType: oraTypeCursor,
        maxLength: 0,
      );
      final req = ExecuteRequest(
        sql: 'SELECT id, CURSOR(SELECT 1 FROM dual) FROM t',
        isQuery: true,
        cursorId: 9,
        defineColumns: [cursorCol],
      );
      final bytes = req.toBytes();
      // node-oracledb DB_TYPE_CURSOR.bufferSizeFactor = 4. The cursor column
      // reports maxLength 0, so the pre-fix `default` branch would have written
      // a buffer size of 1; the byte after the 4-byte define header must be the
      // UB4 encoding of 4 ([1, 4]), not of 1 ([1, 1]).
      final cursorDefine = [
        oraTypeCursor, ttcBindUseIndicators, 0, 0,
        1, 4, // UB4 buffer size = 4 (bufferSizeFactor), NOT the default 1
        0, // max num elements
        0, // contFlag = 0 (no LOB/JSON prefetch flag)
        0, // OID
        0, // version
        0, // UB2 charset = 0 (csfrm 0)
        0, // csfrm
        0, // prefetch length
        0, // oaccolid
      ];
      expect(
        _indexOfSub(bytes, cursorDefine),
        greaterThanOrEqualTo(0),
        reason: 'cursor define block with buffer size 4 not found',
      );
    });
  });

  // RETURN_PARAMETER body parsing. Live wire captures (2026-06-11) against
  // both Oracle 23ai and 21c — DDL, DML, and PL/SQL with a CLOB OUT bind —
  // show the key/value-pairs and registration sections are ALWAYS on the
  // wire (zero-length encoded as single 0x00 UB2 size bytes), so the decoder
  // reads both unconditionally (node-oracledb processReturnParameter parity).
  group('RETURN_PARAMETER section parsing', () {
    // PARAMETER body with empty kv/registration sections — the exact shape
    // every live capture showed on both servers.
    List<int> parameterBody() => [
      ttcMsgTypeParameter,
      ..._ub2(2), // numParams
      ..._ub4(0x123456), // param 1
      ..._ub4(0), // param 2
      ..._ub2(0), // transaction length
      ..._ub2(0), // numKv = 0
      ..._ub2(0), // registration length = 0
    ];

    test('PARAMETER with empty sections directly followed by ERROR '
        '(shape shared by DDL and 21c PL/SQL CLOB OUT responses)', () {
      final payload = _buildPayload([
        parameterBody(),
        _errorMessage(errorNum: 0, rowCount: 1),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      final r = decodeExecuteResponse(payload, isQuery: false);
      expect(r.isSuccess, isTrue);
      expect(
        r.rowsAffected,
        equals(1),
        reason:
            'decode must consume both empty sections and reach the '
            'terminal ERROR/STATUS messages',
      );
    });

    test(
      'PARAMETER with kv pairs and a registration blob drains correctly',
      () {
        final key = 'SESSION_SCHEMA'.codeUnits;
        final value = 'APP_USER'.codeUnits;
        final registration = List<int>.filled(5, 0xAB);
        final paramMsg = <int>[
          ttcMsgTypeParameter,
          ..._ub2(2), // numParams
          ..._ub4(0x123456), // param 1
          ..._ub4(0), // param 2
          ..._ub2(0), // transaction length
          ..._ub2(2), // numKv = 2
          // kv pair 1: key + value + keyword num
          ..._ub2(key.length),
          ..._bytesWithLength(key),
          ..._ub2(value.length),
          ..._bytesWithLength(value),
          ..._ub2(168), // keyword num (skipped, not consumed semantically)
          // kv pair 2: zero-length key and value (no payload bytes follow)
          ..._ub2(0), // key length = 0
          ..._ub2(0), // value length = 0
          ..._ub2(0), // keyword num
          ..._ub2(registration.length), // registration length
          ...registration,
        ];
        final payload = _buildPayload([
          paramMsg,
          _errorMessage(errorNum: 0, rowCount: 4),
          [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
        ]);
        final r = decodeExecuteResponse(payload, isQuery: false);
        expect(r.isSuccess, isTrue);
        expect(
          r.rowsAffected,
          equals(4),
          reason:
              'decode must drain the kv triples and registration blob '
              'and reach the terminal ERROR/STATUS messages',
        );
        // Exhaustive truncation sweep: every cut inside the PARAMETER body
        // (mid-key, mid-value, mid-keyword, mid-registration) must make the
        // probe report incomplete ("need more packets") instead of throwing,
        // now that the kv/registration reads are unconditional.
        for (var cut = 1; cut <= paramMsg.length; cut++) {
          expect(
            ttcStreamIsComplete(Uint8List.sublistView(payload, 0, cut)),
            isFalse,
            reason: 'probe must report incomplete at cut=$cut',
          );
        }
      },
    );

    test('completion probe consumes CLOB OUT binds byte-accurately', () {
      // The pre-23.4 completion probe walks OUT binds with bindMetadata:
      // a CLOB OUT bind ships the locator shape, which the metadata-less
      // fallback (bytes-with-length) would misparse.
      final locator = List<int>.filled(40, 0x55);
      final prefix = <int>[
        ..._ioVector([16]),
        ttcMsgTypeRowData,
        ..._ub4(40), // locator length
        ..._ub8(11), // LOB length in chars
        ..._ub4(8132), // chunk size
        ..._bytesWithLength(locator),
        ..._ub4(0), // SB4 trailer
      ];
      final payload = _buildPayload([
        prefix,
        parameterBody(),
        _errorMessage(errorNum: 0),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);
      const bindMetadata = [
        BindMetadata(oraType: oraTypeClob, maxSize: 100, dir: BindDir.output),
      ];
      expect(ttcStreamIsComplete(payload, bindMetadata: bindMetadata), isTrue);
      // Truncate INSIDE the PARAMETER body, in the section area: drop its
      // final byte (the 0x00 UB2 size of the registration section). The
      // resulting BufferException must make the probe report incomplete
      // ("need more packets") instead of throwing.
      final cutAt = prefix.length + parameterBody().length - 1;
      // Pin the cut location so the test fails loudly if a helper encoding
      // ever changes width: the dropped byte is the registration UB2 size
      // (0x00) and the byte after it starts the terminal ERROR message.
      expect(
        payload[cutAt],
        equals(0),
        reason: 'cut must drop the registration-section UB2 size byte',
      );
      expect(
        payload[cutAt + 1],
        equals(ttcMsgTypeError),
        reason: 'the byte after the cut must start the ERROR message',
      );
      expect(
        ttcStreamIsComplete(
          Uint8List.sublistView(payload, 0, cutAt),
          bindMetadata: bindMetadata,
        ),
        isFalse,
      );
    });

    // Probe underflow/malformation distinction: a face-value malformed
    // integer encoding can never be repaired by more packets, so the probe
    // must throw OracleException(oraProtocolError) instead of reporting
    // "need more packets" (which would spin the receive loop into the
    // cap/timeout backstop). Genuine truncation keeps returning false —
    // pinned by the exhaustive sweep above.
    group('completion probe malformation escalation', () {
      // PARAMETER body whose numKv UB2 position carries [malformedNumKv]
      // followed by enough bytes that the failure cannot be an underflow.
      Uint8List malformedAtNumKv(List<int> malformedNumKv) => _buildPayload([
        [
          ttcMsgTypeParameter,
          ..._ub2(2), // numParams
          ..._ub4(0x123456), // param 1
          ..._ub4(0), // param 2
          ..._ub2(0), // transaction length
          ...malformedNumKv, // numKv UB2 position — malformed encoding
          0xAA, 0xBB, 0xCC, 0xDD, // bytes present: NOT an underflow
        ],
        _errorMessage(errorNum: 0, rowCount: 1),
        [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
      ]);

      final protocolError = isA<OracleException>().having(
        (e) => e.errorCode,
        'errorCode',
        oraProtocolError,
      );

      test('"integer too large" (UB2 size byte 4 > maxSize 2) throws', () {
        final payload = malformedAtNumKv([0x04]);
        // The cause-message pin proves the escalation fired at the intended
        // malformation, not some other (possibly underflow-adjacent) point.
        expect(
          () => ttcStreamIsComplete(payload),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraProtocolError)
                .having(
                  (e) => e.cause.toString(),
                  'cause',
                  contains('Integer too large'),
                ),
          ),
        );
      });

      test('sign-bit size byte (0x80) at an unsigned position throws', () {
        final payload = malformedAtNumKv([0x80]);
        expect(
          () => ttcStreamIsComplete(payload),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraProtocolError)
                .having(
                  (e) => e.cause.toString(),
                  'cause',
                  contains('negative integer'),
                ),
          ),
        );
      });

      test('probe never throws on decodable-shape values the strict decoder '
          'rejects (region-id TSTZ, BCE DATE)', () {
        // Regression (code review of this change): the probe used to run the
        // strict value decoders on DATE/TIMESTAMP slices, so a region-id
        // TIMESTAMP WITH TIME ZONE or a BCE DATE — both legitimate wire
        // data — escaped the probe as OracleException and poisoned the
        // transport through the probe-throw path. The probe must stop at
        // byte consumption; only the strict pass may reject the values.
        final payload = _buildPayload([
          _rowHeader(),
          [
            ttcMsgTypeRowData,
            // 13-byte TSTZ slice with the region-id flag (byte 11 bit 0x80).
            ..._bytesWithLength(const [
              120,
              121,
              6,
              12,
              11,
              31,
              31,
              0,
              0,
              0,
              0,
              0x80,
              0x01,
            ]),
            // 7-byte BCE DATE slice (century byte 99 < 100).
            ..._bytesWithLength(const [99, 150, 6, 12, 1, 1, 1]),
          ],
          _errorMessage(errorNum: 1403),
          [ttcMsgTypeStatus, ..._ub4(0), ..._ub2(0)],
        ]);
        const cols = [
          ColumnMetadata(
            name: 'TS',
            oracleType: oraTypeTimestampTz,
            maxLength: 13,
          ),
          ColumnMetadata(name: 'D', oracleType: oraTypeDate, maxLength: 7),
        ];
        expect(
          ttcStreamIsComplete(payload, expectedColumns: cols),
          isTrue,
          reason:
              'the probe must consume the slices and locate the '
              'terminal messages without value-decoding them',
        );
        // The strict pass still rejects the values loudly — a per-query
        // error, with no transport poisoning involved.
        expect(
          () => decodeExecuteResponse(
            payload,
            isQuery: true,
            expectedColumns: cols,
          ),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              oraUnsupportedType,
            ),
          ),
        );
      });

      test('the probe error carries the BufferException as cause', () {
        final payload = malformedAtNumKv([0x04]);
        expect(
          () => ttcStreamIsComplete(payload),
          throwsA(
            isA<OracleException>()
                .having((e) => e.cause, 'cause', isA<BufferException>())
                .having(
                  (e) => e.message,
                  'message',
                  contains('Malformed TTC stream'),
                ),
          ),
        );
      });

      test('real decoder wrap on the same malformed payloads is unchanged', () {
        // decodeExecuteResponse catches the parent BufferException and wraps
        // it as oraProtocolError — the subtype split must not change that.
        expect(
          () => decodeExecuteResponse(malformedAtNumKv([0x04]), isQuery: false),
          throwsA(protocolError),
        );
        expect(
          () => decodeExecuteResponse(malformedAtNumKv([0x80]), isQuery: false),
          throwsA(protocolError),
        );
      });
    });
  });

  group('processServerSidePiggybackBody', () {
    // Opcodes and wire shapes mirror node-oracledb processServerSidePiggyBack
    // (thin/protocol/messages/base.js). Every fixture ends with a 0xEE
    // sentinel: reading it back after the call proves the decoder consumed
    // exactly the piggyback body — no more, no less.
    const sentinel = 0xEE;

    void expectFullyConsumed(List<int> body) {
      final buf = ReadBuffer(Uint8List.fromList([...body, sentinel]));
      processServerSidePiggybackBody(buf);
      expect(buf.readUint8(), equals(sentinel));
    }

    test('QUERY_CACHE_INVALIDATION (1) and TRACE_EVENT (3) carry no body', () {
      expectFullyConsumed([0x01]);
      expectFullyConsumed([0x03]);
    });

    test('OS_PID_MTS (2) skips its DTY bytes', () {
      expectFullyConsumed([
        0x02,
        ..._ub2(4), // number of DTY bytes
        0x00, // length of DTYs (raw UB1)
        0x10, 0x20, 0x30, 0x40, // DTY bytes
      ]);
    });

    test('SESS_RET (4) drains key/value elements and session ids', () {
      expectFullyConsumed([
        0x04,
        ..._ub2(0), // number of DTYs
        0x00, // length of DTYs (raw UB1)
        ..._ub2(1), // one key/value element
        0x00, // length (raw UB1)
        ..._ub2(1), 1, 0x6B, // key: UB2 length, then length-prefixed bytes
        ..._ub2(1), 1, 0x76, // value
        ..._ub2(0), // flags
        ..._ub4(0), // session flags
        ..._ub4(0), // session id
        ..._ub2(0), // serial number
      ]);
    });

    test('SYNC (5) — sent after ALTER SESSION — drains its key/value '
        'elements and flags', () {
      expectFullyConsumed([
        0x05,
        ..._ub2(0), // number of DTYs
        0x00, // length of DTYs (raw UB1)
        ..._ub4(2), // two key/value elements
        0x00, // length (raw UB1)
        // element 1: key 'a', value 0xAB, keyword 168 (CURRENT_SCHEMA)
        ..._ub2(1), 1, 0x61,
        ..._ub2(1), 1, 0xAB,
        ..._ub2(168),
        // element 2: empty key, empty value, keyword 0
        ..._ub2(0), ..._ub2(0), ..._ub2(0),
        ..._ub4(0), // overall flags
      ]);
    });

    test('SESS_RET (4) and SYNC (5) handle the zero-element boundary with '
        'their distinct length-byte placement', () {
      // The two messages are deliberately asymmetric (mirrors node-oracledb):
      // SESS_RET reads its post-count length UB1 only inside `num_elements > 0`,
      // while SYNC reads it unconditionally. Pin both so a future edit that
      // collapses them into one shape desyncs a test rather than the wire.
      expectFullyConsumed([
        0x04,
        ..._ub2(0), // number of DTYs
        0x00, // length of DTYs (raw UB1)
        ..._ub2(0), // zero elements: the length UB1 below is NOT present
        ..._ub4(0), // session flags
        ..._ub4(0), // session id
        ..._ub2(0), // serial number
      ]);
      expectFullyConsumed([
        0x05,
        ..._ub2(0), // number of DTYs
        0x00, // length of DTYs (raw UB1)
        ..._ub4(0), // zero elements
        0x00, // length (raw UB1) — read unconditionally, unlike SESS_RET
        ..._ub4(0), // overall flags
      ]);
    });

    test('LTXID (7) drains its logical transaction id', () {
      expectFullyConsumed([
        0x07,
        ..._ub4(3), // ltxid byte count
        3, 0x01, 0x02, 0x03, // length-prefixed ltxid bytes
      ]);
      expectFullyConsumed([0x07, ..._ub4(0)]); // empty ltxid: no bytes follow
    });

    test('AC_REPLAY_CONTEXT (8) drains flags, error code, queue, and '
        'context', () {
      expectFullyConsumed([
        0x08,
        ..._ub2(0), // number of DTYs
        0x00, // length of DTYs (raw UB1)
        ..._ub4(0), // flags
        ..._ub4(0), // error code
        0x00, // queue (raw UB1)
        ..._ub4(2), // replay context byte count
        2, 0xCA, 0xFE, // length-prefixed context bytes
      ]);
    });

    test('EXT_SYNC (9) and SESS_SIGNATURE (10) drain their fixed fields', () {
      expectFullyConsumed([0x09, ..._ub2(0), 0x00]);
      expectFullyConsumed([
        0x0A,
        ..._ub2(0), // number of DTYs
        0x00, // length of DTY (raw UB1)
        0, // signature flags (UB8, zero-length encoding)
        0, // client signature
        0, // server signature
      ]);
    });

    test('an unassigned opcode fails loudly with a protocol error', () {
      final buf = ReadBuffer(Uint8List.fromList([0x06]));
      expect(
        () => processServerSidePiggybackBody(buf),
        throwsA(
          isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            oraProtocolError,
          ),
        ),
      );
    });
  });
}

/// Returns the first index of [needle] within [haystack], or -1.
int _indexOfSub(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
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
/// the direction bytes. Both default to empty (UB2 length 0).
List<int> _ioVector(
  List<int> directions, {
  List<int> fastFetch = const [],
  List<int> rowid = const [],
}) {
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

/// Builds the embedded cursor-describe block carried inside a REF CURSOR OUT
/// bind value. Identical to a DESCRIBE_INFO body but WITHOUT the leading
/// version-bytes preamble — node-oracledb's `createCursorFromDescribe` calls
/// `processDescribeInfo` directly, skipping the preamble the message dispatcher
/// would otherwise consume.
List<int> _embeddedCursorDescribe(List<List<int>> columns) {
  final out = <int>[];
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

/// Builds a REF CURSOR OUT bind value: a non-null length byte, the embedded
/// cursor describe block, then the UB2 server cursor id (matches node-oracledb
/// processColumnData TNS_DATA_TYPE_CURSOR branch).
List<int> _cursorOutBindValue(List<List<int>> columns, int cursorId) {
  return [
    1, // numBytes length byte (non-null, non-0xFF)
    ..._embeddedCursorDescribe(columns),
    ..._ub2(cursorId), // UB2 cursor id
  ];
}

/// Builds a TTC implicit result-set message (type 27, `DBMS_SQL.RETURN_RESULT`):
/// a UB4 result count, then for each result a UInt8 skip-length plus that many
/// skip bytes, the embedded cursor describe block, and the UB2 server cursor id
/// (matches node-oracledb `processImplicitResultSet`).
List<int> _implicitResultSet(
  List<({List<List<int>> columns, int cursorId})> results, {
  int skipBytes = 0,
}) {
  final out = <int>[ttcMsgTypeImplicitResultSet, ..._ub4(results.length)];
  for (final result in results) {
    out.add(skipBytes); // UInt8 numBytes
    out.addAll(List<int>.filled(skipBytes, 0));
    out.addAll(_embeddedCursorDescribe(result.columns));
    out.addAll(_ub2(result.cursorId));
  }
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
  int csfrm = 0,
  int? sizeField,
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
    csfrm, // csfrm
    // The separate `size` field — defaults to maxSize; override via
    // [sizeField] to prove a decoder branch reads one field and not the
    // other (RAW reads maxSize, every other byte-sized type reads size).
    ..._ub4(sizeField ?? maxSize), // size
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

/// Fixed-width 8-byte big-endian field (NOT Oracle's variable-length UB8).
/// Mirrors the QLocator OSON payload-length field, which production writes as
/// two `writeUint32BE` words (high word always 0) — see
/// `_writeOsonValue` in execute_message.dart.
List<int> _u64be(int v) => [
  0, 0, 0, 0, // high word
  (v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff, // low word
];

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

/// Emits a real variable-length UB8 mirroring `WriteBuffer.writeUB8`:
/// size byte 0/1/2/4/8 followed by that many big-endian payload bytes,
/// including the 8-byte form for values above 2³².
/// Deliberately decoupled from [_ub4], which caps at the 4-byte form.
List<int> _ub8(int v) {
  if (v == 0) return [0];
  if (v <= 0xff) return [1, v];
  if (v <= 0xffff) return [2, (v >> 8) & 0xff, v & 0xff];
  if (v <= 0xffffffff) {
    return [4, (v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
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
  // older server would send.
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
