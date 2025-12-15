/// TTC Execute message for SQL statement execution.
///
/// Sends SQL statements to Oracle for execution and parses responses.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../errors.dart';
import '../buffer.dart';
import '../constants.dart';
import 'base.dart';

/// TTC EXECUTE request message (function code 0x03).
///
/// Sends a SQL statement to the database for execution with optional
/// bind parameters.
///
/// **Sequence Numbers:** Unlike auth messages, execute messages typically
/// don't require explicit sequence management for simple queries. The
/// sequence parameter is inherited from Message base class but can be
/// omitted for single-statement executes. Multi-phase operations (cursor
/// fetch loops) may need sequence tracking in Story 2.2.
class ExecuteRequest extends Message {
  /// Creates an EXECUTE request for the given SQL statement.
  ///
  /// For queries with bind parameters, provide [bindValues] as a List
  /// containing the values in order. For named binds, also provide
  /// [bindNames] with the parameter names in SQL order.
  ExecuteRequest({
    required this.sql,
    this.bindValues,
    this.bindNames,
    this.cursorId = 0,
    this.options = 0,
    super.sequence,
  }) : super(messageType: ttcExecute);

  /// The SQL statement to execute.
  final String sql;

  /// Bind values - List of values for positional or named binds.
  final List<dynamic>? bindValues;

  /// Bind names for named parameters (in SQL order).
  final List<String>? bindNames;

  /// Cursor ID (0 for new cursor).
  final int cursorId;

  /// Execution options flags.
  final int options;

  @override
  void encode(WriteBuffer buffer) {
    // Function code
    buffer.writeUint8(messageType);

    // Cursor ID (4 bytes, big-endian)
    buffer.writeUint32BE(cursorId);

    // Execution options (1 byte)
    buffer.writeUint8(options);

    // SQL statement (length-prefixed UTF-8)
    final sqlBytes = utf8.encode(sql);
    buffer.writeUint32BE(sqlBytes.length);
    buffer.writeBytes(Uint8List.fromList(sqlBytes));

    // Bind parameter count (2 bytes, big-endian)
    final bindCount = bindValues?.length ?? 0;
    buffer.writeUint16BE(bindCount);

    // Encode each bind value
    if (bindValues != null) {
      for (final value in bindValues!) {
        _encodeBindValue(buffer, value);
      }
    }
  }

  /// Encodes a single bind value to the buffer.
  void _encodeBindValue(WriteBuffer buffer, dynamic value) {
    if (value == null) {
      // NULL indicator
      buffer.writeUint8(0xFF);
      return;
    }

    // Non-null indicator
    buffer.writeUint8(0x00);

    if (value is String) {
      buffer.writeUint8(oraTypeVarchar2);
      final bytes = utf8.encode(value);
      buffer.writeUint16BE(bytes.length);
      buffer.writeBytes(Uint8List.fromList(bytes));
    } else if (value is int) {
      buffer.writeUint8(oraTypeNumber);
      _encodeOracleNumber(buffer, value);
    } else if (value is double) {
      buffer.writeUint8(oraTypeNumber);
      _encodeOracleNumber(buffer, value);
    } else if (value is DateTime) {
      buffer.writeUint8(oraTypeDate);
      _encodeOracleDate(buffer, value);
    } else if (value is Uint8List) {
      buffer.writeUint8(oraTypeRaw);
      buffer.writeUint16BE(value.length);
      buffer.writeBytes(value);
    } else {
      throw OracleException(
        errorCode: oraBindTypeError,
        message: 'Unsupported bind value type: ${value.runtimeType}. '
            'Supported types: String, int, double, DateTime, Uint8List, null',
      );
    }
  }

  /// Encodes a number value in Oracle NUMBER format.
  void _encodeOracleNumber(WriteBuffer buffer, num value) {
    if (value == 0) {
      buffer.writeUint8(1); // Length
      buffer.writeUint8(0x80); // Zero exponent
      return;
    }

    // For positive integers, use base-100 encoding
    if (value is int && value > 0) {
      final digits = <int>[];
      var remaining = value;
      while (remaining > 0) {
        digits.insert(0, (remaining % 100) + 1);
        remaining ~/= 100;
      }

      final exponent = 0xC0 + digits.length;
      buffer.writeUint8(digits.length + 1); // Length
      buffer.writeUint8(exponent);
      for (final digit in digits) {
        buffer.writeUint8(digit);
      }
      return;
    }

    // For negative integers and decimals - basic support
    // Full implementation in Story 2.6
    throw const OracleException(
      errorCode: oraDataTypeNotSupported,
      message: 'Complex NUMBER encoding (negative/decimal) not yet supported. '
          'See Story 2.6 for full data type mapping.',
    );
  }

  /// Encodes a DateTime value in Oracle DATE format.
  void _encodeOracleDate(WriteBuffer buffer, DateTime value) {
    // Oracle DATE: 7 bytes
    // Byte 0-1: Century and year (offset by 100)
    // Byte 2: Month
    // Byte 3: Day
    // Byte 4: Hour + 1
    // Byte 5: Minute + 1
    // Byte 6: Second + 1
    buffer.writeUint8(7); // Length
    buffer.writeUint8((value.year ~/ 100) + 100);
    buffer.writeUint8((value.year % 100) + 100);
    buffer.writeUint8(value.month);
    buffer.writeUint8(value.day);
    buffer.writeUint8(value.hour + 1);
    buffer.writeUint8(value.minute + 1);
    buffer.writeUint8(value.second + 1);
  }
}

/// TTC EXECUTE response from server.
///
/// Contains the result of executing a SQL statement, including column
/// metadata and row data for SELECT queries, or error information if
/// the query failed.
class ExecuteResponse {
  /// Creates an execute response with the given fields.
  const ExecuteResponse({
    required this.isSuccess,
    this.cursorId,
    this.columnMetadata,
    this.rows,
    this.rowsAffected,
    this.errorCode,
    this.errorMessage,
  });

  /// Whether the query executed successfully.
  final bool isSuccess;

  /// The cursor ID assigned by the server.
  final int? cursorId;

  /// Column metadata for SELECT query results.
  final List<ColumnMetadata>? columnMetadata;

  /// Row data for SELECT query results.
  final List<List<dynamic>>? rows;

  /// Number of rows affected by DML operations.
  final int? rowsAffected;

  /// Oracle error code if the query failed.
  final int? errorCode;

  /// Oracle error message if the query failed.
  final String? errorMessage;

  /// Decodes an execute response from raw bytes.
  ///
  /// Throws [OracleException] if decoding fails.
  static ExecuteResponse decode(Uint8List data) {
    try {
      final buffer = ReadBuffer(data);

      // Status byte (0 = success)
      final status = buffer.readUint8();

      if (status != 0) {
        // Error response
        final errorCode = buffer.readUint16BE();
        final msgLen = buffer.readUint8();
        final errorMessage = msgLen > 0 ? buffer.readString(msgLen) : null;

        return ExecuteResponse(
          isSuccess: false,
          errorCode: errorCode,
          errorMessage: errorMessage,
        );
      }

      // Success - parse result metadata
      final cursorId = buffer.readUint32BE();
      final columnCount = buffer.readUint16BE();

      // Parse column metadata
      final columns = <ColumnMetadata>[];
      for (var i = 0; i < columnCount; i++) {
        columns.add(ColumnMetadata.decode(buffer));
      }

      // Parse rows if present
      final rowCount = buffer.readUint32BE();
      final rows = <List<dynamic>>[];
      for (var i = 0; i < rowCount; i++) {
        rows.add(_decodeRow(buffer, columns));
      }

      return ExecuteResponse(
        isSuccess: true,
        cursorId: cursorId,
        columnMetadata: columns,
        rows: rows,
      );
    } catch (e) {
      if (e is OracleException) rethrow;
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'Failed to decode execute response',
        cause: e,
      );
    }
  }

  static List<dynamic> _decodeRow(
    ReadBuffer buffer,
    List<ColumnMetadata> columns,
  ) {
    final values = <dynamic>[];
    for (final col in columns) {
      values.add(_decodeValue(buffer, col.oracleType));
    }
    return values;
  }

  static dynamic _decodeValue(ReadBuffer buffer, int oracleType) {
    // Check for NULL indicator
    final isNull = buffer.readUint8();
    if (isNull == 0xFF) return null;

    // Decode based on type (basic types for Story 2.1)
    switch (oracleType) {
      case oraTypeVarchar:
      case oraTypeVarchar2:
      case oraTypeString:
        final len = buffer.readUint16BE();
        return buffer.readString(len);

      case oraTypeNumber:
      case oraTypeInteger:
        // Oracle NUMBER encoding - simplified for MVP
        return _decodeNumber(buffer);

      default:
        // Skip unknown types
        final len = buffer.readUint16BE();
        buffer.skip(len);
        return null;
    }
  }

  static num _decodeNumber(ReadBuffer buffer) {
    // Oracle NUMBER is variable-length
    final len = buffer.readUint8();
    if (len == 0) return 0;

    final numBytes = buffer.readBytes(len);
    // Simplified NUMBER decoding - full implementation in Story 2.6
    // For now, handle simple integer cases
    return _parseOracleNumber(numBytes);
  }

  static num _parseOracleNumber(Uint8List bytes) {
    // Oracle NUMBER format: [length] [exponent] [mantissa bytes...]
    // Full decimal support deferred to Story 2.6
    if (bytes.isEmpty) return 0;

    // Basic integer parsing for Story 2.1 MVP
    // Oracle NUMBER uses base-100 encoding with offset exponent
    final exponent = bytes[0];
    if (exponent == 0x80) return 0; // Special case: zero

    // Positive integers: exponent >= 0xC1
    if (exponent >= 0xC1 && bytes.length >= 2) {
      final digits = exponent - 0xC1 + 1;
      int result = 0;
      for (var i = 1; i < bytes.length && i <= digits; i++) {
        result = result * 100 + (bytes[i] - 1);
      }
      return result;
    }

    // Negative or decimal numbers - defer to Story 2.6
    throw const OracleException(
      errorCode: oraDataTypeNotSupported,
      message: 'Complex Oracle NUMBER format not yet supported. '
          'See Story 2.6 for full data type mapping.',
    );
  }
}

/// Column metadata from query result.
///
/// Contains information about a column in a query result set,
/// including its name, Oracle data type, and size constraints.
class ColumnMetadata {
  /// Creates column metadata with the given properties.
  const ColumnMetadata({
    required this.name,
    required this.oracleType,
    required this.maxLength,
    this.precision,
    this.scale,
  });

  /// The column name.
  final String name;

  /// The Oracle data type code.
  final int oracleType;

  /// Maximum length in bytes.
  final int maxLength;

  /// Numeric precision (for NUMBER types).
  final int? precision;

  /// Numeric scale (for NUMBER types).
  final int? scale;

  /// Decodes column metadata from a buffer.
  static ColumnMetadata decode(ReadBuffer buffer) {
    final nameLen = buffer.readUint8();
    final name = buffer.readString(nameLen);
    final oracleType = buffer.readUint16BE();
    final maxLength = buffer.readUint16BE();
    final precision = buffer.readUint8();
    final scale = buffer.readUint8();

    return ColumnMetadata(
      name: name,
      oracleType: oracleType,
      maxLength: maxLength,
      precision: precision > 0 ? precision : null,
      scale: scale > 0 ? scale : null,
    );
  }
}
