/// Query result classes for Oracle database operations.
///
/// This file contains [OracleResult] and [OracleRow] classes for
/// handling SELECT query results and DML operation outcomes.
library;

import 'oracle_bind.dart';
import 'protocol/messages/execute_message.dart';

/// The result of executing a SQL query.
///
/// For SELECT queries, access rows via the [rows] property:
/// ```dart
/// final result = await connection.execute('SELECT * FROM employees');
/// for (final row in result.rows) {
///   print('${row['NAME']}: ${row['SALARY']}');
/// }
/// ```
///
/// For DML queries (INSERT, UPDATE, DELETE), check [rowsAffected]:
/// ```dart
/// final result = await connection.execute(
///   "UPDATE employees SET salary = 50000 WHERE id = 1"
/// );
/// print('Updated ${result.rowsAffected} rows');
/// ```
///
/// ## Oracle NULL conventions
///
/// Oracle treats an empty string (`''`) as `NULL` for `VARCHAR2` columns.
/// Inserting `''` (whether as a SQL literal or as a bound parameter) and
/// selecting it back yields `null`, not a zero-length `String`. Code that
/// needs to round-trip an empty string must use a non-VARCHAR2 column type
/// or a sentinel value.
class OracleResult {
  /// Creates a result from the given column metadata and row data.
  factory OracleResult({
    required List<ColumnMetadata> columnMetadata,
    required List<List<dynamic>> rowData,
    int? rowsAffected,
    OracleOutBinds? outBinds,
  }) {
    final nameToIndex = _buildNameMap(columnMetadata);
    final rows = rowData
        .map((data) => OracleRow._(
              data: data,
              columnMetadata: columnMetadata,
              nameToIndex: nameToIndex,
            ))
        .toList();
    return OracleResult._(
      columnMetadata: columnMetadata,
      rows: rows,
      rowsAffected: rowsAffected,
      outBinds: outBinds ?? const OracleOutBinds.empty(),
    );
  }

  const OracleResult._({
    required List<ColumnMetadata> columnMetadata,
    required List<OracleRow> rows,
    required this.outBinds,
    this.rowsAffected,
  })  : _columnMetadata = columnMetadata,
        _rows = rows;

  final List<ColumnMetadata> _columnMetadata;
  final List<OracleRow> _rows;

  /// Number of rows affected by DML operations.
  ///
  /// This is `null` for SELECT queries.
  final int? rowsAffected;

  /// Decoded OUT bind values from PL/SQL execution. Empty for non-PL/SQL
  /// statements and for PL/SQL blocks that declare no OUT binds.
  ///
  /// Access values by bind name (case-insensitive) for named binds, or by
  /// zero-based index for positional binds:
  ///
  /// ```dart
  /// result.outBinds['ret'];   // named
  /// result.outBinds[0];       // positional
  /// ```
  final OracleOutBinds outBinds;

  /// The rows returned by a SELECT query.
  ///
  /// Each row can be accessed by column name or index.
  /// Returns an unmodifiable view of the rows list.
  List<OracleRow> get rows => List.unmodifiable(_rows);

  /// Number of rows in the result set.
  int get rowCount => _rows.length;

  /// Column metadata for the result set.
  ///
  /// Contains information about each column including name,
  /// Oracle data type, and size constraints.
  /// Returns an unmodifiable view of the columns list.
  List<ColumnMetadata> get columns => List.unmodifiable(_columnMetadata);

  /// Column names in result order.
  List<String> get columnNames => _columnMetadata.map((c) => c.name).toList();

  static Map<String, int> _buildNameMap(List<ColumnMetadata> columns) {
    final map = <String, int>{};
    for (var i = 0; i < columns.length; i++) {
      // Oracle column names are case-insensitive, stored uppercase
      map[columns[i].name.toUpperCase()] = i;
    }
    return map;
  }
}

/// A single row from a query result.
///
/// Access column values by name (case-insensitive) or by zero-based index:
/// ```dart
/// final name = row['NAME'];      // By column name
/// final name = row['name'];      // Case-insensitive
/// final name = row[0];           // By column index
/// ```
///
/// Returns `null` if the column doesn't exist, the index is out of bounds,
/// or the value is NULL in the database.
class OracleRow {
  const OracleRow._({
    required List<dynamic> data,
    required List<ColumnMetadata> columnMetadata,
    required Map<String, int> nameToIndex,
  })  : _data = data,
        _columnMetadata = columnMetadata,
        _nameToIndex = nameToIndex;

  final List<dynamic> _data;
  final List<ColumnMetadata> _columnMetadata;
  final Map<String, int> _nameToIndex;

  /// Gets a column value by name (case-insensitive) or index.
  ///
  /// Returns `null` if:
  /// - The column name doesn't exist
  /// - The index is out of bounds
  /// - The database value is NULL
  dynamic operator [](Object key) {
    if (key is int) {
      if (key < 0 || key >= _data.length) return null;
      return _data[key];
    }
    if (key is String) {
      final index = _nameToIndex[key.toUpperCase()];
      if (index == null) return null;
      return _data[index];
    }
    return null;
  }

  /// Number of columns in this row.
  int get length => _data.length;

  /// Column names in result order.
  List<String> get columnNames => _columnMetadata.map((c) => c.name).toList();

  /// Returns all values as an unmodifiable list.
  ///
  /// The values are in column order.
  List<dynamic> toList() => List.unmodifiable(_data);

  /// Returns all values as a map from column name to value.
  ///
  /// Column names are in their original case (typically uppercase).
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{};
    for (var i = 0; i < _columnMetadata.length; i++) {
      map[_columnMetadata[i].name] = _data[i];
    }
    return map;
  }
}
