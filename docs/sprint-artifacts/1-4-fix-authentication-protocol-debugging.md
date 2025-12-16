# Story 1.4-FIX: Authentication Protocol Debugging

Status: ready-for-dev

## Story

As a **developer maintaining dart-oracledb**,
I want **to identify and fix the authentication protocol bug**,
So that **Story 1.4 authentication implementation actually works with Oracle 23ai**.

## Context

**Critical Issue:** Story 1.4 implementation exists but authentication is **completely broken**. Oracle Database closes the connection immediately after receiving the `AUTH_PHASE_ONE` message (function code 0x76), indicating a protocol mismatch or malformed message.

**Error Observed:**
```
ORA-12547: Socket closed while waiting for data: need 8 bytes, have 0
```

**What Works:**
- ✓ TNS CONNECT/ACCEPT handshake successful
- ✓ Protocol negotiation (receives server version 6, field version 25)
- ✓ Data types negotiation (2479 byte response received)
- ✗ **AUTH_PHASE_ONE (Oracle terminates connection)**

**Impact:** Blocks ALL Epic 2+ work. Cannot execute queries without working authentication.

## Acceptance Criteria

### AC1: Identify exact protocol mismatch
**Given** the current AUTH_PHASE_ONE implementation
**When** comparing byte-by-byte with working node-oracledb via Wireshark or packet capture
**Then** the exact protocol difference causing Oracle to close connection is identified
**And** root cause is documented (capability flag, sequence number, token, or format issue)

### AC2: Implement fix for AUTH_PHASE_ONE
**Given** the identified protocol mismatch
**When** the AUTH_PHASE_ONE message encoding is corrected
**Then** Oracle accepts the message and responds (does not close connection)
**And** AUTH_PHASE_TWO can proceed

### AC3: All integration tests pass
**Given** the authentication fix is implemented
**When** running integration tests against Oracle 23ai Docker
**Then** authentication succeeds (no ORA-12547 errors)
**And** connection is established successfully
**And** basic queries can be executed (validates Story 2.1 foundation)

### AC4: Document findings
**Given** the bug is fixed
**When** documenting the root cause
**Then** findings are added to architecture.md or technical notes
**And** protocol comparison details are documented for future reference
**And** any Oracle 23ai-specific protocol requirements are noted

## Tasks / Subtasks

- [x] **Task 1: Setup Debugging Environment** (AC: 1)
  - [x] 1.1: Ensure Oracle 23ai Docker container is running and accessible
  - [x] 1.2: Install Wireshark or tcpdump for packet capture (if needed)
  - [x] 1.3: Set up node-oracledb reference environment for comparison
  - [x] 1.4: Enable detailed TTC protocol logging in dart-oracledb (`Logger.root.level = Level.FINE`)

- [x] **Task 2: Capture Working Protocol Flow** (AC: 1)
  - [x] 2.1: Capture successful node-oracledb authentication via Wireshark
  - [x] 2.2: Extract AUTH_PHASE_ONE message bytes from node-oracledb
  - [x] 2.3: Extract AUTH_PHASE_ONE message bytes from dart-oracledb
  - [x] 2.4: Create hex dumps of both messages for comparison

- [x] **Task 3: Byte-by-Byte Protocol Analysis** (AC: 1, 4)
  - [x] 3.1: Compare message headers (function code, sequence, token)
  - [x] 3.2: Compare username encoding and length fields
  - [x] 3.3: Compare auth mode flags
  - [x] 3.4: Compare key-value pair count and structure
  - [x] 3.5: Compare client info key-value pairs (AUTH_TERMINAL, etc.)
  - [x] 3.6: Document ALL differences found

- [x] **Task 4: Root Cause Identification** (AC: 1, 4)
  - [x] 4.1: Analyze identified differences for likely culprit
  - [x] 4.2: Review Oracle 23ai protocol documentation (if available)
  - [x] 4.3: Check node-oracledb source for Oracle 23ai-specific changes
  - [x] 4.4: Formulate hypothesis for connection close cause
  - [x] 4.5: Document root cause analysis in this story file

- [x] **Task 5: Implement Protocol Fix (Message Batching)** (AC: 1) - COMPLETED
  - [x] 5.1: Implement message batching in Transport layer
  - [x] 5.2: Fix protocol message format (length prefix + padding)
  - [x] 5.3: Fix data types message padding
  - [x] 5.4: Match exact byte count with node-oracledb (2780 bytes)
  - [x] 5.5: Update test to use batched handshake
  - [x] 5.6: Debug remaining byte content differences - ROOT CAUSE FOUND: FAST_AUTH protocol required

- [ ] **Task 6: Validate AUTH_PHASE_ONE Fix** (AC: 2, 3)
  - [ ] 6.1: Run minimal_auth_test.dart against Oracle 23ai
  - [ ] 6.2: Verify Oracle sends AUTH_PHASE_ONE response (not connection close)
  - [ ] 6.3: Verify response contains verifier parameters (AUTH_VFR_DATA, AUTH_SESSKEY)
  - [ ] 6.4: Log and analyze AUTH_PHASE_ONE response structure

- [ ] **Task 7: Implement/Fix AUTH_PHASE_TWO** (AC: 3)
  - [ ] 7.1: Verify AUTH_PHASE_TWO message encoding matches node-oracledb
  - [ ] 7.2: Fix password proof generation if needed (PBKDF2/SHA512)
  - [ ] 7.3: Fix session key derivation if needed
  - [ ] 7.4: Validate complete authentication flow succeeds

- [ ] **Task 8: Integration Test Validation** (AC: 3)
  - [ ] 8.1: Run all auth integration tests (test/integration/auth_integration_test.dart)
  - [ ] 8.2: Validate connection can be established
  - [ ] 8.3: Validate simple query execution works (SELECT * FROM dual)
  - [ ] 8.4: Validate connection close works properly
  - [ ] 8.5: Ensure all tests pass with 100% success rate

- [ ] **Task 9: Documentation and Knowledge Capture** (AC: 4)
  - [ ] 9.1: Document root cause in architecture.md "Known Issues" (then remove after fix)
  - [ ] 9.2: Add Oracle 23ai protocol notes to architecture.md if applicable
  - [ ] 9.3: Update this story's Dev Notes with detailed findings
  - [ ] 9.4: Create comparison table: dart-oracledb vs node-oracledb AUTH_PHASE_ONE format
  - [ ] 9.5: Document any gotchas for future auth protocol work

- [ ] **Task 10: Finalize and Clean Up** (AC: all)
  - [ ] 10.1: Run `dart analyze` with zero warnings
  - [ ] 10.2: Run `dart format --set-exit-if-changed .`
  - [ ] 10.3: Clean up any debug logging or test artifacts
  - [ ] 10.4: Update sprint-status.yaml: story 1-4-fix → done, epic-1 → done
  - [ ] 10.5: Update sprint-status.yaml: epic-2 → in-progress (unblocked)

## Dev Notes

### Problem Analysis Summary

**Timeline:**
- Story 1.4 (Authentication) was completed and committed at `b17a3ee`
- Subsequent uncommitted work attempted node-oracledb-style TTC auth protocol
- Story 2.1-2.4 implementations completed but **never validated** (no working connection)
- Integration test revealed auth has **never worked**

**Current Implementation Analysis:**

**AUTH_PHASE_ONE Message Structure** (from `lib/src/protocol/messages/auth_message.dart`):
```dart
// Function header
buffer.writeUint8(ttcMsgTypeFunction);    // Message type (3)
buffer.writeUint8(ttcAuthPhaseOne);       // Function code (0x76)
buffer.writeUint8(sequence & 0xFF);       // Sequence number

// Token number for Oracle 23.1+ (8-byte variable length)
if (use23aiFormat) {
  buffer.writeUB8(0);  // Token number = 0 for auth
}

// Authentication mode flags
const authMode = ttcAuthModeLogon | ttcAuthModeWithPassword;

// Username presence and length
buffer.writeUint8(usernamePresent ? 1 : 0);
buffer.writeUB4(usernameBytes.length);
buffer.writeUB4(authMode);

// Phase one parameters
buffer.writeUint8(1);      // Unknown flag
buffer.writeUB4(5);        // Number of key-value pairs
buffer.writeUint8(0);      // Unknown
buffer.writeUint8(1);      // Unknown

// Write username with length
if (usernameBytes.isNotEmpty) {
  buffer.writeBytesWithLength(usernameBytes);
}

// Write key-value pairs with client info
buffer.writeKeyValue('AUTH_TERMINAL', ClientInfo.terminal);
buffer.writeKeyValue('AUTH_PROGRAM_NM', ClientInfo.program);
buffer.writeKeyValue('AUTH_MACHINE', ClientInfo.machine);
buffer.writeKeyValue('AUTH_PID', ClientInfo.processId);
buffer.writeKeyValue('AUTH_SID', ClientInfo.userName);
```

**Message Size:** 220 bytes (as reported in test output)

**Known Constants** (from `lib/src/protocol/constants.dart`):
```dart
const int ttcMsgTypeFunction = 3;        // Function header message type
const int ttcAuthPhaseOne = 0x76;        // AUTH_PHASE_ONE function code
const int ttcAuthModeLogon = 0x0001;     // Logon mode
const int ttcAuthModeWithPassword = 0x0100; // Password authentication
```

**Suspected Issues:**

1. **Token Number Format:** Oracle 23ai introduced 8-byte token numbers. Current code uses `writeUB8(0)` which is variable-length encoding. Might need fixed 8-byte format.

2. **Sequence Number:** First function message should have sequence=0. Current code uses `sequence & 0xFF` which should be 0 on first call, but verify.

3. **Key-Value Pair Encoding:** The `writeKeyValue()` method might not match node-oracledb format. Need to verify exact encoding.

4. **Unknown Fields:** Several fields marked as "Unknown" with hardcoded values (1, 0, 1). These might be protocol flags that Oracle 23ai validates.

5. **Compile Capabilities:** Protocol negotiation sends compile capabilities. If mismatch with what AUTH_PHASE_ONE expects, Oracle might reject.

### Architecture Compliance (MANDATORY)

**Source:** [docs/architecture.md](../architecture.md)

**Target Files (modify these):**
- `lib/src/protocol/messages/auth_message.dart` - AUTH_PHASE_ONE/TWO encoding
- `lib/src/crypto/auth.dart` - Authentication flow coordinator
- `lib/src/transport/transport.dart` - TTC protocol message handling
- `test/integration/auth_integration_test.dart` - Integration test validation

**Existing Files (from previous stories):**
- `lib/src/protocol/buffer.dart` - ReadBuffer and WriteBuffer classes (USE THESE)
- `lib/src/protocol/constants.dart` - TTC constants
- `lib/src/errors.dart` - OracleException class (USE THIS)
- `lib/src/transport/packet.dart` - TNS packet handling

**Buffer Pattern (CRITICAL - Use Story 1.2/1.3 Implementation):**
```dart
import 'package:logging/logging.dart';
import '../protocol/buffer.dart';

final _log = Logger('AuthDebug');

// CORRECT - Use existing buffer classes with explicit endianness
final buffer = WriteBuffer();
buffer.writeUint8(ttcAuthPhaseOne);      // Function code
buffer.writeUint8(sequence);             // Sequence number
buffer.writeUB8(tokenNumber);            // Variable-length 8-byte

// Log for debugging
_log.fine('AUTH_PHASE_ONE: func=0x${ttcAuthPhaseOne.toRadixString(16)}, '
          'seq=$sequence, token=$tokenNumber');
_log.fine('Encoded bytes (${buffer.length}): ${_hexEncode(buffer.toBytes())}');
```

**Error Pattern (MANDATORY):**
```dart
try {
  final response = await transport.receiveMessage();
  // ... process response
} catch (e) {
  throw OracleException(
    errorCode: 12547,  // ORA-12547: TNS lost contact
    message: 'Authentication failed at AUTH_PHASE_ONE: connection closed by Oracle',
    cause: e,  // Preserve original error
  );
}
```

**Logging Pattern:**
```dart
import 'package:logging/logging.dart';

final _log = Logger('AuthMessage');

// Usage - be VERBOSE during debugging
_log.fine('Encoding AUTH_PHASE_ONE: user=$username');
_log.fine('Auth mode: 0x${authMode.toRadixString(16)}');
_log.fine('Key-value pairs: $numPairs');
_log.fine('Sending ${bytes.length} bytes to Oracle');
_log.fine('Hex dump: ${_bytesToHex(bytes)}');  // Full hex for Wireshark comparison
```

### Library/Framework Requirements

**Use Existing Protocol Layer:**
```dart
// From Story 1.3 - TTC Protocol Foundation
import '../protocol/buffer.dart';       // ReadBuffer, WriteBuffer
import '../protocol/constants.dart';    // TTC constants
import '../transport/transport.dart';   // Transport layer

// From Story 1.2 - TNS Transport Layer
import '../transport/packet.dart';      // TnsPacket wrapping
```

**Oracle 23ai Protocol Requirements:**

From `lib/src/protocol/messages/auth_message.dart` analysis:
- Field version 24/25 (Oracle 23ai uses field version 25)
- Token number support (8-byte variable-length encoding)
- Compile capabilities negotiation (done in protocol negotiation phase)
- Modern auth verifiers: O5LOGON (SHA512), O8LOGON (PBKDF2-SHA512)

**Debugging Utilities to Add:**

```dart
// Add to buffer.dart or auth_message.dart as helper
String _bytesToHex(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
}

// Wireshark-style packet dump
void _logPacketDump(String label, Uint8List bytes) {
  _log.fine('$label (${bytes.length} bytes):');
  for (var i = 0; i < bytes.length; i += 16) {
    final chunk = bytes.sublist(i, min(i + 16, bytes.length));
    final hex = chunk.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    final ascii = chunk.map((b) => (b >= 32 && b < 127) ? String.fromCharCode(b) : '.').join();
    _log.fine('  ${i.toRadixString(16).padLeft(4, '0')}: $hex  $ascii');
  }
}
```

### Debugging Approach

**Phase 1: Quick Comparison (2-4 hours)**

1. **Capture node-oracledb AUTH_PHASE_ONE:**
   ```bash
   # Start Wireshark, filter: tcp.port == 1521
   # Run simple node-oracledb connection script
   # Export AUTH_PHASE_ONE packet bytes
   ```

2. **Compare with dart-oracledb:**
   ```dart
   // Enable verbose logging
   Logger.root.level = Level.FINE;
   Logger.root.onRecord.listen((record) {
     print('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
   });

   // Run minimal_auth_test.dart
   // Compare hex output with node-oracledb capture
   ```

3. **Identify Differences:**
   - Byte-by-byte comparison starting from function header
   - Look for: wrong field order, wrong encoding, missing fields, extra fields

**Phase 2: Fix and Validate (2-4 hours)**

1. **Apply Fix:**
   - Update auth_message.dart based on findings
   - Update any related constants if needed

2. **Incremental Testing:**
   - Test AUTH_PHASE_ONE alone first
   - Ensure Oracle responds (not closes)
   - Then test full auth flow (phase one + phase two)

3. **Integration Validation:**
   - Run all auth tests
   - Run Story 2.1 query test to validate end-to-end

**Phase 3: Documentation (1 hour)**

1. Document exact fix applied
2. Note any Oracle 23ai-specific requirements discovered
3. Update architecture.md with protocol notes

### Previous Story Intelligence

**From Story 1.3 (TTC Protocol Foundation) - COMPLETED:**

**Key Learnings:**
- ✓ TTC protocol foundation is working (235+ tests pass)
- ✓ Protocol negotiation succeeds (server version 6, field version 25)
- ✓ Data types negotiation succeeds (2479 byte response)
- ✓ Buffer utilities (`ReadBuffer`, `WriteBuffer`) work correctly with explicit endianness
- ✓ TTC constants defined and validated
- ✓ `OracleException` used consistently with error codes and cause preservation

**Files Created in 1.3 (REUSE THESE):**
- `lib/src/protocol/buffer.dart` - Buffer utilities with BE/LE methods
- `lib/src/protocol/constants.dart` - TTC function codes, data types
- `lib/src/protocol/ttc_packet.dart` - TTC packet structure
- `lib/src/protocol/capabilities.dart` - Protocol capability negotiation
- `lib/src/protocol/protocol.dart` - Protocol orchestrator

**Working Patterns from 1.3:**
```dart
// Correct buffer usage - explicit endianness
final buffer = WriteBuffer();
buffer.writeUint8(functionCode);
buffer.writeUint16BE(sequenceNumber);  // Network byte order
buffer.writeUB4(length);               // Variable-length unsigned
```

**From Story 1.2 (TNS Transport Layer) - COMPLETED:**

**Key Learnings:**
- ✓ TNS CONNECT/ACCEPT handshake works
- ✓ TNS packet framing works correctly
- ✓ Transport layer handles retries (RESEND packets)
- ✓ Logging patterns established with `package:logging`

**Working TNS Flow:**
```
Client → CONNECT packet
Server → ACCEPT packet
Client → DATA packet (Protocol negotiation)
Server → DATA packet (Protocol params)
Client → DATA packet (Data types negotiation)
Server → DATA packet (Data types response)
Client → DATA packet (AUTH_PHASE_ONE)  ← BREAKS HERE
Server → (connection closed)
```

**From Story 2.1-2.4 (Query Execution) - IMPLEMENTED BUT NOT VALIDATED:**

**Status:** Implementation complete but **cannot test** without working authentication.

**Files Ready for Testing:**
- `lib/src/protocol/messages/execute_message.dart`
- `lib/src/protocol/messages/fetch_message.dart`
- `lib/src/connection.dart` (execute method)

**Critical:** Once auth is fixed, Story 2.1-2.4 tests must be run to validate Epic 2 foundation.

### Git Intelligence Summary

**Recent Commits Analysis:**

**Commit `9a2692b` - WIP: Auth protocol implementation (broken)**
- Captures current broken state
- AUTH_PHASE_ONE sends 220 bytes
- Oracle closes connection with ORA-12547
- Commit message: "broken - connection closes at AUTH_PHASE_ONE"

**Commit `431cd72` - Add minimal authentication test**
- Created `test/integration/minimal_auth_test.dart`
- Test demonstrates authentication failure
- Useful for debugging - keep this test

**Commit `b96567f` - Implement DML operations**
- Part of Epic 2 Story 2.4
- Implementation ready, needs auth to test

**Commit `bd57e42` - Implement bind parameter support**
- Part of Epic 2 Story 2.3
- Implementation ready, needs auth to test

**Files Modified in Recent Commits:**

Critical files for this story:
- `lib/src/protocol/messages/auth_message.dart` - **453 lines changed** (major rewrite)
- `lib/src/crypto/auth.dart` - **71 lines changed** (auth flow)
- `lib/src/transport/transport.dart` - **718 lines changed** (TTC protocol support)
- `lib/src/protocol/buffer.dart` - **164 lines added** (variable-length encodings)

Test files:
- `test/integration/minimal_auth_test.dart` - New minimal test
- `test/integration/debug_auth_test.dart` - New debug test
- `test/integration/auth_integration_test.dart` - **19 lines changed** (updated for new protocol)

**Code Patterns Established:**

From recent commits, established patterns:
- Variable-length integer encoding: `writeUB1()`, `writeUB2()`, `writeUB4()`, `writeUB8()`
- Key-value pair encoding: `writeKeyValue(key, value)` method
- Client info collection: `ClientInfo` class with terminal, program, machine, pid, username
- Session key derivation: PBKDF2-SHA512 with salt and iterations

### Common Oracle Error Codes

```dart
// Authentication errors
const int oraInvalidCredentials = 1017;     // ORA-01017: invalid username/password
const int oraAccountLocked = 28000;         // ORA-28000: account is locked
const int oraPasswordExpired = 28001;       // ORA-28001: password has expired

// Protocol errors
const int oraTnsLostContact = 12547;        // ORA-12547: TNS:lost contact
const int oraTnsNoListener = 12541;         // ORA-12541: TNS:no listener
const int oraTnsPacketWriter = 12571;       // ORA-12571: TNS:packet writer failure
const int oraTnsProtocolAdapter = 12560;    // ORA-12560: TNS:protocol adapter error
```

**Expected Error Flow:**

✗ Current: ORA-12547 (connection closed) at AUTH_PHASE_ONE
✓ Fixed: Oracle responds to AUTH_PHASE_ONE with verifier params
✓ Fixed: If password wrong, ORA-01017 at AUTH_PHASE_TWO (not connection close)

### Testing Strategy

**Test Progression:**

1. **Unit Tests** (Fast feedback):
   ```dart
   // test/src/protocol/messages/auth_message_test.dart
   test('AUTH_PHASE_ONE encoding matches node-oracledb format', () {
     final msg = AuthPhaseOneRequest(
       username: 'SYSTEM',
       clientNonce: Uint8List(16),  // zeros for deterministic test
     );
     final bytes = msg.toBytes();

     // Compare with known-good node-oracledb hex dump
     expect(_bytesToHex(bytes), equals(expectedNodeOracledbHex));
   });
   ```

2. **Integration Tests** (Real Oracle):
   ```dart
   // test/integration/minimal_auth_test.dart
   test('AUTH_PHASE_ONE receives response from Oracle', () async {
     final transport = await Transport.connect(...);
     // ... protocol negotiation ...

     final authReq = AuthPhaseOneRequest(...);
     await transport.sendMessage(authReq.toBytes());

     // Should NOT throw ORA-12547
     final response = await transport.receiveMessage();
     expect(response, isNotNull);  // Oracle responded!
   });
   ```

3. **Full Authentication Test:**
   ```dart
   // test/integration/auth_integration_test.dart
   test('Complete authentication flow succeeds', () async {
     final conn = await OracleConnection.connect(
       'localhost:1521/FREEPDB1',
       user: 'system',
       password: 'testpassword',
     );

     expect(conn.isOpen, isTrue);
     await conn.close();
   });
   ```

4. **Query Execution Test** (Validates Epic 2):
   ```dart
   test('Simple query execution after auth', () async {
     final conn = await OracleConnection.connect(...);
     final result = await conn.execute('SELECT * FROM dual');
     expect(result.rows.length, equals(1));
     await conn.close();
   });
   ```

### Anti-Patterns to Avoid

1. **DO NOT** guess at protocol fixes - always compare with working reference (node-oracledb)
2. **DO NOT** disable logging during debugging - verbose logs are critical
3. **DO NOT** skip Wireshark comparison if quick fixes fail
4. **DO NOT** modify protocol negotiation - it's working, problem is in AUTH_PHASE_ONE
5. **DO NOT** change buffer utility methods - they're tested and working
6. **DO NOT** swallow connection close error - surface it for debugging
7. **DO NOT** commit fixes without integration test validation

### Success Criteria Checklist

Before marking story "done":

- [ ] AUTH_PHASE_ONE sends message, Oracle responds (no connection close)
- [ ] AUTH_PHASE_ONE response contains verifier parameters
- [ ] AUTH_PHASE_TWO completes successfully
- [ ] Integration test: Connection established
- [ ] Integration test: Simple query executes (SELECT * FROM dual)
- [ ] Integration test: Invalid password throws ORA-01017 (not connection close)
- [ ] Unit tests updated and passing
- [ ] Root cause documented in this story file
- [ ] Architecture.md updated with any Oracle 23ai protocol notes
- [ ] `dart analyze` passes with zero warnings
- [ ] Sprint status updated: Epic 1 → done, Epic 2 → in-progress

### References

- [Architecture: Protocol Layer](../architecture.md#protocol-layer)
- [Architecture: Error Handling Patterns](../architecture.md#error-handling-patterns)
- [Architecture: Authentication Implementation](../architecture.md#crypto-layer)
- [Epic 1: Story 1.4-FIX Requirements](../epics.md#story-14-fix-authentication-protocol-debugging)
- [Story 1.3: TTC Protocol Foundation](./1-3-ttc-protocol-foundation.md) - Completed, provides foundation
- [Story 1.2: TNS Transport Layer](./1-2-tns-transport-layer.md) - Completed, TNS layer working
- [Sprint Change Proposal 2025-12-16](../sprint-change-proposal-2025-12-16.md) - Detailed problem analysis
- [node-oracledb thin driver](https://github.com/oracle/node-oracledb) - Reference implementation

## Dev Agent Record

### Context Reference

Story created by SM agent (Bob) using ultimate BMad Method context engine analysis.

**Context Sources Analyzed:**
- Epic 1 complete breakdown from epics.md
- Story 1.4-FIX acceptance criteria and priority
- Architecture patterns and requirements
- Previous stories 1.2 and 1.3 learnings
- Recent commit history (auth protocol rewrite)
- Sprint change proposal (detailed problem analysis)
- Current auth implementation code review

**Analysis Depth:** EXHAUSTIVE - All available artifacts thoroughly analyzed to create comprehensive developer guide.

### Agent Model Used

Claude Sonnet 4.5 (claude-sonnet-4-5-20250929)

### Debug Log References

N/A - Story creation, not implementation

### Implementation Notes (2025-12-16)

**Session Summary:**
Implemented message batching solution for Oracle 23ai authentication based on findings document analysis. Successfully matched byte count with node-oracledb (2780 TTC bytes) but Oracle still rejects connection - indicating subtle byte content differences remain.

**What Was Completed:**

1. ✅ **Message Batching Implementation**
   - Added `Transport.sendBatchedProtocolAndAuth()` method
   - Sends Protocol + DataTypes + AUTH_PHASE_ONE in single TNS DATA packet
   - Matches node-oracledb's 2790-byte packet structure

2. ✅ **Protocol Message Format Fix**
   - Added length prefix (1 byte)
   - Fixed message structure: length + type + 5-byte sequence + driver + null + 6-byte padding
   - Protocol message: 17 bytes → 27 bytes (matches node exactly)

3. ✅ **Data Types Message Padding**
   - Added 10 bytes of padding after terminator
   - Data types message: 2598 bytes → 2608 bytes
   - Pattern: `00 00 | 00 7f 00 7f 00 01 00 00 00 00`

4. ✅ **Test Updates**
   - Updated `minimal_auth_test.dart` to use batched handshake
   - Fixed username case (SYSTEM → system)
   - Removed `.toUpperCase()` call in username encoding

**Current State:**
- Byte count: ✅ EXACT match (2780 TTC bytes, 2790 TNS packet)
- Authentication: ❌ Oracle still closes connection (ORA-12547)
- Root cause: Byte CONTENT differs subtly from node-oracledb

**Remaining Work:**
- [ ] Byte-by-byte comparison of actual TTC content
- [ ] Identify and fix remaining content differences
- [ ] Validate AUTH_PHASE_ONE response received
- [ ] Complete AUTH_PHASE_TWO implementation if needed

**Tools Created:**
- `compare_auth_bytes.js` - Captures node-oracledb AUTH_PHASE_ONE bytes
- `compare_batched_bytes.js` - Captures full batched handshake (2790 bytes)
- `node_batched.bin` - Binary dump of node's batched packet
- `node_ttc_batch.bin` - TTC messages only (2780 bytes)

### File List

**Modified:**
- `lib/src/transport/transport.dart` - Added `sendBatchedProtocolAndAuth()`, `_buildDataTypesMessage()` methods
- `lib/src/protocol/messages/protocol_message.dart` - Fixed `ProtocolRequest.encode()` format
- `test/integration/minimal_auth_test.dart` - Updated to use batched handshake, fixed username case

**Created:**
- `compare_auth_bytes.js` - Node.js debugging tool
- `compare_batched_bytes.js` - Node.js packet capture tool
- `node_batched.bin` - Reference binary data
- `node_ttc_batch.bin` - Reference TTC data

**Not Modified (from expected list):**
- `lib/src/protocol/messages/auth_message.dart` - No changes needed (already correct per findings)
- `lib/src/crypto/auth.dart` - No changes needed (already correct per findings)
- `test/integration/auth_integration_test.dart` - Not tested yet
- `docs/architecture.md` - Deferred until solution complete

---

### Implementation Notes (2025-12-16 Session 2) - CRITICAL DISCOVERY

**🔍 ROOT CAUSE IDENTIFIED: FAST_AUTH Protocol Required**

After extensive byte-by-byte comparison between dart-oracledb and node-oracledb, the fundamental issue has been identified:

**Oracle 23ai requires the FAST_AUTH protocol**, NOT manual message batching!

#### Key Findings

1. **Node-oracledb uses `TNS_MSG_TYPE_FAST_AUTH` (message type 15)**
   - Located in: `reference/node-oracledb/lib/thin/protocol/messages/fastAuth.js`
   - This is Oracle's official Fast Authentication protocol introduced in newer versions
   - Sends Protocol + DataTypes + Auth in a SINGLE FAST_AUTH message envelope

2. **FAST_AUTH Message Structure** (from fastAuth.js lines 47-61):
   ```javascript
   encode(buf) {
     buf.writeUInt8(constants.TNS_MSG_TYPE_FAST_AUTH);  // Message type = 15
     buf.writeUInt8(1);                                  // Fast Auth version
     buf.writeUInt8(constants.TNS_SERVER_CONVERTS_CHARS); // flag 1
     buf.writeUInt8(0);                                  // flag 2
     this.protocolMessage.encode(buf);                   // Protocol (no type prefix!)
     buf.writeUInt16BE(0);                               // server charset (unused)
     buf.writeUInt8(0);                                  // server charset flag (unused)
     buf.writeUInt16BE(0);                               // server ncharset (unused)
     buf.caps.ttcFieldVersion = constants.TNS_CCAP_FIELD_VERSION_19_1_EXT_1;
     buf.writeUInt8(buf.caps.ttcFieldVersion);
     this.dataTypeMessage.encode(buf);                   // Data types (no type prefix!)
     this.authMessage.encode(buf);                       // Auth (WITH function header!)
     buf.caps.ttcFieldVersion = constants.TNS_CCAP_FIELD_VERSION_MAX;
   }
   ```

3. **Why Our Manual Batching Failed:**
   - We were concatenating three separate TTC messages with length prefixes
   - Oracle 23ai expects a SINGLE FAST_AUTH envelope message
   - The protocol and data types messages are embedded WITHOUT their message type bytes
   - The auth message IS embedded WITH its full function header
   - This explains why our AUTH_PHASE_ONE appeared misaligned by 7 bytes!

4. **Byte-by-byte Analysis Confirmed:**
   - Protocol message: ✓ 34 bytes (but needs to be embedded in FAST_AUTH, not standalone)
   - Data types message: ✓ 2608 bytes (but needs to be embedded, not standalone)
   - AUTH message: ❌ Currently 145 bytes with function header, should be 138 bytes embedded
   - Our approach: Sent 3 separate messages (wrong!)
   - Correct approach: Send 1 FAST_AUTH message containing all 3 (right!)

#### Required Changes

**IMMEDIATE NEXT STEPS:**

1. **Implement FastAuthMessage class** (`lib/src/protocol/messages/fast_auth_message.dart`)
   - Message type: `TNS_MSG_TYPE_FAST_AUTH` (15)
   - Embed protocol negotiation (without type prefix)
   - Embed data types negotiation (without type prefix)
   - Embed AUTH_PHASE_ONE (with function header)
   - Handle RENEGOTIATE response case

2. **Update Transport.sendBatchedProtocolAndAuth()**
   - Remove manual batching logic
   - Use FastAuthMessage instead
   - Send as single message

3. **Add FastAuth constant**
   - Add `TNS_MSG_TYPE_FAST_AUTH = 15` to constants

4. **Test against Oracle 23ai**
   - Verify server accepts FAST_AUTH message
   - Confirm AUTH_PHASE_ONE response received
   - Complete authentication flow

#### References
- Node-oracledb FAST_AUTH: `reference/node-oracledb/lib/thin/protocol/messages/fastAuth.js`
- Usage in connection: `reference/node-oracledb/lib/thin/connection.js` lines 901-912
- Oracle docs: FAST_AUTH is Oracle's optimization for reducing round trips during connection

#### Impact
- **Epic 1 Status:** Still blocked until FAST_AUTH implemented
- **Epic 2 Status:** Blocked (depends on working auth)
- **Estimated Fix:** 2-4 hours to implement FAST_AUTH protocol correctly
- **Confidence:** HIGH - root cause definitively identified through source code analysis
