/// Pure Dart Oracle Database driver implementing thin-mode TNS/TTC wire protocol.
///
/// This library provides a complete Oracle Database client without requiring
/// Oracle Client libraries, similar to python-oracledb and node-oracledb thin mode.
///
/// ## Usage
///
/// ```dart
/// import 'package:oracledb/oracledb.dart';
///
/// void main() async {
///   final connection = await OracleConnection.connect(
///     host: 'localhost',
///     port: 1521,
///     serviceName: 'FREEPDB1',
///     user: 'testuser',
///     password: 'testpassword',
///   );
///
///   final result = await connection.execute('SELECT * FROM dual');
///   for (final row in result.rows) {
///     print(row);
///   }
///
///   await connection.close();
/// }
/// ```
library;

// Public API exports
export 'src/connection.dart' show OracleConnection, ConnectionParams;
export 'src/pool.dart' show ConnectionPool, PoolConfig;
export 'src/cursor.dart' show Cursor, ResultSet, ColumnMetadata;
export 'src/lob.dart' show Lob, Clob, Blob, NClob;
export 'src/db_object.dart' show DbObject, DbObjectType;
export 'src/types.dart'
    show
        OracleNumber,
        OracleDate,
        OracleTimestamp,
        OracleTimestampTZ,
        OracleInterval,
        OracleRowId;
export 'src/errors.dart'
    show
        OracleException,
        OracleError,
        ConnectionError,
        ProtocolError,
        AuthenticationError,
        DataTypeError;
export 'src/constants.dart' show OracleType, FetchMode, BindDirection;
