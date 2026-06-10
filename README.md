# oracledb

A pure Dart Oracle Database driver implementing the thin-mode TNS/TTC wire protocol. No Oracle Client libraries required.

[![Pub Version](https://img.shields.io/pub/v/oracledb)](https://pub.dev/packages/oracledb)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Dart SDK](https://img.shields.io/badge/dart-%3E%3D3.12.0-blue)](https://dart.dev)

> **Pre-1.0 — stable-leaning API.** Connections, authentication, queries, DML, transactions, statement caching, and PL/SQL (stored procedures, functions, OUT/IN OUT binds) are implemented and validated against Oracle 23ai and 21c. LOBs (CLOB/BLOB/JSON) and connection pooling are not yet implemented. Depend on `oracledb: ^0.9.0`; breaking changes before 1.0 will bump the minor version (0.10.0). 1.0.0 will follow once LOB support and connection pooling land.

> **This is NOT an official Oracle product.** It is an independent Dart port of the thin-client wire protocol as documented and implemented in Oracle's official [node-oracledb](https://github.com/oracle/node-oracledb) driver. Oracle Corporation is not affiliated with this project.

## Features

- **Pure Dart** — no FFI, no native code, no Oracle Instant Client required
- **Thin protocol** — direct TNS/TTC wire protocol implementation
- **Oracle 23ai + Oracle 21c** — tested against both; FAST_AUTH and classical auth paths both supported
- **Desktop & server platforms** — macOS, Windows, Linux (mobile untested; web unsupported — requires `dart:io` TCP sockets)
- **TLS/SSL** — encrypted connections with certificate validation
- **Full query support** — SELECT, INSERT, UPDATE, DELETE with positional and named bind parameters
- **PL/SQL** — stored procedures and functions with OUT / IN OUT bind parameters
- **Transactions** — commit, rollback, and transaction helper
- **TIMESTAMP WITH TIME ZONE** — decoded as UTC `DateTime`, or as `OracleTimestampTz` preserving the original offset (opt-in)
- **Statement caching** — transparent prepared-statement cache
- **Async/await** — modern Dart async API throughout

## Platform Support

| Platform | Supported |
|----------|-----------|
| macOS    | ✅ |
| Windows  | ✅ |
| Linux    | ✅ |
| iOS      | ⚠️ untested (not declared in `pubspec.yaml`) |
| Android  | ⚠️ untested (not declared in `pubspec.yaml`) |
| Web      | ❌ (requires raw TCP sockets via `dart:io`) |

## Supported Oracle Versions

- Oracle 23ai — FAST_AUTH protocol (single-round-trip authentication)
- Oracle 21c — classical AUTH_PHASE_ONE / AUTH_PHASE_TWO

Older versions (19c, 12c) may work but have not been tested.

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  oracledb: ^0.9.0
```

Then run:

```
dart pub get
```

## Quick Start

```dart
import 'package:oracledb/oracledb.dart';

Future<void> main() async {
  final connection = await OracleConnection.connect(
    'localhost:1521/FREEPDB1',
    user: 'testuser',
    password: 'testpassword',
  );

  try {
    final result = await connection.execute(
      'SELECT employee_id, first_name FROM employees WHERE department_id = :dept',
      {'dept': 10},
    );

    for (final row in result.rows) {
      print('${row['EMPLOYEE_ID']}: ${row['FIRST_NAME']}');  // by name
      // or: row[0], row[1]                                  // by index
    }
  } finally {
    await connection.close();
  }
}
```

## Usage

### Connecting

`connect` takes an EZ Connect string (`host:port/service`) as the first argument:

```dart
final conn = await OracleConnection.connect(
  'dbhost.example.com:1521/ORCL',
  user: 'username',
  password: 'password',
  timeout: const Duration(seconds: 30),
);
```

### Auto-closing with `withConnection`

```dart
await OracleConnection.withConnection(
  'localhost:1521/FREEPDB1',
  user: 'testuser',
  password: 'testpassword',
  callback: (conn) async {
    final result = await conn.execute('SELECT SYSDATE FROM dual');
    print(result.rows.first[0]);
  },
);
```

### Queries

```dart
// Named bind parameters (preferred)
final result = await connection.execute(
  'SELECT * FROM employees WHERE salary > :min_salary AND department_id = :dept',
  {'min_salary': 50000, 'dept': 10},
);

// Positional bind parameters
final result2 = await connection.execute(
  'SELECT * FROM employees WHERE salary > :1 AND department_id = :2',
  [50000, 10],
);

// Access rows and column metadata
print(result.columnNames);      // ['EMPLOYEE_ID', 'FIRST_NAME', ...]
for (final row in result.rows) {
  print(row['EMPLOYEE_ID']);    // by column name (case-insensitive)
  print(row[0]);                // or by zero-based index
  final map = row.toMap();      // {'EMPLOYEE_ID': 100, 'FIRST_NAME': 'Alice', ...}
}
```

### DML — Insert, Update, Delete

```dart
final result = await connection.execute(
  'UPDATE employees SET salary = salary * 1.1 WHERE department_id = :dept',
  {'dept': 10},
);
print('Rows affected: ${result.rowsAffected}');
```

### Transactions

```dart
// Managed transaction (automatic rollback on exception)
await connection.runTransaction((conn) async {
  await conn.execute(
    'INSERT INTO orders (id, customer_id) VALUES (:id, :cust)',
    {'id': 1001, 'cust': 42},
  );
  await conn.execute(
    'UPDATE inventory SET quantity = quantity - 1 WHERE product_id = :pid',
    {'pid': 100},
  );
});

// Manual commit/rollback
try {
  await connection.execute(
    'INSERT INTO orders (id, total) VALUES (:id, :total)',
    {'id': 1001, 'total': 99.99},
  );
  await connection.commit();
} catch (e) {
  await connection.rollback();
  rethrow;
}
```

### PL/SQL — Stored Procedures & Functions

```dart
// Call a stored procedure
await connection.execute(
  'BEGIN raise_salary(:dept, :pct); END;',
  {'dept': 10, 'pct': 5},
);

// Function return value via an OUT bind
final result = await connection.execute(
  'BEGIN :ret := get_employee_name(:id); END;',
  {
    'ret': OracleBind.out(type: OracleDbType.varchar, maxSize: 100),
    'id': 100,
  },
);
print(result.outBinds['ret']);

// IN OUT parameter
final r = await connection.execute(
  'BEGIN increment(:value); END;',
  {'value': OracleBind.inOut(value: 41, type: OracleDbType.number)},
);
print(r.outBinds['value']); // 42
```

`maxSize` is required for `varchar` and `raw` OUT binds — size it for the largest value the procedure may return.

`TIMESTAMP WITH TIME ZONE` parameters bind with `OracleDbType.timestampTz`. OUT / IN OUT values follow the connection's decode contract: a UTC `DateTime` by default, or an `OracleTimestampTz` carrying the server-sent offset on a connection opened with `preserveTimestampTimeZone: true`. IN OUT input values may be an `OracleTimestampTz` (the offset travels on the wire) or a plain `DateTime`.

### TLS/SSL Connections

```dart
import 'package:oracledb/oracledb.dart';

// TLS with certificate validation (recommended for production)
final conn = await OracleConnection.connect(
  'dbhost.example.com:2484/ORCL',
  user: 'username',
  password: 'password',
  tls: TlsConfig.enabled(),
);

// TLS with self-signed certificates (development)
final devConn = await OracleConnection.connect(
  'localhost:2484/FREEPDB1',
  user: 'testuser',
  password: 'testpassword',
  tls: TlsConfig.enabled(verifyCertificate: false),
);
```

Oracle typically uses port 2484 for TLS connections. TLS is disabled by default.

### Health Check

```dart
final isAlive = await connection.ping();
```

## API Reference

| Method | Description |
|--------|-------------|
| `OracleConnection.connect(...)` | Open a connection |
| `OracleConnection.withConnection(...)` | Open, use, and auto-close a connection |
| `connection.execute(sql, [bindValues])` | Run a query, DML statement, or PL/SQL block |
| `OracleBind.out(type: ..., maxSize: ...)` | Declare a PL/SQL OUT bind parameter |
| `OracleBind.inOut(value: ..., type: ...)` | Declare a PL/SQL IN OUT bind parameter |
| `result.outBinds` | OUT / IN OUT values, by name or position |
| `connection.ping()` | Send a ping to verify the connection is alive |
| `connection.commit()` | Commit the current transaction |
| `connection.rollback()` | Roll back the current transaction |
| `connection.runTransaction(callback)` | Run a callback inside a managed transaction |
| `connection.close()` | Close the connection |
| `connection.isConnected` | Whether the connection is open |
| `connection.isHealthy` | Synchronous connection state check (no network I/O) |
| `connection.statementCacheSize` | Configured statement cache size |

## Supported Data Types

| Oracle Type | Dart Type |
|-------------|-----------|
| VARCHAR2, CHAR, NVARCHAR2 | `String` |
| NUMBER | `num` / `int` / `double` |
| DATE | `DateTime` |
| TIMESTAMP | `DateTime` |
| TIMESTAMP WITH TIME ZONE | `DateTime` (UTC) — or `OracleTimestampTz` with `preserveTimestampTimeZone: true` |
| RAW | `Uint8List` |
| NULL | `null` |

## Project Status

This package implements a subset of the full Oracle driver feature set. Below is the current roadmap:

| Epic | Status |
|------|--------|
| Core connection & authentication | ✅ Done |
| Query execution & transactions | ✅ Done |
| PL/SQL execution (stored procedures, functions) | ✅ Done |
| Advanced data types (CLOB, BLOB, JSON) | 📋 Planned |
| Connection pooling | 📋 Planned |

## Tests

The project has an extensive test suite:

- **~818 unit tests** — covering protocol, crypto, transport, and connection layers
- **Integration tests** — run against real Oracle instances via Docker

```bash
# Unit tests (no database required)
dart test test/src/

# Integration tests — Oracle 23ai
docker compose up -d
RUN_INTEGRATION_TESTS=true dart test test/integration/

# Integration tests — Oracle 21c
#   On Apple Silicon, 21c has no native ARM build — run it under a Colima
#   x86_64 VM (see CONTRIBUTING.md for full setup):
#     colima start --arch x86_64 --cpu 6 --memory 8 && docker context use colima
docker compose --profile oracle21c up -d oracle21c
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/
```

## Known Limitations

- **Character sets** — the driver assumes the database character set is UTF-8 (`AL32UTF8`, the Oracle default since 12c). Data stored in non-UTF-8 character sets may decode incorrectly.
- **Statement cache and external DDL** — top-level DDL executed on the same connection clears the statement cache, but DDL issued from another session (or inside a PL/SQL block) can leave stale cached SELECT metadata. This matches node-oracledb thin-mode behavior.
- **NUMBER beyond 2⁵³** — integer-valued NUMBERs larger than 2⁵³ decode to `double` and lose precision (Dart `double` limit; matches node-oracledb).
- **One operation per connection** — a connection supports one in-flight operation; overlapping `execute()` calls throw. Use separate connections for concurrent work until connection pooling lands (see roadmap).
- **Pre-12c authentication** — password-verifier paths used by pre-12c servers are untested; the validated matrix is Oracle 21c (classical auth) and 23ai (FAST_AUTH).
- **Region-id time zones** — `TIMESTAMP WITH TIME ZONE` values stored with a region id (e.g. `Europe/Madrid`) are rejected on decode; offset-based zones (e.g. `+02:00`) are supported.
- **Very large result sets** — a single `execute()` is bounded by a safety cap of 1,000 fetch round-trips (about 50,000 rows at the default fetch size); if the cap is hit, a warning is logged, the rows fetched so far are returned, and `result.moreRowsAvailable` is `true` so the truncation is detectable. The same flag is also set (with a logged warning) in the rarer case where the server reports more rows pending but the driver has no usable cursor id to continue fetching — in either case `true` means the rows are an incomplete prefix of the full result set.

## Thin Mode Limitations

This driver implements Oracle's thin-mode protocol. The following features require Oracle Client (thick mode) and are **not supported**:

- SODA (Simple Oracle Document Access)
- Continuous Query Notification (CQN)
- External/Kerberos authentication
- Native Network Encryption (NNE)
- Application Continuity
- Client Result Cache

## Requirements

- Dart SDK >= 3.12.0
- Oracle Database 21c or later (older versions may work but are untested)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, test instructions, and contribution guidelines.

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.

## Acknowledgments

- [node-oracledb](https://github.com/oracle/node-oracledb) — Oracle's official Node.js driver, whose thin-client protocol implementation this project ports to Dart
- [python-oracledb](https://github.com/oracle/python-oracledb) — Oracle's official Python driver, used as a cross-reference for protocol details
- Ian Redfern's TNS/TTC protocol documentation
