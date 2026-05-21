# Test Coverage Tracking - dart-oracledb

**Purpose:** Track test coverage metrics per epic and ensure quality gates are met

**Version:** 1.1
**Date:** 2025-12-16
**Last Updated:** 2026-05-21 (Story 6.2 completion)

---

## Coverage Targets

### Overall Project

| Metric | Target | Status |
|--------|--------|--------|
| Line Coverage (unit + auth integration) | ≥85% | 🟡 78.2% |
| Epic 1 Authentication Code | ≥90% | ✅ **93.8%** (Story 6.2) |

### Layer-Specific Targets (Post Story 6.2 - 2026-05-21)

| Layer | Target | Current | Status | Priority |
|-------|--------|---------|--------|----------|
| **Crypto** | ≥90% | **93.4%** | ✅ Meets target | - |
| **Protocol** | ≥90% | 87.3% | 🟡 Near target | Epic 2/3/4 stories |
| **Transport** | ≥90% | 68.4% | 🔴 Below target (Socket needs Docker integration) | Story 6.3+ |
| **Connection API** | ≥85% | 40.6% | 🔴 Below target | Story 6.3+ |
| **Pool** | ≥85% | Not impl | ⚪ N/A | Epic 5 |
| **Data Types** | ≥85% | TBD | ⚪ TBD | Epic 2 |

---

## Epic Coverage Tracking

### Epic 1: Core Connection & Authentication

**Status:** ✅ Functionally Complete, ✅ Validated (Story 6.2 - 2026-05-21)

**Final Coverage (2026-05-21 - Post Story 6.2):**

| Module | Coverage | Target | Status | Notes |
|--------|----------|--------|--------|-------|
| `lib/src/crypto/auth.dart` | **93.1%** | ≥90% | ✅ | Hex encoding + integration auth flow |
| `lib/src/crypto/session_key.dart` | **97.4%** | ≥90% | ✅ | Session key derivation |
| `lib/src/crypto/verifier.dart` | 85.7% | ≥90% | 🟡 | 2 defensive branches uncovered |
| `lib/src/protocol/messages/auth_message.dart` | **92.9%** | ≥90% | ✅ | AUTH_PHASE_ONE/TWO + decode paths |
| `lib/src/protocol/messages/fast_auth_message.dart` | **97.4%** | ≥90% | ✅ | FAST_AUTH envelope |
| **Total Epic 1 Auth Code** | **93.8%** | **≥90%** | **✅** | **MEETS AC5 TARGET** |

**Test Counts (Final):**
- Unit Tests: 492 passing, 8 skipped (mock-based, replaced by integration)
- Integration Tests (auth): 12 passing against Oracle 23ai Docker
- New tests added in Story 6.2: 49+ (14 FAST_AUTH + 6 hex crypto + 6 security + 7 MARKER + 6 sequence + 24 error path + ~ AUTH_PHASE_ONE/TWO)

**Gap Analysis:**

| Gap | Impact | Resolution |
|-----|--------|------------|
| Integration tests not run during Story 1.4 dev | HIGH | Story 1.4 marked "done" but broken | Story 6.2: Comprehensive auth validation |
| Error path testing inconsistent | MEDIUM | Missed in Stories 1.2, 1.3, 1.5, 1.7 | Story 6.2: Add error path tests |
| Protocol edge cases discovered late | HIGH | FAST_AUTH, hex crypto found in debugging | Story 6.2: Protocol-specific validation |
| Security tests (NFR5) added reactively | MEDIUM | 3 violations in code reviews | Story 6.2: Security test suite |

**Story 6.2 Target:** ≥90% coverage for all Epic 1 authentication code

---

### Epic 2: Query Execution & Transactions

**Status:** ✅ Complete — protocol rebuilt, SELECTs/binds/DML all validated against Oracle 23ai (Story 6.3, 2026-05-21)

**Current Coverage (2026-05-21 — Post Story 6.3):**

| Story | Status | Coverage | Notes |
|-------|--------|----------|-------|
| 2.1: Execute Message & Basic Query | done | ✅ Unit + 6/6 integration | Wire protocol completely rewritten to real Oracle TTC OALL8. SELECT * FROM dual, multi-column, multi-row, NULL, case-insensitive name access all validated. |
| 2.2: Result Set Handling | done | ✅ Unit + 6/6 integration | OracleResult/OracleRow API validated against Oracle 23ai. Missing 2-2 artifact documented in Story 6.3 DAR. |
| 2.3: Bind Parameters | done | ✅ Unit + 12/12 integration | All bind paths validated: positional, named, repeated named, NULL, count mismatch, missing named, invalid type. |
| 2.4: DML Operations | done | ✅ Unit + 20/20 integration | Oracle BREAK/RESET MARKER protocol implemented in transport. INSERT (positional/named/NULL), UPDATE (single/multi/zero rows), DELETE (single/multi/zero rows), duplicate key (ORA-00001), table-not-found (ORA-00942), invalid column (ORA-00904) all validated against Oracle 23ai. |
| 2.5: Transaction Management | dev-complete-pending-validation | 🔴 Needs revalidation | Was `review` pre-Story-6.3 but the protocol rebuild invalidates earlier integration runs. |
| 2.6: Basic Data Type Mapping | dev-complete-pending-validation | 🔴 Needs revalidation | Was `review` pre-Story-6.3 but the protocol rebuild invalidates earlier integration runs. |
| 2.7: Statement Caching | backlog | N/A | Not started |
| 2.8: Query Error Handling | backlog | N/A | Not started |

**Story 6.3 Outcome (sessions 1 + 2):**
- Pre-rebuild integration baseline: **4/38** query integration tests passed (all 34 network-bound tests failed with `ORA-12150 Connection closed by server`).
- Post-rebuild integration baseline (session 1): **18/38** pass (all SELECTs + all bind validation).
- Post-DML-fix integration baseline (session 2): **38/38** pass — all query, bind, and DML tests validated against Oracle 23ai.
- Unit baseline: 472/472 pass (462 post-rebuild + 10 additional execute_message tests added for DML/review-patch coverage).
- `dart analyze` clean.
- Critical defect (session 1): original `execute_message.dart` implemented an invented wire format. Rebuilt against node-oracledb thin client reference.
- DML hang root cause (session 2): Oracle sends BREAK+RESET MARKER packets for constraint violations requiring client acknowledgment. Implemented `_sendResetMarker()` in `lib/src/transport/transport.dart` and BREAK detection in `_receiveAllTtcData()`.

---

### Epic 3: PL/SQL Execution

**Status:** ⚪ Not Started

**Target Coverage:** ≥85%

| Story | Status | Estimated Coverage Target |
|-------|--------|---------------------------|
| 3.1: Call Stored Procedures | backlog | ≥85% (unit + integration) |
| 3.2: Call Functions with Return Values | backlog | ≥85% (unit + integration) |
| 3.3: OUT and IN/OUT Parameters | backlog | ≥85% (unit + integration) |

---

### Epic 4: Advanced Data Types

**Status:** ⚪ Not Started

**Target Coverage:** ≥85%

| Story | Status | Estimated Coverage Target |
|-------|--------|---------------------------|
| 4.1: CLOB Support | backlog | ≥85% (unit + integration) |
| 4.2: BLOB Support | backlog | ≥85% (unit + integration) |
| 4.3: RAW Data Type | backlog | ≥85% (unit + integration) |
| 4.4: JSON Data Type | backlog | ≥85% (unit + integration) |

---

### Epic 5: Connection Pooling

**Status:** ⚪ Not Started

**Target Coverage:** ≥90% (critical for resource management)

| Story | Status | Estimated Coverage Target |
|-------|--------|---------------------------|
| 5.1: Create Connection Pool | backlog | ≥90% (concurrency critical) |
| 5.2: Acquire and Release Connections | backlog | ≥90% (resource management) |
| 5.3: Pool Timeout and Cleanup | backlog | ≥90% (error handling critical) |
| 5.4: Session Tagging | backlog | ≥85% |

---

### Epic 6: Test Architecture & Coverage

**Status:** 🟢 In Progress

**Current Story:**

| Story | Status | Coverage Target | Achieved |
|-------|--------|-----------------|----------|
| 6.1: Test Architecture Design & Standards | ✅ done | N/A (documentation) | ✅ |
| 6.2: Epic 1 Authentication Test Suite Rework | ✅ review | ≥90% Epic 1 coverage | ✅ **93.8%** |
| 6.3: Epic 2 Validation | ✅ review | Validate Stories 2.1-2.4 | ✅ **38/38** integration tests pass |
| 6.4: CI/CD Integration | backlog | N/A | - |

---

## Coverage Analysis Commands

### Generate Coverage Report

```bash
# Run tests with coverage (unit tests only)
dart test --coverage=coverage --exclude-tags=integration

# Include integration tests
RUN_INTEGRATION_TESTS=true dart test --coverage=coverage

# Convert to lcov format
dart pub global activate coverage
dart pub global run coverage:format_coverage \
  --lcov \
  --in=coverage \
  --out=coverage/lcov.info \
  --report-on=lib

# Generate HTML report
genhtml coverage/lcov.info -o coverage/html

# Open in browser
open coverage/html/index.html
```

### Coverage by Directory

```bash
# Protocol layer coverage
lcov --extract coverage/lcov.info 'lib/src/protocol/*' -o coverage/protocol.info
genhtml coverage/protocol.info -o coverage/html/protocol

# Transport layer coverage
lcov --extract coverage/lcov.info 'lib/src/transport/*' -o coverage/transport.info
genhtml coverage/transport.info -o coverage/html/transport

# Crypto layer coverage
lcov --extract coverage/lcov.info 'lib/src/crypto/*' -o coverage/crypto.info
genhtml coverage/crypto.info -o coverage/html/crypto

# Connection API coverage
lcov --extract coverage/lcov.info 'lib/src/connection/*' -o coverage/connection.info
genhtml coverage/connection.info -o coverage/html/connection
```

### Coverage Metrics

```bash
# Line coverage
lcov --summary coverage/lcov.info

# Detailed coverage by file
lcov --list coverage/lcov.info

# Branch coverage
lcov --summary coverage/lcov.info --rc lcov_branch_coverage=1
```

---

## Coverage Gates

### Story Completion Gate

**Before marking story "done":**

- [ ] Overall coverage ≥85% (or layer-specific target)
- [ ] No critical paths uncovered
- [ ] All acceptance criteria have associated tests
- [ ] Error paths tested
- [ ] Edge cases covered
- [ ] Security tests (if applicable)

### Epic Completion Gate

**Before marking epic "done":**

- [ ] Epic coverage meets target (≥85-90%)
- [ ] All stories have passing tests
- [ ] Integration tests validated against Oracle 23ai
- [ ] Regression tests passing
- [ ] No known coverage gaps

### Release Gate

**Before production release:**

- [ ] Overall project coverage ≥85%
- [ ] All critical layers ≥90% (protocol, transport, crypto)
- [ ] All integration tests passing
- [ ] Security tests (NFR5) passing
- [ ] Cross-platform tests passing
- [ ] Performance baselines met

---

## Coverage Improvement Plan

### Short-Term (Epic 6)

**Story 6.2: Epic 1 Authentication Test Suite Rework**

- Target: ≥90% coverage for Epic 1 authentication code
- Focus: Integration tests against Oracle 23ai
- Priorities:
  1. FAST_AUTH protocol validation
  2. Hex-encoded crypto value tests
  3. Wrong password timeout tests (5s)
  4. MARKER packet handling
  5. Sequence counter validation
  6. Security tests (NFR5)
  7. Error path completion

**Story 6.3: Epic 2 Validation**

- Target: Validate Stories 2.1-2.4 with integration tests
- Focus: Query execution, result sets, bind parameters, DML
- Priorities:
  1. Validation Stories 2.1-2.4
  2. Create integration tests
  3. Fix any issues found
  4. Achieve ≥85% coverage

### Medium-Term (Epic 2-5)

**Epic 2 Continuation (Stories 2.5-2.8):**

- Maintain ≥85% coverage from story start
- Integration tests mandatory before "done"
- Error path testing checklist

**Epic 3-5:**

- Apply lessons from Epic 1 retrospective
- Integration-first testing strategy
- Reference implementation (node-oracledb) comparison
- Security checklist (NFR5) for all credential handling

### Long-Term (Production Readiness)

**Quality Gates:**

- Overall coverage ≥85%
- Critical layers ≥90%
- All integration tests passing
- Cross-platform validation
- Performance regression testing
- Security audit passing

---

## Coverage Tracking Process

### Weekly Review

1. Generate coverage report
2. Compare against targets
3. Identify gaps
4. Prioritize improvements
5. Update tracking document

### Per-Story Tracking

1. **Before Development:**
   - Identify coverage target for story
   - Define acceptance criteria with test requirements

2. **During Development:**
   - Write tests first (red-green-refactor)
   - Monitor coverage as implementation progresses
   - Ensure error paths covered

3. **Before Marking "Done":**
   - Run coverage report
   - Verify target met
   - Document any exceptions

4. **After Code Review:**
   - Address coverage gaps found in review
   - Update coverage tracking

### Per-Epic Tracking

1. **Epic Planning:**
   - Set epic coverage target
   - Define critical paths requiring high coverage

2. **Epic Execution:**
   - Track coverage per story
   - Maintain running epic coverage total

3. **Epic Completion:**
   - Final coverage validation
   - Retrospective: coverage effectiveness review
   - Update baselines for next epic

---

## Coverage Exceptions

### When Coverage May Be <85%

| Scenario | Acceptable Coverage | Justification |
|----------|---------------------|---------------|
| Generated code | Varies | Auto-generated may have unreachable paths |
| Legacy compatibility | <85% | May be deprecated/removed |
| Defensive error handling | <85% | "Should never happen" paths |

**Process for Exceptions:**

1. Document exception in code comments
2. Add to coverage tracking document
3. Get approval from team lead
4. Plan future remediation if possible

---

## Epic 1 Baseline Coverage Snapshot (2025-12-16)

**Before Story 6.2 Rework:**

```
Overall Coverage: ~75%

lib/src/transport/
  packet.dart:              78%
  tns_protocol.dart:        72%
  socket_handler.dart:      80%

lib/src/protocol/
  ttc_protocol.dart:        68%
  messages/
    auth_message.dart:      75%
    fast_auth_message.dart: 65%
    connect_message.dart:   80%

lib/src/crypto/
  auth.dart:                82%
  pbkdf2.dart:              85%
  sha512.dart:              78%

lib/src/connection/
  connection.dart:          70%
  connection_string.dart:   85%
  error.dart:               75%

Test Counts:
  Unit Tests: 268+
  Integration Tests: 30+
  Total: 298+

Gaps Identified:
  - Integration tests not run during Story 1.4
  - Error path coverage inconsistent
  - Protocol edge cases missing
  - Security tests (NFR5) reactive, not proactive
```

**After Story 6.2 Target:**

```
Overall Coverage: ≥90% (Epic 1 only)

Protocol-specific tests added:
  - FAST_AUTH validation
  - Hex crypto encoding
  - Timeout behavior (5s wrong password)
  - MARKER packet handling
  - Sequence counter validation

Security tests (NFR5):
  - Password not in logs
  - Username not in logs
  - Credentials not in errors

Error path tests:
  - Connection failures
  - Auth failures
  - Protocol errors
```

---

## Tools and Automation

### Coverage Tools

- **dart test --coverage** - Built-in Dart coverage collection
- **lcov** - Coverage report manipulation
- **genhtml** - HTML report generation

### CI Integration (Future - Story 6.4)

```yaml
# .github/workflows/coverage.yml
name: Coverage

on: [push, pull_request]

jobs:
  coverage:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1

      - name: Install dependencies
        run: dart pub get

      - name: Run tests with coverage
        run: dart test --coverage=coverage --exclude-tags=integration

      - name: Convert coverage
        run: |
          dart pub global activate coverage
          dart pub global run coverage:format_coverage \
            --lcov --in=coverage --out=coverage/lcov.info --report-on=lib

      - name: Upload to Codecov
        uses: codecov/codecov-action@v3
        with:
          files: coverage/lcov.info
          fail_ci_if_error: true

      - name: Coverage gate
        run: |
          coverage=$(lcov --summary coverage/lcov.info | grep lines | awk '{print $2}' | sed 's/%//')
          if (( $(echo "$coverage < 85" | bc -l) )); then
            echo "Coverage $coverage% is below 85% threshold"
            exit 1
          fi
```

---

## References

- [Test Architecture](./test-architecture-dart-oracledb.md) - Test standards and requirements
- [Epic 1 Retrospective](./sprint-artifacts/epic-1-retro-2025-12-16.md) - Coverage learnings
- [Dart Coverage Package](https://pub.dev/packages/coverage)
- [LCOV Documentation](http://ltp.sourceforge.net/coverage/lcov.php)

---

## Document Metadata

**Created:** 2025-12-16
**Last Updated:** 2025-12-16
**Version:** 1.0
**Next Review:** After Epic 6 Story 6.2 completion

**Coverage Tracking Owner:** Dana (QA Engineer)

---

## Notes

- This document is a **living document** - update after each story/epic
- Coverage targets may be adjusted based on project needs
- Exceptions require team lead approval
- Focus on **meaningful coverage**, not just hitting numbers
- Integration tests MORE valuable than unit tests for protocol code

---

**End of Test Coverage Tracking Document**
