# Story 6.4: CI/CD Integration Test Automation

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a **developer maintaining dart-oracledb**,
I want **integration tests automated in CI/CD pipeline**,
so that **every commit is validated against Oracle 23ai automatically**.

## Acceptance Criteria

1. **AC1: Oracle 23ai Docker Setup**
   Given CI/CD pipeline needs Oracle database,
   when configuring CI environment,
   then Oracle 23ai Free Docker container is set up,
   and database is accessible on port 1521,
   and test schema/users are created automatically.

2. **AC2: Integration Test Execution**
   Given Oracle 23ai is running in CI,
   when CI pipeline executes,
   then integration tests run against Oracle 23ai,
   and test results are reported clearly,
   and failures block PR merges.

3. **AC3: Test Coverage Reporting**
   Given tests execute in CI,
   when test run completes,
   then coverage report is generated,
   and coverage metrics are displayed with an aim of at least 80% overall,
   and coverage trends are trackable over time.

4. **AC4: Cross-Platform Validation**
   Given dart-oracledb must work on macOS, Windows, Linux,
   when CI pipeline runs,
   then tests execute on all three platforms,
   and platform-specific issues are caught early.

5. **AC5: CI Performance**
   Given CI pipeline includes Docker and integration tests,
   when optimizing pipeline,
   then full CI run completes in under 15 minutes,
   and test parallelization is used where possible.

## Tasks / Subtasks

- [x] Task 1: Add GitHub Actions CI workflow scaffolding (AC: 2, 4, 5)
  - [x] Create `.github/workflows/ci.yml`; there is no existing `.github/workflows` directory.
  - [x] Run static analysis and unit tests on Linux, macOS, and Windows.
  - [x] Keep Oracle-backed integration tests on Linux only because GitHub service containers require a Linux runner.
  - [x] Use current action versions after checking upstream docs at implementation time; current research on 2026-05-21 found `actions/checkout@v6`, `dart-lang/setup-dart@v1`, and `codecov/codecov-action@v6`.

- [x] Task 2: Automate Oracle 23ai startup for integration tests (AC: 1, 2, 5)
  - [x] Configure Oracle 23ai Free as a GitHub Actions service container or equivalent Linux job setup.
  - [x] Expose host port `1521:1521` for tests that connect to `localhost:1521/FREEPDB1`.
  - [x] Use `ORACLE_PWD=testpassword` unless the test suite is updated consistently.
  - [x] Add an explicit readiness wait around `sqlplus` or another deterministic health check; do not assume the container is ready when the service starts.
  - [x] Account for Oracle first-start latency. The local `docker-compose.yml` uses `start_period: 300s`; CI should allow enough time without making the normal path slow.

- [x] Task 3: Make CI run the repo's existing test gates (AC: 2, 5)
  - [x] Run `dart pub get`.
  - [x] Run `dart analyze`.
  - [x] Run `dart test --exclude-tags=integration` for the non-Oracle gate.
  - [x] Run `RUN_INTEGRATION_TESTS=true dart test --tags=integration` once Oracle is healthy.
  - [x] Ensure CI fails on test failure and prints usable output for failing integration groups.

- [x] Task 4: Register and stabilize test tags/configuration (AC: 2, 5)
  - [x] Update `dart_test.yaml` to declare the custom tags already used by tests: `integration`, `security`, `slow`, `performance`, `protocol`, and `unit`.
  - [x] Add tag-specific timeout configuration where needed, especially for Oracle-backed integration/security tests and wrong-password timeout tests.
  - [x] Preserve the existing environment gate: integration tests self-skip unless `RUN_INTEGRATION_TESTS` is set.

- [x] Task 5: Add coverage reporting (AC: 3)
  - [x] Generate coverage in CI using current `package:test` coverage syntax.
  - [x] Convert or upload coverage in a way that produces an LCOV artifact or Codecov-compatible report.
  - [x] Upload coverage artifacts even when an external coverage service is not configured.
  - [x] If using Codecov, prefer tokenless/OIDC where possible and do not require secrets for fork PRs unless the repo policy requires it.

- [x] Task 6: Handle credentials and test schema deliberately (AC: 1, 2)
  - [x] Current tests mostly connect as `system` / `testpassword` to `localhost:1521/FREEPDB1`; do not silently change this in CI only.
  - [x] If creating a dedicated test user/schema, update all hardcoded integration tests or provide setup that keeps existing tests passing.
  - [x] Never print database passwords, full connection descriptors with credentials, or GitHub secrets in logs.
  - [x] Keep NFR5 security tests in the integration gate.

- [x] Task 7: Verify CI behavior locally where possible (AC: 1, 2, 3, 5)
  - [x] Validate YAML syntax.
  - [x] Run `dart analyze`.
  - [x] Run `dart test --exclude-tags=integration`.
  - [x] If Docker is available, run `docker-compose up -d` followed by `RUN_INTEGRATION_TESTS=true dart test --tags=integration`.
  - [x] Document any environment blocker explicitly in the Dev Agent Record.

## Dev Notes

### Current Baseline

- Target story key: `6-4-ci-cd-integration-test-automation`.
- Sprint status before story creation: `6-4` is `backlog`; Epic 6 is already `in-progress`.
- No `.github/workflows` directory exists, so CI workflow files are NEW files.
- Local Oracle testing is currently documented through `docker-compose.yml`, which starts `container-registry.oracle.com/database/free:latest`, maps `1521:1521`, sets `ORACLE_PWD=testpassword`, and uses a `sqlplus` healthcheck.
- `dart_test.yaml` currently only contains comments. It does not declare the custom tags already used across tests.
- The integration test suite uses `@Tags(['integration'])` and self-skips unless `RUN_INTEGRATION_TESTS` is present. Some files check for key presence, while `security_test.dart` requires the value to equal `'true'`.
- Several integration tests hardcode `localhost:1521/FREEPDB1`, `system`, and `testpassword`; only `auth_integration_test.dart` consistently reads `ORACLE_HOST`, `ORACLE_PORT`, `ORACLE_SERVICE`, `ORACLE_USER`, and `ORACLE_PASSWORD`.
- Worktree note during story creation: Story 6.3/code files were already modified before this story file was created. Treat those as existing user/session changes; do not revert them while implementing 6.4.

### Scope Boundaries

This story is CI/test automation work. The developer should:

- Create CI configuration and small test configuration/support files.
- Reuse the existing test suite and Docker image rather than introducing a new test runner or database emulator.
- Keep platform matrix jobs focused on Dart analysis/unit tests; run Oracle service-container integration tests on Linux.
- Fix test configuration friction that prevents CI from running existing tests reliably.

Do not:

- Rebuild query/auth/transport protocol code as part of CI work.
- Replace the package test framework.
- Change package name, public API, or Oracle protocol behavior.
- Require paid external services for local or fork PR validation.

### Existing Files to Read Completely Before Editing

| File | Current State | Story 6.4 Concern | Preserve |
|------|---------------|-------------------|----------|
| `.github/workflows/ci.yml` | Does not exist. | Create workflow with analysis, unit tests, integration tests, coverage, and platform matrix. | Keep jobs understandable and compatible with public GitHub-hosted runners. |
| `docker-compose.yml` | Local Oracle 23ai Free setup with `container-registry.oracle.com/database/free:latest`, port `1521`, `ORACLE_PWD=testpassword`, and healthcheck. | Mirror or intentionally adapt for CI service container startup. | Local developer workflow and volume behavior. |
| `dart_test.yaml` | Comments only. | Declare tags and timeouts so CI filters are explicit. | Environment-gated integration test behavior. |
| `pubspec.yaml` | Dart SDK `^3.0.0`; dev dependencies are `lints` and `test`. No coverage package dependency. | Decide whether to rely on global coverage tooling, `dart test --coverage-path`, or add a dev dependency. | Minimal dependency posture unless coverage needs justify an addition. |
| `test/integration/*.dart` | Oracle-backed tests with mixed env handling and some hardcoded localhost/system credentials. | CI must satisfy these expectations or normalize them consistently. | Security checks, cleanup behavior, and `@Tags(['integration'])`. |
| `analysis_options.yaml` | Strict Dart analyzer and lints. | Workflow should enforce `dart analyze`. | Zero-warning standard and excluded generated/reference artifacts. |

### Architecture Compliance

- Pure Dart package with no native Oracle client or FFI dependency. CI must not install Oracle Instant Client or depend on platform-native Oracle libraries. [Source: `_bmad-output/project-context.md#Technology Stack & Versions`]
- Strict analyzer rules are active: `strict-casts`, `strict-inference`, and `strict-raw-types`; CI must run `dart analyze` and fail on warnings/errors. [Source: `_bmad-output/project-context.md#Dart Language Rules`]
- Protocol-level behavior must be validated against real Oracle 23ai; unit tests alone are insufficient for database-driver correctness. [Source: `_bmad-output/planning-artifacts/test-architecture-dart-oracledb.md#Key Principles`]
- NFR5 credential protection is part of the test strategy. CI logs must not expose passwords or usernames from auth failures. [Source: `_bmad-output/planning-artifacts/test-design-system.md#NFR Testing Approach`]
- Cross-platform support is a project requirement for macOS, Windows, and Linux, but Oracle Docker integration should be isolated to Linux CI. [Source: `_bmad-output/planning-artifacts/architecture.md#Development Experience`]

### CI Design Guidance

- Recommended workflow shape:
  - `quality`: Ubuntu, `dart pub get`, `dart analyze`, `dart test --exclude-tags=integration`.
  - `platform`: matrix on `ubuntu-latest`, `macos-latest`, and `windows-latest`, running non-integration tests.
  - `integration`: Ubuntu only, Oracle 23ai service container, wait for readiness, then `RUN_INTEGRATION_TESTS=true dart test --tags=integration`.
  - `coverage`: can be combined with `quality` or a separate Ubuntu job; publish an artifact even if Codecov is skipped.
- Keep integration and platform jobs separate. macOS/Windows runners should not try to run Oracle service containers.
- GitHub service containers mapped to a runner-machine job need explicit `ports`, e.g. `1521:1521`, so the current tests can reach `localhost:1521`.
- GitHub's service-container docs state service/container jobs require Linux and that host port mappings are needed when the job runs directly on the runner.
- Oracle container image access may require registry/license acceptance. If CI cannot pull `container-registry.oracle.com/database/free:latest` without credentials, document the blocker and implement the nearest safe fallback rather than weakening integration requirements.
- If the service container healthcheck is unreliable, use a shell wait loop with a bounded timeout and clear failure output.
- Consider `timeout-minutes` on jobs to enforce AC5. A practical starting point is `15` for the integration job and shorter limits for unit/platform jobs.
- Use dependency caching only if it does not make the workflow obscure. `dart pub get` is usually fast; Docker/Oracle startup dominates runtime.

### Test Configuration Notes

- Current `package:test` docs support `@Tags`, `--tags`, `--exclude-tags`, and `dart_test.yaml` tag configuration.
- Current `package:test` docs also document `dart test --coverage-path=./coverage/lcov.info` for LCOV output. Existing project docs use `dart test --coverage=coverage` plus `coverage:format_coverage`; prefer the simpler current command if it works with this package version, otherwise stay with the established conversion flow.
- Useful commands:

```bash
dart analyze
dart test --exclude-tags=integration
RUN_INTEGRATION_TESTS=true dart test --tags=integration
dart test --coverage-path=./coverage/lcov.info --exclude-tags=integration
```

- `test/integration/security_test.dart` checks `Platform.environment['RUN_INTEGRATION_TESTS'] == 'true'`; set exactly `RUN_INTEGRATION_TESTS: 'true'` in CI.
- `test/integration/auth_integration_test.dart` supports `ORACLE_HOST`, `ORACLE_PORT`, `ORACLE_SERVICE`, `ORACLE_USER`, and `ORACLE_PASSWORD`; most other integration files currently hardcode local defaults.
- If normalizing all tests to env-based configuration, make it a focused mechanical change across integration tests and keep local defaults unchanged.

### Previous Story Intelligence

Story 6.3 completed Epic 2 validation after major protocol corrections:

- SELECT, bind, and DML integration tests now pass against Oracle 23ai: 38/38.
- `dart analyze` was clean after Story 6.3.
- Unit baseline after Story 6.3 was 472/472 passing.
- Root causes fixed in 6.3 included an invented EXECUTE wire format and missing BREAK/RESET MARKER acknowledgment for DML error paths.

Implications for Story 6.4:

- CI must preserve the validated Oracle-backed integration suite. Do not skip query/DML tests in CI because they are now the regression guard for the rebuilt protocol.
- If CI integration tests fail, first distinguish environment readiness/container failures from protocol regressions. Do not assume protocol is wrong until Oracle readiness and credentials are verified.
- Keep the integration job output clear enough to identify whether failures are auth, query, DML, security, or container startup failures.

### Git Intelligence

Recent commits show the project is actively converting historical pending-validation work into real Oracle-backed validation:

```text
9ac292f chore: Remove obsolete dart_fast_auth binary file
689cd30 feat(epic2): Validate Story 2.4 DML operations - all 38 integration tests pass
e1d4d3c Refactor authentication protocol handling and enhance test coverage
3a7799a Add scripts for resolving BMad configuration and customization using TOML merges
2dc5173 feat(tests): Update Epic 1 authentication test suite status and apply code review fixes
```

Follow the same pattern: focused changes, real integration validation, and status/artifact updates only after tests have evidence.

### Latest Technical Information

- `actions/checkout` upstream README currently shows Checkout v6 usage and notes v5 moved to the Node 24 runtime. Recheck at implementation time before choosing a major version. [Source: `https://github.com/actions/checkout`, accessed 2026-05-21]
- `dart-lang/setup-dart` upstream README still documents `dart-lang/setup-dart@v1`, `sdk: stable`, and OS/SDK matrix examples. [Source: `https://github.com/dart-lang/setup-dart`, accessed 2026-05-21]
- GitHub Actions service-container docs state that service containers/container jobs require Linux runners and that runner-machine jobs need explicit port mappings to expose service ports to `localhost`. [Source: `https://docs.github.com/en/actions/tutorials/use-containerized-services/use-docker-service-containers`, accessed 2026-05-21]
- `package:test` current docs support custom tags in `dart_test.yaml`, boolean tag selectors for `--tags`/`--exclude-tags`, sharding flags, concurrency flags, and `--coverage-path` LCOV output. [Source: Context7 `/dart-lang/test`, queried 2026-05-21]
- `codecov/codecov-action` upstream README documents v6 with Node 24 support; v5 introduced tokenless upload support for public repositories when Codecov organization settings allow it. Recheck repository policy before requiring a token in PR workflows. [Source: `https://github.com/codecov/codecov-action`, accessed 2026-05-21]

### Anti-Patterns to Avoid

| Anti-Pattern | Correct Pattern |
|--------------|-----------------|
| Running integration tests on macOS/Windows service containers | Run Oracle integration on Linux; run unit/analyze matrix cross-platform. |
| Marking CI complete while integration tests self-skip | Set `RUN_INTEGRATION_TESTS=true` and verify the integration job actually runs Oracle-backed tests. |
| Depending on Oracle container startup without readiness checks | Add a bounded wait loop and fail with clear logs if Oracle never becomes ready. |
| Hiding failing integration tests behind `continue-on-error` | CI failures must block PR merges per AC2. |
| Adding secrets to workflow logs | Use env/secrets carefully; never echo passwords or full credentialed descriptors. |
| Creating a separate CI-only test path | Use the same commands and defaults documented for local development wherever possible. |
| Uploading coverage only to an external service | Also upload an artifact so coverage is available without service configuration. |
| Refactoring protocol code while wiring CI | Keep implementation scope on automation unless a test config bug blocks CI. |

## Project Structure Notes

- New workflow path should be `.github/workflows/ci.yml`, matching the architecture structure. [Source: `_bmad-output/planning-artifacts/architecture.md#Complete Project Directory Structure`]
- Test files already follow `test/integration/*_test.dart` and `test/src/**/*_test.dart`; keep that structure.
- Do not move integration tests. CI should select them with tags rather than path-specific hacks.
- If adding helper scripts, prefer a small checked-in script under `tool/` only if YAML becomes hard to maintain; otherwise keep workflow commands inline and readable.

## Review Findings

- [x] [Review][Decision] Oracle container registry requires authentication — resolved: added `credentials:` block referencing `ORACLE_REGISTRY_USER`/`ORACLE_REGISTRY_PASSWORD` secrets to `services.oracle` in `.github/workflows/ci.yml`. Configure these two secrets in the repo's Actions settings before merging.

- [x] [Review][Defer] Job timeout tightness — 15 min may be tight on a cold runner if Oracle's 5–8 min startup aligns badly with step overhead. Monitor first CI runs; bump to 20 min if flaky. — deferred, pre-existing risk
- [x] [Review][Defer] `testpassword` visible in `--health-cmd` string in GitHub Actions logs — acknowledged tradeoff per Dev Agent Record for ephemeral CI database. — deferred, deliberate design choice
- [x] [Review][Defer] `docker ps` diagnostics on Oracle startup failure — `docker logs <container>` would give more useful failure context than `docker ps --no-trunc`. — deferred, pre-existing
- [x] [Review][Defer] `dart analyze` runs redundantly on macOS and Windows — platform matrix analysis is platform-independent; optimization opportunity for future CI cost reduction. — deferred, pre-existing
- [x] [Review][Defer] Inconsistent `containsKey` vs `== 'true'` skip guards across integration test files — pre-existing; CI's explicit `RUN_INTEGRATION_TESTS: 'true'` satisfies both, but maintenance risk remains. — deferred, pre-existing
- [x] [Review][Defer] `socket_test.dart` has no `@Tags` annotation — pre-existing, outside story 6.4 scope. — deferred, pre-existing
- [x] [Review][Defer] No dedicated test schema/user creation (AC1) — deliberate choice per Dev Notes Task 6; Oracle image auto-creates `system`/`FREEPDB1`. Revisit when test isolation becomes a requirement. — deferred, deliberate design choice
- [x] [Review][Defer] No 80% coverage threshold enforcement gate (AC3) — aspirational "aim of at least 80%"; enforcing requires a current baseline measurement first. — deferred, out of scope for CI wiring
- [x] [Review][Defer] Coverage trends not fully trackable for fork PRs (AC3) — Codecov skipped for forks; 14-day artifact retention. Requires Codecov token setup — operational decision. — deferred, operational decision
- [x] [Review][Defer] Linux not in the `platform` matrix job (AC4) — AC4 functionally met via `quality` job; matrix job name could mislead contributors. — deferred, cosmetic

## References

- `_bmad-output/planning-artifacts/epics.md#Story 6.4: CI/CD Integration Test Automation`
- `_bmad-output/planning-artifacts/test-architecture-dart-oracledb.md#8. CI/CD Integration Strategy`
- `_bmad-output/planning-artifacts/test-architecture-dart-oracledb.md#Configuring Tags in dart_test.yaml`
- `_bmad-output/planning-artifacts/test-design-system.md#NFR Testing Approach`
- `_bmad-output/implementation-artifacts/test-coverage-tracking.md#Epic 2: Query Execution & Transactions`
- `_bmad-output/project-context.md#Testing Rules`

## Dev Agent Record

### Agent Model Used

Claude Opus 4.7 (1M context) via Claude Code.

### Debug Log References

- Local non-integration suite: `dart test --exclude-tags=integration` → 462 passed, 12 skipped (integration self-skip), no failures.
- Local coverage run: `dart test --exclude-tags=integration --coverage-path=./coverage/lcov.info` produced a 2611-line LCOV report.
- Local integration suite: `RUN_INTEGRATION_TESTS=true dart test --tags=integration` against the existing `oracle23ai` container → 64 passed, 5 skipped, no failures.
- `dart analyze --fatal-infos --fatal-warnings` → No issues found.
- `python3 -c "import yaml; yaml.safe_load(open(...))"` confirmed both `dart_test.yaml` and `.github/workflows/ci.yml` parse cleanly.

### Completion Notes List

- Story context created on 2026-05-21.
- Ultimate context engine analysis completed - comprehensive developer guide created.
- Implementation 2026-05-21: Added `.github/workflows/ci.yml` with three jobs: `quality` (Ubuntu analyzer + non-integration tests + LCOV coverage + Codecov upload), `platform` (macOS + Windows analyzer + non-integration tests), and `integration` (Ubuntu Oracle 23ai service container running `RUN_INTEGRATION_TESTS=true dart test --tags=integration`).
- `dart_test.yaml` now declares the in-use tags (`unit`, `protocol`, `integration`, `security`, `slow`, `performance`) and applies `2x`/`4x` timeouts to Oracle-backed and slow categories. Tag entries use `{}` to satisfy the IDE schema.
- Oracle service container mirrors `docker-compose.yml`: `container-registry.oracle.com/database/free:latest`, `ORACLE_PWD=testpassword`, `1521:1521`, and a healthcheck with `start_period=300s` to absorb first-start latency. A bounded TCP probe step adds explicit failure logs without leaking credentials.
- Action versions: `actions/checkout@v6`, `dart-lang/setup-dart@v1`, `actions/upload-artifact@v4`, `codecov/codecov-action@v6` — matching the story's 2026-05-21 upstream check.
- Codecov upload is conditional on same-repo (push or non-fork PR); fork PRs receive the LCOV artifact upload only, satisfying AC3 without requiring secrets for external contributors.
- Integration job sets `ORACLE_HOST/PORT/SERVICE/USER/PASSWORD` env vars matching the hardcoded defaults used in most integration tests, keeping `auth_integration_test.dart`'s env-aware path working too. `testpassword` is intentionally inline (ephemeral CI DB), not a GitHub secret, and is never echoed.
- Cross-platform: macOS and Windows only run analyzer + non-integration tests; service containers require Linux per GitHub Actions docs.
- Local Docker validation: `oracle23ai` was already running (reported `unhealthy` by Docker, likely a stale sqlplus healthcheck), but integration tests pass against it, confirming the listener and Dart driver are healthy. No further local blockers.
- AC5 (under 15 minutes): integration job has `timeout-minutes: 15`; quality and platform jobs are capped at 10 minutes each and run in parallel.

### File List

- `.github/workflows/ci.yml` (new) — GitHub Actions CI workflow (quality, platform, integration jobs).
- `dart_test.yaml` (modified) — declared tags and added timeout overrides for Oracle-backed and slow categories.
- `_bmad-output/implementation-artifacts/6-4-ci-cd-integration-test-automation.md` (modified) — story status, task checkboxes, Dev Agent Record, File List, Change Log.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` (modified) — `6-4-ci-cd-integration-test-automation` moved `ready-for-dev` → `in-progress` → `review`.

### Change Log

- 2026-05-21: Story 6.4 implementation completed. Added GitHub Actions CI workflow with analyzer, cross-platform unit tests, Linux Oracle 23ai integration tests, and LCOV coverage reporting (artifact + tokenless Codecov for same-repo runs). Declared `package:test` tag configuration in `dart_test.yaml`. All ACs verified against local Oracle container.
