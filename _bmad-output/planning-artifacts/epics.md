---
stepsCompleted: ['step-01-validate-prerequisites', 'step-02-design-epics-deferred-work']
inputDocuments:
  - '_bmad-output/planning-artifacts/prd.md'
  - '_bmad-output/planning-artifacts/architecture.md'
  - '_bmad-output/planning-artifacts/test-architecture-dart-oracledb.md'
  - '_bmad-output/implementation-artifacts/deferred-work.md'
lastUpdated: '2026-05-22'
deferredWorkEpic: 'Epic 7'
deferredWorkStoryCount: 9
---

# dart-oracledb - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for dart-oracledb, decomposing the requirements from the PRD, UX Design if it exists, and Architecture requirements into implementable stories.

## Requirements Inventory

### Functional Requirements

FR1: Developer can establish a connection to Oracle database using an EZ Connect string (host:port/service)
FR2: Developer can authenticate using username and password with SHA512/PBKDF2 verifiers
FR3: Developer can establish a TLS/SSL encrypted connection
FR4: Developer can specify connection timeout duration
FR5: Developer can close a connection and release associated resources
FR6: Developer can check if a connection is still valid/alive
FR7: Developer can create a connection pool with configurable minimum and maximum size
FR8: Developer can acquire a connection from the pool
FR9: Developer can release a connection back to the pool
FR10: Developer can configure pool timeout settings
FR11: Developer can close a pool and release all connections
FR12: Developer can set session tags on pooled connections
FR13: Developer can execute a SELECT query and retrieve results
FR14: Developer can execute an INSERT statement
FR15: Developer can execute an UPDATE statement
FR16: Developer can execute a DELETE statement
FR17: Developer can use named bind parameters in queries (e.g., :param_name)
FR18: Developer can use positional bind parameters in queries
FR19: Developer can iterate over query result rows
FR20: Developer can access column values by column name
FR21: Developer can access column values by column index
FR22: Developer can commit a transaction
FR23: Developer can rollback a transaction
FR24: Developer can execute multiple statements within a single transaction
FR25: Developer can call a stored procedure
FR26: Developer can call a function and retrieve the return value
FR27: Developer can pass IN parameters to procedures/functions
FR28: Developer can retrieve OUT parameter values from procedures/functions
FR29: Developer can use IN OUT parameters with procedures/functions
FR30: System can map Oracle VARCHAR2/VARCHAR/CHAR to Dart String
FR31: System can map Oracle NUMBER to Dart int or double
FR32: System can map Oracle DATE to Dart DateTime
FR33: System can map Oracle TIMESTAMP to Dart DateTime with precision
FR34: System can read CLOB data as Dart String
FR35: System can write Dart String to CLOB
FR36: System can read BLOB data as Dart Uint8List
FR37: System can write Dart Uint8List to BLOB
FR38: System can map Oracle RAW to Dart Uint8List
FR39: System can map Oracle JSON to Dart Map/List
FR40: System surfaces Oracle error codes (ORA-xxxxx) in exceptions
FR41: System provides clear error messages for connection failures
FR42: System provides clear error messages for query execution failures
FR43: Developer can catch and handle OracleException types
FR44: System caches prepared statements for performance
FR45: Developer can configure statement cache size

### NonFunctional Requirements

NFR1: Query execution overhead from the driver should be minimal compared to network round-trip time
NFR2: Statement caching should reduce repeated query parsing overhead
NFR3: Connection pooling should eliminate per-request connection establishment cost
NFR4: Crypto/authentication latency is acceptable during initial connection (mitigated by pooling)
NFR5: Database credentials must never be logged or exposed in error messages
NFR6: TLS/SSL encryption must be supported for production connections
NFR7: Authentication must use Oracle's secure verifier protocols (SHA512/PBKDF2)
NFR8: System should detect broken connections and surface clear errors
NFR9: Connection pool should handle connection failures gracefully (remove dead connections, create new ones)
NFR10: System should properly release resources on connection close (no resource leaks)
NFR11: Package must support Dart SDK 3.0+
NFR12: Package must work on macOS (Apple Silicon and Intel), Windows, and Linux
NFR13: Package must support Oracle 23ai with modern authentication
NFR14: Package must compile and run in both JIT (development) and AOT (production) modes
NFR15: Test suite must comprehensively validate Oracle 23ai protocol-specific behaviors including FAST_AUTH protocol, hex-encoded cryptographic values, and edge cases (wrong password handling, connection failures). Integration tests must run against Oracle 23ai to catch protocol deviations.

### Additional Requirements

- Initialize the package with the standard Dart package template, then keep the custom node-oracledb-inspired structure under `lib/src/`.
- Preserve the three-layer architecture: public/application API, TTC protocol layer, and TNS transport layer, with crypto used by authentication.
- Keep `lib/dart_oracledb.dart` as the single public export file and keep implementation code private under `lib/src/`.
- Organize protocol constants in a shared constants module and mirror node-oracledb structure where doing so improves porting and upstream comparison.
- Implement explicit big-endian and little-endian buffer accessors; avoid ambiguous integer read/write APIs.
- Use a single `OracleException` model with queryable Oracle error codes and preserve wrapped causes for debugging.
- Provide explicit resource cleanup (`close()`) and safe wrapper APIs where applicable, including `withConnection()` and transaction helpers.
- Use `package:logging` for diagnostic output and ensure credential material never appears in logs or exceptions.
- Run `dart analyze` with zero warnings before completing implementation stories.
- Maintain tests that mirror `lib/src/` structure and use `_test.dart` suffixes for unit tests.
- Require integration-first validation for protocol-level work against Oracle 23ai, plus pre-23 classical authentication coverage where the behavior differs.
- Select FAST_AUTH vs classical AUTH based on `transport.supportsFastAuth` / `TNS_ACCEPT_FLAG_FAST_AUTH`, never by parsing version strings.
- Validate FAST_AUTH as a combined Protocol + DataTypes + AUTH_PHASE_ONE envelope for Oracle 23ai.
- Encode Oracle authentication crypto values as uppercase hex strings where required by the 12c verifier path.
- Account for wrong-password behavior where Oracle may close silently; expose timely ORA-01017-style failures without credential leakage.
- Handle MARKER packets and TTC sequence progression explicitly during authentication.
- Register and use Dart test tags for `integration`, `security`, `slow`, `performance`, and `protocol`.
- Normalize integration-test gating to `RUN_INTEGRATION_TESTS == 'true'`.
- Maintain test coverage targets: overall at least 85%, protocol/transport/crypto at least 90%, connection/pool/data types at least 85%.
- Keep CI coverage for unit tests, integration tests with Oracle, cross-platform validation, and coverage reporting.
- Strengthen deferred PL/SQL bind validation by checking `OracleBind.inOut` value/type compatibility at construction.
- Add a connection-state probe or equivalent guard after server errors if PL/SQL error behavior ever makes sessions unusable.
- Decide and document semantics for repeated bind names in SQL when an IN OUT placeholder appears more than once.
- Add decode consistency checks, or deliberately remove dead metadata, for client-declared bind direction vs server IO_VECTOR direction.
- Replace OUT-bind decode guards based on `outBindValues.isEmpty` with an explicit decoded-state flag.
- Restrict IO_VECTOR output handling to known OUT and IN OUT direction bytes to avoid stream corruption on malformed or future protocol values.
- Investigate and fix TIMESTAMP OUT-bind decode buffer underrun for PL/SQL function returns on both Oracle 23ai and 21c.
- Unify the parallel public/protocol bind direction enums or document the mapping boundary clearly.
- Add guards or documentation for unrealistic bind-count overflow in IO_VECTOR parsing.
- Replace `allowMalformed: true` string decoding with a broader charset-handling design.
- Revisit `OracleOutBinds.operator[]` behavior for unsupported key types and consider surfacing argument errors.
- Fix or constrain query error-code formatting for pathological negative or six-digit internal codes.
- Harden integration test setup/teardown so failed connection setup does not mask the root error.
- Make SQL truncation Unicode-safe if supplementary-plane SQL text becomes supported.
- Add a defensive length check and targeted reproducer for the intermittent auth hash-length flake.
- Refactor pre-23 multi-packet TTC receive behavior toward lazy packet consumption when long-fetch overhead matters.
- Document or serialize concurrent `execute()` calls on the same connection.
- Investigate statement-cache keys that include bind signature, stale column metadata after DDL, cursor close chunking, `SELECT FOR UPDATE`, and cache size upper bounds.
- Strengthen statement-cache integration evidence with cursor reuse or parse-bit verification.
- Add length-aware NUMBER decode safeguards and expand NUMBER tests for NaN/infinity errors, floating-point artifacts, zero scale, boundaries, pure fractions, and 38-digit precision loss.
- Add broader temporal tests, including Dart-bound DATE/TIMESTAMP round trips, nanosecond truncation, pre-epoch/year-boundary cases, and TIMESTAMP WITH TIME ZONE / LOCAL TIME ZONE.
- Expand character and binary type coverage for CHAR padding, multi-byte text, empty-string/null behavior, VARCHAR2 boundaries, RAW, CLOB, BLOB, NCHAR/NVARCHAR2, LONG, BINARY_FLOAT, and BINARY_DOUBLE.
- Improve integration test isolation by avoiding fixed shared table names, fixed primary keys, and cleanup that masks original failures.
- Add deterministic timeout tests and mark transport state broken after timed-out RPCs to avoid stale-response desynchronization.
- Make `_ensureOpen()` detect silently dropped sockets using transport/socket state where available.
- Add a timeout around classical `sendAuthPhaseOne` if a real pre-23 hang is observed.
- Avoid test imports that depend on unstable `src/` layout, or expose a deliberate internal test API.
- Fix `AuthPhaseOneResponse.decode` so TTC ERROR messages surface as immediate Oracle exceptions.
- Gate AUTH_PHASE_TWO 23ai token-number behavior more robustly if short pre-23 protocol responses are observed.
- Improve CI diagnostics and reliability for Oracle startup, integration job timeout, coverage threshold enforcement, and platform matrix naming.
- Address Epic 6 residual coverage gaps: verifier.dart below target, sequence counter wrap-around, `shouldWriteTokenNumber` boundaries, verifier parameter AES-block lengths, 0xB92 speedy-key behavior, and SHA512 verifier path testing.
- Re-validate Stories 2.5 and 2.6 after protocol rebuild and restore unit coverage for execute response edge cases removed during rewrites.
- Remove, relocate, or sanitize committed one-off probe tools and replace hardcoded local credentials with environment variables.
- Correct the `_ub8` test helper so it does not alias `_ub4`.
- Version-gate protocol decode fields that are currently assumed to be Oracle 23.4/12.2 shaped.
- Add PL/SQL cache exclusion integration evidence, duplicate-bind-name tests, and CTE-with-DML SQL classification fixes.
- Review release tooling so `scripts/bump_version.sh` fails visibly when its version helper command fails.

### UX Design Requirements

No UX Design document was found. No UX design requirements were extracted.

### FR Coverage Map

{{requirements_coverage_map}}

## Epic List

- Epic 1–6: see existing PRD/architecture decomposition (features, auth, query, transactions, data types, PL/SQL, test infrastructure)
- **Epic 7: Deferred Work Backlog — Technical Debt and Follow-ups** _(this document, appended below)_
- **Epic 8: Streaming & Incremental Result Consumption** _(post-1.0, appended below)_
- **Epic 9: REF CURSOR & Implicit Results** _(post-1.0, depends on Epic 8)_
- **Epic 10: Non-AL32UTF8 Database Character Set Compatibility** _(post-1.0)_
- **Epic 11: Bulk DML (`executeMany`)** _(post-1.0)_
- **Epic 12: LOB Streaming & Temporary LOBs** _(post-1.0)_
- **Epic 13: JSON / OSON Parity** _(post-1.0)_
- **Epic 14: Temporal Compatibility & Fetch Type Handlers** _(post-1.0)_
- **Epic 15: Extended Data Type Completeness** _(post-1.0)_

> **Post-1.0 epics (8–15)** were added 2026-06-13 via the Correct Course workflow.
> See `sprint-change-proposal-2026-06-13.md` for the impact analysis and rationale.
> Source candidates: `post-1-0-future-enhancements.md`. Excluded by decision:
> AQ/TxEventQ (deferred), and SODA / CQN / Kerberos & native encryption
> (thick-mode, out of scope for the pure-Dart thin driver).

## Epic 7: Deferred Work Backlog — Technical Debt and Follow-ups

**Goal:** Address the ~95 follow-up items captured in `_bmad-output/implementation-artifacts/deferred-work.md` during code reviews of Epics 1–3 and 6. Items are grouped by technical area into nine sub-area stories so each can be scheduled independently without blocking ongoing feature work.

**Scope:** Pure technical-debt epic. No new user-visible features. Every story must preserve existing passing tests on **both** Oracle 23ai (FAST_AUTH) and Oracle 21c (classical AUTH) — see [project-context.md](/Users/abibiano/Projects/Flutter/dart-oracledb/_bmad-output/project-context.md) §Testing Rules.

**Definition of Done (applies to every story below):**

- All deferred items listed in the story's AC are resolved or explicitly re-deferred with documented reason in `deferred-work.md`.
- `dart analyze` passes with zero warnings.
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color` passes against Oracle 23ai.
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color` passes against Oracle 21c.
- New tests added for each resolved item that previously lacked coverage; existing tests untouched unless directly affected.
- `deferred-work.md` updated to strike resolved items and capture any newly surfaced gaps.

### Story 7.1: Data-Type Codec Hardening

As a driver maintainer,
I want NUMBER, DATE, and TIMESTAMP codecs to handle Oracle edge cases without silent corruption,
So that production users do not encounter buffer desync, lost precision, or wrong values for legal Oracle data.

**Acceptance Criteria:**

**Given** a `TIMESTAMP WITH TIME ZONE` or `TIMESTAMP WITH LOCAL TIME ZONE` column at [lib/src/protocol/data_types.dart](lib/src/protocol/data_types.dart)
**When** the column is decoded via `decodeTimestamp`
**Then** the returned `DateTime` reflects the Oracle TZ offset (hour = `byte11 - 20`, minute = `byte12 - 60`, or region-id when high bit set)
**And** TZ-bearing payload lengths (13 bytes typical) are accepted alongside the existing 7/11-byte shapes.

**Given** a `decodeNumber` call where Oracle omits the `0x66` terminator for a negative NUMBER
**When** the decoder runs to the end of the field
**Then** decoding stops at the declared `length` parameter instead of consuming the rest of the packet buffer
**And** `decodeNumber` signature accepts an explicit `length` (matching `decodeValue` callers).

**Given** Dart `double.infinity`, `double.nan`, or `double.negativeInfinity` passed to `encodeNumber`
**When** encoding is attempted
**Then** an `OracleException` (not an untyped `FormatException`) is thrown with a descriptive message.

**Given** a Dart double with floating-point representation artifacts (e.g. `678.90` → `"678.9000000000000...9"`)
**When** `encodeNumber` runs `toStringAsFixed(20)` and extracts digits
**Then** the wire-encoded mantissa matches Oracle's expected base-100 form (either via decimal rounding or a string-based representation that avoids artifact digits).

**Given** the integration test suite for NUMBER round-trips
**When** the suite runs against Oracle 23ai and 21c
**Then** the following cases are exercised end-to-end: int-vs-double boundary at ±2^53, 38-digit precision-loss behavior, bare `NUMBER` (no precision/scale), pure-fraction values (`0.0001`, `0.000001`), `NUMBER(10,2)` zero (asserts `double` not `int`), negative NUMBER containing a base-100 digit pair of 0 (e.g. `-100`, `-10001`).

**Given** a `TIMESTAMP` value with sub-microsecond fractional seconds (`.123456789`)
**When** the value is decoded
**Then** truncation to microseconds is asserted explicitly (the rounding-vs-floor contract is captured in a documented test).

**Given** a DATE or TIMESTAMP value with a BCE year (`century = 100 - abs(century)` per Oracle encoding)
**When** the value flows through `decodeDate` / `decodeTimestamp`
**Then** either the BCE branch is implemented correctly **or** an explicit `OracleException` is raised, with the behavior documented in code.

**Given** a CHAR(N) column with content shorter than N
**When** the column is decoded
**Then** the test suite asserts the driver's documented padding/trim contract.

**Given** VARCHAR2 columns and bind values containing multi-byte UTF-8 (emoji, CJK, accents) and the empty string
**When** the value is round-tripped
**Then** integration tests cover: non-ASCII content, VARCHAR2(100) length boundary, over-length triggering ORA-12899, and the documented `''` vs `NULL` semantics for VARCHAR2.

### Story 7.2: PL/SQL Bind & IO_VECTOR Decode Robustness

As a driver maintainer,
I want OUT and IN OUT bind decoding to be driven by validated server directions and consistent with the declared `OracleBind` contract,
So that PL/SQL callers cannot trigger stream corruption, silent value loss, or surprising case-sensitivity behavior.

**Acceptance Criteria:**

**Given** `_processIoVector` at [lib/src/protocol/messages/execute_message.dart](lib/src/protocol/messages/execute_message.dart)
**When** an unexpected direction byte arrives from the server
**Then** only `tnsBindDirOutput` (16) and `tnsBindDirInputOutput` (48) are treated as output slots
**And** an `OracleException` is raised for any other non-input direction value.

**Given** an IN OUT bind (server reports direction 48) for which the client declared OUT (16) — or vice versa
**When** the response is decoded
**Then** an explicit consistency check is performed between `BindMetadata.dir` and the server IO_VECTOR direction
**And** a mismatch raises a diagnostic `OracleException` instead of silently following the server direction.

**Given** the first `ROW_DATA` packet for a PL/SQL execution returns all-null OUT values (empty decoded list)
**When** a subsequent `ROW_DATA` packet arrives
**Then** the double-decode guard uses a dedicated `bool _outBindsDecoded` flag (not `outBindValues.isEmpty`) and the second packet is correctly skipped.

**Given** `BindMetadata.dir` is currently populated but never read during decode
**When** this story is complete
**Then** either `BindMetadata.dir` is used in the IO_VECTOR consistency check above **or** it is removed from the type and its construction sites, with no dead field left in the API surface.

**Given** the two parallel direction enums `BindDirection` (public) and `BindDir` (protocol)
**When** Story 7.2 ships
**Then** the enums are unified into a single shared type **or** the mapping boundary in `connection.dart` is documented with a comment explaining why two enums exist.

**Given** `OracleBind.inOut(value: DateTime.now(), type: OracleDbType.number)` or any other value-type/declared-type mismatch
**When** the bind passes through `_validate()`
**Then** an `ArgumentError` is raised at construction time, not at wire-encoding time.

**Given** `OracleOutBinds.operator[]` called with an unsupported key type (not `int`, not `String`)
**When** the lookup runs
**Then** an `ArgumentError` is thrown instead of returning silent `null`.

**Given** the same bind name appears twice in SQL with an IN OUT placeholder
**When** the result is read back via `OracleOutBinds[name]`
**Then** the documented contract (first-occurrence semantics) is captured in a test fixture and surfaced in the API doc-comment.

**Given** a bind-count value exceeding 65535 in `_processIoVector` (`numBinds = temp16 | (temp32 << 16)`)
**When** this branch executes
**Then** either an explicit bounds check raises an `OracleException` **or** a code comment documents that the overflow is unreachable with real Oracle bind counts.

**Given** an SQL statement with `:RET` and a bind map keyed `'ret'` (case-mismatched)
**When** validation runs
**Then** the mismatch is reported at bind-validation time with the missing-bind name, not at result-access time.

### Story 7.3: SQL Classification & PL/SQL Caching Evidence

As a driver maintainer,
I want SQL classification to correctly identify CTE-with-DML, paren-prefixed statements, and CR-terminated comments, and PL/SQL exclusion from the statement cache to have explicit integration evidence,
So that classification bugs cannot silently change `rowsAffected` semantics or accidentally cache PL/SQL.

**Acceptance Criteria:**

**Given** `WITH cte AS (...) INSERT/UPDATE/DELETE/MERGE ...` at [lib/src/sql_classifier.dart](lib/src/sql_classifier.dart)
**When** `isQuerySql` runs
**Then** the terminal verb is detected
**And** the statement is classified as DML
**And** `rowsAffected` is populated from `rowCount` for the execution.

> **Implementation note (code review 2026-05-22):** Current Oracle grammar rejects
> `WITH cte AS (...) INSERT INTO t ...` with ORA-00928, so this AC cannot be
> verified end-to-end against a live Oracle session. The classifier implements this
> shape *defensively* — `_findCteTerminalVerb` correctly identifies the terminal DML
> verb for future Oracle grammar extensions. Integration-level coverage exists for
> the supported Oracle forms: `INSERT INTO t ... WITH src AS (SELECT ...)` and
> `MERGE INTO`. Unit tests in `test/src/sql_classifier_test.dart` cover the full
> `WITH cte AS (...) INSERT/UPDATE/DELETE/MERGE` classification path.

**Given** SQL with a stray leading `(` (e.g. `(BEGIN ... END;)`, `(DELETE FROM t)`)
**When** `skipSqlPrefixes` runs
**Then** the input is rejected as malformed **or** the prefix-stripping no longer reclassifies the inner verb (documented decision).

**Given** SQL terminated with classic Mac line endings (`\r` only) inside a line comment
**When** the comment scanner runs
**Then** the scanner stops at `\r` as well as `\n`.

**Given** the integration test suite at [test/integration/plsql_integration_test.dart](test/integration/plsql_integration_test.dart)
**When** PL/SQL blocks are executed repeatedly with statement caching enabled
**Then** an integration assertion confirms the PL/SQL statement is **not** retained in the cache (e.g. via `v$open_cursor` inspection or instrumented cache hooks).

**Given** a PL/SQL block declaring the same formal parameter twice
**When** unit tests run for SQL classification and bind validation
**Then** the `uniqueNames.toSet()` duplicate-name guard is exercised explicitly for PL/SQL inputs (not only plain SQL).

### Review Findings — Story 7.3 (code review 2026-05-22)

- [x] [Review][Patch] `debugCacheSize` doc comment was factually wrong ("not exported" — getter IS accessible via barrel) + missing `@visibleForTesting` [`lib/src/connection.dart`] — **applied**: corrected doc comment, added `@visibleForTesting`, added `meta: ^1.12.0` dependency
- [x] [Review][Patch] Double-quoted `""` escape unhandled in `_findCteTerminalVerb` — early identifier exit on `"col""name"` could leak content as bare SQL at current paren depth [`lib/src/sql_classifier.dart`] — **applied**: mirrored `''`-escape pattern in the `0x22` branch
- [x] [Review][Decision] AC1 end-to-end gap — Oracle rejects `WITH cte AS (...) INSERT INTO t` (ORA-00928); `_findCteTerminalVerb` is exercised only in unit tests, not against live Oracle — **resolved**: implementation is defensive for future grammar extensions; caveat added to AC1 above
- [x] [Review][Defer] `isCacheEligibleSql` no longer delegates to `isQuerySql` — two independent `_findCteTerminalVerb` calls; if one is updated the other could silently diverge [`lib/src/sql_classifier.dart`] — deferred, maintainability risk only; no current divergence confirmed
- [x] [Review][Defer] `\r` after line-comment break in `_findCteTerminalVerb` handled only by fallthrough `pos++`; no explicit whitespace branch [`lib/src/sql_classifier.dart`] — deferred, functionally correct; fragility concern only
- [x] [Review][Defer] Oracle `q'...'` alternative-quote literals with embedded `'` cause premature string-exit in `_findCteTerminalVerb` [`lib/src/sql_classifier.dart`] — deferred, requires unusual Oracle q-quote in CTE headers; complex to fix with minimal practical impact
- [x] [Review][Defer] Paren-skipping removal — no migration note for JDBC-shim callers that previously relied on `(SELECT ...)` wrapping [`lib/src/sql_classifier.dart`] — deferred, intentional Story 7.3 contract; library doc covers it

### Story 7.4: Transport & Connection Lifecycle Hardening

As a driver maintainer,
I want commit, rollback, and authentication RPCs to be timeout-bounded, and the transport to fail loud after timeouts or dropped sockets,
So that hung Oracle responses cannot leak orphaned packets into the next RPC or silently stall the application.

**Acceptance Criteria:**

**Given** `sendCommit()` and `sendRollback()` at [lib/src/transport/transport.dart](lib/src/transport/transport.dart)
**When** the server fails to respond within the configured RPC timeout
**Then** each call raises an `OracleException` with the elapsed wait and the call name.

**Given** any RPC that times out via `_receiveDataWithTimeout`
**When** the timeout fires
**Then** the transport is marked corrupted (or force-disconnected)
**And** subsequent RPCs fail fast through `_ensureOpen` instead of reading the orphaned response from the previous call.

**Given** a TCP RST or idle-firewall-kill on an established connection
**When** the next RPC is attempted via `_ensureOpen()`
**Then** the check uses `_transport.isConnected` (or socket-level equivalent) and surfaces the dead-connection state immediately, not after a 30-second RPC timeout.

**Given** `AuthFlow.authenticate` on the classical (pre-23) path
**When** `sendAuthPhaseOne` is called against a server that silently closes
**Then** the call is wrapped in a timeout matching the existing `authTimeout` used in phase two.

**Given** the `_receiveAllTtcData` 0x1D heuristic on pre-23ai servers
**When** column data ends with byte `0x1D`
**Then** the receive loop has a follow-up guard so the heuristic cannot prematurely terminate a multi-packet response, OR the heuristic is replaced with TTC stream-level framing.

**Given** the `_receiveAllTtcData` probe-decode runs per inbound packet on pre-23.4 servers
**When** long fetches accumulate
**Then** a lazy-fetch refactor (or an O(1) packet-boundary indicator) eliminates the O(bytes-so-far) re-walk per packet, or the cost is documented and bounded with a regression benchmark.

**Given** a mid-query `tnsPacketRefuse` packet
**When** it is received by the transport
**Then** the resulting exception reflects the actual REFUSE reason rather than reusing `oraInvalidCredentials`.

**Given** the `dart_fast_auth.bin` debug write path in `sendFastAuth()`
**When** Story 7.4 ships
**Then** the debug write code (and any orphaned `dart:io` import retained from an earlier cleanup) is removed.

**Given** `sendData()` with a 0x0800 default `dataFlags` on FAST_AUTH and protocol-negotiation packets
**When** this is exercised
**Then** the default is either documented as Oracle-protocol-required **or** narrowed to the specific callsites that need it.

### Story 7.5: Auth & Crypto Coverage Hardening

As a driver maintainer,
I want every authentication path (FAST_AUTH, classical, 12c, SHA512, 0xB92) to have proven coverage and defensive guards,
So that intermittent hash-length flakes, verifier mis-encoding, or short pre-23 responses cannot ship undetected.

**Acceptance Criteria:**

**Given** the intermittent `RangeError (end): Invalid value: Not in inclusive range 0..31: 32` surfacing in `lib/src/crypto/auth.dart` `fullHash.sublist(0, 32)`
**When** the hash buffer is shorter than 32 bytes
**Then** a defensive length check raises an `OracleException` with a meaningful message
**And** a targeted reproducer test simulates the short-hash condition.

**Given** [lib/src/crypto/verifier.dart](lib/src/crypto/verifier.dart) at 85.7% coverage
**When** Story 7.5 closes
**Then** coverage is at or above the 90% crypto-layer target, with the previously-uncovered defensive branches exercised by tests.

**Given** `Transport._sequence` after 256 calls to `nextSequence()`
**When** the counter wraps to 0x01
**Then** a unit test asserts the wrap behavior and the documented Oracle expectation for long-lived connections.

**Given** `shouldWriteTokenNumber` gated on `_ttcFieldVersion`
**When** boundary tests run
**Then** the threshold is verified at `version=18` (true), `version=17` (false), and `version=0` (false), in addition to the existing default `version=24`.

**Given** `toVerifierParams` with default `Uint8List(16)` fallbacks
**When** the verifier is consumed by AES-256-CBC
**Then** the params have explicit length assertions (not just `isNotNull`) so block-alignment regressions surface as test failures.

**Given** `generatePasswordProof` setting `_speedyKey` for verifierType `0xB92`
**When** AUTH_PHASE_TWO is encoded
**Then** the wire message includes the speedy key for both `0x4815` (12c) and `0xB92` paths, OR a documented decision (with a test) records that 0xB92 intentionally omits it.

**Given** the SHA512 verifier path (`verifierType=0x939`) flagged for potential AES block-alignment crash
**When** Story 7.5 ships
**Then** unit tests exercise the SHA512 branch end-to-end (with mocked inputs simulating an 11g-era server) and confirm no block-misalignment crash.

**Given** `transport.shouldWriteTokenNumber` currently depends on `_ttcFieldVersion` (default 24)
**When** a short `ProtocolResponse` returns null `compileCaps`
**Then** the gating uses `transport.supportsFastAuth` (or another protocol-presence signal) so a pre-23 server cannot receive `use23aiFormat=true`.

**Given** `AuthPhaseOneResponse.decode` receiving `msgType == ttcMsgTypeError`
**When** the response is parsed
**Then** the decoder raises an `OracleException` carrying the parsed Oracle error code, rather than logging a warning and returning empty `sessionData`.

**Given** the classical AUTH branch in `AuthFlow.authenticate`
**When** `updateState(phaseOneSent)` is called
**Then** the state transition occurs only after the classical phase-one packet is actually written to the wire (no premature state advance on `sendProtocolNegotiation` failure).

**Given** the FAST_AUTH receive path in `AuthFlow.authenticate` where `transport.receiveData()` (phase one buffered response) or `transport.sendFastAuth` can throw a non-`OracleException` (e.g. a Dart `SocketException`)
**When** such an exception escapes
**Then** `updateState(AuthState.failed)` is called before the exception propagates, so `AuthState` is never left at `phaseOneSent` after an unhandled FAST_AUTH error. Deferred from Story 7.4 code review (Edge Case Hunter, 2026-06-01) — FAST_AUTH path was intentionally left unchanged in Story 7.4 (AC4 targeted classical only); [lib/src/crypto/auth.dart:~363-369](../../lib/src/crypto/auth.dart).

**Given** the classical AUTH_PHASE_ONE timeout wrapper added in Story 7.4 ([lib/src/transport/transport.dart `sendAuthPhaseOne`](../../lib/src/transport/transport.dart))
**When** Story 7.5 closes
**Then** a deterministic unit test exercises the timeout path using a fake/controlled transport (a local `ServerSocket` that accepts but never replies), asserts `oraConnectTimeout` is thrown, and confirms the transport is poisoned (isConnected returns false) after the timeout. The 21c integration suite exercises the classical path end-to-end, but a unit-level timeout test is needed for regression without a live Oracle server. Deferred from Story 7.4 code review (Acceptance Auditor, 2026-06-01) — integration coverage exists; deterministic unit test is the gap.

### Story 7.6: Statement Cache Correctness

As a driver maintainer,
I want the statement cache to key on bind signature, invalidate on DDL, bound its memory, and have integration evidence for cursor reuse,
So that schema changes, bind-type changes, or pathological cache sizes cannot corrupt subsequent executions.

**Acceptance Criteria:**

**Given** two `execute()` calls running concurrently on the same `OracleConnection`
**When** the second call begins before the first resolves
**Then** the documented contract (either explicit serialization or "undefined; user must not overlap") is captured in API docs and asserted via a test (sequential-only test that documents the precondition).

**Given** a SELECT statement is parsed and cached, then a DDL alters the underlying table to change the result shape
**When** the cached statement is re-executed
**Then** Oracle's DESCRIBE_INFO presence/absence is detected and the cached `expectedColumns` is invalidated rather than reused for the new shape, OR the limitation is documented and `OracleException` is raised on mismatch.

**Given** the same SQL text is executed with different bind types between runs
**When** the cache lookup happens
**Then** the cache key includes a bind signature (types per slot) so node-oracledb-thin–style mismatches surface as parse, not as ORA-01007 or silent coercion.

**Given** `sendCloseCursors` writes all queued cursor IDs in one TTC message
**When** the cursor count exceeds the negotiated SDU
**Then** the message is chunked into multiple sends bounded by SDU.

**Given** a cached statement re-execute returns `response.cursorId == 0`
**When** `_cache.invalidate(sql)` is currently called unconditionally
**Then** the invalidation only fires for the actual failure case (verified against Oracle protocol behavior), preserving the cached cursor for legitimate `cursorId == 0` responses.

**Given** `SELECT ... FOR UPDATE` with statement caching enabled
**When** the same locked SELECT runs twice
**Then** row-lock semantics across executions are documented (test or comment) and any divergence from Oracle expectations is either fixed or excluded from the cache.

**Given** `statementCacheSize` set to a pathological value (e.g. `1 << 31`)
**When** the cache is initialized
**Then** an upper bound is enforced (documented cap) or a warning is logged.

**Given** the integration test for `statementCacheSize: 1`
**When** the test runs
**Then** AC3 is strengthened: the assertion verifies cursor reuse (via `v$open_cursor` query or transport-level instrumentation), not merely that A→B→A doesn't crash.

**Given** `isCacheEligibleSql` and `isQuerySql` both independently call `_findCteTerminalVerb` for `WITH`-prefixed SQL (introduced in Story 7.3)
**When** either function is updated to handle a new SQL shape
**Then** the other is updated in the same commit, OR `isCacheEligibleSql` is refactored to delegate to `isQuerySql` for the `WITH ... SELECT` branch so the logic is no longer duplicated. Deferred from Story 7.3 code review (2026-05-22) — maintainability risk only; no current divergence.

### Story 7.7: Protocol Version-Gating & Pre-23 Compatibility

As a driver maintainer,
I want decode-side version gates to mirror the encode side, and pre-23 servers / Flutter Web targets to be either supported or explicitly rejected,
So that we cannot silently corrupt streams against older servers and so future platform expansion has a clear path.

**Acceptance Criteria:**

**Given** `_processColumnInfo` reading 23.4 vector fields unconditionally
**When** a pre-23.4 server response is decoded
**Then** the six vector-field bytes are read only if the server version supports them; otherwise the read is skipped.

**Given** `_processColumnInfo` reading the 12.2 `oaccolid` field unconditionally on decode
**When** a pre-12.2 server response arrives
**Then** the read is gated on the same version flag used for encode-side gating.

**Given** `_processIoVector` reading `fastFetchLen` and `rowidLen`
**When** Story 3.1 OUT-parameter work is referenced
**Then** the read method (variable-length UB2 vs raw UB2) is confirmed against node-oracledb's `messages/ioVector.js` and the chosen method is documented.

**Given** `_readInteger` for UB8 sizes > 2^53 at [lib/src/protocol/buffer.dart](lib/src/protocol/buffer.dart)
**When** the package is published
**Then** the package manifest declares Dart VM as the supported runtime, **or** UB8 reads use a representation safe under dart2js (`BigInt` or 64-bit split) for any field that can exceed 2^53.

**Given** `readBytesWithLength` treating a 0xFF length prefix as null
**When** an Oracle LONG / LONG RAW column with a 255-byte payload is decoded
**Then** the 0xFF-as-null heuristic is constrained to types where it is correct (current scope) and LONG support (Epic 4) raises an explicit unsupported error.

**Given** `_readInteger` sign-magnitude with size byte `0x80` (negative-zero edge)
**When** unit tests run
**Then** the edge case is covered with explicit assertions matching the documented Oracle TNS sentinel.

**Given** `_processColumnInfo` setting `maxLength = size` for non-RAW types
**When** numeric columns (where `size == 0`) are decoded
**Then** either `maxLength` reflects a meaningful value for future buffer-allocation callers, OR the field is documented as "non-RAW: meaningless".

**Given** a DML statement against a pre-12.2 server
**When** `rowsAffected` is read
**Then** the field is `null` (not `0`) when the server did not send a UB8 row-count, with the contract documented.

**Given** `_maxSizeFor` returning `1` for null-valued VARCHAR binds
**When** statement caching reuses the same prepared statement with a non-null VARCHAR value
**Then** the cached `maxSize` is recomputed (or the cache key includes bind size hint) so the bind buffer does not under-allocate.

**Given** `_receiveAllTtcData` on the pre-23.4 code path (Oracle 21c / 19c) where `ttcStreamIsComplete` is called per inbound packet
**When** the server never returns a response that satisfies the completion probe (e.g. a future TTC message type not yet understood by the parser)
**Then** the loop has a configurable iteration cap (or a hard upper bound) that poisons the transport and throws `OracleException(oraProtocolError)` rather than looping indefinitely. Deferred from Story 7.4 code review (Edge Case Hunter, 2026-06-01) — pre-existing design gap; [lib/src/transport/transport.dart `_receiveAllTtcData` else-branch](../../lib/src/transport/transport.dart).

**Given** the 23ai error-response sub-path in `_receiveAllTtcData` where `flags == 0x0000` and the trailing `0x1D` guard calls `_concatChunks(chunks)` per inbound packet
**When** a long error response arrives over multiple packets (rare but possible)
**Then** the accumulation avoids O(N×bytes) allocation per packet on this path, OR the cost is documented and bounded by an extension of the existing AC6 benchmark that covers the 23ai flags-0x0000 branch. Deferred from Story 7.4 code review (Blind Hunter, 2026-06-01) — rare error path; common path (flags=0x2000 / 0x0040) is unaffected; [lib/src/transport/transport.dart:~573-585](../../lib/src/transport/transport.dart).

**Given** `Transport.sendConnectReceiveAccept` calling `_receiveRawPacket` (used during the initial CONNECT/ACCEPT handshake)
**When** this is called on a transport that has been poisoned by a prior RPC timeout on the same instance
**Then** `_ensureUsable()` is checked before `_receiveRawPacket` so a poisoned transport fails fast rather than silently attempting to read stale bytes. Note: in normal usage the CONNECT phase runs before any RPC timeout can occur; this guard only matters if a transport object is ever reused after being poisoned (currently not done in production code, but the invariant should be enforced). Deferred from Story 7.4 code review (Edge Case Hunter, 2026-06-01); [lib/src/transport/transport.dart `sendConnectReceiveAccept`](../../lib/src/transport/transport.dart).

### Story 7.8: Test Infrastructure & Data-Type Coverage Expansion

As a driver maintainer,
I want integration tests to use unique tables/PKs, normalized env-var gating, defensive setUp/tearDown, and broad data-type coverage,
So that parallel CI runs and retries do not collide and so type-decode regressions are caught before production.

**Acceptance Criteria:**

**Given** integration tests sharing the fixed table name `test_types_story26` and fixed PKs `1..10`
**When** Story 7.8 lands
**Then** tables are uniquely named (e.g. suffixed with a per-suite UUID or test name) and PKs are generated from a sequence or random value to eliminate cross-suite collisions.

**Given** the inconsistent `Platform.environment.containsKey('RUN_INTEGRATION_TESTS')` vs `== 'true'` skip guards
**When** Story 7.8 lands
**Then** all integration files normalize on `== 'true'` (`RUN_INTEGRATION_TESTS=false` skips, no value skips, `true` runs).

**Given** `setUp` blocks where `connect()` may throw before `late OracleConnection connection` is assigned
**When** the suite executes
**Then** `tearDown` no longer raises `LateInitializationError` masking the root failure (uses a nullable connection variable with null-safe close).

**Given** `tearDown` blocks calling `DROP TABLE` followed by `close()` in a `finally`
**When** either call throws
**Then** the original error (e.g. non-942 DROP failure) is preserved and the secondary cleanup failure is logged but not rethrown over it.

**Given** the `_ub8` test helper at [test/src/protocol/messages/execute_message_test.dart](test/src/protocol/messages/execute_message_test.dart) that currently aliases `_ub4`
**When** Story 7.8 ships
**Then** `_ub8` emits a proper variable-length UB8, decoupled from `_ub4`, and at least one fixture with a >32-bit value exercises it.

**Given** the sparse `decodeExecuteResponse` unit test coverage (4 fixture cases)
**When** Story 7.8 closes
**Then** unit tests cover: NUMBER decode variants, multi-bind value ordering, column metadata parsing, chunked payload decoding, DML rowsAffected combinations.

**Given** a fixed-scale `NUMBER` column (e.g. `NUMBER(10,2)`) whose stored value is integer-valued (`0`, `42`, etc.)
**When** the column is decoded via `decodeValue` → `decodeNumber`
**Then** the returned Dart value is a `double`, not an `int` (matching the node-oracledb reference at `lib/impl/datahandlers/buffer.js` `parseOracleNumber` + `parseFloat` wrapper, which always returns a Number).
**And** the bare-`NUMBER` path (no declared scale) may continue to use the int-vs-double heuristic for backward compatibility.
**Implementation note:** requires propagating the column's declared precision/scale into `decodeNumber` (it currently sees only `(buffer, length)`). Deferred from Story 7.1 code review (2026-05-22) where the AC5.5 integration test had to assert numeric value only because the existing heuristic collapses `NUMBER(10,2)` zero to `int`. When this AC lands, tighten [test/integration/number_edge_cases_integration_test.dart:150-162](../../test/integration/number_edge_cases_integration_test.dart#L150-L162) to assert `isA<double>()`.

**Given** `encodeNumber` called with a finite Dart double outside Oracle NUMBER's representable exponent range (roughly `1e-130` to `1e125` in base-10)
**When** encoding runs
**Then** an `OracleException(oraDataTypeNotSupported)` is raised with a descriptive message — **not** a wrapped-modulo-256 exponent byte that produces garbage on the wire.
**Implementation note:** the encoder must compute the base-100 exponent before writing the exponent byte and bounds-check it against Oracle's range. Pre-existing gap; the Story 7.1 AC3 non-finite rejection only covers NaN/±Infinity, not finite-but-out-of-range values. Deferred from Story 7.1 code review (Edge Case Hunter, 2026-05-22).

**Given** `encodeNumber` writing an integer-valued NUMBER such as `10000` whose canonical mantissa has trailing zero base-100 digit pairs
**When** the value is encoded
**Then** the wire bytes match node-oracledb's canonical encoding (trailing zero mantissa pairs stripped) — currently `10000` emits 4 bytes (`0xC3 0x02 0x01 0x01`) where the reference emits 2 (`0xC3 0x02`). Functionally correct (decodes back to the same value); only matters for byte-for-byte canonicalization against indexed caches or hashing pipelines. Deferred from Story 7.1 code review (2026-05-22).

**Given** `decodeNumber` returning an integer-valued NUMBER above `2^53` (the Dart safe-integer boundary)
**When** the value is reconstructed through `_pow100` double arithmetic and the int-vs-double heuristic returns `.toInt()`
**Then** the precision-loss contract is pinned by an explicit boundary test (e.g. `SELECT 9007199254740993 FROM dual` — one above `maxSafeInt` — asserting the loss is bounded and predictable). Pre-existing heuristic acknowledged in Story 7.1 AC5.2 ("38-digit precision-loss behavior"); this AC just adds the boundary test that AC5.2 did not pin. Deferred from Story 7.1 code review (2026-05-22).

**Given** committed probe tools `tool/dml_probe.dart` and `tool/simple_probe.dart` with hardcoded `system/testpassword`
**When** Story 7.8 lands
**Then** the probes are either deleted, relocated to `tool/debug/` (and `.gitignored`), or refactored to read `ORA_TEST_USER`/`ORA_TEST_PASSWORD` env vars.

**Given** `classical_auth_integration_test.dart` and similar tests importing from `package:oracledb/src/...`
**When** Story 7.8 lands
**Then** the tests either use a test-only public API (`dart_oracledb_internal`) or the imports are pinned with a comment justifying the `src/` dependency.

**Given** `socket_test.dart` without an `@Tags(['integration'])` annotation
**When** the integration tag-based exclusion is normalized
**Then** all integration files carry the annotation and `markTestSkipped` patterns are removed where redundant.

**Given** `OracleConnection.connect` calls in setUp blocks without an explicit timeout
**When** the listener is hung
**Then** setUp fails fast within a documented bound (e.g. 5s) instead of stalling until `dart test`'s global timeout.

**Given** the AC6 regression benchmark in `test/src/transport/ttc_stream_benchmark_test.dart` asserts `elapsedMilliseconds < 3000` for 200 full-buffer scans
**When** Story 7.8 closes
**Then** the bound is tightened to a value grounded in CI baseline measurements (the current 3 s ceiling catches catastrophic regression but not a 10× slowdown). Deferred from Story 7.4 code review (Blind Hunter, 2026-06-01) — intentionally generous to avoid CI flakiness until a stable baseline exists; [test/src/transport/ttc_stream_benchmark_test.dart](../../test/src/transport/ttc_stream_benchmark_test.dart).

**Given** Oracle 23ai is the only CI target for the `quality` matrix
**When** Story 7.8 ships
**Then** Linux is added to the `platform` matrix (or AC4 is updated to explicitly delegate Linux coverage to the `quality` job) so the matrix name reflects its scope.

### Story 7.9: API Surface, Error Handling & CI/Release Tooling

As a driver maintainer,
I want public-facing error formatting, response immutability, and CI/release tooling to be defensive against pathological inputs and operator mistakes,
So that the API contract is clean and the release pipeline fails visibly rather than silently.

**Acceptance Criteria:**

**Given** `OracleException.code` formatting an `errorCode` value that is negative or ≥ 100000
**When** the `code` getter runs
**Then** the output is either clamped to a documented range, padded correctly, or raises a clear `ArgumentError` — no `ORA--1` or `ORA-100000` strings.

**Given** `_truncateSql` slicing on UTF-16 code units with `sql.substring(0, 200)`
**When** SQL contains supplementary-plane characters near the 200-char boundary
**Then** truncation uses `Characters` (or rune-aware slicing) so surrogate pairs are not split.

**Given** `ColumnMetadata` and `ExecuteResponse` fields are mutable after the Story 6.3 rebuild
**When** Story 7.9 ships
**Then** the fields are restored to immutable (`final` + defensive list copies) and `_DecodeState.rows` no longer aliases `response.rows` directly.

**Given** the Oracle 19c CI readiness wait loop using a TCP probe + 5s sleep
**When** Oracle 19c PDB mount is slow on cold runners
**Then** the wait loop replaces the fixed sleep with a `sqlplus` (or equivalent) probe loop bounded by a timeout, so ORA-12514 cannot flake CI.

**Given** the `integration` job `timeout-minutes: 15`
**When** cold-runner Oracle 23ai startup approaches that bound
**Then** the timeout is raised to 20 minutes (or the readiness probe is hardened so the bound becomes safe).

**Given** `testpassword` in `--health-cmd` visible in GitHub Actions logs
**When** Story 7.9 ships
**Then** the secret is read from a CI variable (or the credential is generated per-run and rotated), with the trade-off documented if intentionally left as ephemeral.

**Given** `docker ps --no-trunc` used for failure diagnostics
**When** the Oracle listener probe times out
**Then** the diagnostic command is replaced with `docker logs <container>` so Oracle startup errors are visible.

**Given** `dart analyze` runs in both `quality` and `platform` matrix jobs
**When** CI cost optimization is in scope
**Then** the redundant `dart analyze` is removed from the `platform` job (analyzer output is platform-independent).

**Given** coverage is generated and uploaded but no threshold is enforced
**When** a stable baseline is established
**Then** a CI step (e.g. `lcov --summary | awk`) fails the build if overall coverage drops below 80% (or the configured target from project-context.md).

**Given** `OracleConnection.forTesting(statementCacheSize: -1)` (and the production constructor `OracleConnection(..., statementCacheSize: -1)`)
**When** the constructor runs
**Then** an `ArgumentError` is thrown with a descriptive message before `StatementCache` is constructed with a negative size. Deferred from Story 7.4 code review (Edge Case Hunter, 2026-06-01) — pre-existing gap in both constructors; [lib/src/connection.dart](../../lib/src/connection.dart).

**Given** Codecov upload is skipped on fork PRs
**When** community contributors submit PRs
**Then** coverage trends are tracked via tokenless Codecov configuration or `pull_request_target`-scoped upload, or the limitation is documented in CONTRIBUTING.md.

**Given** `scripts/bump_version.sh` invoking `claude -p` without exit-code check (stderr silenced)
**When** the helper fails
**Then** the script exits non-zero with the underlying stderr surfaced.

**Given** a `TIMESTAMP WITH TIME ZONE` value decoded by `decodeTimestamp` (which currently returns a plain `DateTime` in UTC — losing the original zone offset)
**When** the value is re-bound for an `UPDATE` or `INSERT`
**Then** the original wire offset is preserved via a companion type (e.g. `OracleTimestampTz` wrapper exposing both the absolute UTC instant and the original offset/region), so `SELECT … UPDATE …` round-trips do not silently shift the value's zone information. The wrapper must be opt-in (default decode behavior stays as Story 7.1 AC1 chose — return UTC `DateTime`). Deferred from Story 7.1 code review (Edge Case Hunter, 2026-05-22) — contract gap, out of 7.1 scope.

**Given** SQL passed to `execute()` that opens with a leading `(` (e.g. JDBC-shim-wrapped `(SELECT * FROM t)` or `(BEGIN ... END;)`)
**When** `skipSqlPrefixes` runs (Story 7.3 intentionally removed paren-stripping)
**Then** the public API documentation for `execute()` explicitly notes that leading `(` causes the statement to be treated as unclassified (not query, not PL/SQL, not cache-eligible), and any JDBC-compatibility wrapper that produces paren-prefixed SQL must strip the outer parens before passing to the driver. Deferred from Story 7.3 code review (2026-05-22) — intentional design; documentation gap only.

**Given** Oracle q-quote literals (`q'[...]'`, `q'{...}'`, etc.) inside a CTE body in `_findCteTerminalVerb`
**When** the q-quote content contains a raw `'` (e.g. `q'[it's fine]'`)
**Then** the scanner handles the alternative-quoting syntax without premature string-literal exit, OR a code comment documents that Oracle q-quote in CTE headers is unsupported and the classification result for such SQL is undefined. Deferred from Story 7.3 code review (Edge Case Hunter, 2026-05-22) — requires Oracle q-quote inside CTE definitions, which is rare; complex to fix.

**Given** `_findCteTerminalVerb`'s outer scan loop has no explicit whitespace branch — `\r`, `\n`, spaces, and tabs are consumed by the `pos++` fallthrough
**When** a line comment inside a CTE body ends with `\r`
**Then** the `\r` is correctly skipped (confirmed working via fallthrough), but the loop is refactored to include an explicit whitespace branch so the "consume unknown character" intent is self-documenting and a future `break`/`return` addition cannot introduce a silent regression. Deferred from Story 7.3 code review (2026-05-22) — functionally correct; fragility concern only.

<!-- End Epic 7 -->

---

# Post-1.0 Epics (8–15)

Added 2026-06-13 via Correct Course (`sprint-change-proposal-2026-06-13.md`).
These extend the shipped 1.0.0 driver toward node-oracledb thin-mode parity.

**Definition of Done (applies to every story in Epics 8–15):**

- `dart analyze` passes with zero warnings.
- Integration tests written with `test_helper.dart` (no hardcoded connection params).
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color` passes against **Oracle 23ai** (FAST_AUTH).
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --no-color` passes against **Oracle 21c** (classical AUTH).
- node-oracledb thin parity preserved where the candidate cites reference behavior.

> Detailed Given/When/Then acceptance criteria for each story below are authored
> at `create-story` time. The story lists here set scope and acceptance themes.

## Epic 8: Streaming & Incremental Result Consumption

**Goal:** Let applications process large query outputs without materializing every
row in memory and without relying on the single-`execute()` fetch safety cap.

**Depends on:** none. **⚠️ Architecture review required** — introduces a
cursor-backed result model and the one-in-flight-operation-per-connection
invariant for active streams.

**Reference:** node-oracledb `connection.queryStream()`, `ResultSet`
(`reference/node-oracledb/doc/src/api_manual/connection.rst:2265`,
`.../resultset.rst:7`).

**Stories:**

- **8.1 `OracleResultSet` cursor-backed result object** — closeable result with `getRow()`/`getRows(n)`/`close()`; metadata available before first row.
- **8.2 `queryStream()` / `executeStream()`** — returns `Stream<OracleRow>` with configurable `fetchSize`; rows arrive incrementally across fetch rounds.
- **8.3 `execute(resultSet: true)` option** — `OracleExecuteOptions(resultSet: true)` returns an `OracleResultSet` instead of a materialized list, if it fits the existing API style.
- **8.4 Cancellation & connection reuse** — early stream cancellation closes the server cursor and leaves the connection reusable; enforce one in-flight operation per connection.
- **8.5 Statement-cache safety & dual-env tests** — protect cache behavior while streamed cursors are open; integration tests on 23ai + 21c.

## Epic 9: REF CURSOR & Implicit Results

**Goal:** Support REF CURSOR OUT binds, nested cursors, and implicit result sets,
built on `OracleResultSet`.

**Depends on:** **Epic 8** (`OracleResultSet`).

**Reference:** `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:263`,
`.../plsql_execution.rst:342`.

**Stories:**

- **9.1 REF CURSOR OUT bind** — decode a PL/SQL REF CURSOR OUT bind into an `OracleResultSet`.
- **9.2 Nested cursors** — handle cursor-valued result columns.
- **9.3 Implicit result sets** — `DBMS_SQL.RETURN_RESULT` consumption.
- **9.4 Dual-env integration tests** — 23ai + 21c.

## Epic 10: Non-AL32UTF8 Database Character Set Compatibility

**Goal:** Support Oracle databases whose database character set is not AL32UTF8,
keeping Dart strings Unicode and client wire encoding aligned with the thin
reference (server-side conversion model).

**Depends on:** none. **⚠️ Architecture review required** — revisits the
`lib/src/protocol/buffer.dart` UTF-8 assumption and fast-auth charset negotiation.

**Reference:** `reference/node-oracledb/doc/src/user_guide/globalization.rst:15`,
`:36`, `:54`, `:209`; `appendix_a.rst:185`.

**Stories:**

- **10.1 Charset capability detection** — detect server charset and national charset at startup.
- **10.2 Client UTF-8 negotiation model** — validate/implement thin model: negotiate UTF-8 client char data, rely on server-side conversion.
- **10.3 VARCHAR2/CHAR/CLOB round-trip** — correct round-trip against ≥1 non-AL32UTF8 DB charset.
- **10.4 National charset handling** — NCHAR/NVARCHAR2/NCLOB on AL16UTF16; fail-loud `OracleException` (no silent mojibake) on unsupported configs.
- **10.5 Docs & CI fixture** — README support matrix; CI non-AL32UTF8 fixture if reliable; dual-env tests.

## Epic 11: Bulk DML (`executeMany`)

**Goal:** Array DML binding for high-volume insert/update/delete and PL/SQL.

**Depends on:** none.

**Reference:** `reference/node-oracledb/doc/src/api_manual/connection.rst:1629`,
`appendix_a.rst:176`.

**Stories:**

- **11.1 `executeMany()` array DML API** — bind arrays of rows for bulk DML.
- **11.2 Bulk PL/SQL array binds.**
- **11.3 Row-level batch error handling** — `batchErrors`-style per-row reporting.
- **11.4 DML RETURNING with `executeMany`.**
- **11.5 Dual-env integration tests** — 23ai + 21c.

## Epic 12: LOB Streaming & Temporary LOBs

**Goal:** Public streaming LOB object and temporary LOB lifecycle, building on the
Epic 4 basic CLOB/BLOB value support.

**Depends on:** none (extends Epic 4).

**Reference:** `reference/node-oracledb/doc/src/api_manual/connection.rst:892`,
`appendix_a.rst:278`.

**Stories:**

- **12.1 Public LOB object** — read/write streaming for CLOB/BLOB.
- **12.2 Temporary LOB lifecycle** — creation and cleanup.
- **12.3 Chunked streaming transfer** — large payloads without full materialization.
- **12.4 Dual-env integration tests** — 23ai + 21c.

## Epic 13: JSON / OSON Parity

**Goal:** Full JSON support across Oracle versions (21c native JSON type; 12c
JSON-as-BLOB).

**Depends on:** none (extends Story 4.4 JSON work).

**Reference:** `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:296`, `:299`.

**Stories:**

- **13.1 Oracle 21c native JSON (OSON) codec.**
- **13.2 Oracle 12c JSON-as-BLOB compatibility path.**
- **13.3 Bind & fetch JSON** — Dart map/list mapping.
- **13.4 Dual-env integration tests** — 23ai + 21c.

## Epic 14: Temporal Compatibility & Fetch Type Handlers

**Goal:** Close remaining temporal gaps and add custom fetch representations.

**Depends on:** none (extends Epic 4 / Story 7.9 TSTZ work).

**Reference:** `reference/node-oracledb/doc/src/user_guide/sql_execution.rst:1015`,
`:1032`; `README.md:334`; Story 7.9 notes.

**Stories:**

- **14.1 TSTZ region-name decode** — region-id TSTZ values decoded to the correct UTC instant.
- **14.2 Region-name preservation** — optional preservation with clearly documented limits.
- **14.3 Fetch-as-string** — dates/timestamps fetchable as strings.
- **14.4 Fetch type-handler hooks** — custom per-column conversion.
- **14.5 Dual-env integration tests** — 23ai + 21c.

## Epic 15: Extended Data Type Completeness

**Goal:** Medium-value type coverage for schema completeness.

**Depends on:** none.

**Reference:** `reference/node-oracledb/doc/src/user_guide/appendix_a.rst:287`,
`:778`, `:323`, `:814`.

**Stories:**

- **15.1 INTERVAL DAY TO SECOND.**
- **15.2 INTERVAL YEAR TO MONTH.**
- **15.3 ROWID / UROWID.**
- **15.4 VECTOR** (Oracle 23ai).
- **15.5 Dual-env integration tests** — 23ai + 21c.

<!-- End Epic 15 / Post-1.0 Epics -->
