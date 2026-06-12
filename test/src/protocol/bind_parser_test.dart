import 'package:oracledb/src/errors.dart';
import 'package:oracledb/src/protocol/bind_parser.dart';
import 'package:test/test.dart';

void main() {
  group('BindParser', () {
    group('parseNamedBinds', () {
      test('parses single named bind', () {
        final binds =
            BindParser.parseNamedBinds('SELECT * FROM emp WHERE dept = :dept');
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
        final binds =
            BindParser.parseNamedBinds('SELECT * FROM emp WHERE val = :val1');
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

    // Duplicate bind-name guard for PL/SQL inputs.
    //
    // The validator in connection.execute() was previously tested only against
    // plain SELECT/DML shapes. These tests pin the same guard against PL/SQL
    // shapes where it is legitimate to repeat a placeholder name in multiple
    // SQL positions and expect the bind map to provide one value per unique
    // name. Exercised via the package-internal helper so no live Oracle
    // session is required.
    group('validateNamedBindCount', () {
      test(
          'PL/SQL block with duplicate placeholder and wrong bind-map count '
          'throws ORA-01008', () {
        // `BEGIN p(:a, :a, :b); END;` — two distinct names, three positions.
        // Bind map provides three values, but only two are needed (the
        // duplicate `:a` reuses the value). Mismatch → ORA-01008.
        final bindNames = BindParser.parseNamedBinds(
          'BEGIN proc_x(:a, :a, :b); END;',
        );
        expect(bindNames, equals(['a', 'a', 'b']),
            reason: 'parseNamedBinds preserves duplicates in SQL order');

        expect(
          () => BindParser.validateNamedBindCount(bindNames, 3),
          throwsA(
            isA<OracleException>()
                .having((e) => e.errorCode, 'errorCode', oraBindMismatch)
                .having((e) => e.message, 'message',
                    contains('2 unique placeholders'))
                .having(
                    (e) => e.message, 'message', contains('3 values provided')),
          ),
        );
      });

      test(
          'PL/SQL block with duplicate placeholder and correct bind-map count '
          'passes', () {
        // Same SQL as above, but the caller provides one value per *unique*
        // name (a, b). This is the contract the validator must accept.
        final bindNames = BindParser.parseNamedBinds(
          'BEGIN proc_x(:a, :a, :b); END;',
        );
        expect(
          () => BindParser.validateNamedBindCount(bindNames, 2),
          returnsNormally,
        );
      });

      test(
          'PL/SQL DECLARE block with repeated :ret duplicate counts collapse '
          'via toSet()', () {
        // PL/SQL DECLARE shape with a repeated placeholder name. The
        // `uniqueNames.toSet()` path must collapse `:ret` to a single unique
        // name and reject a 2-value bind map.
        final bindNames = BindParser.parseNamedBinds(
          'DECLARE v NUMBER; BEGIN :ret := story73_add(:a, :ret); END;',
        );
        // The parser walks the SQL in order, so duplicate names are emitted
        // wherever they appear (here `:ret` appears twice).
        expect(bindNames, contains('ret'));
        expect(bindNames.where((n) => n == 'ret').length, equals(2));

        // Three SQL positions, two unique names (ret, a). Providing three
        // values is wrong — must throw.
        expect(
          () => BindParser.validateNamedBindCount(bindNames, 3),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraBindMismatch)),
        );

        // Providing two values (one per unique name) is correct.
        expect(
          () => BindParser.validateNamedBindCount(bindNames, 2),
          returnsNormally,
        );
      });

      test('plain SELECT with duplicate :val and wrong count throws ORA-01008',
          () {
        // Regression — the existing SELECT/DML path that previously embedded
        // the same logic now routes through the extracted helper.
        final bindNames = BindParser.parseNamedBinds(
          'SELECT :val AS a, :val AS b FROM dual',
        );
        expect(bindNames, equals(['val', 'val']));
        expect(
          () => BindParser.validateNamedBindCount(bindNames, 2),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraBindMismatch)),
        );
        expect(
          () => BindParser.validateNamedBindCount(bindNames, 1),
          returnsNormally,
        );
      });
    });
  });
}
