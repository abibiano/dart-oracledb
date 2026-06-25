---
created: 2026-06-25
story_key: 10-4-national-charset-handling
baseline_commit: 7b527ee4c15b8cebd50374e36d9ab3e0a1e555d1
---

# Story 10.4: National Charset Handling

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart Oracle driver user,
I want NCHAR, NVARCHAR2, and NCLOB columns to round-trip correctly and unsupported national charset configurations to fail loud with a clear error,
so that national character set data works transparently on AL16UTF16 databases and silent mojibake is impossible on unsupported configurations.

## Acceptance Criteria

1. **National charset wire model follows node-oracledb parity**
   **Given** the driver initiates a connection (FAST_AUTH path and classical path)
   **When** it sends the Data Types message
   **Then** both the primary charset field and national charset slot carry `ttcCharsetUtf8 = 873`, matching the in-repo node-oracledb reference
   **And** national values are marked by `csfrm = ttcCsfrmNChar` and carried as UTF-16BE payloads
   **And** `ttcCharsetAl16Utf16 = 2000` is retained as the supported national charset id for capability checks and temp NCLOB creation, not written into the Data Types negotiation slots.

2. **UTF-16BE codec available in buffer.dart**
   **Given** the driver needs to encode or decode national-charset strings
   **When** `ReadBuffer.readNString(int byteLength)` is called
   **Then** it reads `byteLength` bytes from the buffer and returns a `String` decoded as big-endian UTF-16 code units (2 bytes per code unit)
   **And** `WriteBuffer.writeNString(String value)` encodes the string as UTF-16BE and writes the raw bytes (no length prefix, consistent with `writeString`)
   **And** BMP characters and supplementary-plane characters (surrogate pairs) round-trip correctly.

3. **NCHAR and NVARCHAR2 SELECT columns decode as UTF-16BE**
   **Given** a SELECT query returns columns whose `csfrm == ttcCsfrmNChar`
   **When** `_decodeValueByOraType` processes `oraTypeVarchar`, `oraTypeVarchar2`, `oraTypeChar`, or `oraTypeString` with `csfrm == ttcCsfrmNChar`
   **Then** the raw bytes are decoded as UTF-16BE (not UTF-8) and returned as a Dart `String`
   **And** `NULL` values (empty bytes) still return `null`.

4. **NCLOB SELECT columns decode correctly**
   **Given** a SELECT query returns a CLOB column with `csfrm == ttcCsfrmNChar` (NCLOB)
   **When** `_decodeValueByOraType` processes `oraTypeClob` with `csfrm == ttcCsfrmNChar`
   **Then** the hard-reject `OracleException` for NCLOB is removed
   **And** the locator is returned to the LOB read path exactly as for regular CLOB
   **And** the existing `LobLocator.usesVarLengthCharset` + `decodeUtf16Be` mechanism in `transport.dart` materializes the NCLOB value as UTF-16BE automatically (this path already exists; the only gate removed is the hard-reject in execute_message.dart).

5. **NCHAR/NVARCHAR2/NCLOB OUT and IN OUT bind declarations work**
   **Given** a PL/SQL block returns an NCHAR/NVARCHAR2 or NCLOB OUT bind
   **When** the caller uses `OracleDbType.nVarchar` or `OracleDbType.nClob` in `OracleBind.out`/`OracleBind.inOut`
   **Then** the bind metadata is written with `csfrm = ttcCsfrmNChar` and `charset = ttcCharsetUtf8`, matching node-oracledb `writeColumnMetadata`
   **And** the returned bytes are decoded as UTF-16BE for `nVarchar` or materialized via the NCLOB LOB path for `nClob`
   **And** `maxSize` is required for both, expressed in UTF-16 code units for `nVarchar` and in characters for `nClob` (consistent with the CLOB convention).

6. **Fail-loud for unsupported national charset — never silent corruption**
   **Given** a connection whose `charsetInfo.nationalCharset` is anything other than `AL16UTF16` (e.g., deprecated `UTF8`)
   **When** the driver encounters a column or OUT bind with `csfrm == ttcCsfrmNChar`
   **Then** it throws an `OracleException` with `errorCode: oraUnsupportedType` and a message identifying the unsupported national charset
   **And** it does NOT silently corrupt the data by decoding with the wrong codec.

7. **Primary charset path is unchanged and NCHAR/NVARCHAR2/NCLOB regression is detected**
   **Given** the existing standard Oracle 23ai and Oracle 21c fixtures (both use `AL16UTF16` national charset)
   **When** the focused NCHAR integration tests and full test suites run on both environments
   **Then** VARCHAR2/CHAR/CLOB (csfrm == ttcCsfrmImplicit) continue to use the UTF-8 path unchanged
   **And** the full integration suite baseline count does not regress.

8. **Dual-env integration tests pass on both Oracle 23ai and Oracle 21c**
   **Given** both Oracle 23ai (1521/FREEPDB1) and Oracle 21c (1522/XEPDB1) fixtures
   **When** the NCHAR/NVARCHAR2/NCLOB round-trip tests and full integration suite run
   **Then** all NCHAR-focused tests pass on both environments without skipping
   **And** both servers report `NLS_NCHAR_CHARACTERSET = AL16UTF16` (the `supportsNationalCharacterSet` check validates this at test setup).

## Tasks / Subtasks

- [x] Add `ttcCharsetAl16Utf16` constant and wire-up national charset negotiation (AC: 1) — **see Completion Note A: the wire-format premise of AC1 was incorrect**
  - [x] In `lib/src/protocol/constants.dart`, add `const int ttcCharsetAl16Utf16 = 2000;` immediately after `ttcCharsetUtf8`, with a doc comment referencing `OracleCharsetInfo.supportedNationalCharset` and `ttcCsfrmNChar`.
  - [x] ~~In `fast_auth_message.dart` L133: change the national charset slot to `ttcCharsetAl16Utf16`~~ — **REVERTED**: writing 2000 in the DataTypes national slot corrupts the FAST_AUTH handshake. node-oracledb (`dataType.js`) keeps UTF-8 in both slots; the slot stays `ttcCharsetUtf8`.
  - [x] ~~In `transport.dart`: change the national charset slot to `ttcCharsetAl16Utf16`~~ — **REVERTED** for the same reason; classical-path slot stays `ttcCharsetUtf8`.

- [x] Add `readNString` / `writeNString` to buffer.dart (AC: 2)
  - [x] In `lib/src/protocol/buffer.dart`, add `String readNString(int byteLength)` to `ReadBuffer`: reads `byteLength` bytes, decodes as big-endian UTF-16 code units via `String.fromCharCodes`. Zero length → empty string.
  - [x] Add `void writeNString(String value)` to `WriteBuffer`: each code unit as a 2-byte big-endian pair, no length prefix (mirrors `writeString`).
  - [x] Added a unit test block verifying round-trip of ASCII, accented Latin, CJK, supplementary-plane (emoji), mixed, byte layout, and partial reads.

- [x] Decode NCHAR/NVARCHAR2 columns as UTF-16BE (AC: 3, 6)
  - [x] Added `supportsNationalCharset = true` parameter to `_decodeValueByOraType`.
  - [x] In the `oraTypeVarchar`/`oraTypeVarchar2`/`oraTypeChar`/`oraTypeString` case: when `csfrm == ttcCsfrmNChar`, fail loud if `!supportsNationalCharset`, else decode UTF-16BE.
  - [x] Uses `ReadBuffer(bytes).readNString(bytes.length)` — separate from the utf8 path.

- [x] Enable NCLOB LOB path — remove hard-reject (AC: 4, 6)
  - [x] Replaced the NCLOB hard-reject with a `supportsNationalCharset` fail-loud check (throw if false, fall through if true). No new LOB read logic added here.
  - [x] Updated the `_isSupportedRefCursorColumn` CLOB branch (the `L1849` `csfrm != ttcCsfrmNChar` check) to allow NCLOB. Threaded the declared NCHAR form into `LobLocator.isNChar` so `_readClobAsString` reads it as UTF-16BE even when the locator omits the var-length flag bit (node-oracledb `getCsfrm()` parity).
  - [x] Integration test verifies an NCLOB column returns a `String`.

- [x] Add `OracleDbType.nVarchar` and `OracleDbType.nClob` enum values (AC: 5)
  - [x] Added `nVarchar` and `nClob` to `OracleDbType` with doc comments and `oracleTypeCode` mapping (nVarchar→`oraTypeVarchar`, nClob→`oraTypeClob`).
  - [x] `OracleBind._validate` now requires `maxSize` for `nVarchar` and `nClob`; value-type check accepts `String`/null.
  - [x] `_maxSizeFor`: `nClob` → `_lobLocatorBindBufferSize`; `nVarchar` → `maxSize! * 2` (or `value.codeUnits.length * 2`).
  - [x] `_wireTypeFor` handled via `oracleTypeCode`. `_csfrmFor` refactored to take `BindVariable` and return `ttcCsfrmNChar` for national binds.
  - [x] ~~charset field write `csfrm == ttcCsfrmNChar ? ttcCharsetAl16Utf16 : ...`~~ — **CORRECTED**: the charset field stays `ttcCharsetUtf8` for ALL non-zero csfrm (node-oracledb `writeColumnMetadata`); the `csfrm` byte (`2`) is the sole national marker.

- [x] Encode NCHAR/NVARCHAR2 IN bind values as UTF-16BE (AC: 5)
  - [x] `_writeBindValue` encodes national `oraTypeVarchar`/`oraTypeString` values as UTF-16BE via `writeNString`; `_maxSizeFor` doubles the declared/derived size for the 2-byte code units.

- [x] Thread `supportsNationalCharset` from connection into decode (AC: 6)
  - [x] Added a `supportsNationalCharset` field on `Transport`, set by the connection after `_detectCharsetInfo()` from `charsetInfo.supportsNationalCharacterSet`; threaded through every row/OUT-bind `decodeExecuteResponse` call into `_decodeValueByOraType`. `BindMetadata` carries `csfrm` for the OUT-bind decode.

- [x] Write dual-env NCHAR integration tests (AC: 3, 4, 5, 7, 8)
  - [x] Created `test/integration/nchar_integration_test.dart`, gated with `RUN_INTEGRATION_TESTS=true`.
  - [x] Asserts AL16UTF16 at setup; guards each test with a clear skip if a fixture were not AL16UTF16.
  - [x] Covers NVARCHAR2 SELECT (ASCII, accented, CJK, emoji, NULL) — the insert-then-fetch matrix is also the NVARCHAR2-column IN-bind round-trip; NCHAR fixed-width SELECT; NCLOB SELECT (small, multi-chunk >32 KB, multibyte, NULL, EMPTY_CLOB()); PL/SQL OUT and IN OUT for nVarchar and nClob.
  - [x] Uses `uniqueTableName()`, `nextTestId()`, `cleanUpConnection()`, and `test_helper.dart` env-driven helpers — no hardcoded params.
  - [x] All 20 tests pass on Oracle 23ai (1521/FREEPDB1) and Oracle 21c (1522/XEPDB1).

- [x] Validate and update docs (AC: 7, 8)
  - [x] `dart analyze` — zero issues (whole project).
  - [x] Full integration suite on Oracle 23ai: **421 passed / 28 skipped / 0 failed** (was ~401/28; +20 NCHAR tests, no regression).
  - [x] Full integration suite on Oracle 21c: **422 passed / 27 skipped / 0 failed** (was ~402/27; +20 NCHAR tests, no regression).
  - [x] Updated `oracle_charset_info.dart` `supportsNationalCharacterSet` doc to describe the implemented round-trip/fail-loud behavior.

### Review Findings

- [x] [Review][Decision] Literal charset-field ACs remain contradicted by the implementation — resolved by amending AC1/AC5 and implementation guidance to the in-repo node-oracledb reference model: DataTypes and bind/define charset fields stay `ttcCharsetUtf8`, `csfrm == ttcCsfrmNChar` is the national marker, values travel UTF-16BE, and `ttcCharsetAl16Utf16 = 2000` is used as the supported national charset id/capability and temp NCLOB `CREATE_TEMP` charset id.
- [x] [Review][Patch] Unsupported-national-charset errors do not identify the actual unsupported charset [lib/src/protocol/messages/execute_message.dart:1579]
- [x] [Review][Patch] NCHAR/NVARCHAR2/NCLOB input binds are not guarded on unsupported national charset connections [lib/src/connection.dart:1620]
- [x] [Review][Patch] Scalar UTF-16BE decode silently drops malformed odd trailing bytes [lib/src/protocol/buffer.dart:145]
- [x] [Review][Patch] NULL NCHAR/NVARCHAR2 values bypass the unsupported-national-charset guard [lib/src/protocol/messages/execute_message.dart:1573]
- [x] [Review][Patch] Public enum values were inserted before existing enum members, shifting existing `OracleDbType.index` values [lib/src/oracle_bind.dart:48]
- [x] [Review][Patch] Production CLOB length-mismatch error includes debug internals [lib/src/transport/transport.dart:1302]

## Dev Notes

### Scope Boundary

Story 10.4 is the **national charset** story. Its single job is to make NCHAR/NVARCHAR2/NCLOB work correctly on AL16UTF16 national charset databases and fail loud otherwise. Do not touch VARCHAR2/CHAR/CLOB primary charset paths (UTF-8, `ttcCharsetUtf8`). Do not add CI fixture changes, README support-matrix updates, or LONG/LONG RAW support — those belong to Story 10.5 or later.

### Architecture Guardrails

- **National wire model is node-oracledb parity:** FAST_AUTH and classical DataTypes messages write `ttcCharsetUtf8 = 873` in both charset slots. Bind/define metadata also writes `ttcCharsetUtf8` for any non-zero character form. `csfrm == ttcCsfrmNChar (2)` is the national marker, and the payload bytes travel UTF-16BE. `ttcCharsetAl16Utf16 = 2000` is the supported national charset id and is written only where node-oracledb writes `TNS_CHARSET_UTF16` (for example temp NCLOB `CREATE_TEMP`), not in DataTypes or column metadata. [Source: `reference/node-oracledb/lib/thin/protocol/messages/dataType.js`, `reference/node-oracledb/lib/thin/protocol/messages/withData.js`, `reference/node-oracledb/lib/thin/protocol/messages/lobOp.js`; see Completion Note A]
- **Route by csfrm**: `csfrm == ttcCsfrmNChar (2)` → UTF-16BE; otherwise UTF-8. Apply consistently on decode (SELECT response) and encode (bind wire). [Source: `_bmad-output/planning-artifacts/architecture.md` "National charset handling (NCHAR / NVARCHAR2 / NCLOB)"]
- **NCLOB LOB path already works via `usesVarLengthCharset`**: `transport.dart` `_createTempClob()` and `_readClobAsString()` already branch on `LobLocator.usesVarLengthCharset` to use UTF-16BE. The only gate to remove is the hard-reject in `execute_message.dart` `_decodeValueByOraType`. Do NOT add a separate UTF-16 decode in the transport; the existing flag-based path is the correct one. [Source: `lib/src/protocol/lob_locator.dart` `usesVarLengthCharset`, `lib/src/transport/transport.dart` `_createTempClob()`]
- **`LobLocator.usesVarLengthCharset` flag-3 bit is already documented** as "the locator uses a variable-length (NCHAR) character set" in `constants.dart` near `tnsLobLocFlags`. Oracle sets this bit in NCLOB locators so the UTF-16BE path is automatically taken for NCLOB materialization.
- **`decodeUtf16Be` / `encodeUtf16Be` exist on `LobLocator`** (used by NCLOB LOB reads/writes). Story 10.4 needs analogous functions in `buffer.dart` for non-LOB NCHAR/NVARCHAR2 decode/encode. Do **not** duplicate the logic from `LobLocator` — put the shared codec in `buffer.dart` and if useful, refactor `LobLocator` to call `buffer.dart` helpers too (but that refactor is optional; don't break CLOB/BLOB).
- **`isEligibleForFetch` at `execute_message.dart` L1849** currently excludes `csfrm == ttcCsfrmNChar` columns: `return col.csfrm != ttcCsfrmNChar;`. This must be updated to allow NCLOB (and NCHAR/NVARCHAR2 columns that aren't LOBs are always fetchable via the scalar path). Change to return `true` unconditionally, or explicitly allow `ttcCsfrmNChar` alongside `ttcCsfrmImplicit`.
- **Test must verify both environments have `AL16UTF16` national charset** before running NCHAR tests. Use `connection.charsetInfo.nationalCharset` (Story 10.1). All standard Oracle 23ai Free and Oracle 21c XE images use `AL16UTF16` national charset by default.

### Files To Read Before Editing

- `lib/src/protocol/constants.dart`
  - Current state: has `ttcCharsetUtf8 = 873`, `ttcCsfrmNChar = 2`, `ttcCsfrmImplicit = 1`. No `ttcCharsetAl16Utf16` yet.
  - What changes: add `ttcCharsetAl16Utf16 = 2000`.
  - Must preserve: `ttcCharsetUtf8` usage for primary charset (VARCHAR2/CHAR/CLOB).

- `lib/src/protocol/buffer.dart`
  - Current state: `readString(int length)` reads UTF-8; `writeString(String value)` writes UTF-8 bytes. No UTF-16 path.
  - What changes: add `readNString(int byteLength)` and `writeNString(String value)` for UTF-16BE.
  - Must preserve: existing UTF-8 `readString`/`writeString` behavior — add, do not modify.

- `lib/src/protocol/messages/fast_auth_message.dart`
  - Current state: L127–133 writes primary charset as `ttcCharsetUtf8` (correct) and national charset slot also as `ttcCharsetUtf8` (Story 10.4 placeholder). The comment says "(Story 10.4)".
  - What changes: keep L133 national charset slot as `ttcCharsetUtf8`, update comments/tests to document node-oracledb parity.
  - Must preserve: L132 primary charset stays `ttcCharsetUtf8`; L133 national charset slot also stays `ttcCharsetUtf8`. Server charset fields at L84–86 are `0` (correct, not changed).

- `lib/src/transport/transport.dart`
  - Current state: Classical path at L2186–2188 writes primary charset `ttcCharsetUtf8` and national charset slot `ttcCharsetUtf8` with the same "(Story 10.4)" comment.
  - What changes: keep L2188 national charset slot as `ttcCharsetUtf8`, update comments/tests to document node-oracledb parity.
  - Must preserve: L2187 primary charset and L2188 national charset slot stay `ttcCharsetUtf8`. NCLOB LOB read/write paths (`_readClobAsString`, `_createTempClob`) use declared NCHAR form and/or `LobLocator.usesVarLengthCharset`.

- `lib/src/protocol/messages/execute_message.dart`
  - Current state: `_csfrmFor(int oraType)` returns `ttcCsfrmImplicit` for varchar/string/clob, 0 otherwise. `_writeBindMetadata`/`_writeDefineMetadata` write `ttcCharsetUtf8` for non-zero csfrm. `_decodeValueByOraType` decodes varchar/char as UTF-8 (ignores `csfrm`). NCLOB hard-rejects at L1556–1563. `isEligibleForFetch` at L1849 excludes `csfrm == ttcCsfrmNChar`.
  - What changes: 5 changes listed in Tasks above.
  - Must preserve: UTF-8 decode for `csfrm == 0` and `csfrm == ttcCsfrmImplicit`. Existing LOB locator shape (locatorLen → lobLength → chunkSize → locator bytes) is unchanged. The probe path (`strict == false`) must consume bytes correctly for NCLOB too.

- `lib/src/oracle_bind.dart`
  - Current state: `OracleDbType` has number, varchar, date, timestamp, timestampTz, raw, clob, blob, json, cursor. `OracleBind._validate` requires `maxSize` for varchar/raw/clob/blob/json. `_maxSizeBytes` returns `_lobLocatorBindBufferSize` for clob/blob.
  - What changes: add `nVarchar` and `nClob` to enum; add validate/encode support.
  - Must preserve: all existing enum values and their behavior.

- `lib/src/oracle_charset_info.dart`
  - Current state: `supportsNationalCharacterSet` returns `nationalCharset == 'AL16UTF16'`. `supportedNationalCharset = 'AL16UTF16'`.
  - What changes: no production code change required. The doc comment at L78 says "Until Story 10.4 implements the supported AL16UTF16 national-type path, NCHAR/NCLOB remain hard-rejected even when this returns true" — update this comment.
  - Must preserve: the `fromParameterRows` logic, all detection behavior.

- `lib/src/protocol/lob_locator.dart`
  - Current state: has `usesVarLengthCharset` (flag-3 bit check), `decodeUtf16Be(List<int>)`, and `encodeUtf16Be(String)`.
  - What changes: no changes required — Story 10.4 adds parallel UTF-16 codec to `buffer.dart`. Optionally, refactor `decodeUtf16Be`/`encodeUtf16Be` to delegate to `ReadBuffer`/`WriteBuffer` helpers (nice to have; don't break CLOB tests).
  - Must preserve: CLOB/BLOB LOB read/write behavior, `usesVarLengthCharset` bit logic.

### Existing Code Facts

- The `_decodeValueByOraType` function signature already has `int csfrm = 0` parameter. It is called with `csfrm: col.csfrm` for column decode. No signature change needed for the csfrm part — just use it in the varchar/char branch.
- The `supportsNationalCharset` wiring: `OracleConnection._charsetInfo` is populated by `_detectCharsetInfo()` at connect time (Story 10.1). The transport's `sendExecute` is called on the transport object, not directly on the connection. The cleanest threading path: pass `connection.charsetInfo.supportsNationalCharacterSet` as a parameter into the transport's execute call, which threads it into `_decodeValueByOraType`. Alternatively, post-process: after `sendExecute` returns column metadata but before returning rows, check for NChar columns. Either approach is acceptable; pick the one that requires fewer cascading signature changes.
- `BindVariable` is the internal bind representation. `OracleDbType` is the public API enum. The bridge is `OracleBind._wireOraType()` or equivalent. When `_wireTypeFor(bind)` returns `oraTypeVarchar`, the `_csfrmFor` result determines if it's VARCHAR2 (implicit csfrm=1) or NVARCHAR2 (nchar csfrm=2). The current `_csfrmFor(int oraType)` signature can't distinguish the two — it needs access to the original bind type (either `BindVariable.oracleDbType` if added, or refactor to take `BindVariable`).
- **`_maxSizeFor` for nVarchar IN binds**: when the user doesn't specify `maxSize` and the value is a `String`, `maxSize` should be `value.length * 2` bytes (UTF-16BE is always 2 bytes per code unit for BMP; supplementary characters use two code units = 4 bytes). The simplest safe upper bound: `value.length * 2`.
- Story 10.1 confirmed that **both Oracle 23ai and Oracle 21c report `AL16UTF16`** as their national charset (`NLS_NCHAR_CHARACTERSET`). The `supportsNationalCharacterSet` check will be true for all standard integration test environments.
- `dart:convert` `utf8.encode/decode` are already used in the file. For UTF-16BE encode/decode, **do not use `dart:convert`'s `utf16` codec** — it doesn't exist in the standard library. Use manual byte manipulation: encode as `(codeUnit >> 8, codeUnit & 0xFF)` pairs; decode by reading pairs as `(bytes[i] << 8) | bytes[i+1]` and passing to `String.fromCharCodes`. This handles BMP correctly. For supplementary characters, Dart `String.codeUnits` already decomposes them into surrogate pairs, so `String.fromCharCodes(codeUnits)` where `codeUnits` is the list of 16-bit code units works correctly for all Unicode.
- `connection.charsetInfo.forTesting` connections (`OracleConnection.forTesting()`) have `_charsetInfo == null`. The `charsetInfo` getter throws. Thread `supportsNationalCharset` safely — assume `true` when charsetInfo is unavailable (for testing), since unit tests don't test national charset failure paths via the connection getter.

### Previous Story Intelligence

- Story 10.1 added `OracleCharsetInfo` with `nationalCharset`, `supportsNationalCharacterSet`, `supportedNationalCharset = 'AL16UTF16'`; confirmed both 23ai and 21c report AL16UTF16.
- Story 10.2 made the primary UTF-8 negotiation explicit; it deliberately left national charset negotiation as `ttcCharsetUtf8` placeholder for this story. Review left deferred items that do not affect Story 10.4.
- Story 10.3 confirmed the UTF-8 primary wire model works; it fenced NCHAR/NVARCHAR2/NCLOB out of scope and all 6 review patches are test-only (no production code). AC7 specifically says NCHAR/NCLOB implementation stays out of Story 10.3.
- **Key learning from Story 10.2 review**: charset field offsets are subtle — the AC5 review patch caught an off-by-one in the offset for compile caps length byte. Be careful when computing byte offsets in unit tests for the data types message.
- **Key learning from Story 10.3**: non-AL32UTF8 fixture provisioning was the hard part. Story 10.4 uses standard fixtures (23ai and 21c) so provisioning is trivial — but still need to assert `AL16UTF16` at test setup.

### Git Intelligence Summary

- `7b527ee test(integration): add tests for non-AL32UTF8 database charset round-trips` — Story 10.3; introduced `charset_non_al32utf8_integration_test.dart`, `connectForNonAl32Test()` in test_helper.dart, and the `non-al32utf8` compose profile. Story 10.4 tests go in a separate file and use standard fixtures.
- `20dcf7e feat(tests): implement client UTF-8 negotiation integration tests` — Story 10.2; introduced `charset_negotiation_integration_test.dart`. Story 10.4 tests go in `nchar_integration_test.dart`.
- `028ad1b feat(oracledb): implement character set detection for Oracle connections` — Story 10.1; introduced `oracle_charset_info.dart` and `_detectCharsetInfo()` in connection.dart.
- Pattern: each charset story gets its own integration test file. Name it `test/integration/nchar_integration_test.dart`.

### Latest Technical Information

- node-oracledb 6.x/7.x Thin mode sends NCHAR/NVARCHAR2 as UTF-16BE on the wire, but its DataTypes message writes `TNS_CHARSET_UTF8` in both charset slots and its column metadata writes `TNS_CHARSET_UTF8` for all non-zero character forms. `CSFRM_NCHAR` is the national marker, and `TNS_CHARSET_UTF16 = 2000` is used as the supported national charset id/capability and for temp NCLOB operations. UTF8 national charset (deprecated Oracle feature) is explicitly unsupported in Thin mode. Source: in-repo node-oracledb reference (`dataType.js`, `withData.js`, `lobOp.js`) and Completion Note A.
- Oracle AL16UTF16 is fixed 2-byte big-endian per BMP code unit (U+0000–U+FFFF). Supplementary characters (U+10000+) are encoded as two surrogate code units (each 2 bytes). Dart strings use UTF-16 code units internally, so `String.codeUnits` gives the correct list to encode, and `String.fromCharCodes(codeUnits)` reconstructs it correctly — **do not use runes** for this (runes give Unicode scalar values, not UTF-16 code units, and would fail for supplementary characters).
- Oracle NCHAR column `maxLength` in column metadata is in bytes (2× character count for AL16UTF16 BMP). When computing `_maxSizeFor(bind)` for NVARCHAR2 binds without explicit `maxSize`, `value.length * 2` bytes is the correct byte count for BMP strings; for supplementary-plane strings it's `value.codeUnits.length * 2`.

### Project Structure Notes

- New test file: `test/integration/nchar_integration_test.dart` — mirrors `charset_negotiation_integration_test.dart` in structure.
- All production changes are in existing files under `lib/src/`. No new source files needed.
- `lib/oracledb.dart` already exports `OracleBind, OracleDbType, OracleOutBinds` — the new enum values are automatically exported.
- The `OracleDbType.nVarchar` name matches the node-oracledb `DB_TYPE_NVARCHAR` naming convention for clarity. Use `nVarchar` (camelCase, no CAPS) per Dart enum conventions.

### Done Criteria Checklist

- [x] `ttcCharsetAl16Utf16 = 2000` constant added to `lib/src/protocol/constants.dart`.
- [x] `ReadBuffer.readNString(int byteLength)` and `WriteBuffer.writeNString(String value)` added to `lib/src/protocol/buffer.dart`.
- [x] ~~FAST_AUTH national charset slot changed to `ttcCharsetAl16Utf16`~~ — **deliberately kept `ttcCharsetUtf8`** (see Completion Note A; writing 2000 breaks the handshake).
- [x] ~~Classical path national charset slot changed to `ttcCharsetAl16Utf16`~~ — **deliberately kept `ttcCharsetUtf8`** (same reason).
- [x] NCHAR/NVARCHAR2 columns decode as UTF-16BE when `csfrm == ttcCsfrmNChar` in `_decodeValueByOraType`.
- [x] NCLOB hard-reject removed from `_decodeValueByOraType`; replaced with fail-loud for unsupported national charset.
- [x] Fetch eligibility (`_isSupportedRefCursorColumn` CLOB branch) updated to allow `csfrm == ttcCsfrmNChar` columns.
- [x] `OracleDbType.nVarchar` and `OracleDbType.nClob` added to `oracle_bind.dart`.
- [x] `_csfrmFor` refactored to `BindVariable` and emits `ttcCsfrmNChar`; charset field stays `ttcCharsetUtf8` (node-oracledb parity — the csfrm byte is the marker).
- [x] `supportsNationalCharset` guard threads into decode path for fail-loud behavior.
- [x] `test/integration/nchar_integration_test.dart` written with env-driven helpers, no hardcoded connection params.
- [x] NCHAR, NVARCHAR2 SELECT round-trip tests pass on Oracle 23ai.
- [x] NCHAR, NVARCHAR2 SELECT round-trip tests pass on Oracle 21c.
- [x] NCLOB SELECT round-trip tests pass on Oracle 23ai.
- [x] NCLOB SELECT round-trip tests pass on Oracle 21c.
- [x] PL/SQL OUT bind tests for `nVarchar` and `nClob` pass on both environments.
- [x] Full integration suite baseline does not regress on Oracle 23ai (421/28).
- [x] Full integration suite baseline does not regress on Oracle 21c (422/27).
- [x] `dart analyze` reports zero issues.

## Dev Agent Record

### Agent Model Used

claude-opus-4-8 (Opus 4.8, 1M context) — bmad-dev-story workflow

### Debug Log References

- Initial integration run on 23ai failed every test at connect time with
  `ORA-12547: Server session key (AUTH_SESSKEY) has an invalid length (16)`.
  Isolated via `git stash` (baseline CLOB suite passed 36/36), proving the
  regression was mine. Root-caused to writing `ttcCharsetAl16Utf16 (2000)` in
  the DataTypes national charset slot — see Completion Note A.
- Second integration run: NCLOB reads failed (`ORA-12547: CLOB read returned
  malformed UTF-8 data` for CJK; length mismatch `9 chars vs 18` for ASCII).
  Root-caused to `_readClobAsString` deciding UTF-16BE solely from the locator
  flag bit, which server-created NCLOB locators do not set — fixed by carrying
  the declared NCHAR form on `LobLocator.isNChar` (node-oracledb `getCsfrm()`
  parity), plus the symmetric CREATE_TEMP/WRITE encode fixes.

### Completion Notes List

**A. AC1 wire-format premise was incorrect — corrected to node-oracledb parity
(REQUIRES REVIEWER AWARENESS).** AC1 (and Dev Notes "Latest Technical
Information") asserted the DataTypes negotiation national charset field should
carry `ttcCharsetAl16Utf16 = 2000`. This is factually wrong: the in-repo
reference `reference/node-oracledb/lib/thin/protocol/messages/dataType.js`
writes `TNS_CHARSET_UTF8` in **both** charset slots, and `withData.js
writeColumnMetadata` writes `TNS_CHARSET_UTF8` in **every** character column's
charset field — including NCHAR (csfrm 2). The `csfrm` **byte** (1=implicit,
2=NCHAR) is the sole national marker; the value itself then travels UTF-16BE
(`buffer.js readStr` / `lobOp.js` use `swap16`). Empirically, writing 2000 in
the DataTypes national slot corrupts the FAST_AUTH handshake (server returns a
malformed AUTH_SESSKEY → ORA-12547), which is why all connectivity broke.
Resolution: the `ttcCharsetAl16Utf16` constant is added and documented, but the
DataTypes slots and per-column charset fields stay `ttcCharsetUtf8`; national
types are driven entirely by the csfrm byte + UTF-16BE codec + the
connect-time `supportsNationalCharacterSet` fail-loud guard (the analog of
node-oracledb's `checkNCharsetId`). The functional intent of AC1 (NCHAR/
NVARCHAR2/NCLOB round-trip as AL16UTF16, fail loud otherwise) is fully met and
validated on both DBs.

**B. NCLOB national-ness is carried on the locator, not inferred from bytes.**
`LobLocator.isNChar` is set from the column/bind `csfrm` at decode and from the
CREATE_TEMP csfrm; `_readClobAsString` and `_createTempClob` read/write UTF-16BE
when `isNChar || usesVarLengthCharset`. This mirrors `lob.js getCsfrm()` (an
NCLOB's declared NCHAR form is authoritative; the var-length flag is only a
fallback for plain CLOBs). `lob_op_message.dart` CREATE_TEMP now writes the
`AL16UTF16` charset id for NCHAR temp LOBs (was hardcoded UTF-8).

**C. Decode/encode summary.** csfrm-routed: `csfrm == ttcCsfrmNChar` →
UTF-16BE, else UTF-8, applied symmetrically on column decode, OUT-bind decode,
and IN/IN OUT bind encode. `supportsNationalCharset` threads transport→decode
and fails loud with `oraUnsupportedType` on an unsupported national charset.
`OracleDbType.nVarchar`/`nClob` added (maxSize in UTF-16 code units; nVarchar
buffer doubled to bytes). Primary VARCHAR2/CHAR/CLOB UTF-8 paths untouched.

**Validation:** `dart analyze` clean (whole project); unit 1338 passed / 12
skipped; NCHAR integration 20/20 on 23ai AND 21c; full integration 23ai 421/28,
21c 422/27 — zero failures, no regression.

### File List

Production:
- `lib/src/protocol/constants.dart` — added `ttcCharsetAl16Utf16 = 2000` (documented as not written on the wire); clarified `ttcCharsetUtf8` doc.
- `lib/src/protocol/buffer.dart` — added `ReadBuffer.readNString` / `WriteBuffer.writeNString` (UTF-16BE codec).
- `lib/src/protocol/lob_locator.dart` — added `LobLocator.isNChar`.
- `lib/src/protocol/messages/execute_message.dart` — UTF-16BE NCHAR/NVARCHAR2 column + OUT-bind decode; NCLOB hard-reject → fail-loud; `_csfrmFor(BindVariable)` + `BindVariable.isNChar`; `_charsetFieldFor` (UTF-8, node-oracledb parity); `_maxSizeFor` nVarchar ×2; `_writeBindValue` UTF-16BE; `BindMetadata.csfrm`; `LobLocator.isNChar` set at decode; `supportsNationalCharset` threaded through `decodeExecuteResponse`/`_DecodeState`/`_decodeColumnValue`; NCLOB fetch eligibility.
- `lib/src/protocol/messages/lob_op_message.dart` — CREATE_TEMP charset id = AL16UTF16 for NCHAR temp LOBs.
- `lib/src/protocol/messages/fast_auth_message.dart` — national charset slot comment (stays UTF-8).
- `lib/src/transport/transport.dart` — `supportsNationalCharset` field threaded to all row-decoding `decodeExecuteResponse` calls; `_readClobAsString` / `_createTempClob` UTF-16BE via `isNChar`; `_prepareLobBinds` routes nClob to a temp NCLOB; classical DataTypes slot comment (stays UTF-8).
- `lib/src/oracle_bind.dart` — `OracleDbType.nVarchar` / `nClob`; validate + `oracleTypeCode` + `maxSize` doc.
- `lib/src/connection.dart` — set `_transport.supportsNationalCharset` after charset detection; carry `isNChar`/`csfrm` into `BindVariable`/`BindMetadata`.
- `lib/src/oracle_charset_info.dart` — updated `supportsNationalCharacterSet` doc.

Tests:
- `test/integration/nchar_integration_test.dart` — NEW dual-env NCHAR/NVARCHAR2/NCLOB suite (20 tests).
- `test/src/protocol/buffer_test.dart` — UTF-16BE codec round-trip group.
- `test/src/oracle_bind_test.dart` — nVarchar/nClob validation group.
- `test/src/protocol/messages/execute_message_test.dart` — NVARCHAR2 bind-encode group; NCHAR/NVARCHAR2 column-decode group; NCLOB decode test (locator when supported / fail-loud when unsupported).
- `test/src/transport/transport_test.dart` — national charset slot stays UTF-8 assertions.
- `test/src/protocol/messages/fast_auth_message_test.dart` — national charset slot stays UTF-8 assertion.

### Change Log

| Date       | Change |
|------------|--------|
| 2026-06-25 | Implemented national charset (NCHAR/NVARCHAR2/NCLOB) support: UTF-16BE codec, csfrm-routed decode/encode, `OracleDbType.nVarchar`/`nClob`, NCLOB LOB path, connect-time fail-loud guard. Corrected AC1's wire-format premise to node-oracledb parity (DataTypes/column charset slots stay UTF-8; csfrm byte is the national marker) — see Completion Note A. Status → review. |
| 2026-06-25 | Code review complete: amended AC1/AC5 to the in-repo node-oracledb reference model; patched unsupported-national-charset diagnostics and bind guard, strict odd-byte UTF-16BE decode, NULL national unsupported guard, public enum index compatibility, and debug error text cleanup. `dart analyze` clean; focused unit suite 417/0. Status → done. |
