# Sprint Change Proposal
**Date:** 2025-12-16
**Trigger:** Story 2-1 completion exposed authentication failures
**Type:** Epic Reopening + Sprint Pause

---

## Executive Summary

**Critical Issue:** Epic 1 (Connection & Authentication) was marked "done" but authentication is **completely broken**. All integration tests fail with `ORA-12547: Socket closed` when attempting to authenticate.

**Root Cause:** Massive uncommitted protocol rewrite implementing node-oracledb-style TTC authentication has never been validated. The committed version from Epic 1 was incomplete (no protocol negotiation), and the current uncommitted changes don't work.

**Impact:**
- ❌ Epic 1 falsely marked complete
- ⏸️ Epic 2 blocked (cannot test query execution without connection)
- ⏸️ All downstream epics blocked

**Recommendation:** HALT Epic 2, REOPEN Epic 1, execute focused debugging sprint to fix authentication.

---

## Problem Statement

### What Went Wrong

After completing Story 2-1 (Execute Message/Basic Query), attempting to run integration tests revealed that **authentication has never worked**:

```
ORA-12547: Socket closed while waiting for data: need 8 bytes, have 0
```

Oracle Database closes the connection immediately after receiving the `AUTH_PHASE_ONE` message, indicating a protocol mismatch.

### Evidence

1. **Uncommitted Changes:** 8 files with major rewrites to auth protocol:
   - `lib/src/protocol/messages/auth_message.dart` - Complete rewrite from simple to complex format
   - `lib/src/crypto/auth.dart` - New protocol negotiation flow
   - `lib/src/transport/transport.dart` - TTC protocol support
   - Plus 5 other files

2. **Test Results:**
   ```
   ✗ All integration tests fail at authentication
   ✗ AUTH_PHASE_ONE message sent (220 bytes)
   ✗ Oracle closes connection without responding
   ```

3. **Git History:**
   - Epic 1 Story 1-4 (authentication) committed at `b17a3ee`
   - Committed version had simple auth format (may never have worked)
   - Current uncommitted version has complex node-oracledb-style format (doesn't work)
   - **No evidence authentication ever passed tests**

### Technical Analysis

**Message Format Investigation:**
- Byte-by-byte comparison with node-oracledb reference shows format APPEARS correct
- Compile capabilities match node-oracledb
- Token numbers handled correctly for Oracle 23ai (field version 24)
- Sequence numbering appears correct (sequence=0 for first function message)

**Suspected Issues:**
1. Subtle protocol difference not caught in byte comparison
2. Missing or incorrect capability flag causing Oracle to reject auth
3. State machine issue in protocol negotiation
4. Timing or ordering issue with protocol messages

**What We Know Works:**
- ✓ TNS CONNECT/ACCEPT handshake
- ✓ Protocol negotiation (receives server version 6, field version 25)
- ✓ Data types negotiation (2479 byte response)
- ✗ AUTH_PHASE_ONE (Oracle terminates connection)

---

## Epic Impact Analysis

| Epic | Current Status | Impact | Action Required |
|------|----------------|--------|-----------------|
| **Epic 1** | ❌ Marked "done" | Foundation broken | **REOPEN** - Auth story incomplete |
| **Epic 2** | In-progress | Blocked | **PAUSE** - Cannot test without connection |
| Epic 3 | Backlog | Blocked | No action - already blocked |
| Epic 4 | Backlog | Blocked | No action - already blocked |

### Story-Level Impact

**Epic 1 Stories to Revisit:**
- ✓ 1-1 Project Init - Still valid
- ✓ 1-2 TNS Transport - Working
- ✓ 1-3 TTC Protocol Foundation - Partially working (negotiation OK, auth broken)
- ❌ **1-4 Authentication** - **MUST REOPEN** - Never validated
- ? 1-5 Connection API - Cannot validate until auth works
- ✓ 1-6 TLS/SSL - Likely OK (transport layer)
- ✓ 1-7 Lifecycle Mgmt - Likely OK (disconnect works)

**Epic 2 Stories Affected:**
- 2-1 Execute Message - Implementation done but **cannot test**
- 2-2 Result Set - Implementation done but **cannot test**
- 2-3 Bind Parameters - Implementation done but **cannot test**
- 2-4 DML Operations - Implementation done but **cannot test**
- All remaining stories **blocked**

---

## Proposed Path Forward

### Immediate Actions (This Sprint)

**1. Update Sprint Artifacts** ⏱️ 15 min
- Mark Epic 1 as "in-progress" (was falsely "done")
- Reopen Story 1-4 (authentication-implementation) as "in-progress"
- Mark Epic 2 as "blocked"
- Update `sprint-status.yaml` to reflect reality

**2. Commit Current Work** ⏱️ 30 min
- Commit all uncommitted changes as WIP (Work In Progress)
- Document known issue: "AUTH_PHASE_ONE causes connection close"
- Tag as `auth-protocol-broken-v1` for reference

**3. Choose Debugging Approach** ⏱️ Decision point

Select ONE of these approaches:

#### **Option A: Deep Protocol Analysis** ⭐ RECOMMENDED
- **Task:** Capture working node-oracledb connection via Wireshark
- **Compare:** Byte-by-byte with Dart implementation
- **Outcome:** Find exact protocol difference
- **Effort:** 4-8 hours
- **Success Rate:** High (will definitively find the issue)

#### **Option B: Simplification**
- **Task:** Strip down to minimal auth protocol
- **Test:** Does basic auth work without all the compile caps?
- **Outcome:** Working connection OR confirmation complex protocol needed
- **Effort:** 2-4 hours
- **Success Rate:** Medium (may not work with Oracle 23ai)

#### **Option C: Community Help**
- **Task:** Post detailed issue with packet captures to Oracle forums
- **Wait:** For community response
- **Outcome:** Potential solution from experienced developers
- **Effort:** 1-2 hours + wait time
- **Success Rate:** Variable

#### **Option D: Pivot to OCI (Oracle Call Interface)**
- **Task:** Abandon thin driver, use Oracle's official thick client via FFI
- **Outcome:** Production-ready, guaranteed-working solution
- **Effort:** 1-2 weeks complete rewrite
- **Success Rate:** 100% (Oracle-supported)
- **Trade-off:** Requires Oracle Instant Client deployment

### Recommended Approach

**Phase 1: Quick Win Attempt** (2-4 hours)
1. Try Option B (Simplification) - strip to minimal auth
2. If works → great, understand what was wrong, add back features incrementally
3. If fails → proceed to Phase 2

**Phase 2: Deep Debugging** (4-8 hours)
1. Execute Option A (Wireshark comparison)
2. Find exact byte-level difference
3. Fix implementation
4. Validate with integration tests

**Phase 3: Contingency** (if Phases 1-2 fail after 12 hours)
1. Evaluate Option D (Pivot to OCI)
2. Make strategic decision: continue debugging or switch to thick client

---

## Sprint Adjustments

### Current Sprint Completion
- ✓ Story 2-1: Implementation complete (cannot validate)
- ✓ Story 2-2: Implementation complete (cannot validate)
- ✓ Story 2-3: Implementation complete (cannot validate)
- ⏸️ Story 2-4: In review (cannot validate)

**Proposed:** Mark these stories as "dev-complete-pending-validation" in sprint status.

### New Sprint Focus

**Primary Objective:** Fix authentication to unblock all development

**Sprint Goal:** Working connection that passes all integration tests

**Stories:**
1. **Story 1-4-FIX: Authentication Protocol Debugging**
   - **AC1:** Identify exact protocol mismatch causing connection close
   - **AC2:** Implement fix for AUTH_PHASE_ONE message
   - **AC3:** All integration tests pass (connection + auth)
   - **AC4:** Document findings for future reference

2. **Story 1-5-VALIDATE: Connection API Validation**
   - **AC1:** Validate connection lifecycle (connect, ping, close)
   - **AC2:** Integration tests for error handling
   - **AC3:** Connection pooling readiness (if applicable)

### Success Criteria

**Sprint Success:**
- ✅ Authentication works
- ✅ All Epic 1 integration tests pass
- ✅ Story 2-1 integration test passes (proves Epic 2 foundation works)

**Sprint Failure Indicators:**
- ❌ After 12 hours, still no working auth
- ❌ Protocol too complex to debug without Oracle insider knowledge
- → **Trigger:** Escalate to strategic decision (continue vs pivot to OCI)

---

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Cannot find protocol bug | Medium | Critical | Timebox to 12 hours, have OCI pivot plan ready |
| Oracle protocol undocumented | High | High | Use Wireshark + reference implementation comparison |
| Committed code never worked | High | Medium | Already assumed - focus on current implementation |
| Epic 2 work wasted | Low | Medium | Implementation is good, just needs working connection |

---

## Artifact Updates Required

### Before Starting Debug Sprint

**File:** `docs/sprint-artifacts/sprint-status.yaml`
```yaml
development_status:
  epic-1: in-progress  # Changed from "done"
  1-4-authentication-implementation: in-progress  # Reopened
  1-4-fix-auth-protocol: ready-for-dev  # New debugging story

  epic-2: blocked  # Blocked by Epic 1
  2-1-execute-message-basic-query: dev-complete-pending-validation
  2-2-result-set-handling: dev-complete-pending-validation
  2-3-bind-parameters: dev-complete-pending-validation
  2-4-dml-operations-insert-update-delete: dev-complete-pending-validation
```

**File:** `docs/architecture.md`
```markdown
## Known Issues
- **Authentication Protocol:** AUTH_PHASE_ONE message causes Oracle to close
  connection. Under investigation. See sprint-change-proposal-2025-12-16.md
```

**File:** `docs/project_context.md`
```markdown
## Critical TODOs
- [ ] FIX: Authentication broken - Oracle closes connection at AUTH_PHASE_ONE
- [ ] All Epic 2 work pending auth fix validation
```

### After Successful Fix

- Update all documents to remove "blocked" status
- Document the fix and root cause for future reference
- Run full test suite to validate Epic 1 + Epic 2 stories

---

## Questions for Product Owner

1. **Priority:** Is fixing auth the #1 priority, or should we explore other features?
2. **Timeline:** How much time can we allocate to debugging before pivoting to OCI?
3. **Strategic:** If thin driver proves too complex, is OCI (thick client) acceptable?
4. **Scope:** Should we aim for full protocol compatibility or minimal working auth?

---

## Recommendation

**APPROVE this change proposal to:**
1. ✅ Reopen Epic 1 Story 1-4 (Authentication)
2. ✅ Pause Epic 2 (mark as blocked)
3. ✅ Execute focused debugging sprint (Option A + B combination)
4. ✅ Timebox to 12 hours with OCI contingency plan

**Expected Outcome:** Working authentication within 1-2 days, Epic 2 unblocked.

---

**Prepared by:** PM John (AI Agent)
**Review Required:** Alex (Product Owner)
**Next Step:** Approval → Execute Story 1-4-FIX

