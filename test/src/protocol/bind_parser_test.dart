import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/bind_parser.dart';
import 'package:test/test.dart';

void main() {
  group('BindParser', () {
    group('parseNamedBinds', () {
      test('parses single named bind', () {
        final binds = BindParser.parseNamedBinds('SELECT * FROM emp WHERE dept = :dept');
        expect(binds, equals(['dept']));
      });

      test('parses multiple named binds', () {
        final binds = BindParser.parseNamedBinds(
            'SELECT * FROM emp WHERE dept = :dept AND id = :id');
        expect(binds, equals(['dept', 'id']));
      });

      test('parses bind with underscore', () {
        final binds = BindParser.parseNamedBinds(
            'SELECT * FROM emp WHERE dept_id = :dept_id');
        expect(binds, equals(['dept_id']));
      });

      test('parses bind with numbers in name', () {
        final binds = BindParser.parseNamedBinds(
            'SELECT * FROM emp WHERE val = :val1');
        expect(binds, equals(['val1']));
      });

      test('returns empty list for no binds', () {
        final binds = BindParser.parseNamedBinds('SELECT * FROM emp');
        expect(binds, isEmpty);
      });

      test('ignores binds inside string literals', () {
        final binds = BindParser.parseNamedBinds(
            "SELECT ':not_a_bind' as col, :real_bind FROM dual");
        expect(binds, equals(['real_bind']));
      });

      test('handles escaped quotes in string literals', () {
        final binds = BindParser.parseNamedBinds(
            "SELECT 'it''s :not_a_bind' as col, :real FROM dual");
        expect(binds, equals(['real']));
      });

      test('parses same bind name appearing multiple times', () {
        final binds = BindParser.parseNamedBinds(
            'SELECT * FROM emp WHERE a = :val OR b = :val');
        expect(binds, equals(['val', 'val']));
      });
    });

    group('parsePositionalBinds', () {
      test('parses single positional bind', () {
        final count = BindParser.parsePositionalBinds(
            'SELECT * FROM emp WHERE dept = :1');
        expect(count, equals(1));
      });

      test('parses multiple positional binds', () {
        final count = BindParser.parsePositionalBinds(
            'SELECT * FROM emp WHERE dept = :1 AND id = :2');
        expect(count, equals(2));
      });

      test('returns zero for no positional binds', () {
        final count = BindParser.parsePositionalBinds('SELECT * FROM emp');
        expect(count, equals(0));
      });

      test('ignores positional binds inside string literals', () {
        final count = BindParser.parsePositionalBinds(
            "SELECT ':1' as col, :1 as real FROM dual");
        expect(count, equals(1));
      });

      test('throws on non-sequential positional binds', () {
        expect(
          () => BindParser.parsePositionalBinds(
              'SELECT * FROM emp WHERE a = :1 AND b = :3'),
          throwsA(isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            oraBindMismatch,
          )),
        );
      });

      test('handles two-digit positional binds', () {
        final count = BindParser.parsePositionalBinds(
            'SELECT :1, :2, :3, :4, :5, :6, :7, :8, :9, :10 FROM dual');
        expect(count, equals(10));
      });
    });

    group('isNamedBinds', () {
      test('returns true for named binds', () {
        expect(
          BindParser.isNamedBinds('SELECT * FROM emp WHERE dept = :dept'),
          isTrue,
        );
      });

      test('returns false for positional binds', () {
        expect(
          BindParser.isNamedBinds('SELECT * FROM emp WHERE dept = :1'),
          isFalse,
        );
      });

      test('returns false for no binds', () {
        expect(
          BindParser.isNamedBinds('SELECT * FROM emp'),
          isFalse,
        );
      });

      test('throws on mixed binds', () {
        expect(
          () => BindParser.isNamedBinds(
              'SELECT * FROM emp WHERE dept = :dept AND id = :1'),
          throwsA(isA<OracleException>().having(
            (e) => e.errorCode,
            'errorCode',
            oraBindMismatch,
          )),
        );
      });
    });
  });
}
