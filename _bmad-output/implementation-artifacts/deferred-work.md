# Deferred Work

## Deferred from: code review of 2-5-transaction-management (2026-05-21)

- **AC8 has no end-to-end test that forces the timeout path** — `_receiveDataWithTimeout` is exercised only via the default 30-second value; no test ever blocks a server response to prove the timeout actually fires with a useful `OracleException`. Spec Task 2.3 allowed documenting why ("no mock hook in transport tests; fake server out of scope") and that documentation exists in the Dev Agent Record. Add a mock-socket transport unit test when the transport test infra gains a hook, or an integration-style test using a pausable network proxy.
- **Transport sequence-desync after RPC timeout** — `_receiveDataWithTimeout` (transport.dart:386-388) already documents: "on timeout the underlying socket read continues; subsequent operations may receive stale data." This is a known hazard for all timeout-bounded RPCs, not just commit/rollback. Mark the transport as broken (force disconnect or set `_corrupted = true` checked by `_ensureOpen`) on timeout so the next RPC fails loudly rather than reading the orphaned response.
- **`_ensureOpen()` does not detect silently-dropped sockets** — Only checks `_isClosed`. TCP RST or idle-firewall-kill is only observed after the 30s RPC timeout fires. Cross-check `_transport.isConnected` (or its socket-level equivalent) inside `_ensureOpen` so dead-connection RPC attempts fail fast.

## Deferred from: code review of classical-auth-fallback (2026-05-21)

- **`sendAuthPhaseOne` lacks a timeout wrapper** — `AuthFlow.authenticate` wraps AUTH_PHASE_TWO's `receiveData` in `authTimeout` to handle Oracle's silent-close on wrong password, but the classical AUTH_PHASE_ONE has no timeout. A pre-23 server that silently closes after sending an internal error (dead instance, listener misroute) would hang indefinitely. The 21c wrong-password integration test currently passes because 21c errors out at phase two, not phase one. Add a timeout if a real hang is ever observed.
- **Classical integration test imports `package:oracledb/src/transport/...`** — `classical_auth_integration_test.dart` cracks open the `src/` tree to probe `Transport.supportsFastAuth` before the test starts. Other integration tests do similar. Acceptable for now; consider exposing a test-only API (or a `dart_oracledb_internal` library) if internal layout changes start churning tests.
- **`updateState(phaseOneSent)` runs before the classical branch sends anything** — If `sendProtocolNegotiation` throws inside the classical branch, the AuthFlow state shows `phaseOneSent` despite no phase-one packet on the wire. State-machine inspectors (retry/recovery logic) would be slightly misled. Low impact; move the `updateState` call into each branch if state observability becomes important.
- **`RUN_INTEGRATION_TESTS` skip logic checks presence, not value** — `Platform.environment.containsKey('RUN_INTEGRATION_TESTS')` runs the tests even when the value is `false`. This matches the inconsistent pattern already deferred from 6-4; normalize once across the integration suite.
- **`use23aiFormat` for AUTH_PHASE_TWO is gated on `_ttcFieldVersion`, not `supportsFastAuth`** — In `auth.dart:411` `transport.shouldWriteTokenNumber` depends on `_ttcFieldVersion` set from `compileCaps`. If a pre-23 server returns a short `ProtocolResponse` with null `compileCaps`, `_ttcFieldVersion` stays at its default (`24`) and `use23aiFormat=true` is sent against a pre-23 server. Empirically 19c/21c return compile caps so this is defensive. Consider gating `use23aiFormat` on `transport.supportsFastAuth` instead — more robust to short responses.
- **`AuthPhaseOneResponse.decode` swallows ERROR TTC messages** — Pre-existing: on `msgType == ttcMsgTypeError` the decoder logs a warning and returns a default response with empty `sessionData`, leading to a downstream phase-two failure with garbage inputs instead of a fast surface error. Was already buggy for FAST_AUTH; the new classical path inherits the same behavior. Fix by raising an `OracleException` with the parsed Oracle error code inside `AuthPhaseOneResponse.decode`.

## Deferred from: code review of oracle-19c-compatibility-support (2026-05-21)

- **`dart_fast_auth.bin` debug write removed but `dart:io` import was left behind** — Pre-existing: the debug write (`File('dart_fast_auth.bin').writeAsBytes(...)`) and its `dart:io` import were carried over from before this story. Both were cleaned up as part of this story's review loop. No further action needed.
- **CI Oracle 19c readiness wait loop uses TCP probe + 5s sleep** — `cat < /dev/tcp/localhost/1521` confirms the listener port is open, then sleeps 5 s before running tests. This matches the existing `integration` job pattern. If Oracle 19c startup in CI is slow (PDB not yet mounted when listener answers), tests may see `ORA-12514`. Monitor CI runs and increase the sleep or add a sqlplus probe loop if needed.

## Deferred from: code review of 6-4-ci-cd-integration-test-automation (2026-05-21)

- **Job timeout tightness** — `integration` job `timeout-minutes: 15` may be tight on cold runners where Oracle 23ai Free startup takes 5–8+ min. Monitor first few CI runs; bump to 20 min if jobs start timing out before tests run.
- **`testpassword` in `--health-cmd` visible in CI logs** — `options:` string is logged verbatim by GitHub Actions. Accepted tradeoff per Dev Agent Record for ephemeral CI database; revisit if the image ever switches to a production-adjacent credential.
- **`docker ps` insufficient failure diagnostics** — `docker ps --no-trunc` doesn't show container stdout/stderr. Replace with `docker logs <id>` to get Oracle startup errors when the listener probe times out.
- **`dart analyze` runs redundantly on macOS/Windows** — Dart's analyzer is platform-independent; running it in the `platform` matrix jobs duplicates work already done in `quality`. Remove from platform job when CI cost becomes a concern.
- **Inconsistent `containsKey` vs `== 'true'` skip guards** — Some integration test files skip on `containsKey('RUN_INTEGRATION_TESTS')`; others require `== 'true'`. Pre-existing; CI sets `'true'` so all tests run, but the inconsistency is a maintenance risk.
- **`socket_test.dart` has no `@Tags` annotation** — Pre-existing; tests are gated via `markTestSkipped` inside setUp, not via tag-based exclusion. Add `@Tags(['integration'])` when normalizing integration test guards.
- **No dedicated test schema/user creation (AC1)** — CI uses Oracle's built-in `system`/`FREEPDB1`; no DDL init script. Acceptable now; revisit when test isolation becomes a hard requirement or when `system` usage is restricted.
- **No 80% coverage threshold enforcement** — Coverage is generated and uploaded but not enforced. Requires a stable baseline measurement first; add a `lcov --summary | awk` threshold check once coverage trends are visible.
- **Coverage trends not fully trackable for fork PRs** — Codecov upload skipped for forks (secrets unavailable); only a 14-day artifact is retained. Requires org-level Codecov tokenless config or a token exposed to fork PRs via `pull_request_target`.
- **Linux not in `platform` matrix job** — AC4 is met via the `quality` job, but the `platform` job name implies cross-platform completeness without Linux. Add `ubuntu-latest` to the matrix if the platform job becomes the canonical cross-platform gate.

## Deferred from: code review of 6-2-epic-1-authentication-test-suite-rework (2026-05-21)

- **W1: verifier.dart at 85.7% below ≥90% Crypto layer target** — 2 uncovered defensive branches; acknowledged in story notes. Address in a future coverage sweep or when those branches become exercisable via integration tests.
- **W2: Sequence counter wrap-around at 256 untested** — `Transport._sequence` is never reset; after 256 `nextSequence()` calls the counter wraps to 0x01, colliding with FAST_AUTH sequence. Add a test for wrap behavior and confirm Oracle's behavior when this occurs in a long-lived connection.
- **W3: `shouldWriteTokenNumber` threshold boundary (=18 exactly) untested** — Only the default `_ttcFieldVersion=24` is verified. Add boundary tests for version=18 (true), version=17 (false), and version=0 (false).
- **W4: `toVerifierParams` fallback values not validated for required AES-block lengths** — `params.serverNonce` and `params.salt` default to `Uint8List(16)`. Tests only assert `isNotNull` and `greaterThan(0)`; actual byte lengths matter for AES-256-CBC correctness. Add length assertions to the 7.3 tests.
- **W5: Timeout range `inInclusiveRange(4, 6)` accepts 6s** — AC3 spec says "within 5 seconds" but 6s is kept for CI jitter tolerance. If Oracle 23ai behavior tightens, revisit.
- **W6: `AuthPhaseTwoRequest` verifierType=0xB92 speedyKey not sent on wire** — `generatePasswordProof` sets `_speedyKey` for 0xB92, but `auth_message.dart` only sends it for 0x4815 (`ttcVerifierType12c`). Investigate whether 0xB92 should include the speedy key in the wire message, or if this is intentional protocol behavior.
- **D3: SHA512 verifier path (`verifierType=0x939`) untested** — 11g-era verifier not reachable against Oracle 23ai. ECH flagged a potential AES block-alignment crash in the SHA512 branch of `generatePasswordProof`. When adding legacy Oracle support, add tests for this path and verify the server nonce length assumption.

## Deferred from: code review of 6-3-epic-2-validation-pending-validation-stories (2026-05-21)

- **`ColumnMetadata` / `ExecuteResponse` fields are now mutable** — `lib/src/protocol/messages/execute_message.dart:~1019`. The rewrite turned previously-immutable response objects into mutable ones, and `_DecodeState.rows` aliases `response.rows`. Currently functional and analyzer-clean, but mutability invites bugs once callers retain the response across awaits. Tighten back to immutable (or copy lists on assignment) in a future cleanup pass.
- **Stories 2.5 / 2.6 need re-validation post-protocol-rebuild** — Downgraded from `review` to `dev-complete-pending-validation` in Story 6.3 because the execute path changed. Re-run their integration tests after DML patches are applied and update sprint status accordingly.
- **Unit test coverage gaps from execute_message_test.dart rewrite** — ~27 test cases removed with the old invented-format suite. Scenarios needing future coverage: NUMBER decode variants, DML rowsAffected combinations, multi-bind value ordering, and chunked payload decoding.

## Deferred from: code review of 6-3-epic-2-validation-pending-validation-stories Chunk C (2026-05-21)

- **Probe tools `tool/dml_probe.dart` and `tool/simple_probe.dart` committed to source tree** — One-off debug artifacts from Story 6.3. Not referenced by tests/CI/docs. Move to `.gitignore`/`.pubignore`, relocate to `tool/debug/`, or delete after epic closes.
- **Hardcoded local credentials in probes** — `system/testpassword` against `localhost:1521/FREEPDB1`. If probes stay, read from `ORA_TEST_USER`/`ORA_TEST_PASSWORD` env vars.
- **`_ub8` helper in test file aliases `_ub4` — silently truncates >4-byte values** — `test/src/protocol/messages/execute_message_test.dart:185`. Works by accident with current fixtures (small rowCount values). Replace with a proper variable-length UB8 emitter before adding wider UB8 fixtures.
- **Sparse `decodeExecuteResponse` unit coverage** — Only 4 fixture cases. NUMBER decode variants, multi-bind ordering, and column metadata parsing covered only by integration tests. Adds CI fragility if Oracle 23ai access is lost.

## Deferred from: code review of 6-3-epic-2-validation-pending-validation-stories Chunk B (2026-05-21)

- **`sendCommit()`/`sendRollback()` have no timeout** — `lib/src/transport/transport.dart`. Same behavior as pre-Story-6.3 CommitRequest path. Add timeout wrapper in a connection-lifecycle story.
- **`sendData()` 0x0800 default on FAST_AUTH/protocol-negotiation packets** — `lib/src/transport/transport.dart`. Empirically works on Oracle 23ai (38 tests pass). Risk on pre-23ai Oracle (out of scope).
- **`_receiveAllTtcData` 0x1D heuristic may false-positive on column data ending with byte 29** — `lib/src/transport/transport.dart`. Necessary for DML hang fix; proper fix requires TTC stream-level framing.
- **`tnsPacketRefuse` mid-query misreported as `oraInvalidCredentials`** — `lib/src/transport/transport.dart`. Misleading error message for non-auth REFUSE packets; connection closes correctly either way.
- **`dart_fast_auth.bin` debug write still present in `sendFastAuth()`** — `lib/src/transport/transport.dart`. Pre-existing; binary excluded via `.gitignore`. Remove write code in cleanup story.

## Deferred from: code review of 6-3-epic-2-validation-pending-validation-stories Chunk A (2026-05-21)

- **`_processIoVector` `fastFetchLen`/`rowidLen` may use wrong read method (variable-length UB2 vs raw UB2)** — `lib/src/protocol/messages/execute_message.dart`. IO_VECTOR only triggered for OUT bind parameters (Epic 3). Verify against node-oracledb `messages/ioVector.js` when Story 3.1 OUT-parameter work begins.
- **`_readInteger` UB8 produces wrong results on Flutter Web (JS)** — `lib/src/protocol/buffer.dart`. UB8 values > 2^53 corrupted by JS 53-bit int. Dart VM only target; blocks any future Flutter Web or dart2js port.
- **`readBytesWithLength` 0xFF null-coercion may corrupt LONG column data** — `lib/src/protocol/buffer.dart`. If Oracle sends a 255-byte LONG/LONG RAW value with 0xFF length prefix, bytes are silently discarded. 0xFF-as-null is correct for current scope types; LONG support is Epic 4.
- **`_readInteger` sign-magnitude negative-zero edge case (size byte 0x80)** — `lib/src/protocol/buffer.dart`. Hypothetical Oracle sentinel; sign-magnitude format matches Oracle TNS convention.
- **`_processColumnInfo` reads 23.4 vector fields unconditionally (no version gate)** — `lib/src/protocol/messages/execute_message.dart`. Consumes 6 bytes regardless of server version. Oracle 23ai always sends these; version-gating needed for pre-23.4 server support.
- **`_processColumnInfo` reads 12.2 `oaccolid` field unconditionally on decode side** — `lib/src/protocol/messages/execute_message.dart`. Encode side is version-gated; decode is not. Pre-12.2 server support out of scope.
- **`_processColumnInfo` `maxLength` uses `size` for non-RAW types; can be 0 for numeric columns** — `lib/src/protocol/messages/execute_message.dart`. Harmless for current callers; misleading for future buffer-allocation callers.
- **`rowsAffected` incorrectly 0 (not null) for DML on pre-12.2 server** — `lib/src/protocol/messages/execute_message.dart`. Pre-12.2 UB8 row-count not sent; `rowsAffected` defaults to 0. Pre-12.2 support out of scope.
- **`_maxSizeFor` returns 1 for null-valued VARCHAR bind — cursor re-use risk** — `lib/src/protocol/messages/execute_message.dart`. Safe now (every execute re-parses); becomes a bug when statement caching (Story 2.7) is added.
