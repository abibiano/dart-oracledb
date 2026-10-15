---
title: 'project-context TSTZ region-id wording fix (DW-137)'
type: 'chore'
created: '2026-10-15'
status: 'done'
baseline_revision: '975faef1e7342f4b636ce43d1dde283f888bbc76'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** `_bmad-output/project-context.md:294` says the TSTZ region-id form is hard-rejected. That has been false since Story 14.1, and agents reading the file are misled.

**Approach:** Reword that one bullet to say region-id TSTZ decodes to the UTC instant with a `+00:00` offset (Story 14.1, lib decode path). Docs-only change.

## Boundaries & Constraints

**Always:** Keep the edit to that one bullet in `_bmad-output/project-context.md`. Keep the bullet's style.

**Never:** Edit `deferred-work.md`, `sprint-status.yaml`, `lib/` or `test/`. Do not claim region names are preserved (Story 14.2). Do not claim binding supports region ids (it stays offset-only).

</intent-contract>

## Code Map

- `_bmad-output/project-context.md:294` -- stale bullet about TSTZ region-id rejection.
- `_bmad-output/implementation-artifacts/14-1-tstz-region-name-decode.md` -- source story: region-id decodes to the UTC instant, offset `+00:00`; the region name is not recoverable.

## Tasks & Acceptance

**Execution:**
- `_bmad-output/project-context.md` -- rewrite line 294 so it states region-id TSTZ decodes to the UTC instant at `+00:00` (decode only; bind stays offset-only) -- resolves DW-137

**Acceptance Criteria:**
- Given `_bmad-output/project-context.md`, when the TSTZ bullet is read, then it no longer says "hard-rejected" and states the region-id form decodes to the UTC instant at `+00:00`.

## Verification

**Manual checks (if no CLI):**
- `grep -n -i "hard-rejected" _bmad-output/project-context.md` returns nothing, and `git diff --stat` shows only this file (plus this spec).

## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 12 findings — high 0, medium 1, low 1, false 0, maybe-false 0 (remaining findings reject or are the same root cause)
- findings:
  - `[medium]` `patch` Bullet said region name "is not recoverable"; Story 14.2 added `OracleConnection.timeZoneRegionName` (blind, edge-case, intent-alignment all reported it) — wording corrected to say the name is recoverable on demand.
  - `[low]` `patch` Default mode returns a plain UTC `DateTime`; `+00:00` only in preserve mode — bullet now names both modes and says `+00:00` is the UTC rendering.
  - `[low]` `reject` Binding `regionId` ignored / round-trip loses region — bullet already says binding stays offset-only; more detail not worth the length.
  - `[low]` `reject` Split bullet in two, add Epic 14.3/14.4 notes, replace story reference with a stable pointer — beyond the intent's one-line scope; the story reference is requested by the intent.
  - `[false]` `reject` Verification `git diff --stat` cannot list the untracked spec — this edits the spec's own check, rejected by rule.
  - `[low]` `reject` Acceptance criterion too weak — fix edits this build's spec, rejected by rule.
  - verification-gap layer: no findings; intent-alignment: descriptive only, R1/R2 divergence resolved by the patch above.

### 2026-10-15 — Follow-up review pass
- verdicts: 6 findings — high 0, medium 3, low 2, false 1, maybe-false 0
- findings:
  - `[medium]` `[patch]` The default column `DateTime` lacks the `regionId` needed for name lookup — `timeZoneRegionName` takes `OracleTimestampTz` and checks `regionId`; the bullet now limits lookup to a value retaining that id.
  - `[medium]` `[patch]` Native JSON returns `OracleTimestampTz` regardless of `preserveTimestampTimeZone` — `oson.dart` documents this distinct decode path; the bullet now names it.
  - `[low]` `[reject]` The Code Map still quotes the Story 14.1 limitation — the requested correction is to the project-context bullet, and this finding would edit this build's spec.
  - `[medium]` `[patch]` Edge-case review independently found that default column decoding loses the id needed for name lookup — the same bullet correction now states the `OracleTimestampTz.regionId` condition.
  - `[low]` `[reject]` Intent audit found the bullet longer than its original compact style — the extra phrases distinguish column and JSON decoding and qualify name lookup; shortening would reintroduce the observed ambiguity.
  - `[false]` `[reject]` Intent audit noted the implementation spec as an additional file — this file records the requested build workflow, while the product documentation edit is confined to the one bullet.

## Auto Run Result

Status: done

- Summary: Corrected the TSTZ region-id bullet to describe UTC decoding, the distinct column and native JSON results, the condition for on-demand region-name lookup, and offset-only binding.
- Files changed: `_bmad-output/project-context.md` (one bullet reworded); this spec (follow-up review record and result).
- Review: 2 medium patch entries applied (name lookup was reported twice); 0 deferred; 3 rejected with reasons in the triage log. Follow-up review recommended: false; no high finding was patched.
- Verification: no `hard-rejected` match in `_bmad-output/project-context.md`; the implementation docs for `timeZoneRegionName` and native JSON confirm the wording; targeted diff confines the product documentation change to one bullet. This is a docs-only change, so Oracle integration tests on 23ai and 21c were not run.
- Residual risks: none known.
