# oracledb

A pure Dart Oracle Database driver implementing the thin-mode TNS/TTC wire protocol. No Oracle Client libraries required.

[![Pub Version](https://img.shields.io/pub/v/oracledb)](https://pub.dev/packages/oracledb)
[![pub pre-release](https://img.shields.io/pub/v/oracledb?label=pre-release&include_prereleases)](https://pub.dev/packages/oracledb)
[![CI](https://img.shields.io/github/actions/workflow/status/abibiano/dart-oracledb/ci.yml?branch=main&label=CI)](https://github.com/abibiano/dart-oracledb/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Dart SDK](https://img.shields.io/badge/dart-%3E%3D3.3.0-blue)](https://dart.dev)

> **Alpha — public API may change between releases.** Epics 1 & 2 (connection, auth, queries, DML, transactions) are stable. PL/SQL, LOBs, and connection pooling are not yet implemented. Pin to an exact version (`oracledb: 0.1.0-alpha.1`) until 1.0.

> **This is NOT an official Oracle product.** It is an independent Dart port of the thin-client wire protocol as documented and implemented in Oracle's official [node-oracledb](https://github.com/oracle/node-oracledb) driver. Oracle Corporation is not affiliated with this project.

## Features

- **Pure Dart** — no FFI, no native code, no Oracle Instant Client required
- **Thin protocol** — direct TNS/TTC wire protocol implementation
- **Oracle 23ai + Oracle 21c** — tested against both; FAST_AUTH and classical auth paths both supported
- **All Dart platforms** — macOS, Windows, Linux, iOS, Android (not web — requires TCP sockets)
- **TLS/SSL** — encrypted connections with certificate validation
- **Full query support** — SELECT, INSERT, UPDATE, DELETE with positional and named bind parameters
- **Transactions** — commit, rollback, and transaction helper
- **Statement caching** — transparent prepared-statement cache
- **Async/await** — modern Dart async API throughout

## Platform Support

| Platform | Supported |
|----------|-----------|
| macOS    | ✅ |
| Windows  | ✅ |
| Linux    | ✅ |
| iOS      | ✅ |
| Android  | ✅ |
| Web      | ❌ (requires raw TCP sockets via `dart:io`) |

## Supported Oracle Versions

- Oracle 23ai — FAST_AUTH protocol (single-round-trip authentication)
- Oracle 21c — classical AUTH_PHASE_ONE / AUTH_PHASE_TWO

Older versions (19c, 12c) may work but have not been tested.

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  oracledb: ^0.1.0
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
| `connection.execute(sql, [bindValues])` | Run a query or DML statement |
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
| RAW | `Uint8List` |
| NULL | `null` |

## Project Status

This package implements a subset of the full Oracle driver feature set. Below is the current roadmap:

| Epic | Status |
|------|--------|
| Core connection & authentication | ✅ Done |
| Query execution & transactions | ✅ Done |
| PL/SQL execution (stored procedures, functions) | 🔄 In progress |
| Advanced data types (CLOB, BLOB, RAW, JSON) | 📋 Planned |
| Connection pooling | 📋 Planned |

## Tests

The project has an extensive test suite:

- **~490 unit tests** — covering protocol, crypto, transport, and connection layers
- **Integration tests** — run against real Oracle instances via Docker

```bash
# Unit tests (no database required)
dart test test/src/

# Integration tests — Oracle 23ai
docker compose up -d
RUN_INTEGRATION_TESTS=true dart test test/integration/

# Integration tests — Oracle 21c
docker compose --profile oracle21c up -d
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/
```

## Thin Mode Limitations

This driver implements Oracle's thin-mode protocol. The following features require Oracle Client (thick mode) and are **not supported**:

- SODA (Simple Oracle Document Access)
- Continuous Query Notification (CQN)
- External/Kerberos authentication
- Native Network Encryption (NNE)
- Application Continuity
- Client Result Cache

## Requirements

- Dart SDK >= 3.3.0
- Oracle Database 21c or later (older versions may work but are untested)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, test instructions, and contribution guidelines.

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.

## Acknowledgments

- [node-oracledb](https://github.com/oracle/node-oracledb) — Oracle's official Node.js driver, whose thin-client protocol implementation this project ports to Dart
- [python-oracledb](https://github.com/oracle/python-oracledb) — Oracle's official Python driver, used as a cross-reference for protocol details
- Ian Redfern's TNS/TTC protocol documentation
