---
title: 'Surface a clear pool-reclaim error to a live result-set stream subscriber'
type: 'bugfix'
created: '2026-06-21'
status: 'done'
baseline_commit: 1052e728d51dcb92c881773e33e1171dfccc5285
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem (deferred-work F):** When the pool reclaims a connection on `release()` while one of its `OracleResultSet` streams (`queryStream()`/`executeStream()`, or an idle-between-pulls `getRow()/getRows()` loop) is mid-flight, `release()` calls `OracleConnection.forceCloseOpenResultSet()`, which calls `rs.close()` → sets `_closed = true`. The stream generator's next `rs.getRows()` then hits `_ensureOpen()` and throws the GENERIC `OracleException(oraProtocolError, "OracleResultSet is closed; open a new one to read more rows")`. That message is a leaked internal implementation detail — it reads as if the *caller* closed the result set, when in fact the pool reclaimed the connection underneath the live stream. The subscriber gets a misleading error with the wrong error code.

**Approach:** Distinguish a *pool-reclaim* close from an ordinary `close()`. `forceCloseOpenResultSet()` marks each result set it reaps as reclaimed-by-pool; `_ensureOpen()` (and `close()`'s own short-circuit) then surface a CLEAR, intentional `OracleException(oraConnectionClosed /* ORA-03113 */, "the connection pool reclaimed this connection while its result-set stream was active; the stream was terminated")` instead of the generic "is closed" detail. This mirrors node-oracledb, where releasing a pooled connection (`connection.close()`) deletes the impl so the next `resultSet.getRow()` fails with a clear `NJS-018 invalid ResultSet` / `NJS-003 invalid or closed connection` — an intentional invalid-state error, never a leaked internal detail. The leak guard is untouched: the cursor is still reaped via the same `releaseResultSet()` close path; only the subscriber-facing error surface changes.

## Boundaries & Constraints

**Always:** The pool MUST still reap the cursor and keep the physical session reusable (no leak) — the existing "Pooled OracleResultSet leak guard" group and `pool_test.dart` reclaim tests MUST stay green. The reclaim error MUST carry `errorCode == oraConnectionClosed` (3113), the package's connection-reclaim lifecycle code. An ordinary borrower-initiated `close()` followed by `getRow()` MUST keep throwing the existing generic "OracleResultSet is closed" message (that is correct caller-misuse feedback — only the pool-reclaim case changes). Use `test_helper.dart` getters for integration tests — never hardcode port/service/creds.

**Ask First:** Any change to WHEN the pool force-closes (the `isExecuting` vs `hasOpenResultSet` dispositions in `release()`), or to the cursor-reaping / cache-invalidation path.

**Never:** Do NOT make the stream terminate "gracefully" (silent `done`) on reclaim — silently swallowing the rows the subscriber expected would hide data loss; a clear error is the defensible outcome (see Design Notes). Do NOT destroy the session on the open-but-idle reclaim path (that stays a recoverable close, not a mid-RPC destroy). Do NOT change the eager `execute()` error surface.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Pool reclaims a live stream | borrower released mid-`queryStream`/`executeStream` (idle between pulls; `isExecuting==false`, `hasOpenResultSet==true`) | next `getRows()` throws `OracleException(oraConnectionClosed, "…pool reclaimed…")`; cursor reaped; session reusable | clear reclaim error to subscriber |
| Pool reclaims an open `getRow()` loop | same, manual `openResultSet` loop | next `getRow()` throws the reclaim error | clear reclaim error |
| Ordinary borrower `close()` then `getRow()` | caller closed the RS itself | throws existing generic "OracleResultSet is closed; open a new one…" | unchanged |
| Stream completes normally / cancelled | natural drain or `break`/`cancel()` | completes; cursor reaped; no error | unchanged |
| Reclaim with implicit result sets open | `_openImplicitResultSets` non-empty | each handle reclaim-marked; next fetch on any throws the reclaim error | clear reclaim error |
| `close()` on an already reclaim-closed RS | idempotent re-close | no-op, throws nothing | unchanged |

</frozen-after-approval>

## Code Map

- `lib/src/result_set.dart` -- `OracleResultSet`: add an internal `markReclaimedByPool()` (or a flag set by a force-close variant) and a `_reclaimedByPool` flag; `_ensureOpen()` throws the reclaim error when the flag is set, else the existing generic error; `close()` short-circuit unaffected.
- `lib/src/connection.dart` -- `forceCloseOpenResultSet()`: mark each result set reclaimed-by-pool BEFORE closing it (so a subsequent fetch surfaces the clear error), then close as today (cursor reaping unchanged).
- `lib/src/errors.dart` -- reuse `oraConnectionClosed` (3113); no new constant needed.
- `test/integration/streaming_result_set_integration_test.dart` -- new regression in the "Pooled OracleResultSet leak guard" group: a pool reclaim of a connection with a live stream surfaces the reclaim error to the subscriber AND the session is reused (no leak).
- `test/src/result_set_stream_test.dart` (or the nearest result-set unit suite) -- unit: reclaim-marked RS fetch throws the reclaim error; ordinary closed RS keeps the generic error.

## Tasks & Acceptance

**Execution:**
- [ ] `lib/src/result_set.dart` -- add `_reclaimedByPool` flag + `@internal markReclaimedByPool()`; `_ensureOpen()` branches on it (reclaim error vs generic error). Keep `close()` idempotent.
- [ ] `lib/src/connection.dart` -- `forceCloseOpenResultSet()` calls `markReclaimedByPool()` on the top-level handle and every implicit handle before closing them.
- [ ] `test/integration/streaming_result_set_integration_test.dart` -- dual-env: release a connection mid-stream; assert the subscriber sees `OracleException` with `errorCode == oraConnectionClosed` and the pool-reclaim message substring; then re-acquire and run a query (session reusable, cursor reaped). Proven-to-fail against the unpatched generic message.
- [ ] result-set unit suite -- reclaim-marked fetch throws reclaim error; ordinary close keeps generic error.

**Acceptance Criteria:**
- Given a pooled connection released while a `queryStream`/`executeStream` is mid-flight, when the stream's next fetch runs, then the subscriber receives an `OracleException(oraConnectionClosed)` whose message names the pool reclaim — NOT the generic "OracleResultSet is closed" detail.
- Given the same reclaim, the cursor is reaped and the physical session is handed back healthy on the next acquire (no leak; existing leak-guard tests stay green).
- Given an ordinary borrower-initiated `close()`, a subsequent fetch still throws the existing generic message (unchanged).
- `dart analyze` clean; result-set + pool unit suites green; integration green on 23ai AND 21c.

## Spec Change Log

- **2026-06-21 (adversarial review — Edge-Case Hunter, Low):** First implementation had `forceCloseOpenResultSet()` UNCONDITIONALLY mark every handle reclaimed-by-pool. But that method is ALSO the generic "reap any leaked handles" helper on the PL/SQL execute-failure cleanup path (`connection.dart` ~1122) — NOT a pool reclaim. Marking there was a latent mislabel trap (currently unobservable because those handles never reach a caller, but a future surfacing would hand a "pool reclaimed" message for a plain query failure). Amended: gated the marking behind `forceCloseOpenResultSet({bool reclaimedByPool = false})`; only `OraclePool.release()` passes `true`. Added a unit test pinning that the default path keeps the generic "is closed" error. KEEP: the mark-before-close mechanism and the `_ensureOpen` branch are unchanged.
- **2026-06-21 (acceptance auditor note, not actioned):** The in-flight-FETCH reclaim race (`isExecuting == true`) is intentionally OUT of scope (I/O matrix): `release()` takes the destroy branch (genuine mid-RPC race, `oraProtocolError`), which the spec deliberately leaves unchanged. The fix targets the open-but-idle-between-pulls window, which is the case deferred-work F described.

## Design Notes

**Why error, not graceful done.** node-oracledb surfaces a clear invalid-state error (NJS-018 / NJS-003) when a stream's result set is used after its connection was released — it does not silently end the stream. Silently emitting `done` would hide from the subscriber that rows it was iterating were dropped because the pool took the connection back; that is a correctness hazard. A clear, coded error is the defensible, parity-aligned choice.

**Why `oraConnectionClosed` (3113).** The reclaim is, from the stream's perspective, the connection going away underneath it — the same lifecycle event the package already models with ORA-03113 (`_poolClosedException`, closed-connection rejections). node-oracledb maps the connection-invalidation family (ORA-03113/03114 and the NJS connection-closed codes) the same way. Using the existing constant keeps callers' error handling consistent.

**Mechanism / minimality.** The pool already force-closes correctly and reaps the cursor; the ONLY defect is the message/code the post-close fetch raises. Marking the RS reclaimed-by-pool before `close()` and branching in `_ensureOpen()` changes nothing about the reap path, the cache invalidation, or the `release()` dispositions — it is the smallest change that fixes the subscriber-facing surface. The mark is set before close so the flag survives (`close()` only flips `_closed`; the reclaim flag is independent).

## Verification

**Commands:**
- `dart analyze` -- expected: No issues found.
- `dart test test/src/result_set_stream_test.dart test/src/pool_test.dart` -- expected: all pass.
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color --concurrency=3` -- expected: green (23ai).
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color --concurrency=3` -- expected: green (21c).
