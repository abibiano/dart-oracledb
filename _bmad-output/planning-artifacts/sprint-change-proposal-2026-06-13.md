# Sprint Change Proposal — Post-1.0 Feature Expansion

**Date:** 2026-06-13
**Author:** Correct Course workflow (with Alex)
**Project:** dart-oracledb
**Status:** Proposed — awaiting approval
**Source of candidates:** `_bmad-output/planning-artifacts/post-1-0-future-enhancements.md`

---

## Section 1 — Issue Summary

dart-oracledb shipped **1.0.0** on 2026-06-12. Epics 1–7 are `done`, all
retrospectives complete, and `deferred-work.md` has **zero open items**. The
project is at a clean release boundary with no in-flight sprint work.

This is **not a defect or course reversal**. It is a planned **scope
expansion**: the post-1.0 enhancement candidates captured in
`post-1-0-future-enhancements.md` (2026-06-11) need to be promoted from a
planning note into committed, schedulable epics so they can enter the normal
implementation cycle.

**Decision taken during this workflow:** include **high + medium value**
candidates as committed epics; exclude AQ/TxEventQ (deferred) and the
thick-mode defer list (SODA, CQN, Kerberos/native encryption — architecturally
incompatible with the pure-Dart thin direction).

---

## Section 2 — Impact Analysis

### Epic Impact

- **Purely additive.** No existing epic (1–7) is modified, rolled back, or
  resequenced.
- **Numbering correction:** the source note labels its candidates "Epic 6/7",
  but those numbers are already used (Epic 6 = Test Architecture, Epic 7 =
  Deferred Work). New epics are numbered **8–15**.

### Story Impact

- No existing stories change. ~38 new stories are introduced across 8 new epics
  (detailed Given/When/Then ACs to be authored at `create-story` time).

### Artifact Conflicts

| Artifact | Impact |
|----------|--------|
| `epics.md` | Append Epic List entries + Epic 8–15 definitions. |
| `prd.md` | Add a "Post-1.0 Roadmap (v1.1+)" section; these exceed the original 1.0 MVP. |
| `architecture.md` | Updates needed for **Epic 8** (cursor/ResultSet result model + one-in-flight-operation-per-connection invariant) and **Epic 10** (wire-level charset negotiation; revisits the `lib/src/protocol/buffer.dart` UTF-8 assumption and fast-auth charset id). Other epics fit existing patterns. |
| `sprint-status.yaml` | Add `epic-8`…`epic-15` and their stories as `backlog`. |
| README | Charset support matrix (Epic 10), streaming docs (Epic 8), and per-type docs updated as each epic lands. |
| CI | Epic 10 needs a non-AL32UTF8 database fixture/image if it can be made reliable. |

### Technical Impact

- **Epic 8 (streaming)** and **Epic 10 (charset)** touch core result and
  wire-encoding behavior — they were intentionally kept out of Epics 4/5 for
  this reason. They warrant architecture review before story execution.
- All other epics build on established patterns (data-type codecs, bind
  handling, LOB value support, statement cache).

---

## Section 3 — Recommended Approach

**Option 1 — Direct Adjustment (additive new epics).** Selected.

- **Option 2 (Rollback):** Not viable — nothing to roll back; 1.0 is stable.
- **Option 3 (MVP Review):** Not applicable — 1.0 MVP shipped and is unchanged;
  this is post-MVP roadmap.

**Effort:** High (8 epics, ~38 stories). **Risk:** Medium — concentrated in
Epics 8 and 10 (core behavior changes); the rest is incremental.

**Rationale:** The candidates are reference-grounded (node-oracledb thin parity),
already triaged by value in the source note, and additive. Sequencing respects
the one hard dependency (Epic 9 builds on Epic 8's `OracleResultSet`).

---

## Section 4 — Detailed Change Proposals (Epics 8–15)

Dependency-ordered. Every epic inherits the project **Definition of Done**:
`dart analyze` clean; integration tests pass on **both Oracle 23ai (FAST_AUTH)
and Oracle 21c (classical AUTH)**; new tests written with `test_helper.dart`
(no hardcoded connection params).

### Epic 8 — Streaming & Incremental Result Consumption
**Goal:** Process large query outputs without materializing all rows and without
relying on the single-`execute()` fetch cap.
**Depends on:** none. **Architecture review required.**
- 8.1 `OracleResultSet` — closeable, cursor-backed result object (getRow/getRows/close).
- 8.2 `connection.queryStream()` / `executeStream()` → `Stream<OracleRow>` with `fetchSize`.
- 8.3 `execute(..., OracleExecuteOptions(resultSet: true))` integration (if it fits API style).
- 8.4 Early cancellation closes the server cursor; connection remains reusable; preserve one-in-flight-operation-per-connection invariant.
- 8.5 Statement-cache safety with open streamed cursors; dual-env integration tests.

### Epic 9 — REF CURSOR & Implicit Results
**Goal:** Support REF CURSOR OUT binds, nested cursors, and implicit result sets.
**Depends on:** Epic 8 (`OracleResultSet`).
- 9.1 REF CURSOR OUT bind decoded into `OracleResultSet`.
- 9.2 Nested cursors within result columns.
- 9.3 Implicit result sets (`DBMS_SQL.RETURN_RESULT`).
- 9.4 Dual-env integration tests.

### Epic 10 — Non-AL32UTF8 Database Character Set Compatibility
**Goal:** Support databases whose DB charset is not AL32UTF8, keeping Dart strings
Unicode and client wire encoding aligned with thin reference behavior.
**Depends on:** none. **Architecture review required.**
- 10.1 Startup capability detection for server charset and national charset.
- 10.2 Validate/implement the node-oracledb thin model: negotiate UTF-8 client char data, rely on server-side conversion.
- 10.3 VARCHAR2/CHAR/CLOB round-trip against ≥1 non-AL32UTF8 DB charset.
- 10.4 NCHAR/NVARCHAR2/NCLOB on AL16UTF16 national charset; fail-loud `OracleException` on unsupported configs (no silent mojibake).
- 10.5 README support matrix + CI non-AL32UTF8 fixture; dual-env tests.

### Epic 11 — Bulk DML (`executeMany`)
**Goal:** Array DML binding for high-volume insert/update/delete and PL/SQL.
**Depends on:** none.
- 11.1 `executeMany()` array DML binding API.
- 11.2 Bulk PL/SQL array binds.
- 11.3 Row-level batch error handling (`batchErrors`).
- 11.4 DML RETURNING with `executeMany`.
- 11.5 Dual-env integration tests.

### Epic 12 — LOB Streaming & Temporary LOBs
**Goal:** Public streaming LOB object and temporary LOB lifecycle, building on
Epic 4 basic CLOB/BLOB value support.
**Depends on:** none (extends Epic 4).
- 12.1 Public LOB object with read/write streaming (CLOB/BLOB).
- 12.2 Temporary LOB creation & lifecycle/cleanup.
- 12.3 Chunked streaming transfer for large payloads.
- 12.4 Dual-env integration tests.

### Epic 13 — JSON / OSON Parity
**Goal:** Full JSON support across Oracle versions (21c native JSON type; 12c
JSON-as-BLOB).
**Depends on:** none.
- 13.1 Oracle 21c native JSON type encode/decode (OSON).
- 13.2 Oracle 12c JSON-as-BLOB compatibility path.
- 13.3 Bind & fetch JSON; Dart map/list mapping.
- 13.4 Dual-env integration tests.

### Epic 14 — Temporal Compatibility & Fetch Type Handlers
**Goal:** Close remaining temporal gaps and add custom fetch representations.
**Depends on:** none (extends Epic 4 / Story 7.9 TSTZ work).
- 14.1 TSTZ region-name (region-id) decode to correct UTC instant.
- 14.2 Optional region-name preservation / clearly documented limits.
- 14.3 Fetch-as-string for dates/timestamps.
- 14.4 Fetch type-handler hooks (custom per-column conversion).
- 14.5 Dual-env integration tests.

### Epic 15 — Extended Data Type Completeness
**Goal:** Medium-value type coverage for schema completeness.
**Depends on:** none.
- 15.1 INTERVAL DAY TO SECOND.
- 15.2 INTERVAL YEAR TO MONTH.
- 15.3 ROWID / UROWID.
- 15.4 VECTOR (Oracle 23ai).
- 15.5 Dual-env integration tests.

### Explicitly excluded
- **AQ / TxEventQ** — deferred; large surface area, revisit only on concrete user need.
- **SODA** — thick-mode only in the reference; out of scope for pure thin driver.
- **CQN / subscriptions** — thin support limited/absent; long-lived notification transport concerns.
- **External/Kerberos auth & native network encryption** — thick-mode; conflicts with pure-Dart/no-Oracle-Client direction.

---

## Section 5 — Implementation Handoff

**Scope classification: Major** (new epics + PRD + architecture changes).

1. **Architect** — update `architecture.md` for Epic 8 (cursor/ResultSet model,
   one-in-flight invariant) and Epic 10 (wire charset negotiation) before those
   epics are scheduled.
2. **PM/SM** — re-run `sprint-planning` to regenerate `sprint-status.yaml` with
   Epics 8–15.
3. **SM/Dev** — per-story cycle: `create-story` → `dev-story` → `code-review`,
   one epic at a time, respecting the Epic 8 → Epic 9 dependency.

**Success criteria:** Each story passes integration tests on **both 23ai and
21c**; `dart analyze` clean; node-oracledb thin parity preserved where the
candidate cites reference behavior.

**Suggested execution order:** 8 → 9 → 10 → 11 → 12 → 13 → 14 → 15
(only 8→9 is a hard dependency; the rest may be reprioritized by user value).
