---
status: done
review_loop_iteration: 0
followup_review_recommended: false
deferred:
  - summary: >-
      Numeric JSON literals outside the exact double range can lose precision before the text JSON reviver runs.
    evidence: |-
      Dart jsonDecode rounds 9007199254740993.0 to 9007199254740992.0 before the reviver sees it. The OSON NUMBER decoder also reconstructs through double. Exact numeric semantics need a separate parser and cross-format design.
    location: >-
      lib/src/protocol/oson.dart:1153
    severity: medium
---

# BMad Build Auto Result

## Review Triage Log

### 2026-10-09 — Review pass
- verdicts: 6 findings — high 0, medium 3, low 1, false 2, maybe-false 0
- findings:
  - `[low]` `[reject]` Very small nonzero JSON numbers normalize to integer zero — `jsonDecode` already underflows `1e-999` to zero, as the OSON NUMBER path can; preserving the original literal needs a new numeric parser. This edge case is unlikely in everyday use, and adding parser state for it is disproportionate here.
  - `[medium]` `[defer]` A number just above 2^53 can become an incorrect integer after rounding — `jsonDecode` has already rounded `9007199254740993.0` before the reviver sees it; the OSON NUMBER decoder has the same double reconstruction limit. Recorded the shared precision limitation in frontmatter for a separate cross-format design.
  - `[false]` `[reject]` The new `readJsonLocator` FormatException catch has no transport test — `decodeJsonBlobBytes` wraps text decode and parse FormatExceptions, and `decodeOson` wraps malformed UTF-8; the cited catch is defensive and cannot be reached through these inputs.
  - `[false]` `[reject]` A range overflow cannot be distinguished from malformed syntax — the error includes `number literal out of double range`, which identifies the range failure without echoing document content.
  - `[medium]` `[patch]` Nested text-JSON number types were not asserted — added an `isA<int>()` assertion for a value nested in an array and object in `oson_test.dart`.
  - `[medium]` `[patch]` The behavioral fetch surface lacked an assertion for integral-double normalization — changed the integration fixture's BLOB JSON text to `2.0` and asserted `int` through REF CURSOR and nested CURSOR fetches on both Oracle versions. The auditor's wider rebind reading was descriptive, while this pass directly verifies the changed fetch behavior.

### 2026-10-09 — Follow-up review pass
- verdicts: 4 findings — high 0, medium 1, low 2, false 1, maybe-false 0
- findings:
  - `[low]` `[reject]` Fractional literals that round to an integral double become `int` — confirmed with `1.0000000000000001` and `0.99999999999999999`; `jsonDecode` loses the fractional part before the reviver runs. This rare precision edge needs a literal-aware parser and falls under the recorded cross-format precision limitation.
  - `[low]` `[reject]` Text JSON `-0.0` becomes integer zero — confirmed, but OSON NUMBER already decodes negative zero as zero and the parity rule explicitly includes it. Preserving the sign requires a separate numeric representation or parser for a negligible edge.
  - `[medium]` `[patch]` A malformed OSON UTF-8 `FormatException` retained input bytes in `OracleException.cause` — removed the byte-bearing cause and asserted it is absent; the protocol error still reports the reason and offset without document content.
  - `[false]` `[reject]` A wider fetch-then-rebind reading lacks an integration assertion — the artifact explicitly identifies rebind as descriptive and the changed behavior is JSON fetch normalization, which the REF CURSOR and nested CURSOR tests exercise.

## Auto Run Result

Status: done

Summary: Follow-up review hardened malformed OSON UTF-8 errors so callers cannot retrieve the input bytes through the exception cause. The existing JSON number normalization and cursor fetch coverage remain verified.

Files changed: `lib/src/protocol/oson.dart` removes the byte-bearing cause; `test/src/protocol/oson_test.dart` asserts the sanitized error; this result artifact records the follow-up review.

Review: one medium patch, no new deferrals, two low findings rejected because they require a literal-aware numeric design for rare precision/sign edges, and one false rebind finding rejected because it is outside the artifact's stated fetch behavior. Follow-up review recommended: false (one medium patch, no high patch).

Verification: `dart test test/src/protocol/oson_test.dart` passed (105 tests); `dart analyze lib/src/protocol/oson.dart test/src/protocol/oson_test.dart` passed; `./scripts/verify-integration.sh` passed on Oracle 23ai (628 passed, 32 skipped) and Oracle 21c (629 passed, 31 skipped).

Residual risk: exact numeric literal semantics across text JSON and OSON remain limited by double reconstruction, as recorded in the existing `deferred` item above.
