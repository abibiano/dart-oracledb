---
title: 'Move integration-non-al32utf8 CI host port off 1521 (defuse latent collision)'
type: 'ci'
created: '2026-06-25'
status: 'done'
baseline_commit: '1fa4545'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Deferred-work concern (item 2, "## Deferred from: code review of
10-5-docs-ci-fixture (2026-06-25)"):** "Port-1521 conflict if
`integration-non-al32utf8` is ever promoted to a required check — the standard
`integration` job also uses host port 1521; concurrent runs on the same runner
would collide. Requires redesigning to use a different host port (e.g. 1523,
matching local compose) before promotion."

**Goal:** Permanently defuse the latent host port-1521 collision between the
manual `integration-non-al32utf8` job and the standard `integration` /
`integration-21c` jobs, so the manual job can later be promoted to a
required/auto check without colliding. CI-config-only change — no Dart code, no
protocol behavior. Prefer the proactive port move (to 1523, matching the local
compose convention) over documentation, since it has zero downside today.

</frozen-after-approval>

## The finding — is the collision reachable today?

**No, not reachable today.** Two independent reasons:

1. **Trigger isolation.** `integration-non-al32utf8` is gated
   `if: github.event_name == 'workflow_dispatch'` (ci.yml line 268). It runs
   ONLY when manually dispatched from the Actions tab. The standard `integration`
   and `integration-21c` jobs run on `push`/`pull_request`. A `workflow_dispatch`
   run and a `push`/`pull_request` run are distinct workflow runs; the manual job
   never co-runs with the standard jobs in the same triggering event.

2. **Runner model.** GitHub-hosted runners are one-job-per-VM: every job in a run
   gets its own fresh `ubuntu-latest` virtual machine. So even the three
   AL32UTF8-era jobs that all declare `1521:1521` (`integration` line 150,
   `integration-21c` line 206) do NOT actually share a host:port — each binds
   1521 on its own VM. The collision the item describes ("concurrent runs on the
   same runner") only materializes under a different runner model (self-hosted or
   a shared/concurrent runner) AND after the manual gate is lifted.

The risk is therefore strictly **future-conditional**: it bites only if the job
is promoted to a required/auto check AND the project moves to a runner model
where jobs can co-reside on one host. That is exactly what the deferred-work item
says ("if ... ever promoted ... before promotion").

### Ports each job binds (pre-change)

| Job | Host port | Trigger | Wait/probe | Test-step port env |
|-----|-----------|---------|------------|--------------------|
| `integration` (23ai) | `1521:1521` (services) | push/PR | host `localhost:1521` | `ORACLE_PORT: '1521'` |
| `integration-21c` | `1521:1521` (services) | push/PR | host `localhost:1521` | `ORACLE_PORT: '1521'` |
| `integration-non-al32utf8` | `1521:1521` (docker run) | workflow_dispatch | in-container `//localhost:1521/we8pdb1` | `ORACLE_NON_AL32UTF8_PORT: '1521'` |

### Local convention to align to

`docker-compose.yml` `oracle-non-al32` service publishes host port **1523**
(`"1523:1521"`, line 118). `test/integration/test_helper.dart` `nonAl32Port`
getter defaults to **1523** and is overridable via `ORACLE_NON_AL32UTF8_PORT`
(lines 66-69). So 1523 is the established non-AL32UTF8 convention end-to-end.

## Resolution — proactive port move to 1523

Changed the `integration-non-al32utf8` job to bind host port **1523** and pass
`ORACLE_NON_AL32UTF8_PORT=1523` to the test step. Only the HOST mapping changes;
the container's INTERNAL listener stays 1521.

### End-to-end port trace (post-change, all consistent)

1. **Container publish** — `docker run -d --name oracle-non-al32 -p 1523:1521 …`
   (host 1523 → container 1521).
2. **Readiness / charset-assert probe** — `echo "SELECT …" | docker exec -i
   oracle-non-al32 sqlplus -S -L "system/testpassword@//localhost:1521/we8pdb1"`.
   This runs **inside** the container (`docker exec`), so it correctly targets
   the container-internal listener on **1521** — it must NOT change, and was not
   changed. (It is not reachable via the host mapping and never was.)
3. **Dart test step** — `ORACLE_NON_AL32UTF8_PORT: '1523'`. The dart process runs
   on the runner HOST and connects through the published host mapping, so it must
   use 1523. `test_helper.dart`'s `nonAl32Port` getter reads
   `ORACLE_NON_AL32UTF8_PORT` → builds `nonAl32ConnectString`
   (`localhost:1523/we8pdb1`) → `charset_non_al32utf8_integration_test.dart`
   connects via that. Because the getter already reads the env var, changing the
   published port + the env var is sufficient; no Dart change is needed.

A clarifying comment was added above the launch step explaining why 1523 (not
1521) is used, that only the host mapping moves while the internal listener stays
1521, and that this makes the job safe to promote later. A second comment on the
test step explains that 1523 is the host mapping (vs the container-internal 1521
the probe uses).

## Acceptance Criteria

- **AC1 — Host port moved off 1521.**
  - GIVEN the `integration-non-al32utf8` job previously published `-p 1521:1521`,
  - WHEN the workflow is inspected,
  - THEN the launch step publishes `-p 1523:1521` (host 1523, container 1521).

- **AC2 — Test step port threaded consistently.**
  - GIVEN the dart test step previously set `ORACLE_NON_AL32UTF8_PORT: '1521'`,
  - WHEN the step env is inspected,
  - THEN it sets `ORACLE_NON_AL32UTF8_PORT: '1523'`, matching the published host
    port and the local compose / `test_helper.dart` default.

- **AC3 — Container-internal probe unchanged.**
  - GIVEN the readiness/charset-assert step runs `sqlplus` via `docker exec`
    inside the container,
  - WHEN that step is reviewed,
  - THEN it still targets `//localhost:1521/we8pdb1` (the container-internal
    listener), because the internal port did not change — only the host mapping
    did.

- **AC4 — No 1521 host binding remains in this job; standard jobs untouched.**
  - GIVEN the edited workflow,
  - WHEN the `integration-non-al32utf8` job is searched for `1521`,
  - THEN the only `1521` references in that job are the container-internal probe
    and the `:1521` right-hand side of `-p 1523:1521`; the standard `integration`
    / `integration-21c` jobs are unchanged (they remain on their own VMs).

- **AC5 — YAML well-formed.**
  - GIVEN the edited `.github/workflows/ci.yml`,
  - WHEN parsed with `python3 -c "import yaml; yaml.safe_load(open(...))"`,
  - THEN it loads without error.

- **AC6 — No behavior change beyond the port.**
  - GIVEN the job otherwise unchanged,
  - WHEN the step diff is reviewed,
  - THEN only the host port (`1521`→`1523`), the test-step `ORACLE_NON_AL32UTF8_PORT`
    (`1521`→`1523`), and explanatory comments changed. The image tag, bind mount,
    other env, the readiness loop logic, and the in-container probe are untouched.
    CI is not triggered as part of this change.

## Validation performed

- `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"` →
  **`ci.yml: YAML OK`**.
- `grep -n "152[0-9]"` over `ci.yml` confirms the trace: launch `-p 1523:1521`,
  in-container probe `//localhost:1521/we8pdb1`, test step
  `ORACLE_NON_AL32UTF8_PORT: '1523'`; standard jobs still `1521:1521` on their own
  VMs.
- `test_helper.dart` confirmed to read `ORACLE_NON_AL32UTF8_PORT` (`nonAl32Port`
  getter, default 1523), so the env change is sufficient — no Dart edit needed.

### Confidence the job still connects

**High.** The change is symmetric and minimal: the container still listens on
1521 internally; Docker maps host 1523 → container 1521; the in-container probe
(which never used the host mapping) is untouched; the only host-side consumer
(the dart test) is pointed at 1523 via an env var the test helper already
honors. This is exactly the mapping the local compose fixture has used
successfully (host 1523 → container 1521, `we8pdb1`), so the topology is proven.
CI was not run per task constraints; the reasoning above is the basis for the
confidence rating.

## Out of scope (left untouched)

- The standard `integration` and `integration-21c` jobs keep `1521:1521` — they
  are separate jobs on separate runner VMs and were never the thing to move.
- `docker-compose.yml` was already on host 1523 for `oracle-non-al32`; no change
  needed (the CI job now matches it).
- Promotion of `integration-non-al32utf8` from `workflow_dispatch` to a required
  check — a separate future decision (the architecture note still requires it to
  prove consistently green inside the timeout first). This change only makes that
  promotion port-safe.
