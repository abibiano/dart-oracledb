---
created: 2026-06-23
story_key: 10-2-client-utf8-negotiation-model
baseline_commit: 028ad1be98eacbf427ffeb17b7e15e7f82a5a08a
---

# Story 10.2: Client UTF-8 Negotiation Model

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart Oracle driver user,
I want the driver to explicitly negotiate UTF-8 client character data using the thin-driver model,
so that primary text values can rely on Oracle server-side conversion for non-AL32UTF8 databases without adding fragile client-side charset codecs.

## Acceptance Criteria

1. **Primary client charset negotiation is explicit and constant-driven**
   **Given** either FAST_AUTH or the classical AUTH_PHASE_ONE/AUTH_PHASE_TWO connection path is used
   **When** the driver encodes DataTypes negotiation and AUTH_PHASE_TWO session attributes
   **Then** the primary client character set is `ttcCharsetUtf8` (`873`, AL32UTF8/UTF-8)
   **And** `SESSION_CLIENT_CHARSET` is written from that constant as the string `'873'`
   **And** production code no longer writes unexplained primary-charset literal `873` values in the negotiation paths.

2. **Thin server-conversion model is preserved**
   **Given** Story 10.1 has detected `OracleConnection.charsetInfo.databaseCharset`
   **When** the database charset is `AL32UTF8`, `WE8MSWIN1252`, `WE8ISO8859P1`, or another Oracle database character set
   **Then** the driver still encodes and decodes primary character data as UTF-8 on the client wire path
   **And** the server is relied on to convert to/from its database character set
   **And** no arbitrary Dart-side database charset codec, `NLS_LANG` parser, or public charset override is added.

3. **FAST_AUTH and classical negotiation stay behaviorally aligned**
   **Given** Oracle 23ai advertises FAST_AUTH and Oracle 21c uses the classical path
   **When** each path performs protocol/data-types/auth negotiation
   **Then** both paths advertise the same primary UTF-8 client charset
   **And** the branch remains driven only by `Transport.supportsFastAuth`, never by parsed version strings or detected NLS charset names.

4. **National-character work is not silently pulled into this story**
   **Given** Epic 10 later implements AL16UTF16 national type handling
   **When** Story 10.2 is implemented
   **Then** do not add `readNString()` / `writeNString()`, do not remove the current `ttcCsfrmNChar` hard rejection, and do not claim NCHAR/NVARCHAR2/NCLOB round-trip support
   **And** any national charset constant or comment added here must state that functional national-type support belongs to Story 10.4.

5. **Byte-level tests pin the negotiation contract**
   **Given** focused unit tests run without a live Oracle server
   **When** FAST_AUTH and classical DataTypes negotiation messages are encoded
   **Then** tests assert the primary charset field is little-endian `ttcCharsetUtf8`
   **And** tests assert `AuthPhaseTwoRequest` encodes `SESSION_CLIENT_CHARSET=873`
   **And** existing tests that search loosely for any `873` byte pair are tightened to verify the expected field offset where practical.

6. **Integration tests prove no startup/query regression**
   **Given** Oracle 23ai and Oracle 21c Docker fixtures are running
   **When** charset capability and a small primary-text smoke test run through `test/integration/test_helper.dart`
   **Then** both environments connect successfully, expose `charsetInfo`, and round-trip ordinary `VARCHAR2` values containing ASCII, accents, and multi-byte UTF-8 characters
   **And** the tests use environment-driven host, port, service, user, and password values with no hardcoded connection parameters.

7. **Diagnostics and docs tell future devs the right model**
   **Given** a developer reads the touched constants, auth/data-types negotiation code, or `OracleCharsetInfo` docs
   **When** they look for charset behavior
   **Then** the code states that primary text always uses UTF-8 client encoding and Oracle performs database-charset conversion
   **And** the comments distinguish primary database charset support from national character set support.

## Tasks / Subtasks

- [x] Make primary charset constants the single source of truth (AC: 1, 2, 3)
  - [x] Keep `ttcCharsetUtf8 = 873` in `lib/src/protocol/constants.dart` and use it in `AuthPhaseTwoRequest`, `FastAuthMessage._encodeDataTypesMessageContent`, and `Transport._sendDataTypesNegotiation` (extracted to `Transport.encodeDataTypesMessage`).
  - [x] Replace `SESSION_CLIENT_CHARSET`'s hardcoded `'873'` with `ttcCharsetUtf8.toString()`.
  - [x] Update comments from "UTF-8 = 873" to "primary client charset: AL32UTF8/UTF-8 (`ttcCharsetUtf8`)" so the model is explicit.
  - [x] Do not change packet order, byte order, message type bytes, capability trimming, or data type mappings. (Verified byte-identical: all pre-existing FAST_AUTH/auth/transport unit tests still pass unchanged.)

- [x] Preserve the primary UTF-8 codec path (AC: 2, 7)
  - [x] Leave `WriteBuffer.writeString()` and `ReadBuffer.readString()` as UTF-8. (Untouched.)
  - [x] Do not add a dependency on `package:characters`, `package:charset`, `dart:convert` codecs beyond UTF-8, or any client-side Oracle database charset map. (No new deps; `pubspec.yaml` unchanged.)
  - [x] Confirm `execute_message.dart` primary VARCHAR2/CHAR/CLOB decoding remains UTF-8 and does not branch on `OracleCharsetInfo.databaseCharset`. (Verified: no `databaseCharset`/`charsetInfo` reference in `execute_message.dart`.)
  - [x] Keep `allowMalformed: true` behavior unchanged unless a test proves this story's negotiation work requires a narrower fix; full mojibake/fail-loud cleanup belongs to later Epic 10 stories. (Unchanged.)

- [x] Keep national charset scope fenced (AC: 4)
  - [x] Do not implement `ttcCharsetAl16Utf16` behavior, UTF-16BE read/write helpers, or NCHAR/NVARCHAR2/NCLOB result/bind support in this story.
  - [x] Keep current NCHAR/NCLOB hard rejection in `execute_message.dart`. (Verified: `ttcCsfrmNChar` rejection intact.)
  - [x] If adding `ttcCharsetAl16Utf16 = 2000` for documentation parity, do not wire it into DataTypes negotiation without also moving the associated Story 10.4 tests into scope. (Constant NOT added \u2014 deferred to Story 10.4 per Open Questions; comments instead point to 10.4.)

- [x] Add focused unit tests (AC: 1, 3, 5)
  - [x] Update `test/src/protocol/messages/fast_auth_message_test.dart` to assert DataTypes layout precisely: type byte, primary charset `ttcCharsetUtf8` little-endian, national field unchanged for this story, flags, and caps length.
  - [x] Add or update a classical DataTypes negotiation unit test around `Transport._sendDataTypesNegotiation` behavior. Extracted `@visibleForTesting Transport.encodeDataTypesMessage(...)` so the byte layout is testable without a socket; added field-layout, terminator, and FAST_AUTH/classical cross-path alignment tests in `transport_test.dart`.
  - [x] Add an AUTH_PHASE_TWO encoding assertion that the key-value payload contains `SESSION_CLIENT_CHARSET` with `ttcCharsetUtf8.toString()` (`auth_message_test.dart`).
  - [x] Update imports to use constants rather than repeating `873` in test expectations, except where a test deliberately verifies the raw byte value.

- [x] Add or extend integration coverage (AC: 6)
  - [x] Added `test/integration/charset_negotiation_integration_test.dart`.
  - [x] Use `connectForTest()`, `uniqueTableName()`, `cleanUpConnection()`, and other helpers from `test/integration/test_helper.dart`.
  - [x] Round-trip `ASCII`, accented Latin, and multi-byte UTF-8 (CJK and emoji, plus a mixed value) through a `VARCHAR2` column via the bind path on both standard fixtures.
  - [x] Do not make claims about a non-AL32UTF8 fixture here; Story 10.3 owns the first required non-AL32UTF8 database round-trip. (File doc comment states this.)

- [x] Validate full project invariants (AC: 3, 6)
  - [x] `dart analyze` reports zero issues.
  - [x] Focused unit tests for auth/data-types negotiation pass (full unit suite: 1310 pass / 12 skip).
  - [x] Charset integration test passes on Oracle 23ai (focused file + capability file: 10 pass).
  - [x] Charset integration test passes on Oracle 21c (focused file + capability file: 10 pass).
  - [x] Full integration suite passes on both supported environments before marking done (23ai: 401 pass / 8 skip; 21c: 402 pass / 7 skip).

### Review Findings

- [x] [Review][Patch] `capabilities.dart` `defaultCharset = 873` has no doc comment linking it to `ttcCharsetUtf8` — violates AC1 single-source-of-truth intent; add a doc comment aliasing or cross-referencing `ttcCharsetUtf8` [lib/src/protocol/capabilities.dart:25]
- [x] [Review][Patch] "Capabilities are trimmed" test offset off-by-one: `capsLengthIndex = dataTypesIndex + 5` points to the encoding-flags byte (value `0x03`), not the compile-caps length byte (`+6`); test passes coincidentally because `0x03 == 3` — violates AC5 [test/src/protocol/messages/fast_auth_message_test.dart:~357]
- [x] [Review][Defer] `encodeDataTypesMessage` caps length byte (`writeUint8(compileCaps.length)`) not guarded against overflow if caps > 255 bytes [lib/src/transport/transport.dart] — deferred, pre-existing
- [x] [Review][Defer] Classical DataTypes response parser potentially misaligned preamble skip vs FAST_AUTH path [lib/src/transport/transport.dart] — deferred, pre-existing
- [x] [Review][Defer] No unit test covering `encodeDataTypesMessage` with production-length caps (53+7 bytes) — deferred, future improvement
- [x] [Review][Defer] `_sendDataTypesNegotiation` `protoResponse` parameter passed but never used inside the method [lib/src/transport/transport.dart] — deferred, pre-existing

## Dev Notes

### Scope Boundary

Story 10.2 is not the non-AL32UTF8 fixture story and not the national charset implementation story. It makes the existing thin model explicit in code and tests: the client negotiates UTF-8/AL32UTF8 for primary character data and relies on Oracle server-side conversion. Story 10.3 proves this against at least one non-AL32UTF8 database. Story 10.4 implements AL16UTF16 national types and fail-loud unsupported national charset behavior.

### Architecture Guardrails

- Epic 10's architecture decision is explicit: keep primary wire character data as UTF-8 (`873`) and do not expose arbitrary Dart text encodings. [Source: `_bmad-output/planning-artifacts/architecture.md` "Core model decision - adopt node-oracledb thin charset model"]
- `OracleCharsetInfo.databaseCharset` is diagnostic, not a codec selector. It must not change `buffer.dart`, bind encoding, or result decoding for primary character data. [Source: `lib/src/oracle_charset_info.dart`; `_bmad-output/implementation-artifacts/10-1-charset-capability-detection.md`]
- FAST_AUTH vs classical auth path selection is server-driven through `Transport.supportsFastAuth`; do not parse version strings or NLS charset names to choose the auth path. [Source: `_bmad-output/project-context.md` "Auth path is server-driven"]
- Keep mixed-endian rules exact: DataTypes charset fields are little-endian `uint16`; most data type mapping entries are big-endian `uint16`. [Source: `_bmad-output/project-context.md` "Buffer Byte Order"]
- All new integration tests must run on both Oracle 23ai and Oracle 21c and must use `test/integration/test_helper.dart` for connection parameters. [Source: `_bmad-output/project-context.md` "Mandatory: Dual-Environment Validation"]

### Files To Read Before Editing

- `lib/src/protocol/constants.dart`
  - Current state: defines `ttcCsfrmImplicit`, `ttcCsfrmNChar`, and `ttcCharsetUtf8 = 873`.
  - What this story changes: likely comments only, plus optional helper constant documentation.
  - Must preserve: existing type codes and constants used by LOB, JSON, cursor, bind, and execute paths.

- `lib/src/protocol/messages/auth_message.dart`
  - Current state: AUTH_PHASE_TWO writes `SESSION_CLIENT_CHARSET` as the literal string `'873'`; crypto session key, speedy key, and password proof values are UTF-8 hex strings.
  - What this story changes: write `SESSION_CLIENT_CHARSET` from `ttcCharsetUtf8.toString()` and add/adjust tests.
  - Must preserve: no password logging, uppercase hex UTF-8 crypto fields, speedy-key verifier gating, `AUTH_ALTER_SESSION`, and FAST_AUTH-specific token behavior.

- `lib/src/protocol/messages/fast_auth_message.dart`
  - Current state: embedded DataTypes negotiation writes message type `ttcMsgTypeDataTypes`, then two little-endian `873` fields, encoding flags, trimmed compile/runtime caps, and data type mappings.
  - What this story changes: make the primary charset field constant-driven and test exact layout. National field behavior remains unchanged unless a deliberate scope decision moves Story 10.4 work into this story.
  - Must preserve: FAST_AUTH envelope shape, Protocol + DataTypes + AUTH_PHASE_ONE order, sequence number 1, capability trimming, and data type mapping order.

- `lib/src/transport/transport.dart`
  - Current state: classical `_sendDataTypesNegotiation()` writes the same two literal `873` fields after the DataTypes message type. `resetExecuteInstrumentation()` exists for Story 10.1 startup detection.
  - What this story changes: make classical DataTypes charset encoding constant-driven and testable.
  - Must preserve: server-driven `supportsFastAuth`, `ttcFieldVersion` adjustment, data flags, one-byte TTC sequence counter, and `_receiveAllTtcData()` completion behavior.

- `lib/src/protocol/buffer.dart`
  - Current state: `readString()` and `writeString()` use UTF-8 and throw normal UTF-8 decode errors when malformed unless callers decode manually with `allowMalformed`.
  - What this story changes: no behavior change expected.
  - Must preserve: explicit endian methods and no ambiguous byte-order helpers.

- `lib/src/protocol/messages/execute_message.dart`
  - Current state: primary string decode uses UTF-8; column-name and some value paths use `allowMalformed: true`; NCHAR/NCLOB are hard-rejected by `ttcCsfrmNChar`.
  - What this story changes: no result decode behavior unless tests expose an existing negotiation inconsistency.
  - Must preserve: VARCHAR2/CHAR/CLOB behavior, LOB materialization, JSON, REF CURSOR/nested cursor, implicit results, and field-version threading.

- `lib/src/oracle_charset_info.dart`
  - Current state: documents that primary text always travels as UTF-8 and server-converted, while `supportsNationalCharacterSet` concerns NCHAR/NVARCHAR2/NCLOB only.
  - What this story changes: likely no code change; keep docs consistent if comments elsewhere are updated.
  - Must preserve: Story 10.1 parsing/fail-loud behavior and public API shape.

- `test/src/protocol/messages/fast_auth_message_test.dart`
  - Current state: verifies a UTF-8 charset byte pair exists near the DataTypes message, but the assertion is search-based rather than exact-field based.
  - What this story changes: tighten layout assertions and use `ttcCharsetUtf8`.
  - Must preserve: existing FAST_AUTH envelope and capability trimming tests.

- `test/src/crypto/auth_test.dart`
  - Current state: has fake transport coverage for auth path selection and auth message behavior.
  - What this story changes: good location for asserting `SESSION_CLIENT_CHARSET` payload if no narrower auth-message test exists.
  - Must preserve: FAST_AUTH/classical branch tests and verifier behavior.

- `test/integration/charset_capability_integration_test.dart`
  - Current state: validates Story 10.1 charset detection, startup instrumentation cleanliness, and pool inheritance on both standard fixtures.
  - What this story changes: can be extended with a primary-text smoke test, or a sibling charset negotiation integration file can be added.
  - Must preserve: no hardcoded connection params and dual-env doc comment.

### Existing Code Facts

- `ttcCharsetUtf8 = 873` already exists, but negotiation writers still contain literals in `auth_message.dart`, `fast_auth_message.dart`, and `transport.dart`.
- `Capabilities.defaultCharset` is also `873`; do not create a competing constant unless a later refactor deliberately unifies the protocol capability layer.
- The bundled node-oracledb reference writes `SESSION_CLIENT_CHARSET` as `"873"` and its DataTypes message writes `TNS_CHARSET_UTF8` for the charset fields. [Source: `reference/node-oracledb/lib/thin/protocol/messages/auth.js`; `reference/node-oracledb/lib/thin/protocol/messages/dataType.js`]
- The bundled node-oracledb capability model separately has `TNS_CHARSET_UTF16 = 2000` and `checkNCharsetId()` for national charset support. Do not confuse this with the primary UTF-8 negotiation work in Story 10.2. [Source: `reference/node-oracledb/lib/thin/protocol/constants.js`; `reference/node-oracledb/lib/thin/protocol/capabilities.js`]

### Previous Story Intelligence

- Story 10.1 added `OracleCharsetInfo`, startup detection through `NLS_DATABASE_PARAMETERS`, and dual-env charset integration tests.
- Story 10.1 review fixed stack-trace preservation and credential-free detection errors. Do not add new error paths that lose causes or include credentials.
- Story 10.1 deliberately did not replace all `873` literals because some byte-exact tests depended on them. Story 10.2 is the right place to do that cleanup with stronger tests.
- Story 10.1 left a deferred note: `resetExecuteInstrumentation()` currently resets parse/reuse counters only. This story should not change startup detection to use LOB columns or add instrumentation that expands that reset boundary.

### Git Intelligence Summary

- `028ad1b feat(oracledb): implement character set detection for Oracle connections` is the direct predecessor and touched `connection.dart`, `oracle_charset_info.dart`, `transport.dart`, charset tests, and sprint artifacts.
- `ef91bf9 chore: bump version to 1.1.0` confirms the package is post-1.0; keep public changes additive and avoid changing existing return shapes.
- Recent cursor/implicit-result work modified connection and execute-message lifecycle paths. Charset negotiation changes must not disturb result-set ownership or in-flight operation guards.

### Latest Technical Information

- node-oracledb 7.0.0 docs, last updated June 2, 2026, state that Thin mode relies on the database server to perform database-character-set conversion and that node-oracledb uses AL32UTF8 for character data. Source checked 2026-06-23: https://node-oracledb.readthedocs.io/en/latest/user_guide/globalization.html
- The same docs state AL16UTF16 national character set is supported, while UTF8 national character set is not supported in Thin mode. Source checked 2026-06-23: https://node-oracledb.readthedocs.io/en/latest/user_guide/globalization.html
- node-oracledb Appendix A states client character set support is UTF-8 in Thin and Thick modes, and Thin mode ignores Oracle NLS environment variables. Source checked 2026-06-23: https://node-oracledb.readthedocs.io/en/latest/user_guide/appendix_a.html
- Oracle Database 26ai reference documents `NLS_DATABASE_PARAMETERS` as the permanent database NLS parameter view with `PARAMETER` and `VALUE` columns. Source checked 2026-06-23: https://docs.oracle.com/en/database/oracle/oracle-database/26/refrn/NLS_DATABASE_PARAMETERS.html

### Project Structure Notes

- Production code remains under `lib/src/`; no new public file is expected for this story.
- Unit tests should mirror touched areas under `test/src/`.
- Integration tests should remain under `test/integration/charset_*`.
- Use `package:oracledb/oracledb.dart` in integration tests; use `src/` imports only in focused unit tests where existing tests already do so.
- Keep imports ordered: `dart:`, `package:`, relative imports.

### Done Criteria Checklist

- [x] Integration tests written using `test_helper.dart` with no hardcoded connection params.
- [x] Tests pass: focused `charset_negotiation_integration_test.dart` + `charset_capability_integration_test.dart` on Oracle 23ai (10 pass).
- [x] Tests pass: same files on Oracle 21c via `ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1` (10 pass).
- [x] Full integration suite passes on both environments before story is marked done (23ai: 401/8, 21c: 402/7).
- [x] `dart analyze` reports zero issues.

### Open Questions

- Should the implementation extract a tiny internal DataTypes encoder helper to make the classical path byte-testable without a socket fake? This is recommended if testing `_sendDataTypesNegotiation()` directly is brittle.
- Should `ttcCharsetAl16Utf16 = 2000` be added now as documentation-only, or wait until Story 10.4 when it becomes behavior? Waiting reduces ambiguity.

## Dev Agent Record

### Agent Model Used

claude-opus-4-8[1m] (Opus 4.8, 1M context)

### Debug Log References

- 23ai container `oracle23ai` (desktop-linux context, port 1521) — Up, healthy.
- 21c container `dart-oracledb-oracle21c-1` (colima context, port 1522) — Up, healthy.
- Full unit suite: `dart test test/src/` → 1310 pass, 12 skip, 0 fail.
- Charset focused (23ai): 10 pass. Charset focused (21c): 10 pass.
- Full integration (23ai): 401 pass, 8 skip. Full integration (21c): 402 pass, 7 skip.
- `dart analyze` (whole project): No issues found.

### Completion Notes List

- Ultimate context engine analysis completed - comprehensive developer guide created.
- Made `ttcCharsetUtf8` the single source of truth for the primary client charset
  across all three negotiation writers: `AuthPhaseTwoRequest.toBytes()`
  (`SESSION_CLIENT_CHARSET` now `ttcCharsetUtf8.toString()`),
  `FastAuthRequest._encodeDataTypesMessageContent`, and the classical path.
- Extracted `@visibleForTesting Transport.encodeDataTypesMessage(compileCaps, runtimeCaps)`
  from `_sendDataTypesNegotiation` so the classical DataTypes byte layout is unit-testable
  without a live socket. The refactor is byte-identical (existing tests unchanged & green).
- The DataTypes message type byte stays the literal `2`: the named constant
  `ttcMsgTypeDataTypes` is ambiguous inside `transport.dart` (defined in both
  `constants.dart` and `protocol_message.dart`), matching the pre-existing code's choice.
- National charset scope kept fenced: `ttcCharsetAl16Utf16 = 2000` was deliberately NOT
  added (deferred to Story 10.4 per Open Questions); comments instead route national-type
  support to Story 10.4. The DataTypes "national charset slot" continues to advertise
  UTF-8 (`ttcCharsetUtf8`), byte-identical to before (matches node-oracledb dataType.js,
  which writes `TNS_CHARSET_UTF8` for both charset fields).
- Verified no behavior regression: `execute_message.dart` primary decode does not branch
  on `OracleCharsetInfo.databaseCharset`; NCHAR/NCLOB hard rejection intact; UTF-8
  `writeString`/`readString` and `allowMalformed` behavior unchanged; no new dependencies.
- New integration test round-trips ASCII, accented Latin, CJK, emoji, and a mixed value
  through a `VARCHAR2` column via the **bind path** (exercising the client UTF-8 encoder)
  on both AL32UTF8 fixtures, proving the thin server-conversion model end-to-end.

### File List

- `lib/src/protocol/constants.dart` (modified — expanded `ttcCharsetUtf8` doc comment to state the thin server-conversion model)
- `lib/src/protocol/messages/auth_message.dart` (modified — `SESSION_CLIENT_CHARSET` driven by `ttcCharsetUtf8.toString()`)
- `lib/src/protocol/messages/fast_auth_message.dart` (modified — DataTypes charset fields use `ttcCharsetUtf8`; clarified comments)
- `lib/src/transport/transport.dart` (modified — extracted `encodeDataTypesMessage`; constant-driven charset fields)
- `test/src/protocol/messages/auth_message_test.dart` (modified — added `SESSION_CLIENT_CHARSET=873` precise assertion)
- `test/src/protocol/messages/fast_auth_message_test.dart` (modified — replaced loose 873 search with exact field-layout assertion)
- `test/src/transport/transport_test.dart` (modified — added classical `encodeDataTypesMessage` layout, terminator, and cross-path alignment tests)
- `test/integration/charset_negotiation_integration_test.dart` (new — UTF-8 bind-path round-trip smoke tests, dual-env)

## Change Log

| Date | Change |
|------|--------|
| 2026-06-23 | Implemented Story 10.2: made `ttcCharsetUtf8` the single source of truth for the primary client charset across FAST_AUTH, classical DataTypes negotiation, and AUTH_PHASE_TWO `SESSION_CLIENT_CHARSET`; extracted `Transport.encodeDataTypesMessage` for byte-level testing; tightened FAST_AUTH/auth unit tests; added dual-env UTF-8 bind-path round-trip integration test. National charset work kept fenced for Story 10.4. Validated on Oracle 23ai and 21c. |
