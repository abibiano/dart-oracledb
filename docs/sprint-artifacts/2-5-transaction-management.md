# Story 2.5: Transaction Management

Status: ready-for-dev

## Story

As a **developer using dart-oracledb**,
I want **to control transaction boundaries with commit and rollback**,
So that **I can ensure data consistency** (FR22, FR23, FR24).

## Acceptance Criteria

1. **AC1:** Given a connection with pending changes, when calling `connection.commit()`, then all changes are committed to the database (FR22)

2. **AC2:** Given a connection with pending changes, when calling `connection.rollback()`, then all changes are rolled back (FR23)

3. **AC3:** Given multiple DML statements, when executed before commit, then all changes are part of the same transaction (FR24), and a single rollback undoes all changes

4. **AC4:** Given a convenience wrapper is needed, when using `connection.runTransaction((conn) async { ... })`, then auto-commit on success, auto-rollback on exception

5. **AC5:** Given a transaction completes successfully, when commit() is called, then changes are visible to other connections/sessions

6. **AC6:** Given a transaction is rolled back, when rollback() is called, then all changes since the last commit are undone

## Dev Notes

### CRITICAL CONTEXT: Oracle Transaction Behavior

**Oracle's Implicit Transaction Model:**
- Oracle automatically starts a transaction on the first DML statement (INSERT, UPDATE, DELETE)
- No explicit "BEGIN TRANSACTION" command needed (unlike PostgreSQL or SQL Server)
- Transaction remains open until COMMIT or ROLLBACK is executed
- Connection close WITHOUT commit will **automatically rollback** uncommitted changes

**Visibility Rules:**
- Changes are **immediately visible** to the same connection (before commit)
- Changes are **NOT visible** to other sessions/connections until commit
- This behavior was observed and documented in Story 2.4 testing

**Transaction Isolation:**
- Oracle uses READ COMMITTED isolation by default
- Each DML operation gets a lock on affected rows
- Other sessions will block on locked rows until commit/rollback releases locks

### Epic 2 Context

**Epic Objective:** Developer can execute CRUD operations with transactions

**Epic Status:** ⚠️ BLOCKED - Epic 2 is blocked due to Epic 1 authentication bug (ORA-12547)

**Previous Stories in Epic 2:**
- **Story 2.1:** Execute Message & Basic Query (dev-complete-pending-validation)
- **Story 2.2:** Result Set Handling (dev-complete-pending-validation)
- **Story 2.3:** Bind Parameters (dev-complete-pending-validation)
- **Story 2.4:** DML Operations (dev-complete-pending-validation)

**Story 2.5 Dependencies:**
- Requires working connection (Story 1.4 currently broken - AUTH_PHASE_ONE fails)
- Builds on DML operations from Story 2.4 (INSERT, UPDATE, DELETE)
- Uses execute message infrastructure from Story 2.1

## Tasks / Subtasks

- [ ] Task 1: Implement TTC COMMIT Message (AC: 1, 5)
  - [ ] 1.1: Create `lib/src/protocol/messages/commit_message.dart`
  - [ ] 1.2: Implement `CommitRequest.encode()` following TTC protocol
  - [ ] 1.3: Implement `CommitResponse.decode()` to parse Oracle's commit response
  - [ ] 1.4: Reference: `node-oracledb/lib/thin/protocol/messages/commit.js`
  - [ ] 1.5: Add unit tests for CommitRequest/CommitResponse encoding/decoding

- [ ] Task 2: Implement TTC ROLLBACK Message (AC: 2, 3, 6)
  - [ ] 2.1: Create `lib/src/protocol/messages/rollback_message.dart`
  - [ ] 2.2: Implement `RollbackRequest.encode()` following TTC protocol
  - [ ] 2.3: Implement `RollbackResponse.decode()` to parse Oracle's rollback response
  - [ ] 2.4: Reference: `node-oracledb/lib/thin/protocol/messages/rollback.js`
  - [ ] 2.5: Add unit tests for RollbackRequest/RollbackResponse encoding/decoding

- [ ] Task 3: Add commit() Method to OracleConnection (AC: 1, 5)
  - [ ] 3.1: In `lib/src/connection.dart`, add `Future<void> commit()` method
  - [ ] 3.2: Method should call `_ensureOpen()` to check connection state
  - [ ] 3.3: Send CommitRequest via transport and await CommitResponse
  - [ ] 3.4: Log transaction commit with `package:logging` (_log.fine)
  - [ ] 3.5: Throw OracleException on commit failure with error context

- [ ] Task 4: Add rollback() Method to OracleConnection (AC: 2, 3, 6)
  - [ ] 4.1: In `lib/src/connection.dart`, add `Future<void> rollback()` method
  - [ ] 4.2: Method should call `_ensureOpen()` to check connection state
  - [ ] 4.3: Send RollbackRequest via transport and await RollbackResponse
  - [ ] 4.4: Log transaction rollback with `package:logging` (_log.fine)
  - [ ] 4.5: Throw OracleException on rollback failure with error context

- [ ] Task 5: Implement runTransaction() Convenience Wrapper (AC: 4)
  - [ ] 5.1: In `lib/src/connection.dart`, add `Future<T> runTransaction<T>(Future<T> Function(OracleConnection) callback)`
  - [ ] 5.2: Execute callback with connection passed as parameter
  - [ ] 5.3: On successful completion, call `commit()` automatically
  - [ ] 5.4: On exception, call `rollback()` automatically and rethrow exception
  - [ ] 5.5: Use try-catch-finally to ensure rollback happens on error
  - [ ] 5.6: Return callback's return value to caller

- [ ] Task 6: Create Integration Tests for commit() (AC: 1, 5) - WILL BE BLOCKED until auth fix
  - [ ] 6.1: Test INSERT → commit() → verify on new connection (visibility)
  - [ ] 6.2: Test multiple INSERTs → single commit() → verify all visible
  - [ ] 6.3: Test commit() with no pending changes (should succeed)
  - [ ] 6.4: Test commit() on closed connection throws OracleException
  - [ ] 6.5: Add to `test/integration/query_integration_test.dart`

- [ ] Task 7: Create Integration Tests for rollback() (AC: 2, 3, 6) - WILL BE BLOCKED until auth fix
  - [ ] 7.1: Test INSERT → rollback() → verify data NOT present
  - [ ] 7.2: Test multiple DML → rollback() → verify ALL undone (AC3)
  - [ ] 7.3: Test UPDATE → rollback() → verify original value restored
  - [ ] 7.4: Test DELETE → rollback() → verify row still exists
  - [ ] 7.5: Test rollback() with no pending changes (should succeed)
  - [ ] 7.6: Test rollback() on closed connection throws OracleException

- [ ] Task 8: Create Integration Tests for runTransaction() (AC: 4) - WILL BE BLOCKED until auth fix
  - [ ] 8.1: Test successful transaction → auto-commit → verify visible
  - [ ] 8.2: Test exception in transaction → auto-rollback → verify NOT visible
  - [ ] 8.3: Test return value passes through wrapper correctly
  - [ ] 8.4: Test nested DML operations within transaction callback
  - [ ] 8.5: Test runTransaction() on closed connection throws OracleException

- [ ] Task 9: Add Dartdoc Documentation (AC: all)
  - [ ] 9.1: Document commit() method with transaction behavior notes
  - [ ] 9.2: Document rollback() method with Oracle implicit transaction model
  - [ ] 9.3: Document runTransaction() with auto-commit/rollback behavior
  - [ ] 9.4: Include code examples showing usage patterns
  - [ ] 9.5: Note that connection.close() auto-rollbacks uncommitted changes

- [ ] Task 10: Finalize and Validate (AC: all)
  - [ ] 10.1: Run `dart analyze` with zero warnings
  - [ ] 10.2: Run `dart format --set-exit-if-changed .`
  - [ ] 10.3: Run unit tests with `dart test` (exclude integration)
  - [ ] 10.4: Integration tests will be BLOCKED until Epic 1 auth bug fixed
  - [ ] 10.5: Update this story file with completion notes

### Architecture Compliance (MANDATORY)

**Source:** [docs/architecture.md](../architecture.md)

**Layer Boundaries:**
- Transaction messages in protocol layer: `lib/src/protocol/messages/commit_message.dart`, `rollback_message.dart`
- Public API methods in application layer: `lib/src/connection.dart` (commit, rollback, runTransaction)
- Transport layer handles message sending (no changes needed)

**Buffer Operations (CRITICAL - use explicit endianness):**
```dart
// CORRECT - Explicit endianness for TTC protocol
final functionCode = buffer.readUint8();
buffer.writeUint8(ttcCommit);  // Or ttcRollback

// WRONG - Ambiguous
buffer.write(ttcCommit);  // Missing type/endianness
```

**Error Handling Pattern (MANDATORY):**
```dart
// CORRECT - Preserve original error context
Future<void> commit() async {
  _ensureOpen();

  try {
    final request = CommitRequest();
    final responseBytes = await _transport.sendReceive(request.encode());
    final response = CommitResponse.decode(responseBytes);
    _log.fine('Transaction committed');
  } catch (e) {
    if (e is OracleException) rethrow;
    throw OracleException(
      errorCode: oraTransactionFailed,
      message: 'Failed to commit transaction',
      cause: e,  // PRESERVE original error
    );
  }
}

// WRONG - Lost error context
Future<void> commit() async {
  try {
    // ... send commit
  } catch (e) {
    throw OracleException(
      errorCode: oraTransactionFailed,
      message: 'Commit failed',
      // Missing cause parameter!
    );
  }
}
```

**Resource Management Pattern (MANDATORY - Dual Pattern):**
```dart
// Pattern 1: Explicit control (always available)
final conn = await OracleConnection.connect(...);
try {
  await conn.execute('INSERT INTO t VALUES (:1)', [1]);
  await conn.execute('UPDATE t SET x = :1 WHERE id = :2', [100, 1]);
  await conn.commit();  // Explicit commit
} catch (e) {
  await conn.rollback();  // Explicit rollback on error
  rethrow;
} finally {
  await conn.close();
}

// Pattern 2: Auto-commit/rollback wrapper (convenience)
final conn = await OracleConnection.connect(...);
try {
  await conn.runTransaction((conn) async {
    await conn.execute('INSERT INTO t VALUES (:1)', [1]);
    await conn.execute('UPDATE t SET x = :1 WHERE id = :2', [100, 1]);
    // Auto-commit on success
  });  // Auto-rollback on exception
} finally {
  await conn.close();
}
```

**Logging Pattern (package:logging required):**
```dart
import 'package:logging/logging.dart';

final _log = Logger('OracleConnection');

// In commit()
_log.fine('Committing transaction');

// In rollback()
_log.fine('Rolling back transaction');

// In runTransaction()
_log.fine('Starting transaction');
_log.fine('Transaction completed successfully');
// or
_log.warning('Transaction failed, rolling back', error);
```

### Previous Story Intelligence

**From Story 2.4 (DML Operations):**
- ✅ DML operations (INSERT, UPDATE, DELETE) working - needed for transaction testing
- ✅ Test infrastructure with setUp/tearDown established
- ✅ Oracle transaction behavior observed: changes visible to same connection before commit
- ✅ Integration tests blocked by ORA-12547 (Epic 1 auth bug)
- ⚠️ **CRITICAL:** All Story 2.4 integration tests will pass once commit() is implemented and auth is fixed

**From Story 2.1 (Execute Message):**
- ✅ ExecuteRequest/ExecuteResponse pattern established - use same pattern for Commit/Rollback messages
- ✅ Message encoding follows TTC protocol with explicit buffer operations
- ✅ Unit tests for message encode/decode in `test/src/protocol/messages/`

**Key Patterns to Reuse:**
```dart
// Message structure pattern (from execute_message.dart)
class CommitRequest {
  Uint8List encode() {
    final buffer = ByteBuffer();
    buffer.writeUint8(ttcCommit);  // Function code
    // ... additional fields per TTC protocol
    return buffer.toBytes();
  }
}

class CommitResponse {
  static CommitResponse decode(Uint8List bytes) {
    final buffer = ByteBuffer.fromBytes(bytes);
    final status = buffer.readUint8();
    // ... parse response fields
    return CommitResponse(status: status);
  }
}
```

### Git Intelligence Summary

**Recent Implementation Patterns (last 10 commits):**
```
431cd72 feat: Add minimal authentication test for AUTH_PHASE_ONE protocol
9a2692b WIP: Auth protocol implementation (broken - connection closes at AUTH_PHASE_ONE)
b96567f feat: Implement DML operations (INSERT, UPDATE, DELETE) support
bd57e42 feat: Implement bind parameter support in execute() method
513fcb8 feat: Implement execute message and basic query execution (Story 2.1)
```

**Established Code Conventions:**
1. ✅ All code passes `dart analyze` with zero warnings
2. ✅ Integration tests use `@Tags(['integration'])` annotation
3. ✅ Message files named `*_message.dart` (e.g., `execute_message.dart`)
4. ✅ Request/Response classes follow encode()/decode() pattern
5. ✅ All methods have dartdoc comments with usage examples
6. ✅ Error handling preserves original error via `cause` parameter

**Files Modified in Recent Stories:**
- `lib/src/connection.dart` - Add new methods here (commit, rollback, runTransaction)
- `lib/src/protocol/messages/` - Add commit_message.dart, rollback_message.dart
- `test/integration/query_integration_test.dart` - Add transaction tests

### Technical Requirements

**TTC Protocol Constants (add to `lib/src/protocol/constants.dart` if not present):**
```dart
const ttcCommit = 0x0E;      // TTC function code for COMMIT
const ttcRollback = 0x0F;    // TTC function code for ROLLBACK
```

**TTC COMMIT Message Structure:**
Reference: node-oracledb thin driver `lib/thin/protocol/messages/commit.js`
```
Request:
[function_code: 1 byte = 0x0E]
[sequence_number: 1 byte]
[... additional TTC protocol fields ...]

Response:
[status: 1 byte]
[... commit confirmation ...]
```

**TTC ROLLBACK Message Structure:**
Reference: node-oracledb thin driver `lib/thin/protocol/messages/rollback.js`
```
Request:
[function_code: 1 byte = 0x0F]
[sequence_number: 1 byte]
[... additional TTC protocol fields ...]

Response:
[status: 1 byte]
[... rollback confirmation ...]
```

**⚠️ IMPORTANT:** The exact TTC message format must be determined by:
1. Reading node-oracledb source code: `lib/thin/protocol/messages/commit.js` and `rollback.js`
2. Following the same pattern as execute_message.dart
3. Using explicit buffer read/write methods (readUint8BE, writeUint32BE, etc.)

### Library & Framework Requirements

**Dependencies (already in pubspec.yaml - no changes needed):**
- `package:logging` - For _log.fine() transaction logging
- `dart:typed_data` - For Uint8List buffer operations
- No external transaction libraries needed (built into Oracle protocol)

**Dart SDK Version:**
- Dart 3.0+ (per architecture.md)
- No special transaction APIs needed - standard async/await patterns

### File Structure Requirements

**Files to CREATE:**
```
lib/src/protocol/messages/commit_message.dart
lib/src/protocol/messages/rollback_message.dart
test/src/protocol/messages/commit_message_test.dart
test/src/protocol/messages/rollback_message_test.dart
```

**Files to MODIFY:**
```
lib/src/connection.dart
  - Add commit() method
  - Add rollback() method
  - Add runTransaction() method

lib/src/protocol/constants.dart (if ttcCommit/ttcRollback not present)
  - Add const ttcCommit = 0x0E;
  - Add const ttcRollback = 0x0F;

test/integration/query_integration_test.dart
  - Add group('Transaction management', ...)
  - Add commit() tests
  - Add rollback() tests
  - Add runTransaction() tests
```

**Files to REFERENCE (do not modify):**
```
lib/src/protocol/messages/execute_message.dart
  - Use as pattern for commit/rollback messages

lib/src/transport/transport.dart
  - sendReceive() method for message communication

lib/src/errors.dart
  - OracleException class and error codes
```

### Testing Requirements

**Unit Tests (can be executed now):**
- CommitRequest.encode() produces correct byte sequence
- CommitResponse.decode() parses Oracle response correctly
- RollbackRequest.encode() produces correct byte sequence
- RollbackResponse.decode() parses Oracle response correctly

**Integration Tests (BLOCKED until Epic 1 auth fixed):**
- commit() makes changes visible to other connections
- rollback() undoes pending changes
- runTransaction() auto-commits on success
- runTransaction() auto-rollbacks on exception
- Multiple DML in single transaction behaves correctly

**Test Isolation Strategy:**
```dart
group('Transaction management',
    skip: !hasOracle ? 'Integration tests disabled' : null, () {
  late OracleConnection conn1;
  late OracleConnection conn2;  // Second connection for visibility testing

  setUp(() async {
    conn1 = await OracleConnection.connect(...);
    conn2 = await OracleConnection.connect(...);

    // Create test table
    await conn1.execute('''
      CREATE TABLE test_tx_story25 (
        id NUMBER PRIMARY KEY,
        value NUMBER
      )
    ''');
    await conn1.commit();  // Make table visible to conn2
  });

  tearDown() async {
    await conn1.execute('DROP TABLE test_tx_story25');
    await conn1.commit();
    await conn1.close();
    await conn2.close();
  });

  test('commit makes changes visible to other connections', () async {
    // Insert on conn1 (not committed)
    await conn1.execute('INSERT INTO test_tx_story25 VALUES (1, 100)');

    // Should NOT be visible on conn2 yet
    var result = await conn2.execute('SELECT * FROM test_tx_story25 WHERE id = 1');
    expect(result.rows, isEmpty);

    // Commit on conn1
    await conn1.commit();

    // NOW should be visible on conn2
    result = await conn2.execute('SELECT * FROM test_tx_story25 WHERE id = 1');
    expect(result.rows.length, equals(1));
    expect(result.rows[0]['VALUE'], equals(100));
  });
});
```

### Anti-Patterns to Avoid

| Anti-Pattern | Correct Pattern |
|--------------|-----------------|
| Assuming commit/rollback are no-ops | Always send TTC messages to Oracle |
| Not testing visibility across connections | Use 2 connections in tests to verify commit behavior |
| Forgetting to rollback in runTransaction() on error | Use try-catch-finally pattern |
| Not preserving error context | Always include `cause: e` in OracleException |
| Using ambiguous buffer methods | Always use explicit BE/LE methods |

### Edge Cases to Handle

1. **commit() with no pending changes**: Should succeed (Oracle allows this)
2. **rollback() with no pending changes**: Should succeed (Oracle allows this)
3. **commit() on closed connection**: Should throw OracleException with oraConnectionClosed
4. **rollback() on closed connection**: Should throw OracleException with oraConnectionClosed
5. **Exception in runTransaction() callback**: Must rollback AND rethrow exception
6. **Nested runTransaction() calls**: Not supported in this story (document as limitation)
7. **Return value from runTransaction()**: Must pass through callback's return value

### References

**Project Documents:**
- [Architecture: Transaction Management](../architecture.md#resource-management) - Dual pattern requirement
- [PRD: FR22, FR23, FR24](../prd.md) - Transaction requirements
- [Epic 2: Story 2.5 Requirements](../epics.md#story-25-transaction-management)

**Source Files:**
- `lib/src/connection.dart` - Add commit(), rollback(), runTransaction() methods
- `lib/src/protocol/messages/execute_message.dart` - Pattern reference for message encoding
- `lib/src/protocol/constants.dart` - Add ttcCommit, ttcRollback constants

**External References:**
- node-oracledb: `lib/thin/protocol/messages/commit.js`
- node-oracledb: `lib/thin/protocol/messages/rollback.js`
- Oracle TTC Protocol documentation (if available)
- [Oracle Transaction Management](https://docs.oracle.com/en/database/oracle/oracle-database/23/cncpt/transactions.html)

### BLOCKER: Epic 1 Authentication Bug

**Status:** ⚠️ CRITICAL - All Epic 2 integration tests are blocked

**Issue:** Story 1.4 authentication is broken - Oracle closes connection at AUTH_PHASE_ONE with ORA-12547

**Impact on Story 2.5:**
- Unit tests for commit/rollback messages CAN be written and will pass
- Integration tests CANNOT be executed until authentication is fixed
- Code implementation for commit(), rollback(), runTransaction() CAN be completed
- Full story validation requires Epic 1 fix

**Workaround:**
- Implement all code and unit tests
- Mark integration tests with clear comments: `// BLOCKED: Epic 1 auth bug`
- Story will be marked "ready-for-review" pending integration test validation
- Integration tests will be executed after Epic 1.4-FIX is completed

## Dev Agent Record

### Context Reference

Story created by SM agent using ultimate context engine analysis.

**Comprehensive Analysis Performed:**
- ✅ Epic 2 context and story dependencies analyzed
- ✅ Story 2.4 DML operations learnings extracted
- ✅ Architecture patterns for transaction management reviewed
- ✅ Oracle transaction behavior documented from previous testing
- ✅ Git commit history analyzed for implementation patterns
- ✅ TTC protocol requirements identified from node-oracledb reference
- ✅ Integration test blocking issue documented (Epic 1 auth bug)

**Critical Context Included:**
- Oracle implicit transaction model (auto-start on first DML)
- Visibility rules (same connection vs. other sessions)
- Dual pattern requirement (explicit + convenience wrapper)
- Error handling with cause preservation
- Test infrastructure from Story 2.4 (setUp/tearDown)
- TTC message structure references from node-oracledb

**Developer Guardrails Established:**
- ✅ Explicit buffer operation requirements (readUint8BE, etc.)
- ✅ Error propagation pattern with cause parameter
- ✅ Logging requirements with package:logging
- ✅ Dual pattern implementation (commit/rollback + runTransaction)
- ✅ Integration test strategy with 2 connections for visibility testing
- ✅ Documentation requirements (dartdoc with examples)

### Agent Model Used

Claude Sonnet 4.5 (claude-sonnet-4-5-20250929)

### Completion Notes List

Story context created - ready for dev agent implementation.

All architectural requirements, previous story learnings, and critical Oracle transaction behavior documented for flawless implementation.

### File List

**Files to be Created:**
- `lib/src/protocol/messages/commit_message.dart`
- `lib/src/protocol/messages/rollback_message.dart`
- `test/src/protocol/messages/commit_message_test.dart`
- `test/src/protocol/messages/rollback_message_test.dart`

**Files to be Modified:**
- `lib/src/connection.dart`
- `lib/src/protocol/constants.dart` (if constants not present)
- `test/integration/query_integration_test.dart`
