/// Unit tests for the SQL statement classifier (sql_classifier.dart).
///
/// Covers isQuerySql, isPlSqlSql, and isCacheEligibleSql for leading
/// whitespace, block/line comments, and all recognised keyword forms.
library;

import 'package:oracledb/src/sql_classifier.dart';
import 'package:test/test.dart';

void main() {
  group('isQuerySql', () {
    test('SELECT is a query', () {
      expect(isQuerySql('SELECT 1 FROM dual'), isTrue);
    });

    test('SELECT case-insensitive', () {
      expect(isQuerySql('select 1 from dual'), isTrue);
      expect(isQuerySql('Select * From t'), isTrue);
    });

    test('WITH is a query', () {
      expect(isQuerySql('WITH cte AS (SELECT 1) SELECT * FROM cte'), isTrue);
    });

    test('leading whitespace before SELECT', () {
      expect(isQuerySql('   SELECT 1 FROM dual'), isTrue);
      expect(isQuerySql('\n\tSELECT 1'), isTrue);
    });

    test('leading block comment before SELECT', () {
      expect(isQuerySql('/* hint */ SELECT 1 FROM dual'), isTrue);
    });

    test('leading line comment before SELECT', () {
      expect(isQuerySql('-- comment\nSELECT 1 FROM dual'), isTrue);
    });

    test('DML is not a query', () {
      expect(isQuerySql('INSERT INTO t VALUES (1)'), isFalse);
      expect(isQuerySql('UPDATE t SET x = 1'), isFalse);
      expect(isQuerySql('DELETE FROM t'), isFalse);
    });

    test('PL/SQL is not a query', () {
      expect(isQuerySql('BEGIN my_proc(); END;'), isFalse);
      expect(isQuerySql('DECLARE v NUMBER; BEGIN NULL; END;'), isFalse);
      expect(isQuerySql('CALL my_proc()'), isFalse);
    });

    test('empty string is not a query', () {
      expect(isQuerySql(''), isFalse);
      expect(isQuerySql('   '), isFalse);
    });
  });

  group('isPlSqlSql', () {
    test('BEGIN block is PL/SQL', () {
      expect(isPlSqlSql('BEGIN my_proc(); END;'), isTrue);
    });

    test('BEGIN case-insensitive', () {
      expect(isPlSqlSql('begin my_proc(); end;'), isTrue);
      expect(isPlSqlSql('Begin Null; End;'), isTrue);
    });

    test('DECLARE block is PL/SQL', () {
      expect(isPlSqlSql('DECLARE v NUMBER; BEGIN NULL; END;'), isTrue);
    });

    test('CALL statement is PL/SQL', () {
      expect(isPlSqlSql('CALL my_proc(1, 2)'), isTrue);
      expect(isPlSqlSql('call my_proc()'), isTrue);
    });

    test('leading whitespace before BEGIN', () {
      expect(isPlSqlSql('  BEGIN NULL; END;'), isTrue);
      expect(isPlSqlSql('\n\tBEGIN NULL; END;'), isTrue);
    });

    test('leading block comment before BEGIN', () {
      expect(isPlSqlSql('/* plsql */ BEGIN NULL; END;'), isTrue);
    });

    test('leading line comment before DECLARE', () {
      expect(
          isPlSqlSql('-- comment\nDECLARE x NUMBER; BEGIN NULL; END;'), isTrue);
    });

    test('SELECT is not PL/SQL', () {
      expect(isPlSqlSql('SELECT 1 FROM dual'), isFalse);
    });

    test('DML is not PL/SQL', () {
      expect(isPlSqlSql('INSERT INTO t VALUES (1)'), isFalse);
      expect(isPlSqlSql('UPDATE t SET x = 1'), isFalse);
      expect(isPlSqlSql('DELETE FROM t'), isFalse);
    });

    test('BEGINNING (prefix collision) is not PL/SQL', () {
      // The word "BEGINNING" starts with BEGIN but is not a keyword boundary.
      expect(isPlSqlSql('BEGINNING OF LOOP'), isFalse);
    });

    test('keyword immediately followed by block comment is PL/SQL', () {
      // Word boundary must allow `/` so `BEGIN/*…*/` is still classified.
      expect(isPlSqlSql('BEGIN/*hint*/ my_proc(); END;'), isTrue);
      expect(isPlSqlSql('DECLARE/*c*/ v NUMBER; BEGIN NULL; END;'), isTrue);
      expect(isPlSqlSql('CALL/*c*/my_proc()'), isTrue);
    });

    test('keyword immediately followed by line comment is PL/SQL', () {
      expect(isPlSqlSql('BEGIN-- inline\n my_proc(); END;'), isTrue);
    });

    test('keyword immediately followed by semicolon is PL/SQL', () {
      // `BEGIN;` is a degenerate but syntactically PL/SQL form.
      expect(isPlSqlSql('BEGIN; NULL; END;'), isTrue);
    });

    test('empty string is not PL/SQL', () {
      expect(isPlSqlSql(''), isFalse);
    });
  });

  group('isCacheEligibleSql', () {
    test('SELECT is eligible', () {
      expect(isCacheEligibleSql('SELECT 1 FROM dual'), isTrue);
    });

    test('WITH is eligible', () {
      expect(isCacheEligibleSql('WITH cte AS (SELECT 1) SELECT * FROM cte'),
          isTrue);
    });

    test('INSERT is eligible', () {
      expect(isCacheEligibleSql('INSERT INTO t VALUES (1)'), isTrue);
    });

    test('UPDATE is eligible', () {
      expect(isCacheEligibleSql('UPDATE t SET x = 1'), isTrue);
    });

    test('DELETE is eligible', () {
      expect(isCacheEligibleSql('DELETE FROM t'), isTrue);
    });

    test('DDL is not eligible', () {
      expect(isCacheEligibleSql('CREATE TABLE t (id NUMBER)'), isFalse);
      expect(isCacheEligibleSql('ALTER TABLE t ADD COLUMN x'), isFalse);
      expect(isCacheEligibleSql('DROP TABLE t'), isFalse);
    });

    test('PL/SQL BEGIN is not eligible', () {
      expect(isCacheEligibleSql('BEGIN my_proc(); END;'), isFalse);
    });

    test('PL/SQL DECLARE is not eligible', () {
      expect(isCacheEligibleSql('DECLARE v NUMBER; BEGIN NULL; END;'), isFalse);
    });

    test('PL/SQL CALL is not eligible', () {
      expect(isCacheEligibleSql('CALL my_proc()'), isFalse);
    });
  });
}
