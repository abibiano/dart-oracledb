---
title: 'Streaming / result-set polish & coverage'
type: 'chore'
created: '2026-06-21'
status: 'done'
baseline_commit: '0b707daa82da86d7346d11f49d70508c0501bb8d'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Four low-severity streaming/result-set follow-ups: (G) the
concurrency guard's exception text says "Concurrent execute()" but fires for
`executeStream`/`queryStream`/`openResultSet`/`execute(resultSet:true)` too, so
it misleads stream callers; (I-a) the `@visibleForTesting openResultSet()` seam
cannot thread `prefetchRows`, diverging from `executeStream`; (I-b) the
degenerate `fetchSize == 1` boundary (every row a separate FETCH) is untested;
(I-c) the streaming duplicate-column cross-batch sentinel
(`ResultSetCursor._previousRoundLastRow`) is unproven by a targeted test.

**Approach:** Reword `_rejectConcurrentOperation`'s message to name all entry
points (keep error CODE unchanged); update the assertions that pin the old text.
Add an optional `prefetchRows` param to `openResultSet()` threaded into
`_openResultSetGuarded`. Add a `fetchSize == 1` unit test and an integration
test. Add a targeted streaming test that forces a duplicate column at a FETCH
batch boundary, proving `_previousRoundLastRow` carries the right value into the
next round's `previousRoundLastRow:`.

## Boundaries & Constraints

**Always:** Keep the concurrency error CODE (`oraProtocolError`). New message
must remain accurate for ALL entry points. `openResultSet` param is additive and
optional (default = current behaviour). Tests use `test/integration/test_helper.dart`
getters for service/port/credentials — never hardcode. Dual-env (23ai + 21c)
integration MUST pass. `dart analyze` clean.

**Ask First:** Any change to observable behaviour beyond the message text and
the additive seam param. Any change to the concurrency-guard firing conditions.

**Never:** Change when the guard fires. Change the error code. Touch
`runResultSetFetch`'s separate "Concurrent operation…" message (out of scope —
item G is specifically `_rejectConcurrentOperation`). Force a brittle/flaky
duplicate-LOB-at-boundary test if it cannot be made deterministic (fall back to
a non-LOB duplicate at a boundary, or report still-deferred with rationale).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Concurrent op while RS open | second op via any entry point | throws OracleException(oraProtocolError); message names "another operation … in progress" | fail-fast, no wire trip |
| `openResultSet(sql, binds, prefetchRows: 1)` | small fetch granularity | continuation FETCHes request exactly 1 row | N/A |
| `fetchSize == 1` over N rows | multi-row SELECT | every row delivered exactly once, in order; N separate FETCH rounds | N/A |
| Duplicate column at batch boundary | row[0] of FETCH round 2 duplicates last row of round 1 | dedup source = `_previousRoundLastRow`; value resolves correctly | protocol error if no prior row |

</frozen-after-approval>

## Code Map

- `lib/src/connection.dart` -- `_rejectConcurrentOperation` (message, G); `openResultSet` seam (add `prefetchRows`, I-a)
- `lib/src/protocol/result_set_cursor.dart` -- `_previousRoundLastRow` capture + thread to `fetchRows(previousRoundLastRow:)` (I-c subject; no code change expected)
- `test/src/result_set_stream_test.dart` -- fetchSize=1 unit test (I-b); duplicate-column-at-boundary streaming test (I-c). `_FakeResultSetTransport` must capture `previousRoundLastRow`.
- `test/integration/streaming_result_set_integration_test.dart` -- fetchSize=1 integration test (I-b); message assertion at ~line 178 (G)
- `test/src/connection_test.dart` (~line 372), `test/src/result_set_test.dart` (~lines 722, 970) -- `contains('Concurrent execute')` assertions to update (G)

## Tasks & Acceptance

**Execution:**
- [ ] `lib/src/connection.dart` -- reword `_rejectConcurrentOperation` message to name all entry points; keep code -- G
- [ ] `lib/src/connection.dart` -- add optional `prefetchRows` to `openResultSet`, thread to `_openResultSetGuarded` -- I-a
- [ ] update all old-text assertions (`connection_test.dart`, `result_set_test.dart`, `streaming_result_set_integration_test.dart`, `result_set_stream_test.dart`) to the new wording -- G
- [ ] `test/src/result_set_stream_test.dart` -- add fetchSize=1 unit test + duplicate-column-at-boundary streaming test; capture `previousRoundLastRow` in the fake -- I-b, I-c
- [ ] `test/integration/streaming_result_set_integration_test.dart` -- add fetchSize=1 integration test -- I-b

**Acceptance Criteria:**
- Given a result set is open, when any entry point starts a new op, then it throws with the reworded (entry-point-agnostic) message and the unchanged code.
- Given `openResultSet(..., prefetchRows: 1)`, when continuation FETCHes run, then each requests exactly 1 row.
- Given a multi-row SELECT streamed with fetchSize=1, when fully consumed, then every row is delivered exactly once in order across N FETCH rounds.
- Given a duplicate-column bit on row[0] of FETCH round 2, when decoded, then `_previousRoundLastRow` from round 1 supplies the value and the row resolves correctly.

## Spec Change Log

## Design Notes

I-c is decode-level-covered already (`execute_message_test.dart` "cross-round
duplicate copies from previousRoundLastRow"). The gap is the END-TO-END
`ResultSetCursor` wiring: that it captures `batch.rows.last` after round 1 and
passes it as `fetchRows(previousRoundLastRow:)` for round 2. The fake transport
returns already-decoded rows, so to exercise the sentinel the test asserts the
`previousRoundLastRow` the cursor threaded into the second FETCH equals round 1's
last row (and that a duplicate-shaped round-2 row resolves). Non-LOB columns are
sufficient — the value flows through `_previousRoundLastRow` identically whether
materialized or raw (the residual the story-8.1 item flagged: equivalence of a
materialized-vs-raw carried value, which a non-LOB test still exercises since the
carry mechanism is value-type-agnostic).

## Verification

**Commands:**
- `dart analyze` -- expected: No issues found!
- `dart test test/src/result_set_stream_test.dart test/src/connection_test.dart test/src/result_set_test.dart` -- expected: all pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color --concurrency=3` -- expected: 23ai green
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color --concurrency=3` -- expected: 21c green
