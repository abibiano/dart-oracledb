---
status: done
followup_review_recommended: true
review_loop_iteration: 0
baseline_revision: 595f7d1c598f0b71802c4995b05ff67d7fd0a18c
---

# BMad Build Auto Result

## Auto Run Result

Status: done

Reviewed and corrected the stale JSON BLOB documentation and decode-error recovery hint. The hint now distinguishes streaming APIs from `executeMany()` options, recommends a separate `execute()` SELECT for raw bytes, identifies `resultSet: true` for large results, and warns against replaying statements with side effects. Corrected the row-count constant name guidance in project context.

Files changed:
- `README.md` and `CHANGELOG.md` — explain the supported raw-byte fetch path and `executeMany()` limitation accurately.
- `lib/src/connection.dart` — correct `rawJsonBlobs` Dartdoc.
- `lib/src/protocol/oson.dart` — give safe, actionable decode-error guidance.
- `_bmad-output/project-context.md` — correct the row-count constant naming note.
- `test/src/protocol/oson_test.dart` — assert the caller-visible recovery hint.
- This result file — record review, verification, and hand-back status.

Review: 12 findings triaged; six root-cause patches applied (high 1, medium 4, low 1). No findings deferred or rejected. The existing orchestrator-owned deferred-work ledger content was left untouched by this run.

Verification:
- `dart test test/src/protocol/oson_test.dart` — 121 passed.
- `dart analyze` — no issues.
- Oracle 23ai integration suite — 657 passed, 33 skipped.
- Oracle 21c integration suite — 658 passed, 32 skipped.
- `git diff --check` — clean.

Follow-up review recommended: true, because this follow-up pass patched a high-severity risk of retrying a statement with side effects after an implicit-result decode failure. That exact side-effect scenario has not been exercised as a dedicated test; the warning is covered by the decoder message assertion and the full integration suites passed.

## Review Triage Log

### 2026-10-15 — Review pass
- verdicts: 12 findings — high 2, medium 7, low 3, false 0, maybe-false 0
- findings:
  - `[low]` `[patch]` Project context still claimed `ttcDmlOptionRowCounts` has the `ttcExecOption*` prefix — the constant declaration disproves that prefix; described its actual option word and nearby constants.
  - `[medium]` `[patch]` Docs said `executeMany()` takes no options — its signature accepts `OracleExecuteManyOptions`; distinguished its options from the absent `rawJsonBlobs` fetch option.
  - `[medium]` `[patch]` Docs said `executeMany()` always decodes JSON BLOBs — SELECT is rejected and DML RETURNING values stay bytes, while implicit result rows can decode; narrowed the claim to implicit result rows.
  - `[medium]` `[patch]` Eager `execute()` advice lacked a large-result path — `OracleExecuteOptions(resultSet: true)` supports lazy fetching; added that option to the hint and README.
  - `[medium]` `[patch]` README's no-options claim could mislead `executeMany()` users about bind and batch options — corrected the option distinction in documentation.
  - `[high]` `[patch]` Re-running an `executeMany()` PL/SQL call after an implicit-result decode failure could repeat side effects — the error now calls for a separate SELECT and warns against replaying such statements.
  - `[low]` `[patch]` Project-context constant-name warning described a prefix that does not exist — corrected the warning at its source.
  - `[medium]` `[patch]` Existing decode-error tests did not assert the new `execute()` recovery guidance — added assertions for the separate SELECT and lazy result-set hint to the decoder test.
  - `[medium]` `[patch]` Error text repeated the false claim that `executeMany()` takes no options — named the missing `rawJsonBlobs` option instead.
  - `[medium]` `[patch]` Intent audit found no test of the actionable recovery hint — the focused decoder test now checks the caller-visible wording.
  - `[high]` `[patch]` Intent audit found the generic `executeMany()` retry advice could replay work — changed it to a separate SELECT with an explicit side-effect warning.
  - `[low]` `[patch]` Intent audit found the constant-prefix statement false — updated project context to match the declaration.
