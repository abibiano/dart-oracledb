---
title: 'Harden result-set & statement-cache cursor lifecycle against leaks (E1-E4)'
type: 'bugfix'
created: '2026-06-21'
status: 'done'
baseline_commit: 882d45954d14b9249b0a318a8a8ebf1398394b60
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Four latent cursor-leak / unsafe-state bugs in the result-set + statement-cache lifecycle. Currently masked by the single-connection concurrent-op guard, but real and worth fixing before a release:
- **E1** — `_openResultSetGuarded` constructs an `OracleResultSet` backed by cursor id 0 when a describe-mismatch full-reparse retry returns no cursor; a later `fetchRows(0, …)` then errors or reads stale data.
- **E2** — `releaseResultSet` failed path calls `_cache.invalidate(key)` (remove-by-key). If a newer entry was stored under the same key (e.g. `invalidateAll()` + re-execute) the newer *live* entry is dropped and ITS cursor leaks, while the held cursor is never queued.
- **E3** — that same failed path is a no-op after `closeAll()`/`invalidateAll()` already removed the entry, so the held cursor is never queued for close → leaks until session teardown.
- **E4** — `StatementCache.release()` removes by key, not object identity. A newer same-key entry stored after an in-use eviction is silently dropped and its cursor leaks.

**Approach:** Make cursor reclamation identity-based and always-queue-the-held-cursor, mirroring node-oracledb (identity-keyed `_openCursors` + `_addCursorToClose(statement)`). Add `StatementCache.invalidateEntry(entry)` (queue `entry.cursorId`; drop the map slot only if it still `identical`-holds this entry); apply the same identity guard to `release()`; point `releaseResultSet`'s failed path at `invalidateEntry`; and fail loud in `_openResultSetGuarded` when the post-retry cursor id is 0.

## Boundaries & Constraints

**Always:** Queuing for close stays idempotent (the `_cursorsToClose` Set dedups). Preserve success-path reuse semantics (`returnToCache` entries still return to cache). The E1 fail-loud throw must leave the connection reusable — throw inside the existing `try` so the catch reaps any acquired cursor. Dual-env validate on Oracle 23ai AND 21c; use `test_helper.dart` getters, never hardcode service/port/credentials.

**Ask First:** If any fix would require changing the cache KEY model (SQL+bindSignature) or the `inUse`/`returnToCache` state machine beyond identity-guarding the removal.

**Never:** Do not change the semantics of `invalidate(key)`, `invalidateAll()`, or `closeAll()` for their existing callers (DDL invalidation, execute-error catch, connection close) — only ADD `invalidateEntry` and fix `release()` / `releaseResultSet`. Do not add a concurrent-op guard or otherwise alter connection concurrency. Do not re-fix E5 (already resolved — see Design Notes). Do not branch on server version.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| release() after in-use eviction + newer same-key store | A in-use, `returnToCache=false`; B (diff cursor) stored under same key | A's cursor queued for close; B stays cached; B's cursor NOT dropped | N/A |
| invalidateEntry, newer same-key entry present | held A; `_entries[key]` holds newer B | A's cursor queued; B left intact | N/A |
| invalidateEntry after closeAll removed the entry | held A; `_entries` empty | A's cursor queued (not a no-op) | N/A |
| openResultSet retry yields cursor id 0 | full-reparse retry returns cursorId 0 | throws `OracleException(oraProtocolError)`; no result set; any acquired cursor reaped; connection reusable | fail loud |
| Regression: normal release/invalidate | held A `identical` to `_entries[key]` | A removed + cursor queued, exactly as before | N/A |

</frozen-after-approval>

## Code Map

- `lib/src/statement_cache.dart` -- `release()` (~233, E4: identity-guard the `_entries.remove`); ADD `invalidateEntry()` after `invalidate()` (~254). `invalidate`/`invalidateAll`/`closeAll`/`_cursorsToClose` (183) left unchanged (reference for the dedup + existing callers).
- `lib/src/connection.dart` -- `releaseResultSet` failed branch (~1682, E2/E3: call `invalidateEntry`); `_openResultSetGuarded` (~1556, E1: throw on `firstResponse.cursorId == 0`, inside the `try`); its catch (~1596) reaps `unhandledCursorId`/`invalidate` on throw (reference).
- `reference/node-oracledb/lib/thin/statementCache.js` -- `_addCursorToClose`/`_openCursors` (identity-keyed) — the parity target.
- `test/src/statement_cache_test.dart`, `test/src/connection_test.dart` -- proven-to-fail unit tests.

## Tasks & Acceptance

**Execution:**
- [x] `lib/src/statement_cache.dart` -- Add `invalidateEntry(StatementCacheEntry entry)`: if `identical(_entries[entry.key], entry)` remove it; then `if (entry.cursorId != 0) _cursorsToClose.add(entry.cursorId)`. Change `release()`'s non-`returnToCache` branch to the same identity-guarded removal while still always queuing `entry.cursorId`. Dartdoc both with the race they prevent + node-oracledb parity note.
- [x] `lib/src/connection.dart` -- `releaseResultSet` failed path: replace `_cache.invalidate(cacheEntry.key)` with `_cache.invalidateEntry(cacheEntry)`.
- [x] `lib/src/connection.dart` -- `_openResultSetGuarded`: after nested-cursor materialization and before cache disposition, `if (firstResponse.cursorId == 0) throw const OracleException(errorCode: oraProtocolError, message: …)` (inside the `try`, so the catch reaps any acquired cursor and the connection stays reusable).
- [x] `test/src/statement_cache_test.dart` -- Proven-to-fail unit tests: (a) `release()` identity — newer same-key entry survives, held cursor queued; (b) `invalidateEntry` leaves a newer same-key entry intact + queues held cursor; (c) `invalidateEntry` queues the held cursor even after `closeAll()` emptied the map; (d) regression — normal `release()`/`invalidateEntry` still removes + queues. Each (a)-(c) must fail against the unpatched code.
- [x] `test/src/connection_test.dart` -- Added the E1 fail-loud test via the `_FakeTransport`/`openResultSet` seam (cursorId-0 → `OracleException(oraProtocolError)`, connection reusable, nothing queued). The E2/E3 *connection wiring* (releaseResultSet → invalidateEntry) is NOT unit-tested here — see Design Notes for why.
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` -- Move E1-E4 to a Resolved section; record E5 as verified-already-fixed.

**Acceptance Criteria:**
- Given a held cache entry whose key now maps to a newer entry, when the held entry is released or failed-invalidated, then the held entry's cursor is queued for close and the newer entry is left intact (unit-proven; dual-env suite green).
- Given a held entry already removed by `closeAll`/`invalidateAll`, when `releaseResultSet(failed:true)` runs, then the held cursor is still queued for close (no silent leak).
- Given a result-set open whose server cursor id is 0, when `openResultSet`/`executeStream`/`execute(resultSet:true)` runs, then it throws `OracleException(oraProtocolError)` and the connection remains reusable.
- Given the full integration suite, when run on both Oracle 23ai and 21c, then it stays green with no regressions.

## Spec Change Log

### 1 — E1 guard narrowed: `cursorId == 0` is legitimate on cache reuse (2026-06-21, review-driven patch)

**Trigger:** Edge-Case-Hunter review (corroborated by the Acceptance Auditor) found the first implementation's `if (firstResponse.cursorId == 0) throw` was too broad. The Oracle server **echoes `cursorId == 0` on a cached re-execute** while the original cursor stays open; the transport (`transport.dart:590`) patches that echo back to the request's id only when `moreRowsToFetch` is true, so a **cached single-batch SELECT re-run via the result-set path arrives with `cursorId == 0`** and was being rejected spuriously (the eager `execute` path handles it fine). The full dual-env suite missed it because no test re-ran the same small SELECT through the result-set API.

**Amendment (patch, no frozen change):** Resolve `effectiveCursorId = firstResponse.cursorId != 0 ? firstResponse.cursorId : (heldEntry?.cursorId ?? 0)` and fail loud only when *that* is 0 (genuine no-cursor: no echo AND no cached cursor — the describe-mismatch full-reparse case the frozen I/O-matrix row actually targets). This also fixes a pre-existing latent `effectiveCursorId == 0` for single-batch reuse. Added: a connection-unit test proving cached reuse-echo-0 does NOT throw, and a dual-env integration test re-opening a cached single-batch SELECT.

**Also (patch):** `StatementCache.release()`'s non-`returnToCache` branch now delegates to `invalidateEntry()` (one implementation of the identity-guarded removal + always-queue), addressing a reviewer note about duplicated/divergent logic. Behavior is identical (+ a strict improvement: it no longer collateral-evicts a newer same-key entry).

**KEEP:** The identity-based reclamation (E2/E3/E4) and its proven-to-fail unit tests were confirmed correct by all three reviewers — preserve them. The `invalidate(key)` semantics for DDL/execute-error callers stay unchanged (race-free at execution-error time — see Design Notes).

## Design Notes

**E5 (partial-open materializeLobs orphan) is already fixed — out of scope.** Both open-path catches capture `unhandledCursorId = firstResponse.cursorId` BEFORE the `try` and `requeueCursorsToClose([unhandledCursorId])` on any throw — `_openResultSetGuarded` (connection.dart ~1600) and eager `execute` (~1111). No orphan remains; no code change, documented for the record.

**Why `invalidate(key)` is NOT changed:** its callers (DDL `invalidateAll`, the execute-error catch) invalidate at execution-error time, before any new entry could be stored under the same key, so by-key removal is correct there. Only the held-entry close/release paths can race a newer same-key store, so only they need identity.

**E2/E3 connection-wiring test coverage:** the deterministic proof lives at the `StatementCache` unit level (`invalidateEntry` leaves a newer same-key entry intact, and queues the held cursor even after `closeAll()` removed it — both with explicit buggy-vs-fixed contrast). The connection-level wiring is a single verified one-liner (`releaseResultSet` failed path now calls `invalidateEntry(cacheEntry)`), and a connection-level test would need to drive a mid-stream FETCH/materialize failure to reach the `failed: true` path — the `_FakeTransport` only overrides `sendExecute`, not the fetch path, so there is no clean seam. The wiring is covered by the unit proofs of the primitive plus the full dual-env integration suite (no regression). A future hardening pass could extend `_FakeTransport` with a failing-fetch seam to assert the wiring directly.

## Verification

**Commands:**
- `dart analyze` -- expected: zero warnings/errors.
- `dart test test/src/statement_cache_test.dart test/src/connection_test.dart` -- expected: all pass, including the new proven-to-fail leak tests.
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color` -- expected: full suite green (Oracle 23ai).
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color` -- expected: full suite green (Oracle 21c).

## Suggested Review Order

**Statement-cache identity primitive (design intent)**

- Entry point — the new identity-aware reclamation: queue the held cursor, drop the slot only if it still `identical`-holds this entry (E2/E3/E4 root)
  [`statement_cache.dart:273`](../../lib/src/statement_cache.dart#L273)

- `release()` now delegates to it, so the race-safe logic lives in one place
  [`statement_cache.dart:233`](../../lib/src/statement_cache.dart#L233)

**Connection close/open wiring**

- Failed result-set release routes through the identity-aware primitive (E2/E3)
  [`connection.dart:1707`](../../lib/src/connection.dart#L1707)

- E1 — resolve the usable cursor id with a cache-reuse fallback; fail loud only on a genuine no-cursor (the review-driven narrowing)
  [`connection.dart:1611`](../../lib/src/connection.dart#L1611)

**Tests (peripheral)**

- Proven-to-fail unit tests for the identity logic (E2/E3/E4, buggy-vs-fixed contrast)
  [`statement_cache_test.dart:359`](../../test/src/statement_cache_test.dart#L359)

- E1 genuine-throw + cached reuse-echo-0 no-throw regression
  [`connection_test.dart:715`](../../test/src/connection_test.dart#L715)

- Dual-env cached single-batch reuse regression (the path the full suite had missed)
  [`streaming_result_set_integration_test.dart:72`](../../test/integration/streaming_result_set_integration_test.dart#L72)
