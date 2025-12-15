# Story 2.1: Execute Message & Basic Query

Status: ready-for-dev

## Story

As a **developer using dart-oracledb**,
I want **to execute a simple SELECT query**,
So that **I can retrieve data from Oracle tables**.

## Acceptance Criteria

1. **AC1:** Given an authenticated connection, when calling `connection.execute('SELECT * FROM dual')`, then the TTC EXECUTE message is sent to Oracle, the response is received and parsed, and an `OracleResult` object is returned
2. **AC2:** Given a SELECT query with no bind parameters, when executed against a table with data, then rows are returned in the result

## Tasks / Subtasks

- [ ] **Task 1: Create ExecuteMessage Class** (AC: 1)
  - [ ] 1.1: Create `lib/src/protocol/messages/execute_message.dart`
  - [ ] 1.2: Implement `ExecuteRequest` extending Message with ttcExecute (0x03)
  - [ ] 1.3: Encode SQL text with proper TTC format (length-prefixed UTF-8)
  - [ ] 1.4: Add cursor ID handling (0 for new cursor)
  - [ ] 1.5: Add execution flags field

- [ ] **Task 2: Implement ExecuteResponse Parsing** (AC: 1)
  - [ ] 2.1: Create `ExecuteResponse` class for decoding server response
  - [ ] 2.2: Parse response status byte (0 = success)
  - [ ] 2.3: Parse column metadata (count, names, types)
  - [ ] 2.4: Parse row data when present
  - [ ] 2.5: Handle error responses with ORA codes

- [ ] **Task 3: Create OracleResult and OracleRow Classes** (AC: 1, 2)
  - [ ] 3.1: Create `lib/src/result.dart`
  - [ ] 3.2: Implement `OracleResult` with `rows` getter, `rowCount`, column metadata
  - [ ] 3.3: Implement `OracleRow` with `operator []` for name and index access
  - [ ] 3.4: Store column metadata for name-to-index mapping
  - [ ] 3.5: Handle null values properly

- [ ] **Task 4: Add execute() Method to OracleConnection** (AC: 1, 2)
  - [ ] 4.1: Add `Future<OracleResult> execute(String sql)` method
  - [ ] 4.2: Call `_ensureOpen()` at start (use existing guard method)
  - [ ] 4.3: Create ExecuteRequest message with SQL
  - [ ] 4.4: Send via transport, receive response
  - [ ] 4.5: Parse response into OracleResult
  - [ ] 4.6: Handle error responses by throwing OracleException

- [ ] **Task 5: Add Transport Support for Execute** (AC: 1)
  - [ ] 5.1: Add `sendExecute()` method to Transport class
  - [ ] 5.2: Wrap ExecuteMessage in TnsPacket (type=DATA)
  - [ ] 5.3: Handle multi-packet responses if needed

- [ ] **Task 6: Update Public Exports** (AC: 1, 2)
  - [ ] 6.1: Export OracleResult and OracleRow from `lib/dart_oracledb.dart`
  - [ ] 6.2: Export ColumnMetadata (used by OracleResult.columns getter)
  - [ ] 6.3: Keep ExecuteMessage/ExecuteResponse internal (not exported)

- [ ] **Task 7: Write Unit Tests** (AC: all)
  - [ ] 7.1: Create `test/src/protocol/messages/execute_message_test.dart`
  - [ ] 7.2: Test ExecuteRequest encodes SQL correctly
  - [ ] 7.3: Test ExecuteResponse decodes success response
  - [ ] 7.4: Test ExecuteResponse decodes error response
  - [ ] 7.5: Create `test/src/result_test.dart`
  - [ ] 7.6: Test OracleRow access by name
  - [ ] 7.7: Test OracleRow access by index
  - [ ] 7.8: Test null value handling

- [ ] **Task 8: Write Integration Tests** (AC: 1, 2)
  - [ ] 8.1: Create/update `test/integration/query_integration_test.dart`
  - [ ] 8.2: Test `SELECT * FROM dual` returns result
  - [ ] 8.3: Test `SELECT 'hello' as greeting FROM dual` returns string
  - [ ] 8.4: Test `SELECT 123 as num FROM dual` returns number
  - [ ] 8.5: Test execute on closed connection throws

- [ ] **Task 9: Finalize and Validate** (AC: all)
  - [ ] 9.1: Run `dart analyze` with zero warnings
  - [ ] 9.2: Run `dart format --set-exit-if-changed .`
  - [ ] 9.3: Run `dart test` - all tests pass
  - [ ] 9.4: Run integration tests with `RUN_INTEGRATION_TESTS=true dart test`

## Dev Notes

### Wire Protocol Validation (CRITICAL)

**WARNING:** The execute message format below is based on protocol analysis but MUST be validated:
1. TNS handshake issue from Epic 1 blocks end-to-end integration testing
2. Before implementing, reference `node-oracledb/lib/thin/protocol/messages/withInfo.js` for actual TTC message structure
3. Use Wireshark/tcpdump to capture real Oracle traffic if format issues arise
4. Execute may require multi-phase handling (PREPARE→DESCRIBE→EXECUTE→FETCH) for complex queries - Story 2.1 targets simple SELECT FROM DUAL which may use simplified flow

### TTC Execute Message Format

The TTC Execute message follows the Oracle wire protocol format used by the thin driver:

```dart
// lib/src/protocol/messages/execute_message.dart

import 'dart:convert';
import 'dart:typed_data';

import '../buffer.dart';
import '../constants.dart';
import 'base.dart';

/// TTC EXECUTE request message (function code 0x03).
///
/// Sends a SQL statement to the database for execution.
///
/// **Sequence Numbers:** Unlike auth messages, execute messages typically
/// don't require explicit sequence management for simple queries. The
/// sequence parameter is inherited from Message base class but can be
/// omitted for single-statement executes. Multi-phase operations (cursor
/// fetch loops) may need sequence tracking in Story 2.2.
class ExecuteRequest extends Message {
  /// Creates an EXECUTE request for the given SQL statement.
  ExecuteRequest({
    required this.sql,
    this.cursorId = 0,
    this.options = 0,
    super.sequence,
  }) : super(messageType: ttcExecute);

  /// The SQL statement to execute.
  final String sql;

  /// Cursor ID (0 for new cursor).
  final int cursorId;

  /// Execution options flags.
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
  }
}
```

### Execute Response Format

```dart
/// TTC EXECUTE response from server.
class ExecuteResponse {
  const ExecuteResponse({
    required this.isSuccess,
    this.cursorId,
    this.columnMetadata,
    this.rows,
    this.rowsAffected,
    this.errorCode,
    this.errorMessage,
  });

  final bool isSuccess;
  final int? cursorId;
  final List<ColumnMetadata>? columnMetadata;
  final List<List<dynamic>>? rows;
  final int? rowsAffected;
  final int? errorCode;
  final String? errorMessage;

  static ExecuteResponse decode(Uint8List data) {
    try {
      final buffer = ReadBuffer(data);

      // Status byte (0 = success)
      final status = buffer.readUint8();

    if (status != 0) {
      // Error response
      final errorCode = buffer.readUint16BE();
      final msgLen = buffer.readUint8();
      final errorMessage = msgLen > 0 ? buffer.readString(msgLen) : null;

      return ExecuteResponse(
        isSuccess: false,
        errorCode: errorCode,
        errorMessage: errorMessage,
      );
    }

    // Success - parse result metadata
    final cursorId = buffer.readUint32BE();
    final columnCount = buffer.readUint16BE();

    // Parse column metadata
    final columns = <ColumnMetadata>[];
    for (var i = 0; i < columnCount; i++) {
      columns.add(ColumnMetadata.decode(buffer));
    }

    // Parse rows if present
    final rowCount = buffer.readUint32BE();
    final rows = <List<dynamic>>[];
    for (var i = 0; i < rowCount; i++) {
      rows.add(_decodeRow(buffer, columns));
    }

    return ExecuteResponse(
      isSuccess: true,
      cursorId: cursorId,
      columnMetadata: columns,
      rows: rows,
    );
    } catch (e) {
      if (e is OracleException) rethrow;
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'Failed to decode execute response',
        cause: e,
      );
    }
  }

  static List<dynamic> _decodeRow(ReadBuffer buffer, List<ColumnMetadata> columns) {
    final values = <dynamic>[];
    for (final col in columns) {
      values.add(_decodeValue(buffer, col.oracleType));
    }
    return values;
  }

  static dynamic _decodeValue(ReadBuffer buffer, int oracleType) {
    // Check for NULL indicator
    final isNull = buffer.readUint8();
    if (isNull == 0xFF) return null;

    // Decode based on type (basic types for Story 2.1)
    switch (oracleType) {
      case oraTypeVarchar:
      case oraTypeVarchar2:
      case oraTypeString:
        final len = buffer.readUint16BE();
        return buffer.readString(len);

      case oraTypeNumber:
      case oraTypeInteger:
        // Oracle NUMBER encoding - simplified for MVP
        return _decodeNumber(buffer);

      default:
        // Skip unknown types
        final len = buffer.readUint16BE();
        buffer.skip(len);
        return null;
    }
  }

  static num _decodeNumber(ReadBuffer buffer) {
    // Oracle NUMBER is variable-length
    final len = buffer.readUint8();
    if (len == 0) return 0;

    final numBytes = buffer.readBytes(len);
    // Simplified NUMBER decoding - full implementation in Story 2.6
    // For now, handle simple integer cases
    return _parseOracleNumber(numBytes);
  }

  static num _parseOracleNumber(Uint8List bytes) {
    // Oracle NUMBER format: [length] [exponent] [mantissa bytes...]
    // Full decimal support deferred to Story 2.6
    if (bytes.isEmpty) return 0;

    // Basic integer parsing for Story 2.1 MVP
    // Oracle NUMBER uses base-100 encoding with offset exponent
    final exponent = bytes[0];
    if (exponent == 0x80) return 0; // Special case: zero

    // Positive integers: exponent >= 0xC1
    if (exponent >= 0xC1 && bytes.length >= 2) {
      final digits = exponent - 0xC1 + 1;
      int result = 0;
      for (var i = 1; i < bytes.length && i <= digits; i++) {
        result = result * 100 + (bytes[i] - 1);
      }
      return result;
    }

    // Negative or decimal numbers - defer to Story 2.6
    throw UnimplementedError(
      'Complex Oracle NUMBER format not yet supported. '
      'See Story 2.6 for full data type mapping.',
    );
  }
}

/// Column metadata from query result.
class ColumnMetadata {
  const ColumnMetadata({
    required this.name,
    required this.oracleType,
    required this.maxLength,
    this.precision,
    this.scale,
  });

  final String name;
  final int oracleType;
  final int maxLength;
  final int? precision;
  final int? scale;

  static ColumnMetadata decode(ReadBuffer buffer) {
    final nameLen = buffer.readUint8();
    final name = buffer.readString(nameLen);
    final oracleType = buffer.readUint16BE();
    final maxLength = buffer.readUint16BE();
    final precision = buffer.readUint8();
    final scale = buffer.readUint8();

    return ColumnMetadata(
      name: name,
      oracleType: oracleType,
      maxLength: maxLength,
      precision: precision > 0 ? precision : null,
      scale: scale > 0 ? scale : null,
    );
  }
}
```

### OracleResult and OracleRow Implementation

```dart
// lib/src/result.dart

/// The result of executing a SQL query.
///
/// For SELECT queries, access rows via the [rows] property.
/// For DML queries (INSERT, UPDATE, DELETE), check [rowsAffected].
class OracleResult {
  /// Creates a result from the given data.
  OracleResult({
    required List<ColumnMetadata> columnMetadata,
    required List<List<dynamic>> rowData,
    this.rowsAffected,
  }) : _columnMetadata = columnMetadata,
       _nameToIndex = _buildNameMap(columnMetadata),
       _rows = rowData.map((data) => OracleRow._(
         data: data,
         columnMetadata: columnMetadata,
         nameToIndex: _buildNameMap(columnMetadata),
       )).toList();

  final List<ColumnMetadata> _columnMetadata;
  final Map<String, int> _nameToIndex;
  final List<OracleRow> _rows;

  /// Number of rows affected by DML operations.
  final int? rowsAffected;

  /// The rows returned by a SELECT query.
  List<OracleRow> get rows => _rows;

  /// Number of rows in the result.
  int get rowCount => _rows.length;

  /// Column metadata for the result set.
  List<ColumnMetadata> get columns => _columnMetadata;

  /// Column names in result order.
  List<String> get columnNames => _columnMetadata.map((c) => c.name).toList();

  static Map<String, int> _buildNameMap(List<ColumnMetadata> columns) {
    final map = <String, int>{};
    for (var i = 0; i < columns.length; i++) {
      // Oracle column names are case-insensitive, stored uppercase
      map[columns[i].name.toUpperCase()] = i;
    }
    return map;
  }
}

/// A single row from a query result.
///
/// Access column values by name or index:
/// ```dart
/// final name = row['NAME'];      // By column name
/// final name = row[0];           // By column index
/// ```
class OracleRow {
  const OracleRow._({
    required List<dynamic> data,
    required List<ColumnMetadata> columnMetadata,
    required Map<String, int> nameToIndex,
  }) : _data = data,
       _columnMetadata = columnMetadata,
       _nameToIndex = nameToIndex;

  final List<dynamic> _data;
  final List<ColumnMetadata> _columnMetadata;
  final Map<String, int> _nameToIndex;

  /// Gets a column value by name (case-insensitive) or index.
  ///
  /// Returns `null` if the column doesn't exist or the value is NULL.
  dynamic operator [](Object key) {
    if (key is int) {
      if (key < 0 || key >= _data.length) return null;
      return _data[key];
    }
    if (key is String) {
      final index = _nameToIndex[key.toUpperCase()];
      if (index == null) return null;
      return _data[index];
    }
    return null;
  }

  /// Number of columns in this row.
  int get length => _data.length;

  /// Column names in result order.
  List<String> get columnNames => _columnMetadata.map((c) => c.name).toList();

  /// All values as a list.
  List<dynamic> toList() => List.unmodifiable(_data);

  /// All values as a map (column name -> value).
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{};
    for (var i = 0; i < _columnMetadata.length; i++) {
      map[_columnMetadata[i].name] = _data[i];
    }
    return map;
  }
}
```

### Connection.execute() Implementation

```dart
// Add to lib/src/connection.dart

/// Executes a SQL statement and returns the result.
///
/// For SELECT queries, the result contains rows that can be iterated:
/// ```dart
/// final result = await connection.execute('SELECT * FROM employees');
/// for (final row in result.rows) {
///   print('${row['NAME']}: ${row['SALARY']}');
/// }
/// ```
///
/// For DML queries (INSERT, UPDATE, DELETE), check [OracleResult.rowsAffected]:
/// ```dart
/// final result = await connection.execute(
///   "UPDATE employees SET salary = 50000 WHERE id = 1"
/// );
/// print('Updated ${result.rowsAffected} rows');
/// ```
///
/// Throws [OracleException] if execution fails.
Future<OracleResult> execute(String sql) async {
  _ensureOpen();  // This was already added in Story 1.7

  _log.fine('Executing: ${sql.length > 100 ? '${sql.substring(0, 100)}...' : sql}');

  try {
    final response = await _transport.sendExecute(sql);

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

### Transport.sendExecute() Implementation

```dart
// Add to lib/src/transport/transport.dart

/// Sends a SQL statement for execution and returns the response.
Future<ExecuteResponse> sendExecute(String sql) async {
  _log.fine('Sending execute request...');

  final request = ExecuteRequest(sql: sql);
  final requestData = request.toBytes();

  final packet = TnsPacket(type: tnsPacketData, payload: requestData);
  await send(packet);

  // Receive response
  final response = await receive();

  if (response.type != tnsPacketData) {
    throw OracleException(
      errorCode: oraProtocolError,
      message: 'Unexpected response type: ${response.type}',
    );
  }

  return ExecuteResponse.decode(response.payload);
}
```

### Project Structure Notes

**Target Files (create/modify):**
- `lib/src/protocol/messages/execute_message.dart` - NEW: ExecuteRequest, ExecuteResponse, ColumnMetadata
- `lib/src/result.dart` - NEW: OracleResult, OracleRow classes
- `lib/src/connection.dart` - MODIFY: Add execute() method
- `lib/src/transport/transport.dart` - MODIFY: Add sendExecute() method
- `lib/dart_oracledb.dart` - MODIFY: Export OracleResult, OracleRow
- `test/src/protocol/messages/execute_message_test.dart` - NEW
- `test/src/result_test.dart` - NEW
- `test/integration/query_integration_test.dart` - NEW

**Existing Files (REUSE - understand their patterns):**
- `lib/src/protocol/messages/base.dart` - Message base class (extend this)
- `lib/src/protocol/messages/auth_message.dart` - Reference for encode/decode patterns
- `lib/src/protocol/buffer.dart` - Buffer reading/writing (use explicit endianness!)
- `lib/src/protocol/constants.dart` - ttcExecute (0x03) and type constants
- `lib/src/errors.dart` - OracleException and error codes
- `lib/src/transport/packet.dart` - tnsPacketData constant

### Architecture Compliance (MANDATORY)

**Source:** [docs/architecture.md](../architecture.md)

**Layer Boundaries:**
- ExecuteMessage in protocol layer (`lib/src/protocol/messages/`)
- sendExecute() in transport layer (`lib/src/transport/`)
- execute() exposed in public API (`lib/src/connection.dart`)
- OracleResult/OracleRow in application layer (`lib/src/result.dart`)

**Data Flow:**
```
User Code
    │
    ▼
OracleConnection.execute(sql)
    │ _ensureOpen() guard
    ▼
Transport.sendExecute()
    │
    ▼
ExecuteRequest.encode() → WriteBuffer → Uint8List
    │
    ▼
TnsPacket(type=DATA, payload=executeBytes)
    │
    ▼
Socket.send(bytes)
    │
    ▼
[Oracle Database]
    │
    ▼
Socket.read(bytes)
    │
    ▼
TnsPacket.decode() → payload
    │
    ▼
ExecuteResponse.decode(payload) → ReadBuffer parsing
    │
    ▼
OracleResult with OracleRow[]
    │
    ▼
User Code
```

**Buffer Operations (CRITICAL - use explicit endianness):**
```dart
// CORRECT
buffer.writeUint32BE(length);   // Big-endian for TNS/TTC
buffer.readUint16BE();          // Explicit endianness

// WRONG - never use ambiguous methods
buffer.writeUint32(length);     // Which endian?
```

### Error Handling Patterns (CRITICAL)

**Query Execution Error Codes:**

| Scenario | Error Code | Constant/Source |
|----------|------------|-----------------|
| Invalid SQL syntax | ORA-00900 to ORA-00999 | Oracle parser errors |
| Table/view not found | ORA-00942 | Oracle catalog error |
| Invalid column name | ORA-00904 | Oracle catalog error |
| Invalid identifier | ORA-00911 | Oracle parser error |
| Connection closed | 3113 | `oraConnectionClosed` |
| Protocol error | 12547 | `oraProtocolError` |
| Decode failure | 12547 | `oraProtocolError` (wrap BufferException) |

**Note:** Oracle error codes are returned directly from the server in ExecuteResponse.
The driver wraps decode/transport errors with `oraProtocolError` preserving the cause chain.

**Error Wrapping Pattern (from Epic 1):**
```dart
try {
  // Execute operation
} catch (e) {
  if (e is OracleException) rethrow;  // Don't double-wrap
  throw OracleException(
    errorCode: oraProtocolError,
    message: 'Operation failed',
    cause: e,  // PRESERVE original error
  );
}
```

### Testing Requirements

**Unit Tests Required:**
1. ExecuteRequest encodes SQL correctly (in `execute_message_test.dart`)
2. ExecuteResponse decodes success response (in `execute_message_test.dart`)
3. ExecuteResponse decodes error response with ORA code (in `execute_message_test.dart`)
4. ColumnMetadata.decode parses column info (in `execute_message_test.dart`)
5. OracleRow access by column name (case-insensitive) (in `result_test.dart`)
6. OracleRow access by column index (in `result_test.dart`)
7. OracleRow null value handling (in `result_test.dart`)
8. OracleResult column metadata access (in `result_test.dart`)

**Test Organization:** Protocol-level tests (ExecuteRequest, ExecuteResponse, ColumnMetadata)
go in `execute_message_test.dart`. Public API tests (OracleResult, OracleRow) go in `result_test.dart`.

**Unit Test Pattern:**
```dart
// test/src/protocol/messages/execute_message_test.dart
import 'package:test/test.dart';
import 'package:dart_oracledb/src/protocol/messages/execute_message.dart';
import 'package:dart_oracledb/src/protocol/constants.dart';

void main() {
  group('ExecuteRequest', () {
    test('encodes with correct function code', () {
      final request = ExecuteRequest(sql: 'SELECT * FROM dual');
      final bytes = request.toBytes();
      expect(bytes[0], equals(ttcExecute)); // 0x03
    });

    test('encodes SQL as UTF-8 with length prefix', () {
      final request = ExecuteRequest(sql: 'SELECT 1');
      final bytes = request.toBytes();
      // Verify length prefix and SQL bytes
      // ...
    });
  });
}
```

**Integration Test Notes:**
- Story 2.1 tests use only `SELECT ... FROM DUAL` - no table setup required
- DUAL is Oracle's built-in single-row table, always available
- No test data fixtures needed for this story

**Integration Test Pattern:**
```dart
// test/integration/query_integration_test.dart
@Tags(['integration'])
import 'dart:io';
import 'package:test/test.dart';
import 'package:dart_oracledb/dart_oracledb.dart';

void main() {
  final hasOracle = Platform.environment.containsKey('RUN_INTEGRATION_TESTS');

  group('Query execution', skip: !hasOracle, () {
    late OracleConnection connection;

    setUp(() async {
      connection = await OracleConnection.connect(
        'localhost:1521/FREEPDB1',
        user: 'system',
        password: 'testpassword',
      );
    });

    tearDown(() async {
      await connection.close();
    });

    test('SELECT FROM dual returns result', () async {
      final result = await connection.execute('SELECT * FROM dual');
      expect(result.rows, isNotEmpty);
      expect(result.rowCount, equals(1));
    });

    test('SELECT string returns correct value', () async {
      final result = await connection.execute(
        "SELECT 'hello' as greeting FROM dual"
      );
      expect(result.rows[0]['GREETING'], equals('hello'));
    });

    test('SELECT number returns correct value', () async {
      final result = await connection.execute(
        'SELECT 123 as num FROM dual'
      );
      expect(result.rows[0]['NUM'], equals(123));
    });

    test('execute on closed connection throws', () async {
      await connection.close();
      expect(
        () => connection.execute('SELECT 1 FROM dual'),
        throwsA(isA<OracleException>()
          .having((e) => e.errorCode, 'errorCode', oraConnectionClosed)),
      );
    });
  });
}
```

### Previous Story Intelligence

**From Story 1.7 (Connection Lifecycle Management):**
- `_ensureOpen()` method exists at `lib/src/connection.dart:~116` - CALL IT at start of execute()
- `_isClosed` flag tracks connection state
- Error wrapping pattern: check `if (e is OracleException) rethrow`
- Integration tests use `RUN_INTEGRATION_TESTS` environment variable
- See: `lib/src/protocol/messages/ping_message.dart` for simple message encode pattern

**From Story 1.5 (Connection API & Error Handling):**
- OracleException with errorCode, message, cause
- All files must pass `dart analyze` with zero warnings
- Logger pattern: `final _log = Logger('ClassName');`

**From Auth Message Implementation:**
- Message encoding pattern: function code byte first
- Length-prefixed strings: write length, then UTF-8 bytes
- Response decoding: check status byte first
- Use ReadBuffer/WriteBuffer with explicit BE/LE methods

### Git Intelligence

**Recent commits:**
```
b92475f feat: Implement connection lifecycle management with ping and close capabilities
582a9d8 feat: Implement TLS/SSL support for Oracle database connections
b17a3ee feat: Implement Oracle authentication protocol with SHA512 and PBKDF2 verifiers
```

**Patterns from previous stories:**
- All files pass `dart analyze` with zero warnings
- All files pass `dart format`
- Tests mirror lib/src/ structure exactly
- Logging uses `package:logging` with Logger per class
- Message classes have encode() method, response classes have static decode()

### Anti-Patterns to Avoid (Consolidated Checklist)

| # | Anti-Pattern | Correct Pattern |
|---|--------------|-----------------|
| 1 | Missing `_ensureOpen()` guard | First line of execute(): `_ensureOpen();` |
| 2 | Ambiguous buffer methods | Always use `BE`/`LE` suffix: `readUint16BE()` |
| 3 | Swallowing errors | Preserve cause: `throw OracleException(..., cause: e)` |
| 4 | Logging sensitive SQL | Truncate: `sql.length > 100 ? '${sql.substring(0, 100)}...' : sql` |
| 5 | Exposing internal types | Export only: OracleResult, OracleRow, ColumnMetadata |
| 6 | Mutable collections returned | Return `List.unmodifiable(_data)` |
| 7 | Raw exceptions thrown | Always wrap in OracleException with errorCode |
| 8 | BufferException leaking | Catch and wrap with `oraProtocolError` |

### Edge Cases to Handle

1. **Empty result set**: Return OracleResult with empty rows list
2. **NULL column values**: Return Dart `null` for Oracle NULL
3. **Column name case**: Oracle returns uppercase - make lookup case-insensitive
4. **Invalid column access**: Return `null` for non-existent column (not throw)
5. **Connection closed during execute**: Check and throw meaningful error
6. **Very long SQL**: Handle properly, don't truncate in transmission
7. **Unsupported data types**: Return `null` and skip bytes (intentional for Story 2.1 - full types in Story 2.6)
8. **Complex NUMBER values**: Throw `UnimplementedError` for decimals/negatives (deferred to Story 2.6)

### Oracle Wire Protocol Notes

The TTC EXECUTE message format may vary slightly based on Oracle version. Reference the node-oracledb thin driver implementation for exact byte-level format. Key considerations:

1. Cursor ID 0 means "create new cursor"
2. SQL text is UTF-8 encoded with 4-byte length prefix
3. Response includes column metadata before row data
4. Oracle NUMBER encoding is complex - simplified handling okay for Story 2.1, full support in Story 2.6

### References

**Project Documents (relative from docs/):**
- [Architecture: Layer Boundaries](../architecture.md#architectural-boundaries)
- [Architecture: Buffer Patterns](../architecture.md#buffer-byte-order-handling)
- [Architecture: Error Handling](../architecture.md#error-handling-patterns)
- [PRD: FR13, FR19-FR21](../prd.md) - Execute SELECT, result iteration
- [Epic 2: Story 2.1 Requirements](../epics.md#story-21-execute-message--basic-query)
- [Story 1.7: _ensureOpen()](./1-7-connection-lifecycle-management.md)
- [Epic 1 Retrospective](./epic-1-retrospective.md) - Lessons learned

**Source Files (relative from project root):**
- `lib/src/protocol/constants.dart` - ttcExecute (0x03), type constants
- `lib/src/protocol/messages/auth_message.dart` - Encode/decode reference pattern
- `lib/src/protocol/messages/ping_message.dart` - Simple message example
- `lib/src/protocol/buffer.dart` - ReadBuffer/WriteBuffer with BE/LE methods
- `lib/src/errors.dart` - OracleException, oraProtocolError

**External References:**
- node-oracledb thin driver: `lib/thin/protocol/messages/withInfo.js`
- Oracle Error Reference: [docs.oracle.com/error-help](https://docs.oracle.com/error-help/db/)

## Dev Agent Record

### Context Reference

Story created by SM agent using ultimate context engine analysis. YOLO mode enabled.
Comprehensive analysis of Epic 2 requirements, architecture patterns, and existing codebase.

### Agent Model Used

Claude Opus 4.5 (claude-opus-4-5-20251101)

### Debug Log References

N/A

### Completion Notes List

### Change Log

- 2025-12-15: Story drafted by SM agent (Bob) with comprehensive context analysis
- 2025-12-15: Story validated by SM agent (Bob) - 4 critical issues, 5 enhancements, 3 optimizations applied:
  - C1: Fixed Oracle NUMBER decoding placeholder with basic integer support
  - C2: Added wire protocol validation warning and node-oracledb reference
  - C3: Added try-catch wrapping in ExecuteResponse.decode() for BufferException
  - C4: Documented sequence number handling for execute messages
  - E1-E5: Added file references, export clarifications, test organization
  - O1-O3: Enhanced error codes, git history refs, integration test notes
  - L1-L3: Consolidated anti-patterns, standardized references

### File List

**Files to Create:**
- `lib/src/protocol/messages/execute_message.dart` - ExecuteRequest, ExecuteResponse, ColumnMetadata
- `lib/src/result.dart` - OracleResult, OracleRow classes
- `test/src/protocol/messages/execute_message_test.dart` - Execute message + ColumnMetadata unit tests
- `test/src/result_test.dart` - Result/Row unit tests
- `test/integration/query_integration_test.dart` - Query integration tests (DUAL only)

**Files to Modify:**
- `lib/src/connection.dart` - Add execute() method (uses _ensureOpen())
- `lib/src/transport/transport.dart` - Add sendExecute() method
- `lib/dart_oracledb.dart` - Export OracleResult, OracleRow, ColumnMetadata
- `docs/sprint-artifacts/sprint-status.yaml` - Update story status to in-progress/done
