---
created: 2026-06-23
story_key: 10-3-varchar2-char-clob-roundtrip
baseline_commit: 20dcf7e748d3a7930d678ca4cc512ad6dd6c269f
---

# Story 10.3: VARCHAR2/CHAR/CLOB Round-Trip

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart Oracle driver user,
I want VARCHAR2, CHAR, and CLOB values to round-trip correctly against a non-AL32UTF8 database character set,
so that normal primary text data works through Oracle server-side conversion without a Dart-side database charset codec.

## Acceptance Criteria

1. **Non-AL32UTF8 fixture is explicit and cannot be faked**
   **Given** the new Story 10.3 integration suite is run
   **When** its non-AL32UTF8 tests are enabled
   **Then** it connects to a database whose `OracleConnection.charsetInfo.databaseCharset` is not `AL32UTF8`
   **And** the test fails with a clear message if the target database is still `AL32UTF8`
   **And** all connection parameters come from environment-driven helpers, not hardcoded host, port, service, user, password, or schema names.

2. **VARCHAR2 primary text round-trips through binds and fetch**
   **Given** a non-AL32UTF8 database character set such as `WE8MSWIN1252` or `WE8ISO8859P1`
   **When** representable Western text is inserted into `VARCHAR2` columns through positional and named binds
   **Then** fetching the row returns the exact Dart `String`
   **And** tests cover ASCII, accented Latin-1 text, mixed punctuation representable by the fixture charset, SQL `NULL`, and Oracle's documented empty-string-as-`NULL` behavior.

3. **CHAR padding semantics remain exact**
   **Given** a `CHAR(N)` column in the non-AL32UTF8 fixture
   **When** a shorter representable string is inserted and fetched
   **Then** the returned Dart string preserves Oracle's right-padding spaces exactly
   **And** the driver does not trim or normalize the value client-side.

4. **Length and conversion failures are visible**
   **Given** bounded `VARCHAR2` columns in the non-AL32UTF8 fixture
   **When** a value exceeds the declared column length
   **Then** Oracle raises the expected over-length error, such as ORA-12899
   **And** the driver surfaces it as an `OracleException` without replacing it with a charset/client-codec error.

5. **CLOB query, DML, and PL/SQL paths round-trip**
   **Given** a non-AL32UTF8 database character set
   **When** CLOB values are inserted, fetched, updated, and passed through PL/SQL OUT / IN OUT binds
   **Then** the returned Dart `String` exactly matches the input for values representable by the fixture charset
   **And** tests cover SQL `NULL`, `EMPTY_CLOB()`, small CLOBs, multi-chunk CLOB reads, and the temp-CLOB path for values over the 32767-byte VARCHAR bind limit.

6. **Thin UTF-8 server-conversion model is preserved**
   **Given** Stories 10.1 and 10.2 detected charset info and made UTF-8 negotiation explicit
   **When** Story 10.3 is implemented
   **Then** do not add arbitrary Dart database charset codecs, do not parse or honor `NLS_LANG`, do not make primary text encoding configurable, and do not branch primary VARCHAR2/CHAR/CLOB encoding on `OracleCharsetInfo.databaseCharset`
   **And** primary client charset negotiation remains `ttcCharsetUtf8` (`873`) on both FAST_AUTH and classical paths.

7. **National charset scope remains fenced**
   **Given** Story 10.4 owns NCHAR/NVARCHAR2/NCLOB support
   **When** Story 10.3 is implemented
   **Then** do not implement `ttcCharsetAl16Utf16`, `readNString()` / `writeNString()`, or NCHAR/NVARCHAR2/NCLOB bind/fetch support
   **And** existing fail-loud NCHAR/NCLOB behavior remains unless a test proves a primary CLOB regression that must be fixed without adding national-type support.

8. **Standard dual-env suites keep passing**
   **Given** the existing Oracle 23ai and Oracle 21c fixtures are running
   **When** the focused charset/CLOB integration tests and full test suite run
   **Then** Story 10.1 and 10.2 behavior remains green on both standard environments
   **And** the new non-AL32UTF8 test is skipped only when its explicit enable flag is absent, never when it is enabled against the wrong database.

## Tasks / Subtasks

- [x] Add a non-AL32UTF8 integration-test entry point (AC: 1, 8)
  - [x] Add `test/integration/charset_non_al32utf8_integration_test.dart`.
  - [x] Gate it behind an explicit flag such as `RUN_NON_AL32UTF8_TESTS=true`; when the flag is absent, skip with a clear reason.
  - [x] Add environment-driven connection helpers for the fixture, preferably in `test/integration/test_helper.dart` using `ORACLE_NON_AL32UTF8_HOST`, `ORACLE_NON_AL32UTF8_PORT`, `ORACLE_NON_AL32UTF8_SERVICE`, `ORACLE_NON_AL32UTF8_USER`, and `ORACLE_NON_AL32UTF8_PASSWORD`.
  - [x] If the suite is enabled and `connection.charsetInfo.databaseCharset == 'AL32UTF8'`, fail immediately with a message that the fixture is invalid for Story 10.3.
  - [x] Use `uniqueTableName()`, `nextTestId()`, and `cleanUpConnection()`; do not hardcode schema object names or credentials.

- [x] Prove VARCHAR2 and CHAR round-trip on the non-AL32UTF8 fixture (AC: 2, 3, 4)
  - [x] Create a table with `VARCHAR2`, `VARCHAR2(... CHAR)`, `CHAR(N)`, and `CLOB` columns.
  - [x] Insert and fetch representable Western text through named and positional binds; use explicit Dart escapes where useful so the test source encoding is not part of the proof.
  - [x] Assert `VARCHAR2` SQL `NULL` returns `null`, and binding `''` to `VARCHAR2` returns `null` after fetch.
  - [x] Assert `CHAR(N)` returns the padded string exactly, e.g. `value.padRight(N)`.
  - [x] Assert an over-length bind surfaces ORA-12899 (or the exact Oracle error observed on the target fixture) as `OracleException`.

- [x] Prove CLOB behavior on the non-AL32UTF8 fixture (AC: 5)
  - [x] Cover `NULL` CLOB and `EMPTY_CLOB()` separately.
  - [x] Cover small CLOB insert/fetch and update/fetch with accented Latin-1 text.
  - [x] Cover a multi-chunk query-read CLOB using a large representable text value.
  - [x] Cover PL/SQL CLOB OUT and IN OUT through `OracleBind.out(type: OracleDbType.clob, maxSize: ...)` and `OracleBind.inOut(...)`.
  - [x] Cover a value whose UTF-8 client payload exceeds `ttcMaxVarcharBindBytes` so `_createTempClob()` is exercised.
  - [x] Keep CLOB test values representable in the selected database charset. Do not use CJK or emoji in this non-AL32UTF8 suite; Story 10.2 already proves those on AL32UTF8 standard fixtures.

- [x] Preserve the UTF-8 primary text model (AC: 6, 7)
  - [x] Leave `WriteBuffer.writeString()`, `ReadBuffer.readString()`, `encodeVarchar()`, and `decodeVarchar()` as UTF-8 paths for primary text.
  - [x] Do not add dependencies for arbitrary Oracle database charset conversion.
  - [x] Do not use `OracleCharsetInfo.databaseCharset` to choose a primary text codec.
  - [x] Keep FAST_AUTH/classical negotiation byte layout unchanged unless a regression test proves an existing bug; if touched, preserve the Story 10.2 `ttcCharsetUtf8` contract.
  - [x] Keep NCHAR/NVARCHAR2/NCLOB implementation out of scope.

- [x] Validate regressions and document fixture commands (AC: 1, 8)
  - [x] Run `dart analyze`.
  - [x] Run the focused non-AL32UTF8 integration test with its explicit env flag against a real non-AL32UTF8 database.
  - [x] Run `RUN_INTEGRATION_TESTS=true dart test test/integration/charset_capability_integration_test.dart test/integration/charset_negotiation_integration_test.dart test/integration/clob_integration_test.dart --no-color` on Oracle 23ai.
  - [x] Run the same focused set on Oracle 21c with `ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1`.
  - [x] Run the full integration suite on both standard fixtures before marking done, per project rule.
  - [x] Add a test-file doc comment with the exact non-AL32UTF8 env vars and command used. README support-matrix/CI fixture work remains Story 10.5 unless this story adds a small local-only helper.

### Review Findings

- [x] [Review][Patch] Require the actual WE8MSWIN1252 fixture instead of only rejecting AL32UTF8 [test/integration/charset_non_al32utf8_integration_test.dart:92]
- [x] [Review][Patch] Replace raw non-ASCII test literals with explicit Dart Unicode escapes where the story claims source-encoding independence [test/integration/charset_non_al32utf8_integration_test.dart:65]
- [x] [Review][Patch] Gate the non-AL32UTF8 suite behind the standard RUN_INTEGRATION_TESTS flag as well as RUN_NON_AL32UTF8_TESTS [test/integration/charset_non_al32utf8_integration_test.dart:73]
- [x] [Review][Patch] Fix the non-AL32 helper comment that says the default service is FREEPDB1 while the code uses we8pdb1 [test/integration/test_helper.dart:52]
- [x] [Review][Patch] Avoid echoing the fixture admin password into SQL init logs [test/integration/fixtures/non_al32utf8_setup.sql:25]
- [x] [Review][Patch] Wait for killed PDB sessions to detach before attempting the character-set migration [test/integration/fixtures/non_al32utf8_setup.sql:41]

## Dev Notes

### Scope Boundary

Story 10.3 is a proof and correction story for **primary** database character set conversion on `VARCHAR2`, `CHAR`, and `CLOB`. It should reuse the model established by Stories 10.1 and 10.2: the client wire path stays UTF-8 (`ttcCharsetUtf8`), and Oracle converts between client AL32UTF8 and the database character set. This story should not implement arbitrary client-side database charsets, national types, or README/CI support matrix changes beyond minimal test documentation.

### Architecture Guardrails

- Epic 10 architecture says primary wire charset remains UTF-8 (`873`) and the server converts to/from the database character set. Do not make `buffer.dart` configurable. [Source: `_bmad-output/planning-artifacts/architecture.md` "Core model decision - adopt node-oracledb thin charset model"]
- `OracleCharsetInfo.databaseCharset` is diagnostic and a fixture assertion, not a codec selector. [Source: `lib/src/oracle_charset_info.dart`]
- National charset handling (`AL16UTF16`, `NCHAR`, `NVARCHAR2`, `NCLOB`) belongs to Story 10.4. [Source: `_bmad-output/planning-artifacts/epics.md` Epic 10 story list]
- Tests must pass on both standard Oracle 23ai and Oracle 21c fixtures, and integration tests must use `test/integration/test_helper.dart` patterns. [Source: `_bmad-output/project-context.md` "Mandatory: Dual-Environment Validation"]
- The non-AL32UTF8 test must prove a real non-AL32UTF8 target. A skip is acceptable only when the explicit non-AL32 flag is absent; an enabled suite connected to AL32UTF8 is a test failure.

### Files To Read Before Editing

- `test/integration/test_helper.dart`
  - Current state: provides env-driven standard fixture getters, `integrationEnabled`, `connectForTest()`, `uniqueTableName()`, `nextTestId()`, and `cleanUpConnection()`.
  - What this story changes: add non-AL32UTF8 fixture getters/connect helper if the new test needs shared setup.
  - Must preserve: standard 23ai/21c defaults, `RUN_INTEGRATION_TESTS == 'true'` behavior, 5-second default timeout, and cleanup semantics.

- `test/integration/charset_negotiation_integration_test.dart`
  - Current state: Story 10.2 standard-fixture smoke test for UTF-8 negotiation and VARCHAR2 round-trips with ASCII, accented Latin, CJK, emoji, and mixed text.
  - What this story changes: likely no direct edits; use it as the AL32UTF8 baseline and pattern source.
  - Must preserve: no hardcoded connection parameters and dual-env behavior.

- `test/integration/charset_capability_integration_test.dart`
  - Current state: Story 10.1 detection tests for `charsetInfo`, instrumentation cleanliness, and pool inheritance on standard fixtures.
  - What this story changes: likely no direct edits; use `charsetInfo` assertions in the new non-AL32 suite.
  - Must preserve: standard fixture assumption that `NLS_NCHAR_CHARACTERSET == AL16UTF16`.

- `test/integration/clob_integration_test.dart`
  - Current state: comprehensive CLOB coverage: NULL, EMPTY_CLOB, small and large query reads, DML binds, PL/SQL OUT/IN OUT, temp-CLOB threshold and large-write boundaries.
  - What this story changes: do not duplicate the whole file. Port the minimum high-value matrix into the new non-AL32 suite: small text, multi-chunk read, PL/SQL temp CLOB, and NULL/empty behavior.
  - Must preserve: standard 23ai/21c CLOB coverage and existing large-write boundary tests.

- `lib/src/oracle_charset_info.dart`
  - Current state: immutable detected charset model; documents database charset vs national charset and the UTF-8 server-conversion model.
  - What this story changes: likely no code change.
  - Must preserve: diagnostic-only meaning of `databaseCharset` and `supportsNationalCharacterSet` being national-type only.

- `lib/src/protocol/data_types.dart`
  - Current state: `encodeVarchar()` and `decodeVarchar()` use UTF-8 and document CHAR padding and empty-string semantics.
  - What this story changes: likely no code change unless non-AL32 tests expose a real bug.
  - Must preserve: UTF-8 primary text path, CHAR trailing spaces, and `''` as `NULL` for VARCHAR2.

- `lib/src/protocol/messages/execute_message.dart`
  - Current state: bind/define metadata writes `ttcCharsetUtf8` for nonzero `csfrm`; CLOB/BLOB locators are decoded and materialized by transport; NCLOB is fail-loud when `csfrm == ttcCsfrmNChar`.
  - What this story changes: only if tests expose a primary CLOB metadata bug.
  - Must preserve: LOB prefetch flags, locator shape, JSON/RAW/REF CURSOR/implicit result handling, and NCHAR hard rejection.

- `lib/src/transport/transport.dart`
  - Current state: `_createTempClob()` writes temp CLOB data as UTF-16BE when the locator reports variable-length charset, otherwise UTF-8; `_readClobAsString()` decodes the assembled LOB bytes once and fails loud on malformed data or length mismatch.
  - What this story changes: only if non-AL32 CLOB tests expose a real primary CLOB bug.
  - Must preserve: one full-length LOB READ per locator, temp LOB cleanup queue, `debugLobReadOps`, OUT bind maxSize enforcement, and BLOB behavior.

- `lib/src/protocol/lob_locator.dart`
  - Current state: defines `usesVarLengthCharset`, `encodeUtf16Be()`, and `decodeUtf16Be()`.
  - What this story changes: likely no code change.
  - Must preserve: UTF-16BE handling for variable-length charset CLOB locators and `String.length` as Oracle CLOB UCS-2-unit length.

- `docker-compose.yml`
  - Current state: standard Oracle 23ai and Oracle 21c services only.
  - What this story changes: do not require CI or global compose changes unless a small optional local non-AL32UTF8 service is reliable. Story 10.5 owns CI fixture hardening and README support matrix.
  - Must preserve: existing service names, ports, healthchecks, and Apple Silicon guidance.

### Existing Code Facts

- `OracleConnection.charsetInfo` is populated once during startup by querying `NLS_DATABASE_PARAMETERS`. [Source: `lib/src/connection.dart` `_detectCharsetInfo`]
- Story 10.2 replaced primary charset literals in negotiation writers with `ttcCharsetUtf8` and verified FAST_AUTH/classical byte layout. Do not re-open that unless tests fail.
- `VARCHAR2` and `CHAR` scalar conversion already uses UTF-8 encode/decode; tests should prove server conversion on a real non-AL32UTF8 database rather than changing this path.
- CLOB query results travel as locators and are materialized before escaping `Transport.sendExecute`; PL/SQL large strings may be converted into temporary CLOBs. Non-AL32 CLOB proof must hit both paths.
- Current deferred item: `resetExecuteInstrumentation()` does not reset `_lobReadOps`; do not change startup charset detection to read LOB data in this story. [Source: `_bmad-output/implementation-artifacts/deferred-work.md`]

### Previous Story Intelligence

- Story 10.1 added `OracleCharsetInfo`, startup detection, and failure cleanup. Its review fixed stack-trace preservation and credential-free errors; keep new fixture failures credential-free.
- Story 10.2 made primary UTF-8 negotiation explicit and added `charset_negotiation_integration_test.dart`; it deliberately left non-AL32UTF8 proof to this story.
- Story 10.2 review left deferred transport/parser hardening items that are not required for this story unless a new test exposes them.
- Existing CLOB integration tests already cover large temp-CLOB write boundaries and multi-chunk read behavior on standard fixtures. Reuse their data patterns instead of inventing a new CLOB pipeline.

### Git Intelligence Summary

- `20dcf7e feat(tests): implement client UTF-8 negotiation integration tests` touched charset tests, auth/data-types constants, transport testability, and Story 10.2 artifact.
- `028ad1b feat(oracledb): implement character set detection for Oracle connections` touched `connection.dart`, `oracle_charset_info.dart`, `transport.dart`, and charset capability tests.
- Recent changes are test-heavy and centered on charset detection/negotiation. Story 10.3 should start as integration coverage plus only minimal production fixes if the new fixture reveals a real defect.

### Latest Technical Information

- node-oracledb 7.0.0 globalization docs state Thin mode relies on the database server for database-character-set conversion and uses AL32UTF8 for character data. Source checked 2026-06-23: https://node-oracledb.readthedocs.io/en/latest/user_guide/globalization.html
- node-oracledb docs also state `AL16UTF16` national charset is supported, while `UTF8` national charset is not supported in Thin mode. This informs Story 10.4, not this primary text story. Source checked 2026-06-23: https://node-oracledb.readthedocs.io/en/latest/user_guide/globalization.html
- node-oracledb Appendix A lists client character set support as UTF-8 and says Thin mode ignores Oracle NLS environment variables. Source checked 2026-06-23: https://node-oracledb.readthedocs.io/en/latest/user_guide/appendix_a.html
- Oracle Database container docs state `ORACLE_CHARACTERSET` sets the character set when creating official Oracle Database Free/XE container databases, defaulting to `AL32UTF8`. Source checked 2026-06-23: https://raw.githubusercontent.com/oracle/docker-images/main/OracleDatabase/SingleInstance/README.md
- Oracle Database 26ai reference documents `NLS_DATABASE_PARAMETERS` as the permanent database NLS parameter view with `PARAMETER` and `VALUE` columns. Source checked 2026-06-23: https://docs.oracle.com/en/database/oracle/oracle-database/26/refrn/NLS_DATABASE_PARAMETERS.html

### Project Structure Notes

- Prefer a new focused file under `test/integration/charset_non_al32utf8_integration_test.dart`.
- Add helper getters in `test/integration/test_helper.dart` only if shared helper code is cleaner than local env parsing.
- Keep production code under `lib/src/` only if the new fixture exposes a driver defect.
- Do not update README support claims unless the story also adds a reliable fixture story note; Story 10.5 owns support matrix and CI fixture work.
- Use `package:oracledb/oracledb.dart` in integration tests; use `src/` imports only in focused unit tests.

### Done Criteria Checklist

- [x] Non-AL32UTF8 integration test written with explicit enable flag and environment-driven connection parameters.
- [x] Enabled non-AL32UTF8 suite fails if connected to `AL32UTF8`.
- [x] VARCHAR2, CHAR, and CLOB round-trip tests pass against at least one real non-AL32UTF8 database charset.
- [x] Existing charset capability, charset negotiation, and CLOB focused tests pass on Oracle 23ai.
- [x] Existing charset capability, charset negotiation, and CLOB focused tests pass on Oracle 21c.
- [x] Full integration suite passes on both standard supported environments before marking done.
- [x] `dart analyze` reports zero issues.

### Open Questions

- Which concrete non-AL32UTF8 fixture will be used for the first live validation: `WE8MSWIN1252`, `WE8ISO8859P1`, or another single-byte Western charset? The test should document the exact charset it was validated against.
- Should this story add an optional local Docker Compose profile for the non-AL32UTF8 database, or keep the fixture entirely env-driven and leave compose/CI wiring to Story 10.5?

## Dev Agent Record

### Agent Model Used

claude-opus-4-8 (Opus 4.8, 1M context) — BMad dev-story workflow

### Debug Log References

- Non-AL32UTF8 focused suite (real WE8MSWIN1252 fixture): 20/20 passed.
- AC1/AC8 guard verified two ways: flag absent → all 20 skipped with reason;
  flag enabled against AL32UTF8 (23ai 1521/FREEPDB1) → every test fails loudly
  with the StateError fixture-invalid message (never silently passes).
- Focused charset+CLOB regression (`charset_capability` + `charset_negotiation`
  + `clob`): 23ai 46/46, 21c 46/46.
- Full integration suite: 23ai 401 passed / 28 skipped; 21c 402 passed /
  27 skipped (the 20 non-AL32 tests skip without `RUN_NON_AL32UTF8_TESTS`,
  per AC8; remainder are pre-existing TLS-only skips).
- Unit suite: 1315 passed / 12 skipped. `dart analyze`: no issues.

### Completion Notes List

- **Outcome: integration coverage only — no production code change.** The
  driver's existing UTF-8 server-conversion model (Stories 10.1/10.2) round-trips
  VARCHAR2/CHAR/CLOB primary text against a real non-AL32UTF8 database with no
  defect. Nothing under `lib/` was modified, so AC6 (UTF-8 model preserved:
  `writeString`/`readString`/`encodeVarchar`/`decodeVarchar` untouched, no
  database-charset codec, no NLS_LANG parsing, no `databaseCharset` branching,
  `ttcCharsetUtf8` negotiation intact) and AC7 (national scope fenced: no
  `ttcCharsetAl16Utf16`, `readNString`/`writeNString`, or NCHAR/NVARCHAR2/NCLOB
  support added) are satisfied by construction.
- **Provisioning the non-AL32UTF8 fixture was the hard part.** Every readily
  available Oracle 23ai/26ai Free image ships a PREBUILT AL32UTF8 database and
  ignores `ORACLE_CHARACTERSET` — verified against the official
  `container-registry.oracle.com/database/free`, `gvenzl/oracle-free:slim`, and
  `gvenzl/oracle-free:latest` (all stayed AL32UTF8). `CREATE PLUGGABLE DATABASE
  ... CHARACTER SET` is not valid syntax (ORA-00922). The working approach: the
  `non-al32utf8` compose profile bind-mounts `non_al32utf8_setup.sql` into
  gvenzl's first-boot init dir (runs as SYSDBA in CDB$ROOT); it creates a fresh
  empty PDB `we8pdb1` and migrates it to WE8MSWIN1252 via the CSALTER bypass
  (`ALTER DATABASE CHARACTER SET INTERNAL_USE WE8MSWIN1252`) — safe because the
  PDB still holds only its all-ASCII data dictionary. Verified single-byte:
  `DUMP` shows `é` = `0xe9` (one byte), not UTF-8 `c3 a9`.
- **Validated charset: WE8MSWIN1252.** AC2's punctuation case (euro, smart
  quotes, en/em dash, ellipsis, bullet) is WIN1252-specific — those code points
  are control codes in ISO-8859-1 — so a clean round-trip proves real client
  UTF-8 ⇆ server WE8MSWIN1252 conversion, not an accidental byte-identity pass.
- **The non-AL32UTF8 fixture is local-only and opt-in.** It is gated behind
  `RUN_NON_AL32UTF8_TESTS=true`, lives behind the `non-al32utf8` compose profile
  (untouched by `docker compose up` and CI), and the standard dual-env suites
  skip it. CI fixture wiring + README support matrix remain Story 10.5.
- **Open Questions resolved:** (1) validated against WE8MSWIN1252; (2) added a
  small optional local-only compose profile + init script (the story explicitly
  permitted "a small local-only helper"), keeping the test fully env-driven.
- **Code review patches applied:** tightened the non-AL32 guard to require
  WE8MSWIN1252 because the data set uses WIN1252-specific punctuation; converted
  non-ASCII data literals to explicit Dart Unicode escapes; made the suite honor
  `RUN_INTEGRATION_TESTS`; fixed the helper service-name comment; suppressed SQL
  echo around password-bearing DDL; and waited for killed sessions to detach
  before charset migration.

### File List

- `test/integration/charset_non_al32utf8_integration_test.dart` (new) — focused
  non-AL32UTF8 VARCHAR2/CHAR/CLOB round-trip suite (AC1–AC8).
- `test/integration/test_helper.dart` (modified) — added `nonAl32Enabled` gate,
  `ORACLE_NON_AL32UTF8_*` env-driven getters, and `connectForNonAl32Test()`.
- `test/integration/fixtures/non_al32utf8_setup.sql` (new) — first-boot init
  script that creates + migrates the `we8pdb1` WE8MSWIN1252 PDB.
- `docker-compose.yml` (modified) — added the optional, profile-gated
  `oracle-non-al32` service (gvenzl/oracle-free + init-script bind mount).

## Change Log

| Date | Change |
|------|--------|
| 2026-06-25 | Implemented Story 10.3: new non-AL32UTF8 (WE8MSWIN1252) integration suite proving VARCHAR2/CHAR/CLOB server-side conversion; env-driven `ORACLE_NON_AL32UTF8_*` helpers; optional `non-al32utf8` compose profile + PDB-migration init script. No production code changed (UTF-8 model and national-type fence preserved). Validated: non-AL32 20/20, focused regression 23ai 46/46 + 21c 46/46, full integration 23ai 401✓/28-skip + 21c 402✓/27-skip, unit 1315✓, analyzer clean. Status → review. |
