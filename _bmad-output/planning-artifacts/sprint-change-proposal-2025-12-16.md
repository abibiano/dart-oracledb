# Sprint Change Proposal - Test Suite Alignment with Oracle 23ai Protocol

**Date:** 2025-12-16
**Project:** dart-oracledb
**Author:** PM Agent (John) with Alex
**Status:** Pending Approval

---

## Executive Summary

During Epic 1 implementation, Stories 1-4-FIX (Authentication Protocol Debugging) and 1-8-FIX (Wrong Password Error Handling) revealed critical Oracle 23ai authentication protocol details that were not fully understood when initial tests were written. This proposal recommends creating **Epic 6: Test Architecture & Coverage** to establish comprehensive test standards, rework Epic 1 authentication tests, and validate Epic 2's existing work before proceeding.

**Impact:** Adds 1-2 weeks of focused test work between Epic 1 and Epic 2. No change to MVP scope or features.

**Recommendation:** APPROVED for implementation - addresses quality foundation critical for production reliability.

---

## Section 1: Issue Summary

### Problem Statement

The unit and integration test suite for dart-oracledb was written before the complete Oracle 23ai authentication protocol was fully understood. Stories 1-4-FIX and 1-8-FIX revealed critical protocol details (FAST_AUTH, hex-encoded crypto values, wrong password timeout handling) that invalidate test assumptions. The test suite needs rework to align with the discovered authentication protocol behavior and ensure Epic 2+ work builds on a solid, properly-tested foundation.

### Discovery Context

**Triggering Stories:**
- **Story 1-4-FIX:** Authentication Protocol Debugging (DONE)
- **Story 1-8-FIX:** Wrong Password Error Handling (DONE)

**When Discovered:** Epic 1 implementation phase (2025-12-14 through 2025-12-16)

**How Discovered:** Byte-level protocol debugging and comparison with node-oracledb reference implementation revealed Oracle 23ai-specific protocol requirements not documented in official Oracle specifications.

### Evidence

**From Story 1-4-FIX (Authentication Protocol Debugging):**
- Discovered FAST_AUTH protocol requirement (message type 34) combining Protocol Negotiation + Data Types Negotiation + AUTH_PHASE_ONE into single message
- Identified critical crypto format: ALL cryptographic values must be **hex-encoded STRINGS** (uppercase), not raw bytes
- Affected values: AUTH_SESSKEY (64 hex chars), AUTH_PBKDF2_SPEEDY_KEY (160 hex chars), AUTH_PASSWORD (variable hex)
- Protocol byte structure can be byte-perfect but still fail if crypto values are wrong format
- Reference: architecture.md lines 706-748

**From Story 1-8-FIX (Wrong Password Error Handling):**
- Oracle 23ai closes connection **silently** when authentication fails due to wrong password (no error packet sent)
- Client's `socket.read()` waits indefinitely for data that never arrives
- Solution: Added 5-second `authTimeout` to detect wrong password (previously 30 seconds)
- Error thrown: OracleException with errorCode 1017 (oraInvalidCredentials)
- Reference: architecture.md lines 761-786

**Current Test State:**
Existing tests likely:
- Were written before these protocol discoveries
- May not cover FAST_AUTH protocol correctly
- May not test hex-encoding of crypto values
- May not validate wrong password timeout behavior (5s)
- May assume different error handling patterns

---

## Section 2: Impact Analysis

### Epic Impact

**Epic 1: Core Connection & Authentication (IN-PROGRESS)**

**Current Status:**
- Functional implementation: COMPLETE (all stories 1.1-1.8 marked DONE)
- Test coverage: GAPS IDENTIFIED

**Required Changes:**
- Rework unit tests to validate FAST_AUTH protocol message structure
- Add tests for hex-encoded cryptographic value format
- Add tests for wrong password timeout detection (5 seconds)
- Validate integration tests cover Oracle 23ai-specific behaviors (MARKER packets, sequence counters)

**Impact Level:** HIGH - Test gaps create risk for production deployment

---

**Epic 2: Query Execution & Transactions (READY)**

**Current Status:**
- Stories 2.1-2.4: "dev-complete-pending-validation"
- Stories 2.5-2.8: backlog

**Required Changes:**
- Validate stories 2.1-2.4 have adequate test coverage before proceeding to 2.5+
- Review tests for EXECUTE message, result set handling, bind parameters, DML operations
- Identify and remediate any test gaps

**Impact Level:** HIGH - Cannot confidently proceed to Story 2.5+ without validated foundation

---

**Epic 3: PL/SQL Execution (BACKLOG)**

**Impact Level:** MEDIUM - Depends on validated Epic 2 foundation

---

**Epic 4: Advanced Data Types (BACKLOG)**

**Impact Level:** MEDIUM - Depends on validated Epic 2 foundation

---

**Epic 5: Connection Pooling (BACKLOG)**

**Impact Level:** MEDIUM - Depends on validated Epic 1 (authentication, connection lifecycle) foundation

---

### New Epic Required

**Epic 6: Test Architecture & Coverage** (NEW)

**Purpose:**
- Establish comprehensive test architecture standards
- Rework Epic 1 tests to validate discovered authentication protocol
- Validate Epic 2 stories 2.1-2.4 before proceeding
- Set up CI/CD integration test automation

**Priority:** CRITICAL - blocks Epic 2.5+ progression

**Insertion Point:** Between Epic 1 and Epic 2

**Stories:**
1. Story 6.1: Test Architecture Design & Standards
2. Story 6.2: Epic 1 Authentication Test Suite Rework
3. Story 6.3: Epic 2 Validation - Review Existing "Pending-Validation" Stories
4. Story 6.4: CI/CD Integration Test Automation

**Estimated Effort:** 1-2 weeks

---

### Artifact Conflicts

**PRD (docs/prd.md):**
- **Conflict:** None - MVP goals remain intact
- **Change Needed:** Add NFR15 (Testing requirement)
- **Impact:** Codifies comprehensive protocol testing requirement

**Architecture (docs/architecture.md):**
- **Conflict:** None - architecture already documents protocol discoveries
- **Change Needed:** Expand "Testing & Documentation" section with detailed test strategy
- **Impact:** Documents test architecture approach

**Epics (docs/epics.md):**
- **Conflict:** None - functional epics remain valid
- **Change Needed:** Add Epic 6 definition, update epic sequencing
- **Impact:** Inserts test epic between Epic 1 and Epic 2

**Technical Impact:**
- CI/CD pipeline: Validate integration tests run against Oracle 23ai
- Test coverage: May need coverage reporting tools
- Documentation: README.md and CHANGELOG.md references to "passing tests"

---

## Section 3: Recommended Approach

### Selected Path Forward

**HYBRID APPROACH - Dedicated Test Epic (Epic 6)**

### Rationale

**Why Not Pure "Direct Adjustment" (scattered test stories)?**
- Scattering test improvements across multiple epics lacks cohesion
- Doesn't establish unified test architecture for future work
- Risk of inconsistent test coverage standards across epics

**Why Not "Rollback"?**
- Stories 1-4-FIX and 1-8-FIX are the **solutions**, not the problem
- Rolling back would lose critical protocol knowledge and break working authentication
- Makes zero sense

**Why Not "PRD MVP Review"?**
- MVP is 100% achievable - this is test coverage, not feature feasibility
- No scope reduction needed

**Why Dedicated Test Epic?**
- Provides clear scope boundary and focus
- Establishes test architecture standards for all future epics
- Validates both Epic 1 (authentication) and Epic 2 (existing stories) systematically
- Prevents "rush to Epic 5 then discover issues" scenario

### Implementation Effort & Timeline Impact

**Effort Estimate:** 1-2 weeks of focused test work

**Timeline Impact:**
- Short-term: Adds 1-2 weeks before Epic 2.5+ can proceed
- Long-term: Saves weeks of debugging and rework by catching issues early

**Breakdown:**
- Story 6.1 (Test Architecture Design): 1-2 days
- Story 6.2 (Epic 1 Test Rework): 3-5 days
- Story 6.3 (Epic 2 Validation): 2-4 days
- Story 6.4 (CI/CD Automation): 2-3 days

### Technical Risk & Complexity

**Risk Level:** LOW

**Why Low Risk?**
- Tests de-risk the actual implementation
- Addresses authentication protocol edge cases discovered in 1-4-FIX and 1-8-FIX
- Ensures Epic 2+ builds on validated foundation

**Complexity:**
- Test architecture design requires thought but not complex
- Epic 1 test rework benefits from clear protocol understanding (now documented)
- Epic 2 validation is straightforward code review + test analysis

### Team Morale & Momentum

**Positive Impact:**
- Shows commitment to quality over speed
- Prevents "rush to Epic 5 then discover issues" scenario
- Creates confidence in the codebase

**Prevents Burnout:**
- Catching issues now vs. debugging production failures later

### Long-term Sustainability & Maintainability

**Critical for Open-Source Package:**
- pub.dev users expect solid test coverage
- Test suite enables confident refactoring
- Makes future protocol changes (Oracle updates) easier to validate

**Maintainability:**
- Clear test standards prevent technical debt accumulation
- CI/CD automation catches regressions immediately

### Stakeholder Expectations & Business Value

**PRD Requirement:**
- "All core integration tests passing against Oracle 23ai" (line 71)
- This proposal delivers on that requirement properly

**Production Reliability:**
- PRD states: "Production reliability—the package works reliably in the author's own production environment" (line 65)
- Comprehensive tests ensure production reliability

---

## Section 4: Detailed Change Proposals

### Change Proposal 1: PRD - Add NFR15

**File:** docs/prd.md
**Section:** Non-Functional Requirements (after NFR14 on line 464)

**Change:**

Add new NFR15:

```markdown
- NFR15: Test suite must comprehensively validate Oracle 23ai protocol-specific behaviors including FAST_AUTH protocol, hex-encoded cryptographic values, and edge cases (wrong password handling, connection failures). Integration tests must run against Oracle 23ai to catch protocol deviations.
```

**Rationale:** Codifies the requirement for comprehensive protocol testing discovered through Epic 1 work.

**Status:** ✅ APPROVED

---

### Change Proposal 2: Architecture - Expand Testing Section

**File:** docs/architecture.md
**Section:** Testing & Documentation (lines 174-178)

**Change:**

Replace existing Testing & Documentation table with expanded version:

```markdown
### Testing & Documentation

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Testing strategy** | Integration-first against Oracle 23ai Docker + Comprehensive unit tests | Real database validation over mocks, with protocol-layer unit tests |
| **Test architecture** | Epic 6: Test Architecture & Coverage | Dedicated epic establishes test standards, validates Epic 1 authentication protocol, ensures Epic 2+ foundation |
| **Test coverage requirements** | Unit tests for protocol layers (transport, TTC, crypto), Integration tests covering Oracle 23ai-specific behaviors (FAST_AUTH, hex crypto, edge cases) | Validates discovered protocol details from Stories 1-4-FIX and 1-8-FIX |
| **CI/CD integration** | Automated integration tests against Oracle 23ai in CI pipeline | Continuous validation of protocol compatibility |
| **Documentation** | README + dartdoc | Standard Dart: quickstart in README, API via dartdoc |
```

**Rationale:** Expands testing section to reflect the comprehensive test architecture approach being implemented in Epic 6.

**Status:** ✅ APPROVED

---

### Change Proposal 3: Epics - Add Epic 6 Definition

**File:** docs/epics.md
**Section:** After Epic 5 (around line 849)

**Change:**

Add complete Epic 6 definition with 4 stories (see full definition in epics.md).

**Status:** ✅ APPROVED

---

### Change Proposal 4: Epics - Update Epic List and Sequencing

**File:** docs/epics.md
**Section:** Epic List (around line 181)

**Change:**

Add epic sequence note:

```markdown
## Epic List

**Epic Execution Sequence:** Epic 1 → **Epic 6** → Epic 2 → Epic 3 → Epic 4 → Epic 5

**Note:** Epic 6 (Test Architecture & Coverage) must complete BEFORE Epic 2 Story 2.5+ can proceed.
```

**Status:** ✅ APPROVED

---

## Section 5: Implementation Handoff

### Change Scope Classification

**MODERATE**

**Justification:**
- Requires backlog reorganization (new epic insertion)
- Requires multiple artifact updates (PRD, Architecture, Epics)
- Does NOT require fundamental architectural replanning
- Does NOT change MVP scope or business goals

### Handoff Recipients and Responsibilities

**1. Product Manager (PM) - Alex**

**Responsibilities:**
- Approve this Sprint Change Proposal
- Review and approve Epic 6 definition
- Review and approve all artifact changes
- Make final decision on test coverage standards

**Deliverables:**
- Approved Sprint Change Proposal document
- Updated PRD with NFR15
- Updated Epics with Epic 6

---

**2. Scrum Master (SM)**

**Responsibilities:**
- Update backlog with Epic 6
- Reorganize sprint planning to accommodate Epic 6
- Update sprint-status.yaml
- Facilitate Epic 6 story breakdown

**Deliverables:**
- Updated sprint-status.yaml with Epic 6
- Sprint plan reflecting Epic 6 insertion

---

**3. Test & Automation Engineer (TEA)**

**Responsibilities:**
- Design test architecture standards (Story 6.1)
- Implement Epic 1 test suite rework (Story 6.2)
- Validate Epic 2 "pending-validation" stories (Story 6.3)
- Set up CI/CD integration test automation (Story 6.4)

**Deliverables:**
- Test architecture design document
- Reworked test suite for Epic 1
- Validation report for Epic 2 stories 2.1-2.4
- CI/CD pipeline with automated Oracle 23ai integration tests

---

**4. Development Team (DEV)**

**Responsibilities:**
- Participate in Epic 6 story execution
- Ensure future epics follow established test standards
- Continue Epic 2+ work AFTER Epic 6 completion

**Deliverables:**
- Test code aligned with test architecture standards

---

### Success Criteria

**Epic 6 Completion Criteria:**
1. Test architecture standards document approved
2. Epic 1 test suite reworked with ≥90% coverage on authentication code
3. All Epic 1 tests pass against Oracle 23ai
4. Epic 2 stories 2.1-2.4 validated and marked "done"
5. CI/CD pipeline running automated integration tests
6. Test coverage reporting enabled (aim: ≥80% overall)

---

## Section 6: PRD MVP Impact

**MVP Scope Impact:** ✅ **NO CHANGE**

The PRD MVP remains fully achievable. This is a quality/validation initiative, not a feature expansion.

**Timeline Impact:**
- Adds 1-2 weeks between Epic 1 and Epic 2
- **Benefit:** Prevents weeks of debugging/rework by establishing solid test foundation

---

## Conclusion

This Sprint Change Proposal addresses critical test coverage gaps identified during Epic 1 implementation. By creating Epic 6: Test Architecture & Coverage, we establish a solid, validated foundation for Epic 2+ work while maintaining the PRD MVP scope.

**Recommendation:** APPROVE and proceed with artifact updates and Epic 6 execution.

**Timeline Impact:** +1-2 weeks before Epic 2.5+ (acceptable for quality assurance)

**Risk Mitigation:** Prevents weeks of future debugging by catching issues now

**Production Readiness:** Ensures dart-oracledb meets the PRD's production reliability goal

---

**Approval Signature:**

- [ ] **Product Manager (Alex):** ________________ Date: ______
- [ ] **Scrum Master:** ________________ Date: ______
- [ ] **Test & Automation Engineer:** ________________ Date: ______

---

**Document Version:** 1.0
**Generated By:** PM Agent (John) via Correct Course Workflow
**Date:** 2025-12-16
