---
title: 'resetExecuteInstrumentation() scope boundary — document excluded counters'
type: 'docs'
created: '2026-06-25'
status: 'done'
baseline_commit: '0788170b6c4bc436e02936c08b83af12d17d9ce7'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Deferred-work concern (item 5, "## Open"):** "`resetExecuteInstrumentation()`
excludes `_sequence`, `_lobReadOps`, and `_describeRetries` from reset scope.
Correct for the current VARCHAR2-only `NLS_DATABASE_PARAMETERS` detection query.
If any future Epic 10 story changes the detection query to read a LOB column,
these counters would carry detection footprint into post-connect instrumentation
assertions. Note this scope boundary when modifying
`resetExecuteInstrumentation()`. [lib/src/transport/transport.dart]"

**Goal:** This is a SCOPE-BOUNDARY NOTE, not a bug. It does NOT ask for a
behavior change. It asks that the boundary be DOCUMENTED in-code so a future
change to the detection query does not silently carry detection footprint into
post-connect instrumentation assertions. Confirm the exclusion is still correct
today; if so, record the excluded counters, why each exclusion is currently
correct, and the precise condition under which the exclusion would become wrong.
If the exclusion is actually wrong today, fix it and dual-env validate instead.

</frozen-after-approval>

## Investigation (verified against current source @ 0788170)

### What `resetExecuteInstrumentation()` resets today

`Transport.resetExecuteInstrumentation()` (lib/src/transport/transport.dart)
resets exactly two counters to zero:

- `_fullParseExecutes` (exposed as `debugFullParseExecutes`)
- `_reuseExecutes` (exposed as `debugReuseExecutes`)

It is called from exactly one site: `OracleConnection._detectCharsetInfo()`
(lib/src/connection.dart:1095), immediately after the internal startup
charset-detection query succeeds and before the connection is handed to the
caller. Its purpose is to erase the detection round trip's parse/reuse footprint
so post-connect instrumentation (tests, pool diagnostics) observes only user
work (Story 10.1, AC6).

### The three excluded counters and why the exclusion is correct TODAY

The detection query is `_charsetDetectionSql` (connection.dart:1039):
`SELECT parameter, value FROM nls_database_parameters WHERE parameter IN
('NLS_CHARACTERSET', 'NLS_NCHAR_CHARACTERSET')` — **two VARCHAR2 columns**, run
**uncacheable** (`forceUncacheable: true`, connection.dart:1075).

- **`_sequence`** (transport.dart, the TTC packet sequence byte advanced by
  `nextSequence()`). This is **wire protocol state, not a footprint counter**.
  The detection round trip *does* advance it, and it MUST stay advanced —
  rewinding it would desync the server's sequence tracking on the next message.
  Excluding it is not just acceptable, it is required. It must never be reset
  here under any future change.

- **`_lobReadOps`** (transport.dart:501, exposed as `debugLobReadOps`).
  Incremented only by `sendLobOp(...)` with `tnsLobOpRead` (transport.dart:867).
  The current VARCHAR2-only detection query issues **no LOB READ**, so the
  counter is still `0` when reset runs. There is nothing to reset.

- **`_describeRetries`** (lib/src/connection.dart:291, exposed as
  `debugDescribeRetries`). NOTE: this counter lives on `OracleConnection`, NOT
  on `Transport` (the deferred-work note slightly mislocated it). It is
  incremented only by a cached-query ORA-01007/00932 describe-mismatch
  re-execute (connection.dart:1480). Detection is forced **uncacheable**, and a
  fresh connection has nothing to mismatch against, so the retry path can never
  fire for the detection query. There is nothing to reset.

**Conclusion: the exclusion is correct today.** No counter currently carries
detection footprint past the reset, so this is a documentation task, not a fix.

### The future-risk condition

If a later Epic 10 story rewrites the detection query to read a **LOB column**
(advancing `_lobReadOps`) — or makes it cacheable in a way that could trip a
describe-mismatch retry (advancing `_describeRetries`) — that footprint would
then survive the reset and leak into post-connect instrumentation that tests and
pool diagnostics assert on. At that point the reset must be widened to cover the
newly-advanced counter (and `_describeRetries` would need resetting from the
connection-side path, since it lives on `OracleConnection`). `_sequence` always
stays excluded.

## Resolution

**Doc-only change.** No runtime behavior changed; the method body still resets
only `_fullParseExecutes` and `_reuseExecutes`.

1. Expanded the doc comment on `Transport.resetExecuteInstrumentation()` with a
   "SCOPE BOUNDARY" section naming each excluded counter, the invariant that
   makes its exclusion correct for the current VARCHAR2-only detection query, and
   a "WARNING for a future change" describing the LOB-column / cacheable
   condition under which the exclusion becomes wrong and the reset must be
   widened. Added a short in-body comment at the reset site pointing back to that
   note. [lib/src/transport/transport.dart]

2. Added a cross-reference on `OracleConnection._charsetDetectionSql` so the next
   person editing the detection query is warned to read the scope-boundary note
   before reading a LOB column or making the query cacheable.
   [lib/src/connection.dart]

No unit/assertion test was added: the invariant being documented is "the
detection query does not advance `_lobReadOps`/`_describeRetries`", which is
already covered by the existing Story 10.1 charset-detection unit tests
(`detectCharsetInfoForTesting`) and the post-connect instrumentation assertions;
there is no clean seam to pin it more tightly without contorting the code, which
the task explicitly forbade.

## Acceptance Criteria

**AC1 — Exclusion verified correct today**
- GIVEN the current `_charsetDetectionSql` (two VARCHAR2 columns, uncacheable)
- WHEN `resetExecuteInstrumentation()` runs after detection
- THEN `_sequence` is intentionally left advanced (wire state), and `_lobReadOps`
  and `_describeRetries` were never advanced by detection, so excluding them
  carries no footprint into post-connect instrumentation.

**AC2 — Scope boundary documented in-code**
- GIVEN a future developer editing `resetExecuteInstrumentation()` or the
  detection query
- WHEN they read the method's doc comment / the `_charsetDetectionSql` doc comment
- THEN they find which counters are excluded, why the exclusion is correct now,
  and the precise condition (detection reads a LOB column / becomes cacheable)
  under which the reset must be widened.

**AC3 — No behavior change, analysis clean**
- GIVEN the doc-only edits
- WHEN `dart analyze` runs on the edited files
- THEN it reports zero issues, AND the method body is byte-for-byte unchanged in
  effect (still resets only the two parse/reuse counters).

**AC4 — Focused unit suite green**
- GIVEN the doc-only edits
- WHEN `dart test test/src/transport/transport_test.dart` runs
- THEN all transport unit tests pass (no regression).

## Validation results

- `dart analyze lib/src/transport/transport.dart lib/src/connection.dart` —
  "No issues found!"
- `dart test test/src/transport/transport_test.dart` — 55/55 passed.
- Dual-env integration run NOT required: documentation-only change, no runtime
  behavior altered, no integration test added (per the Quick Dev validation
  rule).
