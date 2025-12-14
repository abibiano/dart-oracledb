---
stepsCompleted: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
inputDocuments:
  - 'docs/analysis/product-brief-dart-oracledb-2025-12-14.md'
  - 'docs/analysis/brainstorming-session-2025-12-14.md'
documentCounts:
  briefs: 1
  research: 0
  brainstorming: 1
  projectDocs: 0
workflowType: 'prd'
lastStep: 11
project_name: 'dart-oracledb'
user_name: 'Alex'
date: '2025-12-14'
---

# Product Requirements Document - dart-oracledb

**Author:** Alex
**Date:** 2025-12-14

## Executive Summary

**dart-oracledb** is a pure Dart Oracle Database driver implementing the thin-mode TNS/TTC wire protocol. It enables Dart and Flutter developers to connect directly to Oracle databases without requiring Oracle Client installation or native dependencies.

The project addresses a critical gap in the Dart ecosystem: enterprise developers currently have no viable path to Oracle connectivity. The only existing Dart Oracle package is abandoned, requires the Oracle thick client, and fails entirely on Apple Silicon—blocking a significant portion of modern development environments.

By porting the official node-oracledb thin driver architecture to Dart, this project brings Oracle database access to Dart backend frameworks (like Serverpod) and desktop applications, with the same developer experience as established packages like `package:postgres` or `package:sqlite3`.

### What Makes This Special

1. **Pure Dart** - Zero native dependencies, works everywhere Dart runs including Apple Silicon
2. **Thin Protocol** - Direct TNS/TTC wire protocol implementation, no middleware or Oracle Client required
3. **Apple Silicon Native** - First-class support for modern Mac development environments where the existing package fails
4. **Oracle 23ai Ready** - Supports latest Oracle LTS with modern authentication (SHA512/PBKDF2)
5. **Maintainable Architecture** - Mirrors official node-oracledb structure for long-term sustainability and easier upstream sync
6. **First-Class Dart API** - Idiomatic Dart interface matching ecosystem conventions

## Project Classification

**Technical Type:** developer_tool (SDK/library/package)
**Domain:** general (infrastructure tooling)
**Complexity:** Low domain complexity, High technical complexity
**Project Context:** Greenfield - new project

This is a database connectivity library targeting enterprise Dart developers. While not subject to domain-specific regulations (healthcare, fintech, etc.), the technical implementation complexity is high due to the TNS/TTC protocol stack, cryptographic authentication, and cross-platform socket handling.

## Success Criteria

### User Success

**Primary Success Indicator:** A user has succeeded when they can add dart-oracledb to their project, configure a connection string, and execute their first query returning data—with the same ease as using `package:postgres`.

**Success Moments:**

- **Connection Success:** User connects to Oracle database without errors
- **CRUD Completion:** User performs INSERT, SELECT, UPDATE, DELETE operations successfully
- **"It Works" Moment:** First query returns rows matching expected Oracle data

**API Familiarity Benchmark:** The API should feel immediately familiar to developers who have used `package:postgres` or `package:sqlite3`. If a developer knows those packages, they should be able to use dart-oracledb with minimal learning curve.

### Business Success

**Primary Goal:** Production reliability—the package works reliably in the author's own production environment.

**Secondary Goal:** Community validation through pub.dev likes and popularity score, indicating developer satisfaction and adoption.

### Technical Success

- All core integration tests passing against Oracle 23ai
- Cross-platform verified: macOS (Apple Silicon), Windows, Linux
- Zero critical bugs in production use
- API consistency with Dart database package conventions
- Connection pooling performs adequately for production workloads

### Measurable Outcomes

| Metric | Target | Validation |
|--------|--------|------------|
| Production Stability | Runs reliably in author's production environment | Real-world usage without critical failures |
| Test Coverage | Core integration tests passing | CI against Oracle 23ai |
| Platform Support | Works on macOS Apple Silicon, Windows, Linux | Cross-platform test runs |
| API Familiarity | Comparable to `package:postgres` | Developer feedback, API review |
| Community Reception | Positive pub.dev likes/popularity | pub.dev metrics |

## Product Scope

### MVP - Minimum Viable Product

**Connection & Authentication:**

- Connect to Oracle 23ai with modern authentication (SHA512/PBKDF2)
- EZ Connect string parsing (host:port/service)
- TLS/SSL support
- Connection timeout handling

**Connection Pooling:**

- Min/max pool size configuration
- Connection acquisition and release
- Pool timeout and cleanup
- Session tagging support

**CRUD Operations:**

- SELECT, INSERT, UPDATE, DELETE execution
- Bind parameter support (positional and named)
- Transaction management (commit, rollback)
- Statement caching for performance

**PL/SQL Execution:**

- Call stored procedures
- Call functions with return values
- IN/OUT/IN OUT parameter binding

**Data Types:**

- VARCHAR/VARCHAR2, CHAR
- NUMBER (integers and decimals)
- DATE, TIMESTAMP
- CLOB/BLOB (basic read/write as values)
- RAW
- JSON

### Growth Features (Post-MVP)

**Phase 3 - Extended Features:**

- Advanced LOB streaming (chunked read/write, temporary LOBs)
- DB Object support (Oracle object types, collections)
- Enhanced JSON capabilities

### Vision (Future)

**Phase 4 - Advanced Features:**

- Advanced Queuing (AQ) for message-based applications
- Vector type support for Oracle 23ai AI workloads
- SODA document store API
- XA transaction support

**Long-term:**

- Serverpod integration package
- Performance optimizations (AOT compilation guidance)
- Community-driven feature expansion

## User Journeys

### Journey 1: Alex Chen - Finally Connecting to Oracle

Alex is a senior developer at a mid-size insurance company that runs everything on Oracle. He's been championing Dart for a new internal tool, but keeps hitting the same wall: "How do we connect to Oracle?" His team has been using a clunky REST API wrapper around a Python service just to query their Oracle databases, adding latency and another service to maintain.

One afternoon, while searching pub.dev for the hundredth time, Alex notices a new package: dart-oracledb. "Pure Dart... no Oracle Client required... Apple Silicon support." He's skeptical—he's been burned before by the abandoned oracle package that never worked on his M2 MacBook.

He adds the dependency to his `pubspec.yaml` and writes his first connection:

```dart
final connection = await OracleConnection.connect(
  'localhost:1521/FREEPDB1',
  user: 'hr',
  password: 'password',
);
```

The connection opens. No errors. No "Oracle Client not found." No architecture mismatch. Just... a connection.

He writes a simple query against the HR schema he knows by heart:

```dart
final result = await connection.execute(
  'SELECT employee_id, first_name FROM employees WHERE department_id = :dept',
  {'dept': 60},
);
for (final row in result.rows) {
  print('${row['employee_id']}: ${row['first_name']}');
}
```

The employee names appear in his terminal. Alex sits back and smiles. Tomorrow, he's going to propose retiring that Python middleware service.

### Journey 2: Alex Chen - When Things Go Wrong

Two weeks into using dart-oracledb in his project, Alex hits his first real issue. His application starts throwing connection errors intermittently during peak hours. The error message reads: `ORA-12516: TNS:listener could not find available handler`.

Alex's first instinct is to check if the package is the problem. He looks at the error—it's a real Oracle error code, not some cryptic Dart exception. That's reassuring. He Googles "ORA-12516" and quickly learns it's a connection pool exhaustion issue on the Oracle side, not a driver bug.

He realizes he's creating new connections for every request instead of using the connection pool. He refactors:

```dart
final pool = await OraclePool.create(
  'localhost:1521/FREEPDB1',
  user: 'hr',
  password: 'password',
  minConnections: 2,
  maxConnections: 10,
);

// In his request handler:
final connection = await pool.acquire();
try {
  final result = await connection.execute('SELECT ...');
  // process result
} finally {
  await pool.release(connection);
}
```

The intermittent errors disappear. Alex appreciates that the error surfaced the real Oracle error code rather than wrapping it in something unhelpful. When his junior developer asks about the fix, Alex can point to standard Oracle documentation—the same troubleshooting path he'd use with any Oracle driver.

A month later, when a query returns unexpected `null` values for a TIMESTAMP column, Alex checks the dart-oracledb README and finds a note about timezone handling. The fix is a one-line configuration change. The driver behaves predictably, and when it doesn't, the errors point him in the right direction.

### Journey Requirements Summary

These journeys reveal the following capability requirements:

| Capability Area | Requirements |
|-----------------|--------------|
| **Onboarding** | Simple dependency add, minimal configuration, familiar connect pattern |
| **Connection Management** | Single connections and connection pooling with min/max settings |
| **Query Execution** | Bind parameters (named), result iteration, column access by name |
| **Error Handling** | Pass-through Oracle error codes (ORA-xxxxx), clear error messages |
| **Documentation** | README with common patterns, timezone/type handling notes |

## Developer Tool Specific Requirements

### Project-Type Overview

dart-oracledb is a Dart package/library distributed via pub.dev, providing Oracle database connectivity for Dart developers. It follows standard Dart package conventions and integrates with existing Dart tooling.

### Language & Platform Matrix

| Aspect | Requirement |
|--------|-------------|
| **Language** | Dart |
| **Minimum SDK** | Dart 3.0+ |
| **Platforms** | macOS (Apple Silicon, Intel), Windows, Linux |
| **Compilation** | JIT (development), AOT (production) |
| **Mobile/Web** | Not supported (requires dart:io Socket) |

### Installation & Distribution

**Primary Distribution:** pub.dev

**Installation Method:**

```yaml
dependencies:
  oracledb: ^1.0.0
```

**Dependencies:**

- `package:crypto` - Cryptographic operations for authentication
- `pointycastle` - Additional crypto (PBKDF2, etc.)
- No native dependencies required

### API Surface

The public API should be minimal and familiar to Dart database package users:

**Core Classes:**

- `OracleConnection` - Single database connection
- `OraclePool` - Connection pool management
- `OracleResult` - Query result container
- `OracleRow` - Single row accessor
- `OracleException` - Error handling with Oracle error codes

**Key Methods:**

- `OracleConnection.connect()` - Establish connection
- `connection.execute()` - Execute SQL with bind parameters
- `connection.commit()` / `connection.rollback()` - Transaction control
- `OraclePool.create()` - Create connection pool
- `pool.acquire()` / `pool.release()` - Pool operations

### Documentation Requirements

**MVP Documentation:**

| Document | Content | Priority |
|----------|---------|----------|
| **README.md** | Quick start, installation, basic examples, troubleshooting | Required |
| **API Docs** | Generated dartdoc for all public APIs | Required |
| **CHANGELOG.md** | Version history and breaking changes | Required |

**README Structure:**

1. Overview and features
2. Installation
3. Quick start (connection + first query)
4. Connection pooling example
5. Bind parameters and transactions
6. PL/SQL execution
7. Data type mapping table
8. Error handling
9. Troubleshooting common issues

### Code Examples

Examples will be embedded in README.md covering:

- Basic connection and query
- Connection pooling
- Bind parameters (named)
- Transaction management
- PL/SQL procedure/function calls
- Error handling patterns

### Implementation Considerations

**Structural Fidelity:**
Mirror node-oracledb thin driver structure for maintainability and easier upstream sync.

**Testing Strategy:**

- Unit tests for protocol encoding/decoding
- Integration tests against Oracle 23ai (Docker or Cloud Free Tier)
- Cross-platform CI verification

**Performance:**

- Crypto operations slower in Dart (acceptable with pooling)
- AOT compilation recommended for production deployments
- Connection pooling essential for high-throughput applications

## Project Scoping & Phased Development

### MVP Strategy & Philosophy

**MVP Approach:** Platform MVP - Build solid foundation for future expansion
**Resource Model:** Solo developer
**Reference Architecture:** node-oracledb thin driver (proven, tested implementation)

### MVP Validation

The MVP scope defined in Product Scope section has been validated:

| Category | MVP Features | Validation |
|----------|--------------|------------|
| **Connection** | Connect, Auth (SHA512/PBKDF2), TLS, Timeout | Essential for any database operation |
| **Pooling** | Min/max config, acquire/release, cleanup | Required for production workloads |
| **CRUD** | Execute, bind params, transactions, caching | Core developer workflow |
| **PL/SQL** | Procedures, functions, IN/OUT params | Enterprise requirement |
| **Data Types** | VARCHAR, NUMBER, DATE, TIMESTAMP, CLOB/BLOB, RAW, JSON | Covers common use cases |

**MVP Success Criteria:** User can connect to Oracle 23ai, execute queries with bind parameters, and manage transactions—with the same ease as `package:postgres`.

### Risk Mitigation Strategy

| Risk Type | Risk | Mitigation |
|-----------|------|------------|
| **Technical** | Crypto/authentication byte-level compatibility | Port directly from node-oracledb's tested implementation |
| **Technical** | Protocol encoding endianness | Explicit Endian.big/little in all buffer operations |
| **Technical** | Cross-platform socket handling | Use dart:io Socket with platform-specific testing |
| **Resource** | Solo developer capacity | Leverage structural fidelity with node-oracledb for clear porting path |

### Development Sequence

1. **Phase 1 (MVP):** Core connectivity, pooling, CRUD, PL/SQL, basic types
2. **Phase 3 (Growth):** Advanced LOB, DB Objects, enhanced JSON
3. **Phase 4 (Expansion):** AQ, Vector, SODA, XA transactions

## Functional Requirements

### Connection Management

- FR1: Developer can establish a connection to Oracle database using an EZ Connect string (host:port/service)
- FR2: Developer can authenticate using username and password with SHA512/PBKDF2 verifiers
- FR3: Developer can establish a TLS/SSL encrypted connection
- FR4: Developer can specify connection timeout duration
- FR5: Developer can close a connection and release associated resources
- FR6: Developer can check if a connection is still valid/alive

### Connection Pooling

- FR7: Developer can create a connection pool with configurable minimum and maximum size
- FR8: Developer can acquire a connection from the pool
- FR9: Developer can release a connection back to the pool
- FR10: Developer can configure pool timeout settings
- FR11: Developer can close a pool and release all connections
- FR12: Developer can set session tags on pooled connections

### Query Execution

- FR13: Developer can execute a SELECT query and retrieve results
- FR14: Developer can execute an INSERT statement
- FR15: Developer can execute an UPDATE statement
- FR16: Developer can execute a DELETE statement
- FR17: Developer can use named bind parameters in queries (e.g., :param_name)
- FR18: Developer can use positional bind parameters in queries
- FR19: Developer can iterate over query result rows
- FR20: Developer can access column values by column name
- FR21: Developer can access column values by column index

### Transaction Management

- FR22: Developer can commit a transaction
- FR23: Developer can rollback a transaction
- FR24: Developer can execute multiple statements within a single transaction

### PL/SQL Execution

- FR25: Developer can call a stored procedure
- FR26: Developer can call a function and retrieve the return value
- FR27: Developer can pass IN parameters to procedures/functions
- FR28: Developer can retrieve OUT parameter values from procedures/functions
- FR29: Developer can use IN OUT parameters with procedures/functions

### Data Type Handling

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

### Error Handling

- FR40: System surfaces Oracle error codes (ORA-xxxxx) in exceptions
- FR41: System provides clear error messages for connection failures
- FR42: System provides clear error messages for query execution failures
- FR43: Developer can catch and handle OracleException types

### Statement Caching

- FR44: System caches prepared statements for performance
- FR45: Developer can configure statement cache size

## Non-Functional Requirements

### Performance

- NFR1: Query execution overhead from the driver should be minimal compared to network round-trip time
- NFR2: Statement caching should reduce repeated query parsing overhead
- NFR3: Connection pooling should eliminate per-request connection establishment cost
- NFR4: Crypto/authentication latency is acceptable during initial connection (mitigated by pooling)

### Security

- NFR5: Database credentials must never be logged or exposed in error messages
- NFR6: TLS/SSL encryption must be supported for production connections
- NFR7: Authentication must use Oracle's secure verifier protocols (SHA512/PBKDF2)

### Reliability

- NFR8: System should detect broken connections and surface clear errors
- NFR9: Connection pool should handle connection failures gracefully (remove dead connections, create new ones)
- NFR10: System should properly release resources on connection close (no resource leaks)

### Compatibility

- NFR11: Package must support Dart SDK 3.0+
- NFR12: Package must work on macOS (Apple Silicon and Intel), Windows, and Linux
- NFR13: Package must support Oracle 23ai with modern authentication
- NFR14: Package must compile and run in both JIT (development) and AOT (production) modes
