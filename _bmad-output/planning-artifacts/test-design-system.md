# System-Level Test Design - dart-oracledb

**Date:** 2025-12-15
**Author:** Alex (with TEA - Murat)
**Status:** Draft
**Mode:** System-Level (Phase 3 - Testability Review)

---

## Executive Summary

**Scope:** System-level testability assessment for dart-oracledb, a pure Dart Oracle database driver implementing TNS/TTC wire protocol.

**Testability Verdict:** PASS with recommendations

**Summary:**
- Architecture supports testability through clear layer boundaries
- Integration-first strategy aligned with project nature (database driver)
- Critical risks identified in authentication/security requiring focused testing
- No blocking testability concerns

---

## Testability Assessment

### Controllability

**Rating:** PASS (with recommendations)

| Controllability Aspect | Status | Evidence | Recommendation |
|------------------------|--------|----------|----------------|
| System state control | PASS | Layer boundaries enable mocking (transport → protocol → API) | - |
| Data seeding | CONCERNS | No test data factory abstractions defined | Add test fixtures for common Oracle states |
| Error injection | PASS | Socket-level errors injectable via transport layer | - |
| Connection pool reset | CONCERNS | No pool state reset mechanism | Add `pool.drain()` for test isolation |
| External service mocking | PASS | Transport layer abstracts Oracle - mockable for unit tests | - |

**Controllability Notes:**
- Architecture enables mocking at each layer boundary
- Oracle 23ai Docker provides real database for integration testing
- Recommend: Add test helper utilities for common setup patterns

### Observability

**Rating:** PASS (with recommendations)

| Observability Aspect | Status | Evidence | Recommendation |
|----------------------|--------|----------|----------------|
| Logging | PASS | `package:logging` with levels: fine, info, warning, severe | - |
| Oracle error codes | PASS | OracleException.errorCode surfaces ORA-xxxxx directly | - |
| Connection health | PASS | `ping()` and `isHealthy` methods defined (FR6) | - |
| Protocol debugging | CONCERNS | No explicit TNS/TTC tracing | Add verbose debug mode for wire protocol |
| Test result determinism | PASS | Async/await enables deterministic waits | - |

**Observability Notes:**
- Logging strategy is well-defined
- ORA-xxxxx error passthrough enables standard Oracle troubleshooting
- Recommend: Add protocol tracing for debugging wire-level issues

### Reliability (Test Isolation)

**Rating:** PASS (with recommendations)

| Reliability Aspect | Status | Evidence | Recommendation |
|--------------------|--------|----------|----------------|
| Test isolation | CONCERNS | Pool shared state needs isolation strategy | Use unique pool per test or drain() between tests |
| Deterministic waits | PASS | Future/Stream async patterns enable proper waits | - |
| Resource cleanup | PASS | Dual pattern: explicit `close()` + auto-close wrappers | - |
| Parallel test safety | CONCERNS | Need connection pool isolation for parallel runs | Unique service names or pool instances per test |
| Component coupling | PASS | Loose coupling between transport/protocol/API layers | - |

**Reliability Notes:**
- Clear architectural boundaries support isolation
- Connection pool requires test-friendly design for parallel execution
- Resource management patterns (dual close) support reliable cleanup

---

## Architecturally Significant Requirements (ASRs)

Requirements that drive testability decisions and pose testing challenges:

### High-Priority ASRs (Score >= 6)

| ASR ID | Category | Requirement | Probability | Impact | Score | Testing Implication |
|--------|----------|-------------|-------------|--------|-------|---------------------|
| ASR-1 | SEC | SHA512/PBKDF2 authentication (NFR7, FR2) | 3 | 3 | **9** | Crypto byte-level compatibility testing - must match Oracle exactly |
| ASR-2 | SEC | Credentials never logged (NFR5) | 3 | 3 | **9** | Security audit: scan all log output for password leaks |
| ASR-3 | TECH | Pure Dart/no FFI (constraint) | 2 | 3 | **6** | All tests must work without native dependencies |
| ASR-4 | OPS | Cross-platform (macOS/Win/Linux) (NFR12) | 2 | 3 | **6** | CI matrix testing on all platforms |
| ASR-5 | TECH | TLS/SSL encryption support (NFR6, FR3) | 2 | 3 | **6** | TLS handshake verification, certificate validation tests |
| ASR-6 | DATA | Connection pool failure recovery (NFR9) | 2 | 3 | **6** | Failure injection: broken connections, pool recovery |

### Medium-Priority ASRs (Score 3-5)

| ASR ID | Category | Requirement | Probability | Impact | Score | Testing Implication |
|--------|----------|-------------|-------------|--------|-------|---------------------|
| ASR-7 | PERF | Driver overhead minimal (NFR1) | 2 | 2 | 4 | Benchmark tests vs raw socket operations |
| ASR-8 | PERF | Statement caching reduces overhead (NFR2, FR44) | 2 | 2 | 4 | Cache hit/miss validation, performance comparison |
| ASR-9 | TECH | JIT/AOT compilation (NFR14) | 2 | 2 | 4 | AOT compilation verification in CI |

### Risk Mitigation Strategy

| ASR | Mitigation Approach | Owner | Verification Method |
|-----|---------------------|-------|---------------------|
| ASR-1 | Port directly from node-oracledb tested implementation | Dev | Byte comparison tests against reference |
| ASR-2 | Log output scanning in CI, credential regex checks | QA | Automated security audit job |
| ASR-3 | CI on pure Dart - no FFI dependencies | Dev | `dart analyze` verification |
| ASR-4 | GitHub Actions matrix: macOS ARM64/Intel, Windows, Ubuntu | DevOps | Platform-specific test runs |
| ASR-5 | TLS tests against Oracle with cert validation | Dev | Integration tests with TLS config |
| ASR-6 | Failure injection tests, pool recovery validation | QA | Connection drop simulation |

---

## Test Levels Strategy

### Test Pyramid for dart-oracledb

Based on project type (database driver library, no UI):

```
          /\
         /  \
        / E2E \        5% - Critical user journeys
       /  (5%) \
      /----------\
     /            \
    / Integration  \   55% - Protocol, Oracle interactions
   /    (55%)       \
  /------------------\
 /                    \
/    Unit Tests (40%)  \  40% - Buffer ops, type mapping
/________________________\
```

### Level Allocation Rationale

| Level | Allocation | What to Test | Why This Level |
|-------|------------|--------------|----------------|
| **Unit** | 40% | Buffer encoding/decoding, type converters, error construction, connection string parsing | Pure functions, fast feedback, isolated logic |
| **Integration** | 55% | Protocol messages, authentication flow, query execution, connection lifecycle, pool operations | Real Oracle behavior, protocol compatibility |
| **E2E** | 5% | Full connect → query → results → close workflow | Critical path validation, user journey |

### Test Level Decision Matrix

| Scenario | Test Level | Justification |
|----------|------------|---------------|
| `readUint16BE()` buffer method | Unit | Pure function, no dependencies |
| EZ Connect string parsing | Unit | Isolated parsing logic |
| Oracle type to Dart type mapping | Unit | Deterministic conversion |
| OracleException construction | Unit | Error object creation |
| AUTH_PHASE_ONE message encoding | Integration | Must match Oracle protocol |
| AUTH_PHASE_TWO authentication | Integration | Real Oracle validation needed |
| Query execution with bind params | Integration | Oracle SQL parsing involved |
| Transaction commit/rollback | Integration | Oracle transaction state |
| Connection pool acquire/release | Integration | Real connection lifecycle |
| Full CRUD workflow (connect → query → close) | E2E | Critical user journey |

---

## NFR Testing Approach

### Security (NFR5-NFR7)

| Requirement | Test Approach | Verification |
|-------------|---------------|--------------|
| NFR5: Credentials never logged | Log output scanning | CI job scans all test output for password patterns |
| NFR6: TLS/SSL encryption | TLS connection tests | Verify handshake, cert validation against Oracle |
| NFR7: SHA512/PBKDF2 auth | Auth flow integration tests | Successful auth against Oracle 23ai |

**Security Testing Tools:**
- Custom log scanner (regex for credential patterns)
- Integration tests against Oracle 23ai with TLS enabled
- Byte comparison tests for auth message encoding

**Security Test Examples:**
```dart
// NFR5: Verify password never appears in logs
test('password not logged during auth failure', () {
  final logs = captureLogOutput(() async {
    await expectThrows(() => OracleConnection.connect(
      'localhost:1521/FREEPDB1',
      user: 'test',
      password: 'secretPassword123',
    ));
  });

  expect(logs, isNot(contains('secretPassword123')));
  expect(logs, isNot(contains('password=')));
});

// NFR7: Verify SHA512/PBKDF2 authentication
test('authenticates with modern verifiers', () async {
  final conn = await OracleConnection.connect(
    'localhost:1521/FREEPDB1',
    user: 'testuser',
    password: 'testpass',
  );

  expect(conn.isConnected, isTrue);
  await conn.close();
});
```

### Performance (NFR1-NFR4)

| Requirement | Test Approach | Threshold |
|-------------|---------------|-----------|
| NFR1: Driver overhead minimal | Benchmark vs raw socket | Driver adds <5% overhead to network RTT |
| NFR2: Statement cache effective | Cache hit rate measurement | >90% hit rate for repeated queries |
| NFR3: Pool eliminates connection cost | Pool vs new connection timing | Pool acquire <10ms vs new connection |
| NFR4: Crypto latency acceptable | Auth timing measurement | Auth completes <500ms (pooling mitigates) |

**Performance Testing Tools:**
- `package:benchmark_harness` for micro-benchmarks
- Custom timing harness for connection/query measurements
- CI job for performance regression detection

**Performance Test Examples:**
```dart
// NFR2: Statement caching performance
test('statement cache improves repeated query performance', () async {
  final conn = await getConnection(statementCacheSize: 50);

  final firstExecution = await measureTime(() =>
    conn.execute('SELECT * FROM dual'));

  final cachedExecution = await measureTime(() =>
    conn.execute('SELECT * FROM dual'));

  // Cached should be faster (no parse phase)
  expect(cachedExecution, lessThan(firstExecution * 0.5));
});
```

### Reliability (NFR8-NFR10)

| Requirement | Test Approach | Verification |
|-------------|---------------|--------------|
| NFR8: Detect broken connections | Connection drop simulation | `isHealthy` returns false for broken conn |
| NFR9: Pool handles failures | Failure injection tests | Pool removes dead connections, creates new |
| NFR10: Resource cleanup | Resource leak detection | No socket leaks after close() |

**Reliability Testing Tools:**
- Socket error injection at transport layer
- Connection state verification
- Resource tracking for leak detection

**Reliability Test Examples:**
```dart
// NFR9: Pool recovers from connection failure
test('pool removes dead connections and creates new ones', () async {
  final pool = await OraclePool.create(
    'localhost:1521/FREEPDB1',
    user: 'test', password: 'test',
    minConnections: 2, maxConnections: 5,
  );

  // Get a connection and simulate failure
  final conn = await pool.acquire();
  await simulateConnectionDrop(conn);

  // Release broken connection
  await pool.release(conn);

  // Next acquire should get a healthy connection
  final newConn = await pool.acquire();
  expect(newConn.isHealthy, isTrue);

  await pool.close();
});
```

### Compatibility (NFR11-NFR14)

| Requirement | Test Approach | Verification |
|-------------|---------------|--------------|
| NFR11: Dart SDK 3.0+ | pubspec.yaml constraint | CI verifies minimum SDK |
| NFR12: Cross-platform | CI matrix testing | Tests pass on macOS, Windows, Linux |
| NFR13: Oracle 23ai support | Integration tests | Full test suite against 23ai |
| NFR14: JIT/AOT compatible | Compilation verification | AOT compile + run in CI |

**Compatibility Testing Tools:**
- GitHub Actions matrix for platforms
- Docker for Oracle 23ai
- AOT compilation job in CI

---

## Test Environment Requirements

| Environment | Purpose | Infrastructure |
|-------------|---------|----------------|
| **Local Development** | Unit tests, fast integration | Docker Compose with Oracle 23ai Free |
| **CI - Unit** | Fast feedback on PRs | GitHub Actions (no Oracle needed) |
| **CI - Integration** | Protocol/Oracle tests | GitHub Actions + Oracle 23ai container |
| **CI - Platform Matrix** | Cross-platform validation | GitHub Actions matrix: macOS-arm64, macos-latest, windows-latest, ubuntu-latest |

### Oracle 23ai Docker Setup

```yaml
# docker-compose.yml
version: '3.8'
services:
  oracle:
    image: container-registry.oracle.com/database/free:latest
    ports:
      - "1521:1521"
    environment:
      - ORACLE_PWD=testpassword
    volumes:
      - oracle-data:/opt/oracle/oradata
    healthcheck:
      test: ["CMD", "sqlplus", "-L", "sys/testpassword@//localhost:1521/FREEPDB1 as sysdba", "@/dev/null"]
      interval: 30s
      timeout: 10s
      retries: 5

volumes:
  oracle-data:
```

### CI Pipeline Structure

```yaml
# .github/workflows/ci.yml
jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: dart-lang/setup-dart@v1
      - run: dart test --tags=unit

  integration-tests:
    runs-on: ubuntu-latest
    services:
      oracle:
        image: container-registry.oracle.com/database/free:latest
    steps:
      - uses: dart-lang/setup-dart@v1
      - run: dart test --tags=integration

  platform-matrix:
    strategy:
      matrix:
        os: [macos-arm64, macos-latest, windows-latest, ubuntu-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: dart-lang/setup-dart@v1
      - run: dart test --tags=unit
```

---

## Testability Concerns

### Issues Identified

| Concern | Severity | Impact | Recommendation |
|---------|----------|--------|----------------|
| No protocol tracing | MEDIUM | Debugging wire issues is difficult | Add `Logger('TNS')` and `Logger('TTC')` with verbose mode |
| Pool state isolation | MEDIUM | Parallel tests may conflict | Add `pool.drain()` method for test cleanup |
| Crypto debugging | HIGH | Auth failures hard to diagnose | Add verbose auth flow logging (without credentials) |
| Integration test startup | LOW | Oracle container slow to start | Use GitHub Actions service container caching |

### Recommendations for Sprint 0

1. **Test Framework Setup** (`*framework` workflow):
   - Configure `dart test` with tags: `unit`, `integration`, `e2e`
   - Set up test fixtures for common Oracle states
   - Create test helper utilities for connection/pool management

2. **CI Pipeline Setup** (`*ci` workflow):
   - GitHub Actions with platform matrix
   - Oracle 23ai service container
   - Security audit job for credential scanning
   - Performance regression detection

3. **Protocol Debugging**:
   - Add `Logger('TNS')` for transport-level packet logging
   - Add `Logger('TTC')` for protocol-level message logging
   - Enable via environment variable for debugging

---

## Quality Gate Criteria

### Solutioning Gate (Current Phase)

| Criterion | Threshold | Status |
|-----------|-----------|--------|
| Architecture supports testability | Controllability/Observability/Reliability assessed | PASS |
| Critical ASRs identified | All score ≥6 risks documented | PASS |
| Test levels strategy defined | Unit/Integration/E2E allocation | PASS |
| NFR testing approach defined | Security/Performance/Reliability/Compatibility | PASS |
| No blocking testability concerns | Architecture enables testing | PASS |

### Implementation Gate (Phase 4)

| Criterion | Threshold | Notes |
|-----------|-----------|-------|
| Unit test coverage | ≥80% for buffer/types/errors | Critical logic coverage |
| Integration test coverage | All FR requirements tested | Protocol/Oracle validation |
| Security tests pass | 100% | Auth, TLS, credential handling |
| Platform tests pass | All matrix platforms green | macOS, Windows, Linux |
| Performance baselines met | No regressions from baseline | Statement cache, pool timing |

---

## Next Steps

1. **Immediate (Sprint 0):**
   - Run `*framework` workflow to initialize test infrastructure
   - Run `*ci` workflow to scaffold CI/CD pipeline
   - Create test fixtures for Oracle connection/pool

2. **Before Epic 1:**
   - Set up Docker Compose for local Oracle 23ai
   - Create test data seeding utilities
   - Configure CI with Oracle service container

3. **During Implementation:**
   - Use `*atdd` workflow to generate failing tests before implementation
   - Use `*automate` workflow to expand test coverage after implementation
   - Run `*trace` workflow at epic completion for quality gate

---

**Architecture Status:** READY FOR IMPLEMENTATION

**Testability Verdict:** PASS - Architecture supports comprehensive testing

---

**Generated by**: BMad TEA Agent - Test Architect Module
**Workflow**: `.bmad/bmm/testarch/test-design` (System-Level Mode)
**Version**: 4.0 (BMad v6)
