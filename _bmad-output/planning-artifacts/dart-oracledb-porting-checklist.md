# dart-oracledb Porting Checklist

**Project:** Port Oracle node-oracledb thin driver to pure Dart
**Source:** `reference/node-oracledb/lib/thin/`
**Target:** `lib/src/`
**Generated:** 2025-12-14

---

## Project Setup

### Package Configuration

- [ ] Create `pubspec.yaml` with dependencies:

```yaml
name: oracledb
description: Pure Dart Oracle Database driver (thin mode)
version: 0.1.0

environment:
  sdk: '>=3.0.0 <4.0.0'

dependencies:
  crypto: ^3.0.0           # SHA256, SHA512, MD5
  pointycastle: ^3.7.0     # AES, RSA, PBKDF2

dev_dependencies:
  test: ^1.24.0
  lints: ^2.1.0
```

- [ ] Create `analysis_options.yaml`
- [ ] Create `lib/oracledb.dart` (main export file)

### Directory Structure

```
lib/
├── oracledb.dart                    # Main export
└── src/
    ├── connection.dart              # ThinConnection
    ├── pool.dart                    # ThinPool
    ├── result_set.dart              # ThinResultSet
    ├── statement.dart               # Statement handling
    ├── statement_cache.dart         # Prepared statement cache
    ├── lob.dart                     # LOB handling
    ├── db_object.dart               # Oracle object types
    ├── aq.dart                      # Advanced Queuing
    ├── util.dart                    # Utilities
    ├── errors.dart                  # Error definitions
    ├── types.dart                   # Type definitions
    ├── constants.dart               # Public constants
    │
    ├── protocol/                    # TTC Protocol
    │   ├── constants.dart
    │   ├── protocol.dart
    │   ├── packet.dart
    │   ├── capabilities.dart
    │   ├── encrypt_decrypt.dart
    │   ├── utils.dart
    │   └── messages/
    │       ├── base.dart
    │       ├── with_data.dart
    │       ├── auth.dart
    │       ├── execute.dart
    │       ├── fetch.dart
    │       ├── commit.dart
    │       ├── rollback.dart
    │       ├── ping.dart
    │       ├── log_off.dart
    │       ├── lob_op.dart
    │       └── ... (other messages)
    │
    ├── sqlnet/                      # TNS/SQLNet
    │   ├── constants.dart
    │   ├── network_session.dart
    │   ├── nt_tcp.dart
    │   ├── packet.dart
    │   ├── session_atts.dart
    │   ├── conn_strategy.dart
    │   ├── nav_nodes.dart
    │   ├── ez_connect_resolver.dart
    │   ├── param_parser.dart
    │   ├── nv_str_to_nv_pair.dart
    │   └── ano.dart
    │
    └── datahandlers/                # Data encoding/decoding
        ├── buffer.dart              # OracleBuffer class
        ├── constants.dart
        ├── oson.dart
        └── vector.dart
```

---

## Phase 1: Foundation (P0)

### 1.1 Buffer Infrastructure

- [ ] **`lib/src/datahandlers/buffer.dart`** - OracleBuffer class
  - [ ] `readUInt8()`, `writeUInt8()`
  - [ ] `readUInt16BE()`, `readUInt16LE()`, `writeUInt16BE()`, `writeUInt16LE()`
  - [ ] `readUInt32BE()`, `readUInt32LE()`, `writeUInt32BE()`, `writeUInt32LE()`
  - [ ] `readUB4()`, `writeUB4()` - Variable length integers
  - [ ] `readBytes()`, `writeBytes()`
  - [ ] `readBytesWithLength()`, `writeBytesWithLength()`
  - [ ] `readStr()`, `writeStr()` - String with charset
  - [ ] `subarray()`, `copy()`
  - [ ] Position tracking (`pos`, `size`, `numBytesLeft()`)

- [ ] **`lib/src/datahandlers/constants.dart`** - Handler constants
  - [ ] `TNS_LONG_LENGTH_INDICATOR`
  - [ ] `TNS_NULL_LENGTH_INDICATOR`

### 1.2 Protocol Constants

- [ ] **`lib/src/protocol/constants.dart`** - All protocol constants
  - [ ] TNS packet types (CONNECT, ACCEPT, REFUSE, etc.)
  - [ ] TTC function codes (AUTH, EXECUTE, FETCH, etc.)
  - [ ] Data type codes (VARCHAR, NUMBER, DATE, etc.)
  - [ ] Message types
  - [ ] Auth modes
  - [ ] Execute options
  - [ ] LOB operations
  - [ ] Capability indices and values

- [ ] **`lib/src/sqlnet/constants.dart`** - SQLNet constants

### 1.3 Crypto Infrastructure

- [ ] **`lib/src/protocol/encrypt_decrypt.dart`**
  - [ ] `generateSessionKey()` - PBKDF2 key derivation
  - [ ] `encrypt()` / `decrypt()` - AES encryption
  - [ ] `updateVerifierData()` - Password verifier
  - [ ] `updatePasswordsWithComboKey()` - Password encoding
  - [ ] SHA512 hashing
  - [ ] SHA1 hashing (for 11G compatibility)

**Test:** Verify crypto output matches Node.js byte-for-byte

### 1.4 TNS Layer (sqlnet/)

- [ ] **`lib/src/sqlnet/packet.dart`** - TNS packet framing
  - [ ] 8-byte header parsing
  - [ ] Packet type identification
  - [ ] Payload extraction

- [ ] **`lib/src/sqlnet/nt_tcp.dart`** - TCP socket handling
  - [ ] Socket connection
  - [ ] TLS upgrade (`SecureSocket.secure()`)
  - [ ] Read/write operations
  - [ ] Timeout handling

- [ ] **`lib/src/sqlnet/network_session.dart`** - Session management
  - [ ] `connect()` - Establish connection
  - [ ] `disconnect()` - Close connection
  - [ ] Send/receive packets
  - [ ] Handle redirects

- [ ] **`lib/src/sqlnet/session_atts.dart`** - Session attributes

- [ ] **`lib/src/sqlnet/ez_connect_resolver.dart`** - EZ Connect parsing
  - [ ] Parse `host:port/service` format
  - [ ] Parse `host:port:sid` format

- [ ] **`lib/src/sqlnet/param_parser.dart`** - tnsnames.ora parsing
  - [ ] Load tnsnames.ora
  - [ ] Parse TNS aliases
  - [ ] Resolve to connection info

- [ ] **`lib/src/sqlnet/nv_str_to_nv_pair.dart`** - NV pair parsing
  - [ ] Parse `(DESCRIPTION=...)` format
  - [ ] Extract ADDRESS, CONNECT_DATA, etc.

### 1.5 TTC Protocol Layer (protocol/)

- [ ] **`lib/src/protocol/capabilities.dart`** - Capability negotiation
  - [ ] Compile-time capabilities
  - [ ] Runtime capabilities
  - [ ] Version negotiation

- [ ] **`lib/src/protocol/packet.dart`** - TTC packet handling

- [ ] **`lib/src/protocol/protocol.dart`** - Protocol orchestration
  - [ ] Message sending
  - [ ] Response parsing
  - [ ] Error handling

### 1.6 Message Classes (protocol/messages/)

- [ ] **`base.dart`** - Base Message class
  - [ ] `encode(buf)` method
  - [ ] `writeFunctionHeader(buf)`
  - [ ] `processErrorInfo(buf)`
  - [ ] `preProcess()` / `postProcess()`

- [ ] **`with_data.dart`** - MessageWithData base
  - [ ] Column metadata handling
  - [ ] Bind parameter handling
  - [ ] Row data handling

- [ ] **`auth.dart`** - AuthMessage
  - [ ] Phase 1 (OSESSKEY) encoding
  - [ ] Phase 2 (OAUTH) encoding
  - [ ] Response parsing
  - [ ] Verifier handling

- [ ] **`protocol_message.dart`** - ProtocolMessage
  - [ ] Protocol version negotiation
  - [ ] Capability exchange

- [ ] **`data_type.dart`** - DataTypeMessage
  - [ ] Data type negotiation

- [ ] **`execute.dart`** - ExecuteMessage
  - [ ] SQL execution
  - [ ] Bind parameter encoding
  - [ ] Options handling

- [ ] **`fetch.dart`** - FetchMessage
  - [ ] Cursor fetch
  - [ ] Row data parsing

- [ ] **`commit.dart`** - CommitMessage
- [ ] **`rollback.dart`** - RollbackMessage
- [ ] **`ping.dart`** - PingMessage
- [ ] **`log_off.dart`** - LogOffMessage

### 1.7 Data Type Handlers

- [ ] **Oracle NUMBER parsing** (`parseOracleNumber()`)
  - [ ] Base-100 decoding
  - [ ] Sign handling
  - [ ] Exponent handling
  - [ ] String output

- [ ] **Oracle DATE parsing** (`parseOracleDate()`)
  - [ ] 7-byte format
  - [ ] Century/year calculation

- [ ] **TIMESTAMP parsing** (7/11/13 byte formats)
  - [ ] Fractional seconds
  - [ ] Time zone handling

- [ ] **BINARY_FLOAT/DOUBLE** (`parseBinaryFloat/Double()`)
  - [ ] IEEE 754 with Oracle sign handling

- [ ] **String encoding/decoding**
  - [ ] UTF-8 handling
  - [ ] Length prefixing

- [ ] **RAW/BLOB binary handling**

### 1.8 Connection Implementation

- [ ] **`lib/src/connection.dart`** - ThinConnection
  - [ ] `connect()` - Full connection flow
  - [ ] `execute()` - SQL execution
  - [ ] `commit()` / `rollback()`
  - [ ] `ping()`
  - [ ] `close()`
  - [ ] Property getters (serverVersion, etc.)

### 1.9 Result Set Implementation

- [ ] **`lib/src/result_set.dart`** - ThinResultSet
  - [ ] `getRows()` - Fetch rows
  - [ ] `close()`
  - [ ] Column metadata access
  - [ ] Iterator/Stream support

### 1.10 Statement Implementation

- [ ] **`lib/src/statement.dart`** - Statement handling
  - [ ] SQL parsing
  - [ ] Bind info extraction
  - [ ] Cursor management

---

## Phase 2: Extended Features (P1)

### 2.1 Connection Pooling

- [ ] **`lib/src/pool.dart`** - ThinPool
  - [ ] `getConnection()` - Acquire from pool
  - [ ] `releaseConnection()` - Return to pool
  - [ ] `close()` - Close all connections
  - [ ] Min/max pool size
  - [ ] Connection timeout
  - [ ] Pool expansion/shrinkage
  - [ ] Session tagging

### 2.2 Statement Caching

- [ ] **`lib/src/statement_cache.dart`**
  - [ ] LRU cache implementation
  - [ ] Cursor reuse
  - [ ] Cache statistics

### 2.3 Additional Messages

- [ ] **`session_release.dart`** - DRCP session release
- [ ] **`fast_auth.dart`** - Fast re-authentication

### 2.4 Advanced Connection Features

- [ ] TNS redirect handling
- [ ] Connection class support
- [ ] Edition support
- [ ] Application context

---

## Phase 3: LOB & Objects (P2)

### 3.1 LOB Support

- [ ] **`lib/src/lob.dart`** - ThinLob
  - [ ] Read operations
  - [ ] Write operations
  - [ ] Stream support
  - [ ] Temporary LOBs
  - [ ] CLOB/BLOB/NCLOB

- [ ] **`lob_op.dart`** - LobOpMessage
  - [ ] LOB_OP_READ
  - [ ] LOB_OP_WRITE
  - [ ] LOB_OP_TRIM
  - [ ] LOB_OP_GET_LENGTH

### 3.2 DB Object Support

- [ ] **`lib/src/db_object.dart`** - ThinDbObject
  - [ ] Object type metadata
  - [ ] Attribute access
  - [ ] Collection support

### 3.3 JSON Support

- [ ] **`lib/src/datahandlers/oson.dart`** - OSON encoding/decoding
  - [ ] JSON to OSON conversion
  - [ ] OSON to JSON conversion

---

## Phase 4: Advanced Features (P3)

### 4.1 Advanced Queuing

- [ ] **`lib/src/aq.dart`** - AQ support
- [ ] AQ message classes

### 4.2 Transaction Support

- [ ] Two-phase commit (XA)
- [ ] Sessionless transactions

### 4.3 Vector Type (Oracle 23c+)

- [ ] **`lib/src/datahandlers/vector.dart`**

---

## Testing Phases

### Test Infrastructure

- [ ] Set up Oracle XE in Docker for testing
- [ ] Create `test/test_config.dart` with connection settings
- [ ] Create `test/test_helpers.dart` with utilities

### Phase 1 Tests (~85 tests)

- [ ] `test/connection_test.dart` - Basic connection
- [ ] `test/execute_test.dart` - SQL execution
- [ ] `test/fetch_test.dart` - Row fetching
- [ ] `test/binding_test.dart` - Parameter binding
- [ ] `test/data_types/`
  - [ ] `number_test.dart`
  - [ ] `varchar_test.dart`
  - [ ] `date_test.dart`
  - [ ] `timestamp_test.dart`
  - [ ] `raw_test.dart`
  - [ ] `rowid_test.dart`

### Phase 2 Tests (~34 tests)

- [ ] `test/pool_test.dart` - Connection pooling
- [ ] `test/statement_cache_test.dart`
- [ ] `test/plsql_test.dart` - PL/SQL execution
- [ ] `test/transaction_test.dart`

### Phase 3 Tests (~81 tests)

- [ ] `test/lob_test.dart` - LOB operations
- [ ] `test/json_test.dart` - JSON support
- [ ] `test/db_object_test.dart` - Object types

### Phase 4 Tests (~42 tests)

- [ ] `test/aq_test.dart` - Advanced Queuing
- [ ] `test/vector_test.dart` - Vector type

---

## Quality Checklist

### Code Quality

- [ ] All files have proper Dart doc comments
- [ ] All public APIs documented
- [ ] No lint warnings
- [ ] Consistent naming (snake_case files, camelCase members)

### Error Handling

- [ ] All Oracle errors properly wrapped
- [ ] Meaningful error messages
- [ ] Stack traces preserved

### Performance

- [ ] Buffer operations optimized
- [ ] No unnecessary allocations in hot paths
- [ ] Connection pooling efficient

### Security

- [ ] No credentials logged
- [ ] Secure password handling
- [ ] TLS properly implemented

---

## Milestones

### Milestone 1: Connect & Query
- [ ] Can connect to Oracle
- [ ] Can execute simple SELECT
- [ ] Can fetch rows

### Milestone 2: Full CRUD
- [ ] INSERT/UPDATE/DELETE working
- [ ] Bind parameters working
- [ ] Transactions working

### Milestone 3: Production Ready
- [ ] Connection pooling
- [ ] All core data types
- [ ] Statement caching
- [ ] Error handling complete

### Milestone 4: Feature Complete
- [ ] LOB support
- [ ] JSON support
- [ ] Object types
- [ ] All tests passing

---

## Reference Files Mapping

| Node.js Source | Dart Target | Priority |
|----------------|-------------|----------|
| `lib/thin/connection.js` | `lib/src/connection.dart` | P0 |
| `lib/thin/pool.js` | `lib/src/pool.dart` | P1 |
| `lib/thin/statement.js` | `lib/src/statement.dart` | P0 |
| `lib/thin/statementCache.js` | `lib/src/statement_cache.dart` | P1 |
| `lib/thin/resultSet.js` | `lib/src/result_set.dart` | P0 |
| `lib/thin/lob.js` | `lib/src/lob.dart` | P2 |
| `lib/thin/dbObject.js` | `lib/src/db_object.dart` | P2 |
| `lib/thin/util.js` | `lib/src/util.dart` | P0 |
| `lib/thin/protocol/constants.js` | `lib/src/protocol/constants.dart` | P0 |
| `lib/thin/protocol/protocol.js` | `lib/src/protocol/protocol.dart` | P0 |
| `lib/thin/protocol/packet.js` | `lib/src/protocol/packet.dart` | P0 |
| `lib/thin/protocol/capabilities.js` | `lib/src/protocol/capabilities.dart` | P0 |
| `lib/thin/protocol/encryptDecrypt.js` | `lib/src/protocol/encrypt_decrypt.dart` | P0 |
| `lib/thin/protocol/messages/base.js` | `lib/src/protocol/messages/base.dart` | P0 |
| `lib/thin/protocol/messages/auth.js` | `lib/src/protocol/messages/auth.dart` | P0 |
| `lib/thin/protocol/messages/execute.js` | `lib/src/protocol/messages/execute.dart` | P0 |
| `lib/thin/protocol/messages/fetch.js` | `lib/src/protocol/messages/fetch.dart` | P0 |
| `lib/thin/sqlnet/networkSession.js` | `lib/src/sqlnet/network_session.dart` | P0 |
| `lib/thin/sqlnet/ntTcp.js` | `lib/src/sqlnet/nt_tcp.dart` | P0 |
| `lib/thin/sqlnet/packet.js` | `lib/src/sqlnet/packet.dart` | P0 |
| `lib/impl/datahandlers/buffer.js` | `lib/src/datahandlers/buffer.dart` | P0 |

---

## Notes

- **Endianness:** Always use explicit `Endian.big` or `Endian.little`
- **Crypto:** Test authentication against real Oracle to verify
- **Testing:** Use Docker Oracle XE: `container-registry.oracle.com/database/express:latest`
- **Performance:** Compile with AOT for production deployments
