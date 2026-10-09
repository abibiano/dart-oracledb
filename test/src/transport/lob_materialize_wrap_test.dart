/// Unit coverage for the `fetchLobs` wrap path threaded through
/// [Transport.materializeLobs] (Story 12.1, Epic 11 retro action item 2) and for
/// the chunked read-continuation loop behind every LOB read
/// ([Transport.readLobRange], Story 12.3 AC1).
///
/// When a `wrapLob` callback is supplied, every [LobLocator] — in result rows,
/// OUT-bind values, OUT-bind rows (PL/SQL scalar shape AND DML RETURNING nested
/// shape) — must be replaced by whatever the callback returns, with NO LOB READ
/// round trip issued (the callback never reads). The connection layer feeds the
/// same callback to the implicit-result drain, which reaches this exact code via
/// the `rows` shape, so the four transport shapes below cover every entry point.
library;

import 'dart:typed_data';

import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'package:oracledb/src/protocol/lob_locator.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/protocol/messages/lob_op_message.dart';
import 'package:oracledb/src/protocol/oson.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

/// Marker returned by the test `wrapLob` callback in place of a locator.
class _WrapMarker {
  _WrapMarker(this.locator);
  final LobLocator locator;
}

LobLocator _clob(int length) => LobLocator(
  locator: Uint8List(tnsLobLocatorBufferSize),
  oracleType: oraTypeClob,
  length: length,
  chunkSize: 0,
);

/// A FETCHED locator whose flag byte 4 carries the TEMP bit — the shape an
/// `IN OUT` LOB bind's server-returned OUT locator was measured to have on both
/// Oracle 23ai and 21c (Story 12.4 AC4). `isTemporary` is derived from the
/// bytes, NOT passed to the constructor, so this exercises the same read path
/// production does.
LobLocator _fetchedTempLocator({
  required int oracleType,
  required int length,
  int? tag,
}) {
  final bytes = Uint8List(tnsLobLocatorBufferSize);
  bytes[tnsLobLocOffsetFlag4] |= tnsLobLocFlagsTemp;
  // A distinguishing byte so two locators are not byte-identical (the queue
  // stores raw bytes; identity assertions must not depend on content equality).
  if (tag != null) bytes[0] = tag;
  final loc = LobLocator(
    locator: bytes,
    oracleType: oracleType,
    length: length,
    chunkSize: 0,
  );
  // Guard the fixture itself: if this ever stops reporting temporary, every
  // assertion below would pass vacuously.
  expect(
    loc.isTemporary,
    isTrue,
    reason: 'fixture must carry the TEMP flag bit',
  );
  return loc;
}

/// A FETCHED locator with no flag bits set (a plain table row locator — measured
/// non-temporary on both fixtures).
LobLocator _fetchedPlainLocator({
  required int oracleType,
  required int length,
}) {
  final loc = LobLocator(
    locator: Uint8List(tnsLobLocatorBufferSize),
    oracleType: oracleType,
    length: length,
    chunkSize: 0,
  );
  expect(loc.isTemporary, isFalse);
  return loc;
}

/// A [Transport] whose `sendLobOp` replays a queue of canned READ replies.
///
/// Live servers never short-read on demand (measured: no size up to 32 MB on
/// 23ai or 8 MB on 21c splits a READ), so a deterministic short `amount` is the
/// only way to exercise [Transport.readLobRange]'s continuation loop at all —
/// every continuation test here fails without it.
class _ChunkedReadTransport extends Transport {
  _ChunkedReadTransport(this.replies);

  final List<({Uint8List? data, int? amount})> replies;
  final List<({int offset, int amount})> requests =
      <({int offset, int amount})>[];

  /// Echoed as each reply's `updatedLocator`, so the post-op copy-back can be
  /// asserted per piece.
  Uint8List? echoLocator;

  int _next = 0;

  @override
  bool get isConnected => true;

  @override
  bool get isCorrupted => false;

  @override
  Future<void> disconnect() async {}

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
    expect(operation, equals(tnsLobOpRead));
    expect(sendAmount, isTrue, reason: 'the SB8 unit count is load-bearing');
    requests.add((offset: sourceOffset, amount: amount));
    if (_next >= replies.length) {
      return LobOpResponse(isSuccess: true, amount: 0);
    }
    final reply = replies[_next++];
    return LobOpResponse(
      isSuccess: true,
      data: reply.data,
      amount: reply.amount,
      updatedLocator: echoLocator,
    );
  }
}

void main() {
  group('materializeLobs wrapLob threading', () {
    late Transport transport;
    late List<LobLocator> wrapped;
    Object wrap(LobLocator l) {
      wrapped.add(l);
      return _WrapMarker(l);
    }

    setUp(() {
      // An UNCONNECTED transport is safe here: the wrap path issues no wire
      // traffic (it never calls sendLobOp). A locator materialized instead of
      // wrapped WOULD hit the socket and throw — so a clean wrap proves no read.
      transport = Transport();
      wrapped = <LobLocator>[];
    });

    test('wraps LOB locators in result rows', () async {
      final loc = _clob(3);
      final response = ExecuteResponse(
        isSuccess: true,
        rows: [
          [loc, 'other'],
        ],
      );
      final out = await transport.materializeLobs(response, wrapLob: wrap);
      expect(out.rows.single[0], isA<_WrapMarker>());
      expect((out.rows.single[0] as _WrapMarker).locator, same(loc));
      expect(out.rows.single[1], equals('other'));
      expect(wrapped, hasLength(1));
    });

    test('wraps LOB locators in OUT-bind values', () async {
      final loc = _clob(3);
      final response = ExecuteResponse(
        isSuccess: true,
        outBindValues: [loc],
        outBindIndices: const [0],
      );
      final out = await transport.materializeLobs(response, wrapLob: wrap);
      expect(out.outBindValues.single, isA<_WrapMarker>());
      expect(wrapped, hasLength(1));
    });

    test('wraps LOB locators in OUT-bind rows (PL/SQL scalar shape)', () async {
      final loc = _clob(3);
      final response = ExecuteResponse(
        isSuccess: true,
        outBindRows: [
          [loc],
        ],
        outBindIndices: const [0],
      );
      final out = await transport.materializeLobs(response, wrapLob: wrap);
      expect(out.outBindRows.single.single, isA<_WrapMarker>());
      expect(wrapped, hasLength(1));
    });

    test(
      'wraps LOB locators in OUT-bind rows (DML RETURNING nested shape)',
      () async {
        final loc = _clob(3);
        final response = ExecuteResponse(
          isSuccess: true,
          outBindRows: [
            [
              [loc], // one return bind's list of returned values
            ],
          ],
          outBindIndices: const [0],
        );
        final out = await transport.materializeLobs(
          response,
          dmlReturning: true,
          wrapLob: wrap,
        );
        final cell = out.outBindRows.single.single as List<Object?>;
        expect(cell.single, isA<_WrapMarker>());
        expect(wrapped, hasLength(1));
      },
    );

    test('skips the OUT-bind maxSize guard when wrapping (a handle '
        'materializes nothing)', () async {
      // length 999 far exceeds the declared maxSize 1: on the MATERIALIZE path
      // this throws; on the WRAP path it must not.
      final loc = _clob(999);
      final response = ExecuteResponse(
        isSuccess: true,
        outBindValues: [loc],
        outBindIndices: const [0],
      );
      const meta = [
        BindMetadata(oraType: oraTypeClob, dir: BindDir.output, maxSize: 1),
      ];
      final out = await transport.materializeLobs(
        response,
        bindMetadata: meta,
        wrapLob: wrap,
      );
      expect(out.outBindValues.single, isA<_WrapMarker>());
    });

    test(
      'the same guard DOES throw on the materialize path (no wrapLob)',
      () async {
        final loc = _clob(999);
        final response = ExecuteResponse(
          isSuccess: true,
          outBindValues: [loc],
          outBindIndices: const [0],
        );
        const meta = [
          BindMetadata(oraType: oraTypeClob, dir: BindDir.output, maxSize: 1),
        ];
        await expectLater(
          transport.materializeLobs(response, bindMetadata: meta),
          throwsA(
            isA<OracleException>().having(
              (e) => e.errorCode,
              'errorCode',
              oraBindTypeError,
            ),
          ),
        );
      },
    );

    test('an aliased locator is wrapped exactly once (dedup)', () async {
      final loc = _clob(3);
      final response = ExecuteResponse(
        isSuccess: true,
        rows: [
          [loc],
          [loc], // Oracle duplicate-column aliasing
        ],
      );
      final out = await transport.materializeLobs(response, wrapLob: wrap);
      expect(wrapped, hasLength(1), reason: 'one distinct locator');
      expect(identical(out.rows[0][0], out.rows[1][0]), isTrue);
    });

    test(
      'a locator-free response is returned unchanged with no wrapping',
      () async {
        final response = ExecuteResponse(
          isSuccess: true,
          rows: [
            [1, 'a'],
          ],
        );
        final out = await transport.materializeLobs(response, wrapLob: wrap);
        expect(out.rows.single, equals([1, 'a']));
        expect(wrapped, isEmpty);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Story 12.3 AC1 — the ONE shared read-continuation loop.
  //
  // `_readClobAsString`, `_readBlobAsBytes` and the connection's `runLobRead`
  // seam all route through `readLobRange`, so these tests pin the loop for every
  // caller at once. Each one fails without the loop (a single READ returns only
  // the first piece).
  // -------------------------------------------------------------------------
  group('Transport.readLobRange continuation (AC1)', () {
    final locator = Uint8List(tnsLobLocatorBufferSize);

    test(
      'keeps reading at the advanced offset until the requested units arrive',
      () async {
        final t = _ChunkedReadTransport([
          (data: Uint8List.fromList([1, 2, 3]), amount: 3),
          (data: Uint8List.fromList([4, 5]), amount: 2),
          (data: Uint8List.fromList([6, 7, 8]), amount: 3),
        ]);
        final read = await t.readLobRange(
          locator: locator,
          offset: 1,
          amount: 8,
        );
        expect(read.bytes, equals([1, 2, 3, 4, 5, 6, 7, 8]));
        expect(read.unitsRead, equals(8));
        expect(
          t.requests,
          equals([
            (offset: 1, amount: 8),
            (offset: 4, amount: 5),
            (offset: 6, amount: 3),
          ]),
        );
      },
    );

    test('a value that fits ONE round trip costs exactly one READ (fast path '
        'preserved byte-for-byte)', () async {
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([1, 2, 3, 4]), amount: 4),
      ]);
      final read = await t.readLobRange(locator: locator, offset: 1, amount: 4);
      expect(read.bytes, equals([1, 2, 3, 4]));
      expect(t.requests, hasLength(1));
      expect(t.requests.single, equals((offset: 1, amount: 4)));
    });

    test('honors a non-1 start offset across pieces', () async {
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([9]), amount: 1),
        (data: Uint8List.fromList([8]), amount: 1),
      ]);
      await t.readLobRange(locator: locator, offset: 7, amount: 2);
      expect(
        t.requests,
        equals([(offset: 7, amount: 2), (offset: 8, amount: 1)]),
      );
    });

    test('pieceUnits caps each READ request', () async {
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([1, 2]), amount: 2),
        (data: Uint8List.fromList([3, 4]), amount: 2),
        (data: Uint8List.fromList([5]), amount: 1),
      ]);
      final read = await t.readLobRange(
        locator: locator,
        offset: 1,
        amount: 5,
        pieceUnits: 2,
      );
      expect(read.bytes, equals([1, 2, 3, 4, 5]));
      expect(
        t.requests,
        equals([
          (offset: 1, amount: 2),
          (offset: 3, amount: 2),
          (offset: 5, amount: 1), // outstanding < pieceUnits
        ]),
      );
    });

    test('a piece reporting ZERO units with work outstanding throws instead of '
        'spinning', () async {
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([1, 2]), amount: 2),
        (data: null, amount: 0),
        (data: Uint8List.fromList([3]), amount: 1), // must never be reached
      ]);
      await expectLater(
        t.readLobRange(locator: locator, offset: 1, amount: 5),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('made no progress'),
                  contains('offset 3'),
                  contains('5 units'),
                ),
              ),
        ),
      );
      expect(t.requests, hasLength(2));
    });

    test('nothing delivered at all returns empty so the CALLER reports it '
        '("read returned no data", not a no-progress error)', () async {
      final t = _ChunkedReadTransport([(data: null, amount: 0)]);
      final read = await t.readLobRange(locator: locator, offset: 1, amount: 5);
      expect(read.bytes, isEmpty);
      expect(read.unitsRead, equals(0));
      expect(t.requests, hasLength(1));
    });

    test('a piece reporting MORE units than outstanding throws', () async {
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([1, 2, 3]), amount: 3),
      ]);
      await expectLater(
        t.readLobRange(locator: locator, offset: 1, amount: 2),
        throwsA(
          isA<OracleException>().having(
            (e) => e.message,
            'message',
            contains('overshot'),
          ),
        ),
      );
    });

    test('a reply that omits the SB8 amount is treated as satisfying the whole '
        'request (degrades to the pre-12.3 single READ)', () async {
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([1, 2]), amount: null),
        (data: Uint8List.fromList([3]), amount: null), // never requested
      ]);
      final read = await t.readLobRange(locator: locator, offset: 1, amount: 5);
      expect(read.bytes, equals([1, 2]), reason: 'short payload, one READ');
      expect(read.unitsRead, equals(5));
      expect(t.requests, hasLength(1));
    });

    test('a non-positive amount issues no round trip', () async {
      final t = _ChunkedReadTransport([]);
      final read = await t.readLobRange(locator: locator, offset: 1, amount: 0);
      expect(read.bytes, isEmpty);
      expect(read.unitsRead, equals(0));
      expect(t.requests, isEmpty);
    });

    test(
      'the server post-op locator echo is copied back after EVERY piece',
      () async {
        final live = Uint8List(tnsLobLocatorBufferSize);
        final t =
            _ChunkedReadTransport([
                (data: Uint8List.fromList([1]), amount: 1),
                (data: Uint8List.fromList([2]), amount: 1),
              ])
              ..echoLocator = Uint8List(tnsLobLocatorBufferSize)
              ..echoLocator!.fillRange(0, tnsLobLocatorBufferSize, 0x7E);
        await t.readLobRange(locator: live, offset: 1, amount: 2);
        expect(live, everyElement(equals(0x7E)));
      },
    );

    test('a differently-sized echo is ignored, never truncating the live '
        'locator', () async {
      final live = Uint8List(tnsLobLocatorBufferSize);
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([1]), amount: 1),
      ])..echoLocator = Uint8List.fromList([0xAB, 0xCD]);
      await t.readLobRange(locator: live, offset: 1, amount: 1);
      expect(live, everyElement(equals(0)));
      expect(live, hasLength(tnsLobLocatorBufferSize));
    });
  });

  // -------------------------------------------------------------------------
  // Story 12.4 AC4 — the MATERIALIZE path frees a TEMP-flagged locator.
  //
  // Under `fetchLobs: false` there is no `OracleLob` to own the locator: the
  // value is read into a String/Uint8List and the locator discarded, so a
  // server-allocated TEMPORARY LOB would leak session temp-LOB space until the
  // session ended (measured live: three `OracleBind.inOut(type: clob)` calls
  // grew V$TEMPORARY_LOBS 0 -> 1 -> 2 -> 3 on 23ai AND 21c). Each of these
  // fails without the `queueTempLobToFree` call in `_materializeLobValues`.
  //
  // The FLAG-THREADING audit (Epic 11 retro action item 2) is what the group
  // covers site by site: rows, scalar OUT-bind values, PL/SQL `outBindRows`, the
  // deeper DML-RETURNING nesting, the aliased duplicate-column locator, the
  // `wrapLob != null` path, and the non-temporary control.
  // -------------------------------------------------------------------------
  group('materializeLobs queues a TEMP-flagged materialized locator (AC4)', () {
    /// Replies with [length] bytes of BLOB payload, so `_readBlobAsBytes`
    /// completes its strict length check.
    _ChunkedReadTransport blobTransport(int length) => _ChunkedReadTransport([
      for (var i = 0; i < 4; i++)
        (
          data: Uint8List.fromList(
            List<int>.generate(length, (j) => (j + 1) & 0xFF),
          ),
          amount: length,
        ),
    ]);

    test('a scalar OUT-bind TEMP locator is queued exactly ONCE (the measured '
        'IN OUT shape)', () async {
      final t = blobTransport(3);
      final loc = _fetchedTempLocator(oracleType: oraTypeBlob, length: 3);
      expect(t.debugPendingTempLobCount, equals(0));
      final out = await t.materializeLobs(
        ExecuteResponse(
          isSuccess: true,
          outBindValues: [loc],
          outBindIndices: const [0],
        ),
      );
      // The observable materialized value is UNCHANGED — only the free-temp
      // queue accounting differs (AC4 overrides 12.2 AC7 / 12.3 AC6's
      // "byte-for-byte identical" mandate for the accounting, never the value).
      expect(out.outBindValues.single, equals([1, 2, 3]));
      expect(t.debugPendingTempLobCount, equals(1));
    });

    test('a TEMP locator in a result ROW is queued', () async {
      final t = blobTransport(2);
      final loc = _fetchedTempLocator(oracleType: oraTypeBlob, length: 2);
      final out = await t.materializeLobs(
        ExecuteResponse(
          isSuccess: true,
          rows: [
            [loc, 'other'],
          ],
        ),
      );
      expect(out.rows.single[0], equals([1, 2]));
      expect(out.rows.single[1], equals('other'));
      expect(t.debugPendingTempLobCount, equals(1));
    });

    test(
      'TEMP locators in outBindRows (PL/SQL scalar shape) are each queued',
      () async {
        final t = blobTransport(1);
        final a = _fetchedTempLocator(
          oracleType: oraTypeBlob,
          length: 1,
          tag: 1,
        );
        final b = _fetchedTempLocator(
          oracleType: oraTypeBlob,
          length: 1,
          tag: 2,
        );
        await t.materializeLobs(
          ExecuteResponse(
            isSuccess: true,
            outBindRows: [
              [a],
              [b],
            ],
            outBindIndices: const [0],
          ),
        );
        expect(
          t.debugPendingTempLobCount,
          equals(2),
          reason: 'two DISTINCT locators, one free each',
        );
      },
    );

    test(
      'a TEMP locator in the deeper DML-RETURNING nesting inherits the queue '
      '(not a second implementation)',
      () async {
        final t = blobTransport(1);
        final loc = _fetchedTempLocator(oracleType: oraTypeBlob, length: 1);
        await t.materializeLobs(
          ExecuteResponse(
            isSuccess: true,
            outBindRows: [
              [
                [loc],
              ],
            ],
            outBindIndices: const [0],
          ),
          dmlReturning: true,
        );
        expect(t.debugPendingTempLobCount, equals(1));
      },
    );

    test('an ALIASED TEMP locator (duplicate-column dedup) is queued at most '
        'ONCE per response', () async {
      final t = blobTransport(2);
      final loc = _fetchedTempLocator(oracleType: oraTypeBlob, length: 2);
      final out = await t.materializeLobs(
        ExecuteResponse(
          isSuccess: true,
          rows: [
            [loc],
            [loc], // Oracle aliases one locator instance into several rows
            [loc],
          ],
        ),
      );
      expect(
        t.debugPendingTempLobCount,
        equals(1),
        reason:
            'a double queue would send the same locator twice in one '
            'piggyback and surface as an error on an unrelated statement',
      );
      expect(t.requests, hasLength(1), reason: 'and it is read once too');
      expect(out.rows[0][0], equals(out.rows[2][0]));
    });

    // Story 12.4 AC4 SITE-AUDIT item 6: `ResultSetCursor`'s per-batch
    // `materializeLobs` and the eager drain call the same method, so both inherit
    // the fix — but nothing pinned "no per-batch double-queue". The per-response
    // `materialized` dedup map does NOT span calls, so a locator appearing in two
    // batches of one result set is presented twice; only the content dedupe
    // (`_tempLobKeysToClose`) keeps the queue at 1. Reachable because the queue
    // cannot drain between batches: draining needs a `sendExecute`, and an open
    // fetched handle / open result set means none happens.
    test('the SAME TEMP locator across two batches (two materializeLobs calls, '
        'no execute between) queues exactly ONCE', () async {
      final t = blobTransport(2);
      final loc = _fetchedTempLocator(oracleType: oraTypeBlob, length: 2);
      // Batch 1.
      final first = await t.materializeLobs(
        ExecuteResponse(
          isSuccess: true,
          rows: [
            [loc],
          ],
        ),
      );
      expect(first.rows.single.single, equals([1, 2]));
      expect(t.debugPendingTempLobCount, equals(1));
      // Batch 2 — a fresh response (fresh dedup map), same locator instance, as
      // Oracle's duplicate-column optimization can carry via
      // `_previousRoundLastRow`.
      final second = await t.materializeLobs(
        ExecuteResponse(
          isSuccess: true,
          rows: [
            [loc],
          ],
        ),
      );
      expect(second.rows.single.single, equals([1, 2]));
      expect(
        t.debugPendingTempLobCount,
        equals(1),
        reason:
            'a second queue would send the locator twice in ONE piggyback '
            'and surface as a double FREE_TEMP on an unrelated statement',
      );
    });

    test(
      'a NON-temporary locator queues nothing (table row / TO_CLOB / FOR '
      'UPDATE / TO_CLOB-literal PL-SQL-OUT shapes stay unaffected)',
      () async {
        final t = blobTransport(3);
        final loc = _fetchedPlainLocator(oracleType: oraTypeBlob, length: 3);
        final out = await t.materializeLobs(
          ExecuteResponse(
            isSuccess: true,
            rows: [
              [loc],
            ],
          ),
        );
        expect(out.rows.single.single, equals([1, 2, 3]));
        expect(t.debugPendingTempLobCount, equals(0));
      },
    );

    test('the WRAP path (fetchLobs: true) queues NOTHING — the handle frees it '
        'on close(), so queueing here would double-free', () async {
      // No canned replies: a wrap must issue no READ at all.
      final t = _ChunkedReadTransport([]);
      final loc = _fetchedTempLocator(oracleType: oraTypeBlob, length: 5);
      final out = await t.materializeLobs(
        ExecuteResponse(
          isSuccess: true,
          rows: [
            [loc],
          ],
        ),
        wrapLob: _WrapMarker.new,
      );
      expect(out.rows.single.single, isA<_WrapMarker>());
      expect(t.requests, isEmpty);
      expect(t.debugPendingTempLobCount, equals(0));
    });

    test(
      'a CLOB TEMP locator is queued too (the type only picks the decode)',
      () async {
        const text = 'temp clob out';
        final t = _ChunkedReadTransport([
          (data: Uint8List.fromList(text.codeUnits), amount: text.length),
        ]);
        final loc = _fetchedTempLocator(
          oracleType: oraTypeClob,
          length: text.length,
        );
        final out = await t.materializeLobs(
          ExecuteResponse(
            isSuccess: true,
            outBindValues: [loc],
            outBindIndices: const [0],
          ),
        );
        expect(out.outBindValues.single, equals(text));
        expect(t.debugPendingTempLobCount, equals(1));
      },
    );

    test('a ZERO-length TEMP locator issues NO READ yet is still queued (an '
        'empty temporary LOB is still a server resource)', () async {
      // `_readBlobAsBytes` short-circuits EMPTY_BLOB()/EMPTY_CLOB() before any
      // round trip, but the queue point sits AFTER it in `readLocator`, so the
      // free still lands. Pinned rather than assumed, because the two halves of
      // this boundary pull in opposite directions.
      final t = _ChunkedReadTransport([]);
      final loc = _fetchedTempLocator(oracleType: oraTypeBlob, length: 0);
      final out = await t.materializeLobs(
        ExecuteResponse(
          isSuccess: true,
          rows: [
            [loc],
          ],
        ),
      );
      expect(out.rows.single.single, isEmpty);
      expect(t.requests, isEmpty);
      expect(
        t.debugPendingTempLobCount,
        equals(1),
        reason:
            'the locator IS temporary and the materialize path discards '
            'it, so it still must be freed even though no READ was needed',
      );
    });

    // -----------------------------------------------------------------------
    // The free must be gated on "the read was ATTEMPTED", never on "the read
    // SUCCEEDED". Queueing only after a successful read re-opens the very leak
    // AC4 closed, on every read-failure path: the server-side temporary LOB
    // exists regardless of whether the driver managed to decode its content, and
    // once `readLocator` throws, the locator is discarded and nothing else can
    // ever free it. Each of these fails if the queue call is moved back below
    // the read.
    // -----------------------------------------------------------------------
    test('a TEMP locator whose READ returns no data is STILL queued', () async {
      // No canned replies => amount 0 on the first READ => readLobRange hands
      // back an empty result and `_readBlobAsBytes` throws its "returned no
      // data" guard.
      final t = _ChunkedReadTransport([]);
      final loc = _fetchedTempLocator(oracleType: oraTypeBlob, length: 3);
      await expectLater(
        t.materializeLobs(
          ExecuteResponse(
            isSuccess: true,
            rows: [
              [loc],
            ],
          ),
        ),
        throwsA(isA<OracleException>()),
      );
      expect(
        t.debugPendingTempLobCount,
        equals(1),
        reason:
            'the temp LOB exists server-side whether or not the read '
            'worked; gating the free on success leaks it until session end',
      );
    });

    test('a TEMP locator whose READ is SHORT (strict truncation guard) is '
        'still queued', () async {
      final t = _ChunkedReadTransport([
        // Declares 2 units delivered but the locator says 5 => the read
        // completes the loop and the caller's length verification throws.
        (data: Uint8List.fromList([1, 2]), amount: 5),
      ]);
      final loc = _fetchedTempLocator(oracleType: oraTypeBlob, length: 5);
      await expectLater(
        t.materializeLobs(
          ExecuteResponse(
            isSuccess: true,
            rows: [
              [loc],
            ],
          ),
        ),
        throwsA(isA<OracleException>()),
      );
      expect(t.debugPendingTempLobCount, equals(1));
    });

    test('a TEMP locator whose READ faults MID-continuation (no progress) is '
        'still queued', () async {
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([1, 2]), amount: 2),
        (data: null, amount: 0), // 0 units with 3 outstanding => fail loud
      ]);
      final loc = _fetchedTempLocator(oracleType: oraTypeBlob, length: 5);
      await expectLater(
        t.materializeLobs(
          ExecuteResponse(
            isSuccess: true,
            rows: [
              [loc],
            ],
          ),
        ),
        throwsA(
          isA<OracleException>().having(
            (e) => e.message,
            'message',
            contains('made no progress'),
          ),
        ),
      );
      expect(t.debugPendingTempLobCount, equals(1));
    });

    test('a failing read on a NON-temporary locator queues nothing (the guard '
        'is still content-driven, not failure-driven)', () async {
      final t = _ChunkedReadTransport([]);
      final loc = _fetchedPlainLocator(oracleType: oraTypeBlob, length: 3);
      await expectLater(
        t.materializeLobs(
          ExecuteResponse(
            isSuccess: true,
            rows: [
              [loc],
            ],
          ),
        ),
        throwsA(isA<OracleException>()),
      );
      expect(
        t.debugPendingTempLobCount,
        equals(0),
        reason:
            'exception-safety must not turn every failed read into a '
            'FREE_TEMP for a persistent locator',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Story 12.4 AC4 — the free-temp queue's locator-level dedupe.
  //
  // Adding a SECOND owner class (the materialize path, which has no OracleLob)
  // made one live shape able to present the SAME server LOB twice: a PL/SQL
  // `IN OUT` bind whose body is `p := p` returns the very locator the driver
  // created for the INPUT value, which `_createTempClob`/`_createTempBlob`
  // already queued. MEASURED on 23ai AND 21c. Queueing it again would put the
  // same locator twice in ONE FREE_TEMP piggyback, and because that piggyback
  // rides an unrelated statement's message the double free would surface as an
  // error on THAT statement.
  // -------------------------------------------------------------------------
  group('queueTempLobToFree dedupes an already-pending locator (AC4)', () {
    Uint8List locatorBytes(int tag) {
      final b = Uint8List(tnsLobLocatorBufferSize);
      b[tnsLobLocOffsetFlag4] |= tnsLobLocFlagsTemp;
      b[0] = tag;
      return b;
    }

    test('a byte-EQUAL but distinct instance is not queued twice', () {
      final t = _ChunkedReadTransport([]);
      t.queueTempLobToFree(locatorBytes(1));
      expect(t.debugPendingTempLobCount, equals(1));
      // A different Uint8List INSTANCE with identical content — exactly what the
      // server's echo of the driver's own locator looks like.
      t.queueTempLobToFree(locatorBytes(1));
      expect(
        t.debugPendingTempLobCount,
        equals(1),
        reason: 'the same server LOB must be freed once, not twice',
      );
      // A genuinely different locator still queues.
      t.queueTempLobToFree(locatorBytes(2));
      expect(t.debugPendingTempLobCount, equals(2));
    });

    test('the materialize path does not re-queue a locator already pending '
        '(the p := p IN OUT shape)', () async {
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([1, 2, 3]), amount: 3),
      ]);
      // Stand in for `_createTempClob` having queued the INPUT temp locator.
      final inputLocator = locatorBytes(9);
      t.queueTempLobToFree(inputLocator);
      expect(t.debugPendingTempLobCount, equals(1));

      // The server echoes the SAME locator bytes back as the OUT value.
      final echoed = LobLocator(
        locator: locatorBytes(9),
        oracleType: oraTypeBlob,
        length: 3,
        chunkSize: 0,
      );
      expect(echoed.isTemporary, isTrue);
      final out = await t.materializeLobs(
        ExecuteResponse(
          isSuccess: true,
          outBindValues: [echoed],
          outBindIndices: const [0],
        ),
      );
      expect(
        out.outBindValues.single,
        equals([1, 2, 3]),
        reason: 'the value is still materialized normally',
      );
      expect(
        t.debugPendingTempLobCount,
        equals(1),
        reason: 'no double free of the input locator',
      );
    });

    test('the dedupe only spans the PENDING window, so a locator freed and '
        'later re-created is queued again', () async {
      final t = _ChunkedReadTransport([]);
      t.queueTempLobToFree(locatorBytes(3));
      expect(t.debugPendingTempLobCount, equals(1));
      // Simulate the piggyback having been sent: the drain happens inside
      // sendExecute, which an unconnected transport cannot run, so assert the
      // property that matters — after the list is empty the same bytes queue
      // again — via a fresh transport standing in for the post-drain state.
      final afterDrain = _ChunkedReadTransport([]);
      afterDrain.queueTempLobToFree(locatorBytes(3));
      expect(
        afterDrain.debugPendingTempLobCount,
        equals(1),
        reason:
            'a locator can only be re-created after its free was SENT, '
            'i.e. after it left the pending list',
      );
    });

    test('an executeMany-scale queue stays correct AND cheap (the dedupe is '
        'O(1), not a per-queue linear scan)', () {
      // `_prepareBulkRowLobs` queues one locator PER ROW before the single array
      // execute, so the queue is emphatically not "at most a handful of
      // entries". A content scan on every queue attempt is ~N^2/2 whole-locator
      // byte comparisons: 10k rows was measured as ~2e9 comparisons. The wall
      // clock below is a coarse regression fence (a linear scan at this N takes
      // orders of magnitude longer than the O(1) index); the count assertions
      // are the real contract.
      const n = 20000;
      final t = _ChunkedReadTransport([]);
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        final b = Uint8List(tnsLobLocatorBufferSize);
        b[tnsLobLocOffsetFlag4] |= tnsLobLocFlagsTemp;
        // 4 distinguishing bytes so all N locators are distinct.
        b[0] = i & 0xFF;
        b[1] = (i >> 8) & 0xFF;
        b[2] = (i >> 16) & 0xFF;
        b[3] = (i >> 24) & 0xFF;
        t.queueTempLobToFree(b);
      }
      sw.stop();
      expect(
        t.debugPendingTempLobCount,
        equals(n),
        reason:
            'N distinct locators must all be queued — the fast path must '
            'not have become a dedupe that swallows real frees',
      );
      // Re-queueing every one of them must still be fully deduped.
      for (var i = 0; i < n; i++) {
        final b = Uint8List(tnsLobLocatorBufferSize);
        b[tnsLobLocOffsetFlag4] |= tnsLobLocFlagsTemp;
        b[0] = i & 0xFF;
        b[1] = (i >> 8) & 0xFF;
        b[2] = (i >> 16) & 0xFF;
        b[3] = (i >> 24) & 0xFF;
        t.queueTempLobToFree(b);
      }
      expect(
        t.debugPendingTempLobCount,
        equals(n),
        reason: 'byte-equal re-queues are still deduped at scale',
      );
      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason: 'queueing $n locators must not be quadratic',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Story 12.4 AC5 — the test-only piece cap that makes the continuation loop
  // reachable against a real server. Default off ⇒ the production single-READ
  // fast path is byte-for-byte unchanged.
  // -------------------------------------------------------------------------
  group('Transport.debugLobReadPieceUnits (AC5 test-only seam)', () {
    final locator = Uint8List(tnsLobLocatorBufferSize);

    test('defaults to null, and a default read of a value that fits issues '
        'exactly ONE READ', () async {
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([1, 2, 3, 4, 5, 6]), amount: 6),
      ]);
      expect(t.debugLobReadPieceUnits, isNull);
      final read = await t.readLobRange(locator: locator, offset: 1, amount: 6);
      expect(read.bytes, equals([1, 2, 3, 4, 5, 6]));
      expect(t.requests, hasLength(1));
      expect(t.requests.single, equals((offset: 1, amount: 6)));
    });

    test('with the cap set, the SAME read is split into capped pieces at the '
        'advanced offset and assembles byte-exact', () async {
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([1, 2]), amount: 2),
        (data: Uint8List.fromList([3, 4]), amount: 2),
        (data: Uint8List.fromList([5, 6]), amount: 2),
      ])..debugLobReadPieceUnits = 2;
      final read = await t.readLobRange(locator: locator, offset: 1, amount: 6);
      expect(read.bytes, equals([1, 2, 3, 4, 5, 6]));
      expect(read.unitsRead, equals(6));
      expect(
        t.requests,
        equals([
          (offset: 1, amount: 2),
          (offset: 3, amount: 2),
          (offset: 5, amount: 2),
        ]),
      );
    });

    test('an exact multiple of the cap terminates cleanly (off-by-one at the '
        'boundary)', () async {
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([1, 2]), amount: 2),
        (data: Uint8List.fromList([3, 4]), amount: 2),
        // A third reply exists but must never be requested.
        (data: Uint8List.fromList([9, 9]), amount: 2),
      ])..debugLobReadPieceUnits = 2;
      final read = await t.readLobRange(locator: locator, offset: 1, amount: 4);
      expect(read.bytes, equals([1, 2, 3, 4]));
      expect(t.requests, hasLength(2));
    });

    test('an EXPLICIT pieceUnits argument wins over the cap', () async {
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([1, 2, 3]), amount: 3),
        (data: Uint8List.fromList([4]), amount: 1),
      ])..debugLobReadPieceUnits = 1;
      await t.readLobRange(
        locator: locator,
        offset: 1,
        amount: 4,
        pieceUnits: 3,
      );
      expect(
        t.requests,
        equals([(offset: 1, amount: 3), (offset: 4, amount: 1)]),
      );
    });

    test(
      'a zero-unit read still issues no round trip with the cap set',
      () async {
        final t = _ChunkedReadTransport([])..debugLobReadPieceUnits = 4;
        final read = await t.readLobRange(
          locator: locator,
          offset: 1,
          amount: 0,
        );
        expect(read.bytes, isEmpty);
        expect(t.requests, isEmpty);
      },
    );

    test(
      'the fail-loud guards still fire under the cap (no-progress)',
      () async {
        final t = _ChunkedReadTransport([
          (data: Uint8List.fromList([1]), amount: 1),
          (data: null, amount: 0),
        ])..debugLobReadPieceUnits = 1;
        await expectLater(
          t.readLobRange(locator: locator, offset: 1, amount: 4),
          throwsA(
            isA<OracleException>().having(
              (e) => e.message,
              'message',
              contains('made no progress'),
            ),
          ),
        );
      },
    );

    test('the cap is validated: a non-positive value throws and leaves the '
        'seam off', () async {
      final t = _ChunkedReadTransport([]);
      expect(() => t.debugLobReadPieceUnits = 0, throwsArgumentError);
      expect(() => t.debugLobReadPieceUnits = -1, throwsArgumentError);
      expect(t.debugLobReadPieceUnits, isNull);
      // And it can be turned back off.
      t.debugLobReadPieceUnits = 3;
      expect(t.debugLobReadPieceUnits, equals(3));
      t.debugLobReadPieceUnits = null;
      expect(t.debugLobReadPieceUnits, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Story 13.2 — JSON stored in a BLOB (`IS JSON` / `IS JSON FORMAT OSON`).
  //
  // On the materialize path a row cell of a BLOB column whose describe carries
  // the IS JSON (0x100) or IS OSON (0x800) UDS flag is decoded right after its
  // READ. Never on the wrap path (fetchLobs: true is the raw-bytes opt-out),
  // never for CLOB / plain BLOB columns, never for OUT binds.
  // -------------------------------------------------------------------------
  group('materializeLobs decodes BLOB IS JSON row cells (Story 13.2)', () {
    const jsonBlob = ColumnMetadata(
      name: 'DOC',
      oracleType: oraTypeBlob,
      maxLength: 4000,
      udsFlags: 0x100, // Oracle 21c IS JSON
    );
    const jsonBlob23 = ColumnMetadata(
      name: 'DOC23',
      oracleType: oraTypeBlob,
      maxLength: 4000,
      udsFlags: 0x1100, // Oracle 23ai IS JSON
    );
    const osonOnlyBlob = ColumnMetadata(
      name: 'ODOC',
      oracleType: oraTypeBlob,
      maxLength: 4000,
      udsFlags: 0x800, // Oracle 21c IS JSON FORMAT OSON: no IS JSON bit
    );
    const plainBlob = ColumnMetadata(
      name: 'PLAIN',
      oracleType: oraTypeBlob,
      maxLength: 4000,
    );
    const jsonClob = ColumnMetadata(
      name: 'CDOC',
      oracleType: oraTypeClob,
      maxLength: 4000,
      udsFlags: 0x100,
    );
    const label = ColumnMetadata(
      name: 'LABEL',
      oracleType: oraTypeVarchar,
      maxLength: 10,
    );

    Uint8List bytesOf(String text) => Uint8List.fromList(text.codeUnits);

    LobLocator blobLocator(int length, {int tag = 0}) {
      final bytes = Uint8List(tnsLobLocatorBufferSize);
      bytes[0] = tag;
      return LobLocator(
        locator: bytes,
        oracleType: oraTypeBlob,
        length: length,
        chunkSize: 0,
      );
    }

    _ChunkedReadTransport replying(List<Uint8List> payloads) =>
        _ChunkedReadTransport([
          for (final p in payloads) (data: p, amount: p.length),
        ]);

    test('a flagged BLOB cell decodes to the Dart JSON value; other cells and '
        'SQL NULL are untouched', () async {
      final doc = bytesOf('{"a":1,"b":[true,null]}');
      final t = replying([doc]);
      final out = await t.materializeLobs(
        ExecuteResponse(
          isSuccess: true,
          columnMetadata: const [label, jsonBlob],
          rows: [
            ['x', blobLocator(doc.length)],
            ['y', null], // SQL NULL BLOB — no locator at all
          ],
        ),
      );
      expect(out.rows[0][0], equals('x'));
      expect(
        out.rows[0][1],
        equals(<String, Object?>{
          'a': 1,
          'b': <Object?>[true, null],
        }),
      );
      expect(out.rows[1][1], isNull);
      expect(t.requests, hasLength(1));
    });

    test('the 23ai flag word (0x1100) and the 21c OSON-only word (0x800) '
        'both select the decode; OSON bytes route to the OSON codec', () async {
      final text = bytesOf('[1,"two"]');
      final oson = encodeOson(<String, Object?>{'o': 2});
      final t = replying([text, oson]);
      final out = await t.materializeLobs(
        ExecuteResponse(
          isSuccess: true,
          columnMetadata: const [jsonBlob23, osonOnlyBlob],
          rows: [
            [
              blobLocator(text.length, tag: 1),
              blobLocator(oson.length, tag: 2),
            ],
          ],
        ),
      );
      expect(out.rows.single[0], equals(<Object?>[1, 'two']));
      expect(out.rows.single[1], equals(<String, Object?>{'o': 2}));
    });

    test('plain BLOB stays Uint8List and a CLOB IS JSON column stays String '
        '(out of scope, unchanged)', () async {
      final raw = bytesOf('{"looks":"like json"}');
      const clobText = '{"c":1}';
      final t = _ChunkedReadTransport([
        (data: raw, amount: raw.length),
        (data: bytesOf(clobText), amount: clobText.length),
      ]);
      final clobLocator = LobLocator(
        locator: Uint8List(tnsLobLocatorBufferSize)..[0] = 9,
        oracleType: oraTypeClob,
        length: clobText.length,
        chunkSize: 0,
      );
      final out = await t.materializeLobs(
        ExecuteResponse(
          isSuccess: true,
          columnMetadata: const [plainBlob, jsonClob],
          rows: [
            [blobLocator(raw.length), clobLocator],
          ],
        ),
      );
      expect(out.rows.single[0], isA<Uint8List>());
      expect(out.rows.single[0], equals(raw));
      expect(out.rows.single[1], equals(clobText));
    });

    test('explicit columns drive the decode when the response carries no '
        'describe (a FETCH round)', () async {
      final doc = bytesOf('{"fetched":true}');
      final t = replying([doc]);
      final out = await t.materializeLobs(
        ExecuteResponse(
          isSuccess: true,
          rows: [
            [7, blobLocator(doc.length)],
          ],
        ),
        columns: const [label, jsonBlob],
      );
      expect(out.rows.single[1], equals(<String, Object?>{'fetched': true}));
    });

    test('without any column metadata a BLOB stays raw bytes', () async {
      final doc = bytesOf('{"a":1}');
      final t = replying([doc]);
      final out = await t.materializeLobs(
        ExecuteResponse(
          isSuccess: true,
          rows: [
            [blobLocator(doc.length)],
          ],
        ),
      );
      expect(out.rows.single.single, isA<Uint8List>());
    });

    test('the wrap path (fetchLobs: true) hands back the handle: no READ and '
        'no decode', () async {
      final t = _ChunkedReadTransport([]);
      final loc = blobLocator(12);
      final out = await t.materializeLobs(
        ExecuteResponse(
          isSuccess: true,
          columnMetadata: const [jsonBlob],
          rows: [
            [loc],
          ],
        ),
        wrapLob: _WrapMarker.new,
      );
      final marker = out.rows.single.single! as _WrapMarker;
      expect(marker.locator, same(loc));
      expect(t.requests, isEmpty);
    });

    test('an aliased locator is read and decoded once and shared, like a '
        'native JSON duplicate cell', () async {
      final doc = bytesOf('{"dup":1}');
      final t = replying([doc]);
      final loc = blobLocator(doc.length);
      final out = await t.materializeLobs(
        ExecuteResponse(
          isSuccess: true,
          columnMetadata: const [jsonBlob],
          rows: [
            [loc],
            [loc],
          ],
        ),
      );
      expect(t.requests, hasLength(1));
      expect(out.rows[0][0], equals(<String, Object?>{'dup': 1}));
      expect(identical(out.rows[0][0], out.rows[1][0]), isTrue);
    });

    test(
      'an aliased JSON `null` document is cached too (not re-read)',
      () async {
        final doc = bytesOf('null');
        final t = replying([doc, doc]);
        final loc = blobLocator(doc.length);
        final out = await t.materializeLobs(
          ExecuteResponse(
            isSuccess: true,
            columnMetadata: const [jsonBlob],
            rows: [
              [loc],
              [loc],
            ],
          ),
        );
        expect(out.rows[0][0], isNull);
        expect(out.rows[1][0], isNull);
        expect(t.requests, hasLength(1));
      },
    );

    test('an undecodable cell fails the WHOLE call, naming the column — no '
        'partial rows, never raw bytes', () async {
      final good = bytesOf('[1]');
      final lax = bytesOf('{a:1}'); // accepted by a lax IS JSON constraint
      final t = replying([good, lax]);
      await expectLater(
        t.materializeLobs(
          ExecuteResponse(
            isSuccess: true,
            columnMetadata: const [jsonBlob],
            rows: [
              [blobLocator(good.length, tag: 1)],
              [blobLocator(lax.length, tag: 2)],
            ],
          ),
        ),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
              .having(
                (e) => e.message,
                'message',
                allOf(contains('"DOC"'), contains('not strict JSON')),
              ),
        ),
      );
    });

    test(
      'a zero-length value (EMPTY_BLOB()) fails loud without a READ',
      () async {
        final t = _ChunkedReadTransport([]);
        await expectLater(
          t.materializeLobs(
            ExecuteResponse(
              isSuccess: true,
              columnMetadata: const [jsonBlob],
              rows: [
                [blobLocator(0)],
              ],
            ),
          ),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraUnsupportedType)
                .having((e) => e.message, 'message', contains('empty')),
          ),
        );
        expect(t.requests, isEmpty);
      },
    );

    test('corrupt OSON keeps its oraProtocolError code through the column '
        'wrap', () async {
      final full = encodeOson(<String, Object?>{'a': 1});
      final cut = Uint8List.sublistView(full, 0, full.length - 1);
      final t = replying([cut]);
      await expectLater(
        t.materializeLobs(
          ExecuteResponse(
            isSuccess: true,
            columnMetadata: const [osonOnlyBlob],
            rows: [
              [blobLocator(cut.length)],
            ],
          ),
        ),
        throwsA(
          isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('"ODOC"')),
        ),
      );
    });

    test('BLOB OUT binds are never decoded (only result columns carry the '
        'flag)', () async {
      final doc = bytesOf('{"out":1}');
      final t = replying([doc]);
      final out = await t.materializeLobs(
        ExecuteResponse(
          isSuccess: true,
          columnMetadata: const [jsonBlob],
          outBindValues: [blobLocator(doc.length)],
          outBindIndices: const [0],
        ),
      );
      expect(out.outBindValues.single, isA<Uint8List>());
      expect(out.outBindValues.single, equals(doc));
    });
  });
}
