---
project_name: 'oracledb'
user_name: 'Abibiano'
date: '2026-07-26'
sections_completed:
  [
    'technology_stack',
    'language_rules',
    'architecture_rules',
    'protocol_rules',
    'lob_rules',
    'testing_rules',
    'quality_rules',
    'workflow_rules',
    'anti_patterns',
  ]
status: 'complete'
optimized_for_llm: true
refreshed_after: 'epic-12 (LOB streaming & temporary LOBs), v1.4.0'
---

# Project Context for AI Agents

_Critical rules and patterns for implementing code in this project. Focused on unobvious details agents otherwise get wrong. Verified against the tree at v1.4.0 / post-Epic-12._

---

## Technology Stack & Versions

| Technology       | Version    | Notes                                                                                            |
| ---------------- | ---------- | ------------------------------------------------------------------------------------------------ |
| Dart SDK         | `^3.12.0`  | Pure Dart. No FFI, no Oracle Client, no native bindings.                                          |
| `meta`           | `^1.12.0`  | `@internal`, `@visibleForTesting` annotations — load-bearing, see Debug Seams below.              |
| `pointycastle`   | `^4.0.0`   | ALL crypto: SHA-512, PBKDF2, HMAC, AES. `package:crypto` is NOT used and must not be added.       |
| `logging`        | `^1.3.0`   | All diagnostic output. `avoid_print` is enforced.                                                 |
| `lints`          | `^6.0.0`   | dev — `package:lints/recommended.yaml` plus project rules.                                        |
| `test`           | `^1.28.0`  | dev — unit + integration.                                                                         |

**Package name is `oracledb`** (pubspec `name: oracledb`, repo dir `dart-oracledb`). Current version **1.4.0**.

- Import in tests/examples: `import 'package:oracledb/oracledb.dart';`
- ❌ NEVER `package:dart_oracledb/...` — that package does not exist.

**Declared platforms:** linux, macos, windows, android, ios. **`web` is deliberately excluded** — `dart:io` is unavailable in the browser and dart2js maps `int` to a double, silently losing precision past 2^53 (corrupts Oracle NUMBER/rowid). Do not add a `web:` platform or a browser-conditional import.

### Reference implementation (consult before assuming)

`reference/node-oracledb` is a **git submodule pinned at 7.0.1**. It is the source of truth for wire behaviour.

- Before implementing or "fixing" any protocol/API behaviour, read the corresponding file under `reference/node-oracledb/lib/thin/` and cite it in the code comment or story record.
- Repeated lesson: several "bugs" in this driver were actually parity-correct, and several "parity fixes" would have introduced defects. **Port intent, not literal JS** — node-oracledb's `lib/thin/lob.js` `init()` has a real operator-precedence bug (`a & B === B`) that would mark every fetched BLOB temporary. Do not port `TNS_LOB_LOC_FLAGS_ABSTRACT` handling literally.
- Where this driver deliberately diverges or declines parity, say so in dartdoc.

---

## Critical Implementation Rules

### Language-Specific Rules (Dart)

**Analyzer must be clean — `dart analyze --fatal-infos --fatal-warnings` → zero issues. This is a CI gate.**

- `strict-casts`, `strict-inference`, `strict-raw-types` all `true`.
- Escalated to **errors**: `missing_return`, `must_be_immutable`, `must_call_super`, `invalid_use_of_protected_member`, `parameter_assignments`.
- `reference/**` and `_bmad-output/**` are excluded from analysis — never "fix" analyzer output there.

**Style (enforced by lints):** `prefer_single_quotes`, `prefer_const_constructors`, `prefer_const_declarations`, `prefer_final_locals`, `use_super_parameters`, `avoid_print`, `unawaited_futures`, `cancel_subscriptions`, `close_sinks`, `no_runtimeType_toString`, `missing_whitespace_between_adjacent_strings`.

**`dart format .` is required** before a PR (checked in review; formatting drift is a real review finding).

**Naming:** files `snake_case.dart`; classes `PascalCase`; methods/vars `camelCase`; constants `lowerCamelCase` (e.g. `tnsPacketConnect`, `oraTypeCursor`); private `_prefixed`.

**Imports:** relative within `lib/src/`; `package:oracledb/` only in `test/` and `example/`. Order: `dart:`, `package:`, relative.

**Async:** `await` immediately, or `unawaited()` deliberately. Never block on a Future in protocol code.

### Architecture & Boundaries

```
lib/oracledb.dart                     # THE public surface — explicit `export ... show` lists only
lib/src/connection.dart               # OracleConnection, OracleExecuteOptions, OracleExecuteManyOptions
lib/src/pool.dart                     # OraclePool
lib/src/result.dart / result_set.dart # OracleResult / OracleRow / OracleResultSet
lib/src/oracle_lob.dart               # OracleLob (public, Epic 12)
lib/src/oracle_bind.dart              # OracleBind, OracleBindDef, OracleDbType, OracleOutBinds
lib/src/errors.dart                   # OracleException, OracleBatchError, ora* codes
lib/src/crypto/                       # auth.dart, session_key.dart, verifier.dart
lib/src/protocol/                     # buffer, constants, data_types, oson, lob_locator,
                                      #   capabilities, result_set_cursor, ttc_packet, messages/
lib/src/transport/                    # transport.dart, socket.dart, tls.dart, packet.dart, connect_string.dart
```

- **Protocol constants live in `lib/src/protocol/constants.dart`** (NOT `lib/src/constants.dart` — the architecture doc's 1.0 tree is stale here). Group by domain (TNS / TTC / Oracle types) with comments.
- **A new public type must be added to `lib/oracledb.dart`'s `show` list**, or it is unreachable by callers.
- `lib/src/transport/` must not import `connection.dart`, `oracle_lob.dart`, or other upper-layer files — that would be a circular import. **Pass a callback instead.** The established precedent: `fetchLobs` wrap-vs-materialize crosses this boundary as `Object Function(LobLocator)? wrapLob`, not as a type dependency. Reuse that seam rather than inventing a new one.

### Protocol Implementation Rules

**Buffer byte order — always explicit.** Oracle TNS/TTC is mixed-endian.

```dart
final v = buffer.readUint16BE();   // CORRECT — endianness in the name
buffer.writeUint32LE(value);       // CORRECT
final v = buffer.readUint16();     // WRONG — which endian?
```

**Behaviour is CONTENT-driven, NEVER server-version-driven.** This is the project's hardest rule.

- Branch on negotiated capability or on the bytes actually received — never on a parsed version string, and never on "is this 21c".
- Auth path: `Transport.supportsFastAuth` is set from the `TNS_ACCEPT_FLAG_FAST_AUTH` bit in the TNS ACCEPT packet; `AuthFlow.authenticate` (`lib/src/crypto/auth.dart`) branches on that flag alone.
  - FAST_AUTH (typically 23ai): one round trip — `sendFastAuth()` bundles Protocol + DataTypes + AUTH_PHASE_ONE; AUTH_PHASE_TWO follows with `dataFlags: 0x0800`.
  - Classical (typically pre-23): `sendProtocolNegotiation()` → `sendAuthPhaseOne()` (`dataFlags: 0x0000`) → AUTH_PHASE_TWO (`0x0000`).
  - ❌ Never call `sendFastAuth` unconditionally.
- Negotiated capabilities must be **propagated into the bytes emitted**, not just stored. Precedent bug: `_buildCompileCapabilities()` clamped `_ttcFieldVersion` internally but kept emitting a literal `24`, so 21c got an over-advertised field version. If you clamp a value, write the clamped value into the slot.

**Fail loud over silent null.** Known type → decode; recognized-but-unsupported → explicit `OracleException`; never a silent `null`, truncation, or mojibake. Prefer failing **before** the wire trip (decode-time / construction-time) so the connection stays reusable.

**Validate synchronously where the caller can see it.** Argument validation must throw synchronously (`expect(() => ..., throwsArgumentError)`), not deliver an `ArgumentError` through a returned Future. Older tests encoded the wrong shape here; fix the test, don't preserve the defect.

**Length prefixes must be bounds-checked.** A single-byte length prefix silently wraps at 256. Guard before writing (see `_checkCapLengthFitsPrefix`).

**Bind validation happens in two places.** Adding a new bind-value type requires auditing **`OracleBind._validate` (construction time)** *as well as* the connection-layer unwrap in `_prepareStatement`. The validator rejects at construction, upstream of everything else — a frequently missed threading site.

**Threading a new per-execute flag: make the internal parameter `required`.** Public `OracleExecuteOptions` fields keep sensible defaults (`fetchLobs = false`), but the internal helpers that carry them are declared `required bool fetchLobs` (three sites in `connection.dart`). This converts a silent-default class of bug into a compile error, and it demonstrably found omitted call sites. Do the same for any new flag threaded through `connection.dart`.

### LOB Rules (Epic 12 — read before touching LOBs)

**Two paths, one decision point.** `OracleExecuteOptions(fetchLobs: false)` (default) **materializes** LOBs to `String`/`Uint8List`. `fetchLobs: true` **wraps** them as `OracleLob` handles. The switch is the `wrapLob` callback threaded through the transport. It must reach **every** consumer: rows, OUT-bind scalars, OUT-bind rows (incl. DML-RETURNING nested), both eager call sites, the implicit-result drain, **and the streaming result-set path**. An unthreaded call site is the epic's signature defect class.

**Handle lifecycle — the categories are not interchangeable:**

- A **fetched** handle (`fetchLobs` wrap) holds the connection's **single in-flight slot** until `close()`. It trips `_rejectConcurrentOperation`, and it therefore **cannot be bound** as a bind value while open. This forces ordering in real code: close the fetched handle before `createTemporaryClob()` or a result-set open.
- A **created** handle (`createTemporaryClob()` / `createTemporaryBlob()`, `isCreatedTemporary == true`) is caller-owned: exempt from the concurrency guard, not reaped by execute-failure cleanup, still serialized by `_runLobOp`.
- Liveness is **consulted, not mirrored**: a handle whose connection closed/reset/broke reports `isClosed == true` immediately. Do not "fix" liveness by marking handles closed at each invalidation site — that was tried and reverted.
- Pool reclaim force-closes open handles (`forceCloseOpenLobs(reclaimedByPool: true)`), and a later `read`/`write` surfaces a pool-reclaim-specific error.

**Temporary-LOB free queue ownership is IMPLICIT and hazardous.** Two owner classes queue locators for `FREE_TEMP`: `createTemporary*` and the materialize path (TEMP-flagged fetched locators). They are meant to be mutually exclusive, backstopped by an O(1) content-level dedupe **inside `Transport.queueTempLobToFree` itself** — the `_tempLobKeysToClose` index keyed by `_tempLobKey(locator)`, kept in lockstep with `_tempLobsToClose` at queue / drain / restore. (The earlier linear `_isTempLobAlreadyQueued` scan is gone; do not grep for it.) If you add a third owner, **verify the dedupe covers it in the same pass** — a double queue sends the same locator twice in one piggyback, and because the piggyback rides an unrelated statement's message the failure surfaces on *that* statement. The dedupe key is a snapshot of the whole mutable locator buffer, so its correctness is fixture-proven rather than structural; the identity-subrange hardening is a carried ledger item.

**A wrap/materialize decision must carry its full close / force-close / bulk-close lifecycle in the same change.** A partial decision reads as a leak and will be reverted.

**Known LOB boundaries — do not "fix" these casually:**

- **Cursor-embedded LOBs are rejected pre-wire.** A LOB column inside a nested `CURSOR()` / REF-CURSOR row cannot be decoded at all (`BufferException: Integer too large` in `decodeExecuteResponse`), and on **pre-23 servers it poisons the transport — the caller loses the connection**. The reject guard must stay reachable from every path, including the streaming result-set path. Nested-cursor LOBs stay on the materialize path.
- **A LOB locator is read-consistent.** A stale handle returns the OLD value *in full* — it does not fail loud. `read()` trusts a once-seeded prefetched `_length`, so `read(offset: length + 1)` returns empty **with no wire trip at all**; `textStream`/`byteStream` at the same offset do issue a READ. Remedy direction matters: an explicit `amount` is itself capped at the cached length so it guards the *shrunk* direction only; a re-`SELECT` is the remedy for the *grown* direction. Get this right in dartdoc AND README — they have disagreed before.
- **`Transport.debugLobReadPieceUnits` / `OracleConnection.debugLobReadPieceUnits` are TEST-ONLY** and must stay so. Do not promote them into a caller-facing `pieceSize` for `read()`.
- **Piece boundaries are joined as BYTES and decoded exactly once**, so a boundary inside a UTF-8 sequence or a UTF-16 surrogate pair cannot corrupt a value. Preserve that invariant.
- On an `AL32UTF8` database **every** CLOB arrives UTF-16BE; the UTF-8-form decode branch is only reachable on a single-byte-charset database (the `we8pdb1` fixture). A *split* UTF-8 sequence is measured unreachable live (the server delivers whole characters) and stays unit-proven only.
- CLOB/NCLOB `write()` is deliberately **surrogate-lenient** (node parity) — documented with a dartdoc caveat.
- A full-length single LOB `READ` scales **super-linearly** (~141 s for a 32 M-unit CLOB). Keep fixtures modest; use `byteStream()`/`textStream()` for the linear path; use the debug piece cap to prove multi-piece behaviour instead of using bigger values.
- An `IN OUT` `OracleLob` bind **consumes** the handle (ORA-22922) with no driver-authored error; the handle still needs `close()`.
- Bare DML `RETURNING ... INTO` cannot take an `OracleBind` spec — it needs a `BEGIN/END` wrapper.
- `OracleResult.closeLobs()` also closes not-yet-delivered handles and an aliased delivered handle (known, unit-pinned).

**Not implemented on purpose (do not assume they exist):** `trim(newSize)`, the BFILE family, a mutable `pieceSize` property, `autoCloseLob`-style auto-close, and any server `length`/`chunkSize` refresh API.

### Error Handling Rules

**Always preserve `cause`:**

```dart
throw OracleException(
  errorCode: oraProtocolError,
  message: 'TNS connection lost',
  cause: originalError,   // REQUIRED — never drop it
);
```

Prefer the exported `ora*` code constants over bare integers. Note `OracleException` and `OracleBatchError` have **no `==`/`hashCode`** — destructure fields in assertions rather than comparing instances.

**Resource cleanup — every server-backed resource needs both an explicit `close()` and an auto-close wrapper:**

```dart
final conn = await OracleConnection.connect(...);
try {
  await conn.execute('SELECT ...');
} finally {
  await conn.close();
}
// or
await pool.withConnection((conn) async { ... });
```

**One lifecycle model for all lazy, server-backed handles** — `OracleResultSet`, REF cursors, and fetched `OracleLob`s all: hold the single in-flight slot, fail-fast on a concurrent operation, close the server resource on `close()`/cancel, and are force-closed with a warning on pool release. Reuse it; don't invent a parallel model. (Created temp LOBs are the one documented narrowing — see above.)

**Reap server resources on the failure path too.** Capture the cursor id *before* the `try` and `requeueCursorsToClose([...])` on any throw. Cache invalidation must be **identity-aware** (`identical`) so a newer same-key entry is never collaterally evicted.

### Logging Rules

```dart
final Logger _log = Logger('OracleConnection');   // or 'oracledb.<area>'
```

`fine` = protocol detail · `info` = connection lifecycle · `warning` = recoverable · `severe` = error + stackTrace. **Never log passwords** — derived session keys only.

### Testing Rules

**Two tiers, both mandatory.**

**1. Unit tests (1741 pass / 6 skip currently) — `dart test --exclude-tags=integration`.**

- Test tree mirrors `lib/src/` exactly; files end `_test.dart`.
- The core unit pattern is a **fake transport**: `class _FakeXTransport extends Transport` with canned wire bytes (see `test/src/oracle_lob_test.dart`, `connection_test.dart`, `nested_cursor_test.dart`, `transport/lob_materialize_wrap_test.dart`, `connection_execute_many_test.dart`). Prefer this over mocking a socket.
- A fake transport must honour the parameters the real one does. Precedent gap: `_NestedCursorTransport.sendExecute` ignored `cursorId`, silently making every nested-cursor test depth-1-only. When you extend a fake, check it can actually drive the path you claim to cover.
- **Proven-to-fail is the standard.** A regression test must be verified to FAIL against the unfixed code (temporarily revert the fix), and say so in the story record. Add negative controls so nothing can pass vacuously.
- Assert **exact** counters, not bounds, when you can — exact `debugCacheSize` / `debugPendingTempLobCount` / `debugLobReadOps` deltas have repeatedly corrected wrong mental models.
- Coverage gate: **line coverage floor 80%** in `.github/workflows/ci.yml` (measured 82.33% on 2026-07-29). Convention: **a floor bump rides the story diff that raises coverage.** This floor has silently drifted ~9 points below reality twice; if you touch coverage, re-measure and bump.

**2. Integration tests — real Oracle, both versions, EVERY story. Non-negotiable.**

`test/integration/*_integration_test.dart`, tagged `@Tags(['integration'])`, gated on `RUN_INTEGRATION_TESTS=true`.

| Fixture               | Image                                                 | Service    | Port | Runtime (Apple Silicon)                      | Gate                                   |
| --------------------- | ----------------------------------------------------- | ---------- | ---- | -------------------------------------------- | -------------------------------------- |
| Oracle 23ai (primary) | `container-registry.oracle.com/database/free:latest`  | `FREEPDB1` | 1521 | **Docker Desktop** (`desktop-linux`, native) | `RUN_INTEGRATION_TESTS`                |
| Oracle 21c (required) | `gvenzl/oracle-xe:21`                                 | `XEPDB1`   | 1522 | **Colima x86_64 VM** (emulated, 6 CPU/8 GB)  | `RUN_INTEGRATION_TESTS`                |
| WE8MSWIN1252 (opt-in) | `gvenzl/oracle-free:latest` + `non_al32utf8_setup.sql` | `we8pdb1`  | 1523 | Docker Desktop (native ARM64)                | **also** `RUN_NON_AL32UTF8_TESTS=true` |

```bash
# 23ai (native)
docker context use desktop-linux && docker compose up -d
RUN_INTEGRATION_TESTS=true dart test test/integration/ --no-color

# 21c (emulated — ALWAYS name the service, or a bare --profile up also starts 23ai inside Colima)
colima start --arch x86_64 --cpu 6 --memory 8
docker context use colima
docker compose --profile oracle21c up -d oracle21c    # wait for `healthy`
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 \
  dart test test/integration/ --no-color

# Optional single-byte-charset fixture
docker compose --profile non-al32utf8 up -d oracle-non-al32
RUN_INTEGRATION_TESTS=true RUN_NON_AL32UTF8_TESTS=true \
  dart test test/integration/charset_non_al32utf8_integration_test.dart
```

Current baselines: **563 pass / 32 skip on 23ai**, **564 pass / 31 skip on 21c** (+4 more when the non-AL32UTF8 fixture is up). The focused Epic 12 LOB suite (6 files) is **155 / 0** on both. Re-read these from a real run before quoting them anywhere user-facing — a stale count shipped in the 1.4.0 CHANGELOG twice.

**Integration test rules:**

- ❌ NEVER hardcode `FREEPDB1`, `XEPDB1`, `we8pdb1`, `1521`, `1522`, `1523`, `system`, or `testpassword`. Use `test_helper.dart`: `testHost`, `testPort`, `testService`, `testUser`, `testPassword`, `testConnectString`, `connectForTest()`, and the `nonAl32*` / `connectForNonAl32Test()` equivalents.
- **Reuse the shared helpers in `test/integration/test_helper.dart`; do not copy-paste** — `uniqueObjectName()`, `uniqueTableName()`, `nextTestId()`, `returned()`, `nationalCharsetSupported()`, `tempLobCount()`, `cleanUpConnection()`, `integrationEnabled`. A helper copy-pasted four times is a review finding.
- Object names must be **per-run unique** and fit **Oracle 21c's 30-byte identifier limit** (23ai allows 128 — the dual-env mandate means 30 wins).
- Only auth-path-specific tests may skip by version, via a `Transport.supportsFastAuth` probe. **Everything else must pass on both** without skipping.
- **Non-ASCII test fixtures MUST use explicit Dart escapes** — `'caf\u{00E9}'`, `'\u{4E2D}\u{6587}'`, `'\u{1F600}'` — never raw literals. (This rule was missed three consecutive stories; the source file has now been normalized, so there is no excuse left.)
- Use a **dedicated, expendable connection** for any case that can poison the transport, and accept version-agnostic outcomes where the poisoned session's fate genuinely differs (23ai survives, 21c reports ORA-03113).
- Known pre-23 server quirk, not a driver bug: on a MERGE, `dmlRowCounts` under-reports a success that follows a batch error when `batchErrors` is also on. Keep those two options in **separate** MERGE tests.

**"Measure, don't assume" is a hard rule, not advice.** Every claim about server behaviour must be measured live on both fixtures before it goes in code or docs. This has paid off four separate times in Epic 12 — closing a "defect" as a non-issue, surfacing two unrelated real leaks, and overturning two *documented* claims. Record the measurement (including negative results) in the story record and the ledger.

### Debug Seams

There are ~33 `@visibleForTesting` and ~37 `@internal` annotations. Instrumentation counters (`debugCacheSize`, `debugSequence`, `debugPendingCloseCount`, `debugPendingTempLobCount`, `debugLobReadOps`, `debugFullParseExecutes`, `debugReuseExecutes`, `debugTtcFieldVersion`, `debugSupportsFastAuth`, `debugSdu`, `debugLobReadPieceUnits`, …) exist so tests can assert facts without contorting production code.

- Prefer adding a **narrow, default-off, annotated seam** over reshaping production logic for testability. Assert the production fast path is byte-for-byte unchanged when the seam is off.
- Document the **scope boundary** of any reset/instrumentation helper (what it deliberately does NOT reset, the invariant, and the condition that would break it).

### Development Workflow Rules

- Branches: `story/<epic>-<story>-<slug>` (e.g. `story/12-1-public-lob-object`). Work happens on a branch, PR into `main`.
- Commits: Conventional Commits with a story scope — `feat(story-12-3): ...`, `chore(story-12-1): ...`. **Never** include `Co-Authored-By` or any AI attribution.
- Pre-PR checklist: `dart analyze --fatal-infos --fatal-warnings` clean · `dart format .` · unit suite green · integration green on **23ai AND 21c** · `scripts/sync_readme_version.sh --check` if version metadata changed.
- CI jobs: `quality` (analyze + pana + unit + coverage gate + Codecov, Linux) · `platform` (unit on macOS + Windows; Linux deliberately absent) · `integration` (23ai) · `integration-21c` · `integration-non-al32utf8` (**manual `workflow_dispatch` only**).
- Version bumps go through `scripts/bump_version.sh`; `CHANGELOG.md` and README version references must agree with `pubspec.yaml`.
- **Docs are release artifacts, reviewed as adversarially as code.** Three Epic 12 review findings were pure documentation defects (a CHANGELOG entry claiming a bug fix for a defect that never shipped; README and dartdoc disagreeing on a remedy). Two habits are now required:
  1. After the code settles, run a **docs-vs-diff consistency pass** — re-read every doc sentence the diff invalidated.
  2. Any fix that **adds a remedy claim** must cite the measurement row proving that remedy is reachable. An unmeasured remedy in the README is a user-facing falsehood.
- **At epic close, grep the docs for forward references to sibling stories in the same epic** ("deferred to Story 12.3" when 12.3 already shipped). Per-story review structurally cannot catch these.
- **Resolve cross-AC contradictions at story-authoring time**, not in Completion Notes. Two known shapes: a hold-back-and-join clause always breaks a hard per-piece size cap; and "a handle is bindable" contradicts "the handle holds the in-flight slot".
- Track deferrals in `_bmad-output/implementation-artifacts/deferred-work.md`. **Every deferral needs a `target:`.** Reviewer lenses do not read this ledger, so accepted deferrals resurface as fresh findings every iteration — triage is the filter, not the reviewer.

---

## Critical Don't-Miss Rules

**Top anti-patterns, in the order they actually bite:**

1. ❌ `import 'package:dart_oracledb/...'` → ✅ `package:oracledb/oracledb.dart`.
2. ❌ Branching on Oracle version → ✅ branch on negotiated capability or received content.
3. ❌ `buffer.writeUint16(len)` → ✅ `buffer.writeUint16BE(len)`.
4. ❌ Threading a new flag with a defaulted internal parameter → ✅ `required`, so an omitted call site is a compile error.
5. ❌ Adding a public type without adding it to `lib/oracledb.dart`'s `show` list.
6. ❌ Importing an upper layer from `lib/src/transport/` → ✅ pass a callback (`wrapLob` precedent).
7. ❌ Hardcoded connection params, service names, or ports in tests → ✅ `test_helper.dart` getters.
8. ❌ Raw non-ASCII literals in tests → ✅ `\u{...}` escapes.
9. ❌ Validating a "real Oracle only, no mocks" belief → the fake-transport unit tier is the primary tier; use it.
10. ❌ Declaring done after 23ai only → ✅ both fixtures, every time.
11. ❌ Silent `null` on an unrecognized type, silent truncation, silent mojibake → ✅ `OracleException`.
12. ❌ Dropping `cause` when rewrapping an error.
13. ❌ Documenting a remedy nobody measured.

**Edge cases that must be handled explicitly:**

- Empty result set → empty list, never `null`. Oracle NULL ≠ empty string.
- Oracle `NUMBER` is base-100-encoded and can exceed Dart `int` range.
- `DATE` is a 7-byte format; TSTZ **region-id** form is currently hard-rejected (offset form only).
- LOBs materialize by default; handles are opt-in via `fetchLobs: true`.
- TNS timeout and socket timeout are distinct.
- `SELECT ... FOR UPDATE` takes **no** statement-cache slot (`isCacheEligibleSql` in `lib/src/sql_classifier.dart` excludes locking selects); a repeated LOB SELECT holds exactly one.
- Naming trap in `lib/src/protocol/constants.dart`: `ttcDmlOptionRowCounts` uses the **`dmlOptions`/exec-flags** word, unlike nearby `ttcExecOption*` constants in the **`options`** word. Read its doc comment before adding a neighbour.

**Security:** never log or persist passwords (derived keys only) · credentials from environment variables only · bind parameters over string interpolation · close connections on error so the pool cannot be exhausted.

**Performance:** reuse cached prepared statements · page large result sets (`maxRows`, `fetchSize`, streaming `resultSet`) · size pools to connections, not requests · never block on a Future in protocol code · avoid full-length single LOB reads (super-linear).

---

## Usage Guidelines

**For AI agents:**

- Read this file before implementing anything. Follow every rule as written; when in doubt take the more restrictive option.
- Consult `reference/node-oracledb` (7.0.1) before asserting how the wire behaves — and measure live on both fixtures before asserting how the server behaves.
- Check `_bmad-output/implementation-artifacts/deferred-work.md` before reporting a "new" finding: it may be an accepted, targeted deferral.
- Update this file when a rule genuinely changes; do not append per-story trivia.

**For humans:** keep it lean · refresh at each epic close (stack, fixtures, counters, coverage floor, new durable constraints) · delete rules that have become obvious.

Last Updated: 2026-07-26 (post-Epic-12, v1.4.0)
