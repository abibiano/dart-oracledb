import 'package:test/test.dart';

import 'package:oracledb/src/oracle_bind.dart';
import 'package:oracledb/src/result.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/protocol/constants.dart';

void main() {
  group('OracleResult', () {
    test('exposes rows from constructor', () {
      final result = OracleResult(
        columnMetadata: const [
          ColumnMetadata(
              name: 'NAME', oracleType: oraTypeVarchar, maxLength: 100),
        ],
        rowData: const [
          ['Alice'],
          ['Bob'],
        ],
      );

      expect(result.rows, hasLength(2));
      expect(result.rowCount, equals(2));
    });

    test('exposes column metadata', () {
      const columns = [
        ColumnMetadata(name: 'ID', oracleType: oraTypeNumber, maxLength: 22),
        ColumnMetadata(
            name: 'NAME', oracleType: oraTypeVarchar, maxLength: 100),
      ];

      final result = OracleResult(
        columnMetadata: columns,
        rowData: const [],
      );

      expect(result.columns, hasLength(2));
      expect(result.columns[0].name, equals('ID'));
      expect(result.columns[1].name, equals('NAME'));
    });

    test('exposes column names', () {
      final result = OracleResult(
        columnMetadata: const [
          ColumnMetadata(
              name: 'FIRST', oracleType: oraTypeVarchar, maxLength: 50),
          ColumnMetadata(
              name: 'SECOND', oracleType: oraTypeVarchar, maxLength: 50),
        ],
        rowData: const [],
      );

      expect(result.columnNames, equals(['FIRST', 'SECOND']));
    });

    test('handles empty result set', () {
      final result = OracleResult(
        columnMetadata: const [
          ColumnMetadata(
              name: 'COL', oracleType: oraTypeVarchar, maxLength: 10),
        ],
        rowData: const [],
      );

      expect(result.rows, isEmpty);
      expect(result.rowCount, equals(0));
    });

    test('rowsAffected is available for DML operations', () {
      final result = OracleResult(
        columnMetadata: const [],
        rowData: const [],
        rowsAffected: 5,
      );

      expect(result.rowsAffected, equals(5));
    });

    test('outBinds defaults to an empty container', () {
      final result = OracleResult(
        columnMetadata: const [],
        rowData: const [],
      );
      expect(result.outBinds.isEmpty, isTrue);
      expect(result.outBinds['ret'], isNull);
      expect(result.outBinds[0], isNull);
    });

    test('outBinds carries decoded values when supplied', () {
      final result = OracleResult(
        columnMetadata: const [],
        rowData: const [],
        outBinds: OracleOutBinds(
          values: const [42],
          names: const {'ret': 0},
        ),
      );
      expect(result.outBinds['ret'], equals(42));
      expect(result.outBinds[0], equals(42));
      expect(result.outBinds.length, equals(1));
    });
  });

  group('OracleRow', () {
    late OracleResult result;

    setUp(() {
      result = OracleResult(
        columnMetadata: const [
          ColumnMetadata(name: 'ID', oracleType: oraTypeNumber, maxLength: 22),
          ColumnMetadata(
              name: 'NAME', oracleType: oraTypeVarchar, maxLength: 100),
          ColumnMetadata(name: 'AGE', oracleType: oraTypeNumber, maxLength: 22),
        ],
        rowData: const [
          [1, 'Alice', 30],
          [2, 'Bob', null],
        ],
      );
    });

    test('access by column name (case-insensitive)', () {
      final row = result.rows[0];
      expect(row['NAME'], equals('Alice'));
      expect(row['name'], equals('Alice'));
      expect(row['Name'], equals('Alice'));
    });

    test('access by column index', () {
      final row = result.rows[0];
      expect(row[0], equals(1));
      expect(row[1], equals('Alice'));
      expect(row[2], equals(30));
    });

    test('returns null for non-existent column name', () {
      final row = result.rows[0];
      expect(row['NONEXISTENT'], isNull);
    });

    test('returns null for out-of-bounds index', () {
      final row = result.rows[0];
      expect(row[99], isNull);
      expect(row[-1], isNull);
    });

    test('handles null values properly', () {
      final row = result.rows[1];
      expect(row['AGE'], isNull);
      expect(row[2], isNull);
    });

    test('length returns column count', () {
      final row = result.rows[0];
      expect(row.length, equals(3));
    });

    test('columnNames returns column names in order', () {
      final row = result.rows[0];
      expect(row.columnNames, equals(['ID', 'NAME', 'AGE']));
    });

    test('toList returns all values', () {
      final row = result.rows[0];
      expect(row.toList(), equals([1, 'Alice', 30]));
    });

    test('toMap returns column name to value mapping', () {
      final row = result.rows[0];
      final map = row.toMap();
      expect(map['ID'], equals(1));
      expect(map['NAME'], equals('Alice'));
      expect(map['AGE'], equals(30));
    });

    test('toList returns unmodifiable list', () {
      final row = result.rows[0];
      final list = row.toList();
      expect(() => list.add('foo'), throwsUnsupportedError);
    });
  });
}
