# oracledb

A pure Dart driver for Oracle Database. It speaks the thin-mode TNS/TTC wire protocol directly, so there is no Oracle Client, no FFI and no native code to install.

[![Pub Version](https://img.shields.io/badge/pub-v1.5.0-orange)](https://pub.dev/packages/oracledb)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Dart SDK](https://img.shields.io/badge/dart-%3E%3D3.12.0-blue)](https://dart.dev)

> **Stable API** (semantic versioning), validated against Oracle 23ai and 21c.
> Connections, pooling, queries, DML, bulk DML, transactions, PL/SQL, result-set
> streaming, LOBs, and native JSON are all supported. See the
> [Features](#features) list below, and the [CHANGELOG](CHANGELOG.md) for what
> changed in each release.

> **This is NOT an official Oracle product.** It is an independent Dart port of the thin-client wire protocol as documented and implemented in Oracle's official [node-oracledb](https://github.com/oracle/node-oracledb) driver. Oracle Corporation is not affiliated with this project.

## Features

- **Pure Dart** — no FFI, no native code, no Oracle Instant Client required
- **Thin protocol** — direct TNS/TTC wire protocol implementation
- **Oracle 23ai + Oracle 21c** — tested against both; FAST_AUTH and classical auth paths both supported
- **Native Dart platforms** — macOS, Windows, Linux, Android, and iOS (web unsupported — requires `dart:io` TCP sockets)
- **TLS/SSL** — encrypted connections with certificate validation
- **Full query support** — SELECT, INSERT, UPDATE, DELETE with positional and named bind parameters
- **Bulk DML** — `executeMany()` runs one statement across many bind sets in a single round trip, with array `RETURNING`, per-iteration PL/SQL binds, batch errors, and per-row counts
- **PL/SQL** — stored procedures and functions with OUT / IN OUT bind parameters
- **Result sets & streaming** — consume large queries incrementally via `OracleResultSet` or `queryStream()` / `executeStream()` instead of materializing every row
- **REF CURSOR & implicit results** — PL/SQL `SYS_REFCURSOR` OUT binds, `DBMS_SQL.RETURN_RESULT` implicit result sets (including rows that carry CLOB/NCLOB/BLOB/JSON/VECTOR columns), and nested `CURSOR()` columns (nested-cursor and REF CURSOR rows must not carry a CLOB/NCLOB/BLOB column — see [Known Limitations](#known-limitations))
- **LOB streaming & temporary LOBs** — `OracleExecuteOptions(fetchLobs: true)` returns a server-backed `OracleLob` with bounded `read()`/`write()`, `trim()`, `refresh()` of the cached `length`/`chunkSize`, `textStream()`/`byteStream()`/`writeStream()` for piece-by-piece transfer, and `createTemporaryClob()`/`createTemporaryNClob()`/`createTemporaryBlob()` for session-duration temporary LOBs
- **Native JSON** — `JSON` columns (and `BLOB ... IS JSON`) decode to `Map` / `List`, including Oracle `DATE`/`TIMESTAMP`/`RAW` members, and fetched documents bind back unchanged
- **Transactions** — commit, rollback, and transaction helper
- **TIMESTAMP WITH TIME ZONE** — decoded as UTC `DateTime`, or as `OracleTimestampTz` preserving a numeric offset (opt-in); named-region values (e.g. `Europe/Madrid`) decode to the correct UTC instant with a reported `+00:00` offset and a region id that `timeZoneRegionName` resolves to the region name
- **INTERVAL DAY TO SECOND** — decoded as `OracleIntervalDS` with nanosecond fractional seconds; binds from `OracleIntervalDS` or a Dart `Duration`
- **INTERVAL YEAR TO MONTH** — decoded as `OracleIntervalYM` (signed years and months); binds from `OracleIntervalYM`
- **ROWID / UROWID** — decoded as the rowid's `String` text (`ROWIDTOCHAR` for a physical rowid; an index-organized table's logical rowid starts with `*` and matches `CAST(rowid AS VARCHAR2(4000))`); a fetched rowid binds back as a plain `String` (`WHERE rowid = :1`)
- **VECTOR (Oracle 23ai)** — dense vectors decode to `Float32List` / `Float64List` / `Int8List` / `Uint8List` (BINARY) by storage format and sparse vectors to `OracleSparseVector`; a `Float32List`, `Float64List`, `Int8List` or `OracleSparseVector` binds as a vector (e.g. for `VECTOR_DISTANCE`), while a `Uint8List` (BINARY) still binds as RAW unless declared `OracleDbType.vector`; see [VECTOR support](#vector-support)
- **Fail-loud decoding** — a column type the driver cannot decode (23ai `BOOLEAN`, `XMLTYPE` and other object types, any unrecognised type code) raises `OracleException` instead of decoding to a silent `null`; see [Unsupported types fail loud](#unsupported-types-fail-loud)
- **Dates as strings** — `OracleExecuteOptions(fetchAsString: {...})` returns DATE / TIMESTAMP / TIMESTAMP WITH (LOCAL) TIME ZONE columns as `String` (node-oracledb `fetchAsString` parity; see [Fetching dates and timestamps as strings](#fetching-dates-and-timestamps-as-strings))
- **Per-column fetch converters** — `OracleExecuteOptions(fetchTypeHandler: ...)` picks a converter per result column (e.g. a NUMBER as `String`, your own date format) applied to every fetched value (node-oracledb `fetchTypeHandler` converter parity; see [Fetch type handlers](#fetch-type-handlers-per-column-converters))
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
  oracledb: ^1.5.0
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

### Connection Pooling

`OraclePool` keeps a bounded set of authenticated sessions and recycles them across borrowers. Acquire and release always belong in `try`/`finally`:

```dart
final pool = await OraclePool.create(
  'localhost:1521/FREEPDB1',
  user: 'testuser',
  password: 'testpassword',
  minConnections: 2,  // opened and authenticated up front
  maxConnections: 10, // hard upper bound; acquire() waits FIFO when exhausted
  acquireTimeout: const Duration(seconds: 30), // bound queued waits (null = wait forever)
  idleTimeout: const Duration(minutes: 5), // shrink surplus idle sessions (zero = never)
);

try {
  final conn = await pool.acquire();
  try {
    final result = await conn.execute('SELECT SYSDATE FROM dual');
    print(result.rows.first[0]);
  } finally {
    await pool.release(conn); // rolls back uncommitted work, recycles the session
  }

  // Or leak-safe by construction:
  final result = await pool.withConnection(
    (conn) => conn.execute('SELECT SYSDATE FROM dual'),
  );
  print(result.rows.first[0]);
} finally {
  // Optionally wait for borrowed sessions to come back before shutting down.
  await pool.close(drainTimeout: const Duration(seconds: 10));
}
```

`release()` rolls back any uncommitted transaction before the session is handed to the next borrower, and quietly destroys sessions that are no longer healthy.

Pool timeouts are opt-in and validated at create time:

- `acquireTimeout` bounds how long a queued `acquire()` waits once the pool is exhausted; on expiry the acquire fails with an `OracleException` (ORA-12170). The default `null` waits indefinitely. It never bounds physical connection establishment — the `timeout` option does that.
- `idleTimeout` closes surplus idle sessions (beyond `minConnections`) that sit unused longer than the configured duration; the pool never shrinks below `minConnections`, and retained sessions keep their statement cache warm. The default `Duration.zero` disables shrinking.
- `close(drainTimeout: ...)` rejects new acquires immediately, then waits for checked-out sessions to be released (destroying each as it comes back) until the drain timeout expires. Omitting `drainTimeout` (or passing `Duration.zero`) closes without waiting — borrowed sessions are destroyed whenever they are eventually released. Repeated `close()` calls are idempotent and join a pending drain.

#### Session tagging

Pooled sessions can carry a **tag** — a client-side label for session state (NLS settings, time zone, …) that user code or a pool callback has applied — so that state is reused instead of reset on every borrow. Request a tag with `acquire(tag: ...)` / `withConnection(tag: ...)` and let an optional pool-wide `sessionCallback` apply the state:

```dart
final pool = await OraclePool.create(
  'localhost:1521/FREEPDB1',
  user: 'testuser',
  password: 'testpassword',
  maxConnections: 10,
  sessionCallback: (conn, requestedTag) async {
    if (requestedTag == 'TZ=UTC') {
      await conn.execute("ALTER SESSION SET TIME_ZONE = 'UTC'");
      conn.tag = requestedTag; // the callback records the state it applied
    }
  },
);

final conn = await pool.acquire(tag: 'TZ=UTC'); // session arrives with UTC applied
```

How it behaves:

- **Tags are client-side metadata.** `connection.tag` (default `''` = untagged) never applies database state by itself; it records state already applied. `null` and `''` requests both mean untagged.
- **Selection order.** For a requested tag the pool prefers an exact-match idle session, then an untagged one, then opening a new connection. A session carrying a *different* tag is used only when `matchAnyTag: true` is passed or the `sessionCallback` can repair its state first — the pool never claims a tag it did not observe.
- **The callback runs when needed.** It is invoked before a borrower receives a session that is brand new or whose tag differs from the requested one, and it must set `connection.tag` itself once the state matches. If it throws, the candidate session is destroyed and the acquire fails with that error.
- **Tags survive release.** A borrower may update `conn.tag` before `release()`; the automatic rollback does not clear it, so the next matching acquire reuses the session (statement cache intact). Without a callback, a tagged request may still return an untagged session — check `conn.tag`, apply the state yourself, and set the tag.
- **Queued waiters are tag-aware.** A released session goes to the oldest waiter that can accept it; incompatible waiters keep their place in the queue.

Out of scope (by design, this is a pure-Dart thin driver): DRCP, heterogeneous credentials/proxy users, sharding keys, PL/SQL (server-side) session callbacks, pool reconfiguration, and Oracle thick-client tag-matching heuristics (tags are matched as exact strings, not parsed as property lists).

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

### Bulk DML — `executeMany()`

`executeMany()` runs one statement many times in a **single wire round trip**:
Oracle array DML for INSERT/UPDATE/DELETE/MERGE (including `RETURNING ... INTO`),
and repeated PL/SQL execution with per-iteration binds (node-oracledb
`executeMany` parity). Iterations run inside the current transaction and are
**not** auto-committed — call `commit()` / `rollback()` exactly as after
`execute()`.

```dart
// Array DML — one INSERT executed once per row.
final result = await connection.executeMany(
  'INSERT INTO emp (id, name) VALUES (:1, :2)',
  [
    [1, 'Alice'],
    [2, 'Bob'],
    [3, null], // NULL name
  ],
);
print('Inserted ${result.rowsAffected} rows'); // 3
await connection.commit();
```

Rows are a `List` for positional (`:1`, `:2`) SQL or a `Map` for named
(`:name`) SQL. Each slot's Oracle type is inferred from the first non-null
value and must stay consistent across all rows; string/RAW slots are sized to
the largest value. All row-shape and type validation happens before any wire
round trip, and bind values never appear in error messages.

**Batch errors and per-row counts.** By default the first failing row throws.
Pass `batchErrors: true` to apply every valid row and collect each failed row's
data error instead, and `dmlRowCounts: true` for one affected-row count per
input row (both DML-only):

```dart
final result = await connection.executeMany(
  'INSERT INTO emp (id, name) VALUES (:1, :2)',
  [[1, 'Alice'], [1, 'Dup'], [2, 'Bob']], // row 1 duplicates the PK
  OracleExecuteManyOptions(batchErrors: true, dmlRowCounts: true),
);
for (final e in result.batchErrors) {
  print('row ${e.offset} failed: ${e.code} ${e.message}'); // row 1: ORA-00001 ...
}
print(result.dmlRowCounts); // [1, 0, 1]
await connection.commit(); // applied rows stay pending until you commit
```

**DML `RETURNING ... INTO`.** Declare every placeholder once via `bindDefs`
(required for RETURNING — the OUT targets carry no per-row value to infer a type
from). Results are row-major: one entry per input row, each holding a list of
returned values per OUT bind.

```dart
final result = await connection.executeMany(
  'INSERT INTO emp (name) VALUES (:1) RETURNING id INTO :2',
  [['Alice'], ['Bob']],
  OracleExecuteManyOptions(bindDefs: [
    OracleBindDef.input(type: OracleDbType.varchar, maxSize: 100),
    OracleBindDef.output(type: OracleDbType.number),
  ]),
);
print(result.outBinds.toList()); // [[[1]], [[2]]]
```

**Single-statement `RETURNING ... INTO`.** A plain `execute()` of an
INSERT/UPDATE/DELETE with a `RETURNING ... INTO` clause accepts
`OracleBind.out(...)` specs for the INTO targets (the same wire path as
`executeMany()`, one iteration). Each OUT bind yields a `List` of the returned
values, one per affected row (empty when no row matched). `OracleBind` specs on
any other non-PL/SQL statement are still rejected (ORA-06502). Oracle 23ai
also supports `MERGE ... RETURNING`; Oracle 21c does not.

```dart
final r = await connection.execute(
  'UPDATE emp SET sal = sal * 1.1 WHERE dept = :d RETURNING id INTO :ids',
  {'d': 10, 'ids': OracleBind.out(type: OracleDbType.number)},
);
print(r.outBinds['ids']); // [1, 4, 9]
```

**Bulk PL/SQL.** A `BEGIN`/`DECLARE`/`CALL` block runs once per row (or
`numIterations` times). OUT / IN OUT placeholders are declared once via
`bindDefs`; OUT results are row-major, one entry per iteration:

```dart
final result = await connection.executeMany(
  'BEGIN :2 := double_it(:1); END;',
  [[10], [20]],
  OracleExecuteManyOptions(bindDefs: [
    OracleBindDef.input(type: OracleDbType.number),
    OracleBindDef.output(type: OracleDbType.number),
  ]),
);
print(result.outBinds.toList()); // [[20], [40]]

// A positive int runs a bind-free (or all-OUT) PL/SQL block N times:
await connection.executeMany('BEGIN log_tick(); END;', 3);
```

> SELECT / `WITH ... SELECT` queries, `SYS_REFCURSOR` OUT binds, PL/SQL
> collection binds, `OracleBind` value specs inside rows, RETURNING without
> `bindDefs`, and `bindDefs` on plain (non-returning) array DML all fail loudly
> before any wire round trip.

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

`TIMESTAMP WITH TIME ZONE` parameters bind with `OracleDbType.timestampTz`. OUT / IN OUT values follow the connection's decode contract: a UTC `DateTime` by default, or an `OracleTimestampTz` carrying the server-sent offset (`+00:00` plus a `regionId` for a [region-id](#region-id-time-zones) value) on a connection opened with `preserveTimestampTimeZone: true`. IN OUT input values may be an `OracleTimestampTz` (the offset travels on the wire; `regionId` is ignored) or a plain `DateTime`.

`INTERVAL DAY TO SECOND` parameters bind with `OracleDbType.intervalDS` (no `maxSize`). OUT / IN OUT values decode to `OracleIntervalDS`; IN OUT input values may be an `OracleIntervalDS` or a `Duration`. See [INTERVAL DAY TO SECOND support](#interval-day-to-second-support).

`INTERVAL YEAR TO MONTH` parameters bind with `OracleDbType.intervalYM` (no `maxSize`). OUT / IN OUT values decode to `OracleIntervalYM`, and IN OUT input values must be an `OracleIntervalYM`. See [INTERVAL YEAR TO MONTH support](#interval-year-to-month-support).

`ROWID` / `UROWID` parameters and `RETURNING rowid INTO` targets bind with `OracleDbType.rowid` / `OracleDbType.urowid` (no `maxSize`). OUT / IN OUT values decode to the rowid's `String` text, and IN OUT input values must be a `String`. See [ROWID / UROWID support](#rowid--urowid-support).

`VECTOR` parameters and `RETURNING vec INTO` targets bind with `OracleDbType.vector` (Oracle 23ai, no `maxSize`). OUT / IN OUT values decode exactly like a fetched column (a typed list per format, or an `OracleSparseVector`); IN OUT input values may be any of those or a plain `List` of numbers, which travels as `FLOAT64`. See [VECTOR support](#vector-support).

### Result Sets & Streaming

Large queries can be consumed incrementally instead of materializing every row up front. These paths have no 1,000-fetch safety cap — that bound applies only to eager `execute()`.

**Row stream.** `queryStream()` / `executeStream()` return a single-subscription `Stream<OracleRow>`. The cursor opens when a subscriber listens and is closed automatically when the stream completes, is cancelled, or errors:

```dart
await for (final row in connection.queryStream('SELECT id, name FROM big_table')) {
  print(row['NAME']);
}
// executeStream() is identical; queryStream() is the node-oracledb-parity name.
// Pass a third argument to tune the FETCH batch size: queryStream(sql, binds, 100).
```

**Result set handle.** Pass `OracleExecuteOptions(resultSet: true)` to `execute()` to get an `OracleResultSet` in `result.resultSet` for manual, batched pulls. Column metadata is available before the first fetch. Always `close()` it (or fully drain it) to release the cursor and free the connection:

```dart
final result = await connection.execute(
  'SELECT id, name FROM big_table',
  null,
  OracleExecuteOptions(resultSet: true, fetchSize: 100),
);
final rs = result.resultSet!;
try {
  print(rs.columnNames);                 // available before the first row
  for (var row = await rs.getRow(); row != null; row = await rs.getRow()) {
    print(row.toMap());
  }
  // or pull in batches: final batch = await rs.getRows(50);
} finally {
  await rs.close();
}
```

> A connection owns a single TTC byte stream, so only one result set or row stream may be open on it at a time — overlapping operations fail fast with a concurrent-operation `OracleException`. Close the result set before running the next statement.

#### REF CURSOR OUT binds

Bind a PL/SQL `SYS_REFCURSOR` OUT parameter with `OracleBind.out(type: OracleDbType.cursor)`; the returned cursor arrives in `result.outBinds` as an `OracleResultSet`:

```dart
final result = await connection.execute(
  'BEGIN open_employees(:rc, :dept); END;',
  {
    'rc': OracleBind.out(type: OracleDbType.cursor),
    'dept': 10,
  },
);
final rs = result.outBinds['rc']! as OracleResultSet;
try {
  for (var row = await rs.getRow(); row != null; row = await rs.getRow()) {
    print(row['FIRST_NAME']);
  }
} finally {
  await rs.close();
}
```

`IN OUT` cursor binds are not supported — use `OracleBind.out(type: OracleDbType.cursor)`.

#### Implicit result sets

Result sets a PL/SQL block returns via `DBMS_SQL.RETURN_RESULT` surface in `result.implicitResults`, in server-returned order. By default each element is a fully-drained `List<OracleRow>`:

```dart
final result = await connection.execute('BEGIN report(); END;');
for (final cursor in result.implicitResults) {
  for (final row in cursor as List<OracleRow>) {
    print(row.toMap());
  }
}
```

Under `OracleExecuteOptions(resultSet: true)`, each element is a lazy `OracleResultSet` handle instead — `close()` (or fully drain) each one.

Implicit result rows may carry CLOB / NCLOB / BLOB and JSON columns: they decode exactly like a top-level SELECT's (`String`, `Uint8List`, `Map`/`List`, and a BLOB `IS JSON` column as JSON), and under `fetchLobs: true` (eager path) the LOB columns come back as `OracleLob` handles. As in node-oracledb, the driver sends the cursor's LOB-prefetch defines before its first fetch.

#### Nested cursor columns

A `CURSOR(SELECT ...)` column in a query projection materializes inline on the parent row as a `List<OracleRow>` (an empty nested cursor is `[]`, a NULL cursor column is `null`), on the eager, streaming, and result-set paths alike:

```dart
final result = await connection.execute('''
  SELECT d.name,
         CURSOR(SELECT e.name FROM employees e WHERE e.dept_id = d.id) AS staff
  FROM departments d
''');
for (final row in result.rows) {
  final staff = row['STAFF']! as List<OracleRow>;
  print('${row['NAME']}: ${staff.map((r) => r['NAME']).join(', ')}');
}
```

#### Capping eager results

`OracleExecuteOptions(maxRows: N)` caps how many rows an eager `execute()` materializes (`0` = unlimited; node-oracledb `maxRows` parity); check `result.moreRowsAvailable` to detect truncation. It is a no-op for `resultSet: true` and the streaming paths, which are already incremental.

```dart
final top = await connection.execute(
  'SELECT * FROM employees ORDER BY salary DESC',
  null,
  OracleExecuteOptions(maxRows: 10),
);
```

#### Fetching dates and timestamps as strings

`OracleExecuteOptions(fetchAsString: {...})` returns the selected date/time column types as `String` instead of `DateTime` / `OracleTimestampTz` (node-oracledb `fetchAsString` parity for dates and timestamps):

```dart
final result = await connection.execute(
  'SELECT hired, updated_at FROM employees',
  null,
  const OracleExecuteOptions(
    fetchAsString: {OracleDbType.date, OracleDbType.timestamp},
  ),
);
result.rows.first['HIRED'];      // '2024-03-05 00:00:00.000'
result.rows.first['UPDATED_AT']; // '2024-03-05 13:14:15.123456'
```

| Entry                      | Columns returned as `String`                       |
| -------------------------- | -------------------------------------------------- |
| `OracleDbType.date`        | `DATE`                                             |
| `OracleDbType.timestamp`   | `TIMESTAMP`, `TIMESTAMP WITH LOCAL TIME ZONE`      |
| `OracleDbType.timestampTz` | `TIMESTAMP WITH TIME ZONE`                         |

- **The text comes from the driver, not from Oracle.** As in node-oracledb thin mode, the column is still fetched in its native binary form (Oracle sends these types in binary whatever the client asks for), and each decoded value is converted with its own `toString()`: `DateTime.toString()` for DATE / TIMESTAMP / LTZ, the UTC `DateTime.toString()` for TIMESTAMP WITH TIME ZONE (`'2024-03-05 12:14:15.123456Z'`), or `OracleTimestampTz.toString()` on a `preserveTimestampTimeZone: true` connection (offset and `regionId`, not the region name). It ignores the session's `NLS_DATE_FORMAT` / `NLS_TIMESTAMP_FORMAT` / `NLS_TIMESTAMP_TZ_FORMAT` and keeps microsecond precision only. **For Oracle's exact text** (an NLS or explicit format, nanoseconds, a region name), select `TO_CHAR(col, 'format')` in the SQL instead.
- SQL `NULL` stays `null`; `result.columns` still reports the database type.
- `OracleDbType.rowid` / `OracleDbType.urowid` are accepted and change nothing: `ROWID` / `UROWID` columns always decode to their `String` text.
- Any other `OracleDbType` in the set (NUMBER, CLOB, RAW, JSON, INTERVAL, VECTOR, ...) throws `ArgumentError` before any round trip. For a VECTOR's text, select `FROM_VECTOR(col)` or convert the value with a [fetch type handler](#fetch-type-handlers-per-column-converters).
- It applies to the top-level query's rows: `result.rows` (with or without `maxRows`) and every batch of a `resultSet: true` result set. The rows of a **REF CURSOR OUT bind, a nested `CURSOR(...)` column and PL/SQL implicit results keep their native types**, as do OUT bind values; `executeStream()` / `queryStream()` take no options.
- For any other per-column representation (a NUMBER as text, your own date format, ...), use a [fetch type handler](#fetch-type-handlers-per-column-converters); its converter wins over `fetchAsString` for the columns it selects.

#### Fetch type handlers (per-column converters)

`OracleExecuteOptions(fetchTypeHandler: ...)` lets you convert fetched values per column (node-oracledb `fetchTypeHandler` parity for its **converter** half). The handler is called once per result column, in column order, with that column's `ColumnMetadata` and the list of all result columns; it returns a converter for the column, or `null` to keep the default value:

```dart
final result = await connection.execute(
  'SELECT name, salary, hired FROM employees',
  null,
  OracleExecuteOptions(
    fetchTypeHandler: (column, columns) {
      if (column.name == 'SALARY') return (value) => value.toString();
      if (column.name == 'HIRED') {
        return (value) => (value as DateTime).toIso8601String();
      }
      return null; // every other column keeps its default value
    },
  ),
);
result.rows.first['SALARY']; // '7000' instead of 7000
result.rows.first['HIRED'];  // '2024-03-05T00:00:00.000'
```

- **The converter** receives each non-NULL value exactly as the row would otherwise hold it — `int` / `double` for NUMBER, `String`, `Uint8List`, `DateTime`, `OracleTimestampTz` (on a `preserveTimestampTimeZone: true` connection), `OracleIntervalDS` for INTERVAL DAY TO SECOND, `OracleIntervalYM` for INTERVAL YEAR TO MONTH, the rowid's `String` text for ROWID / UROWID, the decoded `Map` / `List` for JSON, a `Float32List` / `Float64List` / `Int8List` / `Uint8List` or an `OracleSparseVector` for VECTOR, `List<OracleRow>` for a nested `CURSOR(...)` column, `String` / `Uint8List` for CLOB / BLOB or an `OracleLob` under `fetchLobs: true` — and its return value (any `Object?`, including `null`) becomes the cell. SQL `NULL` stays `null` and the converter is not called. It runs synchronously, once per cell, on every fetch round: `result.rows` (with or without `maxRows`) and every batch of a `resultSet: true` result set.
- **No `type`.** Unlike node-oracledb, the handler cannot change the type Oracle sends: every column is fetched in its native form (no DEFINE, no SQL rewrite) and converted by the driver after decoding — so the result never follows the session's NLS settings. Select `TO_CHAR(col, 'format')` for Oracle's own text. `result.columns` still reports the database type.
- **Precedence:** a column the handler returns a converter for is converted by that converter only; [`fetchAsString`](#fetching-dates-and-timestamps-as-strings) still applies to the columns the handler returned `null` for. A handler that always returns `null` changes nothing.
- **Per call:** the handler runs on every `execute()` and nothing is cached, so re-executing a cached statement with a different handler (or none) returns that call's own representation.
- **Errors propagate unchanged:** an exception thrown by the handler or a converter is rethrown as-is (not wrapped in `OracleException`), no rows of the failed call (or failed result-set batch) are returned, and the connection stays usable — close a failed result set as usual.
- **LOBs under `fetchLobs: true`:** the converter receives the `OracleLob` handle, which still holds the connection until closed. Keep it reachable from the converted value and close it yourself (`result.closeLobs()` only finds handles still present in the rows); a result set's `close()` still reaps the handles of rows you never retrieved.
- **Top-level only:** the handler is never called for REF CURSOR OUT binds, the rows inside a nested `CURSOR(...)` column, PL/SQL implicit results or OUT binds (they keep their default types), nor for DML / PL/SQL; `executeMany()`, `executeStream()` and `queryStream()` take no such option.

**Migrating from node-oracledb:** return the converter function itself instead of `{converter: fn}`; a `{type: ...}` result has no equivalent (convert the value in the converter, or use `TO_CHAR` / `CAST` in the SQL); `metaData.dbType` maps to `ColumnMetadata.oracleType` (an Oracle type code, e.g. `2` for NUMBER); the handler is per call (no global `oracledb.fetchTypeHandler`); converters are synchronous (a returned `Future` is stored as-is, not awaited).

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
| `connection.execute(sql, binds, OracleExecuteOptions(...))` | Eager (default), lazy result set (`resultSet: true`), or row-capped (`maxRows:`) execution; `fetchAsString:` returns date/time columns as `String`; `fetchTypeHandler:` converts chosen columns per value |
| `connection.executeMany(sql, rows, [OracleExecuteManyOptions(...)])` | Run one statement across many bind sets in a single round trip (array DML, PL/SQL, RETURNING) |
| `OracleBindDef.input/output/inputOutput(type: ..., maxSize: ...)` | Declare a placeholder's type & direction for `executeMany` `bindDefs` (PL/SQL and DML RETURNING) |
| `result.batchErrors` / `result.dmlRowCounts` | Per-row errors / per-row affected-row counts from `executeMany` (opt-in via `OracleExecuteManyOptions`) |
| `connection.queryStream(sql, [binds])` / `executeStream(...)` | Stream a query's rows as `Stream<OracleRow>` |
| `OracleBind.out(type: ..., maxSize: ...)` | Declare a PL/SQL OUT bind parameter                 |
| `OracleBind.out(type: OracleDbType.cursor)` | Declare a PL/SQL REF CURSOR OUT bind (returned as an `OracleResultSet`) |
| `OracleBind.inOut(value: ..., type: ...)` | Declare a PL/SQL IN OUT bind parameter              |
| `result.outBinds`                         | OUT / IN OUT values, by name or position            |
| `result.resultSet`                        | The `OracleResultSet` when `OracleExecuteOptions(resultSet: true)` was used |
| `result.implicitResults`                  | PL/SQL `DBMS_SQL.RETURN_RESULT` result sets (eager `List<OracleRow>` / lazy `OracleResultSet`) |
| `result.moreRowsAvailable`                | Whether an eager result was truncated by the fetch cap or `maxRows` |
| `resultSet.getRow()` / `getRows([n])`     | Pull the next row / next batch from a result set    |
| `resultSet.columnNames`                   | Result-set column names (available before the first fetch) |
| `resultSet.close()`                       | Close the cursor and free the connection            |
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
| VARCHAR2, CHAR            | `String` (see [Character Set Support](#character-set-support))                    |
| NCHAR, NVARCHAR2, NCLOB   | `String` (national charset — see [Character Set Support](#character-set-support)) |
| NUMBER                    | `num` / `int` / `double`                                                         |
| DATE                      | `DateTime` — or `String` with `fetchAsString` (see [Fetching dates and timestamps as strings](#fetching-dates-and-timestamps-as-strings)) |
| TIMESTAMP, TIMESTAMP WITH LOCAL TIME ZONE | `DateTime` — or `String` with `fetchAsString`                  |
| TIMESTAMP WITH TIME ZONE  | `DateTime` (UTC) — or `OracleTimestampTz` with `preserveTimestampTimeZone: true` (see [Region-id time zones](#region-id-time-zones)), or `String` with `fetchAsString` |
| INTERVAL DAY TO SECOND    | `OracleIntervalDS` (nanosecond fractional seconds); binds from `OracleIntervalDS` or `Duration` (see [INTERVAL DAY TO SECOND support](#interval-day-to-second-support)) |
| INTERVAL YEAR TO MONTH    | `OracleIntervalYM` (signed years and months); binds from `OracleIntervalYM` (see [INTERVAL YEAR TO MONTH support](#interval-year-to-month-support)) |
| ROWID, UROWID             | `String` — `ROWIDTOCHAR` text for a physical rowid; a logical UROWID starts with `*` and matches `CAST(rowid AS VARCHAR2(4000))`; binds from `String` (see [ROWID / UROWID support](#rowid--urowid-support)) |
| RAW                       | `Uint8List` (see [RAW support](#raw-support))                                    |
| CLOB                      | `String` (see [CLOB support](#clob-support), [Character Set Support](#character-set-support)) |
| BLOB                      | `Uint8List` (see [BLOB support](#blob-support)); a BLOB `IS JSON` column decodes like JSON (see [JSON stored in a BLOB](#json-stored-in-a-blob-is-json)) |
| JSON (21c+)               | `Map<String, Object?>` / `List<Object?>` (see [JSON support](#json-support))     |
| VECTOR (23ai)             | `Float32List` (FLOAT32), `Float64List` (FLOAT64), `Int8List` (INT8), `Uint8List` (BINARY, 8 dimensions per byte), `OracleSparseVector` (sparse); `Float32List` / `Float64List` / `Int8List` / `OracleSparseVector` bind as vectors, a `Uint8List` binds as RAW unless declared `OracleDbType.vector` (see [VECTOR support](#vector-support)) |
| CURSOR / REF CURSOR       | `OracleResultSet` (OUT bind) / `List<OracleRow>` (nested `CURSOR()` column) — cursor-embedded CLOB/NCLOB/BLOB columns decode as materialized values; `fetchLobs: true` cannot wrap them as handles (see [Result Sets & Streaming](#result-sets--streaming), [Known Limitations](#known-limitations)) |
| NULL                      | `null`                                                                           |

### Unsupported types fail loud

Every type above decodes; anything else raises an error instead of returning a
silent `null`. Fetching a column of a type the driver cannot decode throws
`OracleException` with `oraUnsupportedType` (ORA-03115); the message names the
Oracle type code, never the value. This covers:

- SQL `BOOLEAN` (Oracle 23ai, type 252), a `NULL` included;
- object types (type 109): `XMLTYPE`, `ANYDATA`, user-defined objects and
  collections (`VARRAY`, nested tables);
- any other type code the driver does not recognise.

The connection stays usable after the error: verified live for object types on
Oracle 23ai and 21c and for `BOOLEAN` on 23ai (the only server with SQL
`BOOLEAN`); other unrecognised codes are covered by unit tests only. `BFILE`
columns fail loud with their own `oraUnsupportedType` message, as before;
`LONG` / `LONG RAW` columns do too on Oracle 23ai. On Oracle 21c, a `LONG`
column was observed to time out (ORA-12170) instead (see
[Known Limitations](#known-limitations)). Convert such a column in SQL to fetch
it, for example `XMLSERIALIZE(CONTENT x AS CLOB)` for `XMLTYPE`, or
`TO_CHAR(b)` / `CASE WHEN b THEN 1 ELSE 0 END` for a 23ai `BOOLEAN`. A query
that returns no rows does not raise, as there is no value to decode.

### Region-id time zones

A `TIMESTAMP WITH TIME ZONE` value can be stored with a numeric offset
(`+02:00`) or with a named region (`Europe/Madrid`, `US/Pacific`, `UTC`, …).
Both decode to the **correct absolute instant** — on Oracle 23ai and 21c,
including DST-transition values and fractional seconds:

| Stored value                         | Default connection        | `preserveTimestampTimeZone: true`             |
| ------------------------------------ | ------------------------- | --------------------------------------------- |
| `2024-07-15 12:00:00 +02:00`         | `DateTime.utc(2024, 7, 15, 10)` | `OracleTimestampTz` — 10:00Z at `+02:00`, `regionId == null` |
| `2024-07-15 12:00:00 Europe/Madrid`  | `DateTime.utc(2024, 7, 15, 10)` | `OracleTimestampTz` — 10:00Z at **`+00:00`**, `regionId` set |

**Region names (opt-in).** An `OracleTimestampTz` decoded from a region value
carries the server's numeric region id in `regionId`, and the connection
resolves it to the region name — read from **the connected database's own**
`V$TIMEZONE_NAMES`, never from a table bundled with the driver:

```dart
final conn = await OracleConnection.connect(
  connectString,
  user: user,
  password: password,
  preserveTimestampTimeZone: true,
);
final row = (await conn.execute('SELECT ts FROM events')).rows.first;
final ts = row['TS'] as OracleTimestampTz;
ts.utc;                                 // 2024-07-15 10:00:00.000Z
ts.regionId;                            // e.g. 404 (null for +02:00 data)
await conn.timeZoneRegionName(ts);      // 'EUROPE/MADRID'
```

- The name is returned as Oracle's `TZR` format element renders it
  (upper case, e.g. `'EUROPE/MADRID'`, `'US/PACIFIC'`).
- The first lookup on a connection reads every region of `V$TIMEZONE_NAMES`
  in one query (the view is readable by `PUBLIC` by default) and caches the
  id → name map for the connection's lifetime; later lookups need no round
  trip. That first lookup is a normal operation on the connection, so it is
  rejected while another operation (an open `OracleResultSet`, an in-flight
  `execute`) holds it — resolve after iterating, or warm the cache first.
- A value without a region id (a numeric offset) resolves to `null` without
  any query. An id that is not in the server's table — a hand-built value, or
  one fetched from a database with a different time-zone file — throws
  `OracleException` (ORA-01882), never a guessed name. If the view cannot be
  read, the server's error (e.g. ORA-00942) is raised, naming
  `V$TIMEZONE_NAMES`.
- Region ids are numbered by the server's time-zone file: resolve a value on
  a connection to the database it came from (or one with the same file). The
  connection does not need `preserveTimestampTimeZone` to resolve a value.

Limits of the region form (no Oracle time-zone rules are bundled, so the
driver never computes a region's offset):

- **The offset stays `+00:00`.** An opted-in `OracleTimestampTz` for a region
  value reports `+00:00` — the UTC-normalized rendering of the instant, not
  the region's offset at that moment (`wallClock` is the UTC wall clock).
  Select `TO_CHAR(col, 'TZH:TZM')` alongside the column when you need the
  offset. On a default connection the value is a plain UTC `DateTime` and
  carries no region id (`TO_CHAR(col, 'TZR')` names it server-side).
- **Text instead of a value.** `OracleExecuteOptions(fetchAsString:
  {OracleDbType.timestampTz})` returns the column as text, but rendered by
  the driver from the decoded value (see [Fetching dates and timestamps as
  strings](#fetching-dates-and-timestamps-as-strings)): on a
  `preserveTimestampTimeZone: true` connection that is
  `OracleTimestampTz(2024-07-15 10:00:00.000Z +00:00 regionId=404)`, so the
  region appears only as its id. For Oracle's own text with the region name,
  select `TO_CHAR(col, 'YYYY-MM-DD HH24:MI:SS.FF TZR')`.
- **Binding is offset-only.** Binding a fetched region value back stores the
  same instant at `+00:00`; `regionId` is ignored and the region is not
  carried back.
- Inside native JSON, a region-id `TIMESTAMP WITH TIME ZONE` member decodes the
  same way (`OracleTimestampTz` at `+00:00` with its `regionId`) — always, as
  every JSON timestamp-with-time-zone member is an `OracleTimestampTz`. A
  top-level `JSON_SCALAR(ts)` keeps the region on Oracle 23ai and 21c, but
  nested JSON constructors may not: Oracle 23ai may resolve the region to its
  offset (e.g. `JSON_ARRAY(ts)`) and 21c may store a `+00:00` offset, in which
  case the member arrives — and decodes — as an ordinary offset value without
  a `regionId`; the instant is the same either way.

### INTERVAL DAY TO SECOND support

`INTERVAL DAY TO SECOND` columns decode to `OracleIntervalDS` (node-oracledb
`IntervalDS` parity): signed `days`, `hours`, `minutes`, `seconds` and
`fseconds` (fractional seconds in **nanoseconds**, which a Dart `Duration`
cannot hold). A negative interval carries the sign on every component.

```dart
final r = await connection.execute(
  "SELECT INTERVAL '-2 01:02:03.5' DAY TO SECOND AS iv FROM dual",
);
final iv = r.rows.first['IV'] as OracleIntervalDS;
iv.days;         // -2
iv.fseconds;     // -500000000
iv.toDuration(); // Duration (sub-microsecond digits truncated)

// Bind an OracleIntervalDS or a plain Duration (microsecond resolution).
await connection.execute('INSERT INTO t (iv) VALUES (:1)', [iv]);
await connection.execute(
  'INSERT INTO t (iv) VALUES (:1)',
  [const Duration(hours: 1, minutes: 30)],
);
```

- **Construction** — `OracleIntervalDS(days: ..., hours: ..., minutes: ...,
  seconds: ..., fseconds: ...)` carries seconds into minutes, minutes into
  hours and hours into days like node-oracledb (`fseconds` is never carried).
  It throws `ArgumentError` outside `INTERVAL DAY(9) TO SECOND(9)`
  (±999,999,999 days, ±999,999,999 ns) and — unlike node-oracledb — when
  components mix signs (`hours: 1, minutes: -30`): Oracle stores such a value
  verbatim and then renders and compares it inconsistently.
- **Binds** — IN binds, `executeMany()` rows, PL/SQL OUT / IN OUT
  (`OracleDbType.intervalDS`, no `maxSize`), DML `RETURNING`, and intervals in
  REF CURSOR, nested `CURSOR()` and implicit-result rows all use the same
  11-byte wire form (a bind always carries the full `DAY(9) TO SECOND(9)`
  range). The server enforces the target column's own precision: a column
  declared `INTERVAL DAY(2) TO SECOND(6)` rejects too many days with ORA-01873
  and rounds extra fractional digits to its scale. Known issue (pre-existing,
  not interval-specific): on Oracle 21c a SQL `NULL` in a REF CURSOR, nested
  `CURSOR()` or implicit-result row without a LOB or JSON column fails with
  ORA-01405, so NULL intervals cannot be fetched through cursors there.
- **Not covered** — intervals inside native JSON, and `fetchAsString` (which
  converts date and timestamp types only).

### INTERVAL YEAR TO MONTH support

`INTERVAL YEAR TO MONTH` columns decode to `OracleIntervalYM` (node-oracledb
`IntervalYM` parity): signed `years` and `months`. A negative interval carries
the sign on both components. Dart has no native year/month span (a `Duration`
is a fixed length of time; a month is not), so `OracleIntervalYM` is the only
Dart value that binds as one.

```dart
final r = await connection.execute(
  "SELECT INTERVAL '-2-3' YEAR TO MONTH AS iv FROM dual",
);
final iv = r.rows.first['IV'] as OracleIntervalYM;
iv.years;  // -2
iv.months; // -3

await connection.execute('INSERT INTO t (iv) VALUES (:1)', [iv]);
await connection.execute(
  'INSERT INTO t (iv) VALUES (:1)',
  [OracleIntervalYM(months: 14)], // stored as 1 year 2 months
);
```

- **Construction** — `OracleIntervalYM(years: ..., months: ...)` carries
  every 12 months into a year like node-oracledb (`months: 14` is years 1,
  months 2). It throws `ArgumentError` outside `INTERVAL YEAR(9) TO MONTH`
  (±999,999,999 years and 11 months) and — unlike node-oracledb — when the
  components mix signs (`years: 1, months: -6`): Oracle stores such a value
  verbatim and then renders and compares it inconsistently (verified on 23ai
  and 21c).
- **Binds** — IN binds, `executeMany()` rows, PL/SQL OUT / IN OUT
  (`OracleDbType.intervalYM`, no `maxSize`), DML `RETURNING`, and intervals in
  REF CURSOR, nested `CURSOR()` and implicit-result rows all use the same
  5-byte wire form (a bind always carries the full `YEAR(9) TO MONTH` range).
  The server enforces the target column's own precision: a column declared
  `INTERVAL YEAR(2) TO MONTH` (the default) rejects 100 years or more with
  ORA-01873. A `Duration` or an `OracleIntervalDS` never binds as a YEAR TO
  MONTH value, and the two interval kinds cannot share one `executeMany()`
  bind. The same known issue applies as for INTERVAL DAY TO SECOND: on
  Oracle 21c a SQL `NULL` in a REF CURSOR, nested `CURSOR()` or
  implicit-result row without a LOB or JSON column fails with ORA-01405.
- **Not covered** — intervals inside native JSON, and `fetchAsString` (which
  converts date and timestamp types only).

### ROWID / UROWID support

`ROWID` and `UROWID` values decode to their `String` text, as node-oracledb
thin returns them (see the deviations below) and as the server renders them:

- a **heap table's `rowid`** (and a `ROWID` column) is the 18-character base64
  text `ROWIDTOCHAR` returns, e.g. `AAAR3sAAEAAAACXAAA`;
- an **index-organized table's `rowid`** is a logical rowid, described as
  `UROWID`: its text starts with `*` (e.g. `*BAAAtAkCwQIBeP4`) and equals
  `CAST(rowid AS VARCHAR2(4000))` (`ROWIDTOCHAR` rejects logical rowids with
  ORA-01410);
- a **`UROWID` column** holds either form.

```dart
final r = await connection.execute('SELECT rowid AS rid, name FROM emp');
final rid = r.rows.first['RID'] as String; // 'AAAR3sAAEAAAACXAAA'

// A fetched rowid binds back as a plain String.
await connection.execute(
  'UPDATE emp SET name = :1 WHERE rowid = :2',
  ['Smith', rid],
);

// OUT binds and RETURNING targets declare the rowid type.
final ins = await connection.execute(
  'INSERT INTO emp (name) VALUES (:name) RETURNING rowid INTO :rid',
  {'name': 'Jones', 'rid': OracleBind.out(type: OracleDbType.rowid)},
);
ins.outBinds['rid']; // ['AAAR3sAAEAAAACZAAA']
```

- **Binds** — any `String` binds to a `ROWID` / `UROWID` column or a
  `WHERE rowid = :1` predicate (the server converts the text; an invalid one
  fails with ORA-01410). PL/SQL OUT / IN OUT binds, DML `RETURNING` targets
  and `OracleBindDef`s declare `OracleDbType.rowid` or `OracleDbType.urowid`
  (no `maxSize`): both travel as text with a fixed 3950-byte buffer
  (node-oracledb parity) — room for any physical rowid and for logical
  rowids up to 3950 characters — and either type receives physical and
  logical rowids alike. A value is always a
  `String` — there is no rowid wrapper type.
- **Everywhere rows are returned** — top-level queries (eager and
  `resultSet: true`), REF CURSOR OUT binds, nested `CURSOR()` columns,
  implicit results and `executeMany()` RETURNING values all decode the same
  text. `fetchTypeHandler` converters receive the `String`;
  `fetchAsString: {OracleDbType.rowid, OracleDbType.urowid}` is accepted and
  changes nothing. The same known issue applies as for intervals: on Oracle
  21c a SQL `NULL` in a REF CURSOR, nested `CURSOR()` or implicit-result row
  without a LOB or JSON column fails with ORA-01405.
- **Fail loud (fetch shapes only)** — a fetched `UROWID` value with no rowid
  bytes, or a physical one that is not exactly 13 bytes, and a `ROWID` or
  `UROWID` fetch payload cut short, raise `OracleException`
  (`oraProtocolError`). The `ROWID` fetch shape's leading length byte is not
  checked (the server sends 14 for every rowid; node-oracledb ignores it
  too), and OUT bind / `RETURNING` values arrive as plain text that is
  returned unchecked.
- **Deviations from node-oracledb** — the rowid components are encoded as
  unsigned numbers, so a data object or block number of 2^31 or more
  renders with the leading digit Oracle uses (node-oracledb's signed shift
  would differ); a malformed fetched `UROWID` fails loud as above, where
  node-oracledb reads the bytes unchecked or throws a `TypeError`. As in
  node-oracledb, an all-zero physical rowid decodes to `null`.

### VECTOR support

Oracle 23ai `VECTOR` columns decode by storage format, as node-oracledb thin
returns a typed array per format:

| Column format              | Dart value                                                       |
| -------------------------- | ---------------------------------------------------------------- |
| `FLOAT32`                  | `Float32List`                                                    |
| `FLOAT64`                  | `Float64List`                                                    |
| `INT8`                     | `Int8List`                                                       |
| `BINARY`                   | `Uint8List` — packed bits, one byte per 8 dimensions             |
| `SPARSE` (any format)      | `OracleSparseVector` — `numDimensions`, `indices` (`Uint32List`), `values` (the format's typed list) |

A flexible `VECTOR(*, *)` column returns each value in the format it was
stored in. A SQL `NULL` is `null`.

```dart
// docs.embedding is VECTOR(3, FLOAT32).
final r = await connection.execute('SELECT id, embedding FROM docs');
final v = r.rows.first['EMBEDDING'] as Float32List;

// Float32List / Float64List / Int8List and OracleSparseVector bind as vectors
// without a declared type. VECTOR_DISTANCE needs both operands in the same
// format, so bind a Float32List against this FLOAT32 column (ORA-51812
// otherwise).
final hits = await connection.execute(
  'SELECT id FROM docs '
  'ORDER BY VECTOR_DISTANCE(embedding, :1, COSINE) FETCH FIRST 5 ROWS ONLY',
  [Float32List.fromList([0.12, -0.5, 0.33])],
);

await connection.execute('INSERT INTO terms (id, vs) VALUES (:1, :2)', [
  7,
  OracleSparseVector(
    numDimensions: 30000,
    indices: [12, 4011],
    values: Float32List.fromList([0.8, 0.25]),
  ),
]);
```

- **Binds** — a `Float32List`, `Float64List`, `Int8List` or
  `OracleSparseVector` binds as a vector of that format (the server converts
  it to the column's format). A `Uint8List` keeps binding as RAW and a plain
  `List<double>` as JSON, as before this support existed — the server
  converts a JSON array into a `VECTOR` column, but vector functions such as
  `VECTOR_DISTANCE` need a typed list. Where the type is declared —
  `OracleBind.out` / `OracleBind.inOut(type: OracleDbType.vector)` and
  `OracleBindDef`s — a plain `List` of numbers travels as `FLOAT64` and a
  `Uint8List` as a `BINARY` vector. A single `execute()` cannot declare an IN
  bind's type, so a dense `BINARY` vector is bound through a PL/SQL block
  (`OracleBind.inOut`), an `executeMany()` with `bindDefs` (PL/SQL or DML
  `RETURNING`), or `TO_VECTOR('[255, 1]', 16, BINARY)` text. Every vector
  bind declares the 1 MB vector buffer (node-oracledb parity), so `maxSize`
  is not needed.
- **Migrating JSON array binds** — a `Float32List`, `Float64List` or
  `Int8List` used to bind as a JSON array; to keep that, convert it to a plain
  list first (`v.toList()`), which still binds as
  JSON.
- **Everywhere rows are returned** — top-level queries (eager and
  `resultSet: true`), PL/SQL OUT / IN OUT binds, DML `RETURNING` targets,
  REF CURSOR OUT binds, nested `CURSOR()` columns, implicit results and
  `executeMany()` decode the same values; `fetchTypeHandler` converters
  receive them, and `fetchLobs: true` leaves them as values (they are never
  `OracleLob` handles). `fetchAsString: {OracleDbType.vector}` throws
  `ArgumentError`, as for JSON — select `FROM_VECTOR(col)` for Oracle's text.
- **Server-side checks** — the dimension count must match the column
  (ORA-51803), NaN / ±Infinity are rejected (ORA-51805), sparse indices must
  be strictly ascending (ORA-51822), an empty vector is rejected
  (ORA-51862), and `VECTOR_DISTANCE` over two different formats is rejected
  (ORA-51812) — the server converts a bound vector into a column's format on
  INSERT / UPDATE, but not inside vector functions, so bind the column's own
  format there. `OracleSparseVector` itself checks the shape (positive
  dimension count, one value per index, every index in range, at most 65535
  non-zero elements) and throws `ArgumentError`.
- **Fail loud** — a malformed fetched vector image raises `OracleException`:
  `oraProtocolError` for a bad magic byte, a truncated image, a `BINARY`
  dimension count that is not a multiple of 8 or a sparse index outside the
  dimensions; `oraUnsupportedType` for an image version or format this driver
  does not know.
- **Deviation from node-oracledb** — a sparse `BINARY` vector decodes to an
  `OracleSparseVector` with one `Uint8List` byte per listed dimension, the
  form the server stores and node-oracledb itself encodes; node-oracledb
  cannot decode it.
- **Oracle 23ai only** — Oracle 21c rejects a `VECTOR` column with ORA-00902
  and a vector bind with ORA-03115. A table holding vectors must live in an
  automatic segment space management tablespace: the `SYSTEM` tablespace
  draws ORA-43853 (create it `TABLESPACE USERS`, for example).
- **Not covered** — vectors inside native JSON (OSON), the describe's
  dimension / format / sparse metadata (only `ColumnMetadata.oracleType`
  `127` identifies a vector column), and node-oracledb's fetch of a vector
  as text or a CLOB.

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

CLOB values round-trip as Dart `String`s by default (opt into an incremental
[`OracleLob` handle](#incremental-lob-access-with-fetchlobs) with
`fetchLobs: true`):

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

Statement-cache note: result cursors for queries that select CLOB (or BLOB,
or native JSON) columns are always re-parsed, never blind-reused from the
statement cache — fresh defines keep the LOB-prefetch row shape intact — while
RAW queries keep normal cursor reuse.

### BLOB support

BLOB values round-trip as Dart `Uint8List`s by default (opt into an incremental
[`OracleLob` handle](#incremental-lob-access-with-fetchlobs) with
`fetchLobs: true`):

- **Queries** — selecting a `BLOB` column returns a `Uint8List` (`null` for
  SQL NULL, an empty `Uint8List` for `EMPTY_BLOB()`). The driver reads LOB
  locators transparently and byte-for-byte — no character set conversion
  ever touches the bytes; values above 64 KiB are covered by tests. The one
  exception is a BLOB column with an `IS JSON` check constraint, whose value
  decodes to a `Map` / `List` / scalar — see
  [JSON stored in a BLOB](#json-stored-in-a-blob-is-json).
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
at the nearest even UTF-16BE sizes 65,534/65,536/65,538). On this **default**
path values are still materialized in memory as a single `String` / `Uint8List`,
so unbounded/multi-gigabyte LOBs are not claimed for it — use
[`fetchLobs`](#incremental-lob-access-with-fetchlobs) and
`OracleLob.textStream()` / `byteStream()` / `writeStream()` to move a value in
bounded pieces instead. NCLOB columns are supported as Dart `String` (the national
`AL16UTF16` charset — see [Character Set Support](#character-set-support)); BFILE
columns are not supported and fail with a clear `OracleException`.

### Incremental LOB access with `fetchLobs`

By default a fetched CLOB/NCLOB/BLOB is materialized whole into a `String` /
`Uint8List`. Pass `OracleExecuteOptions(fetchLobs: true)` to `execute()` instead
and each CLOB/NCLOB/BLOB in `result.rows` / `result.outBinds` arrives as an
`OracleLob` handle you read (and, for a writable locator, write) in bounded
pieces by offset and amount:

```dart
final result = await connection.execute(
  'SELECT doc FROM articles WHERE id = :1',
  [42],
  OracleExecuteOptions(fetchLobs: true),
);
final lob = result.rows.single['DOC'] as OracleLob;
try {
  print(lob.length);                       // native units (see below)
  final head = await lob.read(offset: 1, amount: 100) as String;
  final all = await lob.read() as String;  // whole value (default args)
  // getData([offset, amount]) is a positional alias of read(), for
  // node-oracledb parity: lob.getData(1, 100).
} finally {
  await lob.close();                        // always close
}
```

- **Units and offsets** — offsets are **1-based**; offsets, amounts, and
  `length` are counted in **characters (UCS-2 code units) for CLOB/NCLOB** and in
  **bytes for BLOB**. A CLOB/NCLOB `read` returns a `String`, a BLOB `read`
  returns a `Uint8List`. An `offset`/`amount` that splits a UTF-16 surrogate pair
  (a supplemental/astral character occupies two UCS-2 code units) has a
  type-dependent outcome — choose boundaries carefully: an **NCLOB /
  variable-length-charset CLOB** (decoded UTF-16BE) returns a lone surrogate as a
  partial character, while a **plain CLOB** (decoded UTF-8) fails loud with an
  `OracleException` because the split leaves an incomplete UTF-8 sequence.
- **No size ceiling on `read()`** — the requested range is fetched in one LOB
  READ round trip and, if one cannot carry it all, the read **continues** at the
  advanced offset until the range arrives. The bytes are assembled first and
  decoded exactly once, so a round-trip boundary can never corrupt multibyte or
  supplemental-plane text. (Measured: every value up to 32 MB on 23ai and 8 MB on
  21c still arrives in a single READ.) Use the streams below when the point is to
  avoid holding the whole value in memory.
- **Writing** — `write(offset, data)` (a `String` for CLOB/NCLOB, `Uint8List` /
  `List<int>` for BLOB) requires a **writable** locator: a LOB OUT/IN OUT bind or
  a `SELECT ... FOR UPDATE` locator. Writing through a read-only plain-`SELECT`
  locator surfaces the Oracle server error (it is not blocked client-side —
  measured: `ORA-22920`, with the handle and connection left usable). Writing
  past `length + 1` extends the LOB and the server fills the gap; the local
  `length` advance matches the server's own `DBMS_LOB.GETLENGTH`.
- **Trimming** — `trim(newSize)` shortens the LOB to `newSize` units (same
  units as `length`) in one round trip and sets `length`; `trim(0)` empties it
  (an empty LOB, not `NULL`). It needs a writable locator like `write()`, and
  on a persistent LOB the change is part of the current transaction. The server
  rejects a `newSize` past the end (`ORA-22926`), a read-only locator
  (`ORA-22920`) and a CLOB/NCLOB size that would split a surrogate pair
  (`ORA-22831`), leaving the handle, its `length` and the connection usable; a
  negative `newSize` throws `ArgumentError` before any round trip.
- **`length` and `chunkSize` are cached** — seeded from the fetch, advanced by
  `write()`, set by `trim()`. `refresh()` re-reads both from the server (one
  GET_LENGTH and one GET_CHUNK_SIZE round trip), and a `read()` that starts
  past the cached `length` always asks the server instead of the cache — see
  [Cached `length`](#temporary-lobs-you-create-fill-and-bind) below.
- **Lifecycle** — each open handle holds the connection's single in-flight slot:
  the connection rejects other operations (and the pool force-closes any
  still-open handle on release) until every handle is `close()`d. `close()` is
  idempotent. A SQL `NULL` LOB is Dart `null` under both modes, never a handle.
- **Multi-row caveat** — a multi-row SELECT with a LOB column yields **one
  handle per row** (200 rows → up to 200 open handles), and only **one** handle
  can be read/written at a time: the connection stays busy — rejecting every
  other statement, and logging a warning if the pool reclaims it — until you
  close **every** handle. Read each row's LOB fully and `close()` it before
  moving to the next, and don't leave any handle open. To close them all at once
  when you're done, call `result.closeLobs()` (it closes every open handle in
  `rows` / `outBinds` and returns the count):

  ```dart
  final result = await connection.execute(
    'SELECT id, doc FROM articles',
    null,
    OracleExecuteOptions(fetchLobs: true),
  );
  try {
    for (final row in result.rows) {
      final lob = row['DOC'] as OracleLob;
      final text = await lob.read() as String; // read one at a time
      await lob.close();                        // ...and close before the next
      // ... use text ...
    }
  } finally {
    await result.closeLobs(); // safety net: close any handle left open
  }
  ```

`fetchLobs` wraps top-level `execute()` SELECT rows, scalar OUT / IN OUT binds,
eager PL/SQL implicit-result rows, and a **streaming** `resultSet: true` cursor
(see below). It does **not** reach a CLOB/NCLOB/BLOB carried by a nested
`CURSOR(...)` column or a REF CURSOR OUT bind: those **fail loud** under
`fetchLobs` (rather than silently materializing or wrapping an untracked handle).
Without `fetchLobs`, such cursor rows decode normally — LOB columns arrive
materialized as `String` / `Uint8List` and native JSON columns as decoded values.
To get an `OracleLob` handle, project the LOB outside the cursor. See
[Known Limitations](#known-limitations) for the shape and the workaround.
`resultSet: true` + `fetchLobs: true`
on a **PL/SQL block** (whose implicit results come back as a group of lazy result
sets) also throws before any wire round trip; use the eager `execute()` path
there. Still not available: BFILE.

#### Streaming a LOB in and out

`textStream()` / `byteStream()` deliver a LOB in bounded pieces — **one LOB READ
round trip per piece** (see the supplemental-character note below for the single
exception) — and `writeStream()` feeds one in from a `Stream`, so a
multi-megabyte value never has to exist whole in memory:

```dart
// Read: one round trip per piece, nothing materialized whole.
final sink = File('article.txt').openWrite();
try {
  await for (final piece in lob.textStream(pieceSize: 64 * 1024)) {
    sink.write(piece);              // Stream<Uint8List> for a BLOB (byteStream)
  }
} finally {
  await sink.close();
  await lob.close();
}
```

```dart
// Write: node-oracledb's canonical streamed insert. A DML RETURNING ... INTO
// statement takes OracleBind OUT specs directly; each OUT bind returns a List
// with one value per affected row (a PL/SQL BEGIN/END wrapper also works).
final result = await connection.execute(
  'INSERT INTO articles (id, doc) VALUES (:id, EMPTY_CLOB()) '
  'RETURNING doc INTO :out',
  {'id': 1, 'out': OracleBind.out(type: OracleDbType.clob, maxSize: 1)},
  OracleExecuteOptions(fetchLobs: true),
);
final lob = (result.outBinds['out'] as List).single as OracleLob;
try {
  final written = await lob.writeStream(pieces); // Stream<String>; returns units
  await connection.commit();
} finally {
  await lob.close();
}
```

- **Units** are the type's native ones: characters (UCS-2 code units) for
  CLOB/NCLOB, bytes for BLOB — same as `read` / `write` / `length`.
- **`pieceSize`** defaults to `chunkSize` when the server reported one and
  otherwise to `OracleLob.defaultStreamPieceSize` (32,768; the top-level
  `defaultLobStreamPieceSize` is a deprecated alias); a multiple of `chunkSize`
  is recommended. Note `chunkSize` is a **byte** count for every LOB type
  (measured: identical for a CLOB and a BLOB with the same `CHUNK` clause, and
  equal to `DBMS_LOB.GETCHUNKSIZE`), not characters like `length`. The concatenation of the emitted pieces equals
  `read(offset: offset)` exactly — for a LOB whose length has not changed since
  the handle was fetched or last `refresh()`ed (see the next bullet for the one
  case where they deliberately differ).
- **A read stream ends when a READ returns no data**, not when the cached
  `length` is reached — so it is immune to a `length` that went stale after the
  fetch, and it never loops past the end. That terminating empty READ costs one
  extra round trip, and an **empty** LOB yields no pieces at all. This is also
  the one case where a stream and `read()` disagree, and the stream is the
  accurate one: for a LOB that **grew** server-side after the fetch, a `read()`
  starting inside the cached `length` caps its request there and returns a
  stale prefix, while the stream keeps going to the real end and so returns
  strictly more. Call `refresh()` before the `read()` to close that gap.
- **Emitted CLOB pieces are not guaranteed whole-character-aligned** (the driver
  picks the boundaries), but they are never corrupt: a split encoding sequence or
  a trailing unpaired high surrogate is held back and joined to the next piece, so
  the **concatenation is always exact**. That carry-over is why a supplemental
  (astral) character straddling a boundary relaxes both piece-level guarantees: a
  piece may be **one UCS-2 code unit longer than `pieceSize`**, and a piece may be
  assembled from **more than one READ** (a READ whose payload is entirely held
  back emits nothing). A LOB that itself ends with an unpaired high surrogate
  emits it as the final piece, again to keep the concatenation exact. `byteStream`
  has no carry-over and so no exceptions.
- **`writeStream` issues one write per caller chunk** at the running offset —
  your chunk size is the wire piece size. An empty chunk costs no round trip, and
  a surrogate pair split across two chunks is stitched back together (that
  boundary is the driver's, unlike the caller-chosen boundaries `write()` stays
  lenient about); a chunk stream ending on a still-unpaired high surrogate costs
  one extra write to flush it. It is **not atomic**: a bad chunk or a server error
  aborts the rest and leaves what was already written in place.
- **Cancelling a read stream mid-flight** leaves the connection immediately
  reusable; the handle stays open, so `close()` it as usual. Liveness is
  re-checked before every piece, so closing the handle (or losing the connection)
  mid-stream fails the stream loud rather than truncating it silently.
- **`executeStream()` / `queryStream()` are unrelated** — they stream *rows* and
  always materialize LOB columns; they take no `fetchLobs` argument.

#### Streaming result sets that yield LOB handles

Combine `resultSet: true` with `fetchLobs: true` and each batch's LOB columns are
wrapped as handles **as the batch is prefetched**, so a huge result set never
holds a handle per row up front:

```dart
final result = await connection.execute(
  'SELECT id, doc FROM articles',
  null,
  OracleExecuteOptions(resultSet: true, fetchLobs: true, fetchSize: 100),
);
final rs = result.resultSet!;
try {
  for (var row = await rs.getRow(); row != null; row = await rs.getRow()) {
    final lob = row['DOC'] as OracleLob?;
    if (lob == null) continue;               // SQL NULL LOB
    try {
      await for (final piece in lob.textStream()) { process(piece); }
    } finally {
      await lob.close();                     // close every handle you receive
    }
  }
} finally {
  await rs.close();      // reaps any handle prefetched but never delivered
}
```

- **Close every handle you receive** — each holds the connection's in-flight
  slot, and only one can be read at a time. Reading a LOB *between* two
  `getRow()` calls is fine and does not disturb the cursor (verified on Oracle
  23ai and 21c).
- **`rs.close()` is the safety net** — it force-closes every handle the cursor
  wrapped for a prefetched row you never retrieved, so abandoning iteration early
  cannot wedge the connection. A handle you already **received** survives
  `rs.close()` and stays readable, which makes the "collect the rows, close the
  result set, then read the LOBs" pattern work.
- **`result.closeLobs()`** also reaches a streaming result set's buffered
  handles, and the pool force-closes everything on release.

#### Temporary LOBs you create, fill, and bind

`createTemporaryClob()`, `createTemporaryNClob()` and `createTemporaryBlob()`
create a new, **empty** session-duration temporary LOB on the server and return
it as a caller-owned `OracleLob`. Fill it with `write()`, bind it into an
`INSERT` or a PL/SQL block, then `close()` it — this is how you build a value
above the 32 KB inline bind limit without materializing one giant
`String`/`Uint8List`:

```dart
final lob = await connection.createTemporaryClob();
try {
  await lob.write(1, firstChunk);             // 1-based offsets
  await lob.write(lob.length + 1, nextChunk); // append after what you wrote
  print(lob.length);        // characters (UCS-2 code units); bytes for BLOB
  print(lob.isTemporary);   // true
  print(lob.chunkSize);     // real server chunk size

  await connection.execute(
    'INSERT INTO articles (id, doc) VALUES (:id, :doc)',
    {'id': 1, 'doc': lob},  // binds as the server-side LOB locator
  );
  await connection.commit(); // the temp LOB survives commit()
} finally {
  await lob.close();         // ALWAYS close
}
```

- **Units and offsets** — identical to a fetched handle: 1-based offsets, counted
  in **characters (UCS-2 code units)** for CLOB/NCLOB and in **bytes** for BLOB.
  `createTemporaryNClob()` stores/transfers its data as UTF-16BE and requires the
  `AL16UTF16` national character set (it throws before any wire round trip
  otherwise).
- **You must `close()` it** — Oracle holds session resources for every unclosed
  temporary LOB (visible in `V$TEMPORARY_LOBS`). `close()` is idempotent and
  never throws. The actual server-side free travels as a **piggyback on the next
  `execute()`** on that session, matching node-oracledb: a `close()` followed
  only by `connection.close()` relies on session teardown, and a pooled
  connection's pending frees are flushed by the next borrower's first
  `execute()`. `commit()` / `rollback()` / `ping()` do not flush them.
- **Releasing a pooled connection closes it for you** — if you `release()` a
  healthy, idle pooled connection while a temporary LOB you created is still
  open, the pool logs a warning, force-closes the handle and queues its
  server-side LOB for freeing on the next borrower's first `execute()` (or at
  session teardown). Later read/write operations on that handle fail with a
  pool-reclaim error; cached properties and another `close()` remain usable.
  `close()` every handle before `release()`.
- **It does not block other statements** — unlike a fetched handle, an open
  created-temporary handle leaves the connection free to run statements (binding
  it is the whole point). Individual LOB round trips are still serialized, so
  `await` each `read()` / `write()`.
- **Session duration, not transaction duration** — the LOB survives `commit()`
  and `rollback()`.
- **An empty temporary LOB is not SQL `NULL`** — binding a created-but-unwritten
  handle stores an **empty LOB**, deliberately unlike binding an empty `String`
  (which Oracle's `'' IS NULL` semantics store as `NULL`).
- **Binding** — pass the handle positionally (`[lob]`), by name
  (`{'doc': lob}`), or as
  `OracleBind.inOut(value: lob, type: OracleDbType.clob, maxSize: ...)` in a
  PL/SQL block. Binding never frees the handle: its lifetime is yours. Binding a
  **closed** handle, or one belonging to a **different** connection, throws
  before any wire round trip. **Only created-temporary handles can be bound.** A
  handle obtained from `fetchLobs: true` holds the connection's single in-flight
  slot while it is open, so the statement that would bind it is rejected as a
  concurrent operation (with an error saying exactly that) — read the fetched
  value, `close()` the handle, then bind the value or a created-temporary LOB. `executeMany()` does not accept `OracleLob` values
  (it fails loud naming `execute()`); pass plain `String` / `Uint8List` values
  there and the driver creates a temporary LOB per iteration.
- **An `IN OUT` bind consumes the handle** — validated on Oracle 23ai and 21c:
  the server replaces the LOB behind an `IN OUT` bind, so the returned value in
  `result.outBinds` is correct but a later `read()` on the **bound** handle
  raises `ORA-22922`. Read the returned value (a `String` / `Uint8List`, or a
  fresh `OracleLob` under `fetchLobs: true`) and treat the bound handle as spent;
  you still `close()` it. A plain **IN** bind leaves the handle fully usable.
- **Cached `length`** — `length` (and `chunkSize`) are seeded from the
  locator's prefetch metadata, advanced locally by `write()` and set by
  `trim()`; only `refresh()` re-reads them from the server. How `read()` uses
  the cached `length` depends on where it starts:
  - **past the cached end** (`offset > length`, including any read of an empty
    handle): the server is asked, never the cache. If the LOB really ends there
    the empty value comes back after **one** READ round trip; if it grew, the
    read continues piece by piece (like the streams) until the requested
    `amount` arrives or the server reports the end, returns the new data, and
    advances `length`. (1.4.0 returned the empty value here without asking —
    silently wrong for a LOB that had grown.)
  - **inside the cached range**: the request is capped at the cached `length`,
    so for a LOB that grew the read returns the prefix up to the stale end (no
    error), and for one that shrank a read for the full cached length **can**
    fail loud (a length mismatch, or `"LOB read made no progress"`) rather than
    return short data. The
    remedy for both is **`refresh()`** before the read (or a re-select).

  `textStream()` / `byteStream()` never consult `length` and stop on the
  server's empty READ. Measured on Oracle 23ai and 21c: because a LOB locator is
  read-consistent, a handle fetched before another session's committed update
  keeps seeing the *old* value in full — correct data, never silently truncated
  — in **both** directions, its READ past the old end comes back empty, and
  `refresh()` reports the old length too, so `length` and `read()` always
  agree; a re-select is what surfaces the new value. `refresh()` and `trim()`
  fail with `ORA-22275` on the locator of an `EMPTY_CLOB()` / `EMPTY_BLOB()`
  value that was never stored (`SELECT EMPTY_CLOB() FROM dual`, or a PL/SQL
  `:out := EMPTY_CLOB()`), which `read()` handles fine.

`OracleLob.isTemporary` reports whether a handle references a temporary LOB —
always `true` for a created one, and `true` for a fetched locator that carries
the server's temporary flag or its abstract (server-expression) LOB flag.
Measured on 23ai and 21c: a plain table LOB, a `SELECT ... FOR UPDATE` locator
and an `EMPTY_CLOB()` value report `false` (they allocate no session temp-LOB
space). Every server **expression** LOB reports `true` — a `SELECT TO_CLOB(...)`
/ `TO_BLOB(...)` value, a CLOB concatenation, and a PL/SQL CLOB/BLOB OUT bind
the body fills from a `VARCHAR2` / `RAW` value or a `TO_CLOB` literal: each one
holds a `V$TEMPORARY_LOBS.ABSTRACT_LOBS` entry until freed. The driver frees
them for you when it materializes the value (`fetchLobs: false`), and a fetched
handle frees its LOB on `close()`. An OUT locator the body assigns from a
*temporary* input LOB (`p_out := p_in`) and an `IN OUT` bind's returned locator
report `true` as well.

If two open handles reference the **same** server LOB — a created temporary LOB
bound as a plain IN into a block that returns it as an OUT value
(`p_out := p_in`) under `fetchLobs: true` — the free is queued only when the
**last** of them closes, so closing one never destroys the LOB under the other.

### JSON support

Oracle's **native `JSON` data type** (introduced in Oracle Database 21c;
requires database `compatible >= 20`) round-trips as ordinary Dart values —
`Map<String, Object?>` for objects, `List<Object?>` for arrays, or a Dart
scalar for a scalar JSON root. Members are `null` / `bool` / `num` /
`String` and nested maps/lists, plus the Oracle-specific scalars listed
below — in **both directions**: values within the bind limits can be bound
back, subject to the date and number narrowings listed below. On the
wire, values travel in Oracle's binary JSON format (OSON) under the native
type — no `jsonEncode()`/`jsonDecode()` round-trip through text, no Oracle
Client, no LOB read round trips:

- **Queries** — selecting a `JSON` column returns a `Map`, `List`, or scalar
  (`null` for SQL NULL or a JSON null root). Document shape and member order
  are preserved and multi-batch fetches work normally. As with CLOB / BLOB
  queries, a repeated JSON SELECT keeps its statement-cache slot but its
  cursor is re-parsed with fresh defines rather than blind-reused.
- **Oracle-specific scalars** — a JSON value may also hold Oracle scalars
  the server keeps in their native form (e.g. from `JSON_SCALAR(SYSDATE)` or
  `JSON_OBJECT(... RETURNING JSON)` over typed columns). They map as follows,
  wherever they appear in the document, when fetching **and** when binding:

  | Scalar inside the JSON value          | Dart type (fetch)    | Bound from Dart as |
  | ------------------------------------- | -------------------- | ------------------ |
  | `DATE`, `TIMESTAMP`                   | `DateTime` — same as a `DATE` / `TIMESTAMP` column (local wall clock, fractional seconds truncated to microseconds) | A local `DateTime` → a `TIMESTAMP` (7 bytes with no sub-second part, else 11), written from its wall-clock fields exactly like a `DATE` / `TIMESTAMP` column bind. A UTC `DateTime` (`isUtc`) names an instant, so it travels as `TIMESTAMP WITH TIME ZONE` at `+00:00` instead and fetches back as an `OracleTimestampTz` for the same instant |
  | `TIMESTAMP WITH TIME ZONE`            | Always `OracleTimestampTz` (UTC instant + original offset; `+00:00` plus a `regionId` for a [region-id](#region-id-time-zones) value), regardless of `preserveTimestampTimeZone` — unlike a column, which returns a UTC `DateTime` by default | `OracleTimestampTz` → `TIMESTAMP WITH TIME ZONE`, offset preserved |
  | `BINARY_FLOAT`, `BINARY_DOUBLE`       | `double` (NaN and ±Infinity included; `BINARY_FLOAT` widened from single precision) | Doubles outside Oracle `NUMBER`'s range (magnitude ≥ 1E126, or a non-zero magnitude below 1E-130) → `BINARY_DOUBLE`; every other finite `num`, including `0.0` / `-0.0`, stays `NUMBER`. NaN and ±Infinity are **rejected by default** (strict JSON has no such values) with an `ArgumentError` naming the member's path; opt in per bind with `OracleBind.inOut(..., type: OracleDbType.json, allowNonFinite: true)` to send them as `BINARY_DOUBLE`. node-oracledb sends NaN as `BINARY_DOUBLE` unasked and cannot bind ±Infinity or out-of-range doubles at all |
  | `RAW` / binary                        | `Uint8List` — an empty binary JSON scalar is an empty list of bytes; an empty `RAW` column decodes to `null` | `Uint8List` → binary (bytes, never an array of numbers) |

  Any fetched document therefore binds back without conversion and fetches
  back equal — except that NaN / ±Infinity members re-bind only through the
  `allowNonFinite` opt-in (a PL/SQL `IN OUT JSON` parameter), and field names
  over 255 UTF-8 bytes only on Oracle 23ai — with these narrowings of the
  stored form:
  - a `DATE` node re-binds as a 7-byte `TIMESTAMP` (same `DateTime`);
  - a finite `BINARY_FLOAT` / `BINARY_DOUBLE` within `NUMBER`'s range
    re-binds as `NUMBER` (equal value; an integral value then decodes as
    `int`, and a `BINARY_FLOAT` keeps its widened single-precision value,
    e.g. `3.140000104904175`);
  - `-0.0` re-binds as `NUMBER` zero and comes back as `0`;
  - nanoseconds were already truncated to microseconds on fetch;
  - a region-id `TIMESTAMP WITH TIME ZONE` member decodes at `+00:00` with a
    `regionId` and re-binds as an offset node at `+00:00` (same instant, the
    region is not carried back);
  - a fetched `DateTime` is a local wall-clock value (as from a `DATE`
    column), and re-binds from those same fields.

  BCE dates fail loudly with `OracleException` on fetch, as they do for
  columns; a region-name time zone (e.g. `US/Pacific`) decodes to its UTC
  instant at `+00:00` with a `regionId` that `timeZoneRegionName` resolves,
  as for a column (see
  [Region-id time zones](#region-id-time-zones)); binding a `DateTime` /
  `OracleTimestampTz` outside years 1–9999 fails loudly at the call site.
  Fetched documents holding these Dart types are not plain JSON, so
  `jsonEncode()` on one can throw `JsonUnsupportedObjectError`.
- **DML** — bind an ordinary `Map<String, Object?>` or `List<Object?>` into a
  `JSON` column with named or positional binds (`execute()` or
  `executeMany()`); the driver encodes it as OSON. Members may be `null`,
  `bool`, `num`, `String`, `DateTime`, `OracleTimestampTz`, `Uint8List`, and
  nested maps/lists; anything else (e.g. `Set`, a non-`String` key, an
  arbitrary object) fails loudly at the call site with `ArgumentError`
  (`OracleException` with `oraBindTypeError` from `executeMany()`) before any
  round trip, and the error never echoes the document — it names the
  offending member by position (list index, or 1-based object member
  ordinal such as `[member #2]`), never by value or key. The same applies to:
  - **NaN / ±Infinity** — rejected by default; a DML or `executeMany()` bind
    has no opt-in, only `OracleBind.inOut(..., allowNonFinite: true)` does.
  - **Field names** — up to 255 UTF-8 bytes on every server; up to 65535
    bytes on Oracle 23ai (the document then travels as OSON version 3, and
    the server can query those names). An older server refuses longer names
    at the call site: Oracle 21c would store such a document but could not
    read it back.
  - **Nesting** — objects and arrays may nest at most 1000 levels (Oracle's
    JSON limit); a deeper value, or a cyclic one (a map or list that contains
    itself), fails instead of overflowing the stack. A sub-document shared by
    two members is fine.

  Each document is validated once per bind. Numeric members follow the same
  NUMBER contract as scalar columns: integers beyond 2⁵³ decode to `double`
  and lose precision (see [Known limitations](#known-limitations)).
- **Scalar JSON values** — a bare `String`, `num`, `DateTime`, `Uint8List`,
  … bind keeps its usual column type (`VARCHAR2`, `NUMBER`, `DATE`, `RAW`),
  so a `String` bound into a `JSON` column is parsed by the server as JSON
  *text*. A scalar JSON value binds only through **PL/SQL**, where the JSON
  type can be declared explicitly: an `OracleBind.inOut(value: 'x', type:
  OracleDbType.json, maxSize: ...)` bound to an `IN OUT JSON` parameter, or
  `executeMany()` of a PL/SQL block with
  `OracleBindDef.input(type: OracleDbType.json)` in `bindDefs` (e.g.
  `BEGIN INSERT INTO t (doc) VALUES (:1); END;`). Plain SQL DML cannot bind
  one: its binds always take their type from the value, and `executeMany()`
  rejects `bindDefs` for plain array DML. The root may be any supported
  scalar (`String`, `num`, `bool`, `DateTime`, `OracleTimestampTz`,
  `Uint8List`). A declared-JSON `String` is a JSON **string** scalar, never
  parsed: `'{"a":1}'` stores the string `"{\"a\":1}"` — bind the `Map`
  itself, not `jsonEncode(map)`.
- **PL/SQL OUT / IN OUT** — declare
  `OracleBind.out(type: OracleDbType.json, maxSize: ...)` or
  `OracleBind.inOut(value: ..., type: OracleDbType.json, maxSize: ...)`;
  values decode through `result.outBinds`. `maxSize` counts **OSON bytes**
  (the binary wire encoding) and bounds the returned document — a larger
  return fails loudly instead of truncating. `OracleBind.inOut(...,
  allowNonFinite: true)` lets the value hold NaN / ±Infinity (sent as
  `BINARY_DOUBLE`); the flag is JSON-only and rejected on other types.

**Creating `JSON` tables — tablespace requirement.** A native `JSON` column
requires a tablespace that uses **Automatic Segment Space Management (ASSM)**.
The default `USERS` tablespace qualifies; the `SYSTEM` tablespace does not, so
`CREATE TABLE ... (doc JSON)` run as a user whose default tablespace is
`SYSTEM` (e.g. the `system` account) fails with **`ORA-43853: JSON type
columns are not allowed in this tablespace`** on every server version. Add an
explicit `TABLESPACE USERS` (or any ASSM tablespace) to the `CREATE TABLE`, or
grant the schema a default ASSM tablespace. This is an environment/DDL
requirement, not a driver limitation.

**Native vs. textual JSON.** The sections above cover the dedicated `JSON`
column type (OSON-backed, 21c+). JSON stored the pre-21c way in a **`BLOB`**
column with an `IS JSON` check constraint decodes to the same Dart values —
see [JSON stored in a BLOB](#json-stored-in-a-blob-is-json) below. JSON *text*
in `VARCHAR2` / `CLOB` (or `RAW`) `IS JSON` columns keeps its ordinary
`String` / `Uint8List` behavior; parse it with `dart:convert` or query it
through SQL/JSON functions. JSON text inserted *into* a native `JSON` column
is parsed by the server and reads back as `Map`/`List`.

Not in scope: SODA, JSON-relational duality views, and the Oracle-specific
JSON scalars beyond date/time, binary and float/double — `INTERVAL YEAR TO
MONTH`, `INTERVAL DAY TO SECOND`, `JsonId`, and VECTOR inside JSON
documents. Documents containing such scalars fail loudly with
`OracleException` (`oraUnsupportedType`, naming the scalar kind) rather than
decoding silently or partially, and no Dart value binds as one.

#### JSON stored in a BLOB (`IS JSON`)

The Oracle 12c pattern — a `BLOB` column constrained `IS JSON` (or
`IS JSON FORMAT OSON`) — reads back exactly like a native `JSON` column:
`Map<String, Object?>`, `List<Object?>`, or a Dart scalar, with SQL NULL as
`null`. It works for an eager `execute()`, `resultSet: true`,
`queryStream()` / `executeStream()`, and implicit result sets (validated on
Oracle 21c and 23ai; the decision comes from the column describe, never from
the server version), so applications no longer hand-decode bytes per server
version:

```dart
await connection.execute(
  'CREATE TABLE orders (id NUMBER, doc BLOB CHECK (doc IS JSON))',
);
await connection.execute(
  'INSERT INTO orders VALUES (1, :doc)',
  {'doc': {'item': 'rocket', 'qty': 2}}, // a Map binds as JSON (21c+)
);
final result = await connection.execute('SELECT doc FROM orders');
final doc = result.rows.first['DOC'] as Map<String, Object?>; // not bytes
```

- **Detection** follows node-oracledb: the column describe carries an
  `IS JSON` (or OSON) flag, exposed as `ColumnMetadata.isJson` /
  `ColumnMetadata.isOson` (raw word: `ColumnMetadata.udsFlags`). The flag
  belongs to the table column — a view over the table, or an expression such
  as `TO_BLOB(doc)`, describes without it and returns plain `Uint8List`.
- **Content** — bytes starting with the OSON magic (`IS JSON FORMAT OSON`
  columns) decode as OSON, including the Oracle-specific scalars listed
  above. Anything else is JSON text: UTF-8 (with or without a byte-order
  mark), or UTF-16LE / UTF-16BE (with a byte-order mark, or detected from the
  zero-byte pattern without one — Oracle accepts both).
- **Writes** need nothing new: bind a `Map` / `List` (it travels as native
  JSON, so the server needs native JSON support — 21c+ with
  `compatible >= 20`; it is stored as JSON text, or as OSON in a
  `FORMAT OSON` column), or bind the JSON text bytes as a `Uint8List`
  (`utf8.encode(jsonEncode(doc))`) on any server. Oracle-specific scalar
  members (`DateTime`, `OracleTimestampTz`, `Uint8List`, and NaN/±Infinity
  through the `allowNonFinite` opt-in) are
  converted by the server: a text `IS JSON` column stores Oracle's JSON text
  serialization — dates as ISO-8601 strings (`"2024-03-15T10:20:30"`),
  binary as a hex string (`"DEAD"`), NaN/±Infinity as `"Nan"` / `"Inf"` /
  `"-Inf"` — so they read back as `String`s, while an `IS JSON FORMAT OSON`
  column keeps them and reads back the same Dart types (measured on 21c and
  23ai).
- **Fails loud** — a value the driver cannot decode throws `OracleException`
  (`oraUnsupportedType`, naming the column) for the whole call; it never
  returns raw bytes, `null`, or a partial result. The default `IS JSON`
  constraint is *lax*, so Oracle also accepts values that are not strict
  JSON and that therefore fail here: lax syntax (unquoted field names,
  single-quoted strings, upper-case `TRUE`), trailing NUL bytes, and a
  zero-length `EMPTY_BLOB()`. Use `IS JSON STRICT` to keep such values out,
  or read them as bytes with `rawJsonBlobs: true` (below).
- **Raw-bytes opt-out** — `OracleExecuteOptions(rawJsonBlobs: true)` returns
  such a column as the stored `Uint8List` (its type before 1.5.0): no decode
  and no JSON validation (lax or empty values read without an error), SQL NULL
  still `null`. It applies to every row of that call — eager `execute()`, every
  batch of `resultSet: true`, implicit results (eager and `resultSet: true`),
  and REF CURSOR OUT bind / nested `CURSOR()` rows — and only to BLOB
  `IS JSON` columns: a native `JSON` column in the same row still decodes.
  `queryStream()` and `executeStream()` have no fetch options;
  `executeMany()` has options, but no `rawJsonBlobs` option for its implicit
  result rows. To read such a column as bytes, use a separate `execute()`
  SELECT with `rawJsonBlobs: true` (and `resultSet: true` for large results).

  ```dart
  final raw = await connection.execute(
    'SELECT doc FROM orders',
    null,
    const OracleExecuteOptions(rawJsonBlobs: true),
  );
  final bytes = raw.rows.first['DOC'] as Uint8List;
  ```

  `OracleExecuteOptions(fetchLobs: true)` still returns an `OracleLob` handle
  whose `read()` yields the stored bytes untouched, and wins when both options
  are set. It too affects only the LOB columns. For PL/SQL implicit results,
  use eager `execute()` with `fetchLobs`; the combination of `resultSet: true`
  and `fetchLobs: true` is unsupported for a PL/SQL block.
- **Behavior change (1.5.0):** before this release such a column returned a
  `Uint8List`; code that decoded those bytes itself must now accept the
  decoded value or pass `rawJsonBlobs: true`. Decoding by default is this
  driver's choice — node-oracledb returns the raw `Buffer` unless
  `oracledb.future.oldJsonColumnAsObj` is enabled.
- **Not covered:** `fetchLobs: true` for a `REF CURSOR` OUT bind or nested
  `CURSOR()` column carrying the BLOB — those rows decode without the option,
  but embedded LOB handles are not supported (see
  [Known Limitations](#known-limitations)); and `CLOB` / `VARCHAR2` / `RAW`
  `IS JSON` columns, which stay `String` / `Uint8List`; and a BLOB returned
  through a PL/SQL OUT bind or `RETURNING ... INTO`, which carries no column
  describe flag and so stays a `Uint8List`.

## Character Set Support

This driver follows node-oracledb's **thin-mode** character-set model: the client
always negotiates **UTF-8** (`AL32UTF8`) on the wire, and the **Oracle server**
performs any conversion to and from the database's own character set. There is no
configurable client-side database-charset codec, and the driver does **not** read
the `NLS_LANG` environment variable — character handling is delegated to the
server exactly as Oracle's own thin drivers do. `connection.charsetInfo` exposes
the detected `databaseCharset` / `nationalCharset` for diagnostics
(`OracleCharsetInfo`).

### Database character set — `VARCHAR2`, `CHAR`, `CLOB`

Because the client speaks UTF-8 and the server converts, the database character
set is transparent to your code:

- **`AL32UTF8`** (the Oracle default since 12c) round-trips directly.
- **Single-byte / non-`AL32UTF8`** database character sets round-trip via
  Oracle's server-side conversion. This is validated end-to-end against
  **`WE8MSWIN1252`** (Windows-1252 Western European), exercising characters that
  are specific to that code page — euro sign, smart quotes, en/em dashes,
  ellipsis, bullet — so the round-trip proves real UTF-8 ⇆ server conversion
  rather than a byte-identity accident.

You never select a client codec; the driver keeps primary text on the UTF-8 wire
path regardless of the database character set.

### National character set — `NCHAR`, `NVARCHAR2`, `NCLOB`

National-character types are supported when the database's national character set
is **`AL16UTF16`** — the standard (and only non-deprecated) national charset,
which both validated server lines (Oracle 23ai and 21c) use. National values
travel the wire as UTF-16BE and map to Dart `String`:

- Selecting an `NCHAR` / `NVARCHAR2` / `NCLOB` column returns a `String`.
- Bind national data with `OracleDbType.nVarchar` (NCHAR / NVARCHAR2) or
  `OracleDbType.nClob` (NCLOB). `connection.charsetInfo.supportsNationalCharacterSet`
  is `true` when the server's national charset is `AL16UTF16`.

### Fail-loud on unsupported national character sets

If a connection's national character set is **not** `AL16UTF16` (for example the
deprecated `UTF8` national charset, which thin mode does not support), the driver
**fails loud** with an `OracleException` on any `NCHAR` / `NVARCHAR2` / `NCLOB`
bind or column — it never silently produces mojibake. Ordinary
`VARCHAR2` / `CHAR` / `CLOB` columns are unaffected and keep working over the
UTF-8 wire path regardless of the national character set.

### Thin-model boundaries

- **No `NLS_LANG` parsing** — the environment variable is ignored (node-oracledb
  thin parity).
- **No configurable client-side database-charset codec** — the server performs
  database-charset conversion.
- **One national character set is supported:** `AL16UTF16`.

## Project Status

This package implements a subset of the full Oracle driver feature set. Below is the current roadmap:

| Epic                                            | Status         |
| ----------------------------------------------- | -------------- |
| Core connection & authentication                | ✅ Done        |
| Query execution & transactions                  | ✅ Done        |
| PL/SQL execution (stored procedures, functions) | ✅ Done        |
| Advanced data types (CLOB, BLOB, RAW, JSON)     | ✅ Done        |
| Connection pooling                              | ✅ Done        |
| Result sets, streaming, REF CURSOR & implicit results | ✅ Done  |
| Character set support (`AL32UTF8` + non-`AL32UTF8` databases, national types) | ✅ Done |
| Bulk DML (`executeMany()` — array DML, RETURNING, bulk PL/SQL, batch errors) | ✅ Done |
| LOB streaming & temporary LOBs (`OracleLob`, chunked read/write, `textStream`/`byteStream`/`writeStream`, `createTemporary*`) | ✅ Done |
| Extended data types (INTERVAL DAY TO SECOND / YEAR TO MONTH, ROWID / UROWID, 23ai VECTOR; unsupported types fail loud) | ✅ Done |

### Planned After 1.0

After the 1.0 release, the project roadmap includes larger API and compatibility work. These items are planned candidates and may change as the APIs are designed and validated:

| Priority | Planned enhancement                                                                       |
| -------- | ----------------------------------------------------------------------------------------- |
| 1        | Extended JSON / OSON parity (interval/VECTOR/`JsonId` JSON scalars, OSON-in-BLOB helpers) |
| 2        | Optional temporal fetch formatting (fetch-as-string, fetch type handlers); region-id values already decode to the correct instant and their region names resolve through `timeZoneRegionName` |

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

The non-`AL32UTF8` character-set round-trip is proven by an optional, local-only
fixture (a `WE8MSWIN1252` database on port 1523). It is double-gated behind
`RUN_NON_AL32UTF8_TESTS` and is **not** part of `docker compose up` — see
[CONTRIBUTING.md](CONTRIBUTING.md#non-al32utf8-character-set-fixture) for the full
walkthrough. In CI it runs as a manually-dispatched (`workflow_dispatch`) job
rather than a blocking push/PR check (the gvenzl cold-start plus charset migration
is slower and less proven than the standard service jobs):

```bash
# Optional: non-AL32UTF8 (WE8MSWIN1252) database charset round-trip
docker compose --profile non-al32utf8 up -d oracle-non-al32   # wait for healthy
RUN_INTEGRATION_TESTS=true RUN_NON_AL32UTF8_TESTS=true \
  dart test test/integration/charset_non_al32utf8_integration_test.dart
```

## Known Limitations

- **Character sets** — primary character data (`VARCHAR2`/`CHAR`/`CLOB`) is handled via Oracle's server-side conversion while the client always negotiates UTF-8, so both `AL32UTF8` and non-`AL32UTF8` database character sets are supported (validated against `WE8MSWIN1252`). National types (`NCHAR`/`NVARCHAR2`/`NCLOB`) require the `AL16UTF16` national charset and otherwise fail loud — there is no client-side codec and `NLS_LANG` is ignored. See [Character Set Support](#character-set-support) for the full matrix.
- **Statement cache and external DDL** — top-level DDL executed on the same connection clears the statement cache, but DDL issued from another session (or inside a PL/SQL block) can leave stale cached SELECT metadata. This matches node-oracledb thin-mode behavior.
- **CLOB/BLOB/JSON/VECTOR cursor re-parse** — result cursors for queries selecting CLOB, BLOB, native JSON or VECTOR columns are always re-parsed, never blind-reused from the statement cache (fresh defines are required to keep the LOB-prefetch metadata); RAW queries keep normal cursor reuse.
- **NUMBER beyond 2⁵³** — integer-valued NUMBERs larger than 2⁵³ decode to `double` and lose precision (Dart `double` limit; matches node-oracledb).
- **No SQL `BOOLEAN` or object types** — a 23ai `BOOLEAN` column and object-type columns (`XMLTYPE`, `ANYDATA`, user-defined objects, collections) are not decoded: fetching one raises `OracleException` (`oraUnsupportedType`) and leaves the connection usable. Convert them in SQL. See [Unsupported types fail loud](#unsupported-types-fail-loud).
- **`LONG` on Oracle 21c** — fetching a `LONG` column was observed to time out (ORA-12170) instead of failing fast with `oraUnsupportedType` as it does on 23ai (pre-existing). `LONG RAW` was not checked on 21c.
- **Nested `CURSOR()` / REF CURSOR rows carrying a LOB with `fetchLobs: true`** — a `CLOB`/`NCLOB`/`BLOB` column projected by a nested `CURSOR(...)` column or a `SYS_REFCURSOR` OUT bind is **not** wrapped as an `OracleLob` handle: with `fetchLobs: true` the call fails loud with an `OracleException` (the cursor-embedded handle lifecycle is not built), after the execute round trip and leaving the connection usable. Without `fetchLobs` these rows decode normally on Oracle 23ai and 21c — LOBs materialize as `String` / `Uint8List`, and native `JSON` (and, on 23ai, `VECTOR`) columns decode to their Dart values (the driver sends a DEFINE call before the cursor's first FETCH, as node-oracledb does). **Workaround for a handle:** project the LOB column outside the cursor (join it into the outer SELECT, or return its key from the cursor and read the LOB in a second statement). `DBMS_SQL.RETURN_RESULT` implicit result sets behave the same way: their LOB / JSON / VECTOR columns decode normally.
- **One operation per connection** — a connection supports one in-flight operation; overlapping `execute()` calls throw. Use a connection pool (`OraclePool`) or separate connections for concurrent work. As of 1.4 an **open fetched `OracleLob`** (from `fetchLobs: true`) also holds that slot — for the handle's whole lifetime, not just during a round trip, and including handles a streaming result set prefetched but you never asked for — so an unclosed LOB handle is the most likely cause of a concurrent-operation error; a **created-temporary** handle (`createTemporaryClob()` and friends) is deliberately exempt and can be read, written, and bound while open. See [Incremental LOB access with `fetchLobs`](#incremental-lob-access-with-fetchlobs).
- **Pre-12c authentication** — password-verifier paths used by pre-12c servers are untested; the validated matrix is Oracle 21c (classical auth) and 23ai (FAST_AUTH).
- **Region-id time zones** — `TIMESTAMP WITH TIME ZONE` values stored with a region id (e.g. `Europe/Madrid`) decode to the correct UTC instant; with `preserveTimestampTimeZone: true` they report a `+00:00` offset (UTC-normalized — the driver never computes the region's offset) and carry the server's region id, which `OracleConnection.timeZoneRegionName` resolves to the name (`'EUROPE/MADRID'`, as `TZR` renders it) from the connected database's `V$TIMEZONE_NAMES` (first lookup per connection runs one query; needs read access to that view, granted to `PUBLIC` by default). Binding one back stores `+00:00` without the region. Offset-based zones (e.g. `+02:00`) keep their offset. See [Region-id time zones](#region-id-time-zones).
- **`fetchAsString` text is client-side** — `OracleExecuteOptions(fetchAsString: ...)` renders DATE / TIMESTAMP / TIMESTAMP WITH (LOCAL) TIME ZONE values with the decoded Dart value's `toString()` (node-oracledb thin parity), not with Oracle's NLS formats; microsecond precision, no region names. Use `TO_CHAR(...)` in SQL for Oracle's exact text. The option covers only the top-level query's rows: REF CURSOR OUT bind, nested `CURSOR(...)` and implicit-result rows keep native types. Only `OracleDbType.date`, `timestamp` and `timestampTz` convert (`rowid` / `urowid` are accepted as no-ops — those columns are already strings); no NUMBER/CLOB/RAW/JSON/VECTOR as string. See [Fetching dates and timestamps as strings](#fetching-dates-and-timestamps-as-strings).
- **`fetchTypeHandler` is converter-only and client-side** — `OracleExecuteOptions(fetchTypeHandler: ...)` cannot request a different fetch type (no node-oracledb `type`, no DEFINE): each column is fetched natively and the converter maps the decoded value in the driver, synchronously. It covers only the top-level query's rows (not REF CURSOR OUT bind, nested `CURSOR(...)`, implicit-result or OUT bind values), is per call (no connection-level or global default), and `executeMany()` / `executeStream()` / `queryStream()` do not take it. See [Fetch type handlers](#fetch-type-handlers-per-column-converters).
- **Very large result sets** — a single `execute()` is bounded by a safety cap of 1,000 fetch round-trips (about 50,000 rows at the default fetch size); if the cap is hit, a warning is logged, the rows fetched so far are returned, and `result.moreRowsAvailable` is `true` so the truncation is detectable. The same flag is also set (with a logged warning) in the rarer case where the server reports more rows pending but the driver has no usable cursor id to continue fetching — in either case `true` means the rows are an incomplete prefix of the full result set. Streaming (`queryStream()` / `executeStream()`) and result-set (`OracleExecuteOptions(resultSet: true)`) consumption have **no such cap** — prefer them for very large result sets.

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
