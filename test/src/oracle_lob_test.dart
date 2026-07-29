import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/oracle_lob.dart' show lobLocatorOf;
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
  ///
  /// Used for every READ unless [lobReadReplies] is non-empty, which takes
  /// precedence.
  Uint8List? lobReadData;

  /// Per-call canned READ replies, consumed in order — the seam for the chunked
  /// read loop and the piece streams (Story 12.3).
  ///
  /// Each entry supplies that READ's payload AND the server's SB8 `amount` (the
  /// units it claims to have delivered), so a test can drive a deterministic
  /// SHORT read (`amount` < requested) or a terminating EMPTY reply
  /// (`amount: 0`, no data) that no live server produces on demand. Once the
  /// queue is exhausted, further READs fall back to an empty reply with
  /// `amount: 0` — i.e. end of LOB — so a stream test never has to enumerate the
  /// terminator explicitly unless it wants to.
  ///
  /// A `null` `amount` reproduces a reply that omits the SB8 entirely (the
  /// [lobReadData] default), which the read loop must treat as "the request was
  /// satisfied".
  final List<({Uint8List? data, int? amount})> lobReadReplies =
      <({Uint8List? data, int? amount})>[];

  /// Whether the reply queue was drained (so a test can assert it consumed
  /// exactly as many READs as it queued).
  bool get lobReadRepliesExhausted => _lobReadReplyIndex >= lobReadReplies.length;
  int _lobReadReplyIndex = 0;

  /// Every (offset, amount) pair a READ requested, in order.
  final List<({int offset, int amount})> readRequests =
      <({int offset, int amount})>[];

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

  /// Per-operation canned `updatedLocator` echoes, overriding
  /// [lobUpdatedLocator] for that operation code. CREATE_TEMP must echo the
  /// "real" server locator, while GET_CHUNK_SIZE echoes it back unchanged.
  final Map<int, Uint8List> opUpdatedLocator = <int, Uint8List>{};

  /// Per-operation canned SB8 `amount` replies (GET_CHUNK_SIZE / GET_LENGTH).
  final Map<int, int> opAmount = <int, int>{};

  /// Every `operation` code passed to `sendLobOp`, in order.
  final List<int> sentOperations = <int>[];

  /// Recorded CREATE_TEMP arguments (charset form, Oracle type, duration).
  int? createTempCsfrm;
  int? createTempOraType;
  int? createTempDuration;

  /// Recorded `sendAmount` flag of the last GET_CHUNK_SIZE.
  bool? chunkSizeSentAmount;

  /// Operation codes that must throw when sent (simulates a server rejecting
  /// one specific step, e.g. GET_CHUNK_SIZE after a successful CREATE_TEMP).
  final Set<int> failOperations = <int>{};

  int lobReadCalls = 0;
  int lobWriteCalls = 0;
  int lastReadOffset = -1;
  int lastReadAmount = -1;
  int lastWriteOffset = -1;
  Uint8List? lastWriteData;

  /// Snapshot (copy) of the `sourceLocator` bytes passed to each op, in order.
  final List<Uint8List> sentLocators = <Uint8List>[];

  /// Flip to `false` to simulate a broken transport (a server-closed socket or
  /// a poisoned/timed-out RPC) WITHOUT a clean `connection.close()` — the
  /// BROKEN/RESET invalidation path that leaves `OracleConnection._isClosed`
  /// unset but the transport disconnected.
  bool connected = true;

  @override
  bool get isConnected => connected;

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
    if (failLobOp || failOperations.contains(operation)) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message: 'simulated LOB operation failure',
      );
    }
    sentOperations.add(operation);
    if (sourceLocator != null) {
      sentLocators.add(Uint8List.fromList(sourceLocator));
    }
    final echo = opUpdatedLocator[operation] ?? lobUpdatedLocator;
    if (operation == tnsLobOpCreateTemp) {
      createTempCsfrm = sourceOffset;
      createTempOraType = destOffset;
      createTempDuration = destLength;
      return LobOpResponse(isSuccess: true, updatedLocator: echo);
    }
    if (operation == tnsLobOpGetChunkSize) {
      chunkSizeSentAmount = sendAmount;
      return LobOpResponse(
        isSuccess: true,
        updatedLocator: echo,
        amount: opAmount[operation],
      );
    }
    if (operation == tnsLobOpRead) {
      lobReadCalls++;
      lastReadOffset = sourceOffset;
      lastReadAmount = amount;
      readRequests.add((offset: sourceOffset, amount: amount));
      if (lobReadReplies.isNotEmpty) {
        // Queued per-call replies: drive short reads, multi-piece streams and the
        // terminating empty reply deterministically. Past the end of the queue the
        // LOB is exhausted (empty payload, 0 units) — what a real server returns
        // for a READ starting past the end (measured on 23ai and 21c).
        if (_lobReadReplyIndex >= lobReadReplies.length) {
          return LobOpResponse(
            isSuccess: true,
            amount: 0,
            updatedLocator: echo,
          );
        }
        final reply = lobReadReplies[_lobReadReplyIndex++];
        return LobOpResponse(
          isSuccess: true,
          data: reply.data,
          amount: reply.amount,
          updatedLocator: echo,
        );
      }
      return LobOpResponse(
        isSuccess: true,
        data: lobReadData,
        updatedLocator: echo,
      );
    }
    lobWriteCalls++;
    lastWriteOffset = sourceOffset;
    lastWriteData = data;
    return LobOpResponse(isSuccess: true, updatedLocator: echo);
  }
}

/// A fake whose CREATE_TEMP echoes a distinctive 40-byte locator and whose
/// GET_CHUNK_SIZE reports [chunkSize], so `createTemporary*()` succeeds.
_FakeLobTransport _tempCapableTransport({
  int chunkSize = 8132,
  int locatorFill = 0x5A,
}) {
  final serverLocator = Uint8List(tnsLobLocatorBufferSize)
    ..fillRange(0, tnsLobLocatorBufferSize, locatorFill);
  return _FakeLobTransport()
    ..opUpdatedLocator[tnsLobOpCreateTemp] = serverLocator
    ..opAmount[tnsLobOpGetChunkSize] = chunkSize;
}

/// A connection whose charset info reports (or not) AL16UTF16 national support.
OracleConnection _connFor(
  Transport t, {
  String nationalCharset = 'AL16UTF16',
}) =>
    OracleConnection.forTesting(
      transport: t,
      charsetInfo: OracleCharsetInfo(
        databaseCharset: 'AL32UTF8',
        nationalCharset: nationalCharset,
      ),
    );

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

    // Story 12.3 AC6: the blanket `resultSet + fetchLobs` rejection was LIFTED
    // for a top-level SELECT (see result_set_test.dart's streaming-fetchLobs
    // group) but deliberately NOT deleted — the PL/SQL lazy-implicit-results path
    // keeps its own, distinct rejection, because that path returns a GROUP of
    // lazy result sets none of which is wired for the wrap + reap lifecycle.
    test('resultSet: true + fetchLobs: true on a PL/SQL block is rejected '
        'pre-wire with its own distinct message', () async {
      final t = _FakeLobTransport();
      final conn = OracleConnection.forTesting(transport: t);
      await expectLater(
        conn.execute(
          'BEGIN NULL; END;',
          null,
          const OracleExecuteOptions(resultSet: true, fetchLobs: true),
        ),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('PL/SQL block'))
              .having((e) => e.message, 'message',
                  contains('IS supported for a top-level SELECT')),
        ),
      );
      // Rejected before any wire round trip.
      expect(t.nextResponses, isEmpty);
      // ...and the connection is left clean and usable.
      expect(conn.isExecuting, isFalse);
      expect(conn.hasOpenResultSet, isFalse);
      expect(conn.hasOpenLob, isFalse);
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

    test(
        'the AC6 SHRUNK-direction remedy: an explicit amount covering only units '
        'that still exist reads correctly where a null amount fails loud',
        () async {
      // Story 12.4 AC6 requires the DOCUMENTED remedies to be asserted to work.
      // The shrunk direction cannot be produced live (measured on 23ai and 21c:
      // a LOB locator is read-consistent, so a stale handle keeps returning the
      // OLD value in full and never trips the truncation guard), so it is pinned
      // here deterministically: a handle whose CACHED length is 40 over a server
      // value that now holds only 10 units.
      final (conn, t, lob) = await _fetchLob(_clob(40));
      t.lobReadData = Uint8List.fromList(utf8.encode('0123456789'));
      expect(lob.length, equals(40), reason: 'the stale CACHED length');

      // Without an explicit amount the read asks for all 40 cached units and the
      // server can only deliver 10 — fail loud, never a silently short value.
      await expectLater(
        lob.read(),
        throwsA(isA<OracleException>().having((e) => e.message, 'message',
            allOf(contains('length mismatch'), contains('expected 40')))),
      );

      // The remedy: ask only for units you know exist. The cap keeps the request
      // at 10, the server satisfies it, and the value comes back correct.
      expect(await lob.read(offset: 1, amount: 10), equals('0123456789'));
      // ... and it really went to the server both times (no short-circuit).
      expect(t.lobReadCalls, equals(2));
      await lob.close();
    });

    // Epic 12 integration review iteration 3 (Low): the `length mismatch`
    // diagnosis above is reachable only from the fake's shape — a server that
    // reports `amount == request` while shipping fewer units. A server that
    // instead reports the units it ACTUALLY delivered makes `readLobRange` take a
    // second piece, get 0 units with progress already made, and throw
    // "LOB read made no progress" — the diagnosis the README named as the only
    // one. Both are pinned now so neither text can drift.
    test('a SHORT-READING server produces the "made no progress" diagnosis for '
        'the same shrunk LOB, not a length mismatch', () async {
      final (conn, t, lob) = await _fetchLob(_clob(40)); // stale cached length
      // Reports honestly: 10 units delivered, then nothing left. `lobReadData`
      // (the sibling test's shape) reports no amount at all, which is what makes
      // that one degrade into the truncation guard instead.
      t.lobReadReplies.addAll([
        (data: Uint8List.fromList(utf8.encode('0123456789')), amount: 10),
        (data: null, amount: 0),
      ]);
      await expectLater(
        lob.read(),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)
            .having((e) => e.message, 'message',
                allOf(contains('made no progress'), contains('offset 11')))),
      );
      expect(t.lobReadCalls, equals(2));
      await lob.close();
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

    // Epic 12 security review (LOW): a wrong-typed chunk must never put the
    // caller's payload into the exception. `ArgumentError.value` renders its
    // value through `Error.safeToString`, so the whole chunk used to land in
    // `toString()` — and `writeStream` DELIBERATELY funnels a rejected chunk into
    // `write()` for "the real ArgumentError", so the natural mistake
    // (`File('patient-records.txt').openRead()` into a CLOB handle, or a
    // Stream<String> into a BLOB handle) embedded a full piece of PII in a message
    // applications routinely log verbatim.
    test('a wrong-typed CLOB write reports the TYPE only, never the payload',
        () async {
      final (conn, t, lob) = await _fetchLob(_clob(1));
      const secret = 'PATIENT 4471 SSN 123-45-6789';
      final payload = Uint8List.fromList(utf8.encode(secret));
      try {
        await lob.write(1, payload);
        fail('expected ArgumentError');
      } on ArgumentError catch (e) {
        final text = e.toString();
        expect(text, contains('requires String'));
        expect(text, contains('Uint8List'),
            reason: 'the runtime type IS useful diagnostics');
        expect(text, isNot(contains('123-45-6789')),
            reason: 'payload bytes must not reach the message');
        expect(text, isNot(contains('12, 51')),
            reason: 'nor the byte-list rendering of the payload');
      }
      expect(t.lobWriteCalls, equals(0));
      await lob.close();
    });

    test('a wrong-typed BLOB write reports the TYPE only, never the payload',
        () async {
      final (conn, t, lob) = await _fetchLob(_blob(1));
      const secret = 'AKIA-SECRET-ACCESS-KEY-0001';
      try {
        await lob.write(1, secret);
        fail('expected ArgumentError');
      } on ArgumentError catch (e) {
        final text = e.toString();
        expect(text, contains('requires Uint8List or List<int>'));
        expect(text, contains('String'));
        expect(text, isNot(contains('AKIA-SECRET')));
      }
      expect(t.lobWriteCalls, equals(0));
      await lob.close();
    });

    test('the BLOB element-range guard still names the offending int (it is not '
        'payload)', () async {
      final (conn, t, lob) = await _fetchLob(_blob(1));
      try {
        await lob.write(1, <int>[1, 2, 999]);
        fail('expected ArgumentError');
      } on ArgumentError catch (e) {
        expect(e.toString(), contains('999'),
            reason: 'one out-of-range element is diagnostics, not payload');
      }
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

  group('OracleLob after the owning connection is broken (not cleanly closed)',
      () {
    // A connection can be invalidated WITHOUT connection.close() — a broken
    // transport (server-closed socket / poisoned RPC) or the runTransaction
    // rollback-failure path leaves the handle's own `_closed` unset while the
    // connection is no longer usable. read()/write() gate on the connection's
    // liveness (via ensureUsableForLobOp), so even the empty/past-end/empty-write
    // short-circuits fail loud there (AC5 "closed OR broken"), not just the wire
    // path. (iter-3 Med patch.)

    test('isClosed reports true once the transport goes broken', () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      expect(lob.isClosed, isFalse);
      t.connected = false; // broken transport, no connection.close()
      expect(lob.isClosed, isTrue);
    });

    test('empty/past-end read short-circuits fail loud on a broken transport',
        () async {
      final (conn, t, lob) = await _fetchLob(_clob(0)); // empty CLOB
      t.connected = false;
      await expectLater(
        lob.read(), // would short-circuit to '' on a live connection
        throwsA(isA<OracleException>()),
      );
      final (conn2, t2, blob) = await _fetchLob(_blob(4));
      t2.connected = false;
      await expectLater(
        blob.read(offset: 5, amount: 8), // past-end short-circuit
        throwsA(isA<OracleException>()),
      );
      expect(t.lobReadCalls, equals(0));
      expect(t2.lobReadCalls, equals(0));
    });

    test('empty write no-op fails loud on a broken transport', () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      t.connected = false;
      await expectLater(
        lob.write(3, ''), // would no-op on a live connection
        throwsA(isA<OracleException>()),
      );
      expect(t.lobWriteCalls, equals(0));
    });

    test('a wire read also fails loud on a broken transport', () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      t.connected = false;
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

    // Epic 12 integration review (Med): the CHANGELOG/README advertise
    // "pass an OracleLob straight into INSERT ... VALUES (:v)", but a FETCHED
    // handle trips the concurrency guard before `_validateLobBindValue` can say
    // anything — so a user following that bullet got "concurrent operation ...
    // is still in progress", which names no cause and suggests awaiting an
    // operation that does not exist.
    test('binding an OPEN FETCHED handle reports the fetched-handle rule, not '
        'the generic concurrent-operation error', () async {
      final (conn, t, lob) = await _fetchLob(_clob(1));
      await expectLater(
        conn.execute('INSERT INTO t (doc) VALUES (:v)', [lob]),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)
            .having((e) => e.message, 'message',
                contains('fetched OracleLob cannot be bound'))
            .having((e) => e.message, 'message',
                contains('createTemporary'))),
      );
      // Named binds and OracleBind wrappers reach the same diagnosis.
      await expectLater(
        conn.execute('INSERT INTO t (doc) VALUES (:v)', {'v': lob}),
        throwsA(isA<OracleException>().having((e) => e.message, 'message',
            contains('fetched OracleLob cannot be bound'))),
      );
      await expectLater(
        conn.execute('BEGIN p(:v); END;', [
          OracleBind.inOut(value: lob, type: OracleDbType.clob, maxSize: 10),
        ]),
        throwsA(isA<OracleException>().having((e) => e.message, 'message',
            contains('fetched OracleLob cannot be bound'))),
      );
      await lob.close();
    });

    test('an unrelated statement while a fetched handle is open still gets the '
        'GENERIC concurrent-operation message', () async {
      final (conn, t, lob) = await _fetchLob(_clob(1));
      await expectLater(
        conn.execute('SELECT 1 FROM dual'),
        throwsA(isA<OracleException>().having((e) => e.message, 'message',
            contains('Concurrent operation'))),
      );
      await lob.close();
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

  // =====================================================================
  // Story 12.2 — temporary LOB lifecycle
  // =====================================================================

  group('createTemporary* wire shape (AC1)', () {
    test('createTemporaryClob issues CREATE_TEMP then GET_CHUNK_SIZE and '
        'returns an empty handle seeded with the server chunk size', () async {
      final t = _tempCapableTransport(chunkSize: 8132);
      final conn = _connFor(t);
      final lob = await conn.createTemporaryClob();

      // Exactly two ops, in node-oracledb `lob.js create()` order.
      expect(t.sentOperations,
          equals([tnsLobOpCreateTemp, tnsLobOpGetChunkSize]));
      // CREATE_TEMP argument placement: charset form in the source offset,
      // Oracle type in the dest offset, session duration in the dest length.
      expect(t.createTempCsfrm, equals(ttcCsfrmImplicit));
      expect(t.createTempOraType, equals(oraTypeClob));
      expect(t.createTempDuration, equals(tnsDurationSession));
      // The CREATE_TEMP source locator is a fresh zeroed 40-byte buffer.
      expect(t.sentLocators.first.length, equals(tnsLobLocatorBufferSize));
      expect(t.sentLocators.first, everyElement(equals(0)));
      // GET_CHUNK_SIZE targets the ECHOED locator and requests the amount.
      expect(t.sentLocators[1], everyElement(equals(0x5A)));
      expect(t.chunkSizeSentAmount, isTrue);

      expect(lob.type, equals(OracleDbType.clob));
      expect(lob.length, equals(0));
      expect(lob.chunkSize, equals(8132));
      expect(lob.isTemporary, isTrue);
      expect(lob.isClosed, isFalse);
      await lob.close();
    });

    test('createTemporaryBlob uses charset form 0 and the BLOB type', () async {
      final t = _tempCapableTransport(chunkSize: 4000);
      final conn = _connFor(t);
      final lob = await conn.createTemporaryBlob();
      expect(t.createTempCsfrm, equals(0));
      expect(t.createTempOraType, equals(oraTypeBlob));
      expect(t.createTempDuration, equals(tnsDurationSession));
      expect(lob.type, equals(OracleDbType.blob));
      expect(lob.length, equals(0));
      expect(lob.chunkSize, equals(4000));
      expect(lob.isTemporary, isTrue);
      await lob.close();
    });

    test('createTemporaryNClob uses the NCHAR charset form and reports nClob',
        () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final lob = await conn.createTemporaryNClob();
      expect(t.createTempCsfrm, equals(ttcCsfrmNChar));
      expect(t.createTempOraType, equals(oraTypeClob));
      expect(lob.type, equals(OracleDbType.nClob));
      expect(lob.isTemporary, isTrue);
      await lob.close();
    });

    test('createTemporaryNClob fails loud pre-wire when the national charset '
        'is unsupported', () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t, nationalCharset: 'UTF8');
      await expectLater(
        conn.createTemporaryNClob(),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
            .having((e) => e.message, 'message', contains('AL16UTF16'))),
      );
      // No wire round trip at all.
      expect(t.sentOperations, isEmpty);
      expect(conn.hasOpenLob, isFalse);
      // A plain CLOB / BLOB is unaffected by the national charset.
      final clob = await conn.createTemporaryClob();
      expect(clob.isTemporary, isTrue);
      await clob.close();
    });

    test('a CREATE_TEMP that returns no locator fails loud and queues nothing',
        () async {
      // No echoed locator at all — the server response is malformed.
      final t = _FakeLobTransport()
        ..opAmount[tnsLobOpGetChunkSize] = 8132;
      final conn = _connFor(t);
      await expectLater(
        conn.createTemporaryClob(),
        throwsA(isA<OracleException>()
            .having((e) => e.message, 'message', contains('no locator'))),
      );
      // Nothing to free: there is no locator to queue.
      expect(conn.debugPendingTempLobCount, equals(0));
      expect(conn.hasOpenLob, isFalse);
      // The connection is not wedged.
      expect(conn.isExecuting, isFalse);
    });

    test('a failure AFTER CREATE_TEMP still queues the locator for the free '
        'piggyback (no leak)', () async {
      final t = _tempCapableTransport()..failOperations.add(tnsLobOpGetChunkSize);
      final conn = _connFor(t);
      await expectLater(
        conn.createTemporaryClob(),
        throwsA(isA<OracleException>()),
      );
      // The temp LOB exists server-side; its locator must already be queued.
      expect(conn.debugPendingTempLobCount, equals(1));
      // No half-registered handle wedges the connection.
      expect(conn.hasOpenLob, isFalse);
      expect(conn.isExecuting, isFalse);
      // The connection still runs the next statement. (The queue DRAIN itself
      // lives in the real Transport.sendExecute, which this fake replaces, so
      // draining is proven live in lob_temporary_integration_test.dart.)
      t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
      await conn.execute('SELECT 1 FROM dual');
    });

    test('a GET_CHUNK_SIZE with no amount fails loud and queues the free',
        () async {
      // Locator echoed, but no SB8 amount came back.
      final serverLocator = Uint8List(tnsLobLocatorBufferSize)
        ..fillRange(0, tnsLobLocatorBufferSize, 0x33);
      final t = _FakeLobTransport()
        ..opUpdatedLocator[tnsLobOpCreateTemp] = serverLocator;
      final conn = _connFor(t);
      await expectLater(
        conn.createTemporaryClob(),
        throwsA(isA<OracleException>()
            .having((e) => e.message, 'message', contains('no amount'))),
      );
      expect(conn.debugPendingTempLobCount, equals(1));
    });

    test('creation is bracketed by the in-flight guard, not the '
        'concurrent-operation guard', () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      // A second creation while the first is still in flight is rejected...
      final gate = Completer<void>();
      t.lobOpGate = gate;
      final first = conn.createTemporaryClob();
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        conn.createTemporaryClob(),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
      );
      gate.complete();
      final lob1 = await first;
      // ...but a SECOND temp LOB created sequentially is fine (this is why the
      // creation path must not use _rejectConcurrentOperation).
      final lob2 = await conn.createTemporaryClob();
      expect(identical(lob1, lob2), isFalse);
      expect(conn.hasOpenLob, isTrue);
      await lob1.close();
      await lob2.close();
      expect(conn.hasOpenLob, isFalse);
    });

    test('read/write work on a created handle (length advances, UTF-8)',
        () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final lob = await conn.createTemporaryClob();
      // A freshly created temp LOB is empty: read() short-circuits.
      expect(await lob.read(), equals(''));
      expect(t.lobReadCalls, equals(0));
      await lob.write(1, 'hello');
      expect(lob.length, equals(5));
      t.lobReadData = Uint8List.fromList(utf8.encode('hello'));
      expect(await lob.read(), equals('hello'));
      await lob.close();
    });

    test('a created NCLOB writes UTF-16BE', () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final lob = await conn.createTemporaryNClob();
      await lob.write(1, 'héllo');
      expect(t.lastWriteData, equals(encodeUtf16Be('héllo')));
      expect(lob.length, equals(5)); // UCS-2 code units
      await lob.close();
    });
  });

  group('OracleLob.isTemporary (AC2)', () {
    test('is false for a plain fetched locator', () async {
      final (conn, t, lob) = await _fetchLob(_clob(3));
      expect(lob.isTemporary, isFalse);
      await lob.close();
      // A non-temporary close queues nothing.
      expect(conn.debugPendingTempLobCount, equals(0));
    });

    test('is true for a fetched locator carrying the server TEMP flag',
        () async {
      final bytes = Uint8List(tnsLobLocatorBufferSize)
        ..[tnsLobLocOffsetFlag4] = tnsLobLocFlagsTemp;
      final loc = LobLocator(
        locator: bytes,
        oracleType: oraTypeClob,
        length: 3,
        chunkSize: 0,
      );
      final (conn, t, lob) = await _fetchLob(loc);
      expect(lob.isTemporary, isTrue);
      // A fetched handle still holds the in-flight slot (12.1 unchanged).
      expect(conn.hasOpenLob, isTrue);
      await expectLater(
        conn.execute('SELECT 1 FROM dual'),
        throwsA(isA<OracleException>()),
      );
      await lob.close();
      // ...and its temp locator IS queued for the free piggyback.
      expect(conn.debugPendingTempLobCount, equals(1));
    });
  });

  group('close() frees a temporary LOB (AC3)', () {
    // NOTE: the free list DRAIN happens inside the real
    // `Transport.sendExecute`, which `_FakeLobTransport` replaces wholesale, so
    // these unit tests pin the QUEUEING side only (rise by exactly one per
    // distinct handle, never twice, never on a dead session). "Drains to 0 after
    // the next execute()" is proven against a real server in
    // test/integration/lob_temporary_integration_test.dart.
    test('close() queues exactly one locator for the free piggyback', () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final lob = await conn.createTemporaryClob();
      expect(conn.debugPendingTempLobCount, equals(0),
          reason: 'creation itself must not queue a free');
      await lob.close();
      expect(conn.debugPendingTempLobCount, equals(1));
      // The connection is immediately reusable.
      t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
      await conn.execute('SELECT 1 FROM dual');
    });

    test('a double close queues the locator only once (no double free)',
        () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final lob = await conn.createTemporaryClob();
      await lob.close();
      await lob.close();
      await lob.close();
      expect(conn.debugPendingTempLobCount, equals(1));
      expect(lob.isClosed, isTrue);
    });

    test('two distinct handles each queue once', () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final a = await conn.createTemporaryClob();
      // A real CREATE_TEMP returns a DISTINCT locator per temporary LOB — the
      // locator bytes ARE the LOB's server-side identity. This fake echoes one
      // canned buffer for every CREATE_TEMP, so the second create is pointed at
      // a different buffer to model that. It matters since Story 12.4: the free
      // queue dedupes byte-EQUAL locators (so a PL/SQL `p := p` IN OUT bind,
      // whose OUT locator is the driver's own input locator, is not freed
      // twice), and without this the two handles would look like one LOB.
      t.opUpdatedLocator[tnsLobOpCreateTemp] =
          Uint8List(tnsLobLocatorBufferSize)
            ..fillRange(0, tnsLobLocatorBufferSize, 0x3C);
      final b = await conn.createTemporaryBlob();
      await a.close();
      await b.close();
      expect(conn.debugPendingTempLobCount, equals(2),
          reason: 'two distinct server LOBs need two distinct frees');
    });

    test('close() on a CLOSED connection skips the queue silently', () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final lob = await conn.createTemporaryClob();
      await conn.close();
      await lob.close(); // no throw
      expect(lob.isClosed, isTrue);
      // The session is gone; the server frees session-duration temp LOBs at
      // teardown, and there is no next execute to carry a piggyback.
      expect(conn.debugPendingTempLobCount, equals(0));
    });

    test('close() on a BROKEN transport skips the queue silently', () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final lob = await conn.createTemporaryClob();
      t.connected = false;
      await lob.close(); // no throw
      expect(conn.debugPendingTempLobCount, equals(0));
    });

    test('a non-temporary handle close is unchanged: no wire effect', () async {
      final (conn, t, lob) = await _fetchLob(_clob(5));
      final opsBefore = t.sentOperations.length;
      await lob.close();
      expect(t.sentOperations.length, equals(opsBefore));
      expect(conn.debugPendingTempLobCount, equals(0));
    });
  });

  group('created-temp handles and the concurrency guard (AC4)', () {
    test('execute() proceeds while a created temp handle is open', () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final lob = await conn.createTemporaryClob();
      expect(conn.hasOpenLob, isTrue); // pool reclaim must still see it
      t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
      await conn.execute('SELECT 1 FROM dual'); // no throw
      await lob.close();
    });

    test('a created temp handle open alongside a FETCHED handle still rejects '
        'execute()', () async {
      final t = _FakeLobTransport()
        ..opUpdatedLocator[tnsLobOpCreateTemp] =
            (Uint8List(tnsLobLocatorBufferSize)
              ..fillRange(0, tnsLobLocatorBufferSize, 0x5A))
        ..opAmount[tnsLobOpGetChunkSize] = 8132
        ..nextResponses.add(_lobRow(_clob(4)));
      final conn = _connFor(t);
      final result = await conn.execute(
        'SELECT doc FROM t',
        null,
        const OracleExecuteOptions(fetchLobs: true),
      );
      final fetched = result.rows.single['DOC'] as OracleLob;
      // A temp LOB can still be created while a fetched handle is open (the
      // creation path uses _runLobOp, not _rejectConcurrentOperation).
      final temp = await conn.createTemporaryClob();
      await expectLater(
        conn.execute('SELECT 1 FROM dual'),
        throwsA(isA<OracleException>()
            .having((e) => e.message, 'message', contains('OracleLob'))),
      );
      // Closing only the FETCHED handle frees the connection.
      await fetched.close();
      t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
      await conn.execute('SELECT 1 FROM dual'); // no throw
      await temp.close();
    });

    test('an in-flight LOB op still rejects an overlapping execute()',
        () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final lob = await conn.createTemporaryClob();
      final gate = Completer<void>();
      t.lobOpGate = gate;
      final writing = lob.write(1, 'abc');
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        conn.execute('SELECT 1 FROM dual'),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)),
      );
      gate.complete();
      await writing;
      await lob.close();
    });

    test('the execute-failure cleanup spares a created temp handle but reaps a '
        'fetched one', () async {
      // A fetchLobs execute that wraps a top-level LOB and THEN throws (its
      // nested CURSOR() column carries a LOB, which Story 12.1 rejects). The
      // caller's created-temp handle was legitimately open at entry — the
      // concurrency guard exempts it — so it must survive; the fetched handle
      // this call registered must be reaped.
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final temp = await conn.createTemporaryClob();
      await temp.write(1, 'precious');
      expect(temp.length, equals(8));

      t.nextResponses.add(
        ExecuteResponse(
          isSuccess: true,
          cursorId: 0,
          columnMetadata: const [
            ColumnMetadata(name: 'DOC', oracleType: oraTypeClob, maxLength: 0),
            ColumnMetadata(name: 'NC', oracleType: oraTypeCursor, maxLength: 0),
          ],
          rows: [
            [
              _clob(2),
              const DecodedCursorResult(
                columns: [
                  ColumnMetadata(
                    name: 'INNER',
                    oracleType: oraTypeClob,
                    maxLength: 0,
                  ),
                ],
                cursorId: 100,
              ),
            ],
          ],
          moreRowsToFetch: false,
        ),
      );
      await expectLater(
        conn.execute(
          'SELECT doc, CURSOR(SELECT inner FROM u) nc FROM t',
          null,
          const OracleExecuteOptions(fetchLobs: true),
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.message, 'message', contains('CURSOR'))),
      );

      // The caller's temp handle survived, unfreed, with its data intact.
      expect(temp.isClosed, isFalse,
          reason: 'a caller-created temp handle must survive the reap');
      expect(temp.length, equals(8));
      expect(conn.debugPendingTempLobCount, equals(0),
          reason: 'the spared handle must not have been freed');
      // ...and it is the ONLY handle left: the fetched one was reaped, so the
      // connection is not wedged.
      expect(conn.hasOpenLob, isTrue);
      t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
      await conn.execute('SELECT 1 FROM dual'); // no concurrent-op rejection
      await temp.close();
      expect(conn.debugPendingTempLobCount, equals(1));
      expect(conn.hasOpenLob, isFalse);
    });

    test('forceCloseOpenLobs (pool reclaim) closes AND frees a created temp '
        'handle', () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final lob = await conn.createTemporaryClob();
      await conn.forceCloseOpenLobs(reclaimedByPool: true);
      expect(lob.isClosed, isTrue);
      expect(conn.hasOpenLob, isFalse);
      expect(conn.debugPendingTempLobCount, equals(1),
          reason: 'a forgetful borrower must not leak session temp-LOB space');
      // The borrower's next read still surfaces the clear pool-reclaim error.
      await expectLater(
        lob.read(),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraConnectionClosed)
            .having((e) => e.message, 'message', contains('pool'))),
      );
      // No double free: an explicit close() after the reclaim queues nothing.
      await lob.close();
      expect(conn.debugPendingTempLobCount, equals(1));
    });
  });

  group('OracleLob as a bind value (AC5)', () {
    /// Extracts the bind values the fake transport last saw for [sql].
    test('a positional OracleLob bind reaches the wire as its locator',
        () async {
      final t = _tempCapableTransport(locatorFill: 0x7C);
      final conn = _connFor(t);
      final lob = await conn.createTemporaryClob();
      t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
      await conn.execute('INSERT INTO t (doc) VALUES (:1)', [lob]);
      // The bind slot carries the locator, so the ExecuteRequest encoder's
      // oraTypeClob branch writes `UB4 length + locator bytes`.
      final encoded = ExecuteRequest(
        sql: 'INSERT INTO t (doc) VALUES (:1)',
        bindValues: [
          BindVariable(
            value: lobLocatorOf(lob),
            oraType: oraTypeClob,
            dir: BindDir.input,
          ),
        ],
        isQuery: false,
      ).toBytes();
      // The 40 locator bytes appear verbatim in the encoded message.
      expect(_containsSubsequence(encoded, lobLocatorOf(lob).locator), isTrue);
      await lob.close();
    });

    test('a named OracleLob bind is accepted', () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final lob = await conn.createTemporaryBlob();
      t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
      await conn.execute('INSERT INTO t (bin) VALUES (:v)', {'v': lob});
      await lob.close();
    });

    test('an OracleBind.inOut OracleLob value is accepted in PL/SQL', () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final lob = await conn.createTemporaryClob();
      t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
      await conn.execute(
        'BEGIN p(:v); END;',
        {
          'v': OracleBind.inOut(
            value: lob,
            type: OracleDbType.clob,
            maxSize: 4000,
          ),
        },
      );
      await lob.close();
    });

    test('binding does NOT queue the locator for the free piggyback', () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final lob = await conn.createTemporaryClob();
      t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
      await conn.execute('INSERT INTO t (doc) VALUES (:v)', {'v': lob});
      // The handle's lifetime is the caller's: only close() frees it.
      expect(conn.debugPendingTempLobCount, equals(0));
      expect(lob.isClosed, isFalse);
      await lob.close();
      expect(conn.debugPendingTempLobCount, equals(1));
    });

    test('binding a CLOSED handle fails loud before any wire round trip',
        () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final lob = await conn.createTemporaryClob();
      await lob.close();
      final opsBefore = t.sentOperations.length;
      await expectLater(
        conn.execute('INSERT INTO t (doc) VALUES (:v)', {'v': lob}),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraBindTypeError)
            .having((e) => e.message, 'message', contains('closed'))),
      );
      // No execute was sent (the canned response list is untouched) and no LOB
      // op either.
      expect(t.nextResponses, isEmpty);
      expect(t.sentOperations.length, equals(opsBefore));
      // The connection stays usable.
      t.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
      await conn.execute('SELECT 1 FROM dual');
    });

    test('binding a FOREIGN connection handle fails loud before the wire',
        () async {
      final tA = _tempCapableTransport();
      final connA = _connFor(tA);
      final foreign = await connA.createTemporaryClob();

      final tB = _tempCapableTransport();
      final connB = _connFor(tB);
      await expectLater(
        connB.execute('INSERT INTO t (doc) VALUES (:v)', {'v': foreign}),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraBindTypeError)
            .having((e) => e.message, 'message', contains('DIFFERENT'))),
      );
      expect(tB.sentOperations, isEmpty);
      // connB stays usable, and the foreign handle is untouched.
      tB.nextResponses.add(ExecuteResponse(isSuccess: true, cursorId: 0));
      await connB.execute('SELECT 1 FROM dual');
      expect(foreign.isClosed, isFalse);
      await foreign.close();
    });

    test('an OracleBind declaring the WRONG LOB type fails loud', () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final blob = await conn.createTemporaryBlob();
      await expectLater(
        conn.execute(
          'BEGIN p(:v); END;',
          {
            'v': OracleBind.inOut(
              value: blob,
              type: OracleDbType.clob,
              maxSize: 100,
            ),
          },
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraBindTypeError)
            .having((e) => e.message, 'message', contains('blob'))),
      );
      expect(t.nextResponses, isEmpty);
      await blob.close();
    });

    test('the unwrap is category-agnostic, but an OPEN fetched handle is still '
        'stopped by the 12.1 concurrency guard (documented consequence)',
        () async {
      // The bind unwrap accepts any OracleLob this connection owns. In practice
      // only a CREATED-temporary handle can reach an execute() while open,
      // because Story 12.1's rule that an open FETCHED handle makes the
      // connection busy is deliberately unchanged (AC4, and carried through the
      // whole of Epic 12) — so a fetched handle bind is rejected by the
      // concurrency guard BEFORE the bind unwrap runs, and after close() the
      // closed-handle guard rejects it. Pin both so a future reader does not read
      // AC5's "temporary or fetched" as a claim that a live fetched handle is
      // bindable today. Since the Epic 12 integration review the guard reports
      // this case SPECIFICALLY rather than as a generic concurrent operation.
      final (conn, t, lob) = await _fetchLob(_clob(4));
      expect(lob.isTemporary, isFalse);
      await expectLater(
        conn.execute('INSERT INTO t (doc) VALUES (:v)', {'v': lob}),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)
            .having((e) => e.message, 'message',
                contains('fetched OracleLob cannot be bound'))),
      );
      await lob.close();
      await expectLater(
        conn.execute('INSERT INTO t (doc) VALUES (:v)', {'v': lob}),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraBindTypeError)
            .having((e) => e.message, 'message', contains('closed'))),
      );
    });

    test('an OracleLob in executeMany rows fails loud naming execute()',
        () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final lob = await conn.createTemporaryClob();
      await expectLater(
        conn.executeMany('INSERT INTO t (doc) VALUES (:1)', [
          [lob],
        ]),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraBindTypeError)
            .having(
              (e) => e.message,
              'message',
              allOf(contains('OracleLob'), contains('execute()')),
            )),
      );
      await lob.close();
    });

    test('an OracleLob in an OracleBindDef-declared executeMany slot fails '
        'loud naming execute()', () async {
      final t = _tempCapableTransport();
      final conn = _connFor(t);
      final lob = await conn.createTemporaryClob();
      await expectLater(
        conn.executeMany(
          'BEGIN p(:v); END;',
          [
            {'v': lob},
          ],
          OracleExecuteManyOptions(
            bindDefs: {
              'v': OracleBindDef.input(type: OracleDbType.clob, maxSize: 4000),
            },
          ),
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraBindTypeError)
            .having(
              (e) => e.message,
              'message',
              allOf(contains('OracleLob'), contains('execute()')),
            )),
      );
      await lob.close();
    });
  });

  // -------------------------------------------------------------------------
  // Story 12.3 AC1 — read() survives a value larger than one READ round trip
  //
  // No live server short-reads (measured to 32 MB on 23ai and 8 MB on 21c), so
  // the continuation loop can ONLY be proven with a fake that reports a
  // deterministic short `amount`. Each test here fails without the loop.
  // -------------------------------------------------------------------------
  group('OracleLob.read chunked continuation (AC1)', () {
    test('a short first READ continues at the advanced offset until the '
        'requested units arrive', () async {
      final (conn, t, lob) = await _fetchLob(_clob(9));
      // 9 chars delivered as 4 + 3 + 2 (plain CLOB -> UTF-8 on the wire).
      t.lobReadReplies.addAll([
        (data: Uint8List.fromList(utf8.encode('abcd')), amount: 4),
        (data: Uint8List.fromList(utf8.encode('efg')), amount: 3),
        (data: Uint8List.fromList(utf8.encode('hi')), amount: 2),
      ]);
      expect(await lob.read(), equals('abcdefghi'));
      // Three READs at the advancing offset, each asking for what is still
      // outstanding.
      expect(t.readRequests, hasLength(3));
      expect(t.readRequests[0], equals((offset: 1, amount: 9)));
      expect(t.readRequests[1], equals((offset: 5, amount: 5)));
      expect(t.readRequests[2], equals((offset: 8, amount: 2)));
      expect(t.lobReadRepliesExhausted, isTrue);
      await lob.close();
    });

    test('assembled pieces are decoded ONCE, so a boundary splitting a UTF-8 '
        'sequence and a surrogate pair still decodes exactly', () async {
      // 'caf\u{00E9}\u{1F600}' = 'c','a','f' (1 byte each), U+00E9 (2 UTF-8
      // bytes, 1 UCS-2 unit) and U+1F600 (4 UTF-8 bytes, 2 UCS-2 units)
      // => 6 UCS-2 units in 9 bytes.
      const text = 'caf\u{00E9}\u{1F600}';
      final all = Uint8List.fromList(utf8.encode(text));
      expect(text.length, equals(6));
      expect(all, hasLength(9));
      final (conn, t, lob) = await _fetchLob(_clob(6));
      // Split mid-U+00E9 (byte 4) and mid-U+1F600 (byte 7): neither piece is
      // independently decodable, so a per-piece decode would throw or corrupt.
      // Units per piece are what the server reports.
      t.lobReadReplies.addAll([
        (data: Uint8List.sublistView(all, 0, 4), amount: 3),
        (data: Uint8List.sublistView(all, 4, 7), amount: 2),
        (data: Uint8List.sublistView(all, 7, 9), amount: 1),
      ]);
      expect(await lob.read(), equals(text));
      expect(t.lobReadCalls, equals(3));
      await lob.close();
    });

    test('a BLOB read continues across pieces and concatenates byte-exact',
        () async {
      final (conn, t, blob) = await _fetchLob(_blob(6));
      t.lobReadReplies.addAll([
        (data: Uint8List.fromList([1, 2]), amount: 2),
        (data: Uint8List.fromList([3, 4, 5]), amount: 3),
        (data: Uint8List.fromList([6]), amount: 1),
      ]);
      expect(await blob.read(), equals([1, 2, 3, 4, 5, 6]));
      expect(t.lobReadCalls, equals(3));
      await blob.close();
    });

    test('a piece reporting ZERO units with work outstanding throws, naming '
        'the offset and amount (no infinite loop)', () async {
      final (conn, t, lob) = await _fetchLob(_clob(9));
      t.lobReadReplies.addAll([
        (data: Uint8List.fromList(utf8.encode('abcd')), amount: 4),
        (data: null, amount: 0), // no progress while 5 units outstanding
      ]);
      await expectLater(
        lob.read(),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)
            .having((e) => e.message, 'message',
                allOf(contains('made no progress'), contains('offset 5')))),
      );
      // Bounded: exactly the two queued READs were issued, then it gave up.
      expect(t.lobReadCalls, equals(2));
      await lob.close();
    });

    test('a piece reporting MORE units than were outstanding throws', () async {
      final (conn, t, lob) = await _fetchLob(_clob(4));
      t.lobReadReplies
          .add((data: Uint8List.fromList(utf8.encode('abcdefgh')), amount: 8));
      await expectLater(
        lob.read(),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)
            .having((e) => e.message, 'message', contains('overshot'))),
      );
      await lob.close();
    });

    // Epic 12 integration review iteration 2 (Low): `amount` (RETURN_PARAMETER)
    // and `data` (separate LOB_DATA messages) are decoded from UNRELATED wire
    // messages, so an internally inconsistent reply is possible in principle and
    // was uncross-checked. A FIRST piece shipping bytes while reporting 0 units
    // used to take the "nothing at all was delivered" break, returning an EMPTY
    // result — the prefix silently discarded and the fault mis-diagnosed as
    // "read returned no data".
    test('a FIRST piece that ships bytes but reports ZERO units fails loud, '
        'never silently discarding the prefix', () async {
      final (conn, t, lob) = await _fetchLob(_clob(9));
      t.lobReadReplies
          .add((data: Uint8List.fromList(utf8.encode('abcd')), amount: 0));
      await expectLater(
        lob.read(),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)
            .having((e) => e.message, 'message',
                allOf(
                  contains('internally inconsistent'),
                  contains('4 payload bytes'),
                  contains('reported 0 units'),
                ))),
      );
      expect(t.lobReadCalls, equals(1));
      await lob.close();
    });

    test('the overshoot guard is measured against what the PIECE requested, not '
        'the whole outstanding tail', () async {
      final (conn, t, lob) = await _fetchLob(_clob(6));
      // A piece cap of 2 makes request(2) < outstanding(6); a server reporting 4
      // units for a 2-unit request is a fault even though 4 <= 6, because the
      // next piece's sourceOffset would then be wrong. The looser comparison
      // accepted it.
      conn.debugLobReadPieceUnits = 2;
      try {
        t.lobReadReplies
            .add((data: Uint8List.fromList(utf8.encode('abcd')), amount: 4));
        await expectLater(
          lob.read(),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message',
                  allOf(contains('overshot'), contains('only 2 were '
                      'requested')))),
        );
      } finally {
        conn.debugLobReadPieceUnits = null;
      }
      await lob.close();
    });

    test('the single-READ fast path is preserved: one tnsLobOpRead for a value '
        'that fits, with no extra probe', () async {
      final (conn, t, lob) = await _fetchLob(_clob(11));
      t.lobReadReplies
          .add((data: Uint8List.fromList(utf8.encode('hello world')), amount: 11));
      expect(await lob.read(), equals('hello world'));
      expect(t.lobReadCalls, equals(1), reason: 'exactly one round trip');
      expect(t.readRequests.single, equals((offset: 1, amount: 11)));
      await lob.close();
    });

    test('a reply that OMITS the SB8 amount is treated as satisfying the '
        'request (pre-12.3 single-READ behavior, guards still fire)', () async {
      final (conn, t, lob) = await _fetchLob(_clob(11));
      // No `amount` at all, and a short payload: the loop must not spin, and the
      // truncation guard must be what reports the problem.
      t.lobReadReplies.add((data: Uint8List.fromList(utf8.encode('abc')), amount: null));
      await expectLater(
        lob.read(),
        throwsA(isA<OracleException>()
            .having((e) => e.message, 'message', contains('length mismatch'))),
      );
      expect(t.lobReadCalls, equals(1));
      await lob.close();
    });

    // Epic 12 integration review iteration 3 (Low): iteration 2's
    // `delivered > request` tightening was paired with a fallback of
    // `response.amount ?? outstanding`, so under a piece cap the documented
    // missing-SB8 DEGRADE tripped the brand-new overshoot throw — a documented
    // behaviour turned into a hard error on precisely the seam 12.4 AC5 added to
    // make this loop testable. The fallback is now `?? request`.
    test('a reply that OMITS the SB8 amount degrades PER PIECE under a piece '
        'cap, instead of tripping the overshoot guard', () async {
      final (conn, t, lob) = await _fetchLob(_clob(6));
      conn.debugLobReadPieceUnits = 2; // request(2) < outstanding(6)
      try {
        // Both replies omit the amount. With `?? outstanding` the first piece
        // "delivered" 6 units against a 2-unit request and threw "overshot";
        // with `?? request` it credits 2 and the loop simply continues.
        t.lobReadReplies.addAll([
          (data: Uint8List.fromList(utf8.encode('ab')), amount: null),
          (data: Uint8List.fromList(utf8.encode('cd')), amount: null),
          (data: Uint8List.fromList(utf8.encode('ef')), amount: null),
        ]);
        expect(await lob.read(), equals('abcdef'));
        expect(
          t.readRequests,
          equals([
            (offset: 1, amount: 2),
            (offset: 3, amount: 2),
            (offset: 5, amount: 2),
          ]),
          reason: 'the offset advances by what each piece requested',
        );
      } finally {
        conn.debugLobReadPieceUnits = null;
      }
      await lob.close();
    });

    test('the overshoot guard still fires under a cap when the server REPORTS '
        'too many units (negative control for the `?? request` fallback)',
        () async {
      final (conn, t, lob) = await _fetchLob(_clob(6));
      conn.debugLobReadPieceUnits = 2;
      try {
        // A reported (non-null) amount is unaffected by the fallback change.
        t.lobReadReplies
            .add((data: Uint8List.fromList(utf8.encode('abc')), amount: 3));
        await expectLater(
          lob.read(),
          throwsA(isA<OracleException>()
              .having((e) => e.message, 'message', contains('overshot'))),
        );
      } finally {
        conn.debugLobReadPieceUnits = null;
      }
      await lob.close();
    });

    test('a deliberate read past the end still reads to the end without '
        'tripping the no-progress guard', () async {
      final (conn, t, lob) = await _fetchLob(_clob(11));
      t.lobReadReplies
          .add((data: Uint8List.fromList(utf8.encode('world')), amount: 5));
      // amount 100 from offset 7 overshoots: only 5 units remain. The seam must
      // be asked for 5, not 100, so it never waits for units that cannot exist.
      expect(await lob.read(offset: 7, amount: 100), equals('world'));
      expect(t.readRequests.single, equals((offset: 7, amount: 5)));
      await lob.close();
    });
  });

  // -------------------------------------------------------------------------
  // Story 12.3 AC2 — textStream() / byteStream()
  // -------------------------------------------------------------------------
  group('OracleLob.textStream / byteStream (AC2)', () {
    test('textStream yields pieces whose concatenation equals read()', () async {
      final (conn, t, lob) = await _fetchLob(_clob(9));
      t.lobReadReplies.addAll([
        (data: Uint8List.fromList(utf8.encode('abcd')), amount: 4),
        (data: Uint8List.fromList(utf8.encode('efgh')), amount: 4),
        (data: Uint8List.fromList(utf8.encode('i')), amount: 1),
      ]);
      final pieces = await lob.textStream(pieceSize: 4).toList();
      expect(pieces, equals(['abcd', 'efgh', 'i']));
      // One READ per piece PLUS the terminating empty READ.
      expect(t.lobReadCalls, equals(4));
      expect(
        t.readRequests,
        equals([
          (offset: 1, amount: 4),
          (offset: 5, amount: 4),
          (offset: 9, amount: 4),
          (offset: 10, amount: 4),
        ]),
      );
      await lob.close();
    });

    test('byteStream yields byte pieces and terminates on the empty READ',
        () async {
      final (conn, t, blob) = await _fetchLob(_blob(5));
      t.lobReadReplies.addAll([
        (data: Uint8List.fromList([1, 2]), amount: 2),
        (data: Uint8List.fromList([3, 4]), amount: 2),
        (data: Uint8List.fromList([5]), amount: 1),
      ]);
      final pieces = await blob.byteStream(pieceSize: 2).toList();
      expect(pieces.map((p) => p.toList()).toList(),
          equals([[1, 2], [3, 4], [5]]));
      expect(t.lobReadCalls, equals(4)); // 3 pieces + terminator
      await blob.close();
    });

    test('an offset > 1 streams only the tail', () async {
      final (conn, t, lob) = await _fetchLob(_clob(9));
      t.lobReadReplies.addAll([
        (data: Uint8List.fromList(utf8.encode('fg')), amount: 2),
        (data: Uint8List.fromList(utf8.encode('hi')), amount: 2),
      ]);
      expect(await lob.textStream(offset: 6, pieceSize: 2).toList(),
          equals(['fg', 'hi']));
      expect(t.readRequests.first, equals((offset: 6, amount: 2)));
      await lob.close();
    });

    test('an empty LOB yields NO pieces after exactly one READ (no useless '
        'loop, and no _length short-circuit)', () async {
      final (conn, t, lob) = await _fetchLob(_clob(0));
      expect(await lob.textStream().toList(), isEmpty);
      expect(t.lobReadCalls, equals(1));
      await lob.close();
    });

    test('the stream is immune to a STALE cached length (it stops on an empty '
        'READ, not at _length)', () async {
      // _length says 2 but the LOB really holds 6 units: read() would stop
      // short, the stream must deliver everything the server sends.
      final (conn, t, lob) = await _fetchLob(_clob(2));
      t.lobReadReplies.addAll([
        (data: Uint8List.fromList(utf8.encode('abc')), amount: 3),
        (data: Uint8List.fromList(utf8.encode('def')), amount: 3),
      ]);
      expect(await lob.textStream(pieceSize: 3).toList(), equals(['abc', 'def']));
      await lob.close();
    });

    test('pieceSize defaults to chunkSize, and to the documented constant when '
        'chunkSize is 0', () async {
      final (conn, t, lob) = await _fetchLob(_clob(3)); // chunkSize 8132
      t.lobReadReplies
          .add((data: Uint8List.fromList(utf8.encode('abc')), amount: 3));
      await lob.textStream().toList();
      expect(t.readRequests.first.amount, equals(8132));
      await lob.close();

      final (conn2, t2, nclob) = await _fetchLob(_nclob(2)); // chunkSize 0
      t2.lobReadReplies.add((data: encodeUtf16Be('hi'), amount: 2));
      await nclob.textStream().toList();
      expect(t2.readRequests.first.amount, equals(defaultLobStreamPieceSize));
      await nclob.close();
    });

    group('synchronous validation (never a delayed stream error)', () {
      test('textStream on a BLOB throws StateError at the call site', () async {
        final (conn, t, blob) = await _fetchLob(_blob(4));
        expect(() => blob.textStream(), throwsStateError);
        expect(t.lobReadCalls, equals(0));
        await blob.close();
      });

      test('byteStream on a CLOB/NCLOB throws StateError at the call site',
          () async {
        final (conn, t, lob) = await _fetchLob(_clob(4));
        expect(() => lob.byteStream(), throwsStateError);
        final (conn2, t2, nclob) = await _fetchLob(_nclob(4));
        expect(() => nclob.byteStream(), throwsStateError);
        expect(t.lobReadCalls, equals(0));
        await lob.close();
        await nclob.close();
      });

      test('a non-positive offset or pieceSize throws ArgumentError at the call '
          'site', () async {
        final (conn, t, lob) = await _fetchLob(_clob(4));
        expect(() => lob.textStream(offset: 0), throwsArgumentError);
        expect(() => lob.textStream(offset: -1), throwsArgumentError);
        expect(() => lob.textStream(pieceSize: 0), throwsArgumentError);
        expect(() => lob.textStream(pieceSize: -5), throwsArgumentError);
        final (conn2, t2, blob) = await _fetchLob(_blob(4));
        expect(() => blob.byteStream(offset: 0), throwsArgumentError);
        expect(() => blob.byteStream(pieceSize: 0), throwsArgumentError);
        expect(t.lobReadCalls, equals(0));
        await lob.close();
        await blob.close();
      });

      test('a closed handle throws at the call site, before any stream exists',
          () async {
        final (conn, t, lob) = await _fetchLob(_clob(4));
        await lob.close();
        expect(
          () => lob.textStream(),
          throwsA(isA<OracleException>()
              .having((e) => e.message, 'message', contains('closed'))),
        );
      });

      test('a broken connection throws at the call site', () async {
        final (conn, t, lob) = await _fetchLob(_clob(4));
        t.connected = false;
        expect(
          () => lob.textStream(),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraConnectionClosed)),
        );
      });
    });

    test('closing the handle MID-stream fails the stream loud rather than '
        'truncating it silently', () async {
      final (conn, t, lob) = await _fetchLob(_clob(9));
      t.lobReadReplies.addAll([
        (data: Uint8List.fromList(utf8.encode('abc')), amount: 3),
        (data: Uint8List.fromList(utf8.encode('def')), amount: 3),
      ]);
      final seen = <String>[];
      await expectLater(
        () async {
          await for (final piece in lob.textStream(pieceSize: 3)) {
            seen.add(piece);
            await lob.close(); // pulled out from under the live stream
          }
        }(),
        throwsA(isA<OracleException>()
            .having((e) => e.message, 'message', contains('closed'))),
      );
      expect(seen, equals(['abc']));
    });

    test('losing the connection MID-stream fails the stream loud', () async {
      final (conn, t, lob) = await _fetchLob(_blob(9));
      t.lobReadReplies.addAll([
        (data: Uint8List.fromList([1, 2, 3]), amount: 3),
        (data: Uint8List.fromList([4, 5, 6]), amount: 3),
      ]);
      await expectLater(
        () async {
          await for (final _ in lob.byteStream(pieceSize: 3)) {
            t.connected = false;
          }
        }(),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraConnectionClosed)),
      );
    });

    test('cancelling mid-stream leaves the connection immediately reusable',
        () async {
      final (conn, t, lob) = await _fetchLob(_clob(12));
      t.lobReadReplies.addAll([
        (data: Uint8List.fromList(utf8.encode('abc')), amount: 3),
        (data: Uint8List.fromList(utf8.encode('def')), amount: 3),
        (data: Uint8List.fromList(utf8.encode('ghi')), amount: 3),
      ]);
      final received = <String>[];
      final sub = lob.textStream(pieceSize: 3).listen(received.add);
      // Let one piece through, then cancel.
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(received, isNotEmpty);
      // No stuck in-flight flag, no half-read state.
      expect(conn.isExecuting, isFalse);
      await lob.close();
      final ok = await conn.execute('SELECT 1 FROM dual');
      expect(ok.rows, isEmpty); // the fake returns a bare successful response
    });

    test('an overlapping operation is rejected per piece via the LOB bracket',
        () async {
      final (conn, t, lob) = await _fetchLob(_clob(6));
      t.lobReadReplies.addAll([
        (data: Uint8List.fromList(utf8.encode('abc')), amount: 3),
        (data: Uint8List.fromList(utf8.encode('def')), amount: 3),
      ]);
      await expectLater(
        () async {
          await for (final _ in lob.textStream(pieceSize: 3)) {
            // A second LOB op while this piece's yield is pending is fine (the
            // bracket has already cleared), but an execute() is still rejected
            // because the handle holds the connection's slot.
            await conn.execute('SELECT 1 FROM dual');
          }
        }(),
        throwsA(isA<OracleException>()
            .having((e) => e.message, 'message', contains('OracleLob'))),
      );
      await lob.close();
    });

    group('character-boundary correctness', () {
      test('a UTF-16 piece boundary splitting a surrogate pair is joined, and '
          'the concatenation is exact', () async {
        // 'A' + U+1F600 + 'B' == 4 UCS-2 units. Measured server behavior: a READ
        // for 2 units at offset 1 returns 'A' plus the LONE HIGH SURROGATE as raw
        // UTF-16BE bytes (00 41 d8 3d), and the next READ returns the low
        // surrogate. A naive per-piece emit would hand the caller half a
        // character.
        const text = 'A\u{1F600}B';
        final all = encodeUtf16Be(text);
        final (conn, t, lob) = await _fetchLob(_nclob(4));
        t.lobReadReplies.addAll([
          (data: Uint8List.sublistView(all, 0, 4), amount: 2), // 'A' + high
          (data: Uint8List.sublistView(all, 4, 8), amount: 2), // low + 'B'
        ]);
        final pieces = await lob.textStream(pieceSize: 2).toList();
        expect(pieces.join(), equals(text), reason: 'concatenation is exact');
        // The high surrogate was held back, so no emitted piece ends mid-pair.
        expect(pieces.first, equals('A'));
        expect(pieces[1], equals('\u{1F600}B'));
        await lob.close();
      });

      test('a UTF-8 piece boundary splitting a multi-byte sequence is joined',
          () async {
        // 'caf\u{00E9}' — U+00E9 is 2 UTF-8 bytes; split between them.
        const text = 'caf\u{00E9}';
        final all = Uint8List.fromList(utf8.encode(text));
        final (conn, t, lob) = await _fetchLob(_clob(4));
        t.lobReadReplies.addAll([
          (data: Uint8List.sublistView(all, 0, 4), amount: 3),
          (data: Uint8List.sublistView(all, 4, 5), amount: 1),
        ]);
        final pieces = await lob.textStream(pieceSize: 3).toList();
        expect(pieces.join(), equals(text));
        expect(pieces.first, equals('caf'),
            reason: 'the half sequence is held back, never emitted');
        await lob.close();
      });

      test('a UTF-8 boundary splitting a 4-byte (supplemental) sequence is '
          'joined', () async {
        const text = 'x\u{1F600}y';
        final all = Uint8List.fromList(utf8.encode(text)); // 1 + 4 + 1 bytes
        final (conn, t, lob) = await _fetchLob(_clob(4));
        t.lobReadReplies.addAll([
          (data: Uint8List.sublistView(all, 0, 3), amount: 2),
          (data: Uint8List.sublistView(all, 3, 6), amount: 2),
        ]);
        expect((await lob.textStream(pieceSize: 2).toList()).join(),
            equals(text));
        await lob.close();
      });

      test('a LOB that really ENDS with an unpaired high surrogate still emits '
          'it, so the stream matches read()', () async {
        final all = encodeUtf16Be('A\u{D83D}'); // deliberately unpaired
        final (conn, t, lob) = await _fetchLob(_nclob(2));
        t.lobReadReplies.add((data: all, amount: 2));
        final pieces = await lob.textStream(pieceSize: 2).toList();
        expect(pieces.join().codeUnits, equals([0x41, 0xD83D]));
        await lob.close();
      });

      test('a straddled surrogate pair makes a piece EXCEED pieceSize and span '
          'more than one READ (the documented carry-over exceptions)', () async {
        // The dartdoc's two exceptions to "pieces of at most pieceSize units,
        // one READ per piece" — both are the price of an exact concatenation, so
        // pin them rather than leave the contract text unverifiable.
        const text = '\u{1F600}A';
        final all = encodeUtf16Be(text); // 3 UCS-2 units, 6 bytes
        final (conn, t, lob) = await _fetchLob(_nclob(3));
        t.lobReadReplies.addAll([
          (data: Uint8List.sublistView(all, 0, 2), amount: 1), // high surrogate
          (data: Uint8List.sublistView(all, 2, 4), amount: 1), // low surrogate
          (data: Uint8List.sublistView(all, 4, 6), amount: 1), // 'A'
        ]);
        final pieces = await lob.textStream(pieceSize: 1).toList();
        expect(pieces.join(), equals(text), reason: 'concatenation is exact');
        // READ 1's whole payload was held back, so it emitted NOTHING and READ 2
        // emitted a piece built from both round trips...
        expect(pieces, equals(['\u{1F600}', 'A']));
        // ...which is 2 UCS-2 units against a pieceSize of 1.
        expect(pieces.first.length, equals(2),
            reason: 'a straddled supplemental character exceeds pieceSize by one '
                'UCS-2 code unit');
        // 3 data READs + the terminating empty one, for only 2 emitted pieces —
        // i.e. reads != pieces + 1 in this shape.
        expect(t.lobReadCalls, equals(4));
        await lob.close();
      });

      test('bytes that can never complete a character fail loud (no U+FFFD '
          'substitution, no silent truncation)', () async {
        final (conn, t, lob) = await _fetchLob(_clob(4));
        // 0xFF is not a valid UTF-8 lead byte and can never be completed.
        t.lobReadReplies.add((data: Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF]), amount: 4));
        await expectLater(
          lob.textStream(pieceSize: 4).toList(),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('malformed'))),
        );
        await lob.close();
      });

      test('a piece that returns DATA but reports zero units fails loud instead '
          'of spinning forever', () async {
        // Never observed live (a 0-unit reply always comes with an empty payload,
        // i.e. end of LOB), so this bounded backstop needs a fake to reach.
        final (conn, t, lob) = await _fetchLob(_clob(6));
        t.lobReadReplies
            .add((data: Uint8List.fromList(utf8.encode('abc')), amount: 0));
        await expectLater(
          lob.textStream(pieceSize: 3).toList(),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message',
                  contains('stream made no progress'))),
        );
        expect(t.lobReadCalls, equals(1), reason: 'bounded: no second READ');
        await lob.close();

        final (conn2, t2, blob) = await _fetchLob(_blob(6));
        t2.lobReadReplies
            .add((data: Uint8List.fromList([1, 2, 3]), amount: 0));
        await expectLater(
          blob.byteStream(pieceSize: 3).toList(),
          throwsA(isA<OracleException>().having(
              (e) => e.message, 'message', contains('stream made no progress'))),
        );
        expect(t2.lobReadCalls, equals(1));
        await blob.close();
      });

      // Epic 12 integration review iteration 3. Iteration 2 made both halves of
      // an internally inconsistent READ reply fail loud in `readLobRange` (the
      // LOOPING seam), but the per-piece stream seam shares the identical wire
      // hazard — `amount` comes from RETURN_PARAMETER and the payload from
      // separate LOB_DATA messages — and had neither check, so both failure
      // shapes were still silent there. Safe to guard on both fixtures: the
      // MEASURED end-of-LOB reply is `amount: 0` with no payload, which stays
      // termination.
      test('a piece reporting UNITS with an EMPTY payload fails loud instead of '
          'silently TRUNCATING the stream', () async {
        // The mirror image of the sibling above: without the guard
        // `piece.bytes.isEmpty` alone ends the stream, so the caller gets a
        // short value and a successful completion — silently wrong data.
        final (conn, t, lob) = await _fetchLob(_clob(9));
        t.lobReadReplies.addAll([
          (data: Uint8List.fromList(utf8.encode('abc')), amount: 3),
          (data: null, amount: 3), // units claimed, nothing shipped
        ]);
        final seen = <String>[];
        await expectLater(
          () async {
            await for (final piece in lob.textStream(pieceSize: 3)) {
              seen.add(piece);
            }
          }(),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having(
                  (e) => e.message,
                  'message',
                  allOf(contains('internally inconsistent'),
                      contains('no payload bytes')))),
        );
        expect(seen, equals(['abc']),
            reason: 'the prefix already delivered is not retracted');
        expect(t.lobReadCalls, equals(2), reason: 'bounded: no third READ');
        await lob.close();

        final (conn2, t2, blob) = await _fetchLob(_blob(9));
        t2.lobReadReplies.addAll([
          (data: Uint8List.fromList([1, 2, 3]), amount: 3),
          (data: Uint8List(0), amount: 2), // empty payload, units claimed
        ]);
        await expectLater(
          blob.byteStream(pieceSize: 3).toList(),
          throwsA(isA<OracleException>().having((e) => e.message, 'message',
              contains('internally inconsistent'))),
        );
        expect(t2.lobReadCalls, equals(2));
        await blob.close();
      });

      test('a piece reporting MORE units than it requested fails loud instead '
          'of leaving a silent HOLE in the value', () async {
        // An over-reported amount advances the next piece's offset past units
        // that were never delivered, so the stream would skip data and still
        // report success. Mirrors `readLobRange`'s `delivered > request` guard.
        final (conn, t, lob) = await _fetchLob(_clob(12));
        t.lobReadReplies.addAll([
          (data: Uint8List.fromList(utf8.encode('abc')), amount: 3),
          (data: Uint8List.fromList(utf8.encode('def')), amount: 5), // > 3
        ]);
        await expectLater(
          lob.textStream(pieceSize: 3).toList(),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having(
                  (e) => e.message,
                  'message',
                  allOf(contains('overshot'), contains('only 3 were '
                      'requested')))),
        );
        expect(t.lobReadCalls, equals(2));
        await lob.close();

        final (conn2, t2, blob) = await _fetchLob(_blob(12));
        t2.lobReadReplies
            .add((data: Uint8List.fromList([1, 2]), amount: 4)); // > 2
        await expectLater(
          blob.byteStream(pieceSize: 2).toList(),
          throwsA(isA<OracleException>()
              .having((e) => e.message, 'message', contains('overshot'))),
        );
        expect(t2.lobReadCalls, equals(1), reason: 'fails on the FIRST piece');
        await blob.close();
      });

      test('a piece reporting EXACTLY what it requested is accepted (negative '
          'control for the overshoot guard)', () async {
        final (conn, t, lob) = await _fetchLob(_clob(6));
        t.lobReadReplies.addAll([
          (data: Uint8List.fromList(utf8.encode('abc')), amount: 3),
          (data: Uint8List.fromList(utf8.encode('def')), amount: 3),
        ]);
        expect(await lob.textStream(pieceSize: 3).toList(),
            equals(['abc', 'def']));
        await lob.close();
      });

      test('a reply that OMITS the SB8 amount still streams (the guards only '
          'act on a reported count)', () async {
        // `amount: null` is the missing-SB8 shape; the byte-derived fallback
        // takes over and neither new guard can fire on it.
        final (conn, t, blob) = await _fetchLob(_blob(4));
        t.lobReadReplies.addAll([
          (data: Uint8List.fromList([1, 2]), amount: null),
          (data: Uint8List.fromList([3, 4]), amount: null),
        ]);
        expect(
          (await blob.byteStream(pieceSize: 2).toList())
              .map((p) => p.toList())
              .toList(),
          equals([
            [1, 2],
            [3, 4]
          ]),
        );
        expect(t.readRequests.map((r) => r.offset).toList(),
            equals([1, 3, 5]), reason: 'advanced by the delivered byte count');
        await blob.close();
      });

      test('a stream that ends mid-character fails loud rather than dropping '
          'the partial bytes', () async {
        final (conn, t, lob) = await _fetchLob(_clob(4));
        // A lone lead byte of a 2-byte sequence, then end of LOB.
        t.lobReadReplies.add((data: Uint8List.fromList([0x63, 0xC3]), amount: 2));
        await expectLater(
          lob.textStream(pieceSize: 2).toList(),
          throwsA(isA<OracleException>()
              .having((e) => e.message, 'message', contains('mid-character'))),
        );
        await lob.close();
      });
    });
  });

  // -------------------------------------------------------------------------
  // Story 12.3 AC3 — writeStream()
  // -------------------------------------------------------------------------
  group('OracleLob.writeStream (AC3)', () {
    test('writes one WRITE per chunk at the running offset and returns the '
        'total units', () async {
      final (conn, t, lob) = await _fetchLob(_clob(0));
      final total = await lob.writeStream(
        Stream<Object>.fromIterable(const ['abc', 'de', 'fghi']),
      );
      expect(total, equals(9));
      expect(t.lobWriteCalls, equals(3));
      expect(lob.length, equals(9)); // max(0, (1-1) + 9)
      expect(t.lastWriteOffset, equals(6)); // chunk 3 at 1 + 3 + 2
      await lob.close();
    });

    test('honors a non-1 start offset in the running arithmetic', () async {
      final (conn, t, lob) = await _fetchLob(_clob(0));
      final total = await lob.writeStream(
        Stream<Object>.fromIterable(const ['ab', 'cd']),
        offset: 5,
      );
      expect(total, equals(4));
      expect(t.lastWriteOffset, equals(7)); // 5 + 2
      expect(lob.length, equals(8)); // (5 - 1) + 4
      await lob.close();
    });

    test('an empty chunk is skipped with NO round trip; an empty stream writes '
        'nothing and returns 0', () async {
      final (conn, t, lob) = await _fetchLob(_clob(0));
      expect(
        await lob.writeStream(
          Stream<Object>.fromIterable(const ['a', '', 'b']),
        ),
        equals(2),
      );
      expect(t.lobWriteCalls, equals(2));
      expect(await lob.writeStream(const Stream<Object>.empty()), equals(0));
      expect(t.lobWriteCalls, equals(2), reason: 'no extra round trip');
      await lob.close();
    });

    test('a BLOB stream writes bytes and counts them', () async {
      final (conn, t, blob) = await _fetchLob(_blob(0));
      final total = await blob.writeStream(
        Stream<Object>.fromIterable(<Object>[
          Uint8List.fromList([1, 2, 3]),
          const <int>[4, 5],
        ]),
      );
      expect(total, equals(5));
      expect(t.lobWriteCalls, equals(2));
      expect(blob.length, equals(5));
      await blob.close();
    });

    test('a surrogate pair split across two chunks is JOINED, not corrupted '
        '(the driver owns this boundary)', () async {
      final (conn, t, lob) = await _fetchLob(_clob(0));
      // Chunk 1 ends with the high surrogate, chunk 2 opens with the low one.
      const high = '\u{D83D}';
      const low = '\u{DE00}';
      final total = await lob.writeStream(
        Stream<Object>.fromIterable(const <Object>['A$high', '${low}B']),
      );
      expect(total, equals(4)); // 'A' + 2 pair units + 'B'
      // The first WRITE shipped only 'A' (the high surrogate was held back), and
      // the second shipped the WHOLE pair plus 'B' — so no U+FFFD anywhere.
      expect(t.lobWriteCalls, equals(2));
      expect(t.lastWriteData, equals(utf8.encode('\u{1F600}B')));
      expect(lob.length, equals(4));
      await lob.close();
    });

    test('a surrogate still unpaired at END of stream keeps write()\'s '
        'documented leniency', () async {
      final (conn, t, lob) = await _fetchLob(_clob(0));
      const high = '\u{D83D}';
      final total = await lob.writeStream(
        Stream<Object>.fromIterable(const <Object>['A$high']),
      );
      expect(total, equals(2));
      // Two WRITEs: 'A', then the lone surrogate through write() unchanged —
      // UTF-8 substitutes U+FFFD exactly as write() documents. Not rejected.
      expect(t.lobWriteCalls, equals(2));
      expect(t.lastWriteData, equals(utf8.encode(high)));
      await lob.close();
    });

    test('an NCLOB chunk join also stitches the pair (UTF-16BE form)', () async {
      final (conn, t, lob) = await _fetchLob(_nclob(0));
      const high = '\u{D83D}';
      const low = '\u{DE00}';
      final total = await lob.writeStream(
        Stream<Object>.fromIterable(const <Object>['A$high', '${low}B']),
      );
      expect(total, equals(4));
      expect(t.lastWriteData, equals(encodeUtf16Be('\u{1F600}B')));
      await lob.close();
    });

    test('offset <= 0 throws ArgumentError SYNCHRONOUSLY at the call site, '
        'before any round trip', () async {
      final (conn, t, lob) = await _fetchLob(_clob(0));
      // Deliberately `expect(() => …)` and not `expectLater(future, …)`: the
      // method must not be `async`, or API misuse arrives as a rejected future
      // (and an un-awaited call as an unhandled async error) instead of at the
      // call site — same shape as textStream/byteStream above.
      expect(
        () => lob.writeStream(Stream<Object>.fromIterable(const ['a']),
            offset: 0),
        throwsArgumentError,
      );
      expect(
        () => lob.writeStream(Stream<Object>.fromIterable(const ['a']),
            offset: -7),
        throwsArgumentError,
      );
      expect(t.lobWriteCalls, equals(0));
      await lob.close();
      // A closed handle likewise fails at the call site, not through the future.
      expect(
        () => lob.writeStream(Stream<Object>.fromIterable(const ['a'])),
        throwsA(isA<OracleException>()),
      );
    });

    test('a wrong-typed chunk throws ArgumentError from write(), aborts the '
        'rest, and leaves earlier chunks written', () async {
      final (conn, t, lob) = await _fetchLob(_clob(0));
      await expectLater(
        lob.writeStream(
          Stream<Object>.fromIterable(<Object>['ok', 42, 'never']),
        ),
        throwsArgumentError,
      );
      expect(t.lobWriteCalls, equals(1), reason: 'first chunk landed');
      expect(lob.length, equals(2), reason: 'not atomic: partial data stays');
      // The connection is not wedged.
      expect(conn.isExecuting, isFalse);
      await lob.close();
      final ok = await conn.execute('SELECT 1 FROM dual');
      expect(ok.rows, isEmpty); // the fake returns a bare successful response
    });

    // Epic 12 integration review iteration 2 (Low): the carry-then-ABORT
    // interaction. The wrong-typed-chunk test above uses chunks that never create
    // a carry, so the documented off-by-one-code-unit at the abort boundary was
    // both unhandled and untested. Pins the DOCUMENTED behaviour (see
    // writeStream's "one code unit short" bullet): the held-back high surrogate
    // from the last written chunk is discarded, never flushed onto a failing
    // stream, and the caller always gets the exception.
    test('an aborted CLOB stream DISCARDS the surrogate carry held back from '
        'the last written chunk (documented, one code unit short)', () async {
      final (conn, t, lob) = await _fetchLob(_clob(0));
      const high = '\u{D83D}';
      await expectLater(
        // Chunk 1 ends with an unpaired high surrogate (held back, so only 'A'
        // is written); chunk 2 is wrong-typed, so write() throws before the carry
        // can be prepended, consumed, or flushed.
        lob.writeStream(Stream<Object>.fromIterable(<Object>['A$high', 42])),
        throwsArgumentError,
      );
      // Exactly one WRITE, carrying 'A' only — the carry never reached the wire
      // and no extra flush WRITE was attempted on the failing stream.
      expect(t.lobWriteCalls, equals(1));
      expect(t.lastWriteData, equals(utf8.encode('A')));
      expect(lob.length, equals(1),
          reason: 'the written prefix is one UTF-16 code unit short of the '
              'chunk the caller emitted — the documented abort boundary');
      expect(conn.isExecuting, isFalse);
      await lob.close();
    });

    test('a source-stream ERROR also discards the surrogate carry', () async {
      final (conn, t, lob) = await _fetchLob(_clob(0));
      const high = '\u{D83D}';
      // A lazy source: nothing runs until writeStream subscribes, so the error
      // arrives strictly after chunk 1's WRITE — the abort boundary under test.
      Stream<Object> failing() async* {
        yield 'A$high';
        throw StateError('source failed');
      }

      await expectLater(
        lob.writeStream(failing()),
        throwsA(isA<StateError>()),
      );
      expect(t.lobWriteCalls, equals(1));
      expect(t.lastWriteData, equals(utf8.encode('A')));
      expect(lob.length, equals(1));
      expect(conn.isExecuting, isFalse);
      await lob.close();
    });

    test('a BLOB chunk with an out-of-range element throws from write()',
        () async {
      final (conn, t, blob) = await _fetchLob(_blob(0));
      await expectLater(
        blob.writeStream(
          Stream<Object>.fromIterable(<Object>[
            const <int>[1, 2],
            const <int>[300],
          ]),
        ),
        throwsArgumentError,
      );
      expect(t.lobWriteCalls, equals(1));
      await blob.close();
    });

    test('a server error mid-stream propagates and does not wedge the '
        'in-flight flag', () async {
      final (conn, t, lob) = await _fetchLob(_clob(0));
      t.failOperations.add(tnsLobOpWrite);
      await expectLater(
        lob.writeStream(Stream<Object>.fromIterable(const ['abc'])),
        throwsA(isA<OracleException>()),
      );
      expect(conn.isExecuting, isFalse);
      // The handle stays usable: a later successful write still works.
      t.failOperations.clear();
      await lob.write(1, 'ok');
      await lob.close();
    });

    test('a closed handle throws before consuming the stream', () async {
      final (conn, t, lob) = await _fetchLob(_clob(0));
      await lob.close();
      // Synchronous at the call site (writeStream is a non-async wrapper), not a
      // rejected future — the whole point of the AC3 validation shape.
      expect(
        () => lob.writeStream(Stream<Object>.fromIterable(const ['a'])),
        throwsA(isA<OracleException>()
            .having((e) => e.message, 'message', contains('closed'))),
      );
      expect(t.lobWriteCalls, equals(0));
    });
  });
}

/// Whether [haystack] contains [needle] as a contiguous subsequence.
bool _containsSubsequence(Uint8List haystack, Uint8List needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
