---
status: done
review_loop_iteration: 0
baseline_revision: c4b6588b503d4ef52561ab4341f4155961287fef
followup_review_recommended: false
---

# BMad Build Auto Result

## Auto Run Result

Status: done

The primary Compose and CI Oracle service use the 23.9.0.0 image from commit
`4d841040afbd9adb44510dffa688e0459e61f9ac`. This follow-up review added a
server-release assertion before the CI and local integration suites and guidance
for existing 26ai data volumes.

Files changed in this follow-up:
- `.github/workflows/ci.yml` — verify the CI service reports Oracle 23.9.
- `scripts/assert_oracle_version.sh` — query `V$INSTANCE.VERSION_FULL` through FREEPDB1.
- `scripts/verify-integration.sh` — check the local 23ai server before running suites.
- `CONTRIBUTING.md` — preserve a former 26ai volume when starting the pinned image.
- This result file — record the review and verification.

Review: two medium findings patched, no high or low findings patched, no items
deferred. The registry-tag reassignment concern was rejected as low likelihood
and more complex to fix than the requested version pin. The CI-scope concern
was rejected because CI is also a 23ai test target. Follow-up review
recommended: false; this follow-up patched no high finding.

Verification:
- `docker compose config --quiet` and `bash -n` on both shell scripts passed.
- The new version check rejected the old 26ai container (`23.26.1.0.0`) and
  accepted the pinned container (`23.9.0.25.07`).
- Oracle 23ai integration suite: 644 passed, 33 skipped.
- Oracle 21c integration suite: 645 passed, 32 skipped.
- `git diff --check` passed.

Residual risk: the 23.9 registry tag can theoretically be reassigned; CI's
hosted job was not run locally. The old 26ai named volume remains preserved.

## Review Triage Log

### 2026-10-14 — Review pass
- verdicts: 4 findings — high 0, medium 2, low 1, false 1, maybe-false 0
- findings:
  - `[medium]` `[patch]` Existing `oracle-data` may contain 26ai and cannot be opened by 23.9 — the running container reported 23.26.1.0.0 and mounted that volume; documented a new Compose project name that preserves the old volume.
  - `[low]` `[reject]` A registry could reassign the 23.9 tag — no reassignment is shown, and a digest pin adds architecture and update maintenance beyond the requested version pin; official version-tag reassignment is unlikely in everyday use.
  - `[medium]` `[patch]` CI and local integration gates did not assert the server release — the readiness probe checked only `SELECT 1`, while the old local container reported 23.26.1.0.0; added a `VERSION_FULL` check before either suite.
  - `[false]` `[reject]` The CI pin exceeds a narrow Compose-only reading — the broader intent of keeping the 23ai test target stable includes the CI service, and the diff keeps the service image and readiness lookup in sync.
