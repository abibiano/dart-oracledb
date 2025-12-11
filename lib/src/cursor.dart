/// Cursor and ResultSet classes for query execution.
library;

import 'dart:async';

import 'constants.dart';
import 'errors.dart';

/// Metadata for a result column.
class ColumnMetadata {
  const ColumnMetadata({
    required this.name,
    required this.type,
    required this.precision,
    required this.scale,
    required this.size,
    required this.nullable,
  });

  /// Column name
  final String name;

  /// Oracle data type
  final OracleType type;

  /// Numeric precision (for NUMBER types)
  final int precision;

  /// Numeric scale (for NUMBER types)
  final int scale;

  /// Maximum size in bytes
  final int size;

  /// Whether the column allows NULL values
  final bool nullable;

  @override
  String toString() =>
      'ColumnMetadata($name, $type, precision: $precision, scale: $scale, '
      'size: $size, nullable: $nullable)';
}

/// Result set from a query execution.
///
/// Contains rows, column metadata, and execution statistics.
class ResultSet {
  const ResultSet({
    required this.columns,
    required this.rows,
    required this.rowsAffected,
    required this.lastRowId,
  });

  /// Empty result set
  static const ResultSet empty = ResultSet(
    columns: [],
    rows: [],
    rowsAffected: 0,
    lastRowId: null,
  );

  /// Column metadata
  final List<ColumnMetadata> columns;

  /// Result rows (each row is `List<dynamic>` or `Map<String, dynamic>`)
  final List<List<dynamic>> rows;

  /// Number of rows affected (for DML statements)
  final int rowsAffected;

  /// ROWID of the last inserted row (for INSERT ... RETURNING)
  final String? lastRowId;

  /// Number of columns
  int get columnCount => columns.length;

  /// Number of rows
  int get rowCount => rows.length;

  /// Whether the result set is empty
  bool get isEmpty => rows.isEmpty;

  /// Whether the result set has rows
  bool get isNotEmpty => rows.isNotEmpty;

  /// Get column index by name
  int? columnIndex(String name) {
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].name.toUpperCase() == name.toUpperCase()) {
        return i;
      }
    }
    return null;
  }

  /// Get rows as maps (column name -> value)
  List<Map<String, dynamic>> toMaps() {
    return rows.map((row) {
      final map = <String, dynamic>{};
      for (var i = 0; i < columns.length; i++) {
        map[columns[i].name] = row[i];
      }
      return map;
    }).toList();
  }

  /// Get a single column as a list
  List<T> column<T>(int index) {
    if (index < 0 || index >= columnCount) {
      throw RangeError.index(index, columns, 'index');
    }
    return rows.map((row) => row[index] as T).toList();
  }

  /// Get a single column by name as a list
  List<T> columnByName<T>(String name) {
    final idx = columnIndex(name);
    if (idx == null) {
      throw ArgumentError.value(name, 'name', 'Column not found');
    }
    return column<T>(idx);
  }

  @override
  String toString() =>
      'ResultSet(columns: $columnCount, rows: $rowCount, affected: $rowsAffected)';
}

/// Database cursor for statement execution.
///
/// Cursors provide fine-grained control over statement execution
/// and result fetching.
class Cursor {
  Cursor({
    required this.sql,
    this.fetchSize = 100,
    this.prefetchRows = 2,
  });

  /// SQL statement
  final String sql;

  /// Number of rows to fetch per round-trip
  final int fetchSize;

  /// Number of rows to prefetch
  final int prefetchRows;

  /// Cursor ID assigned by the server (used by Protocol layer)
  // ignore: unused_field
  int? _cursorId;

  /// Whether the cursor is open
  bool _isOpen = false;

  /// Column metadata (populated after execute)
  List<ColumnMetadata>? _columns;

  /// Buffered rows
  final List<List<dynamic>> _buffer = [];

  /// Whether all rows have been fetched
  bool _exhausted = false;

  /// Number of rows affected by DML
  int _rowsAffected = 0;

  /// Whether the cursor is open
  bool get isOpen => _isOpen;

  /// Column metadata
  List<ColumnMetadata>? get columns => _columns;

  /// Number of rows affected
  int get rowsAffected => _rowsAffected;

  /// Whether more rows are available
  bool get hasMoreRows => !_exhausted || _buffer.isNotEmpty;

  /// Execute the statement with optional parameters.
  ///
  /// This is called internally by the protocol layer.
  Future<void> execute({Object? params}) async {
    if (_isOpen) {
      throw StatementError.cursorNotOpen();
    }
    // Implementation delegated to Protocol
    _isOpen = true;
  }

  /// Fetch the next batch of rows.
  Future<List<List<dynamic>>> fetchMany([int? rows]) async {
    if (!_isOpen) {
      throw StatementError.cursorNotOpen();
    }

    final count = rows ?? fetchSize;
    final result = <List<dynamic>>[];

    while (result.length < count) {
      if (_buffer.isEmpty && !_exhausted) {
        // Fetch more rows from server
        await _fetchFromServer();
      }

      if (_buffer.isEmpty) {
        break;
      }

      result.add(_buffer.removeAt(0));
    }

    return result;
  }

  /// Fetch a single row.
  Future<List<dynamic>?> fetchOne() async {
    final rows = await fetchMany(1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Fetch all remaining rows.
  Future<List<List<dynamic>>> fetchAll() async {
    final result = <List<dynamic>>[];
    while (hasMoreRows) {
      final batch = await fetchMany();
      result.addAll(batch);
    }
    return result;
  }

  /// Iterate over rows as a stream.
  Stream<List<dynamic>> stream() async* {
    while (hasMoreRows) {
      final row = await fetchOne();
      if (row != null) {
        yield row;
      }
    }
  }

  /// Fetch rows from server (internal).
  Future<void> _fetchFromServer() async {
    // Implementation in Protocol layer
    _exhausted = true;
  }

  /// Close the cursor.
  Future<void> close() async {
    if (!_isOpen) return;

    // Send close cursor to server
    _isOpen = false;
    _buffer.clear();
    _cursorId = null;
  }

  /// Set columns metadata (called by Protocol).
  void setColumns(List<ColumnMetadata> columns) {
    _columns = columns;
  }

  /// Add rows to buffer (called by Protocol).
  void addRows(List<List<dynamic>> rows, {bool isLast = false}) {
    _buffer.addAll(rows);
    if (isLast) {
      _exhausted = true;
    }
  }

  /// Set cursor ID (called by Protocol).
  void setCursorId(int id) {
    _cursorId = id;
  }

  /// Set rows affected (called by Protocol).
  void setRowsAffected(int count) {
    _rowsAffected = count;
  }
}

/// REF CURSOR for PL/SQL result sets.
///
/// Represents a cursor returned from a PL/SQL procedure or function.
class RefCursor extends Cursor {
  RefCursor() : super(sql: '');

  /// Bind the REF CURSOR to a cursor variable.
  void bind(int cursorId, List<ColumnMetadata> columns) {
    setCursorId(cursorId);
    setColumns(columns);
    _isOpen = true;
  }
}
