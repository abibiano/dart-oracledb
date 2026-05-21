# Deferred Work

## Deferred from: code review of 6-2-epic-1-authentication-test-suite-rework (2026-05-21)

- **W1: verifier.dart at 85.7% below ≥90% Crypto layer target** — 2 uncovered defensive branches; acknowledged in story notes. Address in a future coverage sweep or when those branches become exercisable via integration tests.
- **W2: Sequence counter wrap-around at 256 untested** — `Transport._sequence` is never reset; after 256 `nextSequence()` calls the counter wraps to 0x01, colliding with FAST_AUTH sequence. Add a test for wrap behavior and confirm Oracle's behavior when this occurs in a long-lived connection.
- **W3: `shouldWriteTokenNumber` threshold boundary (=18 exactly) untested** — Only the default `_ttcFieldVersion=24` is verified. Add boundary tests for version=18 (true), version=17 (false), and version=0 (false).
- **W4: `toVerifierParams` fallback values not validated for required AES-block lengths** — `params.serverNonce` and `params.salt` default to `Uint8List(16)`. Tests only assert `isNotNull` and `greaterThan(0)`; actual byte lengths matter for AES-256-CBC correctness. Add length assertions to the 7.3 tests.
- **W5: Timeout range `inInclusiveRange(4, 6)` accepts 6s** — AC3 spec says "within 5 seconds" but 6s is kept for CI jitter tolerance. If Oracle 23ai behavior tightens, revisit.
- **W6: `AuthPhaseTwoRequest` verifierType=0xB92 speedyKey not sent on wire** — `generatePasswordProof` sets `_speedyKey` for 0xB92, but `auth_message.dart` only sends it for 0x4815 (`ttcVerifierType12c`). Investigate whether 0xB92 should include the speedy key in the wire message, or if this is intentional protocol behavior.
- **D3: SHA512 verifier path (`verifierType=0x939`) untested** — 11g-era verifier not reachable against Oracle 23ai. ECH flagged a potential AES block-alignment crash in the SHA512 branch of `generatePasswordProof`. When adding legacy Oracle support, add tests for this path and verify the server nonce length assumption.
