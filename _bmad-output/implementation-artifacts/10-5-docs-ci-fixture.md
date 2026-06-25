---
created: 2026-06-25
story_key: 10-5-docs-ci-fixture
baseline_commit: 4a2a9a3112058449035c5e5b40ad552a0b5a3b20
---

# Story 10.5: Docs & CI Fixture

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a prospective user evaluating this driver for a non-AL32UTF8 or national-charset
Oracle database,
I want the README to state exactly which character-set configurations are supported
and the CI to prove the non-AL32UTF8 round-trip on every run (or document, honestly,
why it cannot),
so that the Epic 10 charset guarantees are discoverable, trustworthy, and regression-protected
without my having to read the source or run a private fixture.

## Acceptance Criteria

1. **README gains a character-set support matrix that matches the implemented behavior**
   **Given** a reader on the published README
   **When** they look for character-set support
   **Then** there is a dedicated section (e.g. "Character Set Support") that states:
   the **primary** database character set is supported via Oracle **server-side conversion** while the client always negotiates UTF-8 (`AL32UTF8`/`ttcCharsetUtf8`) on the wire — so `AL32UTF8` **and** single-byte/non-AL32UTF8 database charsets (validated against `WE8MSWIN1252`) both round-trip for `VARCHAR2`/`CHAR`/`CLOB`;
   **And** the **national** character set `AL16UTF16` is supported for `NCHAR`/`NVARCHAR2`/`NCLOB` (Story 10.4);
   **And** unsupported national charsets (e.g. deprecated `UTF8` national) **fail loud** with an `OracleException` — never silent mojibake;
   **And** the section explicitly states the thin model: the driver does **not** read `NLS_LANG`, does **not** expose a configurable client-side database-charset codec, and relies on the server for database-charset conversion (node-oracledb thin parity).

2. **Stale charset claims in the README are corrected — no contradiction with Epic 10 behavior**
   **Given** the pre-Epic-10 README text
   **When** Story 10.5 ships
   **Then** the **Known Limitations** "Character sets" bullet (currently "the driver assumes the database character set is UTF-8 … Data stored in non-UTF-8 character sets may decode incorrectly") is rewritten or removed so it no longer contradicts AC1;
   **And** the LOB-section claim "NCLOB and BFILE columns are not yet supported and fail with a clear `OracleException`" is corrected — **NCLOB is now supported** (Story 10.4); BFILE remains unsupported/fail-loud;
   **And** the **Supported Data Types** table reflects national types (`NCHAR`/`NVARCHAR2`/`NCLOB` → `String`) and references the new section;
   **And** the **Project Status** / **Planned After 1.0** roadmap no longer lists "Non-`AL32UTF8` database character set compatibility" as merely planned (Epic 10 is delivered).

3. **The non-AL32UTF8 fixture is wired into CI if it can be made reliable; otherwise the gap is gated and documented — never silently skipped**
   **Given** the local-only `oracle-non-al32` (`WE8MSWIN1252` / `we8pdb1`) fixture from Story 10.3
   **When** the dev wires it into `.github/workflows/ci.yml`
   **Then** the `charset_non_al32utf8_integration_test.dart` suite runs in CI against a real `WE8MSWIN1252` database with `RUN_INTEGRATION_TESTS=true RUN_NON_AL32UTF8_TESTS=true` and the `ORACLE_NON_AL32UTF8_*` env wired to the CI fixture;
   **And** if the fixture cannot be made reliable in GitHub Actions within a reasonable cold-start/timeout budget, the job is **gated** (e.g. `workflow_dispatch`-only or a clearly-labeled non-blocking job) **and** the limitation is documented in a CI comment **and** surfaced (README/CONTRIBUTING) so the gap is explicit;
   **And** in no case does an enabled non-AL32UTF8 job silently skip or pass without actually exercising a non-AL32UTF8 database (the Story 10.3 AC1 guard already fails loud if connected to `AL32UTF8`).

4. **Epic 10 charset tests are confirmed green on both standard environments and the commands are documented**
   **Given** the full Epic 10 charset suite (`charset_capability_*`, `charset_negotiation_*`, `nchar_integration_test.dart`, plus the focused non-AL32UTF8 suite)
   **When** the dev runs them per the project dual-env rule
   **Then** all Epic 10 charset tests pass on Oracle 23ai (1521/FREEPDB1) and Oracle 21c (1522/XEPDB1) without unexpected skips;
   **And** the exact commands (including the `RUN_NON_AL32UTF8_TESTS` fixture command) are documented in the README **Tests** section and/or `CONTRIBUTING.md`.

5. **CONTRIBUTING.md documents the non-AL32UTF8 fixture for contributors**
   **Given** a contributor who wants to run the full charset suite locally
   **When** they read `CONTRIBUTING.md`
   **Then** it documents the optional `non-al32utf8` compose profile (bring-up command, `port 1523`/`we8pdb1`, the `RUN_NON_AL32UTF8_TESTS=true` flag, and the `ORACLE_NON_AL32UTF8_*` overrides);
   **And** it notes the fixture is local/opt-in and (if AC3 gated CI) why CI does not run it by default.

6. **Documentation-and-CI scope only — no behavioral production changes**
   **Given** this is the Epic 10 closeout (docs + CI fixture + dual-env confirmation)
   **When** Story 10.5 is implemented
   **Then** no behavior-changing edits are made under `lib/src/` (charset/national/codec logic stays exactly as Stories 10.1–10.4 left it);
   **And** the only permissible code-adjacent changes are documentation (README, CONTRIBUTING, dartdoc), CI workflow, `docker-compose.yml` comments, and — only if a real defect surfaces while validating — a narrowly-scoped fix recorded as its own task with a regression test.

7. **Version-reference and analyzer gates stay green**
   **Given** the CI `quality` job runs `scripts/sync_readme_version.sh --check` and `dart analyze --fatal-infos --fatal-warnings`
   **When** the README is edited
   **Then** any version strings the README references stay consistent with `pubspec.yaml` (the version check passes);
   **And** `dart analyze` reports zero issues across the whole project.

## Tasks / Subtasks

- [x] Add a "Character Set Support" section to the README (AC: 1)
  - [x] Place it logically — e.g. immediately after **Supported Data Types** (README ~L452-466) or just before **Known Limitations** — so it is discoverable from the data-type table. *(Added as `## Character Set Support`, after the Supported Data Types block and before Project Status; the data-type table cross-links to `#character-set-support`.)*
  - [x] Document the primary model: client always negotiates UTF-8 (`ttcCharsetUtf8 = 873`); server converts to/from the database charset; `AL32UTF8` and non-AL32UTF8 single-byte charsets (validated `WE8MSWIN1252`) both round-trip for `VARCHAR2`/`CHAR`/`CLOB`. *(Described functionally — UTF-8 wire + server-side conversion — not as a "negotiate 2000" wire detail, per Story 10.4 review correction.)*
  - [x] Document the national model: `AL16UTF16` national charset → `NCHAR`/`NVARCHAR2`/`NCLOB` carried as UTF-16BE, marked by `csfrm` (Story 10.4); use `OracleDbType.nVarchar` / `OracleDbType.nClob` for national binds.
  - [x] State fail-loud for unsupported national charsets (e.g. deprecated `UTF8` national) — `OracleException`, never silent corruption.
  - [x] State the thin-model boundaries: no `NLS_LANG` parsing, no configurable client-side DB-charset codec (node-oracledb thin parity).

- [x] Correct stale charset claims across the README (AC: 2)
  - [x] Rewrite the **Known Limitations** "Character sets" bullet (L665) so it no longer says non-UTF-8 data "may decode incorrectly" — point to the new support section instead.
  - [x] Fix the LOB-section line (L560) "NCLOB and BFILE columns are not yet supported" → NCLOB is supported (Story 10.4); only BFILE remains unsupported/fail-loud.
  - [x] Update the **Supported Data Types** table: ensure `NCHAR`/`NVARCHAR2`/`NCLOB` map to `String` with a pointer to the new section. *(Split into a `VARCHAR2, CHAR` row and a dedicated `NCHAR, NVARCHAR2, NCLOB` national row, both cross-linking the new section.)*
  - [x] Update **Project Status** / **Planned After 1.0** (L614-638): Epic 10 charset compatibility is delivered — move it out of the "planned" table (or mark delivered) so the roadmap is accurate. *(Added a "✅ Done" Project Status row; removed the Planned-After-1.0 priority-1 row and renumbered the rest.)*

- [x] Wire the non-AL32UTF8 fixture into CI, or gate-and-document if unreliable (AC: 3)
  - [x] **Constraint to design around:** GitHub Actions `services:` containers start **before** repo checkout and cannot bind-mount repo files. *(Job uses `docker run -v` with the init SQL **after** checkout — not a `services:` block.)*
  - [x] Add an `integration-non-al32utf8` job that runs `charset_non_al32utf8_integration_test.dart` with `RUN_INTEGRATION_TESTS=true RUN_NON_AL32UTF8_TESTS=true` and the `ORACLE_NON_AL32UTF8_*` env pointing at the CI fixture.
  - [x] Validate the gvenzl cold-start + CSALTER migration cost. *(Gated to `workflow_dispatch` (manual) rather than a blocking push/PR check — the cold-start + migration is slower/less proven than the AL32UTF8 service jobs; rationale documented in the CI comment, README, CONTRIBUTING, and docker-compose. A self-contained 25-min wait loop replaces the shared 10-min probe.)*
  - [x] Never silently skip: the job asserts the live charset is `WE8MSWIN1252` **and** the suite's Story 10.3 AC1 guard hard-fails on `AL32UTF8`, so a green run always means a real non-AL32UTF8 round-trip.

- [x] Confirm Epic 10 dual-env green and document the commands (AC: 4)
  - [x] Focused charset suite on **Oracle 23ai** — covered by the full-suite run (charset_capability / charset_negotiation / nchar all executed, no skips).
  - [x] Same on **Oracle 21c** (`ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1`) — national/NCLOB/NVARCHAR2 tests visibly ran.
  - [x] Run the **non-AL32UTF8** fixture suite once locally — 20/20 against the live `WE8MSWIN1252` DB on port 1523.
  - [x] Run the **full** integration suite on both 23ai and 21c — 23ai 421/28-skip, 21c 422/27-skip, zero failures, skip counts match the established TLS-only baseline (no regression).
  - [x] Document the non-AL32UTF8 command in the README **Tests** section and `CONTRIBUTING.md`.

- [x] Document the fixture in CONTRIBUTING.md (AC: 5)
  - [x] Add a non-AL32UTF8 fixture subsection: profile bring-up, port `1523`, service `we8pdb1`, the `RUN_NON_AL32UTF8_TESTS=true` flag, and the `ORACLE_NON_AL32UTF8_*` overrides (defaults table).
  - [x] Note it is local/opt-in and why CI does not run it by default (workflow_dispatch-gated; cold-start cost).

- [x] Validate gates and finalize (AC: 6, 7)
  - [x] Confirm **no** behavioral change under `lib/src/` — `git status lib/` is empty; no defect surfaced.
  - [x] Run `scripts/sync_readme_version.sh --check` — passes (1.1.0).
  - [x] Run `dart analyze --fatal-infos --fatal-warnings` — "No issues found!".
  - [x] CI workflow YAML validated well-formed (parses; 5 jobs incl. `integration-non-al32utf8`; triggers push/pull_request/workflow_dispatch).

## Dev Notes

### Scope Boundary

Story 10.5 is the **Epic 10 closeout**: it makes the charset guarantees built in Stories 10.1–10.4 **discoverable** (README support matrix), **honest** (correct the now-false "non-UTF-8 may decode incorrectly" and "NCLOB not supported" claims), and **regression-protected** (CI fixture if reliable; dual-env confirmation). It is a docs + CI + test-wiring story. Do **not** touch charset/national/codec behavior under `lib/src/` — that is finished and validated. Do **not** add new Oracle charsets, new public API, or new national-type features. The Story 10.3 fixture (compose profile, init SQL, `test_helper.dart` getters, focused suite) and the Story 10.4 national-type support already exist and must be reused, not reinvented.

### Architecture Guardrails

- **Thin server-conversion model is the documented truth.** Primary wire charset stays UTF-8 (`873`); the server converts to/from the database charset. Non-AL32UTF8 DB charsets are supported via that conversion, **not** a configurable client codec; the driver ignores `NLS_LANG`. The README must describe exactly this — do not imply a client-side DB-charset codec exists. [Source: `_bmad-output/planning-artifacts/architecture.md` "Core model decision — adopt node-oracledb thin charset model" (L1029-1045)]
- **National model.** `AL16UTF16` national charset → `NCHAR`/`NVARCHAR2`/`NCLOB` as UTF-16BE, routed by the `csfrm` byte; `ttcCharsetAl16Utf16 = 2000` is the supported national id; unsupported national charsets fail loud. [Source: architecture.md L1046-1059; Story 10.4]
- **CI fixture instruction is explicit in the architecture:** "Add a non-AL32UTF8 DB fixture to CI … **Gate it if it can't be made reliable, and `log()`/document the gap rather than silently skipping.**" This is the binding rule for AC3 — gating + documenting is an acceptable outcome; silent skipping is not. [Source: architecture.md "Validation (the one infra addition)" L1071-1080]
- **Project DoD:** all Epic 10 tests pass on BOTH Oracle 23ai and Oracle 21c, written with `test_helper.dart` (no hardcoded connection params). [Source: `_bmad-output/project-context.md` "Mandatory: Dual-Environment Validation"; `CLAUDE.md`]

### Files To Read Before Editing

- `README.md`
  - Current state (relevant lines): **Supported Data Types** table at L452-466 (`VARCHAR2, CHAR, NVARCHAR2 → String`; no `NCHAR`/`NCLOB`; no charset section); LOB section at L553-561 ends with the now-stale "NCLOB and BFILE columns are not yet supported"; **Project Status** L614-638 still lists non-AL32UTF8 as Planned-After-1.0 priority 1; **Tests** L640-661 (dual-env commands, no non-AL32UTF8 command); **Known Limitations** L663-672, first bullet (L665) says non-UTF-8 "may decode incorrectly".
  - What changes: add a "Character Set Support" section; correct L665, L560, the data-type table, and the roadmap; add the non-AL32UTF8 test command.
  - Must preserve: all other limitation bullets, the existing dual-env command block, version strings checked by `sync_readme_version.sh`, and section ordering/anchors referenced elsewhere (e.g. `#clob-support`).

- `.github/workflows/ci.yml`
  - Current state: jobs `quality` (analyze + unit + coverage + README version check), `platform` (macOS/Windows unit), `integration` (23ai service container, port 1521, FREEPDB1, registry creds, `ci_wait_for_oracle.sh`), `integration-21c` (gvenzl/oracle-xe:21, XEPDB1). All Oracle jobs use the GHA `services:` mechanism (bare image, no repo bind mounts) plus `scripts/ci_wait_for_oracle.sh`.
  - What changes: add a non-AL32UTF8 fixture job/step (AC3). Because `services:` cannot bind-mount the repo's init SQL, this job must `docker run` (or `docker exec` a migration into a running gvenzl container) **after** checkout.
  - Must preserve: existing job names and triggers, the `concurrency` group, the registry-credential pattern for the official 23ai image, the coverage gate, and `ci_wait_for_oracle.sh` usage. Do not make a flaky non-AL32UTF8 job block `main` — gate or mark non-blocking if unreliable.

- `docker-compose.yml`
  - Current state: `oracle23ai` (1521/FREEPDB1), `oracle21c` (profile `oracle21c`, 1522/XEPDB1), `oracle-non-al32` (profile `non-al32utf8`, 1523/we8pdb1, `gvenzl/oracle-free:latest`, bind-mounts `non_al32utf8_setup.sql`, healthcheck on `we8pdb1`). The block comments (L76-107) say "NOT wired into CI — CI fixture hardening and the README support matrix remain Story 10.5."
  - What changes: update the L76-80 comment once CI wiring is decided (wired, or gated-with-reason). Likely no service definition change.
  - Must preserve: service names, ports, healthchecks, profile gating, the no-named-volume-on-purpose comment, and Apple Silicon guidance.

- `test/integration/fixtures/non_al32utf8_setup.sql`
  - Current state: creates `we8pdb1` from the seed and migrates it to `WE8MSWIN1252` via the `ALTER DATABASE CHARACTER SET INTERNAL_USE` (CSALTER bypass), with a session-detach wait loop. Path-specific to gvenzl (`/opt/oracle/oradata/FREE/...`). Runs as SYSDBA in CDB$ROOT on first boot via `/container-entrypoint-initdb.d`.
  - What changes: none expected — reuse as-is for CI. Only touch if CI requires a path/parameter difference (record as its own task if so).
  - Must preserve: the CSALTER safety reasoning (only valid because the PDB is empty/all-ASCII), the session-kill loop, and `SAVE STATE` (open mode survives restart).

- `test/integration/test_helper.dart`
  - Current state: `nonAl32Enabled` (gated on `RUN_NON_AL32UTF8_TESTS`), `nonAl32Host/Port/Service/User/Password` getters (defaults `localhost`/`1523`/`we8pdb1`/`system`/`testpassword`), `nonAl32ConnectString`, `connectForNonAl32Test()`.
  - What changes: none expected — the CI job sets the `ORACLE_NON_AL32UTF8_*` env to override defaults.
  - Must preserve: all getters and the env-override contract (CI overrides host/port to match its fixture).

- `test/integration/charset_non_al32utf8_integration_test.dart`
  - Current state (Story 10.3): 20 VARCHAR2/CHAR/CLOB round-trip tests; double-gated on `RUN_INTEGRATION_TESTS` + `RUN_NON_AL32UTF8_TESTS`; AC1 guard hard-fails if connected to `AL32UTF8` and requires the actual `WE8MSWIN1252` charset.
  - What changes: none expected — Story 10.5 only wires it into CI and documents it.
  - Must preserve: the fail-loud fixture guard (it is the safety net that makes AC3's "never silently passes" true).

- `CONTRIBUTING.md`
  - Current state: developer walkthrough for the dual-env setup (no non-AL32UTF8 fixture mention — grep returned nothing).
  - What changes: add the non-AL32UTF8 fixture subsection (AC5).
  - Must preserve: existing 23ai/21c setup instructions and Apple Silicon/Colima guidance.

### Existing Code Facts

- **The non-AL32UTF8 fixture is local-only and opt-in today** (Story 10.3): `non-al32utf8` compose profile, untouched by `docker compose up` and CI, and the standard dual-env suites skip the suite unless `RUN_NON_AL32UTF8_TESTS=true`. Story 10.5 is exactly the deferred "CI fixture + README support matrix" work that 10.3's completion notes, the compose comments (L79-80), and the SQL header (L22-23) all explicitly hand off to this story.
- **Validated charset is `WE8MSWIN1252`** — chosen because its AC2 punctuation set (euro, smart quotes, en/em dash, ellipsis, bullet) are WIN1252-specific (control codes in ISO-8859-1), so a clean round-trip proves real UTF-8 ⇆ server conversion, not a byte-identity accident. Keep the README wording faithful to "validated against WE8MSWIN1252," not a blanket "all charsets."
- **NCLOB is supported as of Story 10.4** — the README LOB line saying it is "not yet supported" is now false. BFILE remains genuinely unsupported (fail-loud).
- **No image-level charset knob exists.** Every Oracle Free image ships a prebuilt AL32UTF8 DB and ignores `ORACLE_CHARACTERSET`; the fixture exists precisely to work around that via the in-PDB CSALTER migration. The CI job must reproduce that init path (gvenzl + bind-mounted init SQL) — it cannot just set an env var on the official 23ai service.
- **GHA `services:` cannot mount repo files** (containers start before checkout). This is the central CI design constraint for AC3 — the existing `integration`/`integration-21c` jobs work because their images need no repo files; the non-AL32UTF8 fixture does (the init SQL). Hence a `docker run`/`docker exec` step rather than a `services:` block.

### Previous Story Intelligence

- **Story 10.1** added `OracleCharsetInfo` (`databaseCharset`, `nationalCharset`, `supportsNationalCharacterSet`) and startup detection; both 23ai and 21c report `AL16UTF16` national. Its review enforced credential-free errors — keep any new docs/CI free of secrets (CI password is an ephemeral non-secret by existing convention).
- **Story 10.2** made primary UTF-8 negotiation explicit (`ttcCharsetUtf8` on both FAST_AUTH and classical paths) and added `charset_negotiation_integration_test.dart`. Charset-field byte offsets are subtle (an AC5 off-by-one was caught) — irrelevant to docs but explains why production code must stay untouched here.
- **Story 10.3** built the non-AL32UTF8 fixture and proved VARCHAR2/CHAR/CLOB on `WE8MSWIN1252` with **zero production code changes**; it explicitly deferred CI wiring + README support matrix to Story 10.5 and resolved its open questions (WE8MSWIN1252; optional local compose profile added).
- **Story 10.4** added national-type support (UTF-16BE codec, `OracleDbType.nVarchar`/`nClob`, NCLOB LOB path, connect-time fail-loud guard). Crucially, its review **corrected the AC1 wire-format premise**: DataTypes/column charset slots stay `ttcCharsetUtf8`; the `csfrm` byte is the national marker; `ttcCharsetAl16Utf16 = 2000` is the supported-id/capability, **not** written into negotiation. The README support matrix must describe the **functional** outcome (AL16UTF16 national support, fail-loud otherwise), not the internal wire detail — and must not repeat the original (wrong) "negotiate 2000" framing.

### Git Intelligence Summary

- `4a2a9a3 test(integration): add NCHAR, NVARCHAR2, and NCLOB integration tests` — Story 10.4 tail (baseline for this story).
- `7b527ee test(integration): add tests for non-AL32UTF8 database charset round-trips` — Story 10.3; introduced `charset_non_al32utf8_integration_test.dart`, the `non-al32utf8` compose profile, the init SQL, and the `connectForNonAl32Test()`/`ORACLE_NON_AL32UTF8_*` helpers. This is the fixture Story 10.5 wires into CI and documents.
- `20dcf7e` / `028ad1b` — Stories 10.2 / 10.1 (negotiation + detection). Pattern: each charset story is test/docs-heavy with minimal-to-zero production change; Story 10.5 continues that — docs + CI only.

### Latest Technical Information

- **node-oracledb thin globalization** (parity reference): Thin mode relies on the **server** for database-character-set conversion and uses AL32UTF8 for client character data; it **ignores Oracle `NLS_LANG`** environment settings. `AL16UTF16` national charset is supported; `UTF8` national charset is **not** supported in Thin mode. The README support matrix should mirror this framing. [Source: node-oracledb globalization + appendix_a docs, checked 2026-06-23 in Story 10.3; `reference/node-oracledb/doc/src/user_guide/globalization.rst`]
- **GitHub Actions service containers** are created from a bare image at job start (before `actions/checkout`), so they cannot bind-mount workspace files; a custom init script must be supplied via a post-checkout `docker run -v` step or `docker exec`. This is why the existing Oracle service jobs use only the image's own healthcheck/entrypoint and why the non-AL32UTF8 fixture needs a different wiring shape. (General GHA behavior; confirm current Actions docs if the wiring proves fiddly.)
- **Cold-start budget:** the existing 23ai job allows `--health-start-period 600s` (~8-10 min). A gvenzl `oracle-free` + CSALTER-migration fixture will be at least as slow; the dev must measure whether it lands inside the job timeout reliably before making it a blocking job. If marginal, gate it (`workflow_dispatch`) and document — per the architecture's explicit instruction.

### Project Structure Notes

- All edits are in **docs and CI**: `README.md`, `CONTRIBUTING.md`, `.github/workflows/ci.yml`, and comment-only touch-ups to `docker-compose.yml`. No new files under `lib/` or `test/` are expected (the fixture and suite already exist).
- The README "Character Set Support" section should slot near **Supported Data Types** (so the data-type table can cross-link to it) and stay above **Known Limitations**.
- Keep README anchors stable — other sections link to `#clob-support`, `#blob-support`, etc.; a new section adds an anchor but must not rename existing ones.
- If CI wiring needs a helper script, place it under `scripts/` alongside `ci_wait_for_oracle.sh` and follow its style (bounded readiness probe, clear failure-mode logging).

### Done Criteria Checklist

- [ ] README has a "Character Set Support" section describing primary server-conversion (AL32UTF8 + non-AL32UTF8/`WE8MSWIN1252`), national `AL16UTF16` (`NCHAR`/`NVARCHAR2`/`NCLOB`), fail-loud-on-unsupported, and thin-model boundaries (no `NLS_LANG`, no client codec).
- [ ] Known Limitations "Character sets" bullet rewritten/removed (no longer says non-UTF-8 "may decode incorrectly").
- [ ] README LOB section corrected: NCLOB supported; only BFILE unsupported/fail-loud.
- [ ] Supported Data Types table covers `NCHAR`/`NVARCHAR2`/`NCLOB` → `String` and links the new section.
- [ ] Project Status / roadmap no longer lists non-AL32UTF8 charset compat as merely "planned".
- [ ] CI runs the non-AL32UTF8 suite against a real `WE8MSWIN1252` DB — OR the job is explicitly gated and the gap documented in a CI comment + README/CONTRIBUTING (never silently skipped).
- [ ] CONTRIBUTING.md documents the `non-al32utf8` compose profile, port 1523/we8pdb1, the `RUN_NON_AL32UTF8_TESTS` flag, and `ORACLE_NON_AL32UTF8_*` overrides.
- [ ] Epic 10 charset focused suite passes on Oracle 23ai (1521/FREEPDB1).
- [ ] Epic 10 charset focused suite passes on Oracle 21c (1522/XEPDB1).
- [ ] non-AL32UTF8 fixture suite passes once locally against `WE8MSWIN1252`.
- [ ] Full integration suite shows no regression on both 23ai and 21c.
- [ ] No behavioral change under `lib/src/` (any necessary defect fix is a scoped task with a regression test).
- [ ] `scripts/sync_readme_version.sh --check` passes.
- [ ] `dart analyze --fatal-infos --fatal-warnings` reports zero issues.

### Open Questions

- Should the CI non-AL32UTF8 job block `main` (added to the required set), or run as a non-blocking / `workflow_dispatch`-gated job given the gvenzl cold-start + CSALTER-migration cost? Recommendation: start non-blocking or dispatch-gated, measure reliability over a few runs, and promote to required only if it is consistently green inside the timeout — document the choice either way (satisfies AC3's "gate + document").
- For the CI fixture, prefer (a) `docker run` gvenzl/oracle-free with the bind-mounted init SQL, or (b) `docker exec` the migration into a running container? Both reproduce the local fixture; (a) is the closest mirror of the compose service and is the recommended default.

## Dev Agent Record

### Agent Model Used

claude-opus-4-8 (Opus 4.8, 1M context) — bmad-dev-story workflow

### Debug Log References

- No defects surfaced. This is a docs + CI + dual-env-confirmation closeout with
  **zero** production-code changes (`git status lib/` empty throughout).
- Resolved both **Open Questions** during implementation:
  - *Block `main` vs. gated?* → Gated to `workflow_dispatch` (manual). The
    gvenzl cold-start + CSALTER migration is slower/less proven on GitHub Actions
    than the AL32UTF8 service jobs; per architecture's binding rule ("gate it if
    it can't be made reliable, and document the gap"), it is non-blocking and
    documented in four places (CI comment, README Tests, CONTRIBUTING, compose).
  - *`docker run` vs `docker exec`?* → `docker run` gvenzl/oracle-free with the
    bind-mounted init SQL (the recommended default — closest mirror of the local
    compose service).
- CI readiness: the shared `ci_wait_for_oracle.sh` budgets only ~10 min and its
  single-port assumption (host==container port) does not fit a `docker run -p`
  fixture. Rather than touch a script shared with the blocking jobs (AC6), the
  job uses a self-contained 25-min wait loop (`docker exec` sqlplus on the
  container's internal 1521) that also asserts the migrated charset is
  `WE8MSWIN1252` — a second guard alongside the suite's own Story 10.3 AC1 check.

### Completion Notes List

**A. Scope held to docs + CI (AC6).** No edits under `lib/src/`; the only
code-adjacent change to `docker-compose.yml` is comment-only (verified by diff —
every changed line begins with `#`). Charset/national/codec behavior is exactly
as Stories 10.1–10.4 left it.

**B. README support matrix (AC1/AC2).** New `## Character Set Support` section
describes the **functional** outcome — UTF-8 wire + Oracle server-side conversion
for the database charset (`AL32UTF8` and non-`AL32UTF8`/`WE8MSWIN1252`),
`AL16UTF16` national support for `NCHAR`/`NVARCHAR2`/`NCLOB`, fail-loud on
unsupported national charsets, and thin-model boundaries (no `NLS_LANG`, no client
codec). Deliberately avoids the original (wrong) "negotiate 2000" wire framing
per the Story 10.4 review. Stale claims corrected: Known Limitations charset
bullet, the LOB-section NCLOB line, the data-type table (national row + cross-link),
and the roadmap (added a Done row; dropped the Planned-After-1.0 charset entry and
renumbered).

**C. CI fixture wired and gated (AC3).** Added `integration-non-al32utf8` —
`workflow_dispatch`-only, `docker run` of gvenzl/oracle-free + the bind-mounted
`non_al32utf8_setup.sql` after checkout, a charset-asserting wait loop, then the
focused suite with `ORACLE_NON_AL32UTF8_*` env. Can never silently pass (charset
assertion + suite AC1 guard). Existing jobs/triggers/concurrency preserved.

**D. Dual-env validation (AC4) — all green, no regression.**
- Full integration **Oracle 23ai** (1521/FREEPDB1): 421 passed / 28 skipped.
- Full integration **Oracle 21c** (1522/XEPDB1): 422 passed / 27 skipped.
- Focused **non-AL32UTF8** suite (1523/we8pdb1, `WE8MSWIN1252`): 20 passed.
- Skip counts (28/27) match the established TLS-only baseline exactly; the
  charset_capability / charset_negotiation / nchar suites ran without skips.

**E. Gates (AC7).** `scripts/sync_readme_version.sh --check` → matches 1.1.0;
`dart analyze --fatal-infos --fatal-warnings` → "No issues found!"; CI YAML parses
well-formed.

### File List

Docs:
- `README.md` — new `## Character Set Support` section; data-type table split into `VARCHAR2, CHAR` + national `NCHAR, NVARCHAR2, NCLOB` rows with cross-links; corrected the LOB-section NCLOB line, the Known Limitations charset bullet, the Project Status table (added Done row), and the Planned-After-1.0 table (removed charset, renumbered); added the non-AL32UTF8 fixture command to the Tests section.
- `CONTRIBUTING.md` — new "### Non-AL32UTF8 character set fixture" subsection (bring-up, port 1523/we8pdb1, `RUN_NON_AL32UTF8_TESTS`, `ORACLE_NON_AL32UTF8_*` overrides table, why CI is manual-only).

CI / fixtures:
- `.github/workflows/ci.yml` — added `workflow_dispatch` trigger and the gated `integration-non-al32utf8` job (docker run + bind-mounted init SQL, charset-asserting wait loop, focused suite, log dump).
- `docker-compose.yml` — comment-only: updated the `oracle-non-al32` block header to record the CI wiring decision (manual `workflow_dispatch` job).

Sprint tracking:
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `10-5-docs-ci-fixture`: ready-for-dev → in-progress → review.
- `_bmad-output/implementation-artifacts/10-5-docs-ci-fixture.md` — this story file (tasks checked, DAR/File List/Change Log, Status → review).

### Review Findings

- [x] [Review][Patch] Stale comment in `non_al32utf8_setup.sql` — lines 22–23 say "CI wiring and the README support matrix remain Story 10.5" but Story 10.5 is now done [`test/integration/fixtures/non_al32utf8_setup.sql:22`]
- [x] [Review][Patch] CI readiness loop missing `set -e`/`pipefail` — `set -u` is set but not `set -e` or `set -o pipefail`; a container crash causes the loop to spin all 50 iterations (25 min) before failing rather than surfacing immediately [`.github/workflows/ci.yml`, step `Wait for we8pdb1 readiness`]
- [x] [Review][Patch] CLOB row in README data types table has no cross-reference to the new Character Set Support section — the section groups VARCHAR2/CHAR/CLOB together, but only the VARCHAR2/CHAR row was updated with the `#character-set-support` link [`README.md`, Supported Data Types table]
- [x] [Review][Patch] CONTRIBUTING.md calls the fixture "optional, local-only" but the next section describes a CI job — contradictory label; should be "optional, local/CI-manual fixture" or similar [`CONTRIBUTING.md`, Non-AL32UTF8 section intro]
- [x] [Review][Defer] `gvenzl/oracle-free:latest` unpinned tag in CI job — inconsistent with oracle-21c's use of `gvenzl/oracle-xe:21`; reproducibility risk [`.github/workflows/ci.yml`, `docker run` step] — deferred, pre-existing style choice (compose also uses latest); out of scope for docs closeout
- [x] [Review][Defer] Port-1521 conflict if `integration-non-al32utf8` is promoted to required check — CI comment warns about it and the promotion path is not imminent [`.github/workflows/ci.yml`] — deferred, acknowledged design decision; promotion requires explicit redesign

### Change Log

| Date       | Change |
|------------|--------|
| 2026-06-25 | Epic 10 closeout (docs + CI fixture + dual-env confirmation). README: added "Character Set Support" support matrix and corrected all stale charset claims (Known Limitations, LOB/NCLOB, data-type table, roadmap). CI: added a `workflow_dispatch`-gated `integration-non-al32utf8` job (real `WE8MSWIN1252` DB via `docker run` + init SQL; charset-asserting; never silently passes). CONTRIBUTING: documented the local-only non-AL32UTF8 fixture. Dual-env re-validated: 23ai 421/28-skip, 21c 422/27-skip, non-AL32UTF8 20/20 — zero production-code changes. `dart analyze` clean; version-sync passes. Status → review. |
