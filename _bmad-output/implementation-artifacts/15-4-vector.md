---
title: 'Story 15.4: VECTOR (Oracle 23ai)'
type: 'feature'
created: '2026-10-15'
status: 'done'
baseline_revision: '5fb75ccf423c5646adf6795103a42875e5d4ce5b'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/CLAUDE.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-15-context.md'
warnings: [oversized]
deferred:
  - summary: >-
      A single execute() cannot declare an IN bind's type, so a dense BINARY vector (Uint8List, which infers RAW) or a declared List<double> cannot be bound in plain SQL.
    evidence: |-
      OracleBind has only out/inOut (rejected outside PL/SQL and RETURNING targets) and executeMany bindDefs are rejected for non-RETURNING DML. Live 23ai: a RAW bind into VECTOR(16, BINARY) fails ORA-00932. Workarounds documented: PL/SQL OracleBind.inOut, executeMany bindDefs (PL/SQL or DML RETURNING), TO_VECTOR text. A plain List<double> works via the server's JSON-to-VECTOR conversion.
    location: >-
      lib/src/oracle_bind.dart (OracleBind constructors), lib/src/connection.dart (bind preparation)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Oracle 23ai `VECTOR` columns (wire type 127) hit the `default:` branch of `_decodeValueByOraType`, which consumes the bytes and silently returns `null`; there is no way to bind a vector either. Schemas using AI vector search return wrong data with no error.

**Approach:** Mirror node-oracledb thin: decode VECTOR columns (dense FLOAT32/FLOAT64/INT8/BINARY and sparse) to Dart typed lists / an `OracleSparseVector`, add `OracleDbType.vector` and typed-list bind inference, using the same LOB-prefetch-style define/bind shape the JSON type already uses (QLocator + length-prefixed image).

## Boundaries & Constraints

**Always:** Wire parity with node (`reference/node-oracledb/lib/{impl/datahandlers/vector.js,thin/protocol/packet.js:473-490,683-715,thin/protocol/messages/{withData.js,base.js}}`): constant `oraTypeVector = 127`, `tnsVectorMaxLength = 1048576`, vector header consts (magic byte, versions, flags NORM/NORMSRC/SPARSE, formats FLEX/FLOAT32/FLOAT64/INT8/BINARY) copied from node `constants.js`. Fetch: UB4 length (0 => NULL), skip UB8 size, skip UB4 chunk size, length-prefixed image bytes, then chunked-skip the locator; decode image: magic, version (> sparse version => `OracleException`), flags, format, UB32 element count, skip 8 NORM bytes when BINARY or NORM flag, sparse indices, element data (verify declared size against remaining bytes before allocating; BINARY dims must be a multiple of 8). Decoder fails loud (`OracleException`, `oraProtocolError` / unsupported-format) on a bad magic byte, unsupported version/format, or truncated data; probe pass (`!strict`) only consumes bytes. Bind: 40-byte QLocator then length-prefixed image, header as node `_updateVectorHeader` (Float32List => FLOAT32, Float64List / `List<double>` declared as vector => FLOAT64, Int8List => INT8, Uint8List (declared vector only) => BINARY with dims = bytes*8, `OracleSparseVector` => sparse version). Define/bind buffers use `tnsVectorMaxLength` with the LOB-prefetch flag, as node does for DB_TYPE_VECTOR; a VECTOR column needs the DEFINE round like JSON/CLOB (reuse the 13.x/12.x machinery, extend `requiresDefine` handling where JSON is special-cased). Column metadata dimensions/format/sparse flag are read only under the existing field-version >= 24 gate (do not add another gate; expose them on column metadata if a natural field exists). Dart representation (settled here): `Float32List`/`Float64List`/`Int8List`/`Uint8List` (BINARY; element = packed byte) as returned by format, `OracleSparseVector` (`numDimensions`, `Uint32List indices`, typed `values`) in a new `lib/src/oracle_vector.dart`, exported. Bind inference: `Float32List`, `Float64List`, `Int8List`, `OracleSparseVector` infer VECTOR; plain `List<double>` keeps inferring JSON and `Uint8List` keeps inferring RAW unless the bind is declared `OracleDbType.vector`. `fetchTypeHandler` receives the typed list / sparse object; `fetchAsString` must not claim vectors (document the decision: reject or inert, matching how JSON is treated). Embedded paths (REF CURSOR, nested cursor, implicit result, executeMany, DML RETURNING, PL/SQL OUT) decode like top level where the server allows; `_isSupportedRefCursorColumn` accepts VECTOR if live-verified, otherwise fails loud with a clear message. Verify every wire assumption live on 23ai. VECTOR requires 23ai: on 21c the integration suite must be explicitly gated (skip with a logged reason, not silent) and on 21c a real `VECTOR` DDL fails with ORA-00902 which a gated test may assert. `dart analyze --fatal-infos` and `dart format` clean; counts recorded in the Dev Agent Record for BOTH 23ai (1521/FREEPDB1) and 21c (1522/XEPDB1), running the full integration suite on both.

**Never:** Do not flip the `default:` catch-all to fail-loud (that is a later story). No OSON/JSON changes (VECTOR inside JSON stays out of scope). Do not touch `sprint-status.yaml`. No VECTOR_DISTANCE/ANN SQL helpers. No thick-mode work. Do not break existing JSON/RAW/LIST inference.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fetch dense | `VECTOR(3, FLOAT32/FLOAT64/INT8)` column | `Float32List` / `Float64List` / `Int8List` with exact values, stream stays in sync | No error |
| Fetch flexible | `VECTOR(*, *)` column | typed list per stored format | No error |
| Fetch binary | `VECTOR(16, BINARY)` | `Uint8List` of 2 packed bytes | No error |
| Fetch sparse | `VECTOR(8, FLOAT32, SPARSE)` | `OracleSparseVector` equal to inserted | No error |
| NULL | NULL vector | `null`, following column correct | No error |
| Bind IN | typed list / sparse / declared vector with `List<double>` | stored, re-fetched equal; `VECTOR_DISTANCE` query works | No error |
| OUT | `RETURNING vec INTO :v`, PL/SQL OUT | same value as fetched | No error |
| Embedded | REF CURSOR / nested cursor / implicit result / executeMany | same value as top level | per live finding |
| Malformed | bad magic / version / format / truncated image | n/a | `OracleException` |
| 21c | VECTOR tests | explicitly skipped with reason | n/a |
| Hooks | `fetchTypeHandler` | converter receives the typed list | per 14.4 |

</intent-contract>

## Code Map

Follow the 15.1-15.3 touchpoints (`git show 5fb75cc f1760c0 3412579 -- lib`) and the JSON (13.x) LOB-prefetch define/bind handling:

- `lib/src/protocol/constants.dart` (~L139, L260) -- add `oraTypeVector = 127`, `tnsVectorMaxLength`, vector header consts.
- `lib/src/protocol/data_types.dart` (~L1238 `inferOraTypeForValue`) -- vector image encode/decode, `readVector`-style fetch helper; inference per Boundaries.
- `lib/src/protocol/messages/execute_message.dart` -- JSON special-cases at ~L73, 617, 656-666, 698-708, 723, 767, 970-974, 1286, 2476, 2745 are the model for the VECTOR define/bind/decode cases; `_isSupportedRefCursorColumn`; 23.4 column-info vector fields ~L1996 (already gated, read-only unless exposing metadata).
- `lib/src/oracle_bind.dart` (~L582) -- `OracleDbType.vector` appended at END of enum, value check, `oracleTypeCodeFor` -> 127.
- `lib/src/connection.dart` (~L967, 2941, 4844) -- `requiresDefine` JSON exceptions, `executeMany` checks, `fetchAsString`/handler docs.
- `lib/src/oracle_vector.dart` (new) + library export file -- `OracleSparseVector`.
- `lib/src/transport/transport.dart` (~L4481 data-type table already lists 127; caps 52/44 already advertise vector support) -- read-only.
- `README.md`, `doc/api-reference.md`, `CHANGELOG.md` -- support matrix, "VECTOR support" section, drop VECTOR from roadmap/"Not covered".
- Tests to mirror: `test/src/protocol/{constants,data_types}_test.dart`, `messages/execute_message_test.dart`, `oracle_bind_test.dart`, `connection_execute_many_test.dart`, `fetch_as_string_test.dart`, `test/integration/extended_types_rowid_integration_test.dart`.

## Tasks & Acceptance

**Execution:**
- `lib/src/protocol/constants.dart`, `lib/src/protocol/data_types.dart`, `lib/src/oracle_vector.dart` -- constants, vector codec, sparse wrapper -- node wire parity
- `lib/src/protocol/messages/execute_message.dart`, `lib/src/oracle_bind.dart`, `lib/src/connection.dart` -- decode/define/bind wiring, `OracleDbType.vector`, inference -- fetch + bind end to end
- `test/src/**` -- unit tests: node-derived image vectors (each format, sparse, binary, NORM present/absent), malformed images, constants, decode with row sync and probe, bind metadata/QLocator bytes, inference rules, executeMany slots, fetchAsString/handler
- `test/integration/extended_types_vector_integration_test.dart` -- live fetch of each format, flexible, sparse, NULL, round trip via bind, `VECTOR_DISTANCE`, RETURNING/OUT, embedded cursors, multi-round fetch with a following column, `fetchTypeHandler`; 23ai-only with explicit logged skip on 21c; uses `test_helper.dart`
- `README.md`, `doc/api-reference.md`, `CHANGELOG.md` -- docs

**Acceptance Criteria:**
- Given a VECTOR column of any supported format, when queried on 23ai, then it decodes to the matching Dart value, NULL is `null`, and the stream stays in sync (a following column and query are correct).
- Given a Dart typed list or `OracleSparseVector`, when bound on 23ai, then the stored value round-trips equal and `VECTOR_DISTANCE` accepts it.
- Given Oracle 21c, when the integration suite runs, then VECTOR tests are skipped with a logged reason and every other test still passes.
- Given the unit suite, `dart analyze --fatal-infos`, `dart format`, then all pass, and the full integration suite passes on 23ai and 21c with counts recorded.

## Spec Change Log

## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 18 findings — high 0, medium 0, low 17, false 1, maybe-false 0 (findings from different layers that share a claim are merged into one row)
- findings:
  - `[false]` `reject` VECTOR row stream shears on a STANDARD `MAX_STRING_SIZE` server (blind, edge) — the live 23ai Free image reports `max_string_size = STANDARD` and every VECTOR fetch test passes there, so no null-indicator/return-code trailer follows a VECTOR value.
  - `[low]` `reject` Duplicate-column VECTOR rows alias one mutable typed list (blind, edge) — the shared `priorRow[i]` copy is the pre-existing duplicate-column behavior for every mutable value (RAW included); the fix adds a special case.
  - `[low]` `patch` README/Supported-types say all typed lists bind as vectors (blind) — narrowed to the four inferred types with the Uint8List caveat.
  - `[low]` `patch` VECTOR_DISTANCE needs matching formats / ORA-51812 undocumented (blind) — README server-checks bullet and example updated.
  - `[low]` `reject` Sparse indices "ascending" not enforced client-side (blind) — the server rejects with ORA-51822; a guard adds surface.
  - `[low]` `patch` "SparseVector parity" claim overstated (blind) — api-reference wording now describes a plain value type.
  - `[low]` `reject` Vector column metadata not exposed (blind, intent-alignment) — the spec says expose only if a natural field exists; none does.
  - `[low]` `reject` Sparse BINARY value bytes only verified against own encoding (blind) — live-verified against the server's stored form per the Dev Agent Record; extra tests need a server-side sparse BINARY constructor.
  - `[low]` `reject` Oversized (>1 MB) vector bind fails after transport work and loses the drained temp-LOB list (blind, edge, verification-gap) — unreachable for valid vectors (65535 dims x 8 bytes < 1 MB); a call-site size guard across execute/executeMany/OracleBind is new complexity for invalid input.
  - `[low]` `patch` executeMany no-leak assertion could silently not run (blind) — now `expectLater(throwsA(...))`.
  - `[low]` `reject` Cached-statement test does not assert cursor reuse (blind) — it asserts correct values across re-executions, the user-visible behavior.
  - `[low]` `patch` CHANGELOG bindDefs qualifier and README nested-cursor bullet inconsistencies (blind) — fixed.
  - `[low]` `patch` Typed-list JSON-to-VECTOR behavior change has no migration note (blind, edge, intent-alignment) — README/CHANGELOG now give the `List<double>.of(v)` workaround; the inference change itself is the spec's decision.
  - `[low]` `reject` Integration suite hard-codes TABLESPACE USERS (blind) — the CI/dev 23ai image has it; a fallback adds setup complexity.
  - `[low]` `reject` Missing streaming/chunked-OUT/sparse INT8-FLOAT64 byte-image coverage (blind) — shared decode path; chunked and sparse formats are covered live.
  - `[low]` `reject` OracleSparseVector hashCode recomputed / toString unbounded (blind) — no named harm.
  - `[low]` `reject` Typed lists inferred as vector break pre-23.4 JSON binds (edge) — same as the behavior-change row; the spec decides inference.
  - `[low]` `reject` No fetchTypeHandler VECTOR unit test (edge) — covered by the live 23ai test and the shared handler path.
  - intent-alignment layer: descriptive only; noted deliberate deviations from node (no Uint8List inference, no declared IN type in single execute, fetchAsString rejects, no metadata), all documented, and one deferred item (dense BINARY IN bind in plain SQL).

### 2026-10-15 — Follow-up review pass
- verdicts: 14 findings — high 0, medium 1, low 11, false 2, maybe-false 0
- findings:
  - `[low]` `patch` README JSON migration example does not type-check for Int8List — removed `List<double>.of(v)`; `v.toList()` works for all three inferred typed lists.
  - `[low]` `patch` API reference calls all typed lists inferred VECTOR binds — named Float32List, Float64List, and Int8List explicitly; Uint8List remains RAW.
  - `[false]` `reject` sprint-status.yaml says done while the follow-up review says in-review — the orchestrator owns that row and its status is bookkeeping, not a verification claim; it must not be edited here.
  - `[low]` `reject` VECTOR locator marker and advertised size are not checked — the decoder does consume the wrapper and image, while the server produces a valid wrapper; extra validation of malformed server bytes adds branches without an everyday user outcome.
  - `[low]` `patch` sparse decoder accepts duplicate or descending wire indices — added a strictly ascending check before creating OracleSparseVector, with malformed-image tests.
  - `[low]` `reject` dense zero-dimension image decodes empty — Oracle rejects empty vectors before storing them (ORA-51862); rejecting impossible live output adds complexity.
  - `[low]` `reject` decoder does not validate version/format/sparse-flag combinations — the supported server versions produce the combinations covered by live tests; no reachable bad outcome was shown.
  - `[low]` `reject` no VECTOR queryStream/executeStream case — both routes use the same row decoder as the tested multi-round eager/resultSet reads; another test adds cost without a distinct changed branch.
  - `[low]` `reject` live tests do not assert every documented server error — those errors are server validation, while the driver path is covered by the dimension-mismatch and connection-usability test.
  - `[low]` `reject` oversized plain list is copied before size validation — valid Oracle vectors are far below the 1 MB buffer; optimizing invalid oversized input adds complexity.
  - `[low]` `patch` sparse decoder can return a wrapper with out-of-order indices (edge-case layer, same root cause as the sparse finding above) — the ascending check now rejects duplicate and descending indices.
  - `[medium]` `patch` repeated VECTOR-returning SELECT did not exercise the cached-query reparse path (verification-gap layer) — the integration cache test now executes and checks the same SELECT twice.
  - `[false]` `reject` vector dimension/format/sparse metadata is not public — the intent contract makes exposure conditional on a natural ColumnMetadata field; none exists, and the current public type code remains exposed.
  - `[low]` `reject` plain execute cannot declare a dense BINARY IN bind — this is the known API limitation already documented and deferred in this spec; the follow-up review does not introduce a new defect.

## Design Notes

Typed lists are chosen over a single wrapper because node returns typed arrays per format and Dart typed lists are `List<double>`/`List<int>`, so the epic's "`List<double>` or wrapper" decision stays assignable. Plain `List<double>` must keep inferring JSON for backward compatibility, so a plain list needs an explicit `OracleDbType.vector`; `Uint8List` likewise needs it to mean BINARY rather than RAW.

## Verification

**Commands:**
- `dart analyze --fatal-infos` -- expected: No issues found
- `dart format --output=none --set-exit-if-changed lib test example` -- expected: exit 0
- `dart test test/src` -- expected: exit 0
- `RUN_INTEGRATION_TESTS=true dart test test/integration/ --reporter compact --no-color` -- expected: exit 0 on 23ai
- `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --reporter compact --no-color` -- expected: exit 0 on 21c

## Dev Agent Record

### Implementation

- `lib/src/protocol/constants.dart`: `oraTypeVector = 127`, `tnsVectorMaxLength = 1048576`, image header constants copied from node `constants.js` / `impl/datahandlers/constants.js` (magic `0xDB`, versions 0/1/2, flags NORMSRC `0x10` / NORM `0x02` / SPARSE `0x20`, formats FLEX 0 / FLOAT32 2 / FLOAT64 3 / INT8 4 / BINARY 5).
- `lib/src/oracle_vector.dart` (new; `OracleSparseVector` exported from `lib/oracledb.dart`): `numDimensions`, `Uint32List indices`, `List<num> values` (always a typed list whose type is the format; a plain number list becomes `Float64List`), unmodifiable defensive copies, shape validation (`ArgumentError`, no values echoed), `==` / `hashCode` (format-aware), `toString`. Package-internal: `isInferredVectorValue`, `isVectorBindValue`, `sparseVectorFromWire`, `vectorFormatOfValues`, `maxSparseVectorElements`.
- `lib/src/protocol/data_types.dart`: `decodeVector` (node `VectorDecoder.decode`: magic, version > 2 → `oraUnsupportedType`, flags, format (unknown → `oraUnsupportedType`), UB32 count, 8 norm bytes skipped for NORM or BINARY, sparse UInt16 count + UInt32 indices, every declared size checked against the remaining bytes before allocating, BINARY dims % 8, sparse index < dims; all other failures `oraProtocolError`), `encodeVector` (node `_updateVectorHeader` / `encode`, byte-for-byte; 1 MB image guard), byte-comparable FLOAT32/FLOAT64 helpers; `inferOraTypeForValue` maps `Float32List` / `Float64List` / `Int8List` / `OracleSparseVector` to 127 ahead of the RAW / JSON checks.
- `lib/src/protocol/messages/execute_message.dart`: bind/define metadata via shared `_lobPrefetchContFlag` / `_lobPrefetchLength` (VECTOR: cont-flag `0x2000000`, buffer and prefetch length 1 MB), `_maxSizeFor` / `_defineBufferSize` → 1 MB, VECTOR excluded from the long-data deferral like JSON, `_writeBindValue` VECTOR case (QLocator + image; NULL keeps the `0x00` indicator), QLocator writer extracted from the OSON path and shared, `_decodeValueByOraType` VECTOR case (node `readVector`; probe pass only consumes), `ColumnMetadata.requiresDefine` includes VECTOR, `_isSupportedRefCursorColumn` accepts VECTOR (live-verified), `BindVariable` unsupported-type message lists the vector types. The `default:` catch-all is unchanged; the 23.4 column-info vector fields are still skipped under the existing `>= 24` gate.
- `lib/src/oracle_bind.dart`: `OracleDbType.vector` appended at the END (index 16), IN OUT value check (`isVectorBindValue`), `oracleTypeCodeFor` → 127; no `maxSize` required.
- `lib/src/connection.dart`: `_cursorCarriesLob` excludes VECTOR (like JSON), `executeMany()` `OracleBindDef` vector check, inferred-slot unsupported-type message, `fetchAsString` / `fetchTypeHandler` / define-related docs.
- Docs: README (feature bullet, PL/SQL bind paragraph, fetchAsString and converter notes, supported-types row, new "VECTOR support" section, roadmap row 3 removed, Known Limitations re-parse / fetchAsString bullets), `doc/api-reference.md` (public surface row, fetchAsString note, converter list, `OracleDbType.vector` row, `OracleSparseVector` section), CHANGELOG Unreleased (feature, behavior change, limits).

### Live wire findings (23ai; node-oracledb reference capture via `net.Socket` hooks plus a temporary Dart probe, both deleted)

- Describe: every VECTOR column is type 127 with maxSize 8200 (also `VECTOR(9000, FLOAT32)` and `VECTOR(*, *)`), size 0, csfrm 0. 8200 < `maxStringSize` 32767, so no null-indicator / return-code trailer follows a fetched value (node reads one only when maxSize > maxStringSize).
- The first execute of a VECTOR query returns the describe and no rows; node then sends a DEFINE whose VECTOR block is `7f 01 00 00 | UB4 1048576 | 00 | UB4 0x2000000 | 00 00 00 00 | UB4 1048576 | 00` — the driver's define bytes are identical.
- Fetch shape: UB4 40, UB8 image length, UB4 chunk size (32600 / 8060), the image (short, or `0xFE`-chunked for a 36 KB image), then the 40-byte locator. NULL = UB4 0. Server images carry a computed norm (flags `0x12`); a flexible column filled from text sets flags `0x16` (unknown bit `0x04`, ignored by node and the driver); BINARY reserves the norm space (`80 00 ...`).
- IN bind (node capture, reproduced byte-for-byte by the unit tests): metadata as the define above; ROW_DATA = UB4 40, 40, the value-based QLocator with the image length, the image with a zero norm. A NULL vector is the single `00` indicator. OUT binds and DML RETURNING ship the fetch shape plus the SB4 trailer; the RETURNING image arrived chunked even when short.
- Sparse BINARY: the server stores one value byte per listed index (`... 0002 00000000 00000009 01 01`); node-oracledb fails to decode it (NJS-113, its `% 8` check runs on the non-zero count) and python-oracledb 26 returns empty values.
- Server checks: ORA-51803 dimension mismatch (also a zero-element sparse value), ORA-51805 NaN / ±Infinity, ORA-51822 non-ascending or duplicate sparse indices, ORA-51862 empty vector, ORA-51812 `VECTOR_DISTANCE` over mixed formats, ORA-43853 VECTOR in the `SYSTEM` tablespace. A JSON array bind into a VECTOR column is converted by the server; a RAW bind into `VECTOR(16, BINARY)` fails ORA-00932.
- 21c: `CREATE TABLE ... (v VECTOR)` → ORA-00902 (`VECTOR(3, FLOAT32)` → ORA-00907); any vector bind → ORA-03115 and the connection stays usable.
- REF CURSOR OUT binds, nested `CURSOR()` columns and implicit results with VECTOR columns (NULL rows included) decode through their DEFINE round.

### Decisions and deviations

- Dart representation as settled by the spec: typed list per format, `OracleSparseVector` for sparse. `fetchAsString` rejects `vector` (`ArgumentError`), exactly as `json` — node's string fetch is a server-side LONG define this client-side hook cannot reproduce.
- Column metadata: `ColumnMetadata` has no natural field for dimensions / format / sparse flag, so they are not exposed (still skipped under the existing gate).
- A declared vector accepts any `List` whose elements are all `num` (sent FLOAT64, node's plain-array handling), not only `List<double>`.
- Deviation from node: sparse BINARY decodes (one byte per index) instead of failing; `OracleSparseVector` requires one value per index for BINARY too (node exempts `Uint8Array`). The decoder additionally rejects a sparse index outside the dimensions and checks BINARY dimension counts of sparse images; `encodeVector` rejects an image over 1 MB (unreachable for valid vectors).
- Tests use a procedure `OUT SYS_REFCURSOR` for the REF CURSOR case: an anonymous `OPEN :c FOR` is reported IN OUT by the server (pre-existing, documented in other suites).

### Tests added

- `test/src/protocol/data_types_test.dart` (+21): inference rules; node-captured images for FLOAT32 / FLOAT64 / INT8 / BINARY / sparse FLOAT32 / sparse BINARY (encode and decode), plain list → FLOAT64, server images with norm / flexible flags / BINARY reserved space / sparse, NORM absent, special floats, empty vector, malformed images (bad magic, version, format, every truncation length, huge counts before allocation, BINARY dims, sparse index), encode rejections (non-vector values without echo, 1 MB boundary).
- `test/src/oracle_vector_test.dart` (new, 15): construction, copies, unmodifiability, UInt16 / UInt32 limits, validation messages, equality / hashCode / format, `toString`, bind-value predicates.
- `test/src/protocol/messages/execute_message_test.dart` (+17): inference, IN bind metadata + QLocator + image byte-for-byte, NULL IN / OUT placeholder (maxSize ignored), declared FLOAT64 / BINARY, non-vector fails loud, no long-data deferral, define block, `requiresDefine`, row sync (dense / sparse / NULL) with probe, chunked image, duplicate-column copy, malformed strict-vs-probe, unsupported version, truncated stream, PL/SQL OUT and DML RETURNING decode, describe with real vector tail + embedded-cursor acceptance.
- `test/src/oracle_bind_test.dart` (+4 and index 16 assertions), `test/src/connection_execute_many_test.dart` (+5: inferred vector slots, inconsistent slot types, declared defs accept / reject, RETURNING vector slots), `test/src/protocol/constants_test.dart` (+1), `test/src/fetch_as_string_test.dart` (+1, plus `vector` joins the per-enum rejection loop).
- `test/integration/extended_types_vector_integration_test.dart` (new, 23 tests): every dense format, flexible, sparse FLOAT32 / FLOAT64 / INT8 / BINARY, NULLs with row sync, inferred binds round trip, server format conversion, `VECTOR_DISTANCE` (dense and sparse), plain `List<double>` via JSON conversion, 9000-dimension chunked image, DML RETURNING, PL/SQL OUT, PL/SQL IN OUT (list, BINARY, sparse, NULL), executeMany array DML / DML RETURNING with declared slots / PL/SQL, REF CURSOR / nested `CURSOR()` / implicit result, 230-row multi-round fetch eager and `resultSet: true` with a constant (duplicate-column) vector, `fetchTypeHandler`, `fetchLobs` (no handles, no temp LOB queued, nested cursor not rejected), cached statement with differently-typed vectors, ORA-51803. Content probe `CREATE TABLE ... (v VECTOR)`: on ORA-00902 every VECTOR test is skipped with the logged reason (printed once and per test) and the gated 21c test asserts ORA-00902 DDL and ORA-03115 vector bind with the connection usable; on 23ai that one test is skipped instead.

### Verification (2026-10-15)

- `dart analyze --fatal-infos`: No issues found.
- `dart format --output=none --set-exit-if-changed lib test example`: exit 0.
- `dart test test/src`: exit 0, +2384 passed, 12 skipped (15.3 baseline +2319/12; +65 new).
- 23ai (1521/FREEPDB1, Docker Desktop): `RUN_INTEGRATION_TESTS=true dart test test/integration/ --reporter compact --no-color`: exit 0, +831 passed, 34 skipped (15.3 baseline +809/33; the new suite is +22 passed / 1 skipped — the 21c-only test).
- 21c (1522/XEPDB1, Colima): `RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/ --reporter compact --no-color`: exit 0, +811 passed, 54 skipped (15.3 baseline +810/32; the new suite is +1 passed — the gated ORA-00902 / ORA-03115 test — and 22 skipped with the logged reason).
- No existing integration file changed.

## Auto Run Result

Status: done

Follow-up review of the VECTOR implementation completed. The review found and fixed a documentation example that failed for `Int8List`, an imprecise API reference bind statement, malformed sparse-image index ordering, and a missing repeated VECTOR SELECT assertion for the cached-query path.

Files changed in this pass: `README.md` (JSON migration example), `doc/api-reference.md` (inferred bind types), `lib/src/protocol/data_types.dart` (sparse index validation), `test/src/protocol/data_types_test.dart` (duplicate and descending index cases), `test/integration/extended_types_vector_integration_test.dart` (repeat cached VECTOR SELECT), and this story spec (review record). Earlier story implementation files remain in the reviewed change set since the recorded baseline.

Review: three low-severity patch entries and one medium-severity patch entry were applied; no new deferred entries were added. The nine other findings were rejected with individual reasons in the Review Triage Log, including the orchestrator-owned board row and the already documented single-execute BINARY bind limitation. Follow-up review recommended: false (this follow-up pass patched no high-severity entry). No specific unverified risk from the patches remains.

Verification: `dart analyze --fatal-infos` passed; `dart format --output=none --set-exit-if-changed lib test example` passed with 0 changed; `dart test test/src` passed with 2,385 tests and 12 skips. The full 23ai integration suite passed with 831 tests and 34 skips on port 1521. The full 21c integration suite passed with 811 tests and 54 skips on port 1522, including the logged VECTOR skip reason. The new sparse malformed-image unit test passed.

Residual limit: plain single-execute SQL still cannot declare a dense BINARY VECTOR IN bind; this pre-existing deferred item is unchanged.
