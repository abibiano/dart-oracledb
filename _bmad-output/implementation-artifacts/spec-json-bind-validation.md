---
title: 'JSON bind validation hardening (DW-12)'
type: 'bugfix'
created: '2026-10-09'
status: 'done'
baseline_revision: '570df5beb3d7d3b9c7c7407dd12c0f3ca3ccb9cb'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** JSON bind validation has gaps: no depth/cycle guard (a self-referencing Map overflows the stack), UTC `DateTime` members are stored zone-less, a fetched OSON v3 key over 255 bytes cannot be re-bound, NaN/±Infinity are accepted silently, and one document is validated up to three times.

**Approach:** Per the recorded human decision (DW-12): reject non-finite members by default with an `ArgumentError` naming the member path, with an opt-in `allowNonFinite`; keep a declared-JSON `String` root a valid JSON string scalar (documented). Add depth/cycle guard, encode UTC `DateTime` as TIMESTAMP WITH TIME ZONE (offset 0), encode keys over 255 bytes as OSON v3, and validate once.

## Boundaries & Constraints

**Always:** errors never carry bind values or object keys (member path by ordinal only). Encoder output for existing documents (v1, no UTC, finite) stays byte-identical. Validate on both Oracle 23ai and 21c where a DB is reachable.

**Never:** no edits to the deferred-work ledger or sprint board. No change to the `String`-root meaning. No new connection-level option.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| NaN member | `{'a': [1, double.nan]}` | rejected at call site | `ArgumentError` naming `...[member #1][1]`, no value |
| Opt-in | `OracleBind.inOut(type: json, allowNonFinite: true)` | NaN/Inf encode as BINARY_DOUBLE | none |
| Cycle | `m['self'] = m` | rejected | `ArgumentError` (cyclic) |
| Deep | nesting > 1000 | rejected | `ArgumentError` (depth), no StackOverflowError |
| UTC DateTime | `DateTime.utc(...)` member | TSTZ node, offset 0; round-trips as `OracleTimestampTz` same instant | none |
| Long key | key 256..65535 UTF-8 bytes | OSON version 3, decodes back identically | key over 65535 bytes: rejected |
| String root | declared json, `'x'` | JSON string scalar `"x"` | none |

</intent-contract>

## Code Map

- `lib/src/protocol/oson.dart` -- `assertValidJsonBindValue` / `_assertValidJsonMember` (validator), `_OsonEncoder` (`encode`, `_examine`, `_encodeNode`), `_OsonFieldName`, decoder v3 reader already exists.
- `lib/src/oracle_bind.dart` -- `OracleBind.inOut` + `_validate` json case (add `allowNonFinite`).
- `lib/src/protocol/messages/execute_message.dart` -- `BindVariable` ctor re-validates (add `alreadyValidated`); per-row `BindVariable(` re-wraps at ~529 and ~1001.
- `lib/src/connection.dart` -- bind translation (~4078, ~4129), executeMany validation (~2589, ~3143).
- `reference/node-oracledb/lib/impl/datahandlers/oson.js` -- v3 encoder (`_writeExtendedHeader`, `_writeFieldNamesSeg`).

## Tasks & Acceptance

**Execution:**
- `lib/src/protocol/oson.dart` -- add `allowNonFinite`, depth/cycle guard, long-key (<=65535) acceptance to validator; UTC DateTime to TSTZ node; encoder v3 long-name segment + cycle/depth guard; docs
- `lib/src/oracle_bind.dart`, `lib/src/protocol/messages/execute_message.dart`, `lib/src/connection.dart` -- plumb `allowNonFinite`, skip repeat validation
- `test/src/protocol/oson_test.dart`, `test/src/oracle_bind_test.dart`, `test/integration/json_data_type_integration_test.dart` -- unit and dual-env tests; adjust tests that assumed NaN accepted
- `CHANGELOG.md`, `README.md` -- document behavior

**Acceptance Criteria:**
- Given a Map holding NaN, when bound without opt-in, then `ArgumentError` names the path and omits the value
- Given a cyclic or >1000-deep document, when bound or encoded, then a clean error (no StackOverflowError)
- Given a fetched v3 key over 255 bytes, when re-bound on 23ai, then it round-trips
- Given a UTC DateTime member, when bound and fetched, then the instant is preserved

## Verification

**Commands:**
- `dart analyze` -- expected: no issues
- `dart test test/src` -- expected: pass
- `RUN_INTEGRATION_TESTS=true dart test test/integration/json_data_type_integration_test.dart` (23ai, and 21c with ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1) -- expected: pass
