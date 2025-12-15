# Story 1.2: TNS Transport Layer

Status: done

## Story

As a **developer using dart-oracledb**,
I want **the driver to communicate with Oracle over TCP using TNS protocol**,
So that **I can establish network connectivity to Oracle databases**.

## Acceptance Criteria

1. **AC1:** Given an Oracle database listening on a TCP port, when the transport layer is initialized with host and port, then a TCP socket connection is established
2. **AC2:** TNS packets can be sent with proper framing (8-byte header + payload)
3. **AC3:** TNS packets can be received and parsed correctly
4. **AC4:** The transport handles CONNECT, ACCEPT, DATA, and RESEND packet types
5. **AC5:** EZ Connect string parsing works for `host:port/service` format
6. **AC6:** Given a network error occurs when sending or receiving packets, then an appropriate `OracleException` is surfaced (not swallowed) with original error preserved via `cause`

## Tasks / Subtasks

- [x] **Task 1: Implement Buffer utility class** (AC: 2, 3)
  - [x] 1.1: Create `lib/src/protocol/buffer.dart` with explicit endianness methods
  - [x] 1.2: Implement `readUint8()`, `readUint16BE()`, `readUint32BE()`, `readUint16LE()`, `readUint32LE()`
  - [x] 1.3: Implement `writeUint8()`, `writeUint16BE()`, `writeUint32BE()`, `writeUint16LE()`, `writeUint32LE()`
  - [x] 1.4: Implement `readBytes()`, `writeBytes()`, `readString()`, `writeString()`
  - [x] 1.5: Add bounds checking with clear error messages

- [x] **Task 2: Implement OracleException class** (AC: 6)
  - [x] 2.1: Create `lib/src/errors.dart` with `OracleException` class
  - [x] 2.2: Include `errorCode` property for ORA-xxxxx codes
  - [x] 2.3: Include `message` property for description
  - [x] 2.4: Include `cause` property to preserve original error

- [x] **Task 3: Implement TNS packet structure** (AC: 2, 3, 4)
  - [x] 3.1: Create `lib/src/transport/packet.dart` with `TnsPacket` class
  - [x] 3.2: Implement 8-byte TNS header: length (2), checksum (2), type (1), marker (1), header checksum (2)
  - [x] 3.3: Define packet type constants: CONNECT=1, ACCEPT=2, REFUSE=4, DATA=6, RESEND=11, MARKER=12
  - [x] 3.4: Implement `TnsPacket.encode()` for serialization
  - [x] 3.5: Implement `TnsPacket.decode()` for deserialization

- [x] **Task 4: Implement EZ Connect string parser** (AC: 5)
  - [x] 4.1: Create `lib/src/transport/connect_string.dart`
  - [x] 4.2: Parse format: `host:port/service_name`
  - [x] 4.3: Support default port 1521 when not specified
  - [x] 4.4: Validate inputs and throw `OracleException` for invalid format

- [x] **Task 5: Implement TCP socket wrapper** (AC: 1, 6)
  - [x] 5.1: Create `lib/src/transport/socket.dart` with `OracleSocket` class
  - [x] 5.2: Use `dart:io` `Socket.connect()` for TCP connection
  - [x] 5.3: Implement `connect(host, port, {timeout})` method
  - [x] 5.4: Implement `close()` method for resource cleanup
  - [x] 5.5: Handle socket errors and wrap in `OracleException` with `cause`

- [x] **Task 6: Implement Transport abstraction** (AC: 1, 2, 3, 6)
  - [x] 6.1: Create `lib/src/transport/transport.dart` with `Transport` class
  - [x] 6.2: Implement `send(TnsPacket)` method
  - [x] 6.3: Implement `receive()` method returning `TnsPacket`
  - [x] 6.4: Handle partial reads (packets may arrive in chunks)
  - [x] 6.5: Add logging via `package:logging`

- [x] **Task 7: Write integration tests** (AC: 1, 2, 3, 4, 5, 6)
  - [x] 7.1: Create `test/src/protocol/buffer_test.dart` - unit tests for buffer operations
  - [x] 7.2: Create `test/src/transport/packet_test.dart` - unit tests for TNS packet encode/decode
  - [x] 7.3: Create `test/src/transport/connect_string_test.dart` - unit tests for EZ Connect parsing
  - [x] 7.4: Create `test/src/transport/socket_test.dart` - integration test connecting to Oracle 23ai

- [x] **Task 8: Update public exports** (AC: all)
  - [x] 8.1: Export `OracleException` from `lib/dart_oracledb.dart`
  - [x] 8.2: Run `dart analyze` with zero warnings
  - [x] 8.3: Run `dart format --set-exit-if-changed .`

## Dev Notes

### TNS Protocol Specification

**TNS (Transparent Network Substrate)** is Oracle's network protocol layer. Key details:

**8-byte TNS Header Structure:**
```
Offset  Size  Field           Description
0       2     packet_length   Total packet size (big-endian)
2       2     checksum        Packet checksum (usually 0)
4       1     packet_type     Type of packet (see constants)
5       1     marker          Reserved/marker byte
6       2     header_checksum Header checksum (usually 0)
```

**TNS Packet Types:**
```dart
const int tnsPacketConnect = 1;   // Initial connection request
const int tnsPacketAccept = 2;    // Connection accepted
const int tnsPacketAck = 3;       // Acknowledgment
const int tnsPacketRefuse = 4;    // Connection refused
const int tnsPacketRedirect = 5;  // Redirect to another address
const int tnsPacketData = 6;      // Data packet (carries TTC)
const int tnsPacketNull = 7;      // Null packet
const int tnsPacketAbort = 9;     // Abort connection
const int tnsPacketResend = 11;   // Resend request
const int tnsPacketMarker = 12;   // Marker packet
const int tnsPacketAttention = 13; // Attention request
```

### Architecture Compliance (MANDATORY)

**Source:** [docs/architecture.md](../architecture.md)

**Target Files (create these):**
- `lib/src/protocol/buffer.dart` - Buffer with explicit BE/LE methods
- `lib/src/errors.dart` - OracleException class
- `lib/src/transport/packet.dart` - TNS packet types
- `lib/src/transport/connect_string.dart` - EZ Connect parsing
- `lib/src/transport/socket.dart` - TCP socket wrapper
- `lib/src/transport/transport.dart` - Transport abstraction

**Buffer Pattern (CRITICAL):**
```dart
// CORRECT - Endianness explicit in method name
final value = buffer.readUint16BE();
buffer.writeUint32LE(value);

// WRONG - Ambiguous (DO NOT USE)
final value = buffer.readUint16();  // Which endian?
```

**Error Pattern (MANDATORY):**
```dart
// CORRECT - Wrap with cause for debugging
try {
  await socket.connect(host, port);
} catch (e) {
  throw OracleException(
    errorCode: 12170,
    message: 'TNS:Connect timeout occurred',
    cause: e,  // Preserve original error
  );
}

// WRONG - Loses original error context
throw OracleException(errorCode: 12170, message: 'Connect timeout');
```

**Logging Pattern:**
```dart
import 'package:logging/logging.dart';

final _log = Logger('Transport');

// Usage
_log.fine('Sending TNS packet: type=$type, length=$length');
_log.warning('Connection timeout, no response');
_log.severe('Socket error', error, stackTrace);
```

### Library/Framework Requirements

**dart:io Socket API:**
```dart
import 'dart:io';

// Connect with timeout
final socket = await Socket.connect(
  host,
  port,
  timeout: Duration(seconds: 30),
);

// Write bytes
socket.add(packetBytes);
await socket.flush();

// Read bytes (subscription-based)
socket.listen(
  (Uint8List data) { /* handle data */ },
  onError: (error) { /* handle error */ },
  onDone: () { /* socket closed */ },
);

// Close
await socket.close();
```

**Byte buffer operations:**
```dart
import 'dart:typed_data';

// Create buffer
final buffer = ByteData(8);

// Big-endian operations (network byte order for TNS)
buffer.setUint16(0, length, Endian.big);
final length = buffer.getUint16(0, Endian.big);

// Little-endian operations (some TTC fields)
buffer.setUint32(0, value, Endian.little);
```

### File Structure Requirements

**Directory Structure (must follow):**
```
lib/src/
├── errors.dart              # OracleException class
├── protocol/
│   └── buffer.dart          # Buffer utility with BE/LE methods
└── transport/
    ├── connect_string.dart  # EZ Connect parser
    ├── packet.dart          # TNS packet structure
    ├── socket.dart          # TCP socket wrapper
    └── transport.dart       # Transport abstraction
```

**Test Structure (mirrors lib/src/):**
```
test/src/
├── protocol/
│   └── buffer_test.dart
└── transport/
    ├── connect_string_test.dart
    ├── packet_test.dart
    └── socket_test.dart
```

### Testing Requirements

**Unit Tests Required:**
1. Buffer operations - all endianness methods, bounds checking
2. TNS packet encode/decode - round-trip serialization
3. EZ Connect parsing - valid/invalid formats
4. OracleException - error code, message, cause preservation

**Integration Test (requires Oracle 23ai Docker):**
```dart
// test/src/transport/socket_test.dart
@TestOn('vm')
import 'package:test/test.dart';

void main() {
  group('OracleSocket integration', () {
    test('connects to Oracle 23ai', () async {
      // Only runs when RUN_INTEGRATION_TESTS=true
      final shouldRun = Platform.environment['RUN_INTEGRATION_TESTS'] == 'true';
      if (!shouldRun) {
        markTestSkipped('Integration tests disabled');
        return;
      }

      final socket = OracleSocket();
      await socket.connect('localhost', 1521, timeout: Duration(seconds: 10));
      expect(socket.isConnected, isTrue);
      await socket.close();
    });
  });
}
```

**Run integration tests:**
```bash
RUN_INTEGRATION_TESTS=true dart test test/src/transport/socket_test.dart
```

### Previous Story Intelligence

**From Story 1.1 (Project Initialization):**
- Directory structure established: `lib/src/transport/`, `lib/src/protocol/`, `lib/src/crypto/`
- Dependencies in place: `crypto`, `pointycastle`, `logging`
- Empty `.gitkeep` files in directories - replace with actual implementation files
- Test structure mirrors lib: `test/src/transport/`, `test/src/protocol/`
- Public export file: `lib/dart_oracledb.dart` (add exports here)
- All code must pass `dart analyze` with zero warnings

### Common Oracle Error Codes for Transport Layer

```dart
// Common TNS error codes to use in OracleException
const int oraNetworkError = 12150;      // TNS:unable to send data
const int oraConnectTimeout = 12170;    // TNS:Connect timeout occurred
const int oraHostUnreachable = 12541;   // TNS:no listener
const int oraConnectionRefused = 12514; // TNS:listener does not know of service
const int oraProtocolError = 12547;     // TNS:lost contact
```

### Anti-Patterns to Avoid

1. **DO NOT** use `ByteData` methods without explicit `Endian` parameter
2. **DO NOT** swallow socket errors - always wrap and rethrow with cause
3. **DO NOT** create files outside the defined directory structure
4. **DO NOT** use `print()` - use `package:logging` instead
5. **DO NOT** forget to handle partial reads - TCP may deliver data in chunks

### References

- [Architecture: Transport Layer](../architecture.md#transport-layer)
- [Architecture: Buffer Patterns](../architecture.md#protocol-patterns)
- [Architecture: Error Handling](../architecture.md#error-handling-patterns)
- [PRD: FR1 - EZ Connect](../prd.md#connection-management)
- [Epic 1: Story 1.2 Requirements](../epics.md#story-12-tns-transport-layer)

## Dev Agent Record

### Context Reference

Story created by SM agent using ultimate context engine analysis.

### Agent Model Used

{{agent_model_name_version}}

### Debug Log References

### Completion Notes List

- **Task 1 (Buffer utility class):** Implemented ReadBuffer and WriteBuffer classes with explicit BE/LE endianness methods. All 36 unit tests pass. BufferException class provides clear error messages for bounds checking. Code passes `dart analyze` with zero warnings.
- **Task 2 (OracleException class):** Implemented OracleException with errorCode, message, and cause properties. Added common TNS error code constants. All 14 unit tests pass. Code passes `dart analyze` with zero warnings.
- **Task 3 (TNS packet structure):** Implemented TnsPacket class with 8-byte header structure and encode/decode methods. Added TnsPacketException and all packet type constants. All 23 unit tests pass. Code passes `dart analyze` with zero warnings.
- **Task 4 (EZ Connect parser):** Implemented parseEZConnect() and ConnectionInfo class. Supports host:port/service format with default port 1521. Validates all inputs and throws OracleException with helpful messages. All 24 unit tests pass. Code passes `dart analyze` with zero warnings.
- **Task 5 (TCP socket wrapper):** Implemented OracleSocket class wrapping dart:io Socket with Oracle-specific error handling. All socket errors wrapped in OracleException with cause preserved. Includes connect(), close(), send(), read() methods with logging. All 6 unit tests pass (2 integration tests skipped). Code passes `dart analyze` with zero warnings.
- **Task 6 (Transport abstraction):** Implemented Transport class as high-level TNS packet transport. Uses OracleSocket for TCP, handles partial reads (header first, then payload), includes encodePacket/decodePacket methods. All 8 unit tests pass. Code passes `dart analyze` with zero warnings.
- **Task 7 (Integration tests):** All test files created during Tasks 1-6 using red-green-refactor cycle. Total: 111 tests pass (2 integration tests skip when RUN_INTEGRATION_TESTS not set).
- **Task 8 (Public exports):** Exported OracleException and TNS error code constants from lib/dart_oracledb.dart. `dart analyze` shows zero warnings (16 info-level hints in tests). `dart format` applied to all files.

### File List

- `pubspec.yaml` - UPDATED: Dependencies (crypto, pointycastle, logging)
- `lib/dart_oracledb.dart` - UPDATED: Added exports for OracleException and error codes
- `lib/src/protocol/buffer.dart` - NEW: Buffer utility classes (ReadBuffer, WriteBuffer, BufferException)
- `lib/src/errors.dart` - NEW: OracleException class and TNS error code constants
- `lib/src/transport/packet.dart` - NEW: TnsPacket class with encode/decode and packet type constants
- `lib/src/transport/connect_string.dart` - NEW: EZ Connect parser and ConnectionInfo class
- `lib/src/transport/socket.dart` - UPDATED: OracleSocket TCP wrapper with Completer-based read()
- `lib/src/transport/transport.dart` - UPDATED: Transport class with RESEND retry limit
- `test/src/protocol/buffer_test.dart` - NEW: 36 unit tests for buffer operations
- `test/src/errors_test.dart` - NEW: 14 unit tests for OracleException
- `test/src/transport/packet_test.dart` - NEW: 23 unit tests for TNS packet operations
- `test/src/transport/connect_string_test.dart` - NEW: 24 unit tests for EZ Connect parsing
- `test/src/transport/socket_test.dart` - UPDATED: 10 unit tests + 2 integration tests for socket
- `test/src/transport/transport_test.dart` - UPDATED: 14 unit tests for Transport

### Senior Developer Review (AI)

**Review Date:** 2025-12-15
**Reviewer:** Dev Agent (Amelia)

**Issues Found & Fixed:**
1. **H1 (HIGH):** OracleSocket.read() had no unit tests → Added 2 tests
2. **H2 (HIGH):** Transport.sendConnectReceiveAccept() had no tests → Added tests for error paths
3. **H3 (HIGH):** Race condition with broadcast stream in read() → Replaced with Completer-based approach
4. **M1 (MEDIUM):** pubspec.yaml not in File List → Added to File List
5. **M2 (MEDIUM):** StreamController never closed → Removed StreamController, using Completer
6. **M3 (MEDIUM):** isConnected race condition in read() → Check moved inside loop with proper cleanup
7. **M4 (MEDIUM):** RESEND retry had no limit → Added _maxResendRetries = 3
8. **M5 (MEDIUM):** send() on disconnected socket not tested → Added 2 tests

**Outcome:** All HIGH and MEDIUM issues fixed. Code quality improved.
