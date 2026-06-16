/// Query result classes for Oracle database operations.
///
/// This file contains [OracleResult] and [OracleRow] classes for
/// handling SELECT query results and DML operation outcomes.
library;

import 'package:meta/meta.dart';

import 'oracle_bind.dart';
import 'protocol/messages/execute_message.dart';
import 'result_set.dart';

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
    bool moreRowsAvailable = false,
    OracleResultSet? resultSet,
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
      moreRowsAvailable: moreRowsAvailable,
      resultSet: resultSet,
    );
  }

  OracleResult._({
    required this._columnMetadata,
    required this._rows,
    required this.outBinds,
    this.rowsAffected,
    this.moreRowsAvailable = false,
    this.resultSet,
  });

  final List<ColumnMetadata> _columnMetadata;
  final List<OracleRow> _rows;

  /// Number of rows affected by DML operations.
  ///
  /// This is `null` for SELECT queries. It is also `null` — rather than `0` —
  /// when the statement ran against a **pre-12.2 Oracle server** that does not
  /// send the extended row-count field in its response: the absence of a count
  /// is reported distinctly from a confirmed count of zero. Servers from
  /// 12.2 onward (including all currently-tested 19c/21c/23ai targets) always
  /// return the count, so this nullable pre-12.2 case does not arise there.
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

  /// The cursor-backed [OracleResultSet] for incremental row consumption.
  ///
  /// Non-null only when [OracleConnection.execute] was called with
  /// `OracleExecuteOptions(resultSet: true)`. In that case [rows] is empty and
  /// all row data is accessed through this result set. Always `null` on the
  /// default eager path.
  final OracleResultSet? resultSet;

  /// Whether the driver stopped fetching while the server still had rows
  /// pending.
  ///
  /// `true` when the driver could not fully drain the result set, for either
  /// of two reasons:
  ///
  /// - the fetch-iteration safety cap (1,000 FETCH round trips per execute —
  ///   see Known Limitations in the README) stopped the drain early, or
  /// - the server reported more rows pending on a cursor the driver could not
  ///   continue fetching (no usable cursor id was available for FETCH calls).
  ///
  /// In both cases [rows] is a truncated prefix of the full result set. Fully
  /// drained result sets — including empty ones — always report `false`.
  /// Callers reading very large result sets should check this flag and narrow
  /// the query (or paginate) when it is set.
  final bool moreRowsAvailable;

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
    required this._data,
    required this._columnMetadata,
    required this._nameToIndex,
  });

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

/// Package-internal helper that builds [OracleRow] instances from raw decoded
/// value lists.
///
/// `OracleResultSet` streams rows out of the cursor engine one batch at a time
/// and needs to wrap each raw value list in an [OracleRow] without re-deriving
/// the case-insensitive column-name map per row (and without duplicating the
/// private row/name-map plumbing that [OracleResult] owns). The builder
/// computes the name map once from the column metadata and reuses it for every
/// row, exactly as the eager [OracleResult] factory does. Not exported.
@internal
class OracleRowBuilder {
  /// Creates a builder for rows shaped by [columnMetadata], precomputing the
  /// shared case-insensitive name → index map once.
  OracleRowBuilder(List<ColumnMetadata> columnMetadata)
      : _columnMetadata = columnMetadata,
        _nameToIndex = OracleResult._buildNameMap(columnMetadata);

  final List<ColumnMetadata> _columnMetadata;
  final Map<String, int> _nameToIndex;

  /// Wraps a single raw decoded value list in an [OracleRow], sharing the
  /// precomputed column metadata and name map.
  OracleRow build(List<dynamic> data) => OracleRow._(
        data: data,
        columnMetadata: _columnMetadata,
        nameToIndex: _nameToIndex,
      );
}
