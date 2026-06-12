# oracledb

A pure Dart Oracle Database driver implementing the thin-mode TNS/TTC wire protocol. No Oracle Client libraries required.

[![Pub Version](https://img.shields.io/badge/pub-v0.9.3-orange)](https://pub.dev/packages/oracledb)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Dart SDK](https://img.shields.io/badge/dart-%3E%3D3.12.0-blue)](https://dart.dev)

> **Pre-1.0 — stable-leaning API.** Connections, authentication, queries, DML, transactions, statement caching, PL/SQL (stored procedures, functions, OUT/IN OUT binds), CLOB-as-String, BLOB-as-Uint8List, RAW-as-Uint8List, and native JSON-as-Map/List are implemented and validated against Oracle 23ai and 21c. Connection pooling is in progress: `OraclePool.create()` builds a pool of prewarmed authenticated sessions and `close()` releases them, but borrower semantics (`acquire`/`release`) are not yet available. Depend on `oracledb: ^0.9.3`; breaking changes before 1.0 will bump the minor version (0.10.0). 1.0.0 will follow once connection pooling lands.

> **This is NOT an official Oracle product.** It is an independent Dart port of the thin-client wire protocol as documented and implemented in Oracle's official [node-oracledb](https://github.com/oracle/node-oracledb) driver. Oracle Corporation is not affiliated with this project.

## Features

- **Pure Dart** — no FFI, no native code, no Oracle Instant Client required
- **Thin protocol** — direct TNS/TTC wire protocol implementation
- **Oracle 23ai + Oracle 21c** — tested against both; FAST_AUTH and classical auth paths both supported
- **Native Dart platforms** — macOS, Windows, Linux, Android, and iOS (web unsupported — requires `dart:io` TCP sockets)
- **TLS/SSL** — encrypted connections with certificate validation
- **Full query support** — SELECT, INSERT, UPDATE, DELETE with positional and named bind parameters
- **PL/SQL** — stored procedures and functions with OUT / IN OUT bind parameters
- **Transactions** — commit, rollback, and transaction helper
- **TIMESTAMP WITH TIME ZONE** — decoded as UTC `DateTime`, or as `OracleTimestampTz` preserving the original offset (opt-in)
- **Statement caching** — transparent prepared-statement cache
- **Async/await** — modern Dart async API throughout

## Platform Support

| Platform | Supported                                   |
| -------- | ------------------------------------------- |
| macOS    | ✅                                          |
| Windows  | ✅                                          |
| Linux    | ✅                                          |
| iOS      | ✅                                          |
| Android  | ✅                                          |
| Web      | ❌ (requires raw TCP sockets via `dart:io`) |

All supported native platforms are declared in `pubspec.yaml`. Desktop/server
targets are covered by CI. Android and iOS use the same `dart:io` TCP socket
transport, which is available on native Dart targets; mobile-specific runtime
validation is still expected before relying on them in production.

## Supported Oracle Versions

- Oracle 23ai — FAST_AUTH protocol (single-round-trip authentication)
- Oracle 21c — classical AUTH_PHASE_ONE / AUTH_PHASE_TWO

Older versions (19c, 12c) may work but have not been tested.

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  oracledb: ^0.9.3
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

| Method                                    | Description                                         |
| ----------------------------------------- | --------------------------------------------------- |
| `OracleConnection.connect(...)`           | Open a connection                                   |
| `OracleConnection.withConnection(...)`    | Open, use, and auto-close a connection              |
| `connection.execute(sql, [bindValues])`   | Run a query, DML statement, or PL/SQL block         |
| `OracleBind.out(type: ..., maxSize: ...)` | Declare a PL/SQL OUT bind parameter                 |
| `OracleBind.inOut(value: ..., type: ...)` | Declare a PL/SQL IN OUT bind parameter              |
| `result.outBinds`                         | OUT / IN OUT values, by name or position            |
| `connection.ping()`                       | Send a ping to verify the connection is alive       |
| `connection.commit()`                     | Commit the current transaction                      |
| `connection.rollback()`                   | Roll back the current transaction                   |
| `connection.runTransaction(callback)`     | Run a callback inside a managed transaction         |
| `connection.close()`                      | Close the connection                                |
| `connection.isConnected`                  | Whether the connection is open                      |
| `connection.isHealthy`                    | Synchronous connection state check (no network I/O) |
| `connection.statementCacheSize`           | Configured statement cache size                     |

## Supported Data Types

| Oracle Type               | Dart Type                                                                        |
| ------------------------- | -------------------------------------------------------------------------------- |
| VARCHAR2, CHAR, NVARCHAR2 | `String`                                                                         |
| NUMBER                    | `num` / `int` / `double`                                                         |
| DATE                      | `DateTime`                                                                       |
| TIMESTAMP                 | `DateTime`                                                                       |
| TIMESTAMP WITH TIME ZONE  | `DateTime` (UTC) — or `OracleTimestampTz` with `preserveTimestampTimeZone: true` |
| RAW                       | `Uint8List` (see [RAW support](#raw-support))                                    |
| CLOB                      | `String` (see [CLOB support](#clob-support))                                     |
| BLOB                      | `Uint8List` (see [BLOB support](#blob-support))                                  |
| JSON (21c+)               | `Map<String, Object?>` / `List<Object?>` (see [JSON support](#json-support))     |
| NULL                      | `null`                                                                           |

### RAW support

RAW values round-trip as Dart `Uint8List`s. RAW is a **scalar** binary type —
not a LOB and not a BLOB alias: values travel inline on the wire
(length-prefixed bytes, never a LOB locator), bytes are preserved exactly with
no character-set conversion, and RAW queries keep normal statement-cache
cursor reuse:

- **Queries** — selecting a `RAW` column returns a `Uint8List` (`null` for
  SQL NULL). Oracle stores a zero-length RAW as SQL NULL — there is no
  empty-but-not-NULL RAW value, so an inserted `Uint8List(0)` reads back as
  `null`.
- **DML** — bind an ordinary `Uint8List` into a `RAW` column with named or
  positional binds. A value longer than the column's declared byte size fails
  loudly with the Oracle error (ORA-12899) — never truncated or coerced. An
  **empty** `Uint8List` stores SQL NULL (Oracle's zero-length RAW
  convention); this differs from `OracleBind(type: OracleDbType.blob)`,
  which can preserve an empty-but-not-NULL BLOB through a temporary LOB.
- **PL/SQL OUT / IN OUT** — declare
  `OracleBind.out(type: OracleDbType.raw, maxSize: ...)` or
  `OracleBind.inOut(value: ..., type: OracleDbType.raw, maxSize: ...)`;
  values decode through `result.outBinds` as `Uint8List?`. `maxSize` counts
  **bytes** and must hold the largest value the procedure may return — an
  undersized buffer fails loudly with the server's ORA-06502 instead of
  truncating.

RAW columns hold up to 2000 bytes with `MAX_STRING_SIZE=STANDARD` (32,767
with `EXTENDED`); use BLOB for anything larger. `LONG RAW` is not supported
and fails with a clear `OracleException`.

### CLOB support

CLOB values round-trip as Dart `String`s — no LOB handle or streaming API is
needed (or exposed):

- **Queries** — selecting a `CLOB` column returns a `String` (`null` for SQL
  NULL, `''` for `EMPTY_CLOB()`). The driver reads LOB locators transparently
  in server-chunk-sized pieces; values above 64 KiB are covered by tests.
- **DML** — bind an ordinary `String` into a `CLOB` column with named or
  positional binds. Strings above the 32,767-byte VARCHAR bind limit are
  handled automatically: Oracle's long-data path for SQL (covered by tests to
  40,000 characters) and an internal temporary CLOB for PL/SQL (validated
  live to ~1 MB per value, ASCII and mixed multibyte/emoji, on both supported
  server lines).
- **PL/SQL OUT / IN OUT** — declare
  `OracleBind.out(type: OracleDbType.clob, maxSize: ...)` or
  `OracleBind.inOut(value: ..., type: OracleDbType.clob, maxSize: ...)`;
  values decode through `result.outBinds` as `String?`. `maxSize` counts
  characters (UTF-16 code units, the same as `String.length`) and bounds the
  value the driver will materialize — a longer value fails loudly instead of
  truncating. The empty string binds as SQL NULL, consistent with Oracle's
  `'' IS NULL` semantics.

Statement-cache note: result cursors for queries that select CLOB (or BLOB)
columns are always re-parsed, never blind-reused from the statement cache —
fresh defines keep the LOB-prefetch row shape intact — while RAW queries keep
normal cursor reuse.

### BLOB support

BLOB values round-trip as Dart `Uint8List`s — no LOB handle or streaming API
is needed (or exposed):

- **Queries** — selecting a `BLOB` column returns a `Uint8List` (`null` for
  SQL NULL, an empty `Uint8List` for `EMPTY_BLOB()`). The driver reads LOB
  locators transparently and byte-for-byte — no character set conversion
  ever touches the bytes; values above 64 KiB are covered by tests.
- **DML** — bind an ordinary `Uint8List` into a `BLOB` column with named or
  positional binds. Values above the 32,767-byte scalar bind limit are
  handled automatically: Oracle's long-data path for SQL (covered by tests to
  40,000 bytes) and an internal temporary BLOB for PL/SQL (validated live to
  ~1 MB per value on both supported server lines). An **empty** `Uint8List` bound as a plain value
  in SQL DML stores SQL NULL (it travels as a zero-length RAW, and Oracle maps
  that to NULL — matching node-oracledb). To store an empty-but-not-NULL BLOB,
  bind through `OracleBind(value: Uint8List(0), type: OracleDbType.blob)`,
  which routes the value through a temporary BLOB (see PL/SQL note below).
- **PL/SQL OUT / IN OUT** — declare
  `OracleBind.out(type: OracleDbType.blob, maxSize: ...)` or
  `OracleBind.inOut(value: ..., type: OracleDbType.blob, maxSize: ...)`;
  values decode through `result.outBinds` as `Uint8List?`. `maxSize` counts
  **bytes** and bounds the value the driver will materialize — a longer
  value fails loudly instead of truncating. An empty `Uint8List` binds as an
  empty BLOB value (length 0), which Oracle treats as distinct from SQL
  NULL — unlike CLOB's empty string.

Large LOB binds through the internal temporary-LOB path are validated live on
both Oracle 23ai and 21c: a 1,000,000-byte BLOB and 500,000-character CLOBs
(ASCII and mixed multibyte/emoji — ~1 MB as the on-wire UTF-16BE payload) as
IN binds and IN OUT round trips, plus IN binds straddling the 64 KiB
wire-chunk boundary exactly (BLOB at 65,535/65,536/65,537 payload bytes; CLOB
at the nearest even UTF-16BE sizes 65,534/65,536/65,538). Unbounded/multi-gigabyte LOBs are
still not claimed: values are materialized in memory as a single `String` /
`Uint8List`. NCLOB and BFILE columns are not yet supported and fail with a
clear `OracleException` (see roadmap).

### JSON support

Oracle's **native `JSON` data type** (introduced in Oracle Database 21c;
requires database `compatible >= 20`) round-trips as ordinary Dart values —
`Map<String, Object?>` for objects, `List<Object?>` for arrays, with members
decoding as `null` / `bool` / `num` / `String` and nested maps/lists. On the
wire, values travel in Oracle's binary JSON format (OSON) under the native
type — no `jsonEncode()`/`jsonDecode()` round-trip through text, no Oracle
Client, no LOB read round trips:

- **Queries** — selecting a `JSON` column returns a `Map`/`List` (`null` for
  SQL NULL). Document shape and member order are preserved; statement-cache
  cursor reuse and multi-batch fetches work normally.
- **DML** — bind an ordinary `Map<String, Object?>` or `List<Object?>` into a
  `JSON` column with named or positional binds; the driver encodes it as
  OSON. Members may be `null`, `bool`, finite `num`, `String`, and nested
  maps/lists; anything else (e.g. `DateTime`, `Uint8List`, `Set`, NaN)
  fails loudly at the call site. Field names are limited to 255 UTF-8 bytes
  (the limit shared by all supported server versions). Numeric members
  follow the same NUMBER contract as scalar columns: integers beyond 2⁵³
  decode to `double` and lose precision (see
  [Known limitations](#known-limitations)).
- **PL/SQL OUT / IN OUT** — declare
  `OracleBind.out(type: OracleDbType.json, maxSize: ...)` or
  `OracleBind.inOut(value: ..., type: OracleDbType.json, maxSize: ...)`;
  values decode through `result.outBinds`. `maxSize` counts **OSON bytes**
  (the binary wire encoding) and bounds the returned document — a larger
  return fails loudly instead of truncating.

**Creating `JSON` tables — tablespace requirement.** A native `JSON` column
requires a tablespace that uses **Automatic Segment Space Management (ASSM)**.
The default `USERS` tablespace qualifies; the `SYSTEM` tablespace does not, so
`CREATE TABLE ... (doc JSON)` run as a user whose default tablespace is
`SYSTEM` (e.g. the `system` account) fails with **`ORA-43853: JSON type
columns are not allowed in this tablespace`** on every server version. Add an
explicit `TABLESPACE USERS` (or any ASSM tablespace) to the `CREATE TABLE`, or
grant the schema a default ASSM tablespace. This is an environment/DDL
requirement, not a driver limitation.

**Native vs. textual JSON.** This support covers the dedicated `JSON` column
type (OSON-backed, 21c+). JSON *text* stored in `VARCHAR2`/`CLOB`/`BLOB`
columns — the pre-21c pattern with `IS JSON` constraints — keeps its ordinary
`String`/`Uint8List` behavior; parse it with `dart:convert` or query it
through SQL/JSON functions. JSON text inserted *into* a native `JSON` column
is parsed by the server and reads back as `Map`/`List`.

Not in scope: SODA, JSON-relational duality views, `JsonId`, VECTOR, and
Oracle-specific JSON scalar types (dates/timestamps/intervals/binary inside
JSON documents). Documents containing such scalars fail loudly with
`OracleException` rather than decoding silently.

## Project Status

This package implements a subset of the full Oracle driver feature set. Below is the current roadmap:

| Epic                                            | Status         |
| ----------------------------------------------- | -------------- |
| Core connection & authentication                | ✅ Done        |
| Query execution & transactions                  | ✅ Done        |
| PL/SQL execution (stored procedures, functions) | ✅ Done        |
| Advanced data types (CLOB, BLOB, RAW, JSON)     | ✅ Done        |
| Connection pooling                              | 🚧 In progress — pool creation (`OraclePool.create`/`close`) done; acquire/release pending |

### Planned After 1.0

After the 1.0 release, the project roadmap includes larger API and compatibility work. These items are planned candidates and may change as the APIs are designed and validated:

| Priority | Planned enhancement                                                                       |
| -------- | ----------------------------------------------------------------------------------------- |
| 1        | Streaming and `ResultSet` API for incremental result consumption                          |
| 2        | REF CURSOR and implicit results, built on `ResultSet`                                     |
| 3        | Non-`AL32UTF8` database character set compatibility                                       |
| 4        | Bulk DML / `executeMany()`                                                                |
| 5        | Public LOB streaming and temporary LOBs                                                   |
| 6        | Extended JSON / OSON parity (Oracle-specific JSON scalars, OSON-in-BLOB helpers)          |
| 7        | TIMESTAMP WITH TIME ZONE region-name compatibility and optional temporal fetch formatting |
| 8        | Type completeness for `INTERVAL`, `ROWID` / `UROWID`, and `VECTOR`                        |

## Tests

The project has an extensive test suite:

- **Unit tests** — covering protocol, crypto, transport, and connection layers
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
- **CLOB/BLOB cursor re-parse** — result cursors for queries selecting CLOB or BLOB columns are always re-parsed, never blind-reused from the statement cache (fresh defines are required to keep the LOB-prefetch metadata); RAW queries keep normal cursor reuse.
- **NUMBER beyond 2⁵³** — integer-valued NUMBERs larger than 2⁵³ decode to `double` and lose precision (Dart `double` limit; matches node-oracledb).
- **One operation per connection** — a connection supports one in-flight operation; overlapping `execute()` calls throw. Use separate connections for concurrent work until connection pooling lands (see roadmap).
- **Pre-12c authentication** — password-verifier paths used by pre-12c servers are untested; the validated matrix is Oracle 21c (classical auth) and 23ai (FAST_AUTH).
- **Region-id time zones** — `TIMESTAMP WITH TIME ZONE` values stored with a region id (e.g. `Europe/Madrid`) are rejected on decode; offset-based zones (e.g. `+02:00`) are supported. Region-name compatibility is planned as a post-1.0 temporal enhancement.
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
