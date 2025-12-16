---
stepsCompleted: [1, 2, 3]
inputDocuments:
  - 'docs/prd.md'
  - 'docs/architecture.md'
  - 'docs/sprint-change-proposal-2025-12-16.md'
project_name: 'dart-oracledb'
user_name: 'Alex'
date: '2025-12-16'
---

# dart-oracledb - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for dart-oracledb, decomposing the requirements from the PRD and Architecture into implementable stories.

## Requirements Inventory

### Functional Requirements

**Connection Management (FR1-FR6)**
- FR1: Developer can establish a connection to Oracle database using an EZ Connect string (host:port/service)
- FR2: Developer can authenticate using username and password with SHA512/PBKDF2 verifiers
- FR3: Developer can establish a TLS/SSL encrypted connection
- FR4: Developer can specify connection timeout duration
- FR5: Developer can close a connection and release associated resources
- FR6: Developer can check if a connection is still valid/alive

**Connection Pooling (FR7-FR12)**
- FR7: Developer can create a connection pool with configurable minimum and maximum size
- FR8: Developer can acquire a connection from the pool
- FR9: Developer can release a connection back to the pool
- FR10: Developer can configure pool timeout settings
- FR11: Developer can close a pool and release all connections
- FR12: Developer can set session tags on pooled connections

**Query Execution (FR13-FR21)**
- FR13: Developer can execute a SELECT query and retrieve results
- FR14: Developer can execute an INSERT statement
- FR15: Developer can execute an UPDATE statement
- FR16: Developer can execute a DELETE statement
- FR17: Developer can use named bind parameters in queries (e.g., :param_name)
- FR18: Developer can use positional bind parameters in queries
- FR19: Developer can iterate over query result rows
- FR20: Developer can access column values by column name
- FR21: Developer can access column values by column index

**Transaction Management (FR22-FR24)**
- FR22: Developer can commit a transaction
- FR23: Developer can rollback a transaction
- FR24: Developer can execute multiple statements within a single transaction

**PL/SQL Execution (FR25-FR29)**
- FR25: Developer can call a stored procedure
- FR26: Developer can call a function and retrieve the return value
- FR27: Developer can pass IN parameters to procedures/functions
- FR28: Developer can retrieve OUT parameter values from procedures/functions
- FR29: Developer can use IN OUT parameters with procedures/functions

**Data Type Handling (FR30-FR39)**
- FR30: System can map Oracle VARCHAR2/VARCHAR/CHAR to Dart String
- FR31: System can map Oracle NUMBER to Dart int or double
- FR32: System can map Oracle DATE to Dart DateTime
- FR33: System can map Oracle TIMESTAMP to Dart DateTime with precision
- FR34: System can read CLOB data as Dart String
- FR35: System can write Dart String to CLOB
- FR36: System can read BLOB data as Dart Uint8List
- FR37: System can write Dart Uint8List to BLOB
- FR38: System can map Oracle RAW to Dart Uint8List
- FR39: System can map Oracle JSON to Dart Map/List

**Error Handling (FR40-FR43)**
- FR40: System surfaces Oracle error codes (ORA-xxxxx) in exceptions
- FR41: System provides clear error messages for connection failures
- FR42: System provides clear error messages for query execution failures
- FR43: Developer can catch and handle OracleException types

**Statement Caching (FR44-FR45)**
- FR44: System caches prepared statements for performance
- FR45: Developer can configure statement cache size

### NonFunctional Requirements

**Performance (NFR1-NFR4)**
- NFR1: Query execution overhead from the driver should be minimal compared to network round-trip time
- NFR2: Statement caching should reduce repeated query parsing overhead
- NFR3: Connection pooling should eliminate per-request connection establishment cost
- NFR4: Crypto/authentication latency is acceptable during initial connection (mitigated by pooling)

**Security (NFR5-NFR7)**
- NFR5: Database credentials must never be logged or exposed in error messages
- NFR6: TLS/SSL encryption must be supported for production connections
- NFR7: Authentication must use Oracle's secure verifier protocols (SHA512/PBKDF2)

**Reliability (NFR8-NFR10)**
- NFR8: System should detect broken connections and surface clear errors
- NFR9: Connection pool should handle connection failures gracefully (remove dead connections, create new ones)
- NFR10: System should properly release resources on connection close (no resource leaks)

**Compatibility (NFR11-NFR14)**
- NFR11: Package must support Dart SDK 3.0+
- NFR12: Package must work on macOS (Apple Silicon and Intel), Windows, and Linux
- NFR13: Package must support Oracle 23ai with modern authentication
- NFR14: Package must compile and run in both JIT (development) and AOT (production) modes

### Additional Requirements

**From Architecture - Starter Template (Epic 1, Story 1):**
- Initialize project using `dart create -t package dart_oracledb`
- Restructure directories to match node-oracledb organization
- Three-layer architecture: `transport/` → `protocol/` → public API

**From Architecture - Implementation Patterns:**
- Buffer handling with explicit endianness methods (`readUint16BE()`, `writeUint32LE()`, etc.)
- Error propagation must preserve original error via `cause` parameter in OracleException
- Resource management: dual pattern required (explicit `close()` + auto-close wrappers like `withConnection()`)
- Logging via `package:logging` with appropriate log levels
- Test structure must mirror `lib/src/` exactly
- All code must pass `dart analyze` with zero warnings

**From Architecture - Development Sequence:**
1. Initialize project with dart create
2. Restructure directories to match architecture
3. Set up dependencies in pubspec.yaml
4. Implement transport layer (TNS)
5. Implement protocol layer (TTC)
6. Implement public API (connection, pool, result)
7. Add integration tests against Oracle 23ai

### FR Coverage Map

| FR | Epic | Description |
|----|------|-------------|
| FR1 | Epic 1 | EZ Connect string connection |
| FR2 | Epic 1 | SHA512/PBKDF2 authentication |
| FR3 | Epic 1 | TLS/SSL support |
| FR4 | Epic 1 | Connection timeout |
| FR5 | Epic 1 | Connection close |
| FR6 | Epic 1 | Connection health check |
| FR7 | Epic 5 | Create connection pool |
| FR8 | Epic 5 | Acquire connection from pool |
| FR9 | Epic 5 | Release connection to pool |
| FR10 | Epic 5 | Pool timeout settings |
| FR11 | Epic 5 | Close pool |
| FR12 | Epic 5 | Session tagging |
| FR13 | Epic 2 | Execute SELECT |
| FR14 | Epic 2 | Execute INSERT |
| FR15 | Epic 2 | Execute UPDATE |
| FR16 | Epic 2 | Execute DELETE |
| FR17 | Epic 2 | Named bind parameters |
| FR18 | Epic 2 | Positional bind parameters |
| FR19 | Epic 2 | Iterate result rows |
| FR20 | Epic 2 | Access columns by name |
| FR21 | Epic 2 | Access columns by index |
| FR22 | Epic 2 | Commit transaction |
| FR23 | Epic 2 | Rollback transaction |
| FR24 | Epic 2 | Multiple statements in transaction |
| FR25 | Epic 3 | Call stored procedure |
| FR26 | Epic 3 | Call function with return value |
| FR27 | Epic 3 | IN parameters |
| FR28 | Epic 3 | OUT parameters |
| FR29 | Epic 3 | IN OUT parameters |
| FR30 | Epic 2 | VARCHAR2/VARCHAR/CHAR to String |
| FR31 | Epic 2 | NUMBER to int/double |
| FR32 | Epic 2 | DATE to DateTime |
| FR33 | Epic 2 | TIMESTAMP to DateTime |
| FR34 | Epic 4 | Read CLOB as String |
| FR35 | Epic 4 | Write String to CLOB |
| FR36 | Epic 4 | Read BLOB as Uint8List |
| FR37 | Epic 4 | Write Uint8List to BLOB |
| FR38 | Epic 4 | RAW to Uint8List |
| FR39 | Epic 4 | JSON to Map/List |
| FR40 | Epic 1 | Surface Oracle error codes |
| FR41 | Epic 1 | Connection failure messages |
| FR42 | Epic 2 | Query execution failure messages |
| FR43 | Epic 1 | OracleException type |
| FR44 | Epic 2 | Statement caching |
| FR45 | Epic 2 | Configure cache size |

## Epic List

## Epic 1: Core Connection & Authentication

Developer can connect to Oracle database securely using an EZ Connect string, authenticate with modern SHA512/PBKDF2 verifiers, establish TLS/SSL encrypted connections, and verify connection health.

**FRs covered:** FR1, FR2, FR3, FR4, FR5, FR6, FR40, FR41, FR43

**Technical notes:** This epic includes project initialization, transport layer (TNS), protocol layer (TTC authentication), and crypto layer - all required to deliver the first working connection.

**Current Status (2025-12-16):** ⚠️ Epic 1 partially complete - Stories 1.1-1.3 working, Story 1.4 broken (AUTH_PHASE_ONE fails), Story 1.4-FIX in progress. Epic marked as IN-PROGRESS until authentication is fixed. See [sprint-change-proposal-2025-12-16.md](sprint-change-proposal-2025-12-16.md) for details.

### Story 1.1: Project Initialization & Structure

As a **developer contributing to dart-oracledb**,
I want **a properly structured Dart package mirroring node-oracledb organization**,
So that **I have a maintainable foundation that enables easier upstream sync**.

**Acceptance Criteria:**

**Given** a fresh development environment
**When** the project is initialized with `dart create -t package`
**Then** the directory structure matches the Architecture specification:
- `lib/dart_oracledb.dart` as single public export
- `lib/src/` with subdirectories: `transport/`, `protocol/`, `protocol/messages/`, `crypto/`
- `test/src/` mirroring lib structure
- `pubspec.yaml` with Dart 3.0+ SDK constraint
- `analysis_options.yaml` configured
**And** `dart analyze` passes with zero warnings
**And** dependencies are declared: `crypto`, `pointycastle`, `logging`

### Story 1.2: TNS Transport Layer

As a **developer using dart-oracledb**,
I want **the driver to communicate with Oracle over TCP using TNS protocol**,
So that **I can establish network connectivity to Oracle databases**.

**Acceptance Criteria:**

**Given** an Oracle database listening on a TCP port
**When** the transport layer is initialized with host and port
**Then** a TCP socket connection is established
**And** TNS packets can be sent with proper framing (header + payload)
**And** TNS packets can be received and parsed
**And** the transport handles CONNECT, ACCEPT, DATA, and RESEND packet types
**And** EZ Connect string parsing works for `host:port/service` format

**Given** a network error occurs
**When** sending or receiving packets
**Then** an appropriate error is surfaced (not swallowed)

### Story 1.3: TTC Protocol Foundation

As a **developer using dart-oracledb**,
I want **TTC message encoding/decoding implemented**,
So that **the driver can communicate using Oracle's wire protocol**.

**Acceptance Criteria:**

**Given** the transport layer is connected
**When** TTC messages need to be sent
**Then** messages are properly encoded with:
- Explicit endianness handling (`readUint16BE()`, `writeUint32LE()`, etc.)
- Protocol capability negotiation
- Data type indicators
**And** received TTC messages are properly decoded
**And** the buffer utility class handles all byte operations safely

**Given** a malformed TTC response
**When** decoding is attempted
**Then** a clear error is raised with context

### Story 1.4: Authentication Implementation

As a **developer using dart-oracledb**,
I want **SHA512/PBKDF2 authentication implemented**,
So that **I can authenticate securely with Oracle 23ai databases**.

**Acceptance Criteria:**

**Given** valid Oracle credentials (username, password)
**When** authentication is initiated
**Then** the driver performs AUTH_PHASE_ONE (get verifier parameters)
**And** derives session key using SHA512/PBKDF2 per Oracle protocol
**And** completes AUTH_PHASE_TWO with encrypted password proof
**And** authentication succeeds against Oracle 23ai

**Given** invalid credentials
**When** authentication is attempted
**Then** an `OracleException` is thrown with ORA-01017 (invalid username/password)
**And** the password is NOT included in error message or logs (NFR5)

**Current Status:** ⚠️ Implementation exists but authentication is **BROKEN** - Oracle closes connection at AUTH_PHASE_ONE with ORA-12547. See Story 1.4-FIX below.

### Story 1.4-FIX: Authentication Protocol Debugging

As a **developer maintaining dart-oracledb**,
I want **to identify and fix the authentication protocol bug**,
So that **Story 1.4 authentication implementation actually works with Oracle 23ai**.

**Context:** Story 1.4 implementation is complete but broken. Oracle closes the connection immediately after receiving AUTH_PHASE_ONE message, indicating a protocol mismatch. This story focuses on debugging and fixing the protocol issue.

**Acceptance Criteria:**

**AC1: Identify exact protocol mismatch**
**Given** the current AUTH_PHASE_ONE implementation
**When** comparing byte-by-byte with working node-oracledb via Wireshark or packet capture
**Then** the exact protocol difference causing Oracle to close connection is identified
**And** root cause is documented (capability flag, sequence number, token, or format issue)

**AC2: Implement fix for AUTH_PHASE_ONE**
**Given** the identified protocol mismatch
**When** the AUTH_PHASE_ONE message encoding is corrected
**Then** Oracle accepts the message and responds (does not close connection)
**And** AUTH_PHASE_TWO can proceed

**AC3: All integration tests pass**
**Given** the authentication fix is implemented
**When** running integration tests against Oracle 23ai Docker
**Then** authentication succeeds (no ORA-12547 errors)
**And** connection is established successfully
**And** basic queries can be executed (validates Story 2.1 foundation)

**AC4: Document findings**
**Given** the bug is fixed
**When** documenting the root cause
**Then** findings are added to architecture.md or technical notes
**And** protocol comparison details are documented for future reference
**And** any Oracle 23ai-specific protocol requirements are noted

**Priority:** 🔥 CRITICAL - Blocks all Epic 2+ work

### Story 1.5: Connection API & Error Handling

As a **developer using dart-oracledb**,
I want **a simple connection API with clear error handling**,
So that **I can connect to Oracle with minimal code and debug issues easily**.

**Acceptance Criteria:**

**Given** valid connection parameters
**When** calling `OracleConnection.connect('host:port/service', user: 'x', password: 'y')`
**Then** a connected `OracleConnection` instance is returned
**And** the connection is ready for queries

**Given** a connection failure (network, auth, or Oracle error)
**When** `connect()` is called
**Then** an `OracleException` is thrown with:
- `errorCode` property containing ORA-xxxxx code (FR40)
- `message` property with clear description (FR41)
- `cause` property preserving original error for debugging
**And** `OracleException` can be caught and handled (FR43)

**Given** integration test environment
**When** running tests against Oracle 23ai Docker
**Then** connection succeeds and basic connectivity is verified

### Story 1.6: TLS/SSL Support

As a **developer using dart-oracledb**,
I want **TLS/SSL encrypted connections**,
So that **I can securely connect to production Oracle databases** (FR3, NFR6).

**Acceptance Criteria:**

**Given** an Oracle database configured for TLS
**When** connecting with TLS enabled
**Then** the connection is encrypted using TLS/SSL
**And** certificate validation occurs (configurable)

**Given** TLS is required but server doesn't support it
**When** connection is attempted
**Then** a clear error indicates TLS negotiation failed

### Story 1.7: Connection Lifecycle Management

As a **developer using dart-oracledb**,
I want **connection timeout, close, and health check capabilities**,
So that **I can manage connection lifecycle reliably** (FR4, FR5, FR6).

**Acceptance Criteria:**

**Given** a connection timeout is specified
**When** connection takes longer than the timeout
**Then** an `OracleException` is thrown indicating timeout (FR4)

**Given** an open connection
**When** `connection.close()` is called
**Then** the connection is gracefully closed
**And** all resources are released (NFR10)
**And** subsequent operations throw "connection closed" error (FR5)

**Given** an open connection
**When** `connection.ping()` or `connection.isHealthy` is called
**Then** true is returned if connection is alive
**And** false is returned if connection is broken (FR6, NFR8)

## Epic 2: Query Execution & Transactions

Developer can execute CRUD operations (SELECT, INSERT, UPDATE, DELETE) with named and positional bind parameters, iterate over results, access columns by name or index, and manage transactions with commit/rollback.

**FRs covered:** FR13, FR14, FR15, FR16, FR17, FR18, FR19, FR20, FR21, FR22, FR23, FR24, FR30, FR31, FR32, FR33, FR42, FR44, FR45

**Technical notes:** Includes basic data type mapping (String, Number, DateTime) and statement caching for performance.

### Story 2.1: Execute Message & Basic Query

As a **developer using dart-oracledb**,
I want **to execute a simple SELECT query**,
So that **I can retrieve data from Oracle tables**.

**Acceptance Criteria:**

**Given** an authenticated connection
**When** calling `connection.execute('SELECT * FROM dual')`
**Then** the TTC EXECUTE message is sent to Oracle
**And** the response is received and parsed
**And** an `OracleResult` object is returned

**Given** a SELECT query with no bind parameters
**When** executed against a table with data
**Then** rows are returned in the result

### Story 2.2: Result Set Handling

As a **developer using dart-oracledb**,
I want **to iterate over query results and access column values**,
So that **I can process data returned from Oracle** (FR19, FR20, FR21).

**Acceptance Criteria:**

**Given** an `OracleResult` from a SELECT query
**When** iterating with `for (final row in result.rows)`
**Then** each `OracleRow` is accessible sequentially (FR19)

**Given** an `OracleRow` instance
**When** accessing `row['column_name']`
**Then** the column value is returned by name (FR20)

**Given** an `OracleRow` instance
**When** accessing `row[0]`
**Then** the column value is returned by index (FR21)

**Given** a result set with multiple rows
**When** accessing `result.rowCount`
**Then** the number of rows is returned

**Given** a column that doesn't exist
**When** accessing `row['nonexistent']`
**Then** null is returned or appropriate error is raised

### Story 2.3: Bind Parameters

As a **developer using dart-oracledb**,
I want **to use bind parameters in queries**,
So that **I can safely pass values and prevent SQL injection** (FR17, FR18).

**Acceptance Criteria:**

**Given** a query with named bind parameters
**When** calling `connection.execute('SELECT * FROM emp WHERE dept_id = :dept', {'dept': 10})`
**Then** the query executes with the bound value (FR17)
**And** the parameter is properly encoded for Oracle

**Given** a query with positional bind parameters
**When** calling `connection.execute('SELECT * FROM emp WHERE dept_id = :1', [10])`
**Then** the query executes with the bound value (FR18)

**Given** multiple bind parameters
**When** executing `SELECT * FROM emp WHERE dept_id = :dept AND salary > :sal`
**Then** all parameters are bound correctly

**Given** a null bind value
**When** executing the query
**Then** Oracle NULL is properly bound

### Story 2.4: DML Operations (INSERT, UPDATE, DELETE)

As a **developer using dart-oracledb**,
I want **to execute INSERT, UPDATE, and DELETE statements**,
So that **I can modify data in Oracle tables** (FR14, FR15, FR16).

**Acceptance Criteria:**

**Given** an INSERT statement with bind parameters
**When** calling `connection.execute('INSERT INTO emp (id, name) VALUES (:1, :2)', [1, 'John'])`
**Then** the row is inserted (FR14)
**And** `result.rowsAffected` returns 1

**Given** an UPDATE statement
**When** calling `connection.execute('UPDATE emp SET name = :1 WHERE id = :2', ['Jane', 1])`
**Then** matching rows are updated (FR15)
**And** `result.rowsAffected` returns the count of updated rows

**Given** a DELETE statement
**When** calling `connection.execute('DELETE FROM emp WHERE id = :1', [1])`
**Then** matching rows are deleted (FR16)
**And** `result.rowsAffected` returns the count of deleted rows

### Story 2.5: Transaction Management

As a **developer using dart-oracledb**,
I want **to control transaction boundaries with commit and rollback**,
So that **I can ensure data consistency** (FR22, FR23, FR24).

**Acceptance Criteria:**

**Given** a connection with pending changes
**When** calling `connection.commit()`
**Then** all changes are committed to the database (FR22)

**Given** a connection with pending changes
**When** calling `connection.rollback()`
**Then** all changes are rolled back (FR23)

**Given** multiple DML statements
**When** executed before commit
**Then** all changes are part of the same transaction (FR24)
**And** a single rollback undoes all changes

**Given** a convenience wrapper is needed
**When** using `connection.runTransaction((conn) async { ... })`
**Then** auto-commit on success, auto-rollback on exception

### Story 2.6: Basic Data Type Mapping

As a **developer using dart-oracledb**,
I want **Oracle data types mapped to Dart types**,
So that **I can work with query results naturally** (FR30, FR31, FR32, FR33).

**Acceptance Criteria:**

**Given** a column of type VARCHAR2, VARCHAR, or CHAR
**When** reading the value
**Then** it is returned as Dart `String` (FR30)

**Given** a column of type NUMBER
**When** reading an integer value
**Then** it is returned as Dart `int` (FR31)

**Given** a column of type NUMBER with decimals
**When** reading the value
**Then** it is returned as Dart `double` (FR31)

**Given** a column of type DATE
**When** reading the value
**Then** it is returned as Dart `DateTime` (FR32)

**Given** a column of type TIMESTAMP
**When** reading the value
**Then** it is returned as Dart `DateTime` with sub-second precision (FR33)

**Given** a NULL value in any column
**When** reading the value
**Then** Dart `null` is returned

### Story 2.7: Statement Caching

As a **developer using dart-oracledb**,
I want **prepared statements cached for reuse**,
So that **repeated queries execute faster** (FR44, FR45, NFR2).

**Acceptance Criteria:**

**Given** a query executed multiple times
**When** using statement caching
**Then** the statement is prepared once and reused (FR44)
**And** subsequent executions skip the parse phase (NFR2)

**Given** a connection with statement cache
**When** configuring `statementCacheSize: 50`
**Then** up to 50 statements are cached (FR45)

**Given** the cache is full
**When** a new statement is prepared
**Then** the least recently used statement is evicted

### Story 2.8: Query Error Handling

As a **developer using dart-oracledb**,
I want **clear error messages when queries fail**,
So that **I can debug SQL issues efficiently** (FR42).

**Acceptance Criteria:**

**Given** a query with syntax error
**When** executed
**Then** an `OracleException` is thrown with ORA-00900 series error
**And** the error message includes the SQL causing the issue (FR42)

**Given** a query referencing non-existent table
**When** executed
**Then** an `OracleException` is thrown with ORA-00942 (table or view does not exist)

**Given** a constraint violation (e.g., duplicate key)
**When** executing INSERT/UPDATE
**Then** an `OracleException` is thrown with appropriate ORA code

## Epic 3: PL/SQL Execution

Developer can call stored procedures and functions with IN, OUT, and IN OUT parameter binding, and retrieve function return values.

**FRs covered:** FR25, FR26, FR27, FR28, FR29

### Story 3.1: Call Stored Procedures

As a **developer using dart-oracledb**,
I want **to call stored procedures with IN parameters**,
So that **I can execute server-side business logic** (FR25, FR27).

**Acceptance Criteria:**

**Given** a stored procedure exists in the database
**When** calling `connection.execute('BEGIN my_proc(:1, :2); END;', [param1, param2])`
**Then** the procedure is executed successfully (FR25)
**And** IN parameters are passed correctly (FR27)

**Given** a procedure with no parameters
**When** calling `connection.execute('BEGIN simple_proc(); END;')`
**Then** the procedure executes successfully

**Given** a procedure that raises an Oracle error
**When** executed
**Then** an `OracleException` is thrown with the appropriate ORA code

### Story 3.2: Call Functions with Return Values

As a **developer using dart-oracledb**,
I want **to call functions and retrieve return values**,
So that **I can use server-side computations** (FR26).

**Acceptance Criteria:**

**Given** a function that returns a value
**When** calling with return parameter binding
**Then** the function return value is accessible (FR26)

**Given** a function `get_employee_count(dept_id) RETURN NUMBER`
**When** executed with proper binding
**Then** the numeric return value is returned as Dart `int` or `double`

**Given** a function returning VARCHAR2
**When** executed
**Then** the return value is returned as Dart `String`

### Story 3.3: OUT and IN OUT Parameters

As a **developer using dart-oracledb**,
I want **to use OUT and IN OUT parameters with procedures/functions**,
So that **I can retrieve multiple output values** (FR28, FR29).

**Acceptance Criteria:**

**Given** a procedure with OUT parameters
**When** calling with output bindings configured
**Then** OUT parameter values are retrievable after execution (FR28)

**Given** a procedure with IN OUT parameters
**When** calling with a value that gets modified
**Then** the modified value is returned (FR29)

**Given** multiple OUT parameters
**When** executing the procedure
**Then** all output values are accessible by parameter name or position

**Given** an OUT parameter that is NULL
**When** the procedure completes
**Then** Dart `null` is returned for that parameter

## Epic 4: Advanced Data Types (LOB, RAW, JSON)

Developer can work with large objects (CLOB as String, BLOB as Uint8List), binary RAW data, and Oracle JSON mapped to Dart Map/List.

**FRs covered:** FR34, FR35, FR36, FR37, FR38, FR39

### Story 4.1: CLOB Support

As a **developer using dart-oracledb**,
I want **to read and write CLOB data**,
So that **I can work with large text content** (FR34, FR35).

**Acceptance Criteria:**

**Given** a table with a CLOB column containing text
**When** executing a SELECT query
**Then** the CLOB value is returned as Dart `String` (FR34)

**Given** a String value to insert into a CLOB column
**When** executing an INSERT with the String bound
**Then** the CLOB is written successfully (FR35)

**Given** a CLOB with large content (e.g., 100KB)
**When** reading the value
**Then** the complete content is returned as String

**Given** a NULL CLOB value
**When** reading the column
**Then** Dart `null` is returned

### Story 4.2: BLOB Support

As a **developer using dart-oracledb**,
I want **to read and write BLOB data**,
So that **I can work with binary content** (FR36, FR37).

**Acceptance Criteria:**

**Given** a table with a BLOB column containing binary data
**When** executing a SELECT query
**Then** the BLOB value is returned as Dart `Uint8List` (FR36)

**Given** a Uint8List value to insert into a BLOB column
**When** executing an INSERT with the Uint8List bound
**Then** the BLOB is written successfully (FR37)

**Given** a BLOB with binary content (e.g., image data)
**When** reading the value
**Then** the complete binary content is returned

**Given** a NULL BLOB value
**When** reading the column
**Then** Dart `null` is returned

### Story 4.3: RAW Data Type

As a **developer using dart-oracledb**,
I want **RAW columns mapped to Uint8List**,
So that **I can work with fixed-length binary data** (FR38).

**Acceptance Criteria:**

**Given** a table with a RAW column
**When** executing a SELECT query
**Then** the RAW value is returned as Dart `Uint8List` (FR38)

**Given** a Uint8List value to insert into a RAW column
**When** executing an INSERT
**Then** the RAW data is written successfully

**Given** a NULL RAW value
**When** reading the column
**Then** Dart `null` is returned

### Story 4.4: JSON Data Type

As a **developer using dart-oracledb**,
I want **Oracle JSON columns mapped to Dart Map/List**,
So that **I can work with structured JSON data** (FR39).

**Acceptance Criteria:**

**Given** a table with a JSON column containing an object
**When** executing a SELECT query
**Then** the JSON value is returned as Dart `Map<String, dynamic>` (FR39)

**Given** a table with a JSON column containing an array
**When** executing a SELECT query
**Then** the JSON value is returned as Dart `List<dynamic>`

**Given** a Dart Map or List to insert into a JSON column
**When** executing an INSERT
**Then** the JSON is written successfully

**Given** a NULL JSON value
**When** reading the column
**Then** Dart `null` is returned

## Epic 5: Connection Pooling

Developer can efficiently manage connections for production workloads with configurable pool size, acquire/release operations, timeout handling, and session tagging.

**FRs covered:** FR7, FR8, FR9, FR10, FR11, FR12

### Story 5.1: Create Connection Pool

As a **developer using dart-oracledb**,
I want **to create a connection pool with configurable size**,
So that **I can efficiently manage connections for production workloads** (FR7).

**Acceptance Criteria:**

**Given** connection parameters and pool configuration
**When** calling `OraclePool.create('host:port/service', user: 'x', password: 'y', minConnections: 2, maxConnections: 10)`
**Then** a pool is created with minimum connections pre-established (FR7)
**And** the pool is ready to serve connection requests

**Given** pool configuration with min > max
**When** creating the pool
**Then** an error is raised indicating invalid configuration

**Given** a pool with minConnections: 2
**When** pool initialization completes
**Then** 2 connections are already established and ready

### Story 5.2: Acquire and Release Connections

As a **developer using dart-oracledb**,
I want **to acquire and release connections from the pool**,
So that **I can reuse connections efficiently** (FR8, FR9, NFR3).

**Acceptance Criteria:**

**Given** an active connection pool
**When** calling `pool.acquire()`
**Then** a connection is returned from the pool (FR8)
**And** the connection is marked as in-use

**Given** an acquired connection
**When** calling `pool.release(connection)`
**Then** the connection is returned to the pool for reuse (FR9)
**And** the connection remains open

**Given** a convenience pattern is needed
**When** using `pool.withConnection((conn) async { ... })`
**Then** connection is auto-acquired before callback
**And** connection is auto-released after callback completes
**And** connection is released even if callback throws

**Given** all connections are in use and max is reached
**When** calling `pool.acquire()`
**Then** the call waits until a connection becomes available

### Story 5.3: Pool Timeout and Cleanup

As a **developer using dart-oracledb**,
I want **pool timeout settings and proper cleanup**,
So that **the pool handles failures gracefully** (FR10, FR11, NFR9).

**Acceptance Criteria:**

**Given** pool timeout configuration
**When** `pool.acquire()` waits longer than `acquireTimeout`
**Then** an `OracleException` is thrown indicating timeout (FR10)

**Given** an idle connection in the pool
**When** idle time exceeds `idleTimeout`
**Then** the connection is closed and removed from pool

**Given** a connection becomes unhealthy
**When** detected during acquire or health check
**Then** the connection is removed and a new one created (NFR9)

**Given** an active pool
**When** calling `pool.close()`
**Then** all connections are gracefully closed (FR11)
**And** pending acquires are rejected
**And** the pool cannot be used afterward

### Story 5.4: Session Tagging

As a **developer using dart-oracledb**,
I want **to set and retrieve session tags on pooled connections**,
So that **I can maintain session state across acquire/release cycles** (FR12).

**Acceptance Criteria:**

**Given** an acquired connection from the pool
**When** setting `connection.tag = 'user:123'`
**Then** the tag is associated with the connection (FR12)

**Given** a tagged connection is released
**When** acquiring with `pool.acquire(tag: 'user:123')`
**Then** a connection with matching tag is preferred if available

**Given** no connection with matching tag exists
**When** acquiring with a tag
**Then** any available connection is returned
**And** the caller can set the new tag
