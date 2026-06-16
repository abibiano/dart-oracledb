---
stepsCompleted: [1, 2, 3, 4, 5, 6, 7, 8]
status: 'complete'
completedAt: '2025-12-15'
inputDocuments:
  - 'docs/prd.md'
  - 'docs/analysis/product-brief-dart-oracledb-2025-12-14.md'
  - 'docs/analysis/brainstorming-session-2025-12-14.md'
workflowType: 'architecture'
lastStep: 8
project_name: 'dart-oracledb'
user_name: 'Alex'
date: '2025-12-14'
lastRevised: '2026-06-13'
revisions:
  - date: '2026-06-13'
    summary: 'Added Post-1.0 Architecture Decisions: full design for Epic 8 (streaming / OracleResultSet, unified fetch engine) and Epic 10 (non-AL32UTF8 + national charset), plus pattern-mapping notes for the supporting epics 9, 11–15 and cross-cutting notes (shared lazy-handle lifecycle, scalar-codec recipe, fail-loud convergence). The shipped-1.0 sections above are unchanged and remain the release baseline.'
    inputs:
      - '_bmad-output/planning-artifacts/sprint-change-proposal-2026-06-13.md'
      - '_bmad-output/planning-artifacts/post-1-0-future-enhancements.md'
      - '_bmad-output/planning-artifacts/prd.md'
      - '_bmad-output/planning-artifacts/epics.md'
    decisions:
      epic8_api: 'OracleResultSet + executeStream()/queryStream() (Stream built on ResultSet)'
      epic8_engine: 'Unify: eager execute() reimplemented as a full drain of the ResultSet fetch engine'
      epic10_national: 'Include NCHAR/NVARCHAR2/NCLOB on AL16UTF16 (ncharset 2000) with fail-loud on unsupported configs'
---

# Architecture Decision Document

_This document builds collaboratively through step-by-step discovery. Sections are appended as we work through each architectural decision together._

## Project Context Analysis

### Requirements Overview

**Functional Requirements:**
44 requirements spanning connection management, pooling, query execution, transactions, PL/SQL, data types, and error handling. The requirements closely mirror node-oracledb thin driver capabilities, enabling structural fidelity during porting.

**Non-Functional Requirements:**
14 requirements covering performance (driver overhead, caching), security (credential protection, TLS, secure auth), reliability (connection health, pool recovery), and compatibility (Dart 3.12+, cross-platform, JIT/AOT).

**Scale & Complexity:**

- Primary domain: Backend library (database driver SDK)
- Complexity level: High technical / Low domain
- Estimated architectural components: ~8-10 major modules

### Technical Constraints & Dependencies

- **Pure Dart**: No native/FFI dependencies - all protocol handling in Dart
- **dart:io Socket**: Supports native Dart platforms (macOS, Windows, Linux, Android, iOS); excludes web.
- **Crypto Libraries**: pointycastle for authentication crypto
- **Reference Implementation**: node-oracledb thin driver structure
- **Target Databases**: Oracle 23ai (primary, FAST_AUTH path) and pre-23 Oracle 12c+ (supported via classical AUTH_PHASE_ONE/TWO fallback). Auth path selected from the server-advertised `TNS_ACCEPT_FLAG_FAST_AUTH` bit, not by version-string parsing.

### Cross-Cutting Concerns Identified

1. **Protocol Encoding**: Endianness handling across all message types
2. **Error Propagation**: Oracle error codes surfaced through all layers
3. **Resource Management**: Connection lifecycle, pool cleanup, cursor handling
4. **Cryptographic Operations**: Authentication flows at connection layer
5. **Data Type Conversion**: Oracle ↔ Dart type mapping throughout

## Starter Template Evaluation

### Primary Technology Domain

**Backend library (SDK/driver)** - A pure Dart package implementing Oracle TNS/TTC wire protocol.

### Starter Options Considered

| Option | Description | Fit |
|--------|-------------|-----|
| `dart create -t package` | Standard Dart package template | Base structure only |
| Custom node-oracledb mirror | Match official driver organization | Full structural fidelity |

### Selected Approach: Custom Structure Mirroring node-oracledb

**Rationale for Selection:**

- PRD requires structural fidelity with node-oracledb for maintainability
- Enables easier upstream sync when Oracle updates the driver
- Clear mapping between JS and Dart files aids porting
- Dart conventions (snake_case files, `lib/src/`) applied on top of node-oracledb organization

**Initialization Command:**

```bash
dart create -t package dart_oracledb
```

Then reorganize to match the custom structure defined below.

### Architectural Decisions Provided by Structure

**Language & Runtime:**

- Pure Dart 3.12+
- No native/FFI dependencies
- JIT (development) + AOT (production) compatible

**Package Organization:**

- `lib/dart_oracledb.dart` - Single public export file
- `lib/src/` - All implementation code (private)
- Three-layer architecture: `transport/` → `protocol/` → public API

**Structural Mapping:**

| node-oracledb | dart_oracledb | Purpose |
|---------------|---------------|---------|
| `lib/thin/sqlnet/` | `lib/src/transport/` | TNS network layer |
| `lib/thin/protocol/` | `lib/src/protocol/` | TTC message layer |
| `lib/thin/protocol/messages/` | `lib/src/protocol/messages/` | Message types |
| `lib/connection.js` | `lib/src/connection.dart` | Connection API |
| `lib/pool.js` | `lib/src/pool.dart` | Pool API |

**Development Experience:**

- Standard Dart tooling (`dart test`, `dart analyze`, `dart doc`)
- Integration tests against Oracle 23ai Docker (primary) and `gvenzl/oracle-xe:21` Docker (pre-23 fallback path) — both wired into CI as `integration` and `integration-21c` jobs
- Cross-platform CI (macOS, Windows, Linux)

**Note:** Project initialization using `dart create` should be the first implementation story, followed by directory restructuring.

## Core Architectural Decisions

### Decision Priority Analysis

**Critical Decisions (Block Implementation):**

- Connection API pattern
- Error handling strategy
- Bind parameter syntax
- Type mapping approach

**Important Decisions (Shape Architecture):**

- Result set access pattern
- Async patterns (Future vs Stream)
- Pool and transaction APIs
- Testing strategy

**Deferred Decisions (Post-MVP):**

- `fetchAsDecimal` option for high-precision NUMBER
- Streaming cursor optimization
- Custom type codec registration

### Public API Design

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Connection API** | `OracleConnection.connect(connString, user:, password:)` | Simple factory, matches PRD examples |
| **Result access** | `row['name']` and `row[0]` via operator `[]` | Flexible, familiar to Dart developers |
| **Async pattern** | `execute()` → Future, `executeStream()` → Stream | Both patterns for different result sizes |
| **Bind parameters** | Oracle native: `:name` (Map), `:1` (List) | Full Oracle SQL compatibility |

### Error Handling

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Exception type** | Single `OracleException` class | Simple, Oracle errors queryable via `errorCode` |
| **Error codes** | `errorCode` property (ORA-xxxxx) | Direct Oracle error passthrough per PRD |
| **Message** | `message` property with full Oracle message | Clear debugging information |

### Resource Management

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Pool acquire** | Both: `acquire()`/`release()` + `withConnection()` | Explicit control + safe convenience |
| **Transactions** | Both: `commit()`/`rollback()` + `runTransaction()` | Oracle-native + safe wrapper |

### Type System

| Oracle Type | Dart Type | Notes |
|-------------|-----------|-------|
| VARCHAR2, CHAR | `String` | Direct mapping |
| NUMBER | `num` (`int`/`double`) | `fetchAsDecimal` option post-MVP |
| DATE, TIMESTAMP | `DateTime` | Standard Dart datetime |
| CLOB | `String` | Full content as string |
| BLOB, RAW | `Uint8List` | Binary data |
| JSON | `Map`/`List` | Decoded JSON |

### Testing & Documentation

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Testing strategy** | Integration-first against Oracle 23ai Docker + Comprehensive unit tests | Real database validation over mocks, with protocol-layer unit tests |
| **Test architecture** | Epic 6: Test Architecture & Coverage | Dedicated epic establishes test standards, validates Epic 1 authentication protocol, ensures Epic 2+ foundation |
| **Test coverage requirements** | Unit tests for protocol layers (transport, TTC, crypto), Integration tests covering Oracle 23ai-specific behaviors (FAST_AUTH, hex crypto, edge cases) | Validates discovered protocol details from Stories 1-4-FIX and 1-8-FIX |
| **CI/CD integration** | Automated integration tests against Oracle 23ai in CI pipeline | Continuous validation of protocol compatibility |
| **Documentation** | README + dartdoc | Standard Dart: quickstart in README, API via dartdoc |

### Decision Dependencies

```text
Connection API ─────► Pool API ─────► withConnection()
      │                  │
      ▼                  ▼
  execute() ────► Result/Row ────► Type Mapping
      │
      ▼
  Bind Params ──► Oracle native :name/:1 syntax
      │
      ▼
  Error Handling ──► OracleException with errorCode
```

## Implementation Patterns & Consistency Rules

### Pattern Categories Defined

**8 critical conflict points** identified and resolved to ensure AI agents write consistent, compatible code.

### Naming Patterns

**Dart Standard Conventions:**

| Element | Convention | Example |
|---------|------------|---------|
| Files | `snake_case.dart` | `oracle_connection.dart` |
| Classes | `PascalCase` | `OracleConnection` |
| Methods | `camelCase` | `executeQuery()` |
| Constants | `lowerCamelCase` | `tnsPacketConnect` |
| Private members | `_prefixed` | `_socket`, `_isConnected` |

**All AI Agents MUST:** Follow `dart analyze` rules - no exceptions.

### Structure Patterns

**Constants Organization:**

- Single `lib/src/constants.dart` file contains all protocol constants
- Mirrors node-oracledb `constants.js` structure
- Group by domain with comments (TNS, TTC, Oracle Types)

**Test Organization:**

- Test structure mirrors `lib/src/` exactly
- `lib/src/protocol/packet.dart` → `test/src/protocol/packet_test.dart`
- All test files use `_test.dart` suffix

### Protocol Patterns

**Buffer/Byte Order Handling:**

```dart
// CORRECT - Endianness explicit in method name
final value = buffer.readUint16BE();
buffer.writeUint32LE(value);

// WRONG - Ambiguous
final value = buffer.readUint16();  // Which endian?
```

**Wrapper methods required:**

- `readUint16BE()`, `readUint32BE()`, `readUint64BE()`
- `writeUint16BE()`, `writeUint32BE()`, `writeUint64BE()`
- `*LE()` variants for little-endian

### Error Handling Patterns

**Error Propagation with Context:**

```dart
// CORRECT - Wrap with cause for debugging
try {
  await transport.send(packet);
} catch (e) {
  throw OracleException(
    errorCode: 12170,
    message: 'TNS connection lost',
    cause: e,  // Preserve original error
  );
}

// WRONG - Lose original error context
try {
  await transport.send(packet);
} catch (e) {
  throw OracleException(errorCode: 12170, message: 'TNS connection lost');
}
```

### Resource Management Patterns

**Dual Pattern Required:**

```dart
// Pattern 1: Explicit close (always available)
final conn = await OracleConnection.connect(...);
try {
  await conn.execute('SELECT ...');
} finally {
  await conn.close();
}

// Pattern 2: Auto-close wrapper (convenience)
await pool.withConnection((conn) async {
  await conn.execute('SELECT ...');
});  // Auto-closed
```

**All resources MUST have:** Both explicit `close()` and auto-close wrapper where applicable.

### Logging Patterns

**Use `package:logging`:**

```dart
import 'package:logging/logging.dart';

final _log = Logger('OracleConnection');

// Usage
_log.fine('Connecting to $host:$port');
_log.warning('Connection timeout, retrying...');
_log.severe('Authentication failed', error, stackTrace);
```

**Log levels:**

- `fine` - Protocol details (debug)
- `info` - Connection lifecycle events
- `warning` - Recoverable issues
- `severe` - Errors with stack traces

### Documentation Patterns

**Dartdoc Public APIs Only:**

```dart
/// Connects to an Oracle database.
///
/// The [connectionString] should be in EZ Connect format: `host:port/service`.
///
/// Throws [OracleException] if connection fails.
static Future<OracleConnection> connect(
  String connectionString, {
  required String user,
  required String password,
}) async { ... }
```

**Internal code:** Minimal comments, self-documenting names preferred.

### Enforcement Guidelines

**All AI Agents MUST:**

1. Run `dart analyze` with zero warnings before completing any task
2. Follow naming conventions exactly as specified
3. Use explicit endianness in all buffer operations
4. Preserve error context via `cause` parameter
5. Provide both explicit and auto-close resource patterns
6. Use `package:logging` for all diagnostic output

**Pattern Verification:**

- `dart analyze` enforces Dart conventions
- Code review checks protocol patterns
- Integration tests verify error propagation

## Project Structure & Boundaries

### Requirements to Structure Mapping

| FR Category | Requirements | Target Location |
|-------------|--------------|-----------------|
| **Connection Management** | FR1-FR6 | `lib/src/connection.dart`, `lib/src/transport/` |
| **Connection Pooling** | FR7-FR12 | `lib/src/pool.dart` |
| **Query Execution** | FR13-FR21 | `lib/src/connection.dart`, `lib/src/cursor.dart` |
| **Transaction Management** | FR22-FR24 | `lib/src/connection.dart` |
| **PL/SQL Execution** | FR25-FR29 | `lib/src/connection.dart` |
| **Data Type Handling** | FR30-FR39 | `lib/src/types.dart`, `lib/src/protocol/` |
| **Error Handling** | FR40-FR43 | `lib/src/errors.dart` |
| **Statement Caching** | FR44-FR45 | `lib/src/statement_cache.dart` |

### Complete Project Directory Structure

```text
dart_oracledb/
├── .github/
│   └── workflows/
│       └── ci.yml                      # Cross-platform CI (macOS, Windows, Linux)
├── example/
│   └── example.dart                    # Basic usage examples
├── lib/
│   ├── dart_oracledb.dart              # Public API exports only
│   └── src/
│       ├── connection.dart             # OracleConnection class
│       ├── pool.dart                   # OraclePool class
│       ├── cursor.dart                 # OracleCursor, result iteration
│       ├── result.dart                 # OracleResult, OracleRow classes
│       ├── lob.dart                    # LOB handling (CLOB/BLOB)
│       ├── db_object.dart              # DB Objects (future)
│       ├── statement_cache.dart        # Statement caching
│       ├── types.dart                  # Oracle ↔ Dart type mapping
│       ├── errors.dart                 # OracleException
│       ├── constants.dart              # All protocol constants
│       │
│       ├── protocol/                   # TTC Protocol layer
│       │   ├── buffer.dart             # Buffer with BE/LE methods
│       │   ├── capabilities.dart       # Protocol capabilities negotiation
│       │   ├── constants.dart          # TTC-specific constants
│       │   ├── packet.dart             # TTC packet framing
│       │   ├── protocol.dart           # Protocol orchestration
│       │   └── messages/
│       │       ├── base.dart           # Base message class
│       │       ├── auth_message.dart   # AUTH_PHASE_ONE, AUTH_PHASE_TWO
│       │       ├── execute_message.dart # EXECUTE, REEXECUTE
│       │       ├── fetch_message.dart  # FETCH
│       │       ├── commit_message.dart # COMMIT
│       │       ├── rollback_message.dart # ROLLBACK
│       │       ├── ping_message.dart   # PING
│       │       └── lob_message.dart    # LOB operations
│       │
│       ├── transport/                  # TNS Network layer
│       │   ├── socket.dart             # TCP socket wrapper
│       │   ├── tls.dart                # TLS/SSL handling
│       │   ├── transport.dart          # Transport abstraction
│       │   ├── packet.dart             # TNS packet types
│       │   └── connect_string.dart     # EZ Connect parsing
│       │
│       └── crypto/                     # Authentication
│           ├── auth.dart               # Auth flow coordination
│           ├── session_key.dart        # Session key derivation
│           └── verifier.dart           # SHA512/PBKDF2 verifiers
│
├── test/
│   └── src/
│       ├── connection_test.dart
│       ├── pool_test.dart
│       ├── cursor_test.dart
│       ├── result_test.dart
│       ├── types_test.dart
│       ├── errors_test.dart
│       ├── protocol/
│       │   ├── buffer_test.dart
│       │   ├── packet_test.dart
│       │   └── messages/
│       │       ├── auth_message_test.dart
│       │       ├── execute_message_test.dart
│       │       └── fetch_message_test.dart
│       ├── transport/
│       │   ├── socket_test.dart
│       │   └── connect_string_test.dart
│       └── crypto/
│           ├── auth_test.dart
│           └── verifier_test.dart
│
├── pubspec.yaml                        # Package definition
├── analysis_options.yaml               # Dart analyzer config
├── README.md                           # Quickstart, examples
├── CHANGELOG.md                        # Version history
├── LICENSE                             # BSD-3-Clause
└── docker-compose.yml                  # Oracle 23ai for testing
```

### Architectural Boundaries

**Layer Boundaries:**

```text
┌─────────────────────────────────────────────────────────────┐
│                      PUBLIC API                              │
│  dart_oracledb.dart exports:                                │
│  - OracleConnection, OraclePool, OracleResult, OracleRow    │
│  - OracleException                                          │
├─────────────────────────────────────────────────────────────┤
│                   APPLICATION LAYER                          │
│  connection.dart, pool.dart, cursor.dart, result.dart       │
│  - Uses protocol layer for database operations              │
│  - Manages resources (connections, cursors)                 │
├─────────────────────────────────────────────────────────────┤
│                    PROTOCOL LAYER                            │
│  protocol/*.dart, protocol/messages/*.dart                  │
│  - TTC message encoding/decoding                            │
│  - Uses transport layer for network I/O                     │
├─────────────────────────────────────────────────────────────┤
│                    TRANSPORT LAYER                           │
│  transport/*.dart                                           │
│  - TNS packet framing                                       │
│  - TCP socket management, TLS                               │
├─────────────────────────────────────────────────────────────┤
│                     CRYPTO LAYER                             │
│  crypto/*.dart                                              │
│  - Authentication (used by protocol layer)                  │
│  - Session key derivation                                   │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow

```text
User Code
    │
    ▼
OracleConnection.execute(sql, params)
    │
    ▼
Protocol.sendExecute() ──► ExecuteMessage.encode()
    │
    ▼
Transport.send(packet) ──► TnsPacket.wrap()
    │
    ▼
Socket.write(bytes)
    │
    ▼
[Oracle Database]
    │
    ▼
Socket.read(bytes)
    │
    ▼
Transport.receive() ──► TnsPacket.unwrap()
    │
    ▼
Protocol.receiveResponse() ──► Message.decode()
    │
    ▼
OracleResult with OracleRow[]
    │
    ▼
User Code
```

### Integration Points

| Boundary | Communication Pattern |
|----------|----------------------|
| **Public → Application** | Direct method calls, Future/Stream returns |
| **Application → Protocol** | Message objects passed down, decoded data returned |
| **Protocol → Transport** | Raw bytes passed down, raw bytes returned |
| **Protocol → Crypto** | Auth data passed, encrypted data returned |

## Architecture Validation Results

### Coherence Validation

**Decision Compatibility:**
All technology choices (Pure Dart, pointycastle, package:logging) are compatible and work together without conflicts. No version incompatibilities detected.

**Pattern Consistency:**
Implementation patterns (naming, buffer handling, error propagation, resource management) consistently support architectural decisions. All patterns align with Dart conventions.

**Structure Alignment:**
Project structure fully supports the three-layer architecture with clear boundaries between transport, protocol, and public API layers.

### Requirements Coverage Validation

**Functional Requirements Coverage:**
All 44 functional requirements have explicit architectural support with clear mapping to specific files and modules.

**Non-Functional Requirements Coverage:**
All 14 NFRs addressed: performance (caching, pooling), security (TLS, crypto, no credential logging), reliability (connection health, cleanup), compatibility (Dart 3.12+, cross-platform).

### Implementation Readiness Validation

**Decision Completeness:**
10 core architectural decisions documented with rationale, examples, and explicit patterns for AI agents to follow.

**Structure Completeness:**
Complete project tree with ~35 files defined across 4 layers plus tests. All integration points and boundaries clearly specified.

**Pattern Completeness:**
8 pattern categories defined with concrete examples, including anti-patterns to avoid.

### Gap Analysis Results

**Critical Gaps:** None - architecture is implementation-ready

**Minor Gaps (addressed during implementation):**

- CI/CD workflow specifics
- docker-compose.yml Oracle 23ai configuration
- Final pubspec.yaml dependency versions

### Architecture Completeness Checklist

**Requirements Analysis**

- [x] Project context thoroughly analyzed
- [x] Scale and complexity assessed (High technical / Low domain)
- [x] Technical constraints identified (Pure Dart, no FFI)
- [x] Cross-cutting concerns mapped (5 concerns)

**Architectural Decisions**

- [x] Critical decisions documented (10 decisions)
- [x] Technology stack fully specified
- [x] Integration patterns defined (layer boundaries)
- [x] Performance considerations addressed (pooling, caching)

**Implementation Patterns**

- [x] Naming conventions established (Dart standard)
- [x] Structure patterns defined (constants, tests)
- [x] Communication patterns specified (layer boundaries)
- [x] Process patterns documented (error, resource, logging)

**Project Structure**

- [x] Complete directory structure defined (~35 files)
- [x] Component boundaries established (5 layers)
- [x] Integration points mapped (data flow diagram)
- [x] Requirements to structure mapping complete

### Architecture Readiness Assessment

**Overall Status:** READY FOR IMPLEMENTATION

**Confidence Level:** High

**Key Strengths:**

- Clear structural fidelity with node-oracledb for maintainability
- Comprehensive pattern definitions prevent AI agent conflicts
- All 58 requirements (44 FR + 14 NFR) have architectural support
- Layer boundaries enable independent development of components

**Areas for Future Enhancement:**

- `fetchAsDecimal` option for high-precision NUMBER (post-MVP)
- Custom type codec registration (post-MVP)
- Advanced LOB streaming (post-MVP)

### Implementation Handoff

**AI Agent Guidelines:**

- Follow all architectural decisions exactly as documented
- Use implementation patterns consistently across all components
- Respect project structure and boundaries
- Refer to this document for all architectural questions
- Run `dart analyze` with zero warnings before completing any task

**First Implementation Priority:**

```bash
dart create -t package dart_oracledb
```

Then restructure directories to match the defined project structure.

## Architecture Completion Summary

### Workflow Completion

| Item | Status |
|------|--------|
| Architecture Decision Workflow | COMPLETED |
| Total Steps Completed | 8 |
| Date Completed | 2025-12-15 |
| Document Location | docs/architecture.md |

### Final Architecture Deliverables

**Complete Architecture Document**

- All architectural decisions documented with specific versions
- Implementation patterns ensuring AI agent consistency
- Complete project structure with all files and directories
- Requirements to architecture mapping
- Validation confirming coherence and completeness

**Implementation Ready Foundation**

- 10 architectural decisions made
- 8 implementation patterns defined
- 5 architectural layers specified
- 58 requirements fully supported (44 FR + 14 NFR)

**AI Agent Implementation Guide**

- Technology stack with verified versions
- Consistency rules that prevent implementation conflicts
- Project structure with clear boundaries
- Integration patterns and communication standards

### Development Sequence

1. Initialize project: `dart create -t package dart_oracledb`
2. Restructure directories to match architecture
3. Set up dependencies in pubspec.yaml
4. Implement transport layer (TNS)
5. Implement protocol layer (TTC)
6. Implement public API (connection, pool, result)
7. Add integration tests against Oracle 23ai

### Quality Assurance

**Architecture Coherence**

- [x] All decisions work together without conflicts
- [x] Technology choices are compatible
- [x] Patterns support the architectural decisions
- [x] Structure aligns with all choices

**Requirements Coverage**

- [x] All functional requirements are supported
- [x] All non-functional requirements are addressed
- [x] Cross-cutting concerns are handled
- [x] Integration points are defined

**Implementation Readiness**

- [x] Decisions are specific and actionable
- [x] Patterns prevent agent conflicts
- [x] Structure is complete and unambiguous
- [x] Examples are provided for clarity

---

## Oracle 23ai Protocol Implementation Notes

### FAST_AUTH Protocol (Required for Oracle 23ai)

Oracle 23ai requires the **FAST_AUTH protocol** (message type 34) for authentication. This protocol combines Protocol Negotiation + Data Types Negotiation + AUTH_PHASE_ONE into a single message to reduce round trips.

**Implementation:**
- Location: `lib/src/protocol/messages/fast_auth_message.dart`
- Used by: `lib/src/transport/transport.dart` → `sendFastAuth()`
- Reference: node-oracledb `lib/thin/protocol/messages/fastAuth.js`

**Key Differences from Standalone Auth:**
- Protocol and DataTypes messages embedded WITHOUT their message type bytes
- AUTH_PHASE_ONE embedded WITH its full function header
- Single TNS DATA packet contains all three messages (typically ~2780 TTC bytes)

### Oracle 12c Authentication Crypto Format

**Critical Discovery:** Oracle 12c expects ALL cryptographic values as **hex-encoded STRINGS** (uppercase), not raw bytes.

**Affected Values:**
1. **AUTH_SESSKEY**: Encrypted client session key
   - Format: 64 hex characters (= 32 bytes)
   - Implementation: Encrypt sessionKeyPartb, convert to hex, slice to 64 chars, store as UTF-8 string bytes
   - Location: `lib/src/crypto/auth.dart` lines 223-227

2. **AUTH_PBKDF2_SPEEDY_KEY**: Speedy key for 12c verifier
   - Format: 160 hex characters (= 80 bytes)
   - Implementation: Encrypt speedyKeyInput, take first 80 bytes, convert to hex (160 chars), store as UTF-8
   - Location: `lib/src/crypto/auth.dart` lines 262-266

3. **AUTH_PASSWORD**: Encrypted password proof
   - Format: Variable length hex string (uppercase)
   - Implementation: Add 16-byte random salt prefix, encrypt, convert to hex, store as UTF-8
   - Location: `lib/src/crypto/auth.dart` lines 268-286

**Why This Matters:**
- Sending raw bytes causes Oracle to reject AUTH_PHASE_TWO with connection close
- Protocol structure can be byte-perfect (571 bytes) but still fail if crypto values are wrong format
- Reference: node-oracledb `lib/thin/protocol/encryptDecrypt.js` lines 105-174

### Password Handling

**Oracle 12c Password Rules:**
- ✅ **DO NOT uppercase the password** - use UTF-8 bytes as-is
- ✅ Add 16-byte random salt prefix before encryption (security requirement)
- ✅ Use PBKDF2-SHA512 for key derivation (4096+ iterations)
- ❌ Do NOT use Oracle 11g behavior (uppercasing, SHA1)

**Session Key Derivation:**
- sessionKeyPartb length MUST match sessionKeyParta length (decrypted from server's AUTH_SESSKEY)
- For Oracle 12c: typically 32 bytes
- For Oracle 11g: typically 48 bytes
- Implementation handles both cases based on decrypted length

### Known Issues & Gotchas

1. **Wrong Password Handling (RESOLVED - 2025-12-16)**

   **Issue:** When authentication fails due to wrong password, Oracle 23ai closes the connection silently without sending any response packet.

   **Investigation Results (2025-12-16):**
   - Confirmed with test runs: Oracle 23ai closes connection silently after receiving AUTH_PHASE_TWO with invalid credentials
   - No REFUSE packet (type 4) received
   - No error DATA packet received
   - Client's `socket.read()` waits indefinitely for data that never arrives
   - Previously timed out after 30 seconds with correct ORA-01017 error

   **Solution Implemented:**
   - Added `authTimeout` parameter to `AuthFlow.authenticate()` (default: 5 seconds)
   - Applied timeout specifically to AUTH_PHASE_TWO response wait at [auth.dart:409](lib/src/crypto/auth.dart#L409)
   - On timeout, throws OracleException with errorCode 1017 (oraInvalidCredentials)
   - Error message: "Authentication failed: invalid username or password"
   - Password never exposed in error messages (NFR5 compliant)

   **Current Behavior:**
   - Wrong password detected within 5 seconds (was 30 seconds)
   - Clear error message with ORA-01017 code
   - Valid credentials unaffected - normal authentication flow works perfectly
   - Test coverage: [test_wrong_password.dart](../test/integration/test_wrong_password.dart) validates timing and error handling

   **Impact:** Resolved - Developers now get immediate feedback (5s) on wrong password instead of waiting 30s. Still provides rate-limiting against brute force attacks.

2. **MARKER Packets**: Oracle may send MARKER packets (type 12) during authentication - these must be skipped to read the next packet
   - Location: `lib/src/transport/transport.dart` lines 1177-1184

3. **Sequence Counter**: Must be auto-incrementing across all TTC messages
   - FAST_AUTH: sequence=1
   - AUTH_PHASE_TWO: sequence=2
   - Implementation: `transport.nextSequence()` method

4. **Data Flags for AUTH_PHASE_TWO**: Must use `dataFlags=0x0800` (END_OF_REQUEST marker)
   - Location: `lib/src/crypto/auth.dart` line 352

### Testing Against Oracle 23ai

**Docker Setup:**
```bash
docker-compose up -d  # Starts Oracle 23ai Free container
```

**Integration Tests:**
```bash
RUN_INTEGRATION_TESTS=true dart test test/integration/
```

**Packet Capture for Debugging:**
- Use Wireshark with filter: `tcp.port == 1521`
- Compare with node-oracledb reference implementation
- Debug utilities in project root: `compare_auth_phase_two.cjs`, etc.

### References

- Oracle 23ai Protocol: Documented through reverse-engineering and node-oracledb source analysis
- node-oracledb thin driver: `reference/node-oracledb/lib/thin/`
- Story 1.4-FIX: `docs/sprint-artifacts/1-4-fix-authentication-protocol-debugging.md` (complete implementation notes)

---

# Post-1.0 Architecture Decisions (v1.1+)

_Added 2026-06-13 to support the post-1.0 roadmap (Epics 8–15) defined in
`_bmad-output/planning-artifacts/sprint-change-proposal-2026-06-13.md` and
`post-1-0-future-enhancements.md`. The **two epics flagged "architecture review
required"** (Epic 8, Epic 10) get a **full design**. Epics 9, 11–15 build on
already-documented patterns (data-type codecs, bind handling, LOB values,
statement cache) and get **pattern-mapping notes** (extension points + resolved
design choices) so `create-story` is grounded — they need no separate
architecture pass._

> **Relationship to the 1.0 architecture above:** This section is **additive**.
> The sections above describe the shipped 1.0 release and remain the baseline.
> Where a 1.0 decision is *extended* (the fetch loop, the in-flight invariant,
> the charset negotiation) that is called out explicitly below.
>
> **Known stale framing (not addressed in this pass — out of scope for the
> post-1.0 request):** the 1.0 sections still describe auth/testing as
> "23ai / FAST_AUTH-centric." The driver is now **server-driven dual-path**
> (FAST_AUTH *and* classical AUTH_PHASE_ONE/TWO, full Oracle 21c support). The
> authoritative description lives in `_bmad-output/project-context.md` and
> `CLAUDE.md`. All post-1.0 work below targets **both** Oracle 23ai (FAST_AUTH)
> and Oracle 21c (classical) per the project Definition of Done.

## Scope of this revision

| Epic | Architecture review? | Covered here |
|------|----------------------|--------------|
| **Epic 8 — Streaming & Incremental Result Consumption** | **Required** | ✅ Full design below |
| **Epic 10 — Non-AL32UTF8 + National Charset** | **Required** | ✅ Full design below |
| Epic 9 — REF CURSOR & Implicit Results | No (builds on Epic 8 `OracleResultSet`) | ✅ Pattern mapping below |
| Epic 11 — Bulk DML (`executeMany`) | No | ✅ Pattern mapping below |
| Epic 12 — LOB Streaming & Temp LOBs | No (extends Epic 4) | ✅ Pattern mapping below |
| Epic 13 — JSON / OSON Parity | No (extends existing `oson.dart`) | ✅ Pattern mapping below |
| Epic 14 — Temporal & Fetch Type Handlers | No (extends Epic 4 / Story 7.9) | ✅ Pattern mapping below |
| Epic 15 — Extended Data Types | No | ✅ Pattern mapping below |

---

## Epic 8 — Streaming & Incremental Result Consumption

### Current baseline (what already exists — confirmed against code)

The protocol layer is **already incremental**; only the public surface and the
materialization policy are missing.

- The TTC layer already fetches in batches: `prefetchRows` (default 50) seeds the
  first batch with `EXECUTE`, and `_sendFetch()` is looped for more rows
  (`lib/src/transport/transport.dart` ~L610-642). FETCH reuses the execute
  pipeline with function code `ttcFuncFetch`; there is **no** separate
  `fetch_message.dart`.
- The eager hot path **auto-drains** every batch into `OracleResult._rows`
  before returning, bounded by a safety cap of **1,000 FETCH iterations**
  (`_defaultMaxFetchIterations`, `transport.dart` ~L382).
- `OracleResult` already exposes `moreRowsAvailable` (`lib/src/result.dart`
  ~L109) — the "incomplete result set" concept is half-built.
- The **one-in-flight-operation-per-connection invariant already exists** as the
  `_executeInProgress` boolean (`lib/src/connection.dart` ~L89, guarded
  ~L403-412). It currently scopes a *single `execute()` call*.
- The statement cache pins entries via `inUse` and queues evicted cursor IDs for
  piggyback close via `_cursorsToClose` (`lib/src/statement_cache.dart` ~L140,
  L183).

**Implication:** Epic 8 is *expose + extend*, not *build from scratch*. The risk
is concentrated in the unify-on-ResultSet refactor of the eager path, not in the
fetch mechanics.

### Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Public API surface** | `OracleResultSet` (cursor object) **and** `executeStream()`/`queryStream()` returning `Stream<OracleRow>` built on top of it | Mirrors node-oracledb thin (`getRow`/`getRows`/`close` + `queryStream`); serves both pull-based batching and idiomatic Dart `await for` consumers from one engine |
| **Fetch engine** | **Unify** — a single internal lazy cursor engine. Eager `execute()` is reimplemented as "open the engine, drain it fully, build `OracleResult`, close" | One fetch implementation, no duplicated batch/cap logic. Accepted trade-off: the shipped 1.0 hot path is rewritten and must be **fully re-validated on 23ai and 21c** |
| **In-flight ownership** | A `Stream`/`OracleResultSet` **holds the connection's single in-flight slot for its entire lifetime** (open → close/drain/cancel), not for one call | A live cursor multiplexes the same TTC byte stream; a second operation would corrupt cursor IDs and the sequence counter |
| **Early cancellation** | Cancelling a stream subscription or calling `OracleResultSet.close()` before drain **closes the server cursor** and frees the in-flight slot; the connection stays reusable | Required by AC 8.4; avoids leaking server cursors |
| **Statement-cache safety** | An open streamed cursor **pins** its cache entry (`inUse = true`); it cannot be evicted or piggyback-closed until the ResultSet closes | Prevents closing a cursor that is mid-fetch (AC 8.5) |
| **`fetchSize`** | Per-call override of `prefetchRows`; default unchanged (50). Streaming has **no** 1,000-iteration cap | The cap exists to bound *accidental* full materialization; streaming is intentionally unbounded |
| **Eager `execute()` external behavior** | **Unchanged** — same `OracleResult`, same `moreRowsAvailable`, same 1,000-cap safety bound on the drain | Backward compatibility for shipped 1.0 callers despite the internal rewrite |

### The unified fetch engine (core design)

```text
                ┌──────────────────────────────────────────┐
                │  _ResultSetCursor  (internal, lazy)        │
                │  - cursorId, columnMetadata                │
                │  - prefetched-row buffer, moreRowsToFetch  │
                │  - pinned StatementCacheEntry (inUse)      │
                │  - owns the connection in-flight slot      │
                │  fetchNext(n) -> List<OracleRow>           │
                │  close()      -> close server cursor       │
                └──────────────────────────────────────────┘
                    ▲                    ▲                    ▲
   executeStream()  │   OracleResultSet  │   execute() (eager)│
   queryStream()    │   (public wrapper) │   = open + drain   │
   = Stream<OracleRow> over fetchNext    │     + close        │
                                          │
   public: getRow() / getRows([n]) / close() / columns
```

- **`_ResultSetCursor`** (internal, new — likely `lib/src/protocol/result_set_cursor.dart`)
  is the single lazy engine. It wraps the existing prefetch + `_sendFetch()`
  mechanics from `transport.dart`, but **yields batches** instead of draining.
- **`OracleResultSet`** (public, new — `lib/src/result_set.dart`) wraps the
  cursor: `Future<OracleRow?> getRow()`, `Future<List<OracleRow>> getRows([int n])`,
  `Future<void> close()`, plus `columns`/`columnNames` metadata (available before
  the first row, per AC).
- **`executeStream()` / `queryStream()`** (new, on `OracleConnection`) return
  `Stream<OracleRow>`. On `listen`, pull `getRows(fetchSize)` batches; on `cancel`,
  call `close()`. Implement as an async generator or a controller that maps the
  ResultSet — the Stream owns and closes the underlying ResultSet.
- **`execute()`** (existing) is rewritten to: open a `_ResultSetCursor`, drain it
  (`fetchNext` until `!moreRowsToFetch`, bounded by the 1,000-iteration safety
  cap), assemble `OracleResult` (same shape, `moreRowsAvailable` set if the cap
  is hit), then `close()`. **External behavior identical to 1.0.**

### In-flight ownership & lifecycle invariants

The `_executeInProgress` guard is **promoted** from "inside one `execute()`" to
"a cursor is open on this connection":

- Acquired when a ResultSet/stream opens (or an eager `execute()` begins).
- Released only when the ResultSet/stream is closed, fully drained, or cancelled
  (eager `execute()` releases after its drain+close, as today).
- While held, any other `execute()` / `executeStream()` on the same connection
  must **fail fast** with the existing concurrent-operation `OracleException`
  (not queue) — same error already raised at `connection.dart` ~L403-412.

**Leak guard:** an unclosed `OracleResultSet`/stream wedges the connection. Pool
release (`acquire`/`release`, `withConnection`) **must close any open cursor and
clear the in-flight slot** on return-to-pool, and log a warning when it had to.
Document the contract loudly: *callers must `close()` (or fully drain) a
ResultSet; prefer `try/finally` or `await for` which auto-closes on completion.*

### Early cancellation & cursor cleanup

- `OracleResultSet.close()` (and stream `cancel`) with rows still pending **must
  close the server cursor**. Reuse the existing `_cursorsToClose` queue: enqueue
  the cursor and flush it — piggybacked on the next operation if one follows, or
  flushed during pool release if the connection goes idle. The connection's
  in-flight slot is freed immediately so the connection is reusable at once.
- Closing an already-drained/closed ResultSet is idempotent (no double-close RPC).

### Statement-cache interaction

- While a ResultSet is open, its `StatementCacheEntry.inUse` stays `true`; the LRU
  evictor must continue to *not* close in-use entries (it sets
  `returnToCache = false` instead) — extend the existing behavior so an in-use
  **streamed** entry is treated identically.
- `close()` releases the entry back to the cache (or queues the cursor for close
  if it was evicted while open). The 1,000-iteration cap applies **only** to the
  eager-drain path, never to streaming.

### Migration risk & validation (consequence of "Unify")

Because eager `execute()` is reimplemented on the new engine, this is the
highest-risk part of Epic 8:

- Treat Story **8.1** (`_ResultSetCursor` + `OracleResultSet`) and the
  **`execute()` re-implementation** as one reviewable unit; do not ship the
  engine swap and the streaming API in separate half-states.
- Full regression of the existing 1.0 query/PLSQL/LOB suites on **both 23ai and
  21c** is part of 8.1's done-criteria, in addition to new streaming tests.
- Keep `OracleResult`'s public shape byte-for-byte compatible (rows, metadata,
  `rowsAffected` nullability, `moreRowsAvailable`).

### Epic 9 note (REF CURSOR)

REF CURSOR OUT binds, nested cursors, and implicit results all **decode into the
same `OracleResultSet`** defined here — that is the entire reason Epic 9 depends
on Epic 8 and needs no separate architecture pass.

---

## Epic 10 — Non-AL32UTF8 Database Character Set Compatibility

### Current baseline (confirmed against code)

- Wire strings are hardcoded UTF-8: `buffer.dart` `writeString()` ~L354 /
  `readString()` ~L130 use `utf8.encode/decode`.
- Negotiation hardcodes charset **873** for **both** primary and national:
  `fast_auth_message.dart` ~L128-129 and the classical path
  `transport.dart` ~L2076-2077 both write `873 / 873`. Constant
  `ttcCharsetUtf8 = 873` / `defaultCharset = 873`.
- **No charset capability detection** — the server's DB/national charset is never
  read.
- National types are **hard-rejected**: `execute_message.dart` ~L1389-1396 throws
  on `csfrm == ttcCsfrmNChar`.
- Column decode uses `utf8.decode(bytes, allowMalformed: true)`
  (`execute_message.dart` ~L1322-1328).

### Core model decision — adopt node-oracledb thin charset model

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Primary wire charset** | **Keep UTF-8 (873).** The client always sends/receives primary char data as AL32UTF8; the **server converts** to/from the DB charset | This *is* the thin model. `buffer.dart`'s UTF-8 is **correct** and stays. Non-AL32UTF8 DB charsets are supported via server-side conversion, **not** a configurable client codec |
| **No client-side DB-charset codec** | Do **not** expose arbitrary Dart text encodings | Matches node-oracledb thin (which ignores the `NLS_LANG` charset component); avoids a large, fragile codec surface |
| **National wire charset** | Negotiate **AL16UTF16 (id 2000)** for national char data; add a UTF-16 codec for `csfrm == NChar` | Thin supports NCHAR via AL16UTF16; the current hardcoded `ncharset = 873` is wrong for national types |
| **National types** | Implement **NCHAR / NVARCHAR2 / NCLOB** decode/encode (remove the hard rejection) | Decision: include national types now (proposal AC 10.4) |
| **Capability detection** | Detect server DB charset + national charset at connect for **diagnostics + fail-loud**, not for wire selection | Lets us reject unsupported configs clearly instead of emitting mojibake |
| **Unsupported configs** | **Fail loud** with `OracleException` (e.g. national charset ≠ AL16UTF16, such as UTF8 national) — never silent corruption | AC 10.4 |

> **Reframing vs the proposal:** "revisit the `buffer.dart` UTF-8 assumption"
> resolves to **confirm it is correct for primary char data and keep it.** The
> real change is the **national** charset path (ncharset 2000 + a UTF-16 codec)
> plus detection and fail-loud — not making the primary wire charset
> configurable.

### National charset handling (NCHAR / NVARCHAR2 / NCLOB)

- Change national-charset negotiation from `873` → **`2000` (AL16UTF16)** in
  `fast_auth_message.dart`, the classical data-types message, and the connect
  path in `transport.dart`. Add a constant (e.g. `ttcCharsetAl16Utf16 = 2000`).
- Add a **UTF-16 string codec** alongside the UTF-8 path in `buffer.dart`:
  Oracle AL16UTF16 is **2-byte big-endian** code units. Decode via 16-bit BE code
  units → `String.fromCharCodes` (which handles surrogate pairs); encode the
  reverse. Keep it explicit and separate from `readString()/writeString()`
  (e.g. `readNString()/writeNString()`), consistent with the project's
  explicit-encoding rule.
- Route by **`csfrm`**: `csfrm == ttcCsfrmNChar (2)` → national (UTF-16) codec;
  otherwise the existing UTF-8 path. Apply on both **decode** (replace the throw
  at `execute_message.dart` ~L1389-1396) and **bind encode**.

### Charset capability detection

- During connect, capture the server **DB charset** and **national charset**
  (from negotiation metadata if exposed; otherwise lazily via
  `NLS_DATABASE_PARAMETERS` / `V$NLS_PARAMETERS` on first need). Store on the
  connection for diagnostics and the fail-loud checks. The wire stays UTF-8 /
  AL16UTF16 regardless — detection drives **errors and diagnostics only**.
- Surface enough charset/form info in column metadata to diagnose unsupported
  national-charset cases.

### Validation (the one infra addition)

- Add a **non-AL32UTF8 DB fixture** to CI (e.g. a DB created with a single-byte
  charset such as `WE8MSWIN1252` / `WE8ISO8859P1`) to prove VARCHAR2/CHAR/CLOB
  round-trip via server conversion. Gate it if it can't be made reliable, and
  `log()`/document the gap rather than silently skipping.
- National-type round-trip (NCHAR/NVARCHAR2/NCLOB on AL16UTF16) is validated on
  the standard fixtures.
- Per the project DoD, **all Epic 10 tests pass on both Oracle 23ai and Oracle
  21c**, written with `test_helper.dart` (no hardcoded connection params).

---

## Supporting post-1.0 epics (9, 11–15) — pattern mapping

These epics need **no new architecture pass** — each extends an established
pattern. The notes below give implementing agents the real extension points
(confirmed against current code) and resolve the small design choices so
`create-story` has a grounded starting point. All inherit the cross-cutting
notes and the Definition of Done at the end of this section.

### Epic 9 — REF CURSOR & Implicit Results

- **Today:** No cursor type is decoded — unknown oraTypes fall through to the
  `default` case and are silently consumed (`execute_message.dart` ~L1442). The
  implicit-resultset option flag `ttcExecOptionImplicitResultset` is **already
  always set** (`execute_message.dart` ~L225) but never consumed. `ExecuteResponse`
  holds a **single** `columnMetadata` + `rows` set.
- **Extends:** Epic 8's `OracleResultSet` / `_ResultSetCursor` — this is the
  whole reason Epic 9 depends on Epic 8.
- **Design notes:**
  - Add an `oraTypeCursor` constant (wire type per node-oracledb reference) and a
    decode case in `_decodeValueByOraType()` that reads the cursor descriptor and
    produces an `OracleResultSet` backed by the same lazy engine.
  - REF CURSOR OUT binds decode into `OracleResultSet` (not materialized rows);
    surface via the existing `OracleOutBinds`.
  - Extend `ExecuteResponse` to carry **multiple** result sets; expose implicit
    results on `OracleResult` (e.g. `implicitResults`), node-oracledb-parity name.
  - Each returned cursor is a server-backed handle → **inherits the in-flight /
    close discipline** (see cross-cutting notes).

### Epic 11 — Bulk DML (`executeMany`)

- **Today:** Single-execution only — `_numExecs` is hardwired to `1`
  (`execute_message.dart` ~L174). Array-bind constants (`ttcBindArray 0x0040`,
  `ttcBindUseIndicators`) exist but are unused. `rowsAffected` is scalar.
- **Extends:** the existing bind pipeline (`oracle_bind.dart`, `bind_parser.dart`,
  `ExecuteRequest.encode()`) and the statement cache.
- **Design notes:**
  - New `OracleConnection.executeMany(sql, rows, {options})` — `rows` is a list of
    bind sets (Map or List), parity with node-oracledb; reuse `_executeGuarded()`
    bind parsing/ordering.
  - `BindVariable` gains an array form (element count); `ExecuteRequest` drives the
    AL8I4 iteration count from it instead of a constant `1`.
  - Add `batchErrors` (per-row error collection) and `dmlRowCounts` (per-iteration
    affected counts); support **DML RETURNING** via array OUT binds.
  - Same one-in-flight guard as `execute()` (one batch op at a time per connection).

### Epic 12 — LOB Streaming & Temporary LOBs

- **Today:** CLOB/BLOB value support is complete but **single-round-trip** — the
  whole LOB is read at once (`transport.dart` `_readClobAsString`/`_readBlobAsBytes`
  ~L1174-1257), `LobLocator` is internal-only, and temp LOBs are created
  *implicitly* during bind encoding (invisible to callers). LOB op messages
  (READ/WRITE/CREATE_TEMP/FREE_TEMP) already exist (`lob_op_message.dart`).
- **Extends:** Epic 4's LOB value support + `lob_op_message.dart` / `lob_locator.dart`.
- **Design notes:**
  - New public `OracleLob` (`lib/src/oracle_lob.dart`) wrapping `LobLocator` +
    transport: `length`, chunked `read(offset, amount)` / `write(offset, data)`,
    `close()`. Refactor the internal single-read into a chunked `sendLobOp` loop.
  - Public temp-LOB creation: `createTemporaryClob()/createTemporaryBlob()`
    returning `OracleLob`; caller-managed lifecycle (free-temp on `close()`).
  - **Align the streaming surface with Epic 8's decision:** offer both a chunked
    pull (`read`) **and** a `Stream<List<int>>`/`Stream<String>` built on top —
    consistent with `OracleResultSet` + `executeStream()`.
  - A streamed/incremental LOB read is a server-backed handle → **inherits the
    in-flight / close / leak-guard discipline** (see cross-cutting notes). This is
    the one genuinely architectural point in Epic 12 and the reason it was kept
    out of Epic 4.

### Epic 13 — JSON / OSON Parity

- **Today:** Oracle **21c native JSON (OSON, type 119) is fully wired** — encode
  (`_writeOsonValue`) and decode (`decodeOson`) in `oson.dart` + `execute_message.dart`
  ~L1416-1441. **Missing:** the Oracle **12c JSON-as-BLOB** compatibility path
  (no fallback). The OSON decoder **fail-louds** on Oracle-specific embedded scalar
  nodes (date/timestamp/interval/binary-float-double/extended-VECTOR,
  `oson.dart` ~L688-710).
- **Extends:** the existing `oson.dart` codec.
- **Design notes:**
  - Add the 12c path: detect JSON-stored-as-BLOB (`IS JSON` / column metadata) and
    route through the OSON codec or text-JSON as appropriate per server version.
  - Optionally widen OSON embedded-scalar coverage (depends on Epic 14/15 codecs).
  - Bind/fetch already map to Dart `Map`/`List`; keep that contract.

### Epic 14 — Temporal Compatibility & Fetch Type Handlers

- **Today:** DATE/TIMESTAMP/TSTZ/TSLTZ decode correctly; **region-id TSTZ is
  hard-rejected** (`data_types.dart` ~L662-668, offset-based only). There is **no**
  fetch-as-string or fetch-type-handler infrastructure — decode is a pure
  `switch(oraType)`.
- **Extends:** Epic 4 / Story 7.9 temporal codecs (`data_types.dart`,
  `oracle_timestamp_tz.dart`).
- **Design notes:**
  - Region-id TSTZ: decode the `byte11 & 0x80` region form to a correct **UTC
    instant** (minimum), with documented limits on region-name preservation.
  - **Fetch type handler** is the one structural change: thread an optional
    per-column hook `(value, ColumnMetadata) -> Object?` (parity: returns
    type+converter) through `_decodeValueByOraType` → `_decodeColumnValue` →
    `ExecuteResponse` → transport decode. Carry it on the request/decode context so
    it survives multi-round FETCH. `fetchAsString` for dates/timestamps is a
    convenience built on the same hook.

### Epic 15 — Extended Data Type Completeness

- **Today:** `oraTypeRowid (11)` and `oraTypeURowid (104)` **constants exist but
  have no decode case** → they hit the `default` and **silently return `null`**.
  INTERVAL DS/YM and VECTOR have **no constants** and are likewise silently
  skipped.
- **Extends:** the scalar-codec pattern (see cross-cutting notes).
- **Design notes:**
  - Add INTERVAL DAY TO SECOND, INTERVAL YEAR TO MONTH (likely `OracleInterval*`
    wrapper types, mirroring `OracleTimestampTz`), ROWID/UROWID (String), and
    VECTOR (23ai; `List<double>` or a wrapper) via the repeatable recipe.
  - **Flip the silent `default` to fail-loud** once the known types are added, so a
    genuinely unknown column type raises `OracleException` instead of returning
    `null` — consistent with the project's fail-loud rules.

## Cross-cutting post-1.0 architecture notes

These apply across multiple epics and are the reason this revision exists as one
coherent pass rather than eight isolated changes.

1. **One lifecycle model for all lazy, server-backed handles.** `OracleResultSet`
   (Epic 8), REF CURSORs (Epic 9), and streamed/temp LOBs (Epic 12) are all
   handles that own a server resource and do incremental round-trips. They **all**
   share the same discipline: hold the connection's single in-flight slot for
   their lifetime, fail-fast any concurrent operation, close the server resource on
   `close()`/cancel, and be force-closed + warned on pool release. Implement this
   once (Epic 8) and reuse it.

2. **The scalar-type codec recipe (Epics 13/14/15).** Adding a scalar type is a
   fixed sequence: constant in `constants.dart` → encode/decode in `data_types.dart`
   → bind-encode case + define/bind buffer sizes in `execute_message.dart` →
   `decodeValueByOraType` case → `inferOraTypeForValue` → optional Dart wrapper type
   → unit + dual-env integration tests. Follow it uniformly.

3. **Fail-loud over silent null.** The decode `default` currently swallows unknown
   types. As post-1.0 types land, the contract should converge on: known type →
   decode; unsupported-but-recognized → explicit `OracleException`; never silent
   `null`/mojibake. (Epic 10 fail-loud, Epic 15 default flip, Epic 13/OSON
   fail-loud are all instances of this principle.)

## Post-1.0 structural additions (delta to the 1.0 file tree)

```text
lib/src/
├── result_set.dart                     # NEW (Epic 8) — public OracleResultSet (getRow/getRows/close)
├── connection.dart                     # CHANGED (Epic 8) — executeStream()/queryStream(); execute() rewired onto the engine; in-flight slot held for cursor lifetime
├── pool.dart                           # CHANGED (Epic 8) — release/withConnection closes any open cursor + clears in-flight slot
├── statement_cache.dart               # CHANGED (Epic 8) — pin in-use streamed cursors against eviction/close
├── protocol/
│   ├── result_set_cursor.dart          # NEW (Epic 8) — internal lazy fetch engine (prefetch + fetchNext batches)
│   ├── buffer.dart                     # CHANGED (Epic 10) — add explicit UTF-16 (AL16UTF16) readNString/writeNString; keep UTF-8 for primary
│   ├── constants.dart                  # CHANGED (Epic 10) — add ttcCharsetAl16Utf16 = 2000
│   └── messages/
│       ├── execute_message.dart        # CHANGED (Epic 8 fetch yielding; Epic 10 NCHAR decode/encode by csfrm, remove hard reject)
│       └── fast_auth_message.dart      # CHANGED (Epic 10) — national charset 873 -> 2000
└── transport/
    └── transport.dart                  # CHANGED (Epic 8 yield-not-drain fetch loop; Epic 10 connect-path ncharset 2000 + charset detection)
```

Supporting epics (9, 11–15) — additional new/changed files:

```text
lib/src/
├── oracle_lob.dart                     # NEW (Epic 12) — public OracleLob: chunked read/write, Stream, temp-LOB lifecycle
├── oracle_interval.dart                # NEW (Epic 15) — OracleIntervalYM / OracleIntervalDS wrapper types
├── connection.dart                     # CHANGED (Epic 11 executeMany(); Epic 12 createTemporaryClob/Blob(); Epic 14 fetchTypeHandler option)
├── result.dart                         # CHANGED (Epic 9 implicitResults; Epic 11 dmlRowCounts/batchErrors)
├── oracle_bind.dart                    # CHANGED (Epic 11 array bind forms)
├── protocol/
│   ├── constants.dart                  # CHANGED (Epic 9 oraTypeCursor; Epic 15 oraTypeInterval*/oraTypeVector)
│   ├── data_types.dart                 # CHANGED (Epic 14 region-id TSTZ decode; Epic 15 interval/rowid/vector codecs)
│   ├── oson.dart                       # CHANGED (Epic 13 12c JSON-as-BLOB path; wider embedded scalars)
│   └── messages/
│       ├── execute_message.dart        # CHANGED (Epic 9 cursor decode + multi-result-set; Epic 11 array iteration/_numExecs; Epic 14 fetch-type-handler hook; Epic 15 codec cases + fail-loud default)
│       └── lob_op_message.dart         # CHANGED (Epic 12 chunked read/write loop)
└── transport/
    └── transport.dart                  # CHANGED (Epic 12 chunked sendLobOp; Epic 13 12c JSON path)
```

Tests mirror `lib/src/` as always; add `test/integration/streaming_*` (Epic 8),
`test/integration/charset_*` (Epic 10), plus `refcursor_*` (9), `execute_many_*`
(11), `lob_stream_*` (12), `json_*` (13), `temporal_*` (14), and `extended_types_*`
(15) — every suite exercised on Oracle 23ai **and** 21c.

## Definition of Done for these epics (inherited)

- `dart analyze` clean (zero warnings).
- Integration tests pass on **both** Oracle 23ai (FAST_AUTH) **and** Oracle 21c
  (classical AUTH), written with `test_helper.dart`.
- node-oracledb thin parity preserved where the candidate cites reference
  behavior.
- Epic 8 only: existing 1.0 query/PLSQL/LOB suites fully re-validated after the
  `execute()` engine swap.

---

**Architecture Status:** READY FOR IMPLEMENTATION

**Next Phase:** Begin implementation using the architectural decisions and patterns documented herein.

**Document Maintenance:** Update this architecture when major technical decisions are made during implementation
