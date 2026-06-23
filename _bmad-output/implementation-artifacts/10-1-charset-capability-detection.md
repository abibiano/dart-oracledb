---
created: 2026-06-23
story_key: 10-1-charset-capability-detection
baseline_commit: ef91bf97dd1289b6ddaf9d2e66a52c86a59b03c1
---

# Story 10.1: Charset Capability Detection

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart Oracle driver user,
I want each connection to detect the database character set and national character set during startup,
so that the driver can diagnose charset compatibility clearly before later Epic 10 stories add non-AL32UTF8 round-trip and national-character support.

## Acceptance Criteria

1. **Connection startup records database and national charset names**
   **Given** a standalone `OracleConnection.connect()` call succeeds
   **When** authentication completes and the connection is returned to user code
   **Then** the connection has a non-null charset capability object containing `NLS_CHARACTERSET` and `NLS_NCHAR_CHARACTERSET`
   **And** detection is performed once per physical connection, not once per query
   **And** the values come from `NLS_DATABASE_PARAMETERS` unless protocol negotiation exposes an equivalent reliable source.

2. **Detection is available to pools without extra public ceremony**
   **Given** `OraclePool.create()` prewarms or opens physical sessions through the existing connection path
   **When** a pooled connection is acquired
   **Then** the same charset capability object is already available on that borrowed connection
   **And** no pool-specific duplicate detection path is introduced.

3. **Thin UTF-8 model is preserved**
   **Given** Epic 10 adopts node-oracledb Thin's server-conversion model
   **When** Story 10.1 is implemented
   **Then** do not add configurable Dart-side database charset codecs
   **And** do not use `NLS_LANG` to choose client encoding
   **And** keep primary character data on the existing UTF-8/AL32UTF8 wire path
   **And** leave full client charset negotiation and national type encoding changes to Stories 10.2 and 10.4 unless a small constant extraction is needed for test clarity.

4. **Unsupported national charset is diagnosed, not silently ignored**
   **Given** `NLS_NCHAR_CHARACTERSET` is detected
   **When** its value is `AL16UTF16`
   **Then** the capability object reports national character support as compatible
   **When** its value is anything else, including `UTF8`
   **Then** the capability object reports national character support as incompatible
   **And** current NCHAR/NCLOB hard-rejection behavior remains fail-loud until Story 10.4 implements the supported AL16UTF16 path.

5. **Detection failures fail visibly and safely**
   **Given** the post-auth charset detection query fails, returns neither required parameter, or returns malformed data
   **When** `OracleConnection.connect()` is completing startup
   **Then** the connection is closed before the error escapes
   **And** an `OracleException` is thrown with useful context
   **And** no password, verifier, session key, or connect string credentials are logged or included in the message.

6. **No existing connection/query behavior regresses**
   **Given** charset detection is added to startup
   **When** existing query, DML, PL/SQL, LOB, JSON, streaming, REF CURSOR, implicit-result, statement-cache, and pool tests run
   **Then** their public API behavior is unchanged
   **And** startup detection does not leave an open result set, in-flight operation flag, stale statement-cache entry, or unclosed cursor.

7. **Unit coverage proves parsing and lifecycle edge cases**
   **Given** focused unit tests run without a real database
   **When** charset capability parsing and connect-time error paths are exercised
   **Then** tests cover normal `AL32UTF8`/`AL16UTF16`, incompatible national charset, missing `NLS_CHARACTERSET`, missing `NLS_NCHAR_CHARACTERSET`, duplicate rows, and cleanup-on-detection-failure behavior.

8. **Integration coverage proves both supported Oracle environments**
   **Given** Oracle 23ai and Oracle 21c Docker fixtures are running
   **When** charset integration tests run through `test/integration/test_helper.dart`
   **Then** both environments report non-empty database and national charset names
   **And** the standard fixtures report `NLS_NCHAR_CHARACTERSET = AL16UTF16`
   **And** the tests use environment-driven host, port, service, user, and password values with no hardcoded connection parameters.

9. **Developer-facing diagnostics are documented in code**
   **Given** a user or later story needs to understand charset behavior
   **When** reading the new capability type, getter, and relevant comments
   **Then** the docs state that primary wire strings remain UTF-8 and server-converted
   **And** national charset compatibility is about NCHAR/NVARCHAR2/NCLOB support, not normal VARCHAR2/CHAR/CLOB support.

## Tasks / Subtasks

- [x] Add a charset capability model (AC: 1, 3, 4, 9)
  - [x] Add an immutable value type such as `OracleCharsetInfo` with `databaseCharset`, `nationalCharset`, and `supportsNationalCharacterSet`.
  - [x] Prefer uppercase normalized names for comparisons, while preserving the server-reported names for diagnostics if useful. (Names normalized to uppercase — Oracle's canonical form.)
  - [x] Expose it via a read-only `OracleConnection.charsetInfo` getter. If the type is public, export it through `lib/oracledb.dart`. (Exported.)
  - [x] Do not expose a mutable setter or a user-provided charset override.

- [x] Detect charset info during physical connection startup (AC: 1, 2, 5, 6)
  - [x] After authentication succeeds and before returning the `OracleConnection`, run a single query against `NLS_DATABASE_PARAMETERS` for `NLS_CHARACTERSET` and `NLS_NCHAR_CHARACTERSET`.
  - [x] Build the final connection object with populated charset info, or create it then assign through a private initialization path before returning. (Built then `_detectCharsetInfo()` assigns before return.)
  - [x] If detection fails after authentication, close/disconnect the transport before throwing.
  - [x] Ensure startup detection leaves `_executeInProgress`, result-set ownership, and statement-cache state clean. (Query is uncacheable → no cache entry / no held cursor; `_executeInProgress` cleared in `finally`; parse counters reset.)

- [x] Preserve the existing wire model (AC: 3, 6)
  - [x] Keep `buffer.dart` `readString()` / `writeString()` as UTF-8 for primary character data. (Unchanged.)
  - [x] Do not add arbitrary database charset codecs or depend on `NLS_LANG`. (None added.)
  - [~] Replace hardcoded `873` literals with `ttcCharsetUtf8` only where it clarifies existing behavior. (Deliberately NOT done — the literals are in byte-exact auth/negotiation tests; replacing them risks regressing AC3/AC6 with no behavior gain. Discretionary subtask.)
  - [x] Defer `ttcCharsetAl16Utf16 = 2000`, `readNString()` / `writeNString()`, and NCHAR/NVARCHAR2/NCLOB decode/encode to Stories 10.2/10.4. (Deferred — `OracleCharsetInfo` uses the `AL16UTF16` name, not the wire id, so the constant is not needed yet.)

- [x] Add focused unit tests (AC: 4, 5, 7, 9)
  - [x] Add tests for normal and incompatible national charset parsing.
  - [x] Add tests for missing/duplicate/malformed detection rows.
  - [x] Add a connection-startup failure test that proves cleanup occurs if detection throws after auth.
  - [x] Update existing tests that assert charset negotiation bytes only if constants replace magic numbers; do not change expected primary charset bytes in this story. (No magic-number replacement made → no existing test changed.)

- [x] Add dual-env integration coverage (AC: 1, 2, 8)
  - [x] Add `test/integration/charset_capability_integration_test.dart`.
  - [x] Use `connectForTest()` and `test_helper.dart`; no hardcoded host, port, service, user, password, or static schema object names.
  - [x] Assert `connection.charsetInfo.databaseCharset` and `.nationalCharset` are non-empty.
  - [x] Assert standard fixtures report `nationalCharset == 'AL16UTF16'` and `supportsNationalCharacterSet == true`.
  - [x] Run on Oracle 23ai and Oracle 21c.

- [x] Validate the full story (AC: 6, 8)
  - [x] `dart analyze` (zero issues, whole project).
  - [x] Focused unit tests for charset capability and any touched connection/protocol files (full unit suite: 1306 pass).
  - [x] `RUN_INTEGRATION_TESTS=true dart test test/integration/charset_capability_integration_test.dart --no-color` (4/4 on 23ai).
  - [x] `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/charset_capability_integration_test.dart --no-color` (4/4 on 21c).
  - [x] Full integration suite on both supported environments before marking done, per project rule. (23ai 395/8-skip; 21c 396/7-skip.)

### Review Findings

- [x] [Review][Patch] Null PARAMETER column null-coalesces to empty string producing misleading "not returned" error — replace `?? ''` with an explicit null assertion or early throw [lib/src/connection.dart]
- [x] [Review][Patch] Non-OracleException errors in `_detectCharsetInfo` catch lose original stack trace — use `catch (e, st)` + `Error.throwWithStackTrace` to preserve origin frame [lib/src/connection.dart]
- [x] [Review][Patch] AC5 credential-free test asserts only `"password"` absence; spec requires no password, verifier, session key, or connect string — add assertions for the remaining three terms [test/src/connection_charset_detection_test.dart]
- [x] [Review][Patch] AC8 integration test missing project-standard `/// Must pass on Oracle 23ai (FREEPDB1) and Oracle 21c (XEPDB1).` doc comment — all other dual-env integration tests carry this convention [test/integration/charset_capability_integration_test.dart]
- [x] [Review][Defer] `resetExecuteInstrumentation()` excludes `_sequence`, `_lobReadOps`, and `_describeRetries` from reset scope — correct for the current VARCHAR2-only detection query; note this boundary if a future story changes the detection query to return LOB columns [lib/src/transport/transport.dart] — deferred, pre-existing scope boundary

## Dev Notes

### Scope Boundary

Story 10.1 is a detection and diagnostics story. It must create the reliable connection-level fact that later Epic 10 stories use. It must not implement full non-AL32UTF8 round-trip validation, a non-AL32UTF8 CI fixture, arbitrary client encodings, NCHAR/NVARCHAR2/NCLOB support, or README support-matrix changes except small API docs needed for the new capability getter.

### Architecture Guardrails

- The Epic 10 architecture decision is explicit: keep primary wire character data as UTF-8/AL32UTF8 and rely on Oracle server conversion for database character sets. Do not make primary text encoding configurable. [Source: `_bmad-output/planning-artifacts/architecture.md` Epic 10]
- Capability detection stores the server DB charset and national charset for diagnostics and fail-loud checks; it does not select the primary wire codec. [Source: `_bmad-output/planning-artifacts/architecture.md` "Charset capability detection"]
- National charset compatibility is separate from database charset compatibility. `AL16UTF16` is the supported national charset target; `UTF8` national charset must be treated as incompatible for Thin-mode national types. [Source: `_bmad-output/planning-artifacts/architecture.md` Epic 10]
- This project selects FAST_AUTH vs classical auth from `Transport.supportsFastAuth`, never from version strings. Do not add charset logic that changes auth-path selection. [Source: `_bmad-output/project-context.md` "Auth path is server-driven"]
- Tests must pass on both Oracle 23ai and Oracle 21c and must use `test/integration/test_helper.dart` for all connection parameters. [Source: `_bmad-output/project-context.md` "Mandatory: Dual-Environment Validation"]

### Files To Read Before Editing

- `lib/src/connection.dart`
  - Current state: `OracleConnection.connect()` creates a `Transport`, completes TNS handshake, authenticates via `AuthFlow.authenticate()`, then returns `OracleConnection._(...)`. Query execution is guarded by `_executeInProgress`; lazy result sets and implicit results own the connection until closed.
  - What this story changes: add connection-level charset info and initialize it during startup after auth and before returning the connection.
  - Must preserve: authentication cleanup, `timeout`, `statementCacheSize`, `preserveTimestampTimeZone`, `_executeInProgress`, result-set ownership, bounded SQL snippets in errors, and connection close semantics.

- `lib/src/pool.dart`
  - Current state: pools open physical sessions through the same connection path and borrow/release already-authenticated connections.
  - What this story changes: likely no pool-specific logic; pooled sessions should inherit `charsetInfo` automatically from `OracleConnection.connect()`.
  - Must preserve: rollback-on-release, session tagging, drain behavior, and force-close of abandoned result sets.

- `lib/src/protocol/messages/auth_message.dart`
  - Current state: AUTH_PHASE_TWO writes `SESSION_CLIENT_CHARSET` as `'873'` and stores crypto values as UTF-8 hex strings.
  - What this story changes: no behavior change expected. Replacing `873` with `ttcCharsetUtf8.toString()` is acceptable if tests are updated.
  - Must preserve: no password logging, uppercase hex UTF-8 crypto fields, speedy-key verifier gating, and FAST_AUTH-specific token behavior.

- `lib/src/protocol/messages/fast_auth_message.dart`
  - Current state: DataTypes negotiation writes primary charset 873 and national charset 873 as little-endian fields. Tests currently assert UTF-8 charset 873 appears in the DataTypes message.
  - What this story changes: no required behavior change for detection. Do not change national charset negotiation in this story unless the implementation deliberately pulls in a no-user-visible constant extraction with tests.
  - Must preserve: FAST_AUTH envelope shape, embedded protocol/DataTypes/AUTH_PHASE_ONE order, sequence number 1, and capability trimming.

- `lib/src/transport/transport.dart`
  - Current state: classical data-types negotiation also writes `873 / 873`; `sendFastAuth()` parses the combined protocol/DataTypes/AUTH response and buffers the AUTH response; `sendProtocolNegotiation()` handles the classical path. `receiveData()` may return the buffered AUTH response after FAST_AUTH.
  - What this story changes: likely no transport behavior. If constants replace magic numbers, keep byte order and parsing unchanged.
  - Must preserve: server-driven `supportsFastAuth`, `ttcFieldVersion` adjustment, one-byte TTC sequence counter, TNS data flags, and `_receiveAllTtcData()` completion-probe behavior.

- `lib/src/protocol/buffer.dart`
  - Current state: `readString()` and `writeString()` are UTF-8; variable-length byte helpers distinguish null/empty markers and chunked payloads.
  - What this story changes: no required change. Do not add primary database charset codecs.
  - Must preserve: explicit endian methods, `BufferUnderflowException` as the only "more bytes may be coming" signal, and UTF-8 primary string behavior.

- `lib/src/protocol/constants.dart`
  - Current state: `ttcCsfrmImplicit = 1`, `ttcCsfrmNChar = 2`, and `ttcCharsetUtf8 = 873` exist.
  - What this story changes: optional constant cleanup only. `ttcCharsetAl16Utf16 = 2000` can wait for Story 10.2/10.4 unless needed to document compatibility.
  - Must preserve: existing type codes and constants used by LOB, JSON, cursor, bind, and execute paths.

- `lib/src/protocol/messages/execute_message.dart`
  - Current state: `ColumnMetadata` already stores `csfrm`; column names and string values are UTF-8 decoded, currently with `allowMalformed: true` in result decode; NCHAR/NCLOB are still hard-rejected.
  - What this story changes: likely no result decode behavior. Later stories will route NCHAR by `csfrm`; this story should not quietly weaken hard rejections.
  - Must preserve: current VARCHAR2/CHAR/CLOB behavior, LOB materialization, JSON, REF CURSOR/nested cursor, implicit-result, and `ttcFieldVersion` threading.

- `lib/oracledb.dart`
  - Current state: single public export file.
  - What this story changes: export any new public charset capability type if the getter's return type is public.
  - Must preserve: existing public API names and semantic-version-compatible additive change.

- `test/integration/test_helper.dart`
  - Current state: env-driven `connectForTest()`, `testConnectString`, credentials, `uniqueTableName()`, `nextTestId()`, and `cleanUpConnection()`.
  - What this story changes: likely nothing.
  - Must preserve: `RUN_INTEGRATION_TESTS == 'true'` gate, 5-second default connect timeout, and no hardcoded service/port values in tests.

### Existing Code Facts

- `Capabilities` has a `charset` field and `defaultCharset = 873`, but the current connect path does not expose DB/national charset names and does not store charset capability data on `OracleConnection`.
- `ProtocolResponse` parsing includes a charset id in protocol-message tests, but Epic 10 architecture says the reliable implementation can query `NLS_DATABASE_PARAMETERS` if negotiation metadata is insufficient.
- `README.md` still lists non-AL32UTF8 database charset compatibility as backlog/limitation; do not update the support matrix in Story 10.1 unless the implementation fully proves a support claim. Story 10.5 owns that.

### Previous Story Intelligence

- Story 10.1 is the first Epic 10 story, so there is no previous Epic 10 implementation artifact.
- Epic 9 retrospective required the Epic 10 architecture review before story authoring; `architecture.md` now contains the Epic 10 design and should be treated as authoritative.
- Epic 9 also called out `ttcFieldVersion` threading as a repeated risk. Avoid introducing any new decode path in this story; if a future story does, it must thread negotiated field version deliberately.
- Recent cursor work changed `connection.dart`, `execute_message.dart`, and result-set ownership paths. Charset startup detection must not leave an in-flight query/result-set state that would interact badly with those paths.

### Git Intelligence Summary

- `3af3be9 feat(cursor): materialize nested CURSOR() inside implicit results & REF CURSOR OUT binds` recently modified `connection.dart`, `execute_message.dart`, `result_set_cursor.dart`, and integration tests. Any connection startup change should avoid disturbing cursor lifecycle logic.
- `ef91bf9 chore: bump version to 1.1.0` confirms the public API is in semantic-versioned post-1.0 mode; adding a getter/type is acceptable, but changing existing return shapes is not.
- `b267a19 docs(deferred-work): mark the backlog clean -- no open items` means do not reintroduce deferred-work entries unless implementation discovers a real defect outside 10.1 scope.

### Latest Technical Information

- node-oracledb 7.0.0 docs, last updated June 2, 2026, state that in Thin mode the database server performs required database-character-set conversion, and the client uses AL32UTF8 for character data. Source checked 2026-06-23: https://node-oracledb.readthedocs.io/en/latest/user_guide/globalization.html
- The same docs give the exact detection queries against `nls_database_parameters` for `NLS_CHARACTERSET` and `NLS_NCHAR_CHARACTERSET`. Source checked 2026-06-23: https://node-oracledb.readthedocs.io/en/latest/user_guide/globalization.html
- node-oracledb docs state AL16UTF16 national character set is supported in Thin mode, while UTF8 national character set is not. Source checked 2026-06-23: https://node-oracledb.readthedocs.io/en/latest/user_guide/globalization.html
- node-oracledb Appendix A states client character set support is UTF-8 in both Thin and Thick modes, and Thin mode ignores Oracle NLS environment variables. Source checked 2026-06-23: https://node-oracledb.readthedocs.io/en/latest/user_guide/appendix_a.html
- Oracle Database 26ai reference documents `NLS_DATABASE_PARAMETERS` as the view containing permanent database NLS parameters with `PARAMETER` and `VALUE` columns. Source checked 2026-06-23: https://docs.oracle.com/en/database/oracle/oracle-database/26/refrn/NLS_DATABASE_PARAMETERS.html

### Project Structure Notes

- Add production code under `lib/src/`; keep `lib/oracledb.dart` as the public export surface.
- Add unit tests under `test/src/` mirroring the touched source area.
- Add integration tests under `test/integration/charset_capability_integration_test.dart`.
- Use `package:oracledb/oracledb.dart` in integration tests; use `src/` imports only in focused unit tests where existing tests already do so.
- Keep imports ordered: `dart:`, `package:`, relative imports.

### Done Criteria Checklist

- [x] Integration tests written using `test_helper.dart` with no hardcoded connection params.
- [x] Tests pass: `RUN_INTEGRATION_TESTS=true dart test test/integration/charset_capability_integration_test.dart --no-color` on Oracle 23ai (4/4).
- [x] Tests pass: `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/charset_capability_integration_test.dart --no-color` on Oracle 21c (4/4).
- [x] Full integration suite passes on both environments before story is marked done (23ai 395 pass / 8 skip; 21c 396 pass / 7 skip — skips are TLS-only).
- [x] `dart analyze` reports zero issues.

## Dev Agent Record

### Agent Model Used

claude-opus-4-8 (dev-story workflow)

### Debug Log References

- `dart analyze` (whole project): No issues found.
- Unit (`dart test test/src/`): 1306 pass / ~12 skip (includes 27 new charset tests).
- Charset integration (focused): 23ai 4/4, 21c 4/4.
- Full integration suite: 23ai 395 pass / 8 skip; 21c 396 pass / 7 skip (skips are TLS-only, env-gated, consistent with prior stories).

### Implementation Plan

Charset detection is a connection-level diagnostic fact, detected once per
physical session:

1. **`OracleCharsetInfo`** (`lib/src/oracle_charset_info.dart`) — immutable value
   type holding `databaseCharset`, `nationalCharset`, and a derived
   `supportsNationalCharacterSet` getter (true iff `AL16UTF16`, matching
   node-oracledb Thin `Capabilities.checkNCharsetId`). A `fromParameterRows`
   factory parses raw `(PARAMETER, VALUE)` rows: normalizes to uppercase,
   tolerates idempotent duplicates, and fails loud (ORA-protocol) on
   missing/blank/conflicting data. Exported from `lib/oracledb.dart`.
2. **Startup detection** (`OracleConnection._detectCharsetInfo`) runs a single
   `SELECT parameter, value FROM nls_database_parameters WHERE parameter IN (...)`
   after auth, before the connection is returned from `connect()`. It is run
   **uncacheable** (new `forceUncacheable` seam through `_executeGuarded` /
   `_prepareStatement`) so it leaves no statement-cache entry and holds no server
   cursor (the cursor closes at fetch EOF, exactly like a non-cached SELECT), then
   resets the transport's execute instrumentation so the internal round trip is
   invisible post-connect (AC6).
3. **Fail-safe** — on any detection failure the connection is `close()`d before
   the `OracleException` propagates (AC5); the detection query carries no
   credentials.
4. Pools inherit detection for free: `OraclePool` opens physical sessions through
   `connect()`, so no pool-specific path was added (AC2).

### Completion Notes List

- Story context created 2026-06-23.
- Implementation complete (dev-story, 2026-06-23). All 9 ACs satisfied.
- **New public API:** `OracleCharsetInfo` + `OracleConnection.charsetInfo`
  getter (additive, semver-compatible). The getter is non-null on any
  connect()/withConnection()/pool connection; it throws `StateError` only on the
  test-only `forTesting` constructor (which bypasses startup detection).
- **Detection source = `NLS_DATABASE_PARAMETERS` query (by design).**
  node-oracledb Thin reads numeric charset *ids* from protocol negotiation
  (`protocol.js` charsetId/nCharsetId) and never exposes names. This story's ACs
  require human-readable *names*, so it queries `NLS_DATABASE_PARAMETERS` (what
  node-oracledb's docs recommend to users) — explicitly sanctioned by AC1 and the
  Epic 10 architecture. Compatibility *semantics* match the reference exactly
  (`AL16UTF16` national → supported; `UTF8` and all others → incompatible).
- **No wire changes.** The `873` literals, the FAST_AUTH/classical negotiation,
  `buffer.dart` UTF-8 strings, and the NCHAR/NVARCHAR2/NCLOB hard-rejection are
  all untouched (AC3/AC4). `ttcCharsetAl16Utf16 = 2000` and `readNString`/
  `writeNString` remain deferred to Stories 10.2/10.4.
- **AC6 invisibility proven** by the integration test (post-connect
  `debugCacheSize`/`debugFullParseExecutes`/`debugReuseExecutes`/
  `debugPendingCloseCount` all 0) AND by the existing absolute parse-count test
  (`query_integration_test.dart` "cursor reuse … proven by instrumentation")
  staying green — it would read 2 instead of 1 without the counter reset.
- Added an `@internal Transport.resetExecuteInstrumentation()` and a
  `@visibleForTesting OracleConnection.detectCharsetInfoForTesting()` seam.

### File List

- `_bmad-output/implementation-artifacts/10-1-charset-capability-detection.md` (story)
- `_bmad-output/implementation-artifacts/sprint-status.yaml` (status tracking)
- `lib/src/oracle_charset_info.dart` (new — `OracleCharsetInfo` value type + parser)
- `lib/oracledb.dart` (export `OracleCharsetInfo`)
- `lib/src/connection.dart` (charset field/getter, `_detectCharsetInfo`, `forceUncacheable` seam, connect() wiring)
- `lib/src/transport/transport.dart` (new `resetExecuteInstrumentation()`)
- `test/src/oracle_charset_info_test.dart` (new — parsing unit tests)
- `test/src/connection_charset_detection_test.dart` (new — startup detection + cleanup unit tests)
- `test/integration/charset_capability_integration_test.dart` (new — dual-env integration tests)

### Change Log

- 2026-06-23 — Implemented Story 10.1 charset capability detection (dev-story).
  Added `OracleCharsetInfo` (public, exported) + `OracleConnection.charsetInfo`
  getter; once-per-connection startup detection via an uncacheable
  `NLS_DATABASE_PARAMETERS` query wired into `connect()`, with fail-loud cleanup
  (closes the connection before throwing) and instrumentation reset so detection
  is invisible post-connect. No wire/negotiation changes. 27 new unit tests + 4
  dual-env integration tests. `dart analyze` clean; full integration suite green
  on Oracle 23ai (395/8-skip) and Oracle 21c (396/7-skip).
