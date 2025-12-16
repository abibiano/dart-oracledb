# dart-oracledb Test Architecture

**Version:** 1.0
**Date:** 2025-12-16
**Author:** Alex (with Epic 1 Retrospective insights)
**Status:** Active

---

## Executive Summary

This document establishes comprehensive test architecture standards for dart-oracledb, a pure Dart Oracle database driver implementing TNS/TTC wire protocol. These standards ensure systematic, high-quality test coverage across all future epics.

### Key Principles

1. **Integration-First Strategy:** Protocol-level code REQUIRES integration tests against Oracle 23ai
2. **Test-Driven Development:** Write failing tests BEFORE implementation (red-green-refactor)
3. **Security Vigilance:** Credentials NEVER appear in logs, errors, or test output (NFR5)
4. **Error Path Completeness:** Error scenarios tested BEFORE marking stories "done"
5. **Reference Validation:** Compare with node-oracledb reference implementation for protocol layers

### Testing Philosophy for Database Drivers

Unlike typical applications, database drivers have an **inverted test pyramid** where integration tests are MORE critical than unit tests:

- **Unit tests** validate byte encoding, type conversions, and pure functions
- **Integration tests** validate protocol correctness against real Oracle 23ai behavior
- **No E2E tests** - the driver itself IS the integration layer

### Critical Context: Why This Matters

**Epic 1 Discovery (2025-12-16):**
Story 1.4 marked "done" without integration tests - **authentication was completely broken**. Took 8 debugging sessions to discover Oracle 23ai protocol requirements (FAST_AUTH, hex crypto encoding). **Integration tests are not optional for protocol-level code.**

**Epic 2 Impact:**
Stories 2.1-2.4 marked "dev-complete-pending-validation" have same issue. Epic roadmap adjusted: Epic 1 → **Epic 6** → Epic 2 rework → Epic 2 continuation.

---

## 1. Test Organization

### Directory Structure

```
test/
├── src/                          # Unit tests (mirror lib/src/)
│   ├── protocol/
│   │   ├── messages/
│   │   │   ├── auth_message_test.dart
│   │   │   ├── execute_message_test.dart
│   │   │   ├── fast_auth_message_test.dart
│   │   │   └── ...
│   │   ├── buffer_test.dart
│   │   ├── data_types_test.dart
│   │   └── ...
│   ├── transport/
│   │   ├── packet_test.dart
│   │   └── ...
│   ├── crypto/
│   │   ├── auth_test.dart
│   │   └── ...
│   ├── connection/
│   │   ├── connection_string_test.dart
│   │   └── ...
│   └── ...
├── integration/                  # Integration tests (@Tags(['integration']))
│   ├── auth_integration_test.dart
│   ├── query_integration_test.dart
│   ├── connection_integration_test.dart
│   ├── transaction_integration_test.dart
│   ├── plsql_integration_test.dart
│   ├── data_types_integration_test.dart
│   └── ...
└── ...
```

### Naming Conventions

| Type | Pattern | Example |
|------|---------|---------|
| Unit test | `{filename}_test.dart` | `buffer_test.dart` |
| Integration test | `{feature}_integration_test.dart` | `auth_integration_test.dart` |
| Test group | `group('{feature}', ...)` | `group('AUTH_SESSKEY', ...)` |
| Test description | Clear, descriptive sentence | `test('hex-encodes AUTH_SESSKEY to uppercase', ...)` |

### @Tags Usage

```dart
@Tags(['integration'])  // Integration tests (require Oracle 23ai)
@Tags(['slow'])         // Tests taking >5 seconds
@Tags(['security'])     // NFR5 credential protection tests
@Tags(['performance'])  // Performance benchmarks (NFR1-4)
@Tags(['protocol'])     // Protocol-specific validation
```

**Configuring Tags in dart_test.yaml:**

To eliminate tag warnings, register all custom tags in `dart_test.yaml`:

```yaml
# dart_test.yaml
tags:
  integration:
    description: Integration tests requiring Oracle 23ai
  security:
    description: NFR5 credential protection tests
  slow:
    description: Tests taking >5 seconds
  performance:
    description: Performance benchmarks (NFR1-4)
  protocol:
    description: Protocol-specific validation tests
```

**Running Tests by Tag:**

```bash
# Unit tests only (fast)
dart test --exclude-tags=integration

# Integration tests only
RUN_INTEGRATION_TESTS=true dart test --tags=integration

# Security tests
dart test --tags=security

# All tests
RUN_INTEGRATION_TESTS=true dart test
```

---

## 2. Test Levels

### Test Pyramid for dart-oracledb (INVERTED)

```
              ▲ E2E Tests (0%) - None (driver IS the integration layer)
             / \
            /   \
           /_____\
          /       \
         /         \
        /___________\ Integration Tests (55%) - CRITICAL for protocol validation
       /             \
      /               \
     /                 \
    /___________________\ Unit Tests (40%) - Protocol encoding focused
```

### Level Allocation

| Level | Allocation | What to Test | Why This Level |
|-------|------------|--------------|----------------|
| **Unit** | 40% | Buffer encoding/decoding, type converters, error construction, connection string parsing, crypto primitives | Pure functions, fast feedback, isolated logic |
| **Integration** | 55% | Protocol messages, authentication flow, query execution, connection lifecycle, pool operations, transaction management | Real Oracle behavior, protocol compatibility, CRITICAL for protocol validation |
| **E2E** | 5% | Full connect → query → results → close workflow | Critical path validation (minimal - integration tests cover this) |

### Test Level Decision Matrix

| Scenario | Test Level | Justification |
|----------|------------|---------------|
| `readUint16BE()` buffer method | Unit | Pure function, no dependencies |
| EZ Connect string parsing | Unit | Isolated parsing logic |
| Oracle type to Dart type mapping | Unit | Deterministic conversion |
| OracleException construction | Unit | Error object creation |
| PBKDF2 key derivation | Unit | Crypto primitive validation |
| AUTH_PHASE_ONE message encoding | **Integration** | Must match Oracle protocol exactly |
| AUTH_PHASE_TWO authentication | **Integration** | Real Oracle validation needed |
| FAST_AUTH protocol flow | **Integration** | Oracle 23ai-specific protocol |
| Query execution with bind params | **Integration** | Oracle SQL parsing involved |
| Transaction commit/rollback | **Integration** | Oracle transaction state |
| Connection pool acquire/release | **Integration** | Real connection lifecycle |
| LOB data handling | **Integration** | Oracle LOB protocol |
| Full CRUD workflow | E2E (optional) | Critical user journey (integration tests cover most) |

---

## 3. Coverage Requirements

### Coverage Targets by Layer

| Layer | Target | Rationale |
|-------|--------|-----------|
| **Protocol** | ≥90% | Critical - byte-level correctness required |
| **Transport** | ≥90% | Critical - network protocol foundation |
| **Crypto** | ≥90% | Critical - security implications (NFR7) |
| **Connection API** | ≥85% | Important - user-facing interface |
| **Pool** | ≥85% | Important - resource management |
| **Data Types** | ≥85% | Important - data integrity |
| **Overall Project** | ≥85% | Comprehensive validation |

### Story Completion Criteria

#### "dev-complete-pending-validation" Status

**Requirements:**
- ✅ Code implementation complete
- ✅ Unit tests written and passing
- ✅ Code review completed
- ❌ Integration tests NOT required yet

**Use Case:** Early Epic 2 stories where integration test infrastructure wasn't ready.

**Current Status:** Stories 2.1-2.4 in this state - require Epic 6 Story 6.3 validation.

#### "done" Status (MANDATORY Requirements)

**Requirements:**
- ✅ All tasks/subtasks marked complete with [x]
- ✅ Implementation satisfies EVERY Acceptance Criterion
- ✅ Unit tests for core functionality added/updated
- ✅ **Integration tests for protocol/connection code PASSING against Oracle 23ai**
- ✅ Error path tests complete
- ✅ Security validation (NFR5) if auth/connection code
- ✅ All tests pass (no regressions)
- ✅ Code quality checks pass (linting, static analysis)
- ✅ File List complete
- ✅ Dev Agent Record updated
- ✅ Change Log updated

**Critical Rule from Epic 1 Retrospective:**
> "All stories require integration tests passing before marking 'done'" - Team Agreement #1

### Epic-Specific Coverage Targets

| Epic | Target | Special Requirements |
|------|--------|---------------------|
| Epic 1 | ≥90% | Authentication protocol validation (Story 6.2 rework) |
| Epic 2 | ≥85% | Query execution, result sets, transactions |
| Epic 3 | ≥85% | PL/SQL execution, OUT parameters |
| Epic 4 | ≥85% | LOB handling, RAW, JSON |
| Epic 5 | ≥90% | Pool state management, concurrency |

---

## 4. Protocol-Specific Testing Patterns

### Epic 1 Discoveries (Oracle 23ai Requirements)

**Critical Protocol Behaviors Discovered:**

1. **FAST_AUTH Protocol (MANDATORY)**
   - Oracle 23ai requires combined protocol envelope
   - Single packet containing: Protocol + DataTypes + AUTH messages
   - NOT documented in Oracle manuals (found via node-oracledb)

2. **Hex-Encoded Crypto Values (UPPERCASE)**
   - AUTH_SESSKEY: Hex-encoded string
   - PBKDF2 derived key: Hex-encoded string
   - Password salt prefix: 16 random bytes → hex-encoded
   - All hex values UPPERCASE

3. **Wrong Password Timeout (5 seconds)**
   - Oracle 23ai deliberate behavior (not a bug)
   - Security feature to prevent brute force
   - Tests must account for this delay

4. **MARKER Packet Handling**
   - Sequence counter progression validation
   - Proper MARKER packet recognition

5. **Sequence Counter Validation**
   - Protocol sequence must increment correctly
   - Reset on connection close

### Protocol Test Patterns

#### FAST_AUTH Protocol Tests

```dart
@Tags(['integration', 'protocol'])
group('FAST_AUTH protocol', () {
  test('sends combined AUTH envelope (Protocol + DataTypes + AUTH)', () async {
    // Validate message structure matches Oracle 23ai requirements
    final authMessage = FastAuthMessage(/* ... */);

    // Verify envelope contains all three parts
    expect(authMessage.hasProtocolNegotiation, isTrue);
    expect(authMessage.hasDataTypes, isTrue);
    expect(authMessage.hasAuthData, isTrue);
  });

  test('embeds AUTH message in Protocol message', () async {
    // Verify AUTH data is embedded correctly
    final authMessage = FastAuthMessage(/* ... */);

    expect(authMessage.isEmbedded, isTrue);
    expect(authMessage.embeddingLayer, equals('Protocol'));
  });

  test('authenticates successfully against Oracle 23ai', () async {
    // Full integration test
    final conn = await OracleConnection.connect(
      'localhost:1521/FREEPDB1',
      user: 'testuser',
      password: 'testpass',
    );

    expect(conn.isConnected, isTrue);
    await conn.close();
  });
});
```

#### Hex-Encoded Crypto Value Tests

```dart
@Tags(['unit', 'protocol'])
group('hex crypto encoding', () {
  test('AUTH_SESSKEY is uppercase hex-encoded string', () {
    final sessionKey = generateSessionKey();
    final encoded = encodeAuthSessionKey(sessionKey);

    // Verify hex encoding
    expect(encoded, matches(r'^[0-9A-F]+$'));
    expect(encoded.length, equals(sessionKey.length * 2));
  });

  test('PBKDF2 derived key is uppercase hex-encoded', () {
    final key = derivePBKDF2Key('password', salt);
    final encoded = encodePBKDF2Key(key);

    expect(encoded, matches(r'^[0-9A-F]+$'));
  });

  test('password includes hex-encoded 16-byte salt prefix', () {
    final password = 'testpass';
    final encodedPassword = encodePasswordWithSalt(password);

    // Verify 16-byte salt (32 hex chars) + password
    expect(encodedPassword, matches(r'^[0-9A-F]{32}[0-9A-F]+$'));
  });
});
```

#### Timeout Testing

```dart
@Tags(['integration', 'security'])
group('authentication timeouts', () {
  test('wrong password fails after 5 second timeout', () async {
    final stopwatch = Stopwatch()..start();

    await expectLater(
      () => OracleConnection.connect(
        'localhost:1521/FREEPDB1',
        user: 'testuser',
        password: 'WRONG_PASSWORD',
      ),
      throwsA(isA<OracleException>()),
    );

    stopwatch.stop();

    // Verify ~5 second timeout (4-6 second range)
    expect(stopwatch.elapsed.inSeconds, inInclusiveRange(4, 6));
  });
});
```

#### MARKER Packet Handling

```dart
@Tags(['unit', 'protocol'])
group('MARKER packet handling', () {
  test('recognizes MARKER packet type', () {
    final packet = Packet.fromBytes(markerPacketBytes);
    expect(packet.type, equals(PacketType.MARKER));
  });

  test('increments sequence counter on MARKER', () {
    // Validate sequence progression
    expect(sequenceCounter, equals(expectedSequence));
  });
});
```

#### Oracle 23ai-Specific Behaviors

```dart
@Tags(['integration'])
group('Oracle 23ai specific behaviors', () {
  test('supports SHA512/PBKDF2 authentication (NFR7)', () async {
    // Verify modern authentication works
    final conn = await OracleConnection.connect(
      'localhost:1521/FREEPDB1',
      user: 'testuser',
      password: 'testpass',
    );

    expect(conn.isConnected, isTrue);
    await conn.close();
  });

  test('accepts only FAST_AUTH protocol', () async {
    // Verify FAST_AUTH is required (not optional)
    // Attempting old-style auth should fail
  });
});
```

---

## 5. Edge Case Testing Requirements

### Security Edge Cases (NFR5 - CRITICAL)

**Team Agreement #3:** "Code reviews must check NFR5 (no credentials in logs/errors)"

**Epic 1 Violations (3 incidents):**
- Story 1.4: Password in logs
- Story 1.5: Credentials in error messages
- Story 1.8: Username exposure (also sensitive)

#### Security Test Checklist

```dart
@Tags(['security'])
group('NFR5: Credentials never logged', () {
  test('password not in logs during successful connection', () async {
    final logs = captureLogOutput(() async {
      await OracleConnection.connect(
        'localhost:1521/FREEPDB1',
        user: 'testuser',
        password: 'secretPassword123',
      );
    });

    expect(logs, isNot(contains('secretPassword123')));
    expect(logs, isNot(contains('password=')));
    expect(logs, isNot(contains('pwd=')));
  });

  test('password not in logs during auth failure', () async {
    final logs = captureLogOutput(() async {
      await expectLater(
        () => OracleConnection.connect(
          'localhost:1521/FREEPDB1',
          user: 'testuser',
          password: 'WRONG_PASSWORD',
        ),
        throwsA(isA<OracleException>()),
      );
    });

    expect(logs, isNot(contains('WRONG_PASSWORD')));
  });

  test('password not in exception messages', () async {
    try {
      await OracleConnection.connect(
        'localhost:1521/FREEPDB1',
        user: 'testuser',
        password: 'secretPassword123',
      );
      fail('Expected exception');
    } catch (e) {
      expect(e.toString(), isNot(contains('secretPassword123')));
    }
  });

  test('username not in logs (also sensitive)', () async {
    final logs = captureLogOutput(() async {
      await OracleConnection.connect(
        'localhost:1521/FREEPDB1',
        user: 'sensitiveUsername',
        password: 'testpass',
      );
    });

    // Username also sensitive per Story 1.8 discovery
    expect(logs, isNot(contains('sensitiveUsername')));
    expect(logs, isNot(contains('user=')));
  });

  test('connection string not in logs', () async {
    final logs = captureLogOutput(() async {
      await OracleConnection.connect(
        'user/password@localhost:1521/FREEPDB1',
      );
    });

    expect(logs, isNot(contains('user/password@')));
  });
});
```

### Error Path Testing Checklist

**Epic 1 Pattern:** "Error path testing came up in almost every code review - we consistently wrote the happy path first" - Stories 1.2, 1.3, 1.5, 1.7

**Mandatory Error Scenarios:**

#### Connection Failures

```dart
@Tags(['integration'])
group('connection error paths', () {
  test('invalid hostname', () async {
    await expectLater(
      () => OracleConnection.connect('invalid-host:1521/FREEPDB1'),
      throwsA(isA<OracleException>().having(
        (e) => e.message,
        'message',
        contains('connection failed'),
      )),
    );
  });

  test('invalid port', () async {
    await expectLater(
      () => OracleConnection.connect('localhost:9999/FREEPDB1'),
      throwsA(isA<OracleException>()),
    );
  });

  test('invalid service name', () async {
    await expectLater(
      () => OracleConnection.connect('localhost:1521/INVALID'),
      throwsA(isA<OracleException>()),
    );
  });

  test('network timeout', () async {
    // Simulate network delay
  });

  test('connection refused', () async {
    // Oracle not running
  });
});
```

#### Authentication Failures

```dart
@Tags(['integration'])
group('authentication error paths', () {
  test('invalid username', () async {
    await expectLater(
      () => OracleConnection.connect(
        'localhost:1521/FREEPDB1',
        user: 'NONEXISTENT',
        password: 'testpass',
      ),
      throwsA(isA<OracleException>()),
    );
  });

  test('invalid password', () async {
    // Already tested in timeout tests (5 second delay)
  });

  test('account locked', () async {
    // Test locked account scenario
  });

  test('password expired', () async {
    // Test expired password scenario
  });
});
```

#### Protocol Errors

```dart
@Tags(['unit', 'protocol'])
group('protocol error paths', () {
  test('malformed packet', () {
    final invalidBytes = [0xFF, 0xFF, 0xFF]; // Invalid packet
    expect(() => Packet.fromBytes(invalidBytes), throwsA(isA<OracleException>()));
  });

  test('unexpected sequence number', () {
    // Test sequence counter mismatch
  });

  test('invalid message type', () {
    // Test unknown message type handling
  });

  test('buffer overflow protection', () {
    // Test buffer size limits
  });
});
```

### Resource Cleanup Edge Cases

**Epic 1 Pattern:** "Socket listeners, TLS upgrades, connection cleanup - try-finally blocks initially missed" - Stories 1.2, 1.6, 1.7

```dart
@Tags(['integration'])
group('resource cleanup', () {
  test('connection closed on error', () async {
    OracleConnection? conn;
    try {
      conn = await OracleConnection.connect(/* ... */);
      // Simulate error
      throw Exception('Simulated error');
    } catch (e) {
      // Verify connection cleaned up
      expect(conn?.isClosed, isTrue);
    }
  });

  test('socket closed on timeout', () async {
    // Test timeout cleanup
  });

  test('no socket leaks after close', () async {
    final conn = await OracleConnection.connect(/* ... */);
    await conn.close();

    // Verify socket closed
    expect(conn.isClosed, isTrue);
    // Verify no resource leaks
  });

  test('pool drains all connections on close', () async {
    final pool = await OraclePool.create(/* ... */);

    // Acquire some connections
    final conn1 = await pool.acquire();
    final conn2 = await pool.acquire();

    await pool.close();

    // Verify all connections closed
    expect(conn1.isClosed, isTrue);
    expect(conn2.isClosed, isTrue);
  });
});
```

### Concurrent Connection Testing

```dart
@Tags(['integration'])
group('pool behavior under load', () {
  test('handles concurrent acquire requests', () async {
    final pool = await OraclePool.create(
      'localhost:1521/FREEPDB1',
      user: 'test',
      password: 'test',
      minConnections: 2,
      maxConnections: 5,
    );

    // Concurrent requests
    final futures = List.generate(10, (_) => pool.acquire());
    final connections = await Future.wait(futures);

    expect(connections.length, equals(10));

    // Release all
    await Future.wait(connections.map((c) => pool.release(c)));
    await pool.close();
  });

  test('pool recovers from connection failure', () async {
    // Test pool recovery (NFR9)
    final pool = await OraclePool.create(/* ... */);

    final conn = await pool.acquire();
    await simulateConnectionDrop(conn);
    await pool.release(conn);

    // Next acquire should get healthy connection
    final newConn = await pool.acquire();
    expect(newConn.isHealthy, isTrue);
  });
});
```

### Protocol Violation Edge Cases

```dart
@Tags(['unit', 'protocol'])
group('protocol violations', () {
  test('handles unexpected response type', () {
    // Test unexpected message type handling
  });

  test('handles truncated packet', () {
    // Test partial packet handling
  });

  test('handles oversized packet', () {
    // Test packet size limit enforcement
  });

  test('handles protocol version mismatch', () {
    // Test version negotiation failure
  });
});
```

---

## 6. Integration Test Best Practices

### Oracle 23ai Docker Setup

#### docker-compose.yml

```yaml
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

#### Starting Oracle 23ai

```bash
# Start Oracle 23ai container
docker-compose up -d

# Wait for healthcheck
docker-compose ps

# Verify connectivity
docker exec -it dart-oracledb-oracle-1 sqlplus sys/testpassword@FREEPDB1 as sysdba
```

### Connection Parameters (Environment Variables)

```bash
# .env.test (NOT committed to git)
ORACLE_HOST=localhost
ORACLE_PORT=1521
ORACLE_SERVICE=FREEPDB1
ORACLE_USER=testuser
ORACLE_PASSWORD=testpassword
```

#### Using Environment Variables in Tests

```dart
@Tags(['integration'])
void main() {
  // Check if integration tests should run
  final runIntegrationTests = Platform.environment['RUN_INTEGRATION_TESTS'] == 'true';

  if (!runIntegrationTests) {
    test('integration tests skipped', () {
      print('Set RUN_INTEGRATION_TESTS=true to run integration tests');
    });
    return;
  }

  // Load connection params
  final host = Platform.environment['ORACLE_HOST'] ?? 'localhost';
  final port = Platform.environment['ORACLE_PORT'] ?? '1521';
  final service = Platform.environment['ORACLE_SERVICE'] ?? 'FREEPDB1';
  final user = Platform.environment['ORACLE_USER'] ?? 'testuser';
  final password = Platform.environment['ORACLE_PASSWORD'] ?? 'testpassword';

  final connectionString = '$host:$port/$service';

  group('Integration Tests', () {
    // Tests here
  });
}
```

### Test Data Isolation Strategies

#### Unique Table Names Per Test

```dart
@Tags(['integration'])
group('query integration tests', () {
  late OracleConnection conn;
  late String tableName;

  setUp(() async {
    conn = await OracleConnection.connect(/* ... */);

    // Unique table name per test
    tableName = 'TEST_${DateTime.now().millisecondsSinceEpoch}';

    await conn.execute('''
      CREATE TABLE $tableName (
        id NUMBER PRIMARY KEY,
        name VARCHAR2(100)
      )
    ''');
  });

  tearDown(() async {
    await conn.execute('DROP TABLE $tableName');
    await conn.close();
  });

  test('inserts data', () async {
    await conn.execute('INSERT INTO $tableName VALUES (1, \'test\')');
    // Verify
  });
});
```

#### Test Schema Pattern

```dart
// Use dedicated test schema
final testSchema = 'DART_ORACLEDB_TEST';

setUp(() async {
  // Create test schema if not exists
  await conn.execute('CREATE USER $testSchema IDENTIFIED BY testpass');
  await conn.execute('GRANT CONNECT, RESOURCE TO $testSchema');

  // Switch to test schema
  await conn.execute('ALTER SESSION SET CURRENT_SCHEMA = $testSchema');
});

tearDown(() async {
  // Clean up test schema
  await conn.execute('DROP USER $testSchema CASCADE');
});
```

### setUp/tearDown Patterns

#### Connection Management

```dart
@Tags(['integration'])
group('connection tests', () {
  late OracleConnection conn;

  setUp(() async {
    conn = await OracleConnection.connect(
      'localhost:1521/FREEPDB1',
      user: 'testuser',
      password: 'testpassword',
    );
  });

  tearDown(() async {
    await conn.close();
  });

  test('executes query', () async {
    final result = await conn.execute('SELECT * FROM dual');
    expect(result.rows.length, equals(1));
  });
});
```

#### Pool Management

```dart
@Tags(['integration'])
group('pool tests', () {
  late OraclePool pool;

  setUp(() async {
    pool = await OraclePool.create(
      'localhost:1521/FREEPDB1',
      user: 'testuser',
      password: 'testpassword',
      minConnections: 2,
      maxConnections: 5,
    );
  });

  tearDown(() async {
    await pool.close();
  });

  test('acquires connection', () async {
    final conn = await pool.acquire();
    expect(conn.isConnected, isTrue);
    await pool.release(conn);
  });
});
```

### Integration Test Organization

```
test/integration/
├── auth_integration_test.dart         # Authentication tests
├── query_integration_test.dart        # SELECT queries
├── dml_integration_test.dart          # INSERT/UPDATE/DELETE
├── transaction_integration_test.dart  # Commit/rollback
├── plsql_integration_test.dart        # Stored procedures/functions
├── data_types_integration_test.dart   # Type mapping validation
├── lob_integration_test.dart          # CLOB/BLOB handling
├── pool_integration_test.dart         # Connection pooling
└── ...
```

---

## 7. Test Design Workflow

### Test-First for Protocol Code (RED-GREEN-REFACTOR)

**Team Agreement #1:** "All stories require integration tests passing before marking 'done'"

#### RED Phase: Write Failing Tests First

```dart
// BEFORE implementation
@Tags(['unit', 'protocol'])
test('encodes AUTH_SESSKEY as uppercase hex', () {
  final sessionKey = Uint8List.fromList([0x01, 0x02, 0x03]);
  final encoded = encodeAuthSessionKey(sessionKey);

  expect(encoded, equals('010203')); // FAILS - function doesn't exist yet
});
```

#### GREEN Phase: Minimal Implementation

```dart
// Implement JUST enough to pass
String encodeAuthSessionKey(Uint8List key) {
  return key.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
}
```

#### REFACTOR Phase: Improve Code Quality

```dart
// Improve while keeping tests green
String encodeAuthSessionKey(Uint8List key) {
  return _hexEncode(key);
}

String _hexEncode(Uint8List bytes) {
  return bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}
```

### Error Path Tests Before Marking Done

**Checklist before marking story "done":**

- [ ] Happy path tested
- [ ] Error paths tested (connection failures, auth failures, protocol errors)
- [ ] Resource cleanup tested (try-finally blocks validated)
- [ ] Security validation (NFR5) if auth/connection code
- [ ] Integration tests passing against Oracle 23ai

### Security Checklist for Auth/Connection Code

**Mandatory for Stories involving authentication or connection handling:**

- [ ] Password NEVER in logs (test with log capture)
- [ ] Username NEVER in logs (also sensitive per Story 1.8)
- [ ] Credentials NEVER in exception messages
- [ ] Connection string NEVER in logs
- [ ] Crypto values properly encoded (hex, uppercase)
- [ ] Security tests tagged with `@Tags(['security'])`

### Code Review Test Coverage Validation

**Code Review Checklist:**

- [ ] Test coverage meets layer targets (≥85-90%)
- [ ] Integration tests exist for protocol code
- [ ] Error paths tested
- [ ] Security tests (NFR5) if applicable
- [ ] Resource cleanup validated
- [ ] Test descriptions clear and descriptive
- [ ] @Tags used appropriately
- [ ] setUp/tearDown patterns correct

---

## 8. CI/CD Integration Strategy

### GitHub Actions Workflow Structure

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main, develop]

jobs:
  unit-tests:
    name: Unit Tests
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - uses: dart-lang/setup-dart@v1
        with:
          sdk: stable

      - name: Install dependencies
        run: dart pub get

      - name: Analyze code
        run: dart analyze

      - name: Run unit tests
        run: dart test --exclude-tags=integration

  integration-tests:
    name: Integration Tests
    runs-on: ubuntu-latest

    services:
      oracle:
        image: container-registry.oracle.com/database/free:latest
        env:
          ORACLE_PWD: testpassword
        ports:
          - 1521:1521
        options: >-
          --health-cmd "sqlplus -L sys/testpassword@//localhost:1521/FREEPDB1 as sysdba @/dev/null"
          --health-interval 30s
          --health-timeout 10s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4

      - uses: dart-lang/setup-dart@v1

      - name: Install dependencies
        run: dart pub get

      - name: Wait for Oracle
        run: |
          timeout 300 bash -c 'until docker exec ${{ job.services.oracle.id }} sqlplus -L sys/testpassword@//localhost:1521/FREEPDB1 as sysdba @/dev/null; do sleep 5; done'

      - name: Run integration tests
        run: RUN_INTEGRATION_TESTS=true dart test --tags=integration
        env:
          ORACLE_HOST: localhost
          ORACLE_PORT: 1521
          ORACLE_SERVICE: FREEPDB1
          ORACLE_USER: sys as sysdba
          ORACLE_PASSWORD: testpassword

  platform-matrix:
    name: Platform Tests (${{ matrix.os }})
    strategy:
      matrix:
        os: [macos-latest, windows-latest, ubuntu-latest]

    runs-on: ${{ matrix.os }}

    steps:
      - uses: actions/checkout@v4

      - uses: dart-lang/setup-dart@v1

      - name: Install dependencies
        run: dart pub get

      - name: Run unit tests
        run: dart test --exclude-tags=integration

  coverage:
    name: Code Coverage
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
          dart pub global run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info --report-on=lib

      - name: Upload to Codecov
        uses: codecov/codecov-action@v3
        with:
          files: coverage/lcov.info
```

### Oracle 23ai Docker Setup in CI

```yaml
# docker-compose.ci.yml (for CI environment)
version: '3.8'
services:
  oracle:
    image: container-registry.oracle.com/database/free:latest
    ports:
      - "1521:1521"
    environment:
      - ORACLE_PWD=testpassword
    healthcheck:
      test: ["CMD", "sqlplus", "-L", "sys/testpassword@//localhost:1521/FREEPDB1 as sysdba", "@/dev/null"]
      interval: 30s
      timeout: 10s
      retries: 10
```

### Test Execution Strategy

**Sequential Execution:**

1. **Static Analysis** (`dart analyze`) - Fast feedback
2. **Unit Tests** (`dart test --exclude-tags=integration`) - Fast feedback
3. **Integration Tests** (`RUN_INTEGRATION_TESTS=true dart test --tags=integration`) - Requires Oracle
4. **Platform Matrix** - Cross-platform validation
5. **Coverage Report** - Quality gate

### Coverage Reporting Requirements

```bash
# Generate coverage report
dart test --coverage=coverage

# Convert to lcov format
dart pub global activate coverage
dart pub global run coverage:format_coverage \
  --lcov \
  --in=coverage \
  --out=coverage/lcov.info \
  --report-on=lib

# Generate HTML report
genhtml coverage/lcov.info -o coverage/html

# Open report
open coverage/html/index.html
```

**Coverage Gates:**

- Overall project: ≥85%
- Protocol layer: ≥90%
- Transport layer: ≥90%
- Crypto layer: ≥90%

### Cross-Platform Test Matrix

```yaml
strategy:
  matrix:
    os: [macos-latest, macos-13, windows-latest, ubuntu-latest]
    dart-sdk: [stable, beta]
```

**Platform-Specific Considerations:**

- **macOS:** Apple Silicon (M1/M2) + Intel support
- **Windows:** Path separators, line endings
- **Linux:** Primary CI platform, Oracle container host

### CI Implementation Notes

**Note:** Actual CI implementation is Story 6.4 (DESCOPED per Alex decision). This section defines requirements only.

---

## 9. Test Design Templates

### Unit Test Template

```dart
// test/src/{module}/{feature}_test.dart
import 'package:test/test.dart';
import 'package:dart_oracledb/src/{module}/{feature}.dart';

void main() {
  group('{Feature}', () {
    // Setup
    setUp(() {
      // Initialize test fixtures
    });

    // Teardown
    tearDown(() {
      // Clean up resources
    });

    // Happy path tests
    group('happy path', () {
      test('{description}', () {
        // Arrange
        final input = /* test data */;

        // Act
        final result = functionUnderTest(input);

        // Assert
        expect(result, equals(expectedValue));
      });
    });

    // Error path tests
    group('error paths', () {
      test('throws exception when {invalid condition}', () {
        expect(
          () => functionUnderTest(invalidInput),
          throwsA(isA<OracleException>()),
        );
      });
    });

    // Edge cases
    group('edge cases', () {
      test('handles empty input', () {
        // Test edge case
      });

      test('handles maximum value', () {
        // Test boundary
      });
    });
  });
}
```

### Integration Test Template

```dart
// test/integration/{feature}_integration_test.dart
import 'dart:io';
import 'package:test/test.dart';
import 'package:dart_oracledb/dart_oracledb.dart';

@Tags(['integration'])
void main() {
  // Check if integration tests should run
  final runIntegrationTests = Platform.environment['RUN_INTEGRATION_TESTS'] == 'true';

  if (!runIntegrationTests) {
    test('integration tests skipped', () {
      print('Set RUN_INTEGRATION_TESTS=true to run integration tests');
    });
    return;
  }

  // Load connection params
  final host = Platform.environment['ORACLE_HOST'] ?? 'localhost';
  final port = Platform.environment['ORACLE_PORT'] ?? '1521';
  final service = Platform.environment['ORACLE_SERVICE'] ?? 'FREEPDB1';
  final user = Platform.environment['ORACLE_USER'] ?? 'testuser';
  final password = Platform.environment['ORACLE_PASSWORD'] ?? 'testpassword';

  final connectionString = '$host:$port/$service';

  group('{Feature} Integration Tests', () {
    late OracleConnection conn;

    setUp(() async {
      conn = await OracleConnection.connect(
        connectionString,
        user: user,
        password: password,
      );
    });

    tearDown(() async {
      await conn.close();
    });

    test('{test description}', () async {
      // Arrange
      final testData = /* prepare test data */;

      // Act
      final result = await conn.execute(/* SQL */);

      // Assert
      expect(result, /* expected outcome */);
    });

    // Error path tests
    group('error paths', () {
      test('handles {error scenario}', () async {
        await expectLater(
          () => conn.execute(/* invalid SQL */),
          throwsA(isA<OracleException>()),
        );
      });
    });
  });
}
```

### Protocol Test Template

```dart
// test/integration/{protocol}_protocol_test.dart
import 'dart:io';
import 'package:test/test.dart';
import 'package:dart_oracledb/src/protocol/{protocol}.dart';

@Tags(['integration', 'protocol'])
void main() {
  final runIntegrationTests = Platform.environment['RUN_INTEGRATION_TESTS'] == 'true';

  if (!runIntegrationTests) {
    test('protocol tests skipped', () {
      print('Set RUN_INTEGRATION_TESTS=true to run protocol tests');
    });
    return;
  }

  group('{Protocol} Protocol Tests', () {
    // FAST_AUTH pattern example
    test('sends combined protocol envelope', () async {
      // Validate FAST_AUTH structure
      final message = /* construct protocol message */;

      expect(message.hasProtocolNegotiation, isTrue);
      expect(message.hasDataTypes, isTrue);
      expect(message.hasAuthData, isTrue);
    });

    test('hex-encodes crypto values to uppercase', () {
      final key = /* generate key */;
      final encoded = encodeKey(key);

      expect(encoded, matches(r'^[0-9A-F]+$'));
    });

    test('validates against Oracle 23ai', () async {
      // Full protocol integration test
      final conn = await OracleConnection.connect(/* ... */);
      expect(conn.isConnected, isTrue);
      await conn.close();
    });
  });
}
```

### Security Test Checklist

```markdown
# Security Test Checklist (NFR5)

**Story:** {Story ID}
**Feature:** {Feature Name}
**Date:** {Date}

## Credential Protection Tests

- [ ] Password NEVER in logs during successful connection
- [ ] Password NEVER in logs during auth failure
- [ ] Password NEVER in exception messages
- [ ] Username NEVER in logs (also sensitive)
- [ ] Connection string NEVER in logs
- [ ] Crypto values properly encoded (hex, uppercase)

## Test Implementation

```dart
@Tags(['security'])
group('NFR5: Credentials never logged - {Feature}', () {
  test('password not in logs during {scenario}', () async {
    final logs = captureLogOutput(() async {
      // Perform operation
    });

    expect(logs, isNot(contains('password')));
    expect(logs, isNot(contains('pwd')));
  });

  // Additional security tests...
});
```

## Validation

- [ ] All security tests passing
- [ ] Code review verified credential protection
- [ ] Manual log review completed (no false positives)

**Reviewer:** {Name}
**Date:** {Date}
**Status:** ✅ PASS / ❌ FAIL
```

---

## 10. Quick Reference Guide for Developers

### Story Completion Checklist

**Before marking story "done":**

- [ ] All tasks/subtasks marked [x]
- [ ] Implementation satisfies ALL acceptance criteria
- [ ] Unit tests written and passing
- [ ] Integration tests written and passing (if protocol/connection code)
- [ ] Error path tests complete
- [ ] Security validation (NFR5) if auth/connection code
- [ ] Resource cleanup validated (try-finally blocks)
- [ ] Code quality checks pass (dart analyze)
- [ ] Coverage targets met (≥85-90% per layer)
- [ ] File List updated with all changed files
- [ ] Dev Agent Record updated
- [ ] Change Log updated

### Running Tests Locally

```bash
# Unit tests only (fast)
dart test --exclude-tags=integration

# Integration tests (requires Oracle 23ai)
docker-compose up -d
RUN_INTEGRATION_TESTS=true dart test --tags=integration

# All tests
RUN_INTEGRATION_TESTS=true dart test

# Coverage analysis
dart test --coverage=coverage --exclude-tags=integration
dart pub global activate coverage
dart pub global run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info --report-on=lib
genhtml coverage/lcov.info -o coverage/html
open coverage/html/index.html

# Specific tags
dart test --tags=security
dart test --tags=protocol
dart test --tags=performance
```

### Common Patterns

#### Unit Test Pattern

```dart
@Tags(['unit'])
test('description', () {
  // Arrange
  final input = /* test data */;

  // Act
  final result = functionUnderTest(input);

  // Assert
  expect(result, equals(expected));
});
```

#### Integration Test Pattern

```dart
@Tags(['integration'])
test('description', () async {
  final conn = await OracleConnection.connect(/* ... */);

  try {
    // Act
    final result = await conn.execute(/* SQL */);

    // Assert
    expect(result, /* expected */);
  } finally {
    await conn.close();
  }
});
```

#### Error Path Pattern

```dart
test('throws exception when {condition}', () async {
  await expectLater(
    () => functionUnderTest(invalidInput),
    throwsA(isA<OracleException>()),
  );
});
```

#### Security Test Pattern

```dart
@Tags(['security'])
test('credentials not in logs', () async {
  final logs = captureLogOutput(() async {
    // Perform operation
  });

  expect(logs, isNot(contains('password')));
});
```

### Team Agreements (Epic 1 Retrospective)

1. ✅ All stories require integration tests passing before marking "done"
2. ✅ Error path coverage is mandatory, not optional
3. ✅ Code reviews must check NFR5 (no credentials in logs/errors)
4. ✅ Reference implementation (node-oracledb) must be consulted for foundation modules
5. ✅ Lessons learned from code reviews become ACs for subsequent stories
6. ✅ 90% test coverage target for all epics

---

## 11. References

### Project Documents

- [Architecture](../architecture.md) - Testing strategy and organization
- [Test Design System](../test-design-system.md) - System-level testability assessment
- [Epic 1 Retrospective](../sprint-artifacts/epic-1-retro-2025-12-16.md) - Critical test architecture learnings
- [PRD](../prd.md) - Product requirements

### BMAD Test Architecture

- [BMAD Test Architecture](../.bmad/bmm/docs/test-architecture.md) - TEA workflow lifecycle
- [Test Levels Framework](../.bmad/bmm/testarch/knowledge/test-levels-framework.md)
- [Test Quality](../.bmad/bmm/testarch/knowledge/test-quality.md)
- [Test Priorities Matrix](../.bmad/bmm/testarch/knowledge/test-priorities-matrix.md)

### Existing Test Examples

- `test/integration/auth_integration_test.dart` - Integration test pattern
- `test/src/protocol/data_types_test.dart` - Unit test pattern
- `test/src/crypto/auth_test.dart` - Crypto unit tests

### External References

- [Dart Testing Guide](https://dart.dev/guides/testing)
- [package:test Documentation](https://pub.dev/packages/test)
- [Coverage Tools](https://pub.dev/packages/coverage)
- [Oracle 23ai Documentation](https://docs.oracle.com/en/database/oracle/oracle-database/23/)

---

## Appendix A: Epic 1 Key Learnings Summary

### Story 1.4-FIX: The 8-Session Debugging Journey

**Root Cause:** Story 1.4 marked "done" without integration tests - authentication completely broken.

**Discoveries:**

1. **FAST_AUTH Protocol** (Session 2)
   - Oracle 23ai requires combined protocol envelope
   - Single packet: Protocol + DataTypes + AUTH
   - NOT documented in Oracle manuals

2. **Single Packet, Three Messages** (Session 6)
   - Explained receiveData() timeout
   - Protocol understanding breakthrough

3. **Crypto Hex Encoding** (Session 8)
   - All crypto values hex-encoded UPPERCASE strings
   - Password needs 16-byte random salt prefix
   - Five bugs fixed → authentication working!

**Impact:** Adjusted roadmap to Epic 1 → **Epic 6** → Epic 2 rework → Epic 2 continuation

### Recurring Code Review Themes

1. **Error Path Testing** - Initially focused on happy paths (Stories 1.2, 1.3, 1.5, 1.7)
2. **Resource Cleanup** - Try-finally blocks initially forgotten (Stories 1.2, 1.6, 1.7)
3. **Security Compliance (NFR5)** - 3 credential exposure incidents (Stories 1.4, 1.5, 1.8)
4. **Documentation Completeness** - File Lists initially incomplete
5. **Reference Implementation** - node-oracledb not consulted systematically

### Breakthrough Patterns

- **Completer over Broadcast Streams** (Story 1.2) - Solved race conditions
- **FAST_AUTH Discovery** (Story 1.4-FIX) - Unlocked authentication
- **Integration Test Value** - Caught protocol issues unit tests never would
- **Adversarial Code Review** - 40+ issues caught before merge

---

## Appendix B: Coverage Baseline (Epic 1)

### Current Test Coverage

- **Unit Tests:** 268+
- **Integration Tests:** 30+
- **Overall Coverage:** ~75% (estimated)

### Layer Coverage (Current State)

| Layer | Coverage | Target | Gap |
|-------|----------|--------|-----|
| Protocol | ~70% | ≥90% | Story 6.2 |
| Transport | ~75% | ≥90% | Story 6.2 |
| Crypto | ~80% | ≥90% | Story 6.2 |
| Connection API | ~70% | ≥85% | Story 6.2 |

**Epic 6 Story 6.2 Target:** ≥90% coverage for Epic 1 authentication code

---

## Document Metadata

**Created:** 2025-12-16
**Last Updated:** 2025-12-16
**Version:** 1.0
**Status:** Active
**Next Review:** After Epic 6 completion

**Approval:**
- ✅ Alex (Project Lead)
- Pending: Alice (Product Owner)
- Pending: Charlie (Senior Dev)
- Pending: Dana (QA Engineer)

---

**End of Test Architecture Document**
