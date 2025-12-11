# Pure Dart Oracle Database Driver Implementation Guide

Building a thin-mode Oracle Database driver in pure Dart requires implementing Oracle's proprietary TNS/TTC wire protocol without Oracle Client libraries. This guide synthesizes reverse-engineered protocol specifications and patterns from Oracle's official python-oracledb and node-oracledb implementations to provide a complete roadmap for implementation.

## Core architecture mirrors Oracle's reference implementations

Both python-oracledb and node-oracledb organize their thin mode code into **four distinct layers**: transport/network (TCP/TLS socket handling), protocol/TNS (packet framing), messages/TTC (operation encoding), and connection/API (public interface). The Dart driver should follow this proven architecture pattern.

The **python-oracledb** thin implementation in `src/oracledb/impl/thin/` contains approximately 25 Cython files across two directories. Core infrastructure includes `transport.pyx` (socket management, TLS negotiation), `packet.pyx` (TNS packet construction), `protocol.pyx` (message processing loop), and `crypto.pyx` (authentication cryptography). The `messages/` subdirectory contains **17 specialized message handlers** including `auth.pyx`, `fast_auth.pyx`, `execute.pyx`, `fetch.pyx`, `lob_op.pyx`, and `tpc_*.pyx` for two-phase commit.

The **node-oracledb** thin implementation in `lib/thin/` uses a three-tier organization: core files (`connection.js`, `pool.js`, `lob.js`), protocol layer (`protocol/protocol.js`, `protocol/packet.js`, `protocol/messages/*.js`), and network layer (`sqlnet/networkSession.js`, `sqlnet/ntTcp.js`). The `ReadPacket` and `WritePacket` classes in `packet.js` handle TNS packet buffering with chunked data support.

## TNS protocol forms the session layer foundation

TNS (Transparent Network Substrate) handles connection establishment and packet framing over TCP port **1521**. Every TNS packet begins with an **8-byte header** in big-endian format:

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 2 | Length | Total packet size (8-4086 bytes) |
| 2 | 2 | Checksum | Usually 0x0000 |
| 4 | 1 | Type | Packet type code |
| 5 | 1 | Flags | Usually 0x00 |
| 6 | 2 | Header Checksum | Usually 0x0000 |

The **14 TNS packet types** are: Connect (0x01), Accept (0x02), Acknowledge (0x03), Refuse (0x04), Redirect (0x05), Data (0x06), Null (0x07), Abort (0x09), Resend (0x0B), Marker (0x0C), Attention (0x0D), Control (0x0E), and Data Descriptor (0x0F). The Data packet (0x06) carries all TTC/TTI messages after connection establishment.

The **Connect packet** structure contains version negotiation (typically 0x0136 for v310), SDU/TDU sizes (default 2048/32767), and the connect string in NVP (Name-Value Pair) format:

```
(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=hostname)(PORT=1521))
  (CONNECT_DATA=(SERVICE_NAME=orcl)(CID=(PROGRAM=dartapp)(HOST=client)(USER=user))))
```

The **Accept packet** returns negotiated parameters including byte order detection, allowing the driver to detect server endianness.

## TTC message layer implements all database operations

TTC (Two-Task Common) runs inside TNS Data packets and handles protocol negotiation, data type marshalling, and OPI function calls. The **17 TTC message types** include:

| Code | Name | Purpose |
|------|------|---------|
| 0x01 | TTIPRO | Protocol version negotiation |
| 0x02 | TTIDTY | Data type representation negotiation |
| 0x03 | TTIFUN | OPI function invocation |
| 0x04 | TTIOER | Oracle error response |
| 0x06 | TTIRXH | Row transfer header |
| 0x07 | TTIRXD | Row transfer data |
| 0x08 | TTIRPA | Return parameter |
| 0x09 | TTISTA | Function status (OK) |
| 0x0D | TTIOAC | Oracle column accessor |
| 0x0E | TTILOBD | LOB data transfer |
| 0xDE | TTISNS | Secure Network Services |

**Protocol negotiation** (TTIPRO) sends supported versions (6,5,4,3,2,1,0) and a client identifier string. The server responds with the selected version and platform information. Version 6 corresponds to Oracle 8.1+, which thin mode targets.

**Data type negotiation** (TTIDTY) establishes type mappings using 4-byte entries specifying source type, destination type, size, and flags. Character set negotiation occurs here, which is critical for proper string handling.

The **CLR (Chunked Long Raw) encoding** is fundamental to TTC data marshalling:
- Length ≤ 64: Single length byte + data
- Length > 64: 0xFE marker, then 64-byte chunks with length prefixes, terminated by 0x00
- NULL value: Single 0x00 or 0xFF byte

## OPI function codes define all database operations

OPI (Oracle Programmatic Interface) operations are encoded in TTIFUN messages. The **critical function codes** for a minimal driver are:

| Code | Name | Description |
|------|------|-------------|
| 0x01 | OLOGON | Legacy logon |
| 0x02 | OOPEN | Open cursor |
| 0x03 | OPARSE | Parse SQL statement |
| 0x04 | OEXEC | Execute statement |
| 0x05 | OFETCH | Fetch row |
| 0x08 | OCLOSE | Close cursor |
| 0x09 | OLOGOFF | Log off |
| 0x0E | OCOMMIT | Commit transaction |
| 0x0F | OROLLBACK | Rollback transaction |
| 0x5E | OALL8 | Bundled V8 call |
| 0x60 | OLOBOPS | LOB operations |
| 0x73 | OAUTH | Generic authentication |
| 0x76 | OSESSKEY | Get session key |
| 0x89 | OFETCH2 | Enhanced fetch |
| 0x93 | OPING | Connection ping |

The **OALL8** function (code 0x5E) is particularly important as it bundles parse, bind, execute, and fetch into a single round-trip, which both reference implementations use extensively for performance.

The **OALL7 options bitmap** controls bundled operations:
- 0x0001: PARSE
- 0x0008: BIND
- 0x0010: DEFINE
- 0x0020: EXECUTE
- 0x0040: FETCH
- 0x0100: COMMIT

## Oracle NUMBER encoding uses base-100 representation

Oracle NUMBER is a variable-length format (1-22 bytes) using base-100 digits:

**Byte 1 (Exponent + Sign):**
- High bit: 1=positive, 0=negative
- Lower 7 bits: Base-100 exponent with offset 65

**Bytes 2-21 (Mantissa):**
- Positive: Digit X stored as X+1
- Negative: Digit X stored as 101-X, with trailing 0x66

**Special values:**
- Zero: Single byte 0x80
- Positive infinity: 0xFF 0x65
- Negative infinity: 0x00

**Decoding example** for value `123433`:
```
Bytes: c3 0d 23 22
c3 (195) → exponent = 195-128-65 = 2 (10^4 base position)
0d (13) → digit 12 (13-1)
23 (35) → digit 34 (35-1)
22 (34) → digit 33 (34-1)
Result: 12×100² + 34×100¹ + 33×100⁰ = 123,433
```

The Dart implementation should use `BigInt` or `Decimal` packages for arbitrary precision NUMBER support.

## DATE and TIMESTAMP use 7-13 byte fixed formats

**DATE format (7 bytes):**

| Byte | Content | Formula |
|------|---------|---------|
| 1 | Century | century + 100 |
| 2 | Year | year_in_century + 100 |
| 3 | Month | 1-12 |
| 4 | Day | 1-31 |
| 5 | Hour | hour + 1 (1-24) |
| 6 | Minute | minute + 1 (1-60) |
| 7 | Second | second + 1 (1-60) |

**Example** `10-JUL-2004 17:21:30`: `[120, 104, 7, 10, 18, 22, 31]`

**TIMESTAMP** extends DATE with 4 bytes of nanoseconds. **TIMESTAMP WITH TIME ZONE** adds 2 bytes for timezone offset.

## Authentication requires three protocol generations

Thin mode must support multiple authentication protocols depending on database version:

### O5LOGON (11g, SHA1-based)
Password verifier: `SHA1(password || salt)`
Stored in `sys.user$.spare4` as: `S:<40-char hash><20-char salt>`

**Flow:**
1. Client sends username via OSESSKEY
2. Server returns AUTH_SESSKEY (encrypted) + AUTH_VFR_DATA (salt)
3. Client generates key: `SHA1(password || AUTH_VFR_DATA)`
4. Client decrypts AUTH_SESSKEY using AES-192 with zero IV
5. Session established on successful validation

### O7LOGON/O8LOGON (12c+, PBKDF2-SHA512)
**12C verifier generation:**
```
T = SHA512(PBKDF2(password, AUTH_VFR_DATA || 'AUTH_PBKDF2_SPEEDY_KEY', 4096, SHA512) || AUTH_VFR_DATA)
```
Stored as: `T:<128-char hash>;S:<SHA1 hash>;H:<MD5 hash>`

**Requirements for Dart:**
- SHA-1, SHA-512 hash functions
- PBKDF2 key derivation with 4096 iterations
- AES-192 CBC encryption/decryption
- Random number generation for session keys

The `crypto` or `pointycastle` Dart packages provide these primitives.

## Recommended Dart source file structure

Based on the reference implementations, organize the Dart driver as:

```
lib/
├── oracledb.dart                    # Public API exports
├── src/
│   ├── constants.dart               # Protocol constants, type codes
│   ├── errors.dart                  # Exception classes, error codes
│   ├── connection.dart              # OracleConnection class
│   ├── pool.dart                    # ConnectionPool class
│   ├── cursor.dart                  # Cursor/Statement execution
│   ├── lob.dart                     # LOB handling (Clob, Blob, NClob)
│   ├── db_object.dart               # Oracle Object types
│   ├── types.dart                   # Data type converters
│   ├── transport/
│   │   ├── socket.dart              # TCP socket wrapper
│   │   ├── tls.dart                 # TLS negotiation
│   │   └── transport.dart           # Transport abstraction
│   ├── protocol/
│   │   ├── tns_packet.dart          # TNS packet encoding/decoding
│   │   ├── ttc_buffer.dart          # TTC read/write buffers
│   │   ├── protocol.dart            # Protocol state machine
│   │   └── capabilities.dart        # Client/server capabilities
│   ├── messages/
│   │   ├── message.dart             # Base message class
│   │   ├── auth_message.dart        # Authentication
│   │   ├── execute_message.dart     # SQL execution
│   │   ├── fetch_message.dart       # Result fetching
│   │   ├── lob_message.dart         # LOB operations
│   │   ├── commit_message.dart      # Transaction commit
│   │   ├── rollback_message.dart    # Transaction rollback
│   │   └── ping_message.dart        # Connection health check
│   └── crypto/
│       ├── auth.dart                # Authentication protocols
│       ├── verifier.dart            # Password verifier handling
│       └── session_key.dart         # Session key derivation
```

## Complete test suite requirements

The reference implementations provide **~100 test files** covering all functionality. For the Dart driver, prioritize tests in this order:

### Phase 1: Connection and basic operations (20 tests)
- Module constants and version info
- Connection creation with username/password
- Connection pooling (create, acquire, release, destroy)
- Basic SELECT execution and fetch
- INSERT/UPDATE/DELETE with commit/rollback
- Connection ping and health checks
- Error handling and exception mapping

### Phase 2: Data types (25 tests)
- VARCHAR2, CHAR, NVARCHAR2, NCHAR
- NUMBER (integer, decimal, negative, large values, zero)
- DATE, TIMESTAMP, TIMESTAMP WITH TIME ZONE
- INTERVAL YEAR TO MONTH, INTERVAL DAY TO SECOND
- BINARY_FLOAT, BINARY_DOUBLE
- RAW, LONG RAW
- ROWID, UROWID
- BOOLEAN (Oracle 23ai+)

### Phase 3: Advanced features (25 tests)
- CLOB, BLOB, NCLOB streaming
- Bind variables (IN, OUT, IN/OUT)
- DML RETURNING clause
- REF CURSOR handling
- PL/SQL procedure/function execution
- Anonymous PL/SQL blocks
- Implicit results (12c+)
- Batch execution (executeMany)
- Statement caching

### Phase 4: Extended features (20 tests)
- JSON data type
- Oracle Object types and collections
- Advanced Queuing (AQ)
- Two-phase commit (TPC)
- DRCP support
- Token-based authentication

## Test infrastructure setup with Docker

**Recommended image:** `gvenzl/oracle-free:slim-faststart` for fastest CI startup.

**Docker Compose configuration:**
```yaml
services:
  oracle:
    image: gvenzl/oracle-free:slim-faststart
    environment:
      ORACLE_PASSWORD: testpassword
      APP_USER: testuser
      APP_USER_PASSWORD: testpassword
    ports:
      - "1521:1521"
    healthcheck:
      test: ["CMD", "healthcheck.sh"]
      interval: 10s
      timeout: 5s
      retries: 10
```

**GitHub Actions workflow:**
```yaml
services:
  oracle:
    image: gvenzl/oracle-free:slim-faststart
    env:
      ORACLE_RANDOM_PASSWORD: true
      APP_USER: testuser
      APP_USER_PASSWORD: testpassword
    ports:
      - 1521:1521
    options: >-
      --health-cmd healthcheck.sh
      --health-interval 10s
      --health-timeout 5s
      --health-retries 10
```

**Required test schema privileges:**
```sql
GRANT CREATE SESSION, CREATE TABLE, CREATE PROCEDURE TO testuser;
GRANT CREATE SEQUENCE, CREATE TRIGGER, CREATE TYPE TO testuser;
GRANT UNLIMITED TABLESPACE TO testuser;
-- For AQ tests:
GRANT AQ_USER_ROLE TO testuser;
GRANT EXECUTE ON DBMS_AQ TO testuser;
```

## Thin mode feature boundaries to implement

**Must implement (thin mode supports):**
- All basic data types (VARCHAR2, NUMBER, DATE, TIMESTAMP, LOB, JSON)
- Connection pooling (application-level and DRCP)
- Password authentication (11G and 12C+ verifiers)
- TLS connections (requires PEM format wallet - ewallet.pem)
- Two-phase commit (added in recent versions)
- Advanced Queuing
- Token-based authentication
- Oracle Object types
- VECTOR data type (23ai)

**Cannot implement (thick mode only):**
- SODA (Simple Oracle Document Access)
- Continuous Query Notification (CQN)
- External authentication (OS/Wallet)
- Kerberos authentication
- Native Network Encryption (NNE)
- Application Continuity / Transparent Application Continuity
- FAN (Fast Application Notification)
- Client Result Cache
- Bequeath (local) connections

## Implementation phases recommended

**Phase 1 (MVP - 4-6 weeks):**
Transport layer, TNS connect/accept, TTC protocol negotiation, O5LOGON/O8LOGON authentication, basic SELECT with scalar types (VARCHAR2, NUMBER, DATE).

**Phase 2 (Core functionality - 4-6 weeks):**
All data types, bind variables, DML operations, transactions (commit/rollback), connection pooling, statement caching.

**Phase 3 (Advanced features - 4-6 weeks):**
LOB streaming, REF CURSORs, PL/SQL support, batch execution, JSON type, Oracle Objects.

**Phase 4 (Enterprise features - 4-6 weeks):**
Two-phase commit, Advanced Queuing, DRCP, TLS connections, VECTOR type, performance optimization.

## Critical protocol documentation sources

The implementation should reference these reverse-engineering sources:

1. **Ian Redfern's "Oracle Protocol" paper** - Foundational TNS/TTC structure documentation covering packet formats, data type encoding, and authentication
2. **Jonah H. Harris's unofficial specification** - Comprehensive OPI function code listing at github.com/redwood-wire-protocol
3. **SpiderLabs net-tns Ruby library** - Working TNS/TTI implementation for reference
4. **CVE-2012-3137 research** - Detailed O5LOGON authentication flow analysis
5. **python-oracledb and node-oracledb source** - Authoritative reference for current protocol handling

The wire protocol is proprietary and undocumented by Oracle, so implementation requires careful study of reference implementations and network traffic analysis for edge cases.