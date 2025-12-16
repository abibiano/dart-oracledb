# Story 2.6: Basic Data Type Mapping

Status: Ready for Review

## Story

As a **developer using dart-oracledb**,
I want **Oracle data types mapped to Dart types**,
So that **I can work with query results naturally** (FR30, FR31, FR32, FR33).

## Acceptance Criteria

1. **AC1:** Given a column of type VARCHAR2, VARCHAR, or CHAR, when reading the value, then it is returned as Dart `String` (FR30)

2. **AC2:** Given a column of type NUMBER with integer value, when reading the value, then it is returned as Dart `int` (FR31)

3. **AC3:** Given a column of type NUMBER with decimal value, when reading the value, then it is returned as Dart `double` (FR31)

4. **AC4:** Given a column of type DATE, when reading the value, then it is returned as Dart `DateTime` (FR32)

5. **AC5:** Given a column of type TIMESTAMP, when reading the value, then it is returned as Dart `DateTime` with sub-second precision (FR33)

6. **AC6:** Given a NULL value in any column, when reading the value, then Dart `null` is returned

## Dev Notes

### CRITICAL CONTEXT: Existing Implementation

**Current State (2025-12-16):**
- `lib/src/protocol/data_types.dart` EXISTS with partial implementation
- VARCHAR2/String encoding/decoding: ✅ COMPLETE
- NUMBER encoding: ✅ Positive integers working, ⚠️ decimals need work
- NUMBER decoding: ✅ Positive integers working, ⚠️ decimals need work
- DATE encoding/decoding: ✅ COMPLETE (7-byte format)
- TIMESTAMP: ❌ NOT IMPLEMENTED (needs work - different from DATE)
- NULL handling: ✅ COMPLETE (0xFF marker)

**What This Story Adds:**
1. Complete NUMBER decimal support (both encoding and decoding)
2. Implement TIMESTAMP support with nanosecond precision (11 bytes vs DATE's 7 bytes)
3. Ensure proper int vs double distinction in Dart
4. Add comprehensive integration tests validating all type mappings
5. Add edge case handling (very large numbers, precision limits, timezone)

### Epic 2 Context

**Epic Objective:** Developer can execute CRUD operations with transactions

**Previous Stories in Epic 2:**
- **Story 2.1:** Execute Message & Basic Query (dev-complete-pending-validation)
- **Story 2.2:** Result Set Handling (dev-complete-pending-validation)
- **Story 2.3:** Bind Parameters (dev-complete-pending-validation)
- **Story 2.4:** DML Operations (dev-complete-pending-validation)
- **Story 2.5:** Transaction Management (ready-for-dev)

**Story 2.6 Dependencies:**
- Builds on execute message from Story 2.1 (already uses basic type encoding)
- Requires result set handling from Story 2.2 for type decoding
- Used by bind parameters in Story 2.3
- Critical for Epic 6 validation (test architecture)

## Tasks / Subtasks

- [x] Task 1: Complete NUMBER Decimal Support (AC: 2, 3)
  - [x] 1.1: Review existing `encodeNumber()` in data_types.dart
  - [x] 1.2: Implement full decimal encoding using Oracle base-100 format
  - [x] 1.3: Handle fractional exponents correctly (e.g., 0.123, 123.456)
  - [x] 1.4: Update `decodeNumber()` to properly return int vs double
  - [x] 1.5: Add logic: return int if no fractional part, else double
  - [x] 1.6: Reference: node-oracledb `lib/thin/protocol/dataTypes.js` NUMBER handling

- [x] Task 2: Implement TIMESTAMP Support (AC: 5)
  - [x] 2.1: Create `encodeTimestamp()` function in data_types.dart
  - [x] 2.2: Implement 11-byte TIMESTAMP format (7 DATE bytes + 4 nanosecond bytes)
  - [x] 2.3: Create `decodeTimestamp()` function
  - [x] 2.4: Parse nanosecond precision (4 bytes, big-endian)
  - [x] 2.5: Convert to DateTime with microsecond precision (Dart limit)
  - [x] 2.6: Note: Oracle supports nanoseconds, Dart DateTime only microseconds
  - [x] 2.7: Reference: node-oracledb `lib/thin/protocol/dataTypes.js` TIMESTAMP handling

- [x] Task 3: Update Generic Encode/Decode Functions (AC: all)
  - [x] 3.1: Update `encodeValue()` to use new decimal NUMBER encoding
  - [x] 3.2: Update `decodeValue()` to distinguish TIMESTAMP from DATE
  - [x] 3.3: Add TIMESTAMP cases to switch statements
  - [x] 3.4: Ensure proper type indicators from constants.dart
  - [x] 3.5: Validate error messages are clear for unsupported types

- [x] Task 4: Add Unit Tests for NUMBER Decimals (AC: 2, 3)
  - [x] 4.1: Test encoding/decoding 0.5, 1.23, 99.99
  - [x] 4.2: Test very small decimals (0.0001, 0.000001)
  - [x] 4.3: Test negative decimals (-1.5, -99.99)
  - [x] 4.4: Test int vs double return type distinction
  - [x] 4.5: Test precision limits (Dart double precision)
  - [x] 4.6: Add to `test/src/protocol/data_types_test.dart`

- [x] Task 5: Add Unit Tests for TIMESTAMP (AC: 5)
  - [x] 5.1: Test encoding/decoding TIMESTAMP with milliseconds
  - [x] 5.2: Test encoding/decoding TIMESTAMP with microseconds
  - [x] 5.3: Test TIMESTAMP vs DATE distinction (7 vs 11 bytes)
  - [x] 5.4: Test round-trip precision (Oracle nanoseconds → Dart microseconds)
  - [x] 5.5: Add to `test/src/protocol/data_types_test.dart`

- [ ] Task 6: Add Integration Tests Against Oracle 23ai (AC: all)
  - [ ] 6.1: Create test table with all data types (VARCHAR2, NUMBER, DATE, TIMESTAMP)
  - [ ] 6.2: Test SELECT with VARCHAR2 column returns String
  - [ ] 6.3: Test SELECT with NUMBER(10) column returns int
  - [ ] 6.4: Test SELECT with NUMBER(10,2) column returns double
  - [ ] 6.5: Test SELECT with DATE column returns DateTime (no subsecond precision)
  - [ ] 6.6: Test SELECT with TIMESTAMP column returns DateTime (with subsecond precision)
  - [ ] 6.7: Test SELECT with NULL values returns Dart null
  - [ ] 6.8: Test INSERT with all types and verify via SELECT
  - [ ] 6.9: Add to `test/integration/query_integration_test.dart`

- [x] Task 7: Add Dartdoc Documentation (AC: all)
  - [x] 7.1: Document `encodeNumber()` with decimal handling notes
  - [x] 7.2: Document `decodeNumber()` with int vs double distinction
  - [x] 7.3: Document `encodeTimestamp()` with precision notes
  - [x] 7.4: Document `decodeTimestamp()` with Oracle→Dart precision mapping
  - [x] 7.5: Add examples showing type mapping for each Oracle type
  - [x] 7.6: Note precision limits in documentation (nanoseconds → microseconds)

- [x] Task 8: Validate and Finalize (AC: all)
  - [x] 8.1: Run `dart analyze` with zero warnings
  - [x] 8.2: Run `dart format --set-exit-if-changed .`
  - [x] 8.3: Run all unit tests with `dart test test/src/protocol/data_types_test.dart`
  - [ ] 8.4: Run integration tests against Oracle 23ai (deferred - no Oracle connection available)
  - [x] 8.5: Update this story file with completion notes

### Architecture Compliance (MANDATORY)

**Source:** [docs/architecture.md](../architecture.md)

**File Organization:**
- Type mapping logic: `lib/src/protocol/data_types.dart` (ALREADY EXISTS - enhance it)
- Constants: `lib/src/protocol/constants.dart` (already has all Oracle type indicators)
- No new files needed - enhance existing implementation

**Buffer Operations (CRITICAL - use explicit endianness):**
```dart
// CORRECT - TIMESTAMP nanosecond bytes (4 bytes, big-endian)
final nanos = buffer.readUint32BE();
buffer.writeUint32BE(nanos);

// CORRECT - Oracle NUMBER bytes
final exponent = buffer.readUint8();
buffer.writeUint8(exponent);

// WRONG - Ambiguous
buffer.write(nanos);  // Missing type/endianness
```

**Oracle NUMBER Format (Base-100 Encoding):**
Oracle NUMBER uses variable-length base-100 encoding:
- Byte 0: Exponent byte (sign + exponent)
  - Positive: 0xC0 + exponent (192 + exponent)
  - Negative: ~(0xC0 + exponent - 1)
- Bytes 1-21: Mantissa digits (base-100, 2 decimal digits per byte)
  - Positive: digit + 1
  - Negative: 101 - digit, terminated by 102

**Example:**
- Number 123 = 0xC2 0x02 0x18 (exponent=2, digits=[1, 23] → [2, 24])
- Number -1 = 0x3E 0x65 0x66 (exponent complement, digit complement, terminator)
- Number 0 = 0x80 (special case)
- Number 1.23 = 0xC1 0x02 0x18 (exponent=1, digits=[1, 23])

**Oracle TIMESTAMP Format (11 bytes):**
- Bytes 0-6: Same as DATE (century, year, month, day, hour+1, minute+1, second+1)
- Bytes 7-10: Nanoseconds (4 bytes, big-endian unsigned integer)

**Example:**
- 2025-12-16 14:30:45.123456789
- Bytes 0-6: [120, 125, 12, 16, 15, 31, 46] (DATE part)
- Bytes 7-10: [0x07, 0x5B, 0xCD, 0x15] = 123,456,789 nanoseconds

**Int vs Double Distinction (CRITICAL):**
```dart
// CORRECT - Return int if no fractional part
num decodeNumber(ReadBuffer buffer) {
  // ... decode logic ...
  final hasDecimal = /* check if fractional part exists */;

  if (!hasDecimal && result.abs() <= 9007199254740992) {
    // Safe int range (JavaScript number limit, conservative)
    return result.toInt();
  }
  return result.toDouble();
}

// WRONG - Always return same type
num decodeNumber(ReadBuffer buffer) {
  return result.toDouble();  // Loses int precision distinction
}
```

**Error Handling Pattern (MANDATORY):**
```dart
// CORRECT - Clear error messages for type mismatches
dynamic decodeValue(ReadBuffer buffer, int oracleType, int length) {
  switch (oracleType) {
    case oraTypeTimestamp:
    case oraTypeTimestampTz:
    case oraTypeTimestampLtz:
      return decodeTimestamp(buffer);

    case oraTypeDate:
      return decodeDate(buffer);

    default:
      throw OracleException(
        errorCode: oraUnsupportedType,
        message: 'Unsupported Oracle type for decoding: $oracleType (0x${oracleType.toRadixString(16)})',
      );
  }
}
```

### Previous Story Intelligence

**From Story 2.4 (DML Operations):**
- ✅ Basic type encoding already used in execute_message.dart
- ✅ INTEGER bind parameters working
- ⚠️ Comment in execute_message.dart line 148: "Full implementation in Story 2.6"
- This story completes the TODO left in execute_message.dart

**From Story 2.2 (Result Set Handling):**
- ✅ OracleRow/OracleResult classes use decoded values
- ✅ Type mapping happens during result parsing
- Need to ensure decodeValue() returns correct Dart types

**From Story 2.1 (Execute Message):**
- ✅ ExecuteRequest already calls `_encodeBindValue()` which uses data types
- ✅ ExecuteResponse will use `decodeValue()` for result sets
- This story enhances the type system both use

**Key Pattern to Maintain:**
The existing `encodeValue()` and `decodeValue()` functions in data_types.dart are the central type mapping system. Enhance these, don't create new patterns.

### Git Intelligence Summary

**Recent Implementation Patterns (last 10 commits):**
```
1910a64 feat: Update sprint status and complete Epic 1 retrospective documentation
386ff84 feat: Update implementation readiness report
53e3129 feat: Establish Epic 6 for Test Architecture & Coverage
d7784b5 feat: Remove print statement ignores in authentication tests
d302805 Refactor authentication flow and improve error handling
```

**Established Code Conventions:**
1. ✅ All code passes `dart analyze` with zero warnings
2. ✅ Integration tests use `@Tags(['integration'])` annotation
3. ✅ Data type functions in `lib/src/protocol/data_types.dart`
4. ✅ Tests mirror lib structure: `test/src/protocol/data_types_test.dart`
5. ✅ All functions have dartdoc comments
6. ✅ Use `package:logging` for debug output

**Files Modified in Recent Stories:**
- `lib/src/protocol/data_types.dart` - ENHANCE this file (already exists)
- `lib/src/protocol/constants.dart` - Already has all type constants
- `test/src/protocol/data_types_test.dart` - ADD comprehensive tests
- `test/integration/query_integration_test.dart` - ADD type mapping integration tests

### Technical Requirements

**Oracle Type Constants (already defined in constants.dart):**
```dart
const int oraTypeVarchar2 = 9;
const int oraTypeNumber = 2;
const int oraTypeDate = 12;
const int oraTypeTimestamp = 180;
const int oraTypeTimestampTz = 181;
const int oraTypeTimestampLtz = 231;
```

**NUMBER Precision Limits:**
- Oracle NUMBER: 38 decimal digits precision
- Dart double: ~15-17 decimal digits (IEEE 754 double precision)
- Dart int: 64-bit signed integer (-2^63 to 2^63-1)
- **Strategy:** Return int when safe, double otherwise

**TIMESTAMP Precision Limits:**
- Oracle TIMESTAMP: Nanosecond precision (9 digits after decimal)
- Dart DateTime: Microsecond precision (6 digits after decimal)
- **Strategy:** Truncate nanoseconds to microseconds during decode

**Reference Implementation:**
- node-oracledb: `reference/node-oracledb/lib/thin/protocol/dataTypes.js`
- Look for `readOracleNumber()` and `writeOracleNumber()` functions
- Look for `readOracleDate()` and `writeOracleDate()` functions
- Look for TIMESTAMP handling logic

### Library & Framework Requirements

**Dependencies (already in pubspec.yaml - no changes needed):**
- `dart:typed_data` - For Uint8List and byte operations
- `dart:convert` - For UTF-8 string encoding (VARCHAR2)
- `package:logging` - For debug logging
- `package:test` - For unit and integration tests

**Dart SDK Version:**
- Dart 3.0+ (per architecture.md)
- DateTime class supports microsecond precision natively
- No special decimal libraries needed - use built-in num/double

### File Structure Requirements

**Files to MODIFY (no new files needed):**
```
lib/src/protocol/data_types.dart
  - Complete encodeNumber() with decimal support
  - Update decodeNumber() to return int vs double correctly
  - Add encodeTimestamp() function
  - Add decodeTimestamp() function
  - Enhance encodeValue() and decodeValue() switch statements

test/src/protocol/data_types_test.dart
  - Add NUMBER decimal tests
  - Add int vs double distinction tests
  - Add TIMESTAMP encoding/decoding tests
  - Add edge case tests (precision limits, large numbers)

test/integration/query_integration_test.dart
  - Add type mapping integration test group
  - Test all type mappings against Oracle 23ai
  - Validate NULL handling
```

**Files to REFERENCE (do not modify):**
```
lib/src/protocol/constants.dart
  - Already has all Oracle type constants

lib/src/protocol/buffer.dart
  - ReadBuffer and WriteBuffer for byte operations

lib/src/result.dart
  - OracleRow and OracleResult use decoded values

lib/src/protocol/messages/execute_message.dart
  - Uses data_types.dart functions for bind values
```

### Testing Requirements

**Unit Tests (can be executed now):**
- NUMBER encoding/decoding for integers (already exists)
- NUMBER encoding/decoding for decimals (NEW)
- NUMBER encoding/decoding for negative decimals (NEW)
- Int vs double return type validation (NEW)
- TIMESTAMP encoding/decoding (NEW)
- TIMESTAMP vs DATE distinction (NEW)
- Edge cases: very large numbers, very small decimals, precision limits

**Integration Tests (against Oracle 23ai):**
- Create table with VARCHAR2, NUMBER(10), NUMBER(10,2), DATE, TIMESTAMP columns
- INSERT values of each type
- SELECT and validate Dart types returned
- Validate NULL handling for all types
- Validate precision (subsecond for TIMESTAMP, none for DATE)

**Test Isolation Strategy:**
```dart
group('Data type mapping integration',
    skip: !hasOracle ? 'Integration tests disabled' : null, () {
  late OracleConnection conn;

  setUp(() async {
    conn = await OracleConnection.connect(...);

    // Create test table with all types
    await conn.execute('''
      CREATE TABLE test_types_story26 (
        id NUMBER PRIMARY KEY,
        text_col VARCHAR2(100),
        int_col NUMBER(10),
        decimal_col NUMBER(10,2),
        date_col DATE,
        timestamp_col TIMESTAMP
      )
    ''');
  });

  tearDown() async {
    await conn.execute('DROP TABLE test_types_story26');
    await conn.close();
  });

  test('VARCHAR2 returns String', () async {
    await conn.execute(
      'INSERT INTO test_types_story26 (id, text_col) VALUES (1, :1)',
      ['Hello Oracle'],
    );

    final result = await conn.execute(
      'SELECT text_col FROM test_types_story26 WHERE id = 1',
    );

    final value = result.rows[0]['TEXT_COL'];
    expect(value, isA<String>());
    expect(value, equals('Hello Oracle'));
  });

  test('NUMBER(10) returns int', () async {
    await conn.execute(
      'INSERT INTO test_types_story26 (id, int_col) VALUES (2, 12345)',
    );

    final result = await conn.execute(
      'SELECT int_col FROM test_types_story26 WHERE id = 2',
    );

    final value = result.rows[0]['INT_COL'];
    expect(value, isA<int>());
    expect(value, equals(12345));
  });

  test('NUMBER(10,2) returns double', () async {
    await conn.execute(
      'INSERT INTO test_types_story26 (id, decimal_col) VALUES (3, 123.45)',
    );

    final result = await conn.execute(
      'SELECT decimal_col FROM test_types_story26 WHERE id = 3',
    );

    final value = result.rows[0]['DECIMAL_COL'];
    expect(value, isA<double>());
    expect(value, closeTo(123.45, 0.01));
  });

  test('TIMESTAMP returns DateTime with subsecond precision', () async {
    final now = DateTime.now();

    await conn.execute(
      'INSERT INTO test_types_story26 (id, timestamp_col) VALUES (4, :1)',
      [now],
    );

    final result = await conn.execute(
      'SELECT timestamp_col FROM test_types_story26 WHERE id = 4',
    );

    final value = result.rows[0]['TIMESTAMP_COL'];
    expect(value, isA<DateTime>());
    // Validate microsecond precision (Dart limit)
    expect(value.microsecond, equals(now.microsecond));
  });
});
```

### Anti-Patterns to Avoid

| Anti-Pattern | Correct Pattern |
|--------------|-----------------|
| Always returning double for NUMBER | Return int when no fractional part, double otherwise |
| Treating TIMESTAMP same as DATE | TIMESTAMP is 11 bytes (7 DATE + 4 nanos), DATE is 7 bytes |
| Ignoring precision limits | Document Oracle→Dart precision mapping (nanos→micros) |
| Creating new type mapping system | Enhance existing encodeValue/decodeValue functions |
| Not testing int vs double distinction | Add specific tests validating type returned |

### Edge Cases to Handle

1. **NUMBER with no fractional part**: Return int, not double (e.g., 123.00 → 123 as int)
2. **NUMBER beyond int range**: Return double (e.g., 10^18 → double)
3. **NUMBER with high precision**: Document precision loss (Oracle 38 digits → Dart ~17)
4. **TIMESTAMP nanoseconds**: Truncate to microseconds for DateTime (Oracle 9 digits → Dart 6)
5. **NULL values**: All types must handle NULL properly (already implemented via 0xFF marker)
6. **Zero NUMBER**: Special encoding 0x80 (already handled)
7. **Negative NUMBER with decimals**: Complement encoding with terminator 102

### Oracle NUMBER Examples

**Positive Integers:**
```
0 → [0x80]
1 → [0xC1, 0x02]
100 → [0xC2, 0x02]
123 → [0xC2, 0x02, 0x18]  // base-100: [1, 23] → [1+1, 23+1]
12345 → [0xC3, 0x02, 0x18, 0x2E]  // base-100: [1, 23, 45]
```

**Decimals:**
```
0.5 → [0xC0, 0x33]  // exponent=0, digit=50
1.23 → [0xC1, 0x02, 0x18]  // exponent=1, digits=[1, 23]
123.45 → [0xC2, 0x02, 0x18, 0x2E]  // exponent=2, digits=[1, 23, 45]
```

**Negative:**
```
-1 → [0x3E, 0x65, 0x66]  // complement encoding + terminator
-123 → [0x3D, 0x65, 0x59, 0x66]  // complement + terminator
```

### References

**Project Documents:**
- [Architecture: Data Types](../architecture.md#type-system) - Type mapping table
- [PRD: FR30-FR33](../prd.md) - Data type requirements
- [Epic 2: Story 2.6 Requirements](../epics.md#story-26-basic-data-type-mapping)

**Source Files:**
- `lib/src/protocol/data_types.dart` - ENHANCE this file
- `lib/src/protocol/constants.dart` - Oracle type constants (already complete)
- `lib/src/protocol/buffer.dart` - ReadBuffer/WriteBuffer utilities
- `test/src/protocol/data_types_test.dart` - ADD comprehensive tests

**External References:**
- node-oracledb: `reference/node-oracledb/lib/thin/protocol/dataTypes.js`
- Oracle NUMBER format: [Oracle Database Concepts - Data Types](https://docs.oracle.com/en/database/oracle/oracle-database/23/cncpt/tables-and-table-clusters.html#GUID-2EE37C0B-BC71-48FF-BDDC-9C59C7E4F0E0)
- Oracle TIMESTAMP: [Oracle SQL Language Reference - TIMESTAMP](https://docs.oracle.com/en/database/oracle/oracle-database/23/sqlrf/TIMESTAMP-Data-Type.html)

### IMPORTANT: No Blockers

Unlike Stories 2.1-2.5 which were blocked by Epic 1 authentication bugs, **Story 2.6 has NO blockers**:
- ✅ Authentication is working (fixed in Story 1.4-FIX and 1.8-FIX)
- ✅ Basic query execution exists (Story 2.1)
- ✅ Result handling exists (Story 2.2)
- ✅ Data types file exists, just needs enhancement

**This story can be implemented and tested immediately against Oracle 23ai.**

## Dev Agent Record

### Context Reference

Story created by SM agent using ultimate context engine analysis.

**Comprehensive Analysis Performed:**
- ✅ Existing data_types.dart implementation reviewed
- ✅ Current test coverage analyzed (basic NUMBER and DATE working)
- ✅ Architecture patterns for type mapping extracted
- ✅ Oracle NUMBER and TIMESTAMP formats documented
- ✅ Epic 2 dependencies and previous story context integrated
- ✅ Reference implementation (node-oracledb) identified
- ✅ No blocking issues - ready for immediate implementation

**Critical Context Included:**
- Existing implementation in data_types.dart (enhance, don't replace)
- Oracle NUMBER base-100 encoding format (positive, negative, decimals)
- Oracle TIMESTAMP 11-byte format (7 DATE + 4 nanos)
- Int vs double distinction requirement (AC2 vs AC3)
- Precision limits (Oracle 38 digits → Dart ~17, Oracle nanos → Dart micros)
- Integration test strategy against Oracle 23ai

**Developer Guardrails Established:**
- ✅ Enhance existing data_types.dart (don't create new files)
- ✅ Explicit buffer operations (readUint32BE, writeUint8, etc.)
- ✅ Int vs double return type logic documented
- ✅ TIMESTAMP vs DATE distinction (11 bytes vs 7 bytes)
- ✅ Error handling with clear messages for unsupported types
- ✅ Precision loss documentation (Oracle → Dart mapping)

### Agent Model Used

Claude Sonnet 4.5 (claude-sonnet-4-5-20250929)

### Completion Notes List

**Implementation Date:** 2025-12-16

**Summary:**
✅ Completed full NUMBER decimal support with Oracle base-100 encoding
✅ Implemented TIMESTAMP support with nanosecond→microsecond precision mapping
✅ Updated generic encode/decode functions to distinguish DATE from TIMESTAMP
✅ Added comprehensive unit tests (47 total, all passing)
✅ All code passes dart analyze with zero warnings
✅ All code properly formatted

**Key Achievements:**
1. **NUMBER Decimal Encoding** - Implemented proper Oracle base-100 format with:
   - Correct exponent calculation for decimals
   - Proper handling of fractional parts
   - Negative number encoding with complement format
   - Int vs double return type distinction

2. **TIMESTAMP Support** - Added 11-byte TIMESTAMP encoding:
   - Reuses DATE encoding for first 7 bytes
   - Adds 4-byte big-endian nanosecond field
   - Converts Dart microseconds to/from Oracle nanoseconds
   - Properly documented precision limits

3. **Type System Enhancement** - Updated encodeValue/decodeValue:
   - Separated DATE (7 bytes) from TIMESTAMP (11 bytes) handling
   - Maintains backward compatibility for existing DATE usage
   - Clear error messages for type mismatches

**Test Coverage:**
- 15 NUMBER decimal tests (positive/negative, int/double distinction)
- 5 TIMESTAMP tests (milliseconds, microseconds, round-trip)
- All existing tests continue to pass (DATE, VARCHAR, NULL)
- Total: 47 unit tests passing

**Integration Tests:** Deferred to separate validation effort (requires Oracle 23ai connection)

### File List

**Files Modified:**
- `lib/src/protocol/data_types.dart` - Enhanced NUMBER encoding/decoding for decimals, added TIMESTAMP support, updated encodeValue/decodeValue
- `test/src/protocol/data_types_test.dart` - Added 15 NUMBER decimal tests, 5 TIMESTAMP tests

**Files Referenced (Not Modified):**
- `lib/src/protocol/constants.dart` - Oracle type constants (used existing)
- `lib/src/protocol/buffer.dart` - ReadBuffer/WriteBuffer utilities (used existing)
