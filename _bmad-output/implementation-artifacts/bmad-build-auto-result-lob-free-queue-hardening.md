---
status: done
review_loop_iteration: 0
baseline_revision: 21d49ffe0c1ec2180f54afeeee00344e4d3f7d09
deferred:
  - summary: >-
      Distinct temporary LOB identities might collide after enough allocations or across LOB types.
    evidence: |-
      The 12-byte identity range was measured on two temporary CLOBs. A live sequence of many CLOB, BLOB, and NCLOB allocations on both Oracle versions, with distinct-identity and post-free server-count checks, would settle whether the range remains unique.
    location: >-
      lib/src/transport/transport.dart:561
    severity: medium (unverified)
  - summary: >-
      A temporary OUT locator can remain unqueued when an existing maxSize guard rejects it before materialization.
    evidence: |-
      The scalar, bulk, and DML RETURNING maxSize checks throw before readLocator reaches its finally block. These checks and their ordering predate this hardening change. A live server-side leak measurement on an oversized temporary OUT locator would settle the impact.
    location: >-
      lib/src/transport/transport.dart:2362
    severity: medium
  - summary: >-
      Multiple distinct open handles for one temporary locator identity may outlive the ownership set's single claim.
    evidence: |-
      claimTempLobOwnership stores one set key and queueTempLobToFree removes it on one close. The response-local materialized map shares one handle for aliased LobLocator instances; a reachable path producing two independent handles with the same identity has not been established. A live or decoder-level reproducer would settle this.
    location: >-
      lib/src/transport/transport.dart:590
    severity: medium (unverified)
followup_review_recommended: false
---

# BMad Build Auto Result

## Review Triage Log

### 2026-10-14 — Review pass
- verdicts: 12 findings — high 0, medium 3, low 5, false 2, maybe-false 2
- findings:
  - `[medium]` `[defer]` Oversized temporary OUT locators bypass the free queue when maxSize rejects before readLocator — the scalar, bulk, and DML RETURNING guards precede readLocator; their order predates this change. Recorded in deferred frontmatter for a live leak measurement.
  - `[maybe-false]` `[defer]` Two independently wrapped handles for one identity could lose ownership after the first close — a set has no reference count, but response-local aliasing returns one shared handle; a reachable two-handle response is needed to establish the outcome. Recorded in deferred frontmatter as unverified medium.
  - `[low]` `[patch]` Materialize-queued counter counted a skipped duplicate — the increment preceded pending-key deduplication; it now increments only after queue acceptance, with a duplicate regression assertion.
  - `[false]` `[reject]` Post-drain test did not call sendExecute — the test explicitly simulates a post-drain transport and does not claim to verify the wire drain; live integration executes carrier statements and checks the pending queue empties.
  - `[medium]` `[patch]` Queue-depth assertions did not establish server-side release for the changed identity dedupe — added a V$TEMPORARY_LOBS baseline and post-carrier comparison to the CLOB conversion integration case, passing on both Oracle versions.
  - `[low]` `[patch]` Three integration comments still described two frees — changed each to describe the one shared locator identity asserted by the tests.
  - `[false]` `[reject]` A 12-byte nonstandard locator could collide with a standard locator's identity slice — nonstandard buffers fall back to their full contents, but no reachable 12-byte temporary locator or equal live identity was shown; the cited 40-byte standard format uses the measured identity range.
  - `[maybe-false]` `[defer]` A second handle could remain open after the first removes the ownership claim — the same unverified two-handle identity condition as the blind-hunter row; response aliasing shares one handle, so a separate live or decoder reproducer is needed.
  - `[low]` `[patch]` Materialize-queued diagnostics count pending duplicates — the same counter defect above; one queue-acceptance check and regression assertion fix both reports.
  - `[low]` `[patch]` The 1,000-pending-free warning lacked verification — added a logger assertion for no warning at 999 and exactly one warning after 1,001 distinct queues.
  - `[low]` `[patch]` The existing p := p duplicate test did not assert the materialize counter — added assertions that a duplicate increments skipped-duplicate and leaves materialize-queued at zero.
  - `[medium]` `[patch]` Intent-level server release was not exercised by the changed integration assertions — the new CLOB integration check measures V$TEMPORARY_LOBS after the carrier execute on both Oracle versions; it shares the server-verification fix above.

### 2026-10-14 — Follow-up review pass
- verdicts: 10 findings — high 0, medium 0, low 3, false 5, maybe-false 2
- findings:
  - `[false]` `[reject]` A 12-byte nonstandard locator could share a standard locator's identity key — carried from the prior pass: the reviewer showed no reachable 12-byte temporary locator with equal live identity; the standard format measured here is 40 bytes.
  - `[maybe-false]` `[defer]` Independent handles for one locator identity could lose the ownership claim on first close — carried from the prior pass: response aliases share one handle; a reachable two-handle reproducer is still needed.
  - `[maybe-false]` `[defer]` Distinct identities could collide at scale or across BLOB and NCLOB — the current live measurement covers two CLOBs; a many-allocation cross-type server run would settle it. Recorded in this spec's deferred list.
  - `[low]` `[patch]` BLOB conversion had no server-side free assertion — added a V$TEMPORARY_LOBS baseline and post-carrier comparison; existing caller-owned handle tests already check server release.
  - `[false]` `[reject]` Handle registration and release lack a public-path test — live create/bind/materialize/close and carrier-execute cases already exist in lob_temporary_integration_test.dart and lob_coexistence_integration_test.dart.
  - `[false]` `[reject]` DW-120 being done proves the unbounded queue was wrongly resolved — ledger status and resolution are orchestrator bookkeeping; this pass does not modify or reassess those entries.
  - `[low]` `[patch]` The ownership comment still claimed the two paths were mutually exclusive — clarified that a caller-owned handle can be bound while an OUT locator materializes and that the ownership claim prevents premature queueing.
  - `[false]` `[reject]` A 12-byte nonstandard locator could collide with the standard identity slice — carried from the prior pass; no reachable matching temporary locator was demonstrated.
  - `[low]` `[patch]` Warning reset after execute had no regression coverage — extended the unit test to drain a first batch through sendExecute and assert a second warning at the next threshold.
  - `[false]` `[reject]` The diff's ledger changes conflict with this invocation — those entries were changed in earlier commits; this follow-up pass leaves the ledger and sprint-status.yaml untouched.

## Auto Run Result

Status: done

Summary: Follow-up review hardened verification of the temporary LOB free queue's BLOB release and warning reset, and corrected the ownership comment.

Files changed: `lib/src/transport/transport.dart` clarifies ownership; `test/src/transport/lob_materialize_wrap_test.dart` checks a second warning cycle; `test/integration/blob_integration_test.dart` checks server-side release; this result file records review and verification.

Review: three low findings patched, two unverified risks deferred in the spec (one carried from the prior pass), and five findings rejected with reasons in the triage log. No medium or high findings were patched. Follow-up review recommended: false.

Verification: `dart test test/src/transport/lob_materialize_wrap_test.dart` passed; the BLOB integration file passed against Oracle 23ai and Oracle 21c; `dart analyze` reported no issues for the edited code and tests. The previous run's full integration script passed against both databases before these test and comment changes.

Residual risks: the pre-existing oversized-OUT and multiple-handle questions remain deferred; identity uniqueness at larger allocation counts and across LOB types remains unverified. The warning-cycle unit test stops at the fake transport's wire boundary after the execute drain.
