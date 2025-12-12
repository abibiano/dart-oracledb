/// Base message class for TTC protocol messages.
library;

import 'dart:typed_data';

import '../constants.dart';
import '../protocol/ttc_buffer.dart';

/// Base class for all TTC protocol messages.
///
/// TTC messages are sent inside TNS Data packets and handle
/// all database operations.
abstract class Message {
  const Message();

  /// Message type code
  TtcMessageType get type;

  /// Encode the message to bytes
  Uint8List encode() {
    final buffer = TtcBuffer();
    buffer.writeUint8(type.value);
    encodeBody(buffer);
    return buffer.toBytes();
  }

  /// Encode the message body (subclasses implement)
  void encodeBody(TtcBuffer buffer);

  /// Decode a message from bytes
  static Message decode(Uint8List data) {
    final buffer = TtcBuffer();
    buffer.load(data);

    final typeCode = buffer.readUint8();
    final type = TtcMessageType.fromValue(typeCode);

    // Return appropriate message subclass based on type
    switch (type) {
      case TtcMessageType.error:
        return ErrorMessage.decodeBody(buffer);
      case TtcMessageType.status:
        return StatusMessage.decodeBody(buffer);
      case TtcMessageType.rowHeader:
        return RowHeaderMessage.decodeBody(buffer);
      case TtcMessageType.rowData:
        return RowDataMessage.decodeBody(buffer);
      case null:
        return RawMessage(type: TtcMessageType.function, data: data);
      case final knownType:
        return RawMessage(type: knownType, data: data);
    }
  }
}

/// Raw message for unrecognized types
class RawMessage extends Message {
  const RawMessage({required this.type, required this.data});

  @override
  final TtcMessageType type;
  final Uint8List data;

  @override
  void encodeBody(TtcBuffer buffer) {
    buffer.writeBytes(data);
  }
}

/// Error message (TTIOER)
class ErrorMessage extends Message {
  const ErrorMessage({
    required this.errorCode,
    required this.errorMessage,
    this.sqlState,
    this.position,
  });

  @override
  TtcMessageType get type => TtcMessageType.error;

  /// Oracle error code (ORA-XXXXX)
  final int errorCode;

  /// Error message text
  final String errorMessage;

  /// SQL state (if applicable)
  final String? sqlState;

  /// Error position in SQL (if syntax error)
  final int? position;

  @override
  void encodeBody(TtcBuffer buffer) {
    buffer.writeUint32(errorCode);
    buffer.writeClrString(errorMessage);
    if (sqlState != null) {
      buffer.writeClrString(sqlState!);
    }
    if (position != null) {
      buffer.writeUint32(position!);
    }
  }

  factory ErrorMessage.decodeBody(TtcBuffer buffer) {
    final errorCode = buffer.readUint32();
    final errorMessage = buffer.readClrString() ?? '';

    String? sqlState;
    int? position;

    if (!buffer.atEnd) {
      sqlState = buffer.readClrString();
    }
    if (!buffer.atEnd) {
      position = buffer.readUint32();
    }

    return ErrorMessage(
      errorCode: errorCode,
      errorMessage: errorMessage,
      sqlState: sqlState,
      position: position,
    );
  }
}

/// Status message (TTISTA) - indicates operation success
class StatusMessage extends Message {
  const StatusMessage({
    this.rowsAffected = 0,
    this.lastRowId,
    this.warning,
  });

  @override
  TtcMessageType get type => TtcMessageType.status;

  /// Number of rows affected
  final int rowsAffected;

  /// ROWID of last inserted row
  final String? lastRowId;

  /// Warning message (if any)
  final String? warning;

  @override
  void encodeBody(TtcBuffer buffer) {
    buffer.writeUint32(rowsAffected);
    if (lastRowId != null) {
      buffer.writeClrString(lastRowId!);
    }
  }

  factory StatusMessage.decodeBody(TtcBuffer buffer) {
    final rowsAffected = buffer.readUint32();

    String? lastRowId;
    String? warning;

    if (!buffer.atEnd) {
      lastRowId = buffer.readClrString();
    }
    if (!buffer.atEnd) {
      warning = buffer.readClrString();
    }

    return StatusMessage(
      rowsAffected: rowsAffected,
      lastRowId: lastRowId,
      warning: warning,
    );
  }
}

/// Row header message (TTIRXH) - describes columns
class RowHeaderMessage extends Message {
  const RowHeaderMessage({
    required this.columns,
  });

  @override
  TtcMessageType get type => TtcMessageType.rowHeader;

  /// Column definitions
  final List<ColumnDefinition> columns;

  @override
  void encodeBody(TtcBuffer buffer) {
    buffer.writeUint16(columns.length);
    for (final col in columns) {
      buffer.writeClrString(col.name);
      buffer.writeUint8(col.typeCode);
      buffer.writeUint16(col.size);
      buffer.writeUint8(col.precision);
      buffer.writeInt8(col.scale);
      buffer.writeUint8(col.nullable ? 1 : 0);
    }
  }

  factory RowHeaderMessage.decodeBody(TtcBuffer buffer) {
    final count = buffer.readUint16();
    final columns = <ColumnDefinition>[];

    for (var i = 0; i < count; i++) {
      columns.add(ColumnDefinition(
        name: buffer.readClrString() ?? '',
        typeCode: buffer.readUint8(),
        size: buffer.readUint16(),
        precision: buffer.readUint8(),
        scale: buffer.readInt8(),
        nullable: buffer.readUint8() != 0,
      ));
    }

    return RowHeaderMessage(columns: columns);
  }
}

/// Column definition from row header
class ColumnDefinition {
  const ColumnDefinition({
    required this.name,
    required this.typeCode,
    required this.size,
    required this.precision,
    required this.scale,
    required this.nullable,
  });

  final String name;
  final int typeCode;
  final int size;
  final int precision;
  final int scale;
  final bool nullable;
}

/// Row data message (TTIRXD) - contains row values
class RowDataMessage extends Message {
  const RowDataMessage({
    required this.values,
    this.isLastRow = false,
  });

  @override
  TtcMessageType get type => TtcMessageType.rowData;

  /// Column values (as bytes, decoded separately)
  final List<Uint8List?> values;

  /// Whether this is the last row
  final bool isLastRow;

  @override
  void encodeBody(TtcBuffer buffer) {
    buffer.writeUint16(values.length);
    for (final value in values) {
      buffer.writeClr(value);
    }
    buffer.writeUint8(isLastRow ? 1 : 0);
  }

  factory RowDataMessage.decodeBody(TtcBuffer buffer) {
    final count = buffer.readUint16();
    final values = <Uint8List?>[];

    for (var i = 0; i < count; i++) {
      values.add(buffer.readClr());
    }

    final isLastRow = !buffer.atEnd && buffer.readUint8() != 0;

    return RowDataMessage(values: values, isLastRow: isLastRow);
  }
}

// Extension for signed int8 support
extension on TtcBuffer {
  void writeInt8(int value) {
    writeUint8(value < 0 ? value + 256 : value);
  }

  int readInt8() {
    final unsigned = readUint8();
    return unsigned > 127 ? unsigned - 256 : unsigned;
  }
}
