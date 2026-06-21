---
title: 'Reap embedded-cursor server ids when fail-loud describe validation fires'
type: 'bugfix'
created: '2026-06-21'
status: 'done'
baseline_commit: 84d013dab7541ec791860d1e547cdcc21d10e1b0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** When a REF CURSOR OUT bind (B1) or PL/SQL implicit result (B2) carries an *unsupported* nested-cursor / zero-column embedded describe, the decoder fails loud (correct) but leaks the server cursor: the describe is encoded on the wire BEFORE the UB2 server cursor id, so `_readEmbeddedCursorDescribe` throws before the id is read, and the close-cursor piggyback queue never sees that id. B2 has the same defect — `ImplicitResultDecodeException` carries only *previously* decoded ids, never the current failing one.

**Approach:** The describe block is fully byte-parseable; the rejection is *semantic*, not byte-level. Separate validation from byte-consumption: parse the describe leniently so the cursor id is reached and read, THEN apply strict validation and throw — carrying the now-known cursor id for reaping. The thrown validation error is unchanged (same code, same message, still throws). The connection layer queues the carried id through the existing `requeueCursorsToClose` piggyback.

## Boundaries & Constraints

**Always:** Fail-loud is preserved verbatim — nested `CURSOR(...)` columns and zero-column / id-0 descriptors MUST still throw the same `OracleException` (same `errorCode`, same message substring) on BOTH 23ai and 21c. The fix only ensures the server cursor id is QUEUED FOR CLOSE before the error escapes. Mirror node-oracledb wire order (`createCursorFromDescribe` then `readUB2`). Use `test_helper.dart` getters for integration tests — never hardcode port/service/creds.

**Ask First:** Any change that would alter WHICH inputs fail loud, or that selects behaviour by server version.

**Never:** Do NOT make nested cursors inside REF CURSOR OUT binds / implicit results actually work (that is deferred item A, an epic). Do NOT relax `_isSupportedRefCursorColumn`. Do NOT swallow / downgrade the validation error. Do NOT change the lenient completion-probe path's outcome.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| B1 unsupported nested cursor in OUT bind | ROW_DATA cursor value: describe with a `oraTypeCursor` column, then UB2 id=N | throws `oraUnsupportedType` ("column type 102"); id N queued for close | error rethrown to caller |
| B1 zero-column OUT-bind describe | describe numCols=0, then UB2 id=N | throws `oraProtocolError` ("zero columns"); id N queued | rethrown |
| B1 valid OUT-bind cursor | supported columns, UB2 id=N | `DecodedCursorResult(cursorId=N)`; nothing extra queued | N/A |
| B1 id=0 OUT bind | supported describe, UB2 id=0 | throws ("cursor id = 0"); nothing to queue (id is 0) | rethrown |
| B2 unsupported/zero-col implicit (1st & only) | type-27, one result, bad describe, id=N | `ImplicitResultDecodeException` carrying `[N]`; id N queued | rethrown |
| B2 bad result after a good one | result A id=401 (ok), result B bad describe id=402 | exception carries `[401, 402]`; both queued | rethrown |
| Completion probe (lenient) | any of the above | consumes bytes, no throw, no accumulation | unchanged |

</frozen-after-approval>

## Code Map

- `lib/src/protocol/messages/execute_message.dart` -- `_readEmbeddedCursorDescribe` (defer validation), `_decodeValueByOraType` cursor branch (B1: read id then throw carrying it), `_processImplicitResultSet` (B2: include current id), `ImplicitResultDecodeException`, new typed carrier for the OUT-bind cursor failure.
- `lib/src/connection.dart` -- `_openCursor` catch (reap the B1 carried id), already reaps `ImplicitResultDecodeException.cursorIds` (B2 needs only the id-set fix upstream).
- `lib/src/statement_cache.dart` -- `requeueCursorsToClose` / `pendingCloseCount` (the reaping queue + `debugPendingCloseCount` seam).
- `test/src/protocol/messages/execute_message_test.dart` -- unit fixtures `_cursorOutBindValue`, `_implicitResultSet`.
- `test/integration/ref_cursor_implicit_coexistence_integration_test.dart` -- dual-env fail-loud + reaping regression.

## Tasks & Acceptance

**Execution:**
- [ ] `lib/src/protocol/messages/execute_message.dart` -- refactor `_readEmbeddedCursorDescribe` so the strict pass consumes ALL descriptor bytes (lenient byte-walk) and returns the columns plus the FIRST validation failure (unsupported column / zero columns) as a deferred error instead of throwing inline. Caller reads the UB2 id, then throws the deferred error carrying that id.
- [ ] `lib/src/protocol/messages/execute_message.dart` -- B1: in the `oraTypeCursor` branch, after reading the cursor id, if a deferred validation error exists throw a new `EmbeddedCursorDecodeException(cursorId: N, ...)` (subtype of `OracleException`) so the connection layer can reap N. Preserve the id-0 throw unchanged.
- [ ] `lib/src/protocol/messages/execute_message.dart` -- B2: in `_processImplicitResultSet`, read the id after the (now lenient) describe, then if a deferred validation error exists throw `ImplicitResultDecodeException` whose `cursorIds` includes prior ids AND the current id.
- [ ] `lib/src/connection.dart` -- `_openCursor` catch: reap `EmbeddedCursorDecodeException.cursorId` via `requeueCursorsToClose`, alongside the existing `ImplicitResultDecodeException` handling.
- [ ] `test/src/protocol/messages/execute_message_test.dart` -- unit tests proving the carried id (B1 `EmbeddedCursorDecodeException.cursorId`; B2 current id appended to `cursorIds`) for unsupported + zero-column descriptors; assert the validation error is unchanged. Proven-to-fail against unpatched code.
- [ ] `test/integration/ref_cursor_implicit_coexistence_integration_test.dart` -- dual-env: an unsupported nested cursor inside a REF CURSOR OUT bind AND inside an implicit result still fails loud, AND `debugPendingCloseCount` reflects the reaped id (connection stays reusable).

**Acceptance Criteria:**
- Given an unsupported/zero-column embedded describe in a REF CURSOR OUT bind, when decoded, then the same fail-loud `OracleException` is thrown AND its server cursor id is queued for close.
- Given the same inside an implicit result, when decoded, then `ImplicitResultDecodeException.cursorIds` includes the current failing cursor id (plus any prior).
- Given a valid descriptor, when decoded, then behaviour is byte-for-byte unchanged (no spurious queueing).
- `dart analyze` clean; focused unit suite green; integration suites green on 23ai AND 21c.

## Spec Change Log

- **2026-06-21 (adversarial review — Edge-Case Hunter F1):** First implementation read the cursor id then checked id-0 BEFORE the deferred describe-validation error. For the degenerate input "unsupported/zero-column describe AND trailing id 0", this surfaced the id-0 error instead of the describe-validation error the old inline-throwing code raised — a fail-loud *identity* change (violates the Always invariant "same input → same exception"). Amended both paths to evaluate the deferred `validationError` BEFORE the id-0 check, restoring the exact pre-fix error identity (describe validation always wins, as it did when it threw mid-parse). The id is still read first, so it is reapable; a 0 own-id is omitted from the carried ids (B2) / harmlessly filtered by `requeueCursorsToClose` (B1). Added two regression tests pinning the priority ("a bad describe takes fail-loud priority over the id-0 check", unit, B1 + B2). KEEP: the "parse leniently → read id → throw held error" core mechanism is correct and validated dual-env; only the ordering of the two fail-loud branches changed.

## Design Notes

Wire order (node-oracledb `withData.js`): cursor value = `numBytes(UInt8)` → embedded describe (`processDescribeInfo`) → `cursorId = readUB2()`; implicit result = per result `numBytes+skip` → describe → `readUB2()`. The id is ALWAYS after the describe, so reaching it requires fully consuming the descriptor. The descriptor is byte-parseable regardless of column type — `strict:false` already proves a clean walk. So "parse leniently, capture id, then throw the held validation error" reaches the id WITHOUT weakening validation: the identical error still fires, only after the id is in hand.

Shape: `_readEmbeddedCursorDescribe` returns a small record `({List<ColumnMetadata> columns, OracleException? validationError})`. The strict pass collects (does not throw) the first unsupported-column / zero-column error. The call site reads the id, then evaluates the held `validationError` FIRST (before the id-0 check) — this preserves the exact fail-loud identity the old inline-throwing describe had (a malformed describe always threw before id-0 was ever evaluated; see Spec Change Log). Callers: B1 throws `EmbeddedCursorDecodeException(cursorId, …)`; B2 throws `ImplicitResultDecodeException(cursorIds: prior + [id], …)`, omitting a 0 id. Only when the describe is valid does the id-0 fail-loud (OUT bind) / null-column (SELECT) logic apply, unchanged.

## Verification

**Commands:**
- `dart analyze` -- expected: No issues found.
- `dart test test/src/protocol/messages/execute_message_test.dart` -- expected: all pass.
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color --concurrency=3` -- expected: green (23ai).
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color --concurrency=3` -- expected: green (21c).
