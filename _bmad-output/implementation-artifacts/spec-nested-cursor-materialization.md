---
title: 'Materialize nested CURSOR() columns inside REF CURSOR OUT binds and PL/SQL implicit results'
type: 'feature-plan'
created: '2026-06-21'
status: 'closed-no-go'  # S0 spike (2026-06-22) proved 21c cannot materialize this; permanent (evidence-backed) deferral. See "## S0 findings".
baseline_commit: d60e19091e1446038f083e2b3a4587874cac4ab2
context:
  - _bmad-output/implementation-artifacts/deferred-work.md (deferred item "A")
  - _bmad-output/implementation-artifacts/9-4-dual-env-integration-tests.md (AC3 deferral + raw 21c capture)
  - _bmad-output/implementation-artifacts/9-2-nested-cursors.md (top-level SELECT nested-cursor materialization, already shipped)
---

> **THIS IS A PLAN, NOT AN IMPLEMENTED SPEC.** `status: draft`. No production
> code change is associated with this document. The current driver behaviour —
> fail-loud (`oraUnsupportedType`, "column type 102") consistently on both 23ai
> and 21c, with B1/B2 cursor-id reaping intact — is unchanged and must remain so
> until an epic built from this plan lands with full dual-env validation.

## Goal

Decode and materialize a nested `CURSOR(SELECT ...)` column (Oracle type 102)
that appears **inside an embedded cursor describe** — i.e. one level below the
top level — in either of two carriers:

1. a **PL/SQL implicit result** (`DBMS_SQL.RETURN_RESULT`, TTC message type 27); and
2. a **REF CURSOR OUT bind** (`SYS_REFCURSOR`).

Today both fail loud at decode time (correctly, consistently on both server
versions). The top-level-SELECT equivalent (a `CURSOR()` column in the outer
projection) already materializes on both 23ai and 21c — shipped in Story 9.2.
The gap is purely the nested-inside-embedded-describe case.

## What is already in place (do NOT rebuild)

The driver already owns the entire materialization toolkit; this plan REUSES it
rather than inventing new machinery:

- `connection.dart _materializeNestedCursorsInBatch` / `_drainNestedCursor` —
  drains a `DecodedCursorResult` over the shared `ResultSetCursor` engine
  (multi-batch FETCH continuation, per-batch LOB materialization, fail-loud,
  close-cursor-piggyback reaping). Proven dual-env by Story 9.2 for top-level
  SELECT cursor columns.
- `connection.dart _drainOneImplicitResult` / `_wrapImplicitResultsLazy` —
  eager + lazy implicit-result drains; both ALREADY call
  `cursorColumnIndicesOf(descriptor.columns)` and run
  `_materializeNestedCursorsInBatch` / wire `onBatchDecoded` when the implicit
  result's own columns contain a cursor. The wiring assumes the nested
  `DecodedCursorResult` is fully populated (columns + cursorId).
- `connection.dart _wrapRefCursorOutBinds` — wraps a top-level REF CURSOR OUT
  bind into an `OracleResultSet`. It does **not** currently thread
  `onBatchDecoded`, so even if the embedded describe decoded a nested cursor
  column, the OUT-bind result set would surface raw `DecodedCursorResult`
  values. This is a known wiring gap (see Story breakdown S3).
- `execute_message.dart _readEmbeddedCursorDescribe` / `_decodeValueByOraType`
  (`oraTypeCursor` branch) / `_processImplicitResultSet` — decode an embedded
  describe and the per-row cursor value. The single guard that blocks the
  feature is `_isSupportedRefCursorColumn` returning `false` for `oraTypeCursor`.

So the "happy path" is small **IF the wire actually carries the nested cursor's
describe**. It does on 23ai. It does NOT on 21c. That asymmetry is the whole
feature.

## Wire-protocol findings (the crux)

### 23ai — inline describe present

When a nested `CURSOR()` column appears inside an implicit-result row (or a REF
CURSOR OUT bind row), the per-row cursor **value** on 23ai is the same shape the
top-level path already handles:

```
numBytes(UInt8=1) + embedded-describe-block + cursorId(UB2)
```

The embedded-describe-block fully describes the nested cursor's columns inline.
`_readEmbeddedCursorDescribe` can decode it; `_decodeValueByOraType` already
reads exactly this layout for the OUTER cursor. Lifting the
`_isSupportedRefCursorColumn` guard for `oraTypeCursor` and letting recursion
flow would make 23ai work with a very small change — this is the "3-line patch"
the prior investigation noted.

### 21c (pre-23) — inline describe ABSENT (verified by live capture)

Raw 21c capture (Story 9.4 dev-story, `ttcFieldVersion=16`, instrumentation
since removed): the per-row nested cursor value was literally

```
02 01 0c   →  numBytes(02) + cursorId UB2 = 0x000c  (id 12)
02 01 0d   →  id 13
02 01 0e   →  id 14
```

i.e. **`numBytes(1) + cursorId(UB2)` with NO embedded describe**. The type-27
EXECUTE describe (136 bytes) carried the *implicit* cursor's `ID` + `NC` columns
but NOT the nested cursor's column structure. Feeding these bytes to
`_readEmbeddedCursorDescribe` sheared the stream
(`Integer too large: size=7 exceeds maxSize=4`) and poisoned the connection.

### Why node-oracledb is not a turnkey reference here

node-oracledb `withData.js processColumnData` (cursor branch, ~L348-364) calls
`createCursorFromDescribe(buf)` **unconditionally** — it always expects the
inline describe — then `readUB2()` for the cursor id, and sets
`statement.requiresFullExecute = true`. `requiresFullExecute` is NOT a
describe round-trip: it only forces the FIRST fetch of that already-open server
cursor to use a full `ExecuteMessage` (OAL8) instead of the simpler
`FetchMessage` (OFETCH) — see `resultSet.js _fetchMoreRows` (~L42) and
`execute.js encode` (~L324). The describe is assumed already in hand from the
inline bytes.

**Implication:** node-oracledb's thin client, run against the exact 21c
implicit-result byte stream captured above, would also call
`createCursorFromDescribe` expecting an inline describe that 21c did not send —
i.e. node-oracledb does not have a different "fetch the missing nested describe"
path either. The nested-cursor-inside-implicit-result combination appears to be
effectively a **23ai-and-later capability** in the reference client too. This is
the single most important risk this plan surfaces: **before committing to
build the 21c path, an explicit experiment must determine whether 21c can be
made to materialize this combination AT ALL, and if so by what mechanism** (see
S0 below). If the answer is "21c cannot", the only project-rule-compliant
outcome is to keep the feature fail-loud on 21c — which means the feature as
specified (dual-env) is **not deliverable**, and the deferral stands
permanently with that rationale recorded.

### The candidate 21c mechanism (DISPROVEN by the S0 spike — see "## S0 findings")

> **Status after S0 (2026-06-22): DISPROVEN.** On a live 21c server the bare
> nested cursorId yields NO out-of-band describe by any RPC tried, and 21c
> additionally refuses to deliver the nested cursor's row data to a client that
> never received its describe. The mechanism below was the hypothesis; the
> empirical result is in the "## S0 findings" section. It is retained here for
> the record, not as a buildable design.

If 21c is to work, the missing nested describe must be obtained out-of-band. The
plausible mechanism, by analogy to how the driver already drives an open cursor:
the nested cursor id (12/13/14 above) is a live server cursor. Issue a
**fresh EXECUTE (OAL8) carrying that existing cursorId** (cursorId != 0, so it
re-executes the open cursor) WITHOUT a cached describe — the server then returns
a DESCRIBE_INFO for that cursor followed by its first ROW_HEADER/ROW_DATA batch.
This is exactly the `requiresFullExecute` shape, except the driver would consume
the DESCRIBE_INFO it gets back (which the top-level path already parses) rather
than relying on a pre-supplied `columns` list. This is a genuinely NEW transport
capability: today `ResultSetCursor`/`_transport.fetchRows` issues OFETCH against
a KNOWN-columns cursor; here the columns are UNKNOWN until the round trip
returns. It needs:
- a new transport entry point: "EXECUTE an already-open cursor id with no
  client-side describe, return the server DESCRIBE_INFO + first batch";
- decode-path support for a self-describing FETCH/EXECUTE response in the
  nested-drain context (the existing `decodeExecuteResponse` already handles
  DESCRIBE_INFO, so this is mostly threading, not new decode);
- careful sequencing so the extra round trip happens at materialization time,
  inside `_drainNestedCursor`, gated on "describe absent" (columns empty).

**Open empirical questions S0 must answer on a live 21c server:**
1. Does an EXECUTE with the existing nested cursorId actually return a
   DESCRIBE_INFO + rows for that cursor? (node-oracledb does NOT do this, so
   there is no reference precedent — it must be observed.)
2. Is the nested cursor still open/valid by the time the outer result is being
   drained (cursor lifetime / prefetch interactions)?
3. Does this interact safely with the close-cursor piggyback and the
   single-in-flight-operation guard?

## Boundaries & Constraints

**Always:** Preserve fail-loud verbatim for any case the new path cannot
materialize — same `errorCode` (`oraUnsupportedType`), same "column type 102"
message substring — and keep B1/B2 reaping
(`EmbeddedCursorDecodeException.cursorId`,
`ImplicitResultDecodeException.cursorIds`) intact. Thread `ttcFieldVersion`
into every embedded-describe path (Story 9.2 found 21c mis-parses at default
24). Use `test_helper.dart` getters in integration tests. Mirror node-oracledb
wire order where a reference exists.

**Ask First / Gate:** S0's empirical outcome gates the entire epic. If 21c
cannot materialize this combination, STOP — do not ship a 23ai-only path
(violates the absolute dual-env rule); record the permanent deferral instead.

**Never:** Do NOT weaken `_isSupportedRefCursorColumn` (or any guard) on one
server version only. Do NOT enable 23ai while 21c stays fail-loud — both must
materialize, or both stay fail-loud. Do NOT silently truncate a nested result.

## Touch-points

| File | Change |
|------|--------|
| `lib/src/protocol/messages/execute_message.dart` | Allow `oraTypeCursor` in `_isSupportedRefCursorColumn` (recursion guard: reject only a cursor nested >1 level if unsupported). `_decodeValueByOraType` `oraTypeCursor` branch already reads the 23ai inline shape; add a path for the 21c id-only shape (`numBytes(1) + cursorId(UB2)`, columns empty → defer describe to drain time). Distinguish the two shapes by remaining-bytes / a describe-present probe. |
| `lib/src/connection.dart` | `_drainNestedCursor`: when `decoded.columns` is empty (21c id-only), perform the new "EXECUTE-open-cursor, consume returned DESCRIBE_INFO + first batch" round trip before draining. `_wrapRefCursorOutBinds`: thread `onBatchDecoded` so OUT-bind result sets materialize nested cursors (S3). |
| `lib/src/transport/transport.dart` | New entry point: EXECUTE an existing cursorId with no client describe; return server `DESCRIBE_INFO` + first batch (the 21c describe round trip). |
| `lib/src/protocol/result_set_cursor.dart` | Optionally support a "describe-on-first-fetch" mode so the nested drain can adopt server-returned columns. |
| Tests | Unit: 23ai inline-describe nested-cursor decode; 21c id-only decode → deferred describe. Integration (dual-env): nested `CURSOR()` inside an implicit result AND inside a REF CURSOR OUT bind materialize to `List<OracleRow>` — empty nested cursor `[]`, multi-batch nested drain, eager + lazy modes — on BOTH 23ai and 21c. Plus: fail-loud + reaping retained for any genuinely unsupported inner column. |

## Suggested epic / story breakdown

- **S0 — 21c feasibility spike (BLOCKING gate, no production code).** On a live
  21c server, instrument the transport to capture the implicit-result + REF
  CURSOR-OUT-bind streams with a nested cursor, and experimentally drive an
  EXECUTE against the bare nested cursorId to see whether 21c returns a usable
  DESCRIBE_INFO + rows. Decide GO/NO-GO for the whole epic. Output: a findings
  note updating this spec's "candidate 21c mechanism" section with proven
  behaviour. If NO-GO, the epic ends here and the permanent deferral is
  recorded.
- **S1 — 23ai inline-describe path.** Lift the guard for `oraTypeCursor` in
  embedded describes; let the existing materialization wiring decode the inline
  describe. Unit + 23ai integration green. (Do NOT commit alone — would be a
  23ai-only enablement, which is forbidden; land only together with S2.)
- **S2 — 21c describe round-trip transport capability.** Implement the new
  transport entry point and the decode-on-first-fetch nested drain. 21c
  integration green. Land S1+S2 together so neither version regresses to a
  one-sided enablement.
- **S3 — REF CURSOR OUT-bind wiring.** Thread `onBatchDecoded` through
  `_wrapRefCursorOutBinds` (eager + lazy) so OUT-bind result sets materialize
  nested cursors identically to implicit results. Dual-env integration.
- **S4 — adversarial review + dual-env closeout.** Edge cases: empty nested
  cursor, multi-batch nested drain, NULL nested cursor (id 0), a genuinely
  unsupported inner column still fails loud + reaps, close-cursor piggyback
  dedup across the extra round trip, single-in-flight-operation guard not
  tripped by the nested EXECUTE. Re-run full dual-env (baseline 23ai 389/8-skip,
  21c 390/7-skip), `dart analyze` clean.

## Risks

- **R1 (highest): 21c may be unable to materialize this combination at all.**
  The reference client has no nested-describe-fetch path; the 21c server omits
  the nested describe. If S0 shows 21c cannot return a usable describe for the
  bare nested cursorId, the dual-env feature is undeliverable and the deferral
  becomes permanent (recorded with rationale). This is the likely outcome and
  must be settled in S0 before any build effort.
- **R2: new transport round trip vs the single-in-flight-operation guard.** The
  nested describe/EXECUTE happens mid-drain of an outer result; it must not be
  rejected by `_rejectConcurrentOperation` nor corrupt the outer cursor's FETCH
  sequencing.
- **R3: cursor lifetime.** The nested cursor ids must still be open when
  materialization runs; eager drain order and prefetch windows could close them
  early. Needs explicit ordering guarantees + reaping correctness.
- **R4: shape disambiguation.** Reliably distinguishing the 23ai inline-describe
  value from the 21c id-only value at decode time (without server-version
  branching in the decoder, per project rule) requires a structural probe
  (e.g. describe-present-by-remaining-bytes), which is fragile and must be
  unit-pinned with hand-crafted fixtures for both shapes.

## S0 findings (2026-06-22)

Executed the S0 feasibility spike on live 23ai (`localhost:1521/FREEPDB1`,
`ttcFieldVersion=24`) and live 21c (`localhost:1522/XEPDB1`,
`ttcFieldVersion=16`). All instrumentation was throwaway and has been fully
reverted (`git diff --stat -- lib/` shows zero net change); no production code
was modified. Reproduction fixture: the implicit-result-with-nested-`CURSOR()`
block from `ref_cursor_implicit_coexistence_integration_test.dart`
(parent→child, parent 1 has children 10/20/30).

### Reference (node-oracledb) — confirms NO precedent for an out-of-band fetch

Verified the spec's reference claims against the bundled thin client:

- `lib/thin/protocol/messages/withData.js` `processColumnData`
  (`TNS_DATA_TYPE_CURSOR` branch, L348-364): calls `createCursorFromDescribe(buf)`
  **unconditionally**, then `readUB2()` for the id. There is NO branch for an
  id-only nested cursor value — it always expects an inline describe.
- `createCursorFromDescribe` (withData.js L762-769): calls
  `processDescribeInfo(buf, resultSet)` (reads the inline describe from the
  buffer) and sets `requiresFullExecute = true`. The describe MUST already be in
  the byte stream.
- `requiresFullExecute` is NOT a describe round trip:
  `resultSet.js _fetchMoreRows` (L41-46) merely chooses `ExecuteMessage`
  (full OAL8) over `FetchMessage` (OFETCH) for the FIRST fetch of the
  already-open cursor; `execute.js writeReExecuteMessage`/`writeExecuteMessage`
  (L236-281 / L63-199) re-execute the open cursorId and do not re-request a
  describe.

**Conclusion: node-oracledb has no "fetch the missing nested describe" path.**
The nested-cursor-inside-implicit-result combination is effectively a
23ai-and-later capability in the reference client too. The candidate 21c
mechanism therefore had no reference precedent and had to be observed.

### Wire shapes confirmed (raw bytes)

**EXECUTE of the block** (both versions): returns only the type-27
implicit-result message carrying the *implicit* cursor's describe — columns
`ID` (NUMBER, type 2) and `NC` (CURSOR, type 102) — plus the implicit cursor id.
The fail-loud (`ImplicitResultDecodeException`, "Unsupported SYS_REFCURSOR column
type 102 for column NC") fires here, at the implicit cursor's *describe*; the
per-row nested-cursor values are NOT in this response.

**FETCH of the implicit cursor** (the per-row `NC` value):

- **23ai** — INLINE describe present. Each row's `NC` value is
  `numBytes(0x4C=76) + <76-byte embedded describe> + UB2 cursorId`. Confirmed
  nested ids 4/5/6 with a full inline describe per row.
- **21c** — ID-ONLY. Each row's `NC` value is literally `02 01 04`, `02 01 05`,
  `02 01 06` = `numBytes(0x02) + UB2 cursorId(01 xx)`, **NO embedded describe**.
  This reproduces the Story 9.4 capture exactly. With the production decoder
  (which always reads an inline describe) the 21c FETCH shears
  (`Integer too large: size=7`) and poisons the connection.

### THE EXPERIMENT — bare nested cursorId on a LIVE 21c session

To run the experiment without the shear killing the session, the spike
temporarily switched the cursor-value decoder to the id-only shape so the 21c
FETCH completed and the nested cursors (ids 4/5/6) stayed open. Then, on the
SAME live session, two RPCs were driven against the bare nested cursorId 4
(parent 1, whose children are 10/20/30):

- **Probe A — fresh full EXECUTE (OAL8), `isQuery=true`, `cursorId=4`, empty SQL
  (the `requiresFullExecute`/re-execute-open-cursor shape).** Result on 21c:
  **the server returned NOTHING — the call timed out (0 bytes received).** No
  DESCRIBE_INFO, no rows, no error. (Same on 23ai.)
- **Probe B/C — OFETCH (OFETCH RPC) against the bare nested cursorId 4.**
  Result on 21c: the call returns `isSuccess=true` but the response is
  `ROW_HEADER` + three **empty** `ROW_DATA` markers (`06 …  07 07 07  04 …`)
  ending in ORA-01403 — i.e. **NO DESCRIBE_INFO and ZERO column bytes**. The
  nested cursor's actual data was NOT delivered. Decisive contrast: the
  byte-identical OFETCH on **23ai** returned the real values
  (`07 02 c1 0b`=10, `07 02 c1 15`=20, `07 02 c1 1f`=30) — but still NO
  DESCRIBE_INFO. So even on 23ai the describe only ever exists inline; on 21c
  neither the describe NOR the row data is retrievable for a cursor the client
  never received a describe for.

**Answers to the open empirical questions:**

1. *Does an EXECUTE/OFETCH with the existing nested cursorId return a
   DESCRIBE_INFO + rows on 21c?* **NO.** A full EXECUTE returns nothing (timeout);
   an OFETCH returns empty rows and never a DESCRIBE_INFO. The missing nested
   describe cannot be obtained out-of-band on 21c.
2. *Is the nested cursor still open/valid at outer-drain time?* The cursor id is
   accepted by the OFETCH RPC (no "invalid cursor" error), so it is live — but it
   is useless: the server will not describe it nor return its rows to this client.
3. *Interaction with the close-cursor piggyback and the single-in-flight guard?*
   The production FETCH of the id-only stream **shears and poisons the
   connection** before any follow-up RPC is even possible; a poisoned transport
   refuses all further RPCs. A server cursor id is session-scoped, so the id
   cannot be retried on another session. Any "extra round trip mid-drain" design
   (R2/R3) is therefore moot on 21c — there is nothing usable to round-trip for.

### Secondary 23ai sanity check

Confirmed (via the inline-describe shape above) that the 23ai per-row value
carries a full embedded describe that the existing
`_readEmbeddedCursorDescribe` machinery already decodes — so lifting the
`_isSupportedRefCursorColumn` guard would make the 23ai half work with a small
change, exactly as the spec claims (S1). This was NOT shipped; the guard remains
intact. It is irrelevant to deliverability because the dual-env rule forbids a
23ai-only enablement.

## Decision record

Evaluated 2026-06-21 against baseline `d60e190`. Outcome: **NO-GO for immediate
implementation.** Two independent grounds: (1) the GO completion bar requires
dual-env integration validation green on BOTH 23ai and 21c before commit, which
could not be performed in the evaluating session; and (2) substantively, the
21c path is an unproven NEW protocol capability with no reference precedent (R1),
so a single autonomous cycle cannot responsibly deliver and validate it. Current
fail-loud + reaping behaviour left exactly as-is. This plan should drive a
dedicated epic starting with the S0 feasibility gate.

**S0 outcome (2026-06-22): NO-GO — PERMANENT, EVIDENCE-BACKED DEFERRAL.** The S0
spike (findings above) settled R1 empirically: on a live 21c server the per-row
nested-cursor value is id-only (no inline describe), and the missing describe
**cannot** be obtained out-of-band — a fresh full EXECUTE on the bare nested
cursorId returns nothing (timeout) and an OFETCH returns empty rows with no
DESCRIBE_INFO and no data. node-oracledb has no such fetch path either
(`withData.js processColumnData` always assumes the inline describe). Because
the absolute dual-env rule forbids shipping a 23ai-only path, and 21c cannot
materialize this combination at all, **the feature as specified (dual-env) is
undeliverable.** The epic ends at S0. The driver's current behaviour — fail-loud
(`oraUnsupportedType`, "column type 102") with B1/B2 cursor-id reaping intact, on
both versions — is correct and is left exactly as-is. This is a settled
(not "resolved-by-implementation") deferral: revisit only if a future pre-23
server build is shown to transmit the nested describe, or the project's
dual-env support floor moves to 23ai+.
