# Story 1.3: TTC Protocol Foundation

Status: done

## Story

As a **developer using dart-oracledb**,
I want **TTC message encoding/decoding implemented**,
So that **the driver can communicate using Oracle's wire protocol**.

## Acceptance Criteria

1. **AC1:** Given the transport layer is connected, when TTC messages need to be sent, then messages are properly encoded with explicit endianness handling (`readUint16BE()`, `writeUint32LE()`, etc.)
2. **AC2:** Protocol capability negotiation is implemented for TTC handshake
3. **AC3:** Data type indicators are defined and handled for Oracle wire protocol
4. **AC4:** Received TTC messages are properly decoded
5. **AC5:** The buffer utility class handles all byte operations safely (completed in Story 1.2)
6. **AC6:** Given a malformed TTC response, when decoding is attempted, then a clear `OracleException` is raised with context (error code, message, cause preserved)

## Tasks / Subtasks

- [x] **Task 1: Implement TTC Constants** (AC: 2, 3)
  - [x] 1.1: Create `lib/src/protocol/constants.dart` with TTC message type constants
  - [x] 1.2: Define TTC function codes: PROTOCOL, DATA_TYPE, TRANSACT, TTI_FUN_PING, TTI_FUN_COMMIT, TTI_FUN_EXECUTE, TTI_FUN_FETCH, etc.
  - [x] 1.3: Define Oracle data type indicators: NUMBER, VARCHAR2, DATE, TIMESTAMP, CLOB, BLOB, RAW, JSON
  - [x] 1.4: Define protocol capability flags for negotiation
  - [x] 1.5: Mirror constants structure from node-oracledb `constants.js`

- [x] **Task 2: Implement TTC Packet Structure** (AC: 1, 4)
  - [x] 2.1: Create `lib/src/protocol/ttc_packet.dart` with `TtcPacket` class (distinct from TNS packet)
  - [x] 2.2: Implement TTC packet header structure (function code, sequence, etc.)
  - [x] 2.3: Implement `TtcPacket.encode()` for serialization using explicit endianness
  - [x] 2.4: Implement `TtcPacket.decode()` for deserialization with validation
  - [x] 2.5: Add data flags handling within TTC packet

- [x] **Task 3: Implement Protocol Capabilities Negotiation** (AC: 2)
  - [x] 3.1: Create `lib/src/protocol/capabilities.dart`
  - [x] 3.2: Implement `Capabilities` class with client-side capability flags
  - [x] 3.3: Implement capability encoding for sending to server
  - [x] 3.4: Implement capability decoding from server response
  - [x] 3.5: Define negotiated session properties (charset, protocol version, etc.)

- [x] **Task 4: Implement Base Message Class** (AC: 1, 4, 6)
  - [x] 4.1: Create `lib/src/protocol/messages/base.dart` with abstract `Message` class
  - [x] 4.2: Define `encode(WriteBuffer)` abstract method
  - [x] 4.3: Define static `decode(ReadBuffer)` factory pattern via toBytes()
  - [x] 4.4: Include message type field and sequence tracking
  - [x] 4.5: Handle malformed message detection with MessageException

- [x] **Task 5: Implement Data Type Encoder/Decoder** (AC: 3)
  - [x] 5.1: Create `lib/src/protocol/data_types.dart`
  - [x] 5.2: Implement `encodeValue(dynamic value, int oracleType)` for outbound binding
  - [x] 5.3: Implement `decodeValue(ReadBuffer, int oracleType)` for inbound results
  - [x] 5.4: Handle Oracle NUMBER encoding (variable-length format)
  - [x] 5.5: Handle VARCHAR2/CHAR encoding with character set support
  - [x] 5.6: Handle DATE/TIMESTAMP encoding (Oracle 7-byte date format)
  - [x] 5.7: Handle NULL value encoding/decoding

- [x] **Task 6: Implement Protocol Orchestrator** (AC: 1, 2, 4)
  - [x] 6.1: Create `lib/src/protocol/protocol.dart` with `TtcProtocol` class
  - [x] 6.2: Implement `createPacket()` method for packet creation with auto-sequencing
  - [x] 6.3: Implement `validateResponse()` method for request/response matching
  - [x] 6.4: Implement state transitions (disconnected → negotiating → connected)
  - [x] 6.5: Add ping and close packet creation methods

- [x] **Task 7: Write Unit Tests** (AC: all)
  - [x] 7.1: Create `test/src/protocol/constants_test.dart` - verify constant values match Oracle spec
  - [x] 7.2: Create `test/src/protocol/ttc_packet_test.dart` - encode/decode round-trips
  - [x] 7.3: Create `test/src/protocol/capabilities_test.dart` - capability negotiation
  - [x] 7.4: Create `test/src/protocol/data_types_test.dart` - type encoding/decoding
  - [x] 7.5: Create `test/src/protocol/messages/base_test.dart` - base message tests
  - [x] 7.6: Create `test/src/protocol/protocol_test.dart` - protocol orchestration tests

- [x] **Task 8: Finalize and Validate** (AC: all)
  - [x] 8.1: Run `dart analyze` with zero warnings
  - [x] 8.2: Run `dart format --set-exit-if-changed .`
  - [x] 8.3: Update exports in `lib/dart_oracledb.dart` (if any public types needed)
  - [x] 8.4: Verify all tests pass with `dart test`

## Dev Notes

### TTC Protocol Overview

**TTC (Two-Task Common)** is Oracle's application-level wire protocol that runs on top of TNS. Key details:

**TTC Message Structure:**
```
TTC messages are wrapped inside TNS DATA packets.
TNS packet (type=6 DATA) → TTC payload

TTC payload structure varies by message type, but generally:
- Function code (1-2 bytes) identifies the operation
- Sequence number for request/response matching
- Function-specific data fields
- Data type indicators for values
```

**TTC Function Codes (from node-oracledb constants.js):**
```dart
// Protocol negotiation
const int ttcProtocol = 1;           // Protocol negotiation
const int ttcDataTypes = 2;          // Data type negotiation

// Connection operations
const int ttcAuthPhaseOne = 0x76;    // Authentication phase 1 (118)
const int ttcAuthPhaseTwo = 0x73;    // Authentication phase 2 (115)
const int ttcClose = 0x09;           // Close connection

// Query operations
const int ttcExecute = 0x03;         // Execute statement
const int ttcFetch = 0x05;           // Fetch rows
const int ttcCommit = 0x0E;          // Commit transaction
const int ttcRollback = 0x0F;        // Rollback transaction
const int ttcPing = 0x93;            // Connection ping

// LOB operations
const int ttcLobOp = 0x60;           // LOB operation (96)
```

**Oracle Data Type Indicators:**
```dart
// Common Oracle data types (from node-oracledb)
const int oraTypeVarchar = 1;        // VARCHAR2
const int oraTypeNumber = 2;         // NUMBER
const int oraTypeInteger = 3;        // INTEGER (mapped to NUMBER)
const int oraTypeFloat = 4;          // FLOAT
const int oraTypeString = 5;         // STRING/CHAR
const int oraTypeVarnum = 6;         // VARNUM
const int oraTypeLong = 8;           // LONG
const int oraTypeVarchar2 = 9;       // VARCHAR2 (alternate)
const int oraTypeRowid = 11;         // ROWID
const int oraTypeDate = 12;          // DATE
const int oraTypeRaw = 23;           // RAW
const int oraTypeLongRaw = 24;       // LONG RAW
const int oraTypeURowid = 104;       // UROWID
const int oraTypeClob = 112;         // CLOB
const int oraTypeBlob = 113;         // BLOB
const int oraTypeTimestamp = 180;    // TIMESTAMP
const int oraTypeTimestampTz = 181;  // TIMESTAMP WITH TIME ZONE
const int oraTypeTimestampLtz = 231; // TIMESTAMP WITH LOCAL TIME ZONE
const int oraTypeJson = 119;         // JSON (Oracle 21c+)
```

### Architecture Compliance (MANDATORY)

**Source:** [docs/architecture.md](../architecture.md)

**Target Files (create these):**
- `lib/src/protocol/constants.dart` - TTC constants (function codes, data types)
- `lib/src/protocol/packet.dart` - TTC packet structure (separate from TNS)
- `lib/src/protocol/capabilities.dart` - Protocol capability negotiation
- `lib/src/protocol/data_types.dart` - Oracle data type encoding/decoding
- `lib/src/protocol/protocol.dart` - Protocol orchestration
- `lib/src/protocol/messages/base.dart` - Base message class

**Existing Files (from Story 1.2):**
- `lib/src/protocol/buffer.dart` - ReadBuffer and WriteBuffer classes (USE THESE)
- `lib/src/errors.dart` - OracleException class (USE THIS)
- `lib/src/transport/transport.dart` - Transport class (USE THIS)

**Buffer Pattern (CRITICAL - Use Story 1.2 Implementation):**
```dart
import 'buffer.dart';

// CORRECT - Use existing buffer classes with explicit endianness
final buffer = WriteBuffer();
buffer.writeUint8(functionCode);
buffer.writeUint16BE(sequenceNumber);  // Big-endian for TNS/TTC headers
buffer.writeUint32LE(dataLength);      // Little-endian for some TTC fields

final readBuf = ReadBuffer(bytes);
final funcCode = readBuf.readUint8();
final seqNum = readBuf.readUint16BE();
```

**Error Pattern (MANDATORY):**
```dart
// CORRECT - Wrap with cause for debugging
try {
  final message = Message.decode(buffer);
} catch (e) {
  throw OracleException(
    errorCode: 12547,
    message: 'TTC protocol error: malformed message at offset ${buffer.position}',
    cause: e,  // Preserve original error
  );
}
```

**Logging Pattern:**
```dart
import 'package:logging/logging.dart';

final _log = Logger('Protocol');

// Usage
_log.fine('Sending TTC message: function=$funcCode, seq=$seqNum');
_log.warning('Protocol negotiation timeout');
_log.severe('TTC decode error', error, stackTrace);
```

### Library/Framework Requirements

**Use Existing Buffer Classes:**
```dart
// Import from Story 1.2 implementation
import 'buffer.dart';

// WriteBuffer for encoding
final writer = WriteBuffer();
writer.writeUint8(ttcProtocol);
writer.writeUint16BE(version);
writer.writeBytes(capabilityData);
final encoded = writer.toBytes();

// ReadBuffer for decoding
final reader = ReadBuffer(receivedBytes);
final funcCode = reader.readUint8();
final version = reader.readUint16BE();
final remaining = reader.readBytes(reader.remaining);
```

**Use Existing Transport Layer:**
```dart
import '../transport/transport.dart';
import '../transport/packet.dart';

// Wrap TTC in TNS DATA packet
final tnsPacket = TnsPacket(
  type: tnsPacketData,
  payload: ttcEncodedBytes,
);
await transport.send(tnsPacket);

// Receive and unwrap
final response = await transport.receive();
if (response.type != tnsPacketData) {
  throw OracleException(
    errorCode: 12547,
    message: 'Expected TNS DATA packet, got type ${response.type}',
  );
}
final ttcPayload = response.payload;
```

### Oracle NUMBER Encoding Details

Oracle NUMBER is a variable-length format (1-22 bytes):
```
Byte 0: Length/Exponent byte
        High bit: sign (1=positive, 0=negative)
        Lower 7 bits: exponent + 65 (for positive), complement for negative
Bytes 1-21: Mantissa digits, 2 digits per byte (base-100 encoding)
            Each byte = (digit1 * 10 + digit2) + 1 for positive
            Complement for negative
            Terminated with 102 byte for negative numbers
```

**Simplified approach for MVP:**
```dart
// For simple integers, use the simplified encoding
Uint8List encodeNumber(num value) {
  if (value == 0) return Uint8List.fromList([0x80]); // Special case
  // ... implement based on node-oracledb nativeNumberToOracleNumber
}

num decodeNumber(ReadBuffer buffer) {
  // ... implement based on node-oracledb oracleNumberToNativeNumber
}
```

### Oracle DATE Encoding Details

Oracle DATE is exactly 7 bytes:
```
Byte 0: Century (100 + century, e.g., 120 = 20th century = 1900s)
Byte 1: Year in century (100 + year, e.g., 125 = year 25 = 2025)
Byte 2: Month (1-12)
Byte 3: Day (1-31)
Byte 4: Hour + 1 (1-24)
Byte 5: Minute + 1 (1-60)
Byte 6: Second + 1 (1-60)
```

**Example:**
```dart
// Encode DateTime to Oracle DATE format
Uint8List encodeDate(DateTime dt) {
  return Uint8List.fromList([
    (dt.year ~/ 100) + 100,  // Century
    (dt.year % 100) + 100,   // Year
    dt.month,                 // Month
    dt.day,                   // Day
    dt.hour + 1,             // Hour
    dt.minute + 1,           // Minute
    dt.second + 1,           // Second
  ]);
}

DateTime decodeDate(ReadBuffer buffer) {
  final century = buffer.readUint8() - 100;
  final year = buffer.readUint8() - 100;
  final month = buffer.readUint8();
  final day = buffer.readUint8();
  final hour = buffer.readUint8() - 1;
  final minute = buffer.readUint8() - 1;
  final second = buffer.readUint8() - 1;
  return DateTime(century * 100 + year, month, day, hour, minute, second);
}
```

### File Structure Requirements

**Directory Structure (must follow):**
```
lib/src/
├── errors.dart              # OracleException (FROM STORY 1.2)
├── protocol/
│   ├── buffer.dart          # Buffer utility (FROM STORY 1.2)
│   ├── constants.dart       # TTC constants (NEW)
│   ├── packet.dart          # TTC packet structure (NEW)
│   ├── capabilities.dart    # Capability negotiation (NEW)
│   ├── data_types.dart      # Data type encoding (NEW)
│   ├── protocol.dart        # Protocol orchestration (NEW)
│   └── messages/
│       └── base.dart        # Base message class (NEW)
└── transport/
    ├── transport.dart       # Transport abstraction (FROM STORY 1.2)
    └── packet.dart          # TNS packet (FROM STORY 1.2)
```

**Test Structure (mirrors lib/src/):**
```
test/src/
└── protocol/
    ├── constants_test.dart      # NEW
    ├── ttc_packet_test.dart     # NEW
    ├── capabilities_test.dart   # NEW
    ├── data_types_test.dart     # NEW
    ├── protocol_test.dart       # NEW
    └── messages/
        └── base_test.dart       # NEW
```

### Testing Requirements

**Unit Tests Required:**
1. TTC constants - verify values match Oracle specification
2. TTC packet encode/decode - round-trip serialization
3. Capability negotiation - client/server capability exchange
4. Data type encoding - NUMBER, DATE, VARCHAR2, NULL handling
5. Base message - abstract class patterns

**Test Pattern for Data Types:**
```dart
// test/src/protocol/data_types_test.dart
void main() {
  group('NUMBER encoding', () {
    test('encodes zero', () {
      final encoded = encodeNumber(0);
      expect(encoded, equals(Uint8List.fromList([0x80])));
    });

    test('encodes positive integer', () {
      final encoded = encodeNumber(123);
      // ... verify against known Oracle encoding
    });

    test('round-trips integer values', () {
      for (final value in [0, 1, -1, 123, -456, 999999]) {
        final encoded = encodeNumber(value);
        final decoded = decodeNumber(ReadBuffer(encoded));
        expect(decoded, equals(value));
      }
    });
  });

  group('DATE encoding', () {
    test('encodes date correctly', () {
      final dt = DateTime(2025, 12, 15, 14, 30, 45);
      final encoded = encodeDate(dt);
      expect(encoded.length, equals(7));
      expect(encoded[0], equals(120)); // Century 20 + 100
      expect(encoded[1], equals(125)); // Year 25 + 100
    });

    test('round-trips DateTime values', () {
      final dt = DateTime(2025, 12, 15, 14, 30, 45);
      final encoded = encodeDate(dt);
      final decoded = decodeDate(ReadBuffer(encoded));
      expect(decoded, equals(dt));
    });
  });
}
```

### Previous Story Intelligence

**From Story 1.2 (TNS Transport Layer):**
- Buffer utility classes (`ReadBuffer`, `WriteBuffer`) with explicit BE/LE endianness - **REUSE THESE**
- `OracleException` class with `errorCode`, `message`, `cause` - **REUSE THIS**
- `TnsPacket` class for TNS layer with 8-byte header - **REUSE THIS (TTC wraps in TNS DATA)**
- `Transport` class with `send(TnsPacket)` and `receive()` methods - **REUSE THIS**
- 111 tests pass, patterns established
- All code passes `dart analyze` with zero warnings
- Logging patterns established with `package:logging`

**Key Learning from Story 1.2:**
- Completer-based approach for socket reads works well
- RESEND retry limit prevents infinite loops
- Tests should cover error paths, not just happy path
- File List in story must include ALL files modified

### Common Oracle Error Codes for Protocol Layer

```dart
// Protocol-level error codes
const int oraProtocolError = 12547;      // TNS:lost contact
const int oraMalformedPacket = 12571;    // TNS:packet writer failure
const int oraProtocolViolation = 12585;  // TNS:data truncation
const int oraUnsupportedType = 3115;     // Unsupported network datatype
const int oraDataTypeNotSupported = 932; // Inconsistent datatypes
```

### Anti-Patterns to Avoid

1. **DO NOT** create new buffer classes - use existing `ReadBuffer`/`WriteBuffer` from Story 1.2
2. **DO NOT** use `ByteData` directly - use the wrapper methods with explicit endianness
3. **DO NOT** swallow decode errors - wrap with context and rethrow
4. **DO NOT** duplicate constant definitions - single source in `constants.dart`
5. **DO NOT** send TTC messages directly - always wrap in TNS DATA packet via Transport
6. **DO NOT** use `print()` - use `package:logging` instead
7. **DO NOT** create files outside the defined directory structure

### References

- [Architecture: Protocol Layer](../architecture.md#protocol-layer)
- [Architecture: Buffer Patterns](../architecture.md#protocol-patterns)
- [Architecture: Error Handling](../architecture.md#error-handling-patterns)
- [PRD: Data Types](../prd.md#data-type-handling)
- [Epic 1: Story 1.3 Requirements](../epics.md#story-13-ttc-protocol-foundation)
- [Story 1.2: TNS Transport Layer](./1-2-tns-transport-layer.md) - Completed, provides foundation

## Dev Agent Record

### Context Reference

Story created by SM agent using ultimate context engine analysis.

### Agent Model Used

Claude Opus 4.5 (claude-opus-4-5-20251101)

### Debug Log References

N/A

### Completion Notes List

1. **TTC Constants (Task 1):** Implemented all TTC function codes and Oracle data type indicators in `lib/src/protocol/constants.dart`. Constants mirror node-oracledb structure with proper documentation.

2. **TTC Packet Structure (Task 2):** Created `TtcPacket` class in `lib/src/protocol/ttc_packet.dart` with 4-byte header (function code, sequence, data flags) plus variable payload. Encode/decode methods use existing `WriteBuffer`/`ReadBuffer` from Story 1.2.

3. **Capabilities Negotiation (Task 3):** Implemented `Capabilities` class with protocol version, charset, and capability flags. Supports encode/decode and negotiation (intersection of client/server capabilities).

4. **Base Message Class (Task 4):** Created abstract `Message` class with `messageType`, `sequence`, and `encode(WriteBuffer)` method. Includes `MessageException` for error handling.

5. **Data Type Encoder/Decoder (Task 5):** Implemented Oracle NUMBER encoding (variable-length base-100 format), DATE encoding (7-byte format), and VARCHAR2 encoding (UTF-8). Generic `encodeValue`/`decodeValue` functions support type-based encoding.

6. **Protocol Orchestrator (Task 6):** Created `TtcProtocol` class managing state transitions (disconnected → negotiating → connected), sequence number management (0-255 wrap), and packet creation with auto-sequencing.

7. **All tests pass:** 235+ tests including 115 new tests for this story. Coverage includes round-trip encoding, edge cases, and error handling.

8. **All code passes `dart analyze`** with zero warnings and is properly formatted.

### File List

**New Files Created:**
- `lib/src/protocol/constants.dart` - TTC constants (function codes, data types, flags)
- `lib/src/protocol/ttc_packet.dart` - TTC packet structure
- `lib/src/protocol/capabilities.dart` - Protocol capability negotiation
- `lib/src/protocol/data_types.dart` - Oracle data type encoding/decoding
- `lib/src/protocol/protocol.dart` - Protocol orchestrator
- `lib/src/protocol/messages/base.dart` - Base message class

**New Test Files Created:**
- `test/src/protocol/constants_test.dart` - Constants tests (13 tests)
- `test/src/protocol/ttc_packet_test.dart` - TTC packet tests (15 tests)
- `test/src/protocol/capabilities_test.dart` - Capabilities tests (19 tests)
- `test/src/protocol/data_types_test.dart` - Data types tests (32 tests)
- `test/src/protocol/protocol_test.dart` - Protocol tests (25 tests)
- `test/src/protocol/messages/base_test.dart` - Base message tests (11 tests)

**Modified Files:**
- `docs/sprint-artifacts/sprint-status.yaml` - Updated story status
- `docs/sprint-artifacts/1-3-ttc-protocol-foundation.md` - This file
- `lib/dart_oracledb.dart` - Added protocol error code exports

### Code Review Fixes

**Reviewer:** Dev Agent (Amelia) with adversarial review
**Date:** 2025-12-15
**Issues Found:** 4 Critical/High, 4 Medium, 3 Low

**Critical/High Fixes Applied:**

1. **AC6 - OracleException Now Used:** Replaced all custom exceptions (`TtcPacketException`, `CapabilitiesException`, `DataTypeException`, `ProtocolException`) with `OracleException` using proper error codes:
   - `oraMalformedPacket` (12571) for decode errors
   - `oraDataTypeNotSupported` (932) for type mismatches
   - `oraUnsupportedType` (3115) for unsupported Oracle types
   - `oraProtocolError` (12547) for protocol state errors

2. **Task 8.3 - Exports Updated:** Added protocol error codes to `lib/dart_oracledb.dart`:
   - `oraMalformedPacket`, `oraProtocolViolation`, `oraUnsupportedType`, `oraDataTypeNotSupported`

3. **Logging Implemented:** Added `package:logging` to all protocol files:
   - `ttc_packet.dart` - Logger('TtcPacket')
   - `capabilities.dart` - Logger('Capabilities')
   - `data_types.dart` - Logger('DataTypes')
   - `protocol.dart` - Logger('Protocol')
   - `messages/base.dart` - Logger('Message')

4. **Protocol State Validation:** `beginNegotiation()` and `completeNegotiation()` now throw `OracleException` if called from invalid states.

**Test Updates:**
- All tests updated to expect `OracleException` instead of custom exceptions
- Added new tests for state validation errors
- Added tests verifying error codes in exceptions

**Final Verification:**
- `dart analyze`: **0 issues** (previously 7 info-level issues)
- `dart test`: **All tests pass** (148+ tests in protocol layer)
- All AC6 requirements verified with proper error codes and cause preservation
