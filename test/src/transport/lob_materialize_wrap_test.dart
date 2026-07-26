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

    test('wraps LOB locators in OUT-bind rows (DML RETURNING nested shape)',
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
    });

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

    test('the same guard DOES throw on the materialize path (no wrapLob)',
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
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraBindTypeError)),
      );
    });

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

    test('a locator-free response is returned unchanged with no wrapping',
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
    });
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

    test('keeps reading at the advanced offset until the requested units arrive',
        () async {
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([1, 2, 3]), amount: 3),
        (data: Uint8List.fromList([4, 5]), amount: 2),
        (data: Uint8List.fromList([6, 7, 8]), amount: 3),
      ]);
      final read =
          await t.readLobRange(locator: locator, offset: 1, amount: 8);
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
    });

    test('a value that fits ONE round trip costs exactly one READ (fast path '
        'preserved byte-for-byte)', () async {
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([1, 2, 3, 4]), amount: 4),
      ]);
      final read =
          await t.readLobRange(locator: locator, offset: 1, amount: 4);
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
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)
            .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('made no progress'),
                  contains('offset 3'),
                  contains('5 units'),
                ))),
      );
      expect(t.requests, hasLength(2));
    });

    test('nothing delivered at all returns empty so the CALLER reports it '
        '("read returned no data", not a no-progress error)', () async {
      final t = _ChunkedReadTransport([(data: null, amount: 0)]);
      final read =
          await t.readLobRange(locator: locator, offset: 1, amount: 5);
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
        throwsA(isA<OracleException>()
            .having((e) => e.message, 'message', contains('overshot'))),
      );
    });

    test('a reply that omits the SB8 amount is treated as satisfying the whole '
        'request (degrades to the pre-12.3 single READ)', () async {
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([1, 2]), amount: null),
        (data: Uint8List.fromList([3]), amount: null), // never requested
      ]);
      final read =
          await t.readLobRange(locator: locator, offset: 1, amount: 5);
      expect(read.bytes, equals([1, 2]), reason: 'short payload, one READ');
      expect(read.unitsRead, equals(5));
      expect(t.requests, hasLength(1));
    });

    test('a non-positive amount issues no round trip', () async {
      final t = _ChunkedReadTransport([]);
      final read =
          await t.readLobRange(locator: locator, offset: 1, amount: 0);
      expect(read.bytes, isEmpty);
      expect(read.unitsRead, equals(0));
      expect(t.requests, isEmpty);
    });

    test('the server post-op locator echo is copied back after EVERY piece',
        () async {
      final live = Uint8List(tnsLobLocatorBufferSize);
      final t = _ChunkedReadTransport([
        (data: Uint8List.fromList([1]), amount: 1),
        (data: Uint8List.fromList([2]), amount: 1),
      ])
        ..echoLocator = Uint8List(tnsLobLocatorBufferSize)
        ..echoLocator!.fillRange(0, tnsLobLocatorBufferSize, 0x7E);
      await t.readLobRange(locator: live, offset: 1, amount: 2);
      expect(live, everyElement(equals(0x7E)));
    });

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
}
