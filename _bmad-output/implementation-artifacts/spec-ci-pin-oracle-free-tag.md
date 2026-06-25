---
title: 'Pin gvenzl/oracle-free image tag in the integration-non-al32utf8 CI job'
type: 'ci'
created: '2026-06-25'
status: 'done'
baseline_commit: 'adf690d96227f4af6e4b3e9ad56128688e0441a6'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Deferred-work concern (item 1, "## Deferred from: code review of
10-5-docs-ci-fixture (2026-06-25)"):** "`gvenzl/oracle-free:latest` unpinned tag
in `integration-non-al32utf8` CI job — inconsistent with oracle-21c's pinned
`gvenzl/oracle-xe:21`; reproducibility risk if a new Oracle Free release changes
init behavior. Pin to a specific tag (e.g. `gvenzl/oracle-free:23-slim`) when the
job proves stable."

**Goal:** Pin the floating `:latest` image tag used by the
`integration-non-al32utf8` CI job to a specific, stable tag, consistent with how
the `integration-21c` job pins `gvenzl/oracle-xe:21`. CI-config-only change — no
Dart code, no protocol behavior. The point is reproducibility: a future Oracle
Free release pushed to `:latest` must not be able to silently change the
first-boot / CSALTER charset-migration init behavior under this job.

</frozen-after-approval>

## The finding (exact file / line / job)

- **File:** `.github/workflows/ci.yml`
- **Job:** `integration-non-al32utf8` ("Non-AL32UTF8 Charset Fixture
  (WE8MSWIN1252, manual)", gated to `workflow_dispatch`).
- **Step:** "Launch WE8MSWIN1252 fixture (gvenzl/oracle-free + CSALTER init)".
- **Offending line (pre-change, line 292):** the `docker run` ends with
  `gvenzl/oracle-free:latest` — confirmed to be the floating `:latest` tag, and
  the ONLY `gvenzl/oracle-free` image reference in the file.
- **Convention to match:** the `integration-21c` job's `services.oracle.image`
  pins `gvenzl/oracle-xe:21` (a major-version pin), line 202. The pre-23 fixture
  is pinned; the non-AL32UTF8 fixture was not — the exact inconsistency the item
  flags.

The local `docker-compose.yml` `oracle-non-al32` service (line 113) ALSO uses
`gvenzl/oracle-free:latest`; that is the local development fixture and is out of
scope for this CI-job item (left untouched).

## Chosen tag + rationale

**Pinned to `gvenzl/oracle-free:23-slim`.**

- **Matches the locally-validated version.** The running local fixture container
  (`oracle-non-al32`, launched from the same gvenzl image + the same
  `non_al32utf8_setup.sql` init) reports `VERSION_FULL = 23.26.2.0.0`, i.e. the
  Oracle Free **23ai** line. Pinning to the `23` major version tracks exactly
  what is validated locally, while still receiving 23.x patch images (same init
  behavior, no surprise major-version jump).
- **Mirrors the 21c convention.** `integration-21c` pins the major version
  (`gvenzl/oracle-xe:21`); `23-slim` likewise pins the major version (`23`) for
  `gvenzl/oracle-free`, restoring cross-job consistency.
- **`-slim` is the deliberate lighter CI variant** — it omits the bundled sample
  schemas this fixture does not need (the job only creates+migrates a fresh
  `we8pdb1` PDB), is published multi-arch (`23-slim-amd64` / `23-slim-arm64`;
  `ubuntu-latest` runners are amd64), and shares the identical
  `/container-entrypoint-initdb.d` first-boot init path that the bind-mounted
  `non_al32utf8_setup.sql` relies on. It is also the item's own suggested tag.
- Available stable tags inspected on Docker Hub for `gvenzl/oracle-free`:
  `23`, `23-slim`, `23-full`, dated variants (`23.26.2`, ...), plus
  `latest`/`slim`/`full`. `23-slim` is the most specific stable tag that both
  matches the locally-validated major version and is the lighter CI choice;
  preferred over a dated pin (`23.26.2-slim`) so the job stays on 23.x security
  patches without manual bumps, and over `23-full` (heavier, unneeded schemas).

A clarifying comment was added above the step explaining the pin and the `-slim`
choice, cross-referencing the `integration-21c` pin.

## Acceptance Criteria

- **AC1 — Tag pinned.**
  - GIVEN the `integration-non-al32utf8` job's `docker run` previously used
    `gvenzl/oracle-free:latest`,
  - WHEN the workflow is inspected,
  - THEN the image is `gvenzl/oracle-free:23-slim` and no `:latest` reference for
    that image remains in the file.

- **AC2 — Consistent with the 21c pin convention.**
  - GIVEN `integration-21c` pins `gvenzl/oracle-xe:21` (major version),
  - WHEN the non-AL32UTF8 job's image is compared,
  - THEN it is pinned to the `23` major version (`23-slim`), matching the
    pin convention and the Oracle Free version validated locally.

- **AC3 — YAML well-formed.**
  - GIVEN the edited `.github/workflows/ci.yml`,
  - WHEN parsed with `python3 -c "import yaml; yaml.safe_load(open(...))"`,
  - THEN it loads without error (no syntax breakage).

- **AC4 — No behavior change beyond the tag.**
  - GIVEN the job otherwise unchanged,
  - WHEN the step is reviewed,
  - THEN only the image tag (and an explanatory comment) changed; the `docker
    run` flags, bind mount, ports, env, and the readiness/charset-assert step
    are untouched. CI is not triggered as part of this change.

## Validation performed

- `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"` →
  **`ci.yml: YAML OK`**.
- `grep -n "gvenzl/oracle-free:" .github/workflows/ci.yml` → single match,
  `gvenzl/oracle-free:23-slim` (no `:latest` for that image remains).
- Local fixture version confirmed as 23.26.2.0.0 (informs the `23` major pin).
- CI NOT triggered; nothing pushed (per task constraints).

## Out of scope (left untouched, by instruction)

- The SECOND item in the same deferred-work section (host port-1521 conflict if
  `integration-non-al32utf8` is promoted to a required check) — handled
  separately.
- `docker-compose.yml` `oracle-non-al32` local fixture still uses `:latest`
  (local-dev convenience, not the CI reproducibility surface this item targets).
