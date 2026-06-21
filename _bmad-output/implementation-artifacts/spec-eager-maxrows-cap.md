---
title: 'Explicit maxRows cap for eager fetches (node-oracledb parity)'
type: 'feature'
created: '2026-06-21'
status: 'done'
baseline_commit: 'd0c2fdf91f402d39d0729447444f4eb24c4d4ea8'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** node-oracledb lets a caller bound a direct (non-resultSet) execute via
`maxRows` (default `0` = unlimited): `_getAllRows()` returns at most N rows and stops
fetching once N is reached — a deliberate cap, never an error. The Dart driver has no
such public knob; eager draining (both the eager `execute()` SELECT path and eager
implicit-result draining) relies only on the internal `maxFetchIterations` safety
backstop, which Story 9.3 made fail-loud on silent truncation. Callers cannot
intentionally bound a large eager result.

**Approach:** Add an additive, backward-compatible `maxRows` field to
`OracleExecuteOptions` (default `0` = unlimited, matching node-oracledb). Thread it
into the eager SELECT drain and the eager implicit-result drain so a positive N
returns at most N rows and stops fetching cleanly at N. The `maxFetchIterations`
fail-loud backstop is untouched and remains the safety net for the unlimited
(`maxRows == 0`) case.

## Boundaries & Constraints

**Always:**
- Mirror node-oracledb `_getAllRows()` semantics exactly: `0` = unlimited; positive N
  returns at most N rows; stop fetching once N reached; capping is NOT an error.
- Default = current unlimited behavior. Existing callers (and `maxRows: 0`) see no
  change whatsoever.
- A `maxRows`-capped result reports `moreRowsAvailable` honestly (capped at N while the
  server still has rows ⇒ `true`).
- `maxRows` must accept `>= 0` only; reject negatives with `ArgumentError` before any
  wire round trip (matches node-oracledb's `assertParamPropValue(... >= 0)`).
- Dual-env: integration tests pass on BOTH Oracle 23ai (1521/FREEPDB1) and 21c
  (1522/XEPDB1). `dart analyze` zero issues.

**Ask First:**
- Extending `maxRows` to the streaming/`resultSet: true` path. (Decision below: NOT in
  scope — streaming already bounds via pull-based `getRows(n)`.)

**Never:**
- Weaken the Story 9.3 fail-loud `maxFetchIterations` backstop or the
  no-silent-truncation contract for the unlimited case.
- Apply `maxRows` to DML rowsAffected, OUT binds, or the lazy `resultSet: true` paths.
- Fetch more rows from the server than necessary once the cap is reached.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Default unlimited | `maxRows` omitted or `0`, result has M rows | all M rows; behavior byte-identical to today | N/A |
| Cap below total (multi-batch) | `maxRows: N`, result has > N rows | exactly N rows; no fetch past N; `moreRowsAvailable == true` | N/A (deliberate cap) |
| Cap at first-batch boundary | `maxRows: N` ≤ first prefetch batch size | exactly N rows; ZERO continuation FETCH round trips | N/A |
| Cap ≥ total | `maxRows: N` ≥ M total rows | all M rows; `moreRowsAvailable == false` | N/A |
| Eager implicit cap | PL/SQL implicit cursor with > N rows, `maxRows: N` | each implicit result capped at exactly N rows | N/A |
| Negative | `maxRows: -1` | throws before any wire write | `ArgumentError` |

</frozen-after-approval>

## Code Map

- `lib/src/connection.dart` -- `OracleExecuteOptions` (add `maxRows` field + validation);
  `_executeGuarded` (thread cap into eager SELECT drain + `_drainImplicitResults`);
  `execute()` (validate `maxRows >= 0`, pass through). `_drainOneImplicitResult` takes
  the cap.
- `lib/src/protocol/result_set_cursor.dart` -- `drainRemaining` gains an optional
  `maxRows` cap: stop fetching once N buffered, truncate to exactly N, leave
  `incompleteDrain` as the backstop-only signal. The new cap must NOT trip
  `incompleteDrain` (it is a deliberate stop, not the safety backstop).
- `test/integration/eager_maxrows_integration_test.dart` -- dual-env proof.
- `test/src/protocol/result_set_cursor_test.dart` (or new) -- unit boundary tests if a
  pure-unit harness exists; otherwise rely on integration + a focused fake-transport
  unit if feasible.
- `README.md` -- one-line mention under the execute-options surface if present.

## Tasks & Acceptance

**Execution:**
- [ ] `lib/src/protocol/result_set_cursor.dart` -- add `int maxRows = 0` to
  `drainRemaining`; cap+stop+truncate without setting `incompleteDrain`.
- [ ] `lib/src/connection.dart` -- add `maxRows` to `OracleExecuteOptions` (default 0,
  dartdoc); validate `>= 0` in `execute()`; thread through `_executeGuarded`,
  `_drainImplicitResults`, `_drainOneImplicitResult`; set `moreRowsToFetch` honestly.
- [ ] `test/integration/eager_maxrows_integration_test.dart` -- maxRows=N caps eager
  SELECT and eager implicit to exactly N over a > N (multi-batch) result; maxRows=0
  returns all; negative throws. Dual-env header.
- [ ] README -- one-line `maxRows` mention if an OracleExecuteOptions/execute-options
  section exists.

**Acceptance Criteria:**
- Given a SELECT producing > N rows (N spanning >1 prefetch batch), when executed with
  `OracleExecuteOptions(maxRows: N)`, then `result.rows` has exactly N rows and
  `result.moreRowsAvailable` is `true`.
- Given a PL/SQL block whose implicit result has > N rows, when executed with
  `maxRows: N`, then the eager `List<OracleRow>` has exactly N rows.
- Given `maxRows: 0` (or omitted), when executed, then all rows are returned —
  identical to the pre-change behavior.
- Given `maxRows: -1`, when `execute()` is called, then it throws `ArgumentError`
  before any wire round trip.
- `dart analyze` reports zero issues; full integration suite green on 23ai AND 21c.

## Spec Change Log

- 2026-06-21 (implementation): README NOT touched — the README has no
  `OracleExecuteOptions` / execute-options section, and the sibling options
  (`resultSet`, `fetchSize`) are documented in dartdoc only. `maxRows` follows
  the same convention (full dartdoc on `OracleExecuteOptions.maxRows`); adding a
  lone README options section was out of scope.
- 2026-06-21 (implementation): added the cursor-level `maxRowsCapped` signal
  (distinct from `incompleteDrain`) so a deliberate cap drives
  `moreRowsAvailable` without ever tripping the Story 9.3 fail-loud backstop
  throw. Single-batch SELECT (whole result in the first EXECUTE batch, larger
  than N) is trimmed in `connection.dart`, since `drainRemaining` cannot
  "un-fetch" an already-delivered batch.

## Design Notes

**Reference semantics (confirmed, node-oracledb):**
- `lib/settings.js:49` `this.maxRows = 0` (default unlimited);
  `lib/oracledb.js:1724` and `lib/connection.js:678-681` validate integer `>= 0`.
- `lib/resultset.js:51-86` `_getAllRows()`:
  ```js
  while (true) {
    if (maxRows > 0 && fetchArraySize >= maxRows) fetchArraySize = maxRows; // clamp last fetch
    const rows = await this._getRows(fetchArraySize);
    ... rowsFetched = rowsFetched.concat(rows);
    if (rows.length == maxRows || rows.length < fetchArraySize) break; // cap hit OR exhausted
    if (maxRows > 0) maxRows -= rows.length;
  }
  ```
  So: stop once N reached; never fetch more than needed (clamps `fetchArraySize` down,
  so `maxRows < prefetch` works); the cap is a clean stop, NOT an error.

**Dart adaptation:** the EXECUTE already delivers the first batch (up to prefetch 50
rows) in `firstBatch`/`_buffer`, then `drainRemaining` continues. The faithful mapping:
in `drainRemaining`, after seeding from the buffer, if `maxRows > 0 && out.length >= N`
truncate to N and return (no continuation FETCH); otherwise keep fetching but stop the
loop the moment `out.length >= N`, then truncate to exactly N. Because a continuation
FETCH may overshoot N within a batch, truncating after each addition is the simplest
correct mapping (we cannot retroactively un-fetch a batch, but we never issue a FETCH
once N is already buffered — matching node-oracledb's "the rest are simply not
fetched"). The cap stop must NOT set `incompleteDrain`: that flag is reserved for the
`maxFetchIterations` backstop / no-cursor case and drives the Story 9.3 fail-loud throw
on the implicit path. `moreRowsAvailable`/`moreRowsToFetch` for a capped SELECT is set
from "cursor still had rows when we stopped" so callers can tell a cap apart from a
full drain.

**API-surface decision (documented + flagged):** `maxRows` lives on
`OracleExecuteOptions` (`OracleExecuteOptions(maxRows: 0)` default-unlimited) — the
node-oracledb-faithful, minimal, additive surface. It bounds ONLY the two EAGER paths:
the eager `execute()` SELECT drain and eager implicit-result draining. It is
intentionally a no-op for `resultSet: true` (streaming already bounds via pull-based
`getRows(n)`) and for DML/OUT binds (no row set to cap). This matches node-oracledb,
where `maxRows` shapes the direct-execute `rows` array, not a live ResultSet.

## Verification

**Commands:**
- `dart analyze` -- expected: No issues found.
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color --concurrency=3`
  -- expected: all pass (23ai baseline 382/8-skip + new cases).
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color --concurrency=3`
  -- expected: all pass (21c baseline 383/7-skip + new cases).
