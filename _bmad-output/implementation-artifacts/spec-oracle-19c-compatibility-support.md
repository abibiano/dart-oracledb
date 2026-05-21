---
title: 'Oracle 19c Compatibility Support'
type: 'feature'
created: '2026-05-21'
status: 'partially-done'
status_reason: 'Code changes shipped (version gates, env normalization), but the spec was never validated against a real pre-23 Oracle container because the referenced image (gvenzl/oracle-xe:19) does not exist on Docker Hub. Subsequent validation against gvenzl/oracle-xe:21 revealed a deeper FAST_AUTH protocol incompatibility — no integration test can even authenticate against pre-23 Oracle. See Known Issues below.'
baseline_commit: '211cbd03e8bb3c6df1514c5efb6ef085e224b799'
context:
  - '_bmad-output/project-context.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** dart-oracledb only runs against Oracle 23ai. Two 23ai-specific protocol assumptions — unconditional 23.4 vector field reads in `_processColumnInfo` and the 0x0800 END_OF_RPC data flag in `sendData()` — will corrupt result-set parsing and potentially hang DML on Oracle 19c. Additionally, five integration test files hardcode `FREEPDB1`, making them unreachable against Oracle 19c's `XEPDB1` service.

**Approach:** Persist the negotiated Oracle server major version from protocol negotiation in Transport; gate both 23ai-specific behaviors behind version checks; centralize integration test connection parameters to read from env vars; add an Oracle 19c (`gvenzl/oracle-xe:19`) environment to both `docker-compose.yml` and CI. Fix any additional bugs discovered when tests run against Oracle 19c.

## Boundaries & Constraints

**Always:**
- All existing 38 Oracle 23ai integration tests and 462 unit tests must continue to pass unchanged.
- Use `gvenzl/oracle-xe:19` (community image, no registry auth required) for Oracle 19c Docker; PDB service name is `XEPDB1`.
- Integration test env var defaults must remain compatible with the existing `docker-compose.yml` setup (port 1521, service `FREEPDB1`, user `system`, password `testpassword`).
- Zero `dart analyze` warnings.

**Ask First:**
- If integration tests reveal Oracle 19c failures beyond the two known protocol issues (0x0800 flag, 23.4 vector reads), halt and report before expanding fix scope.
- If `protocolResponse.serverVersion` format is ambiguous or not suitable for major-version extraction, halt and ask before proceeding.

**Never:**
- Change Oracle 23ai connection or query behavior.
- Add dedicated Oracle 11g or 12c support (beyond what falls out naturally from the version gates).
- Replace the auth flow or the integration test framework.
- Require Oracle container registry credentials for the 19c CI job.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| SELECT on Oracle 19c | Connected to `gvenzl/oracle-xe:19`, `SELECT 1 FROM DUAL` | Returns row `{1}`, no corruption | — |
| DML on Oracle 19c | `INSERT INTO t VALUES (1)` against 19c | `rowsAffected = 1`, no hang | Constraint violation returns OracleException |
| Tests with `ORACLE_SERVICE=XEPDB1` | All integration tests with env override | Tests connect to XEPDB1 and pass | — |
| Tests without env vars | Integration tests run against defaults | Fall back to `FREEPDB1`/localhost/1521 | — |
| SELECT on Oracle 23ai after version gates added | Existing baseline | 38 integration tests pass, no regression | — |

</frozen-after-approval>

## Code Map

- `lib/src/transport/transport.dart` -- `sendFastAuth()` captures `protocolResponse.serverVersion` but discards it; `sendData()` unconditionally applies the 0x0800 END_OF_RPC flag
- `lib/src/protocol/messages/execute_message.dart:635-638` -- `_processColumnInfo` unconditionally reads 3 Oracle 23.4 vector fields (6 bytes total) regardless of server version
- `lib/src/protocol/constants.dart` -- Existing TTC field version constants; needs `ttcCcapFieldVersion23_4` threshold added
- `test/integration/auth_integration_test.dart` -- Reference: already reads all Oracle env vars (`ORACLE_HOST`, `ORACLE_PORT`, `ORACLE_SERVICE`, `ORACLE_USER`, `ORACLE_PASSWORD`); match this pattern for the helper
- `test/integration/test_helper.dart` -- Does not exist; create here
- `test/integration/query_integration_test.dart` -- Hardcodes `FREEPDB1` (3 occurrences)
- `test/integration/connection_integration_test.dart` -- Hardcodes `FREEPDB1` (7+ occurrences)
- `test/integration/security_test.dart` -- Hardcodes `FREEPDB1` (1 const)
- `test/integration/minimal_auth_test.dart` -- Hardcodes `FREEPDB1` (1 const)
- `test/integration/test_wrong_password.dart` -- Hardcodes `FREEPDB1` (1 const)
- `docker-compose.yml` -- Current 23ai service on port 1521; needs 19c service added
- `.github/workflows/ci.yml` -- Current `integration` job targets Oracle 23ai; needs `integration-19c` job added

## Tasks & Acceptance

**Execution:**
- [x] `lib/src/transport/transport.dart` -- In `sendFastAuth()` and `sendProtocolNegotiation()`, extract Oracle server major version from the protocol response banner and store as `int _serverMajorVersion` field; expose as getter. Default `_serverMajorVersion` to `23`. In `sendData()`, only set `_tnsDataFlagsEndOfRpc` (0x0800) when `_serverMajorVersion >= 23`; use `0x0000` otherwise. **CRITICAL: Bootstrap `sendData` calls inside `sendProtocolNegotiation` and `sendFastAuth` (the outbound request packets, sent before the server version is known) must pass explicit `dataFlags: 0x0000` at those call sites.** The version-gated default in `sendData` applies only to post-negotiation calls (execute, commit, rollback, fetch).
- [x] `lib/src/protocol/constants.dart` -- Add `ttcCcapFieldVersion23_4` constant: the minimum `_ttcFieldVersion` value negotiated from Oracle 23.4+ servers (cross-reference node-oracledb capability constants to determine the exact value).
- [x] `lib/src/protocol/messages/execute_message.dart:635-638` -- Wrap the three 23.4 vector field reads (`skipUB4` + two `skipUint8`) behind a version gate: only execute when the negotiated `_ttcFieldVersion >= ttcCcapFieldVersion23_4`. The field version is already tracked on Transport — expose it as a getter and thread it into the decode path (passed as parameter or via connection context; do not create a new Transport dependency in ExecuteMessage).
- [x] `test/integration/test_helper.dart` (new) -- Create shared helper reading `ORACLE_HOST` (default `localhost`), `ORACLE_PORT` (default `1521`), `ORACLE_SERVICE` (default `FREEPDB1`), `ORACLE_USER` (default `system`), `ORACLE_PASSWORD` (default `testpassword`); expose as top-level getters or a `TestConfig` class. Pattern: match `auth_integration_test.dart`'s env-reading approach.
- [x] `test/integration/query_integration_test.dart`, `connection_integration_test.dart`, `security_test.dart`, `minimal_auth_test.dart`, `test_wrong_password.dart` -- Replace all hardcoded `FREEPDB1` / `localhost` / `1521` / `system` / `testpassword` literals with references to the test helper. Do not change test logic.
- [x] `docker-compose.yml` -- Add `oracle19c` service: image `gvenzl/oracle-xe:19`, profile `oracle19c`, host port `1522:1521` (avoids collision with 23ai on 1521), env `ORACLE_PASSWORD=testpassword`, healthcheck `sqlplus -L system/testpassword@//localhost:1521/XEPDB1`, `start_period: 300s`.
- [x] `.github/workflows/ci.yml` -- Add `integration-19c` job: `gvenzl/oracle-xe:19` service container (no registry credentials required), `ORACLE_SERVICE=XEPDB1`, `ORACLE_PORT=1521`, same `RUN_INTEGRATION_TESTS=true dart test --tags=integration` command as the `integration` job, `timeout-minutes: 20`.
- [x] `test/integration/tls_integration_test.dart` -- Replace hardcoded `FREEPDB1`/`localhost`/`1521`/`system`/`testpassword` literals (3 occurrences) with references to test helper. Same pattern as the 5 files above.
- [x] `test/integration/test_helper.dart` -- Change `int.parse(...)` for `ORACLE_PORT` to `int.tryParse(...) ?? 1521` to avoid a `FormatException` crash on malformed env input.

**Acceptance Criteria:**
- Given Oracle 19c is running (`docker-compose --profile oracle19c up -d`), when `ORACLE_SERVICE=XEPDB1 ORACLE_PORT=1522 RUN_INTEGRATION_TESTS=true dart test --tags=integration` runs, then all integration tests pass with no failures.
- Given no env vars set, when `RUN_INTEGRATION_TESTS=true dart test --tags=integration` runs against the existing Oracle 23ai container (port 1521), then all 38 integration tests still pass.
- Given `dart analyze` runs, then zero warnings or errors.
- Given `dart test --exclude-tags=integration` runs, then 462+ unit tests pass.
- Given the CI `integration-19c` job runs, then it completes within 20 minutes and fails the build on any integration test failure.

## Design Notes

**Server major version extraction:** `protocolResponse.serverVersion` is captured in `sendFastAuth()` but currently unused. Parse the Oracle version to extract the major number (e.g. `19` from `"19.0.0.0.0"` or from an integer encoding). If parsing is ambiguous, default to `23` rather than `0` so that pre-negotiation sends keep the 23ai-safe flags.

**Accessing `_ttcFieldVersion` from `execute_message.dart`:** `_ttcFieldVersion` is private to Transport. Expose it as a public getter. Thread it into the `_processColumnInfo` decode path as a parameter rather than creating a Transport import in ExecuteMessage — this keeps the message layer stateless.

**gvenzl image differences from official Oracle image:** `gvenzl/oracle-xe:19` uses `ORACLE_PASSWORD` (not `ORACLE_PWD`). The sys and system password is the value of `ORACLE_PASSWORD`. No characterset env needed for standard Latin-1 test data.

## Verification

**Commands:**
- `dart analyze` -- expected: No issues found
- `dart test --exclude-tags=integration` -- expected: 462+ passed, 0 failed
- `RUN_INTEGRATION_TESTS=true dart test --tags=integration` -- expected: 38 passed against Oracle 23ai on default port 1521
- `ORACLE_SERVICE=XEPDB1 ORACLE_PORT=1522 RUN_INTEGRATION_TESTS=true dart test --tags=integration` -- expected: all integration tests pass against Oracle 19c (requires `docker-compose --profile oracle19c up -d`)

## Spec Change Log

- **2026-05-21 (loop 1):** Finding: `sendData()` bootstrap calls inside `sendProtocolNegotiation` and `sendFastAuth` are made before `_serverMajorVersion` is set from the server response — so they always send `0x0800` regardless of Oracle version, defeating the version gate for those initial packets. Amended: task 1 now requires explicit `dataFlags: 0x0000` at bootstrap call sites; the version-gated default applies only post-negotiation. Known-bad state avoided: Oracle 19c receiving `0x0800` on the FAST_AUTH/protocol-negotiation packets. KEEP: `_serverMajorVersion` field (default 23), getter, `_extractMajorVersion()` function, version-gated `sendData` default, `ttcFieldVersion` getter — all correct. KEEP: tasks 2–7 unchanged. Added patch tasks: `tls_integration_test.dart` (missed in initial impl) and `test_helper.dart` `int.tryParse` fix.

- **2026-05-21 (post-Story-2.5 investigation):** Finding: `gvenzl/oracle-xe:19` does not exist on Docker Hub — the `gvenzl/oracle-xe` repo publishes only 21c, 18c, and 11g tags (verified via `https://hub.docker.com/v2/repositories/gvenzl/oracle-xe/tags?name=19` → `count: 0` and the maintainer's repo description: *"Oracle Database XE (21c, 18c, 11g) for everyone!"*). Every `integration-19c` CI run since the spec was committed has failed at image pull with `manifest unknown`. The spec was marked done because the *code* changes (version gates, env normalization) were complete, but actual validation against a pre-23 container never happened. Amended: switched image to `gvenzl/oracle-xe:21` everywhere — `docker-compose.yml` service renamed `oracle19c → oracle21c` (profile and service), and CI job renamed `integration-19c → integration-21c`. 21c is the closest available community image and exercises the same pre-23 code path (`_serverMajorVersion < 23` branch) that 19c would. The connection params (port 1522 host-side / 1521 in-container, service `XEPDB1`, no registry creds) are unchanged. Original spec intent (validating non-23ai protocol paths) is preserved; the "19c" framing is no longer literally accurate.

## Known Issues

**Status was reopened from `done` → `partially-done` on 2026-05-21 (post-Story-2.5 investigation).**

### 1. Spec was never actually validated against pre-23 Oracle

The original `done` mark was based on code review and 23ai regression passing — not on the spec's own verification command:

```
ORACLE_SERVICE=XEPDB1 ORACLE_PORT=1522 RUN_INTEGRATION_TESTS=true dart test --tags=integration
```

That command never produced a green run, because the referenced image (`gvenzl/oracle-xe:19`) does not and never has existed on Docker Hub. Every CI run of the `integration-19c` job since the spec landed has failed at `docker pull` with `manifest unknown`. The image has since been swapped to `gvenzl/oracle-xe:21` (closest available community image; see Spec Change Log entry from 2026-05-21 post-Story-2.5).

### 2. FAST_AUTH does not work against pre-23 Oracle (blocking)

Once the image was switched to `gvenzl/oracle-xe:21` and the container was running healthy, the integration suite was executed with `ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1`. **Every test failed at connection setup** with:

```
OracleException: ORA-12150: Connection closed by server while waiting for data: need 8 bytes, have 0
  package:oracledb/src/transport/transport.dart 653:26  Transport.sendFastAuth
```

The Oracle 21c server closes the TCP connection during the FAST_AUTH exchange. FAST_AUTH is an Oracle 23ai-era protocol affordance that pre-23 servers do not recognize. The version gates this spec added (`_serverMajorVersion < 23` for the `0x0800` flag, `_ttcFieldVersion < 24` for the 23.4 vector fields) address *visible* code paths that diverge after the connection is established — they do not help if the connection never gets that far.

**What's needed (out of scope for this spec):** implement a classical `AUTH_PHASE_ONE` / `AUTH_PHASE_TWO` fallback path that triggers when the server signals it does not support FAST_AUTH (or, equivalently, gate FAST_AUTH itself behind `_serverMajorVersion >= 23` after a pre-auth protocol probe). Track in a new spec — do not retrofit into this one.

### 3. CI `integration-21c` job will continue to fail until #2 is fixed

The job now successfully pulls the image and the container boots, but every test fails at `sendFastAuth`. This is a known-bad state and a useful waypoint — it surfaces the real protocol problem instead of masking it behind an image-pull error. Do not green-wash the failure; leave the job red until the auth fallback lands.

### 4. Acceptance criteria revisited

| Original AC | Actual status |
|-------------|---------------|
| "All integration tests pass against Oracle 19c (XEPDB1, port 1522)" | **Not met.** Cannot authenticate. |
| "All 38 23ai integration tests still pass" | **Met.** No regression. |
| "Zero `dart analyze` warnings" | **Met.** |
| "462+ unit tests pass" | **Met.** |
| "CI `integration-19c` job completes within 20 minutes and fails on integration test failure" | **Not met.** Now renamed `integration-21c`; job runs but fails on auth, as described above. |

## Suggested Review Order

**Protocol version detection and 0x0800 flag gate**

- Version field and `_extractMajorVersion`: where the server banner is parsed into a major int.
  [`transport.dart:60`](../../lib/src/transport/transport.dart#L60)

- `sendData` default: version-gated flag; 23ai gets `0x0800`, pre-23ai gets `0x0000`.
  [`transport.dart:1388`](../../lib/src/transport/transport.dart#L1388)

- `sendProtocolNegotiation` bootstrap override: explicit `0x0000` before version is known.
  [`transport.dart:591`](../../lib/src/transport/transport.dart#L591)

- `sendFastAuth` bootstrap override and version store after response.
  [`transport.dart:645`](../../lib/src/transport/transport.dart#L645)

- `sendProtocolNegotiationMinimal` bootstrap override: same pattern, minimal path.
  [`transport.dart:815`](../../lib/src/transport/transport.dart#L815)

**Column metadata 23.4 vector field gate**

- Threshold constant: `ttcCcapFieldVersion23_4 = 24` from node-oracledb reference.
  [`constants.dart:302`](../../lib/src/protocol/constants.dart#L302)

- Guard wrapping the three unconditional 23.4 skip calls; only reads fields on 23.4+ servers.
  [`execute_message.dart:636`](../../lib/src/protocol/messages/execute_message.dart#L636)

**Integration test env-var normalization**

- New shared helper: all Oracle connection params read from env with FREEPDB1/1521 defaults.
  [`test_helper.dart:10`](../../test/integration/test_helper.dart#L10)

**Infrastructure: Oracle 19c Docker and CI**

- `docker-compose.yml` `oracle19c` profile service on port 1522 using `gvenzl/oracle-xe:19`.
  [`docker-compose.yml:28`](../../docker-compose.yml#L28)

- CI `integration-19c` job: community image, no registry auth, `ORACLE_SERVICE=XEPDB1`.
  [`.github/workflows/ci.yml:164`](../../.github/workflows/ci.yml#L164)
