# oracledb

A pure Dart Oracle Database driver implementing thin-mode TNS/TTC wire protocol. No Oracle Client libraries required.

[![Pub Version](https://img.shields.io/pub/v/oracledb)](https://pub.dev/packages/oracledb)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

## Features

- **Pure Dart** - No native dependencies or Oracle Client installation required
- **Thin mode protocol** - Direct TNS/TTC wire protocol implementation
- **Connection pooling** - Built-in connection pool with health checks
- **Full type support** - NUMBER, DATE, TIMESTAMP, VARCHAR2, CLOB, BLOB, JSON, and more
- **Transactions** - Commit, rollback, and savepoint support
- **PL/SQL** - Execute procedures, functions, and anonymous blocks
- **Batch operations** - Efficient bulk inserts with `executeMany`
- **Async/await** - Modern Dart async API

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  oracledb: ^0.1.0
```

Then run:

```bash
dart pub get
```

## Quick Start

```dart
import 'package:oracledb/oracledb.dart';

void main() async {
  // Connect to database
  final connection = await OracleConnection.connect(
    host: 'localhost',
    port: 1521,
    serviceName: 'FREEPDB1',
    user: 'testuser',
    password: 'testpassword',
  );

  try {
    // Execute query
    final result = await connection.execute(
      'SELECT employee_id, first_name FROM employees WHERE department_id = :dept',
      params: {'dept': 10},
    );

    for (final row in result.rows) {
      print('${row[0]}: ${row[1]}');
    }
  } finally {
    await connection.close();
  }
}
```

## Usage

### Connection Parameters

```dart
final connection = await OracleConnection.connect(
  host: 'dbhost.example.com',
  port: 1521,                          // Default Oracle port
  serviceName: 'ORCL',                 // Or use sid: 'ORCL'
  user: 'username',
  password: 'password',
  connectTimeout: Duration(seconds: 30),
  useTls: true,                        // Enable TLS
  walletPath: '/path/to/wallet',       // For TLS certificates
);
```

### Parameterized Queries

```dart
// Positional parameters
final result = await connection.execute(
  'SELECT * FROM employees WHERE salary > :1 AND department_id = :2',
  params: [50000, 10],
);

// Named parameters
final result = await connection.execute(
  'SELECT * FROM employees WHERE salary > :min_salary AND department_id = :dept',
  params: {'min_salary': 50000, 'dept': 10},
);
```

### Insert, Update, Delete

```dart
final rowsAffected = await connection.executeUpdate(
  'UPDATE employees SET salary = salary * 1.1 WHERE department_id = :dept',
  params: {'dept': 10},
);
print('Updated $rowsAffected rows');
```

### Transactions

```dart
await connection.begin();
try {
  await connection.executeUpdate(
    'INSERT INTO orders (id, customer_id) VALUES (:id, :cust)',
    params: {'id': 1001, 'cust': 42},
  );
  await connection.executeUpdate(
    'UPDATE inventory SET quantity = quantity - 1 WHERE product_id = :pid',
    params: {'pid': 100},
  );
  await connection.commit();
} catch (e) {
  await connection.rollback();
  rethrow;
}
```

### Batch Insert

```dart
final params = [
  {'id': 1, 'name': 'Alice'},
  {'id': 2, 'name': 'Bob'},
  {'id': 3, 'name': 'Charlie'},
];

final rowsInserted = await connection.executeMany(
  'INSERT INTO users (id, name) VALUES (:id, :name)',
  params,
);
```

### PL/SQL Execution

```dart
// Call procedure
await connection.callProcedure('process_order', params: {'order_id': 1001});

// Call function
final result = await connection.callFunction<int>(
  'get_employee_count',
  returnType: OracleType.number,
  params: {'dept_id': 10},
);

// Anonymous block with OUT parameters
final output = await connection.executePlSql('''
  DECLARE
    v_count NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v_count FROM employees;
    :result := v_count;
  END;
''', params: {
  'result': (type: OracleType.number, direction: BindDirection.output, value: null),
});
print('Count: ${output['result']}');
```

### Connection Pool

```dart
final pool = await ConnectionPool.create(
  host: 'localhost',
  port: 1521,
  serviceName: 'FREEPDB1',
  user: 'testuser',
  password: 'testpassword',
  config: (
    minConnections: 2,
    maxConnections: 10,
    acquireTimeout: Duration(seconds: 30),
    idleTimeout: Duration(minutes: 5),
    maxLifetime: Duration(hours: 1),
    validateOnBorrow: true,
  ),
);

// Use with automatic release
await pool.withConnection((conn) async {
  final result = await conn.execute('SELECT SYSDATE FROM dual');
  print(result.rows.first[0]);
});

// Or manual acquire/release
final conn = await pool.acquire();
try {
  // Use connection...
} finally {
  await pool.release(conn);
}

await pool.close();
```

## Supported Data Types

| Oracle Type | Dart Type |
|-------------|-----------|
| VARCHAR2, CHAR, NVARCHAR2 | `String` |
| NUMBER | `OracleNumber`, `int`, `double` |
| DATE | `OracleDate`, `DateTime` |
| TIMESTAMP | `OracleTimestamp` |
| TIMESTAMP WITH TIME ZONE | `OracleTimestampTZ` |
| CLOB, NCLOB | `Clob`, `NClob` |
| BLOB | `Blob` |
| RAW | `Uint8List` |
| JSON | `Map<String, dynamic>` |
| BOOLEAN (23ai) | `bool` |

## Thin Mode Limitations

This driver implements Oracle's thin mode protocol. The following features require thick mode (Oracle Client) and are **not supported**:

- SODA (Simple Oracle Document Access)
- Continuous Query Notification (CQN)
- External/Kerberos authentication
- Native Network Encryption (NNE)
- Application Continuity
- Client Result Cache

## Requirements

- Dart SDK >= 3.0.0
- Oracle Database 11g or later

## Development

### Reference Implementations

This project includes Oracle's official thin mode implementations as git submodules for reference:

```bash
git submodule update --init --recursive
```

- `reference/python-oracledb/` - Python implementation (`src/oracledb/impl/thin/`)
- `reference/node-oracledb/` - Node.js implementation (`lib/thin/`)

### Running Tests

```bash
dart pub get
dart test
```

### Integration Tests

Integration tests require an Oracle Database instance. You can use Oracle Free:

```bash
docker run -d -p 1521:1521 -e ORACLE_PASSWORD=testpassword gvenzl/oracle-free:slim-faststart
```

## Contributing

Contributions are welcome! Please read our contributing guidelines before submitting PRs.

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests and linting
5. Submit a pull request

## License

Apache License 2.0 - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [python-oracledb](https://github.com/oracle/python-oracledb) - Oracle's Python driver
- [node-oracledb](https://github.com/oracle/node-oracledb) - Oracle's Node.js driver
- Ian Redfern's TNS/TTC protocol documentation
