/// Unit coverage for the `fetchLobs` wrap path threaded through
/// [Transport.materializeLobs] (Story 12.1, Epic 11 retro action item 2).
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
}
