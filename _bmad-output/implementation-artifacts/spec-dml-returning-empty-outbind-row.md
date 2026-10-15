---
status: done
review_loop_iteration: 0
followup_review_recommended: false
---

# DML RETURNING empty OUT bind row (DW-136)

## Finding

For single-execute DML RETURNING, `lib/src/connection.dart` falls back to one empty list per RETURNING bind when `response.outBindRows` is empty. Zero affected rows is the normal case that reaches this (the server either ships a count-0 ROW_DATA or none; both give empty lists, covered by the existing dual-env zero-row integration test). A response with `rowsAffected > 0` and no ROW_DATA was not observed on Oracle 23ai or 21c, and nothing in the protocol shows it can happen. Decision: keep the lenient empty-list behavior (no throw), pin it with fixtures, and document it at the fallback site.

## Changes

- `lib/src/connection.dart`: comment at the fallback documenting reachability and the pinned behavior (no behavior change).
- `test/src/connection_execute_many_test.dart`: two fixture tests (rowsAffected 3 with no OUT row; count-0 row vs. missing row).

## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 4 findings — high 0, medium 2, low 2, false 0, maybe-false 0
- findings:
  - `[medium]` `[patch]` The zero-row fixture named two response shapes but exercised only the count-0 row — added a second response with no OUT row and compared its result.
  - `[medium]` `[patch]` The fallback creates an empty list for each RETURNING bind, but the fixture checked only one — changed the anomalous response fixture to use two named RETURNING binds and assert both lists.
  - `[low]` `[patch]` The fallback comment called an absent response row the normal zero-row shape despite decoder documentation of a count-0 row — qualified the comment to call count-0 normal and an absent row tolerated. The spec's separate wire-shape claim remains unverified by these fixtures.
  - `[low]` `[patch]` The synthetic connection response cannot determine what Oracle 23ai or 21c sends on the wire — qualified the fixture comment so it claims only the behavior the fixture proves. The existing integration suites check public behavior on both databases.

## Auto Run Result

Status: done

Summary: Reviewed the existing lenient DML RETURNING fallback, completed the zero-row and multi-bind fixture coverage, and qualified comments about unobserved wire behavior. Runtime behavior is unchanged.

Files changed: `lib/src/connection.dart` (fallback comment); `test/src/connection_execute_many_test.dart` (fixture coverage and comment); this spec (review triage and result).

Review: 3 patch entries (2 medium, 1 low) addressed 4 findings. No findings were deferred or rejected. Follow-up review recommended: false; this follow-up pass patched no high-severity entry.

Verification: `dart test test/src` passed (2052 tests, 12 skipped); `dart analyze` passed; `dart format --output=none --set-exit-if-changed` passed. Full integration suites passed on Oracle 23ai (688 tests, 33 skipped) and Oracle 21c (689 tests, 32 skipped).

Residual risk: The fixtures establish behavior for constructed decoded responses; they do not prove whether a positive affected-row count with no RETURNING ROW_DATA occurs on either server.
