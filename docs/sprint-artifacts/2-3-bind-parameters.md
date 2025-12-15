# Story 2.3: Bind Parameters

Status: done

## Story

As a **developer using dart-oracledb**,
I want **to use bind parameters in queries**,
So that **I can safely pass values and prevent SQL injection** (FR17, FR18).

## Acceptance Criteria

1. **AC1:** Given a query with named bind parameters, when calling `connection.execute('SELECT * FROM emp WHERE dept_id = :dept', {'dept': 10})`, then the query executes with the bound value (FR17), and the parameter is properly encoded for Oracle

2. **AC2:** Given a query with positional bind parameters, when calling `connection.execute('SELECT * FROM emp WHERE dept_id = :1', [10])`, then the query executes with the bound value (FR18)

3. **AC3:** Given multiple bind parameters, when executing `SELECT * FROM emp WHERE dept_id = :dept AND salary > :sal`, then all parameters are bound correctly

4. **AC4:** Given a null bind value, when executing the query, then Oracle NULL is properly bound

5. **AC5:** Given mismatched bind parameters (more/fewer values than placeholders), when executing the query, then an appropriate error is thrown

## Tasks / Subtasks

- [x] **Task 1: Add Bind Parameter Support to execute() Method** (AC: 1, 2)
  - [x] 1.1: Modify `execute()` signature to accept optional `bindValues` parameter: `Future<OracleResult> execute(String sql, [Object? bindValues])`
  - [x] 1.2: Detect bind value type: `Map<String, dynamic>` for named, `List<dynamic>` for positional
  - [x] 1.3: Pass bind values to `Transport.sendExecute(sql, bindValues)`
  - [x] 1.4: Validate bind values are either null, Map, or List (throw OracleException otherwise)

- [x] **Task 2: Parse SQL for Bind Placeholders** (AC: 1, 2, 3, 5)
  - [x] 2.1: Create `BindParser` utility class in `lib/src/protocol/bind_parser.dart`
  - [x] 2.2: Implement `parseNamedBinds(String sql)` - returns `List<String>` of placeholder names (`:name` patterns)
  - [x] 2.3: Implement `parsePositionalBinds(String sql)` - returns count of positional placeholders (`:1`, `:2`, etc.)
  - [x] 2.4: Handle bind placeholders inside string literals (don't match them)
  - [x] 2.5: Validate bind value count matches placeholder count

- [x] **Task 3: Implement Bind Parameter Encoding** (AC: 1, 2, 3, 4)
  - [x] 3.1: Add `bindValues` parameter to `ExecuteRequest` constructor
  - [x] 3.2: Add `bindNames` list to track parameter order for named binds
  - [x] 3.3: Encode bind count after SQL in TTC message
  - [x] 3.4: Encode each bind value with type indicator and data
  - [x] 3.5: Handle NULL values (0xFF null indicator byte)

- [x] **Task 4: Implement Value Type Encoding** (AC: 1, 2, 3, 4)
  - [x] 4.1: Create `_encodeBindValue(WriteBuffer buffer, dynamic value)` method
  - [x] 4.2: Encode `String` as VARCHAR2 (type byte + length + UTF-8 bytes)
  - [x] 4.3: Encode `int` as NUMBER (Oracle NUMBER format)
  - [x] 4.4: Encode `double` as NUMBER (Oracle NUMBER format with decimals)
  - [x] 4.5: Encode `null` as NULL indicator (0xFF byte)
  - [x] 4.6: Encode `DateTime` as DATE (Story 2.6 full support, basic here)
  - [x] 4.7: Encode `Uint8List` as RAW

- [x] **Task 5: Update Transport Layer** (AC: 1, 2)
  - [x] 5.1: Modify `Transport.sendExecute()` to accept `bindValues` parameter
  - [x] 5.2: Pass bind values to `ExecuteRequest` constructor
  - [x] 5.3: Ensure response handling unchanged (bind values don't affect response format)

- [x] **Task 6: Error Handling for Bind Parameters** (AC: 5)
  - [x] 6.1: Add `oraBindMismatch` error code constant (ORA-01008: Not all variables bound)
  - [x] 6.2: Add `oraBindTypeError` error code for invalid bind value types
  - [x] 6.3: Throw meaningful errors for: missing bind values, extra bind values, wrong types

- [x] **Task 7: Update Public Exports** (AC: all)
  - [x] 7.1: Ensure BindParser is NOT exported (internal implementation detail)
  - [x] 7.2: Document new execute() signature in dartdoc

- [x] **Task 8: Write Unit Tests** (AC: all)
  - [x] 8.1: Create `test/src/protocol/bind_parser_test.dart`
  - [x] 8.2: Test named bind parsing: `:name`, `:dept_id`, `:a`
  - [x] 8.3: Test positional bind parsing: `:1`, `:2`, `:10`
  - [x] 8.4: Test binds inside string literals are ignored: `'Hello :name'`
  - [x] 8.5: Create/update `test/src/protocol/messages/execute_message_test.dart`
  - [x] 8.6: Test ExecuteRequest encodes String bind value
  - [x] 8.7: Test ExecuteRequest encodes int bind value
  - [x] 8.8: Test ExecuteRequest encodes null bind value
  - [x] 8.9: Test ExecuteRequest encodes multiple bind values
  - [x] 8.10: Test ExecuteRequest with named binds (Map)
  - [x] 8.11: Test ExecuteRequest with positional binds (List)

- [x] **Task 9: Write Integration Tests** (AC: 1, 2, 3, 4)
  - [x] 9.1: Create/update `test/integration/query_integration_test.dart` (Bind parameters group)
  - [x] 9.2: Test named bind: `SELECT :val as result FROM dual` with `{'val': 'hello'}`
  - [x] 9.3: Test positional bind: `SELECT :1 as result FROM dual` with `['hello']`
  - [x] 9.4: Test numeric bind: `SELECT :1 as num FROM dual` with `[123]`
  - [x] 9.5: Test null bind: `SELECT :1 as result FROM dual` with `[null]`
  - [x] 9.6: Test multiple named binds in WHERE clause
  - [x] 9.7: Test bind mismatch throws appropriate error

- [x] **Task 10: Finalize and Validate** (AC: all)
  - [x] 10.1: Run `dart analyze` with zero warnings
  - [x] 10.2: Run `dart format --set-exit-if-changed .`
  - [x] 10.3: Run `dart test` - all unit tests pass (51 bind-related tests)
  - [x] 10.4: Integration tests written and ready for Oracle 23ai validation

## Dev Notes

### Wire Protocol for Bind Parameters (CRITICAL)

**WARNING:** The bind parameter encoding format below is based on protocol analysis but MUST be validated:
1. Reference `node-oracledb/lib/thin/protocol/messages/withInfo.js` for TTC bind encoding
2. Use Wireshark to capture real Oracle traffic with bind parameters if issues arise
3. Bind encoding may vary based on Oracle version - test against Oracle 23ai

### Bind Parameter Detection

Oracle uses `:name` syntax for both named and positional binds:
- Named: `:dept`, `:employee_id`, `:1name` (starts with letter)
- Positional: `:1`, `:2`, `:10` (pure numbers)

```dart
// lib/src/protocol/bind_parser.dart

/// Utility for parsing bind placeholders from SQL statements.
///
/// Oracle uses `:name` for named binds and `:n` for positional binds.
/// This parser identifies placeholders while ignoring strings literals.
class BindParser {
  /// Regex to match bind placeholders (not inside strings).
  /// Named: :name, :dept_id (letter followed by word chars)
  /// Positional: :1, :2, :10 (pure digits)
  static final _bindPattern = RegExp(r':([a-zA-Z]\w*|\d+)');

  /// Regex to detect string literals (to exclude from bind matching).
  static final _stringLiteral = RegExp(r"'(?:[^']|'')*'");

  /// Parses named bind placeholders from SQL.
  ///
  /// Returns list of placeholder names in order of appearance.
  /// Example: `SELECT * FROM emp WHERE dept = :dept AND id = :id`
  /// Returns: `['dept', 'id']`
  static List<String> parseNamedBinds(String sql) {
    // Remove string literals to avoid false matches
    final sanitized = sql.replaceAll(_stringLiteral, '');

    final matches = _bindPattern.allMatches(sanitized);
    final names = <String>[];

    for (final match in matches) {
      final name = match.group(1)!;
      // Named binds start with a letter
      if (name.isNotEmpty && !_isDigit(name[0])) {
        names.add(name);
      }
    }

    return names;
  }

  /// Parses positional bind placeholders from SQL.
  ///
  /// Returns the count of positional binds and validates they are sequential.
  /// Example: `SELECT * FROM emp WHERE dept = :1 AND id = :2`
  /// Returns: `2`
  static int parsePositionalBinds(String sql) {
    final sanitized = sql.replaceAll(_stringLiteral, '');

    final matches = _bindPattern.allMatches(sanitized);
    final positions = <int>{};

    for (final match in matches) {
      final name = match.group(1)!;
      // Positional binds are pure digits
      if (name.isNotEmpty && _isDigit(name[0])) {
        positions.add(int.parse(name));
      }
    }

    if (positions.isEmpty) return 0;

    // Validate sequential: should be 1, 2, 3, ... n
    final sorted = positions.toList()..sort();
    for (var i = 0; i < sorted.length; i++) {
      if (sorted[i] != i + 1) {
        throw OracleException(
          errorCode: oraBindMismatch,
          message: 'Positional bind parameters must be sequential starting from :1. '
              'Found: ${sorted.join(', ')}',
        );
      }
    }

    return positions.length;
  }

  /// Detects if SQL uses named binds (returns true) or positional (returns false).
  ///
  /// Throws if SQL mixes named and positional binds.
  static bool isNamedBinds(String sql) {
    final sanitized = sql.replaceAll(_stringLiteral, '');
    final matches = _bindPattern.allMatches(sanitized);

    bool hasNamed = false;
    bool hasPositional = false;

    for (final match in matches) {
      final name = match.group(1)!;
      if (name.isNotEmpty) {
        if (_isDigit(name[0])) {
          hasPositional = true;
        } else {
          hasNamed = true;
        }
      }
    }

    if (hasNamed && hasPositional) {
      throw const OracleException(
        errorCode: oraBindMismatch,
        message: 'Cannot mix named (:name) and positional (:1) bind parameters',
      );
    }

    return hasNamed;
  }

  static bool _isDigit(String char) => char.codeUnitAt(0) >= 48 && char.codeUnitAt(0) <= 57;
}
```

### ExecuteRequest with Bind Parameters

```dart
// Modified lib/src/protocol/messages/execute_message.dart

/// TTC EXECUTE request message with bind parameter support.
class ExecuteRequest extends Message {
  ExecuteRequest({
    required this.sql,
    this.bindValues,
    this.bindNames,
    this.cursorId = 0,
    this.options = 0,
    super.sequence,
  }) : super(messageType: ttcExecute);

  final String sql;

  /// Bind values - either List for positional or values from Map for named.
  final List<dynamic>? bindValues;

  /// Bind names for named parameters (in SQL order).
  final List<String>? bindNames;

  final int cursorId;
  final int options;

  @override
  void encode(WriteBuffer buffer) {
    // Function code
    buffer.writeUint8(messageType);

    // Cursor ID (4 bytes, big-endian)
    buffer.writeUint32BE(cursorId);

    // Execution options (1 byte)
    buffer.writeUint8(options);

    // SQL statement (length-prefixed UTF-8)
    final sqlBytes = utf8.encode(sql);
    buffer.writeUint32BE(sqlBytes.length);
    buffer.writeBytes(Uint8List.fromList(sqlBytes));

    // Bind parameter count
    final bindCount = bindValues?.length ?? 0;
    buffer.writeUint16BE(bindCount);

    // Encode each bind value
    if (bindValues != null) {
      for (final value in bindValues!) {
        _encodeBindValue(buffer, value);
      }
    }
  }

  void _encodeBindValue(WriteBuffer buffer, dynamic value) {
    if (value == null) {
      // NULL indicator
      buffer.writeUint8(0xFF);
      return;
    }

    // Non-null indicator
    buffer.writeUint8(0x00);

    if (value is String) {
      buffer.writeUint8(oraTypeVarchar2);
      final bytes = utf8.encode(value);
      buffer.writeUint16BE(bytes.length);
      buffer.writeBytes(Uint8List.fromList(bytes));
    } else if (value is int) {
      buffer.writeUint8(oraTypeNumber);
      _encodeOracleNumber(buffer, value);
    } else if (value is double) {
      buffer.writeUint8(oraTypeNumber);
      _encodeOracleNumber(buffer, value);
    } else if (value is DateTime) {
      buffer.writeUint8(oraTypeDate);
      _encodeOracleDate(buffer, value);
    } else if (value is Uint8List) {
      buffer.writeUint8(oraTypeRaw);
      buffer.writeUint16BE(value.length);
      buffer.writeBytes(value);
    } else {
      throw OracleException(
        errorCode: oraBindTypeError,
        message: 'Unsupported bind value type: ${value.runtimeType}. '
            'Supported types: String, int, double, DateTime, Uint8List, null',
      );
    }
  }

  void _encodeOracleNumber(WriteBuffer buffer, num value) {
    if (value == 0) {
      buffer.writeUint8(1); // Length
      buffer.writeUint8(0x80); // Zero exponent
      return;
    }

    // For integers, use base-100 encoding
    if (value is int && value > 0) {
      final digits = <int>[];
      var remaining = value;
      while (remaining > 0) {
        digits.insert(0, (remaining % 100) + 1);
        remaining ~/= 100;
      }

      final exponent = 0xC0 + digits.length;
      buffer.writeUint8(digits.length + 1); // Length
      buffer.writeUint8(exponent);
      for (final digit in digits) {
        buffer.writeUint8(digit);
      }
      return;
    }

    // For negative integers and decimals - basic support
    // Full implementation in Story 2.6
    throw OracleException(
      errorCode: oraDataTypeNotSupported,
      message: 'Complex NUMBER encoding (negative/decimal) not yet supported. '
          'See Story 2.6 for full data type mapping.',
    );
  }

  void _encodeOracleDate(WriteBuffer buffer, DateTime value) {
    // Oracle DATE: 7 bytes
    // Byte 0-1: Century and year (offset by 100)
    // Byte 2: Month
    // Byte 3: Day
    // Byte 4: Hour + 1
    // Byte 5: Minute + 1
    // Byte 6: Second + 1
    buffer.writeUint8(7); // Length
    buffer.writeUint8((value.year ~/ 100) + 100);
    buffer.writeUint8((value.year % 100) + 100);
    buffer.writeUint8(value.month);
    buffer.writeUint8(value.day);
    buffer.writeUint8(value.hour + 1);
    buffer.writeUint8(value.minute + 1);
    buffer.writeUint8(value.second + 1);
  }
}
```

### Connection.execute() with Bind Parameters

```dart
// Modified lib/src/connection.dart

/// Executes a SQL statement with optional bind parameters.
///
/// For queries with named bind parameters (`:name`), pass a Map:
/// ```dart
/// final result = await connection.execute(
///   'SELECT * FROM emp WHERE dept_id = :dept AND salary > :sal',
///   {'dept': 10, 'sal': 50000},
/// );
/// ```
///
/// For queries with positional bind parameters (`:1`, `:2`), pass a List:
/// ```dart
/// final result = await connection.execute(
///   'SELECT * FROM emp WHERE dept_id = :1 AND salary > :2',
///   [10, 50000],
/// );
/// ```
///
/// Throws [OracleException] if:
/// - Bind value count doesn't match placeholder count (ORA-01008)
/// - Unsupported bind value type
/// - Query execution fails
Future<OracleResult> execute(String sql, [Object? bindValues]) async {
  _ensureOpen();

  _log.fine(
      'Executing: ${sql.length > 100 ? '${sql.substring(0, 100)}...' : sql}');

  // Validate and prepare bind values
  List<dynamic>? bindList;
  List<String>? bindNames;

  if (bindValues != null) {
    if (bindValues is Map<String, dynamic>) {
      // Named binds
      bindNames = BindParser.parseNamedBinds(sql);
      if (bindNames.length != bindValues.length) {
        throw OracleException(
          errorCode: oraBindMismatch,
          message: 'Bind parameter count mismatch: SQL has ${bindNames.length} '
              'placeholders but ${bindValues.length} values provided',
        );
      }
      // Order values by their appearance in SQL
      bindList = bindNames.map((name) {
        if (!bindValues.containsKey(name)) {
          throw OracleException(
            errorCode: oraBindMismatch,
            message: 'Missing bind value for parameter ":$name"',
          );
        }
        return bindValues[name];
      }).toList();
    } else if (bindValues is List) {
      // Positional binds
      final placeholderCount = BindParser.parsePositionalBinds(sql);
      if (placeholderCount != bindValues.length) {
        throw OracleException(
          errorCode: oraBindMismatch,
          message: 'Bind parameter count mismatch: SQL has $placeholderCount '
              'placeholders but ${bindValues.length} values provided',
        );
      }
      bindList = bindValues;
    } else {
      throw OracleException(
        errorCode: oraBindTypeError,
        message: 'Bind values must be Map<String, dynamic> for named binds '
            'or List for positional binds. Got: ${bindValues.runtimeType}',
      );
    }
  }

  try {
    final response = await _transport.sendExecute(
      sql,
      bindValues: bindList,
      bindNames: bindNames,
    );

    if (!response.isSuccess) {
      throw OracleException(
        errorCode: response.errorCode ?? oraProtocolError,
        message: response.errorMessage ?? 'Query execution failed',
      );
    }

    return OracleResult(
      columnMetadata: response.columnMetadata ?? [],
      rowData: response.rows ?? [],
      rowsAffected: response.rowsAffected,
    );
  } catch (e) {
    if (e is OracleException) rethrow;
    throw OracleException(
      errorCode: oraProtocolError,
      message: 'Query execution failed',
      cause: e,
    );
  }
}
```

### Project Structure Notes

**Target Files (create/modify):**
- `lib/src/protocol/bind_parser.dart` - NEW: BindParser utility class
- `lib/src/protocol/messages/execute_message.dart` - MODIFY: Add bind parameter encoding
- `lib/src/connection.dart` - MODIFY: Add bind parameter support to execute()
- `lib/src/transport/transport.dart` - MODIFY: Pass bind values through sendExecute()
- `lib/src/protocol/constants.dart` - MODIFY: Add oraBindMismatch, oraBindTypeError
- `test/src/protocol/bind_parser_test.dart` - NEW
- `test/src/protocol/messages/execute_message_test.dart` - MODIFY: Add bind tests
- `test/integration/bind_parameters_test.dart` - NEW

**Existing Files (REUSE - understand their patterns):**
- `lib/src/protocol/buffer.dart` - Buffer reading/writing (use explicit endianness!)
- `lib/src/protocol/constants.dart` - Type constants for bind encoding
- `lib/src/errors.dart` - OracleException and error codes

### Architecture Compliance (MANDATORY)

**Source:** [docs/architecture.md](../architecture.md)

**Layer Boundaries:**
- BindParser in protocol layer (`lib/src/protocol/`)
- Bind encoding in ExecuteRequest (`lib/src/protocol/messages/`)
- Public API unchanged except execute() signature (`lib/src/connection.dart`)

**Buffer Operations (CRITICAL - use explicit endianness):**
```dart
// CORRECT
buffer.writeUint16BE(length);   // Big-endian for TNS/TTC
buffer.readUint32BE();          // Explicit endianness

// WRONG - never use ambiguous methods
buffer.writeUint16(length);     // Which endian?
```

**Error Handling Patterns (CRITICAL):**
```dart
// Wrap errors with cause for debugging
try {
  // operation
} catch (e) {
  if (e is OracleException) rethrow;  // Don't double-wrap
  throw OracleException(
    errorCode: oraProtocolError,
    message: 'Operation failed',
    cause: e,  // PRESERVE original error
  );
}
```

### Error Codes for Bind Parameters

| Scenario | Error Code | Constant |
|----------|------------|----------|
| Bind count mismatch | ORA-01008 | `oraBindMismatch` (add: 1008) |
| Unsupported bind type | ORA-06502 | `oraBindTypeError` (add: 6502) |
| Mixed named/positional | ORA-01008 | `oraBindMismatch` |
| Missing named bind value | ORA-01008 | `oraBindMismatch` |

### Previous Story Intelligence

**From Story 2-1 (Execute Message & Basic Query):**
- ExecuteRequest at `lib/src/protocol/messages/execute_message.dart:23`
- `_encodeOracleNumber` pattern exists in ExecuteResponse._parseOracleNumber - reverse for encoding
- Transport.sendExecute() at `lib/src/transport/transport.dart`
- execute() at `lib/src/connection.dart:91`

**From Story 1.5 (Error Handling):**
- OracleException pattern with errorCode, message, cause
- Error codes defined in `lib/src/errors.dart`

### Git Intelligence

**Recent commits:**
```
513fcb8 feat: Implement execute message and basic query execution (Story 2.1)
772b42c feat: Update sprint status for Epic 2 and mark Story 2.1 as ready-for-dev
```

**Patterns established:**
- All files pass `dart analyze` with zero warnings
- TDD approach: write failing test, implement, pass
- Message classes have encode() method
- Public APIs documented with dartdoc

### Anti-Patterns to Avoid

| # | Anti-Pattern | Correct Pattern |
|---|--------------|-----------------|
| 1 | Parse binds without handling string literals | Use regex to exclude `'string literals'` |
| 2 | Allow mixed named/positional binds | Detect and throw clear error |
| 3 | Ambiguous buffer methods | Always use `BE`/`LE` suffix |
| 4 | Swallowing type errors | Throw OracleException with specific code |
| 5 | Not validating bind count | Always compare placeholder count vs values |
| 6 | Logging bind values (may contain secrets) | Only log SQL, not bind values |

### Edge Cases to Handle

1. **Empty bind values**: `execute('SELECT 1 FROM dual', [])` - should work (0 binds)
2. **NULL in bind list**: `execute('SELECT :1 FROM dual', [null])` - encode as NULL
3. **Same named bind twice**: `SELECT :a + :a FROM dual` - use same value twice
4. **Bind in string literal**: `SELECT ':not_a_bind' FROM dual` - don't match
5. **Unicode in bind value**: Strings should be UTF-8 encoded properly
6. **Large integers**: May overflow Oracle NUMBER encoding - test limits
7. **DateTime edge cases**: Min/max DateTime values

### Oracle NUMBER Encoding Reference

Oracle NUMBER uses base-100 encoding:
- Byte 0: Exponent (offset by 0xC1 for positive)
- Bytes 1-N: Base-100 digits + 1

Examples:
- 0 → `[0x80]` (single byte)
- 1 → `[0xC1, 0x02]` (exponent=1, digit=1+1)
- 100 → `[0xC1, 0x02]` (same as 1 due to base-100)
- 123 → `[0xC2, 0x02, 0x18]` (exponent=2, digits=[1+1, 23+1])

### References

**Project Documents:**
- [Architecture: Layer Boundaries](../architecture.md#architectural-boundaries)
- [Architecture: Buffer Patterns](../architecture.md#buffer-byte-order-handling)
- [PRD: FR17, FR18](../prd.md) - Bind parameters
- [Epic 2: Story 2.3 Requirements](../epics.md#story-23-bind-parameters)

**Source Files:**
- `lib/src/protocol/messages/execute_message.dart` - Current execute message
- `lib/src/connection.dart` - Current execute() method
- `lib/src/protocol/buffer.dart` - Buffer utilities
- `lib/src/protocol/constants.dart` - Type constants

**External References:**
- node-oracledb thin driver: `lib/thin/protocol/messages/withInfo.js`
- Oracle NUMBER format: [Oracle docs](https://docs.oracle.com/en/database/oracle/oracle-database/23/sqlrf/Data-Types.html)

## Dev Agent Record

### Context Reference

Story created by SM agent using ultimate context engine analysis.
Comprehensive analysis of Epic 2 requirements, existing Story 2-1 implementation, and architecture patterns.

### Agent Model Used

Claude Opus 4.5 (claude-opus-4-5-20251101)

### Debug Log References

N/A

### Completion Notes List

- **2025-12-15 Implementation Complete**: All 10 tasks implemented following red-green-refactor TDD cycle
- **Unit Tests**: 51 tests passing (18 BindParser tests + 33 ExecuteRequest tests total, 16 bind-specific)
- **Integration Tests**: 13 bind parameter tests in query_integration_test.dart
- **dart analyze**: Zero warnings/errors
- **Key Implementation Decisions**:
  - BindParser kept internal (not exported) - implementation detail
  - Bind error codes exported (oraBindMismatch=1008, oraBindTypeError=6502) for user error handling
  - Integration tests added to existing query_integration_test.dart rather than separate file
  - Complex NUMBER encoding (negative/decimal) deferred to Story 2.6 as noted in Dev Notes

### Change Log

- 2025-12-15: Story created by create-story workflow with comprehensive context analysis
- 2025-12-15: Implementation completed by Dev Agent (Amelia) - all tasks done, tests passing
- 2025-12-15: Code Review (Amelia) - Fixed duplicate named bind validation bug in connection.dart:126, added edge case test, corrected File List documentation

### File List

**Files Created:**
- `lib/src/protocol/bind_parser.dart` - BindParser utility class
- `test/src/protocol/bind_parser_test.dart` - Bind parser unit tests (18 tests)

**Files Modified:**
- `lib/src/protocol/messages/execute_message.dart` - Add bind parameter encoding
- `lib/src/connection.dart` - Add bind parameter support to execute()
- `lib/src/transport/transport.dart` - Pass bind values through sendExecute()
- `lib/src/errors.dart` - Add bind error code constants (oraBindMismatch, oraBindTypeError)
- `lib/dart_oracledb.dart` - Export bind error codes
- `test/src/protocol/messages/execute_message_test.dart` - Add bind encoding tests (16 bind-specific)
- `test/integration/query_integration_test.dart` - Add bind parameter integration tests (13 tests)
- `docs/sprint-artifacts/sprint-status.yaml` - Update story status
