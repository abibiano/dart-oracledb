/// Unit tests pinning [ResultSetCursor]'s all-or-nothing lazy-LOB-handle
/// callback contract (Epic 12 integration review, iterations 2 + 3).
///
/// Iteration 2 added a constructor `assert` for it, because a PARTIAL set leaks
/// silently: with only `wrapLob`, each batch's handles are registered on the
/// connection while `_recordDelivered` / `bufferedLobHandles()` no-op
/// (`isLobHandle` is null) and `close()` returns early (`closeLobHandles` is
/// null) — a wedged connection with no public API left to find the handles.
/// Iteration 3 found nothing pinned that assert: inverting or deleting it would
/// have kept every test green. These cases follow the project's established
/// convention for pinning an assert (`throwsA(isA<AssertionError>())`).
///
/// Note the guard is dev/test-only by construction — Dart strips asserts in
/// release builds — which is why the dartdoc says "guarded in dev/test builds
/// by", not "enforced by". That is adequate here: these callbacks are wired only
/// inside this driver, so a partial set is a driver-development mistake and the
/// unit suite always runs with asserts enabled.
library;

import 'dart:typed_data';

import 'package:oracledb/src/protocol/lob_locator.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/protocol/result_set_cursor.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

ColumnMetadata _col(String name) =>
    ColumnMetadata(name: name, oracleType: 2, maxLength: 0);

/// The three callbacks, each independently omittable, so a test can construct
/// any subset without repeating their signatures.
Object _wrap(LobLocator locator) => Object();
bool _isHandle(Object? value) => false;
Future<void> _closeHandles(Iterable<Object> handles) async {}

/// Builds a cursor with exactly the callbacks passed in. Every other argument is
/// the same minimal, valid shape, so the ONLY thing under test is the subset.
ResultSetCursor build({
  Object Function(LobLocator locator)? wrapLob,
  bool Function(Object? value)? isLobHandle,
  Future<void> Function(Iterable<Object> handles)? closeLobHandles,
}) =>
    ResultSetCursor(
      transport: Transport(),
      cursorId: 7,
      columns: [_col('N')],
      firstBatch: const [
        <Object?>[1]
      ],
      serverHasMoreRows: false,
      prefetchRows: 50,
      preserveTimestampTimeZone: false,
      materializePerBatch: false,
      wrapLob: wrapLob,
      isLobHandle: isLobHandle,
      closeLobHandles: closeLobHandles,
    );

void main() {
  group('ResultSetCursor lazy-LOB-handle callbacks are all-or-nothing', () {
    test('all three supplied constructs successfully (positive control)', () {
      expect(
        build(
          wrapLob: _wrap,
          isLobHandle: _isHandle,
          closeLobHandles: _closeHandles,
        ),
        isA<ResultSetCursor>(),
      );
    });

    test('none supplied constructs successfully — the materialize / eager-drain '
        'shape (positive control)', () {
      expect(build(), isA<ResultSetCursor>());
    });

    // One case per omitted callback: each omission on its own must trip the
    // assert, so neither half of the `&&` can be deleted without a failure.
    test('wrapLob omitted trips the assert', () {
      expect(
        () => build(isLobHandle: _isHandle, closeLobHandles: _closeHandles),
        throwsA(isA<AssertionError>()),
      );
    });

    test('isLobHandle omitted trips the assert', () {
      expect(
        () => build(wrapLob: _wrap, closeLobHandles: _closeHandles),
        throwsA(isA<AssertionError>()),
      );
    });

    test('closeLobHandles omitted trips the assert', () {
      expect(
        () => build(wrapLob: _wrap, isLobHandle: _isHandle),
        throwsA(isA<AssertionError>()),
      );
    });

    // The exact shape the assert exists for: `wrapLob` alone is the partial set
    // that registers handles nothing can ever reap.
    test('wrapLob ALONE — the silent-leak shape — trips the assert', () {
      expect(() => build(wrapLob: _wrap), throwsA(isA<AssertionError>()));
    });

    test('isLobHandle alone trips the assert', () {
      expect(
        () => build(isLobHandle: _isHandle),
        throwsA(isA<AssertionError>()),
      );
    });

    test('closeLobHandles alone trips the assert', () {
      expect(
        () => build(closeLobHandles: _closeHandles),
        throwsA(isA<AssertionError>()),
      );
    });

    test('the assert message names the contract and the failure mode', () {
      expect(
        () => build(wrapLob: _wrap),
        throwsA(
          isA<AssertionError>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('must be supplied together or not at all'),
              contains('nothing can ever'),
            ),
          ),
        ),
      );
    });
  });

  // Guards the fixture itself: `_wrap` must be a usable `wrapLob`, or every
  // negative case above could be passing for the wrong reason.
  test('the fixture callbacks match the constructor signatures', () {
    expect(
      _wrap(LobLocator(
        locator: Uint8List(40),
        oracleType: 112,
        length: 0,
        chunkSize: 0,
      )),
      isNotNull,
    );
    expect(_isHandle(null), isFalse);
    expect(_closeHandles(const <Object>[]), isA<Future<void>>());
  });
}
