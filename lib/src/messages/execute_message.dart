/// SQL execution messages.
library;

import 'dart:typed_data';

import '../constants.dart';
import '../protocol/ttc_buffer.dart';
import 'message.dart';

/// SQL execution request using OALL8 bundled call
class ExecuteRequest extends Message {
  const ExecuteRequest({
    required this.sql,
    this.cursorId = 0,
    this.options = 0,
    this.bindParams,
    this.fetchSize = 100,
    this.prefetchRows = 2,
  });

  @override
  TtcMessageType get type => TtcMessageType.function;

  /// SQL statement
  final String sql;

  /// Cursor ID (0 for new cursor)
  final int cursorId;

  /// OALL8 options bitmap
  final int options;

  /// Bind parameters
  final List<BindParam>? bindParams;

  /// Number of rows to fetch
  final int fetchSize;

  /// Number of rows to prefetch
  final int prefetchRows;

  @override
  void encodeBody(TtcBuffer buffer) {
    buffer.writeUint8(OpiFunction.bundledCall.value);

    // Cursor ID
    buffer.writeUint32(cursorId);

    // Options
    buffer.writeUint32(options);

    // SQL text (if PARSE option set)
    if (options & OAll8Options.parse != 0) {
      buffer.writeClrString(sql);
    }

    // Bind count and parameters (if BIND option set)
    if (options & OAll8Options.bind != 0) {
      final params = bindParams ?? [];
      buffer.writeUint16(params.length);

      for (final param in params) {
        // Parameter name (empty for positional)
        buffer.writeClrString(param.name ?? '');
        // Parameter direction
        buffer.writeUint8(param.direction.index);
        // Parameter type
        buffer.writeUint8(param.type.value);
        // Parameter value
        buffer.writeClr(param.value);
      }
    }

    // Define columns (if DEFINE option set)
    if (options & OAll8Options.define != 0) {
      // Number of columns to define - determined by server
      buffer.writeUint16(0);
    }

    // Execute count (if EXECUTE option set)
    if (options & OAll8Options.execute != 0) {
      buffer.writeUint32(1); // Execute once
    }

    // Fetch size (if FETCH option set)
    if (options & OAll8Options.fetch != 0) {
      buffer.writeUint32(fetchSize);
      buffer.writeUint32(prefetchRows);
    }
  }

  /// Create a SELECT request
  factory ExecuteRequest.select(
    String sql, {
    List<BindParam>? params,
    int fetchSize = 100,
  }) {
    return ExecuteRequest(
      sql: sql,
      options: OAll8Options.parse |
          OAll8Options.bind |
          OAll8Options.execute |
          OAll8Options.fetch,
      bindParams: params,
      fetchSize: fetchSize,
    );
  }

  /// Create a DML request (INSERT/UPDATE/DELETE)
  factory ExecuteRequest.dml(
    String sql, {
    List<BindParam>? params,
    bool autoCommit = false,
  }) {
    var options = OAll8Options.parse | OAll8Options.bind | OAll8Options.execute;
    if (autoCommit) {
      options |= OAll8Options.commit;
    }
    return ExecuteRequest(
      sql: sql,
      options: options,
      bindParams: params,
    );
  }

  /// Create a PL/SQL execution request
  factory ExecuteRequest.plsql(
    String plsql, {
    List<BindParam>? params,
  }) {
    return ExecuteRequest(
      sql: plsql,
      options: OAll8Options.parse | OAll8Options.bind | OAll8Options.execute,
      bindParams: params,
    );
  }
}

/// Bind parameter for SQL execution
class BindParam {
  const BindParam({
    this.name,
    required this.type,
    this.value,
    this.direction = BindDirection.input,
    this.maxSize,
  });

  /// Parameter name (null for positional)
  final String? name;

  /// Oracle data type
  final OracleType type;

  /// Parameter value (encoded as bytes)
  final Uint8List? value;

  /// Parameter direction (IN/OUT/IN OUT)
  final BindDirection direction;

  /// Maximum size for OUT parameters
  final int? maxSize;

  /// Create from dynamic value
  factory BindParam.from(
    dynamic value, {
    String? name,
    BindDirection direction = BindDirection.input,
  }) {
    OracleType type;
    Uint8List? bytes;

    if (value == null) {
      type = OracleType.varchar2;
      bytes = null;
    } else if (value is String) {
      type = OracleType.varchar2;
      bytes = Uint8List.fromList(value.codeUnits);
    } else if (value is int) {
      type = OracleType.number;
      // Encode as Oracle NUMBER format
      bytes = _encodeInt(value);
    } else if (value is double) {
      type = OracleType.binaryDouble;
      bytes = _encodeDouble(value);
    } else if (value is DateTime) {
      type = OracleType.timestamp;
      bytes = _encodeDateTime(value);
    } else if (value is Uint8List) {
      type = OracleType.raw;
      bytes = value;
    } else {
      type = OracleType.varchar2;
      bytes = Uint8List.fromList(value.toString().codeUnits);
    }

    return BindParam(
      name: name,
      type: type,
      value: bytes,
      direction: direction,
    );
  }

  static Uint8List _encodeInt(int value) {
    // Simple Oracle NUMBER encoding for integers
    if (value == 0) {
      return Uint8List.fromList([0x80]);
    }

    final isNegative = value < 0;
    var absValue = isNegative ? -value : value;

    final digits = <int>[];
    while (absValue > 0) {
      digits.insert(0, absValue % 100);
      absValue ~/= 100;
    }

    final exponent = digits.length - 1;
    final result = <int>[];

    if (isNegative) {
      result.add(62 - exponent);
      for (final d in digits) {
        result.add(101 - d);
      }
      result.add(0x66); // Terminator
    } else {
      result.add((exponent + 65) | 0x80);
      for (final d in digits) {
        result.add(d + 1);
      }
    }

    return Uint8List.fromList(result);
  }

  static Uint8List _encodeDouble(double value) {
    final buffer = ByteData(8);
    buffer.setFloat64(0, value);
    return buffer.buffer.asUint8List();
  }

  static Uint8List _encodeDateTime(DateTime dt) {
    final year = dt.year;
    return Uint8List.fromList([
      (year ~/ 100) + 100,
      (year % 100) + 100,
      dt.month,
      dt.day,
      dt.hour + 1,
      dt.minute + 1,
      dt.second + 1,
    ]);
  }
}

/// Fetch request for additional rows
class FetchRequest extends Message {
  const FetchRequest({
    required this.cursorId,
    this.fetchSize = 100,
  });

  @override
  TtcMessageType get type => TtcMessageType.function;

  final int cursorId;
  final int fetchSize;

  @override
  void encodeBody(TtcBuffer buffer) {
    buffer.writeUint8(OpiFunction.enhancedFetch.value);
    buffer.writeUint32(cursorId);
    buffer.writeUint32(fetchSize);
  }
}

/// Close cursor request
class CloseCursorRequest extends Message {
  const CloseCursorRequest({
    required this.cursorId,
  });

  @override
  TtcMessageType get type => TtcMessageType.function;

  final int cursorId;

  @override
  void encodeBody(TtcBuffer buffer) {
    buffer.writeUint8(OpiFunction.closeCursor.value);
    buffer.writeUint32(cursorId);
  }
}
