import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/lob_locator.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/protocol/messages/lob_op_message.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

/// In-process [Transport] stand-in that drives [OracleLob] and the
/// `fetchLobs` acquisition path deterministically without a live server.
///
/// `sendExecute` returns canned responses (used to hand a query row containing a
/// [LobLocator] to `execute(fetchLobs: true)`), and `sendLobOp` returns canned
/// READ data / records WRITE arguments so a handle's read/write can be exercised
/// without wire traffic.
class _FakeLobTransport extends Transport {
  final List<ExecuteResponse> nextResponses = <ExecuteResponse>[];

  /// Bytes returned by a `tnsLobOpRead` (already in the wire charset the test
  /// expects the handle to decode). Null yields a `null` data response.
  Uint8List? lobReadData;

  /// When true, every `sendLobOp` throws — simulating a server-side LOB error
  /// (e.g. writing through a read-only locator).
  bool failLobOp = false;

  /// When set, the FIRST `sendLobOp` suspends on this gate before returning,
  /// letting a test hold a read/write in flight to prove overlap rejection.
  Completer<void>? lobOpGate;

  /// When set, every `sendLobOp` echoes this as the response's `updatedLocator`
  /// (the server's post-op locator state), so a copy-back test can assert the
  /// handle's live locator buffer tracks it.
  Uint8List? lobUpdatedLocator;

  int lobReadCalls = 0;
  int lobWriteCalls = 0;
  int lastReadOffset = -1;
  int lastReadAmount = -1;
  int lastWriteOffset = -1;
  Uint8List? lastWriteData;

  /// Snapshot (copy) of the `sourceLocator` bytes passed to each op, in order.
  final List<Uint8List> sentLocators = <Uint8List>[];

  @override
  bool get isConnected => true;

  @override
  bool get isCorrupted => false;

  @override
  Future<void> disconnect() async {}

  @override
  Future<ExecuteResponse> sendExecute(
    String sql, {
    required bool isQuery,
    bool isPlSql = false,
    List<Object?>? bindValues,
    List<String>? bindNames,
    List<BindMetadata>? bindMetadata,
    int prefetchRows = 50,
    Duration? timeout = const Duration(minutes: 2),
    int cursorId = 0,
    List<ColumnMetadata>? expectedColumns,
    List<int> cursorsToClose = const <int>[],
    bool preserveTimestampTimeZone = false,
    List<List<Object?>>? bulkRows,
    int? executeManyIters,
    bool batchErrors = false,
    bool dmlRowCounts = false,
    bool dmlReturning = false,
  }) async {
    if (nextResponses.isNotEmpty) return nextResponses.removeAt(0);
    return ExecuteResponse(isSuccess: true);
  }

  @override
  Future<LobOpResponse> sendLobOp({
    required int operation,
    Uint8List? sourceLocator,
    int sourceOffset = 0,
    int destOffset = 0,
    int destLength = 0,
    bool sendAmount = false,
    int amount = 0,
    Uint8List? data,
    Duration? timeout = const Duration(minutes: 2),
  }) async {
    final gate = lobOpGate;
    if (gate != null) {
      lobOpGate = null; // only the first op parks
      await gate.future;
    }
    if (failLobOp) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message: 'simulated LOB operation failure',
      );
    }
    if (sourceLocator != null) {
      sentLocators.add(Uint8List.fromList(sourceLocator));
    }
    if (operation == tnsLobOpRead) {
      lobReadCalls++;
      lastReadOffset = sourceOffset;
      lastReadAmount = amount;
      return LobOpResponse(
        isSuccess: true,
        data: lobReadData,
        updatedLocator: lobUpdatedLocator,
      );
    }
    lobWriteCalls++;
    lastWriteOffset = sourceOffset;
    lastWriteData = data;
    return LobOpResponse(isSuccess: true, updatedLocator: lobUpdatedLocator);
  }
}

/// Builds a single-row query response whose one column holds [loc].
ExecuteResponse _lobRow(LobLocator loc, {String col = 'DOC'}) => ExecuteResponse(
      isSuccess: true,
      cursorId: 0, // not stored in the cache (cursorId 0)
      columnMetadata: [
        ColumnMetadata(name: col, oracleType: loc.oracleType, maxLength: 0),
      ],
      rows: [
        [loc],
      ],
      moreRowsToFetch: false,
    );

/// A CLOB (UTF-8) locator with a given char [length].
LobLocator _clob(int length) => LobLocator(
      locator: Uint8List(tnsLobLocatorBufferSize),
      oracleType: oraTypeClob,
      length: length,
      chunkSize: 8132,
    );

/// An NCLOB (UTF-16BE) locator with a given char [length].
LobLocator _nclob(int length) => LobLocator(
      locator: Uint8List(tnsLobLocatorBufferSize),
      oracleType: oraTypeClob,
      length: length,
      chunkSize: 0,
      isNChar: true,
    );

/// A BLOB locator with a given byte [length].
LobLocator _blob(int length) => LobLocator(
      locator: Uint8List(tnsLobLocatorBufferSize),
      oracleType: oraTypeBlob,
      length: length,
      chunkSize: 8132,
    );

/// Fetches exactly one [OracleLob] from a `fetchLobs: true` query returning the
/// single-column row [loc].
Future<(OracleConnection, _FakeLobTransport, OracleLob)> _fetchLob(
  LobLocator loc,
) async {
  final t = _FakeLobTransport()..nextResponses.add(_lobRow(loc));
  final conn = OracleConnection.forTesting(transport: t);
  final result = await conn.execute(
    'SELECT doc FROM t',
    null,
    const OracleExecuteOptions(fetchLobs: true),
  );
  final lob = result.rows.single['DOC'] as OracleLob;
  return (conn, t, lob);
}

void main() {
  group('OracleLob acquisition (fetchLobs)', () {
    test('a CLOB column is returned as an OracleLob handle, not a String',
        () async {
      final (conn, t, lob) = await _fetchLob(_clob(11));
      expect(lob, isA<OracleLob>());
      expect(lob.type, equals(OracleDbType.clob));
      expect(lob.length, equals(11));
      expect(lob.chunkSize, equals(8132));
      expect(lob.isClosed, isFalse);
      // Wrapping issues no LOB READ round trip — the handle reads lazily.
      expect(t.lobReadCalls, equals(0));
      await lob.close();
    });

    test('type maps CLOB / NCLOB / BLOB from the locator', () async {
      final (c1, _, clob) = await _fetchLob(_clob(1));
      final (c2, _, nclob) = await _fetchLob(_nclob(1));
      final (c3, _, blob) = await _fetchLob(_blob(1));
      expect(clob.type, equals(OracleDbType.clob));
      expect(nclob.type, equals(OracleDbType.nClob));
      expect(blob.type, equals(OracleDbType.blob));
      await clob.close();
      await nclob.close();
      await blob.close();
    });

    test('resultSet: true combined with fetchLobs: true is rejected pre-wire',
        () async {
      final t = _FakeLobTransport();
      final conn = OracleConnection.forTesting(transport: t);
      await expectLater(
        conn.execute(
          'SELECT doc FROM t',
          null,
          const OracleExecuteOptions(resultSet: true, fetchLobs: true),
        ),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('Story 12.3')),
        ),
      );
      // Rejected before any wire round trip.
      expect(t.nextResponses, isEmpty);
    });
  });

  group('OracleLob.read / getData', () {
    test('reads the whole CLOB value (default offset/amount) as a String',
        () async {
      final (conn, t, lob) = await _fetchLob(_clob(11));
      t.lobReadData = Uint8List.fromList(utf8.encode('hello world'));
      final value = await lob.read();
      expect(value, isA<String>());
      expect(value, equals('hello world'));
      // Default read requests offset 1, amount == length (whole value).
      expect(t.lobReadCalls, equals(1));
      expect(t.lastReadOffset, equals(1));
      expect(t.lastReadAmount, equals(11));
      await lob.close();
    });

    test('decodes an NCLOB read as UTF-16BE', () async {
      final (conn, t, lob) = await _fetchLob(_nclob(5));
      t.lobReadData = encodeUtf16Be('héllo');
      final value = await lob.read();
      expect(value, equals('héllo'));
      await lob.close();
    });

    test('returns raw bytes for a BLOB read', () async {
      final (conn, t, lob) = await _fetchLob(_blob(4));
      t.lobReadData = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
      final value = await lob.read();
      expect(value, isA<Uint8List>());
      expect(value, equals([0xDE, 0xAD, 0xBE, 0xEF]));
      await lob.close();
    });

    test('reads a bounded sub-range at a non-1 offset', () async {
      final (conn, t, lob) = await _fetchLob(_clob(11));
      t.lobReadData = Uint8List.fromList(utf8.encode('world'));
      final value = await lob.read(offset: 7, amount: 5);
      expect(value, equals('world'));
      expect(t.lastReadOffset, equals(7));
      expect(t.lastReadAmount, equals(5));
      await lob.close();
    });

    test('a null amount reads from offset to the end of the LOB', () async {
      final (conn, t, lob) = await _fetchLob(_clob(11));
      t.lobReadData = Uint8List.fromList(utf8.encode('world'));
      await lob.read(offset: 7);
      // amount defaults to length - offset + 1 == 11 - 7 + 1 == 5.
      expect(t.lastReadAmount, equals(5));
      await lob.close();
    });

    test('getData() with no args reads the whole value', () async {
      final (conn, t, lob) = await _fetchLob(_clob(2));
      t.lobReadData = Uint8List.fromList(utf8.encode('hi'));
      final value = await lob.getData();
      expect(value, equals('hi'));
      expect(t.lastReadOffset, equals(1));
      expect(t.lastReadAmount, equals(2));
      await lob.close();
    });

    test('an empty CLOB returns "" with no wire round trip', () async {
      final (conn, t, lob) = await _fetchLob(_clob(0));
      final value = await lob.read();
      expect(value, equals(''));
      expect(t.lobReadCalls, equals(0));
      await lob.close();
    });

    test('an empty BLOB returns an empty Uint8List with no wire round trip',
        () async {
      final (conn, t, lob) = await _fetchLob(_blob(0));
      final value = await lob.read();
      expect(value, isA<Uint8List>());
      expect((value as Uint8List), isEmpty);
      expect(t.lobReadCalls, equals(0));
      await lob.close();
    });

    test('reading at/past the end (null amount) short-circuits to empty',
        () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      final value = await lob.read(offset: 6); // offset == length + 1
      expect(value, equals(''));
      expect(t.lobReadCalls, equals(0));
      await lob.close();
    });

    test('reading past the end with an EXPLICIT amount also short-circuits '
        '(no needless READ past end)', () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      // offset 6 == length + 1, explicit amount 10: nothing to fetch. Must not
      // issue a READ (parity with the null-amount path).
      final value = await lob.read(offset: 6, amount: 10);
      expect(value, equals(''));
      expect(t.lobReadCalls, equals(0));
      // Same for a BLOB.
      final (conn2, t2, blob) = await _fetchLob(_blob(4));
      final bytes = await blob.read(offset: 5, amount: 8);
      expect(bytes, isA<Uint8List>());
      expect(bytes as Uint8List, isEmpty);
      expect(t2.lobReadCalls, equals(0));
      await lob.close();
      await blob.close();
    });

    test('a legitimate in-range READ that returns no data fails loud', () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      t.lobReadData = null; // server returns an empty/null payload for an
      // in-range read (offset 1, amount 5) — a fault, not a valid empty value.
      await expectLater(
        lob.read(offset: 1, amount: 5),
        throwsA(isA<OracleException>().having(
          (e) => e.message,
          'message',
          contains('returned no data'),
        )),
      );
      // The READ round trip WAS issued (this is not the short-circuit case).
      expect(t.lobReadCalls, equals(1));
      await lob.close();
    });

    test('a short-but-nonempty CLOB read fails loud (truncation guard)',
        () async {
      final (conn, t, lob) = await _fetchLob(_clob(11));
      // In-range request for 5 units but the server delivers only 3 — a real
      // truncation, not a valid short value. Must fail loud, mirroring the
      // materialize path's text.length == locator.length check.
      t.lobReadData = Uint8List.fromList(utf8.encode('abc'));
      await expectLater(
        lob.read(offset: 1, amount: 5),
        throwsA(isA<OracleException>().having(
          (e) => e.message,
          'message',
          allOf(contains('length mismatch'), contains('expected 5')),
        )),
      );
      await lob.close();
    });

    test('a short-but-nonempty BLOB read fails loud (truncation guard)',
        () async {
      final (conn, t, blob) = await _fetchLob(_blob(11));
      // Requested 5 bytes in range, server delivered only 2.
      t.lobReadData = Uint8List.fromList([1, 2]);
      await expectLater(
        blob.read(offset: 1, amount: 5),
        throwsA(isA<OracleException>().having(
          (e) => e.message,
          'message',
          allOf(contains('length mismatch'), contains('expected 5 bytes')),
        )),
      );
      await blob.close();
    });

    test('an EXPLICIT amount past the end reads to the end (not a truncation)',
        () async {
      // offset 7 into an 11-char CLOB with an explicit amount 100: only 5 units
      // remain (7..11). The server returns those 5 — the request is in range at
      // its start, so this reads-to-end and must NOT trip the truncation guard
      // (node-oracledb getData(offset, amount) parity).
      final (conn, t, lob) = await _fetchLob(_clob(11));
      t.lobReadData = Uint8List.fromList(utf8.encode('world'));
      final value = await lob.read(offset: 7, amount: 100);
      expect(value, equals('world'));
      await lob.close();
    });

    test('offset <= 0 throws ArgumentError before any wire round trip',
        () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      expect(() => lob.read(offset: 0), throwsArgumentError);
      expect(() => lob.read(offset: -3), throwsArgumentError);
      expect(t.lobReadCalls, equals(0));
      await lob.close();
    });

    test('amount <= 0 (when given) throws ArgumentError before any wire trip',
        () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      expect(() => lob.read(amount: 0), throwsArgumentError);
      expect(() => lob.read(amount: -1), throwsArgumentError);
      expect(t.lobReadCalls, equals(0));
      await lob.close();
    });

    test('malformed UTF-16 (odd byte count) fails loud', () async {
      final (conn, t, lob) = await _fetchLob(_nclob(2));
      t.lobReadData = Uint8List.fromList([0x00, 0x41, 0x00]); // odd length
      await expectLater(
        lob.read(),
        throwsA(isA<OracleException>()
            .having((e) => e.message, 'message', contains('UTF-16'))),
      );
      await lob.close();
    });
  });

  group('OracleLob.write', () {
    test('writes CLOB text as UTF-8 and advances length', () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      await lob.write(1, 'hello world');
      expect(t.lobWriteCalls, equals(1));
      expect(t.lastWriteOffset, equals(1));
      expect(t.lastWriteData, equals(utf8.encode('hello world')));
      // length = max(5, (1 - 1) + 11) == 11.
      expect(lob.length, equals(11));
      await lob.close();
    });

    test('writes NCLOB text as UTF-16BE', () async {
      final (conn, t, lob) = await _fetchLob(_nclob(0));
      await lob.write(1, 'héllo');
      expect(t.lastWriteData, equals(encodeUtf16Be('héllo')));
      expect(lob.length, equals(5)); // 5 UCS-2 code units
      await lob.close();
    });

    test('writes BLOB bytes raw and advances length in bytes', () async {
      final (conn, t, lob) = await _fetchLob(_blob(2));
      await lob.write(3, Uint8List.fromList([9, 8, 7]));
      expect(t.lastWriteOffset, equals(3));
      expect(t.lastWriteData, equals([9, 8, 7]));
      // length = max(2, (3 - 1) + 3) == 5.
      expect(lob.length, equals(5));
      await lob.close();
    });

    test('accepts a List<int> for a BLOB write', () async {
      final (conn, t, lob) = await _fetchLob(_blob(0));
      await lob.write(1, [1, 2, 3]);
      expect(t.lastWriteData, equals([1, 2, 3]));
      await lob.close();
    });

    test('a BLOB List<int> with an out-of-range element throws ArgumentError '
        'before any write (no silent modulo-256 corruption)', () async {
      final (conn, t, lob) = await _fetchLob(_blob(0));
      // 256 would wrap to 0, -1 to 255 under Uint8List.fromList — reject loud.
      expect(() => lob.write(1, [1, 256, 3]), throwsArgumentError);
      expect(() => lob.write(1, [-1, 2]), throwsArgumentError);
      expect(t.lobWriteCalls, equals(0));
      // A clean 0..255 list still writes.
      await lob.write(1, [0, 128, 255]);
      expect(t.lastWriteData, equals([0, 128, 255]));
      await lob.close();
    });

    test('does not advance length when the write stays within it', () async {
      final (conn, t, lob) = await _fetchLob(_clob(100));
      await lob.write(1, 'abc');
      expect(lob.length, equals(100)); // max(100, 3) stays 100
      await lob.close();
    });

    test('offset <= 0 throws ArgumentError before any wire round trip',
        () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      expect(() => lob.write(0, 'x'), throwsArgumentError);
      expect(t.lobWriteCalls, equals(0));
      await lob.close();
    });

    test('a String written to a BLOB handle throws ArgumentError', () async {
      final (conn, t, lob) = await _fetchLob(_blob(1));
      expect(() => lob.write(1, 'not bytes'), throwsArgumentError);
      expect(t.lobWriteCalls, equals(0));
      await lob.close();
    });

    test('Uint8List written to a CLOB handle throws ArgumentError', () async {
      final (conn, t, lob) = await _fetchLob(_clob(1));
      expect(() => lob.write(1, Uint8List.fromList([1])), throwsArgumentError);
      expect(t.lobWriteCalls, equals(0));
      await lob.close();
    });

    test('an empty write is a no-op (no wire round trip, no length change)',
        () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      await lob.write(3, '');
      expect(t.lobWriteCalls, equals(0));
      expect(lob.length, equals(5));
      await lob.close();
    });

    test('a server error on write surfaces fail-loud and leaves the handle '
        'usable', () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      t.failLobOp = true;
      await expectLater(lob.write(1, 'x'), throwsA(isA<OracleException>()));
      // The connection is not wedged: _executeInProgress was cleared, so a
      // subsequent op proceeds (here a read, which the fake now allows).
      t.failLobOp = false;
      t.lobReadData = Uint8List.fromList(utf8.encode('h'));
      expect(await lob.read(offset: 1, amount: 1), equals('h'));
      await lob.close();
    });

    test('the server echoed (updated) locator is copied back after an op so a '
        'later op references post-op state (node copy-back parity)', () async {
      // A BLOB avoids charset decode: the echoed locator bytes carry no CLOB
      // charset-flag meaning here, so the test isolates the copy-back.
      final (conn, t, lob) = await _fetchLob(_blob(5));
      // The server echoes a fresh locator state on every op (same length as the
      // live locator buffer, so the copy-back guard applies).
      final echoed = Uint8List(tnsLobLocatorBufferSize)
        ..fillRange(0, tnsLobLocatorBufferSize, 0xAB);
      t.lobUpdatedLocator = echoed;
      t.lobReadData = Uint8List.fromList([1, 2, 3, 4, 5]);

      await lob.write(1, Uint8List.fromList([9]));
      // The write itself sent the ORIGINAL (all-zero) locator bytes.
      expect(t.sentLocators.first, everyElement(equals(0)));

      // A subsequent read must reference the UPDATED locator bytes — proving
      // runLobWrite copied the echoed locator back into the live buffer.
      await lob.read(offset: 1, amount: 5);
      expect(t.sentLocators.last, equals(echoed));
      await lob.close();
    });
  });

  group('OracleLob.close', () {
    test('is idempotent and exception-free', () async {
      final (conn, t, lob) = await _fetchLob(_clob(1));
      await lob.close();
      expect(lob.isClosed, isTrue);
      // A second close does nothing and throws nothing.
      await lob.close();
      await lob.close();
      expect(lob.isClosed, isTrue);
    });

    test('read/write after close surfaces a clear OracleException', () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      await lob.close();
      await expectLater(
        lob.read(),
        throwsA(isA<OracleException>()
            .having((e) => e.message, 'message', contains('closed'))),
      );
      await expectLater(
        lob.write(1, 'x'),
        throwsA(isA<OracleException>()),
      );
      expect(t.lobReadCalls, equals(0));
      expect(t.lobWriteCalls, equals(0));
    });
  });

  group('OracleLob after the owning connection is closed', () {
    test('isClosed reports true once the connection is closed', () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      expect(lob.isClosed, isFalse);
      await conn.close();
      expect(lob.isClosed, isTrue);
    });

    test('an empty/past-end read short-circuit still fails loud after '
        'connection.close() (AC5)', () async {
      // The empty-LOB / past-end read short-circuits return BEFORE the wire
      // round trip; connection.close() must still make them fail loud rather
      // than silently returning '' / Uint8List(0).
      final (conn, t, lob) = await _fetchLob(_clob(0)); // empty CLOB
      await conn.close();
      await expectLater(
        lob.read(), // would short-circuit to '' on an open handle
        throwsA(isA<OracleException>()),
      );
      final (conn2, t2, blob) = await _fetchLob(_blob(4));
      await conn2.close();
      await expectLater(
        blob.read(offset: 5, amount: 8), // past-end short-circuit
        throwsA(isA<OracleException>()),
      );
      expect(t.lobReadCalls, equals(0));
      expect(t2.lobReadCalls, equals(0));
    });

    test('an empty write no-op still fails loud after connection.close() (AC5)',
        () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      await conn.close();
      await expectLater(
        lob.write(3, ''), // empty write would no-op on an open handle
        throwsA(isA<OracleException>()),
      );
      expect(t.lobWriteCalls, equals(0));
    });

    test('a wire read also fails loud after connection.close()', () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      await conn.close();
      await expectLater(
        lob.read(offset: 1, amount: 3),
        throwsA(isA<OracleException>()),
      );
      expect(t.lobReadCalls, equals(0));
    });
  });

  group('OracleLob in-flight / concurrency discipline', () {
    test('an open handle holds the connection busy: execute() is rejected',
        () async {
      final (conn, t, lob) = await _fetchLob(_clob(1));
      expect(conn.hasOpenLob, isTrue);
      await expectLater(
        conn.execute('SELECT 1 FROM dual'),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)
            .having((e) => e.message, 'message', contains('OracleLob'))),
      );
      // Closing the handle frees the connection for the next statement.
      await lob.close();
      expect(conn.hasOpenLob, isFalse);
      t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
      await conn.execute('SELECT 1 FROM dual'); // no throw
    });

    test('an in-flight read rejects an overlapping second read', () async {
      final (conn, t, lob) = await _fetchLob(_clob(3));
      t.lobReadData = Uint8List.fromList(utf8.encode('abc'));
      final gate = Completer<void>();
      t.lobOpGate = gate;
      final first = lob.read(); // parks inside sendLobOp
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        lob.read(),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
      );
      gate.complete();
      expect(await first, equals('abc'));
      await lob.close();
    });

    test('two aliased LOB columns yield the SAME handle (dedup)', () async {
      // Oracle's duplicate-column optimization can alias one locator into two
      // columns; the wrap path must register it once and share the handle.
      final loc = _clob(1);
      final t = _FakeLobTransport()
        ..nextResponses.add(
          ExecuteResponse(
            isSuccess: true,
            cursorId: 0,
            columnMetadata: const [
              ColumnMetadata(name: 'A', oracleType: oraTypeClob, maxLength: 0),
              ColumnMetadata(name: 'B', oracleType: oraTypeClob, maxLength: 0),
            ],
            rows: [
              [loc, loc],
            ],
            moreRowsToFetch: false,
          ),
        );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT a, b FROM t',
        null,
        const OracleExecuteOptions(fetchLobs: true),
      );
      final row = result.rows.single;
      expect(identical(row['A'], row['B']), isTrue);
      await (row['A'] as OracleLob).close();
      expect(conn.hasOpenLob, isFalse);
    });
  });

  group('OracleLob pool-reclaim force-close', () {
    test('forceCloseOpenLobs(reclaimedByPool: true) closes the handle and a '
        'later read raises a clear pool-reclaim error', () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      expect(conn.hasOpenLob, isTrue);
      await conn.forceCloseOpenLobs(reclaimedByPool: true);
      expect(conn.hasOpenLob, isFalse);
      expect(lob.isClosed, isTrue);
      await expectLater(
        lob.read(),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraConnectionClosed)
            .having((e) => e.message, 'message', contains('pool'))),
      );
      expect(t.lobReadCalls, equals(0));
    });
  });

  group('fetchLobs off is unchanged (regression guard)', () {
    test('a query without fetchLobs still materializes a CLOB to String',
        () async {
      // With fetchLobs off, materializeLobs reads the locator via sendLobOp.
      final t = _FakeLobTransport()
        ..lobReadData = Uint8List.fromList(utf8.encode('plain'))
        ..nextResponses.add(_lobRow(_clob(5)));
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('SELECT doc FROM t');
      expect(result.rows.single['DOC'], equals('plain'));
      expect(result.rows.single['DOC'], isA<String>());
      // A real LOB READ round trip was issued (materialize path).
      expect(t.lobReadCalls, equals(1));
      expect(conn.hasOpenLob, isFalse);
    });
  });

  group('OracleResult.closeLobs bulk-close', () {
    test('closes every open handle across a multi-row result and returns the '
        'count', () async {
      // Three rows, three distinct CLOB locators → three open handles wedging
      // the connection. closeLobs() closes them all in one call.
      final locs = [_clob(1), _clob(2), _clob(3)];
      final t = _FakeLobTransport()
        ..nextResponses.add(
          ExecuteResponse(
            isSuccess: true,
            cursorId: 0,
            columnMetadata: const [
              ColumnMetadata(name: 'DOC', oracleType: oraTypeClob, maxLength: 0),
            ],
            rows: [
              [locs[0]],
              [locs[1]],
              [locs[2]],
            ],
            moreRowsToFetch: false,
          ),
        );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT doc FROM t',
        null,
        const OracleExecuteOptions(fetchLobs: true),
      );
      expect(conn.hasOpenLob, isTrue);
      final handles =
          result.rows.map((r) => r['DOC'] as OracleLob).toList();
      final closed = await result.closeLobs();
      expect(closed, equals(3));
      expect(handles.every((h) => h.isClosed), isTrue);
      // The connection is freed for the next statement.
      expect(conn.hasOpenLob, isFalse);
    });

    test('returns 0 when the result holds no LOB handles (fetchLobs off)',
        () async {
      final t = _FakeLobTransport()
        ..nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute('SELECT 1 FROM dual');
      expect(await result.closeLobs(), equals(0));
    });

    test('closing all handles via closeLobs frees the connection even when a '
        'handle was already closed by hand', () async {
      final locs = [_clob(1), _clob(2)];
      final t = _FakeLobTransport()
        ..nextResponses.add(
          ExecuteResponse(
            isSuccess: true,
            cursorId: 0,
            columnMetadata: const [
              ColumnMetadata(name: 'DOC', oracleType: oraTypeClob, maxLength: 0),
            ],
            rows: [
              [locs[0]],
              [locs[1]],
            ],
            moreRowsToFetch: false,
          ),
        );
      final conn = OracleConnection.forTesting(transport: t);
      final result = await conn.execute(
        'SELECT doc FROM t',
        null,
        const OracleExecuteOptions(fetchLobs: true),
      );
      await (result.rows.first['DOC'] as OracleLob).close();
      // Still one open handle; closeLobs reaps both (idempotent on the closed
      // one) and the count reflects both distinct handles.
      final closed = await result.closeLobs();
      expect(closed, equals(2));
      expect(conn.hasOpenLob, isFalse);
    });
  });
}
