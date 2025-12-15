import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/constants.dart';

void main() {
  group('ExecuteRequest', () {
    test('encodes with correct function code (0x03)', () {
      final request = ExecuteRequest(sql: 'SELECT * FROM dual');
      final bytes = request.toBytes();

      expect(bytes[0], equals(ttcExecute)); // 0x03
    });

    test('encodes cursor ID as 4-byte big-endian', () {
      final request = ExecuteRequest(sql: 'SELECT 1', cursorId: 0);
      final bytes = request.toBytes();

      // After function code (1 byte), cursor ID is 4 bytes BE
      expect(bytes[1], equals(0));
      expect(bytes[2], equals(0));
      expect(bytes[3], equals(0));
      expect(bytes[4], equals(0));
    });

    test('encodes non-zero cursor ID correctly', () {
      final request = ExecuteRequest(sql: 'SELECT 1', cursorId: 256);
      final bytes = request.toBytes();

      // cursor ID = 256 = 0x00000100 in BE
      expect(bytes[1], equals(0));
      expect(bytes[2], equals(0));
      expect(bytes[3], equals(1));
      expect(bytes[4], equals(0));
    });

    test('encodes options byte', () {
      final request = ExecuteRequest(sql: 'SELECT 1', options: 0x42);
      final bytes = request.toBytes();

      // After cursor ID (5 bytes), options is 1 byte
      expect(bytes[5], equals(0x42));
    });

    test('encodes SQL as UTF-8 with 4-byte length prefix', () {
      const sql = 'SELECT * FROM dual';
      final request = ExecuteRequest(sql: sql);
      final bytes = request.toBytes();

      final sqlBytes = utf8.encode(sql);

      // SQL length prefix starts at byte 6 (4 bytes BE)
      final lengthFromBytes =
          (bytes[6] << 24) | (bytes[7] << 16) | (bytes[8] << 8) | bytes[9];
      expect(lengthFromBytes, equals(sqlBytes.length));

      // SQL bytes start at byte 10
      final encodedSql = bytes.sublist(10, 10 + sqlBytes.length);
      expect(encodedSql, equals(sqlBytes));
    });

    test('encodes UTF-8 characters correctly', () {
      // SQL with unicode characters
      const sql = "SELECT 'héllo' FROM dual";
      final request = ExecuteRequest(sql: sql);
      final bytes = request.toBytes();

      final sqlBytes = utf8.encode(sql);
      final lengthFromBytes =
          (bytes[6] << 24) | (bytes[7] << 16) | (bytes[8] << 8) | bytes[9];
      expect(lengthFromBytes, equals(sqlBytes.length));
    });

    test('has correct message type', () {
      final request = ExecuteRequest(sql: 'SELECT 1');
      expect(request.messageType, equals(ttcExecute));
    });

    test('default cursor ID is 0', () {
      final request = ExecuteRequest(sql: 'SELECT 1');
      expect(request.cursorId, equals(0));
    });

    test('default options is 0', () {
      final request = ExecuteRequest(sql: 'SELECT 1');
      expect(request.options, equals(0));
    });
  });

  group('ExecuteResponse', () {
    test('decodes success response with status byte 0', () {
      // Success response: status=0, cursorId=1, columnCount=1, column, rowCount=1, row
      final bytes = _buildSuccessResponse(
        cursorId: 1,
        columns: [_TestColumn('DUMMY', oraTypeVarchar, 1)],
        rows: [
          ['X']
        ],
      );

      final response = ExecuteResponse.decode(bytes);

      expect(response.isSuccess, isTrue);
      expect(response.cursorId, equals(1));
      expect(response.errorCode, isNull);
      expect(response.errorMessage, isNull);
    });

    test('decodes error response with ORA code', () {
      // Error response: status=1, errorCode=942, message="table or view does not exist"
      final bytes = _buildErrorResponse(
        errorCode: 942,
        errorMessage: 'table or view does not exist',
      );

      final response = ExecuteResponse.decode(bytes);

      expect(response.isSuccess, isFalse);
      expect(response.errorCode, equals(942));
      expect(response.errorMessage, equals('table or view does not exist'));
    });

    test('decodes column metadata correctly', () {
      final bytes = _buildSuccessResponse(
        cursorId: 1,
        columns: [
          _TestColumn('ID', oraTypeNumber, 22),
          _TestColumn('NAME', oraTypeVarchar, 100),
        ],
        rows: [],
      );

      final response = ExecuteResponse.decode(bytes);

      expect(response.columnMetadata, hasLength(2));
      expect(response.columnMetadata![0].name, equals('ID'));
      expect(response.columnMetadata![0].oracleType, equals(oraTypeNumber));
      expect(response.columnMetadata![1].name, equals('NAME'));
      expect(response.columnMetadata![1].oracleType, equals(oraTypeVarchar));
    });

    test('decodes row data when present', () {
      final bytes = _buildSuccessResponse(
        cursorId: 1,
        columns: [_TestColumn('GREETING', oraTypeVarchar, 10)],
        rows: [
          ['hello']
        ],
      );

      final response = ExecuteResponse.decode(bytes);

      expect(response.rows, hasLength(1));
      expect(response.rows![0][0], equals('hello'));
    });

    test('decodes multiple rows', () {
      final bytes = _buildSuccessResponse(
        cursorId: 1,
        columns: [_TestColumn('VAL', oraTypeVarchar, 10)],
        rows: [
          ['one'],
          ['two'],
          ['three']
        ],
      );

      final response = ExecuteResponse.decode(bytes);

      expect(response.rows, hasLength(3));
      expect(response.rows![0][0], equals('one'));
      expect(response.rows![1][0], equals('two'));
      expect(response.rows![2][0], equals('three'));
    });

    test('handles null values in rows', () {
      final bytes = _buildSuccessResponseWithNull(
        cursorId: 1,
        columns: [_TestColumn('VAL', oraTypeVarchar, 10)],
      );

      final response = ExecuteResponse.decode(bytes);

      expect(response.rows, hasLength(1));
      expect(response.rows![0][0], isNull);
    });

    test('decodes empty result set', () {
      final bytes = _buildSuccessResponse(
        cursorId: 1,
        columns: [_TestColumn('DUMMY', oraTypeVarchar, 1)],
        rows: [],
      );

      final response = ExecuteResponse.decode(bytes);

      expect(response.isSuccess, isTrue);
      expect(response.rows, isEmpty);
    });

    group('NUMBER decoding', () {
      test('decodes zero value', () {
        // Oracle NUMBER zero is represented as single byte 0x80
        final bytes = _buildSuccessResponseWithNumber(
          cursorId: 1,
          numberBytes: [0x80], // Zero
        );

        final response = ExecuteResponse.decode(bytes);

        expect(response.isSuccess, isTrue);
        expect(response.rows, hasLength(1));
        expect(response.rows![0][0], equals(0));
      });

      test('decodes small positive integer (1)', () {
        // Oracle NUMBER 1 = [0xC1, 0x02] (exponent 0xC1, mantissa 1+1=2)
        final bytes = _buildSuccessResponseWithNumber(
          cursorId: 1,
          numberBytes: [0xC1, 0x02],
        );

        final response = ExecuteResponse.decode(bytes);

        expect(response.isSuccess, isTrue);
        expect(response.rows![0][0], equals(1));
      });

      test('decodes positive integer (123)', () {
        // Oracle NUMBER 123 = [0xC2, 0x02, 0x18] (exponent 0xC2 for 2 base-100 digits)
        // 123 = 1*100 + 23 → mantissa bytes [1+1, 23+1] = [0x02, 0x18]
        final bytes = _buildSuccessResponseWithNumber(
          cursorId: 1,
          numberBytes: [0xC2, 0x02, 0x18],
        );

        final response = ExecuteResponse.decode(bytes);

        expect(response.isSuccess, isTrue);
        expect(response.rows![0][0], equals(123));
      });

      test('decodes larger positive integer (10000)', () {
        // Oracle NUMBER 10000 = [0xC3, 0x02, 0x01, 0x01]
        // 10000 = 1*10000 + 0*100 + 0 → [0x02, 0x01, 0x01]
        final bytes = _buildSuccessResponseWithNumber(
          cursorId: 1,
          numberBytes: [0xC3, 0x02, 0x01, 0x01],
        );

        final response = ExecuteResponse.decode(bytes);

        expect(response.isSuccess, isTrue);
        expect(response.rows![0][0], equals(10000));
      });
    });
  });

  group('ColumnMetadata', () {
    test('decodes column name and type', () {
      final bytes = _buildColumnMetadataBytes('TEST_COL', oraTypeVarchar, 50);
      final metadata = ColumnMetadata.decode(ReadBuffer(bytes));

      expect(metadata.name, equals('TEST_COL'));
      expect(metadata.oracleType, equals(oraTypeVarchar));
      expect(metadata.maxLength, equals(50));
    });

    test('decodes precision and scale when present', () {
      final bytes =
          _buildColumnMetadataBytes('AMOUNT', oraTypeNumber, 22, 10, 2);
      final metadata = ColumnMetadata.decode(ReadBuffer(bytes));

      expect(metadata.name, equals('AMOUNT'));
      expect(metadata.oracleType, equals(oraTypeNumber));
      expect(metadata.precision, equals(10));
      expect(metadata.scale, equals(2));
    });

    test('precision and scale are null when zero', () {
      final bytes =
          _buildColumnMetadataBytes('NAME', oraTypeVarchar, 100, 0, 0);
      final metadata = ColumnMetadata.decode(ReadBuffer(bytes));

      expect(metadata.precision, isNull);
      expect(metadata.scale, isNull);
    });
  });
}

// Test helper classes and functions

class _TestColumn {
  _TestColumn(this.name, this.type, this.maxLength);
  final String name;
  final int type;
  final int maxLength;
}

/// Builds a mock success response for testing.
Uint8List _buildSuccessResponse({
  required int cursorId,
  required List<_TestColumn> columns,
  required List<List<String>> rows,
}) {
  final buffer = BytesBuilder();

  // Status byte (0 = success)
  buffer.addByte(0);

  // Cursor ID (4 bytes BE)
  buffer.addByte((cursorId >> 24) & 0xFF);
  buffer.addByte((cursorId >> 16) & 0xFF);
  buffer.addByte((cursorId >> 8) & 0xFF);
  buffer.addByte(cursorId & 0xFF);

  // Column count (2 bytes BE)
  buffer.addByte((columns.length >> 8) & 0xFF);
  buffer.addByte(columns.length & 0xFF);

  // Column metadata
  for (final col in columns) {
    final nameBytes = utf8.encode(col.name);
    buffer.addByte(nameBytes.length); // name length
    buffer.add(nameBytes); // name
    buffer.addByte((col.type >> 8) & 0xFF); // type BE
    buffer.addByte(col.type & 0xFF);
    buffer.addByte((col.maxLength >> 8) & 0xFF); // maxLength BE
    buffer.addByte(col.maxLength & 0xFF);
    buffer.addByte(0); // precision
    buffer.addByte(0); // scale
  }

  // Row count (4 bytes BE)
  buffer.addByte((rows.length >> 24) & 0xFF);
  buffer.addByte((rows.length >> 16) & 0xFF);
  buffer.addByte((rows.length >> 8) & 0xFF);
  buffer.addByte(rows.length & 0xFF);

  // Row data
  for (final row in rows) {
    for (final value in row) {
      buffer.addByte(0); // not null indicator
      final valueBytes = utf8.encode(value);
      buffer.addByte((valueBytes.length >> 8) & 0xFF); // length BE
      buffer.addByte(valueBytes.length & 0xFF);
      buffer.add(valueBytes);
    }
  }

  return buffer.toBytes();
}

/// Builds a mock success response with a null value.
Uint8List _buildSuccessResponseWithNull({
  required int cursorId,
  required List<_TestColumn> columns,
}) {
  final buffer = BytesBuilder();

  // Status byte (0 = success)
  buffer.addByte(0);

  // Cursor ID (4 bytes BE)
  buffer.addByte((cursorId >> 24) & 0xFF);
  buffer.addByte((cursorId >> 16) & 0xFF);
  buffer.addByte((cursorId >> 8) & 0xFF);
  buffer.addByte(cursorId & 0xFF);

  // Column count (2 bytes BE)
  buffer.addByte((columns.length >> 8) & 0xFF);
  buffer.addByte(columns.length & 0xFF);

  // Column metadata
  for (final col in columns) {
    final nameBytes = utf8.encode(col.name);
    buffer.addByte(nameBytes.length);
    buffer.add(nameBytes);
    buffer.addByte((col.type >> 8) & 0xFF);
    buffer.addByte(col.type & 0xFF);
    buffer.addByte((col.maxLength >> 8) & 0xFF);
    buffer.addByte(col.maxLength & 0xFF);
    buffer.addByte(0);
    buffer.addByte(0);
  }

  // Row count = 1
  buffer.addByte(0);
  buffer.addByte(0);
  buffer.addByte(0);
  buffer.addByte(1);

  // One row with null value
  buffer.addByte(0xFF); // NULL indicator

  return buffer.toBytes();
}

/// Builds a mock error response for testing.
Uint8List _buildErrorResponse({
  required int errorCode,
  required String errorMessage,
}) {
  final buffer = BytesBuilder();

  // Status byte (non-zero = error)
  buffer.addByte(1);

  // Error code (2 bytes BE)
  buffer.addByte((errorCode >> 8) & 0xFF);
  buffer.addByte(errorCode & 0xFF);

  // Error message
  final msgBytes = utf8.encode(errorMessage);
  buffer.addByte(msgBytes.length);
  buffer.add(msgBytes);

  return buffer.toBytes();
}

/// Builds column metadata bytes for testing.
Uint8List _buildColumnMetadataBytes(
  String name,
  int type,
  int maxLength, [
  int precision = 0,
  int scale = 0,
]) {
  final buffer = BytesBuilder();
  final nameBytes = utf8.encode(name);

  buffer.addByte(nameBytes.length);
  buffer.add(nameBytes);
  buffer.addByte((type >> 8) & 0xFF);
  buffer.addByte(type & 0xFF);
  buffer.addByte((maxLength >> 8) & 0xFF);
  buffer.addByte(maxLength & 0xFF);
  buffer.addByte(precision);
  buffer.addByte(scale);

  return buffer.toBytes();
}

/// Builds a mock success response with a NUMBER value for testing.
Uint8List _buildSuccessResponseWithNumber({
  required int cursorId,
  required List<int> numberBytes,
}) {
  final buffer = BytesBuilder();

  // Status byte (0 = success)
  buffer.addByte(0);

  // Cursor ID (4 bytes BE)
  buffer.addByte((cursorId >> 24) & 0xFF);
  buffer.addByte((cursorId >> 16) & 0xFF);
  buffer.addByte((cursorId >> 8) & 0xFF);
  buffer.addByte(cursorId & 0xFF);

  // Column count = 1
  buffer.addByte(0);
  buffer.addByte(1);

  // Column metadata for NUMBER column
  const colName = 'NUM';
  final nameBytes = utf8.encode(colName);
  buffer.addByte(nameBytes.length);
  buffer.add(nameBytes);
  buffer.addByte((oraTypeNumber >> 8) & 0xFF); // type BE
  buffer.addByte(oraTypeNumber & 0xFF);
  buffer.addByte(0); // maxLength BE
  buffer.addByte(22);
  buffer.addByte(0); // precision
  buffer.addByte(0); // scale

  // Row count = 1
  buffer.addByte(0);
  buffer.addByte(0);
  buffer.addByte(0);
  buffer.addByte(1);

  // Row data - NUMBER value
  buffer.addByte(0); // not null indicator
  buffer.addByte(numberBytes.length); // NUMBER length byte
  buffer.add(numberBytes); // NUMBER bytes

  return buffer.toBytes();
}
