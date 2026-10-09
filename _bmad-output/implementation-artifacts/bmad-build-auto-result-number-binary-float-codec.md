---
status: done
review_loop_iteration: 0
followup_review_recommended: false
---

# BMad Build Auto Result

## Auto Run Result

Status: done

Resolved DW-1 and DW-6 (bundle number-binary-float-codec). The original change decodes BINARY_FLOAT and BINARY_DOUBLE columns, including embedded cursors, and fixes NUMBER decoding at range extremes. This follow-up review adds a type-specific payload-length guard and regression coverage for float32 precision, REF CURSOR results, long NUMBER mantissas, and the reported OSON round trip.

- DW-1: `_decodeValueByOraType` decodes oraType 100/101 via `decodeBinaryFloatingPoint`, shared with the OSON decoder; both types are also allowed in embedded-cursor column support.
- DW-6: `decodeNumber` no longer mistakes a leading `0x80` exponent byte for zero when mantissa bytes follow, and reconstructs a double in one rounded step to avoid extreme-range underflow and ulp error.

Files changed in this review:
- `lib/src/protocol/messages/execute_message.dart` — reject a BINARY_FLOAT or BINARY_DOUBLE payload with the wrong length for its declared type.
- `test/integration/binary_float_integration_test.dart` — cover float32 precision and returned REF CURSOR values.
- `test/src/protocol/data_types_test.dart` — cover the long-mantissa NUMBER parse path.
- `test/src/protocol/oson_test.dart` — cover the reported OSON NUMBER extremes.

Review findings: five grouped patch entries (zero high, three medium, two low), no deferred entries, and one rejected finding. The negative-zero column assertion was rejected because the shared binary decoder already has negative-zero coverage in `oson_test.dart`; both Oracle versions returned positive zero for `TO_BINARY_FLOAT('-0.0')`, so that expression cannot test preservation of a negative-zero wire value. The edge-case and verification-gap findings repeated the payload-length and REF CURSOR issues, and the intent-alignment finding repeated the OSON test gap.

Follow-up review recommended: false. No high finding was patched in this follow-up pass.

Verification: focused codec and OSON unit tests passed (204); execute-message unit tests passed (228); full integration suites passed on Oracle 23ai (622 passed, 32 skipped) and Oracle 21c (623 passed, 31 skipped). `dart analyze` found no issues; `dart format --output=none --set-exit-if-changed` found no changes.

Residual risk: this result file has no original `<intent-contract>` or `baseline_revision`; the review baseline was the parent of commit `c2dab02436def66ddb1467c91403d090d6002104`.

## Review Triage Log

### 2026-10-09 — Follow-up review pass
- verdicts: 9 findings — high 0, medium 6, low 2, false 1, maybe-false 0
- findings:
  - `[medium]` `[patch]` Declared binary type accepts the other type's payload length at `execute_message.dart:2169` — the generic decoder accepts either four or eight bytes; added a check against the declared type before decoding.
  - `[low]` `[patch]` Float32 column precision lacked a non-exact value at `binary_float_integration_test.dart:31` — added `TO_BINARY_FLOAT(3.14)` and asserted the widened float32 value on both databases.
  - `[false]` `[reject]` Negative-zero column decoding lacked protection at `binary_float_integration_test.dart:34` — `oson_test.dart` already checks negative zero through the same `decodeBinaryFloatingPoint` function; live `TO_BINARY_FLOAT('-0.0')` returned positive zero on both databases, so that SQL expression cannot demonstrate a column decoder defect.
  - `[medium]` `[patch]` Returned-cursor binary types lacked coverage at `execute_message.dart:2513` — added a live REF CURSOR returning both types and checked its decoded row on both databases.
  - `[low]` `[patch]` Long-mantissa NUMBER parse path lacked coverage at `data_types_test.dart:1199` — added a 17-digit mantissa round trip.
  - `[medium]` `[patch]` The reported OSON NUMBER extreme round trip lacked coverage at `deferred-work.md:54` — added direct `decodeOson(encodeOson(value))` assertions for both cited extremes, without editing the ledger.
  - `[medium]` `[patch]` Wrong-length binary payload can be decoded as another type at `execute_message.dart:2169` — same verified root cause and type-specific guard as the first finding.
  - `[medium]` `[patch]` Embedded REF CURSOR type acceptance lacked a checked test at `execute_message.dart:2513` — same verified gap and live returned-cursor test as the fourth finding.
  - `[medium]` `[patch]` OSON expectation was only tested at the shared NUMBER codec — the reported outer OSON surface now has direct round-trip assertions; the original intent contract is unavailable.
