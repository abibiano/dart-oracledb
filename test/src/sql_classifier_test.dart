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

    // Story 7.3 — MERGE classification parity with INSERT/UPDATE/DELETE.
    test('MERGE is eligible (Story 7.3 AC1)', () {
      expect(
        isCacheEligibleSql(
          'MERGE INTO target t USING source s ON (t.id = s.id) '
          'WHEN MATCHED THEN UPDATE SET t.val = s.val',
        ),
        isTrue,
      );
    });

    test('MERGE is not a query (Story 7.3 AC1)', () {
      expect(
        isQuerySql(
          'MERGE INTO target t USING source s ON (t.id = s.id) '
          'WHEN MATCHED THEN UPDATE SET t.val = s.val',
        ),
        isFalse,
      );
    });
  });

  // Story 7.3 — CTE-with-DML classification.
  group('WITH-CTE classification (Story 7.3 AC1)', () {
    test('WITH ... SELECT remains a query', () {
      const sql = 'WITH cte AS (SELECT 1 FROM dual) SELECT * FROM cte';
      expect(isQuerySql(sql), isTrue);
      expect(isCacheEligibleSql(sql), isTrue);
    });

    test('WITH ... INSERT is DML, not a query', () {
      const sql = 'WITH src AS (SELECT 1 AS id FROM dual) '
          'INSERT INTO t (id) SELECT id FROM src';
      expect(isQuerySql(sql), isFalse,
          reason: 'CTE-backed INSERT must classify as DML so rowsAffected is '
              'populated');
      expect(isCacheEligibleSql(sql), isTrue);
    });

    test('WITH ... UPDATE is DML, not a query', () {
      const sql = 'WITH src AS (SELECT 1 AS id FROM dual) '
          'UPDATE t SET val = val + 1 WHERE id IN (SELECT id FROM src)';
      expect(isQuerySql(sql), isFalse);
      expect(isCacheEligibleSql(sql), isTrue);
    });

    test('WITH ... DELETE is DML, not a query', () {
      const sql = 'WITH src AS (SELECT 1 AS id FROM dual) '
          'DELETE FROM t WHERE id IN (SELECT id FROM src)';
      expect(isQuerySql(sql), isFalse);
      expect(isCacheEligibleSql(sql), isTrue);
    });

    test('WITH ... MERGE is DML, not a query', () {
      const sql = 'WITH src AS (SELECT 1 AS id, 2 AS val FROM dual) '
          'MERGE INTO t USING src ON (t.id = src.id) '
          'WHEN MATCHED THEN UPDATE SET t.val = src.val';
      expect(isQuerySql(sql), isFalse);
      expect(isCacheEligibleSql(sql), isTrue);
    });

    test('multiple CTEs followed by SELECT still classify as query', () {
      const sql = 'WITH a AS (SELECT 1 AS x FROM dual), '
          'b AS (SELECT 2 AS y FROM dual) '
          'SELECT a.x, b.y FROM a, b';
      expect(isQuerySql(sql), isTrue);
      expect(isCacheEligibleSql(sql), isTrue);
    });

    test('multiple CTEs followed by INSERT classify as DML', () {
      const sql = 'WITH a AS (SELECT 1 AS id FROM dual), '
          'b AS (SELECT 2 AS id FROM dual) '
          'INSERT INTO t (id) SELECT id FROM a UNION ALL SELECT id FROM b';
      expect(isQuerySql(sql), isFalse);
      expect(isCacheEligibleSql(sql), isTrue);
    });

    test('CTE inner SELECT keywords do not steal terminal-verb match', () {
      // The inner SELECT lives inside parens; the scanner must keep paren
      // depth >0 throughout and only match the terminal INSERT at depth 0.
      const sql = 'WITH src AS (SELECT id FROM (SELECT 1 AS id FROM dual)) '
          'INSERT INTO t (id) SELECT id FROM src';
      expect(isQuerySql(sql), isFalse);
      expect(isCacheEligibleSql(sql), isTrue);
    });

    test('CTE with string literal containing parens does not corrupt depth',
        () {
      // A literal `'('` or `')'` inside the CTE expression must not be
      // interpreted as a real paren — otherwise the depth tracker would
      // never return to zero (or would return early) and the terminal verb
      // would not be found.
      const sql = "WITH src AS (SELECT '(' || ')' AS s FROM dual) "
          'INSERT INTO t (s) SELECT s FROM src';
      expect(isCacheEligibleSql(sql), isTrue);
      expect(isQuerySql(sql), isFalse);
    });

    test('malformed WITH with no terminal verb is not classified', () {
      const sql = 'WITH cte AS (SELECT 1 FROM dual)';
      expect(isQuerySql(sql), isFalse);
      expect(isCacheEligibleSql(sql), isFalse);
    });

    test('bare WITH keyword alone is not classified', () {
      expect(isQuerySql('WITH'), isFalse);
      expect(isCacheEligibleSql('WITH'), isFalse);
    });

    test('WITH case-insensitive (lower-case terminal verb)', () {
      expect(
        isQuerySql('with cte as (select 1 from dual) select * from cte'),
        isTrue,
      );
      expect(
        isCacheEligibleSql(
            'with cte as (select 1 from dual) insert into t select * from cte'),
        isTrue,
      );
    });
  });

  // Story 7.3 — Leading parenthesis no longer reclassifies malformed SQL.
  group('paren-prefixed SQL is not reclassified (Story 7.3 AC2)', () {
    test('(BEGIN ... END;) is NOT classified as PL/SQL', () {
      // Pre-7.3 behavior stripped the leading `(` and matched BEGIN. The
      // story's contract is that a leading paren signals malformed input
      // and the inner verb is not promoted.
      expect(isPlSqlSql('(BEGIN NULL; END;)'), isFalse);
    });

    test('(DELETE FROM t) is NOT classified as DML / cache-eligible', () {
      expect(isCacheEligibleSql('(DELETE FROM t)'), isFalse);
      expect(isQuerySql('(DELETE FROM t)'), isFalse);
    });

    test('((SELECT 1 FROM dual)) is NOT classified as a query', () {
      expect(isQuerySql('((SELECT 1 FROM dual))'), isFalse);
      expect(isCacheEligibleSql('((SELECT 1 FROM dual))'), isFalse);
    });

    test('whitespace before leading paren is still rejected', () {
      // `skipSqlPrefixes` advances past whitespace but stops at `(`.
      expect(isPlSqlSql('   (BEGIN NULL; END;)'), isFalse);
      expect(isQuerySql('   (SELECT 1 FROM dual)'), isFalse);
    });

    test('comment before leading paren is still rejected', () {
      expect(isPlSqlSql('/* hint */(BEGIN NULL; END;)'), isFalse);
      expect(isQuerySql('-- comment\n(SELECT 1 FROM dual)'), isFalse);
    });

    test('SELECT with embedded inner parens still classifies normally', () {
      // Only LEADING parens are rejected; parens inside the statement after
      // the verb are perfectly fine.
      expect(isQuerySql('SELECT (1 + 2) FROM dual'), isTrue);
      expect(isCacheEligibleSql('INSERT INTO t (id) VALUES (1)'), isTrue);
    });
  });

  // Story 7.3 — CR-only line-comment termination.
  group('CR-only line-comment termination (Story 7.3 AC3)', () {
    test('CR-terminated -- comment lets SELECT through (isQuerySql)', () {
      // Classic Mac line ending (\r only). Pre-7.3 the scanner only
      // recognised \n and would swallow the whole line including SELECT.
      expect(isQuerySql('-- comment\rSELECT 1 FROM dual'), isTrue);
    });

    test('CR-terminated -- comment lets BEGIN through (isPlSqlSql)', () {
      expect(isPlSqlSql('-- comment\rBEGIN NULL; END;'), isTrue);
    });

    test('CR-terminated -- comment lets INSERT through (isCacheEligibleSql)',
        () {
      expect(
        isCacheEligibleSql('-- comment\rINSERT INTO t VALUES (1)'),
        isTrue,
      );
    });

    test('CRLF-terminated -- comment still works', () {
      // \r\n: scanner stops on \r, then the loop in skipSqlPrefixes treats
      // \n as whitespace.
      expect(isQuerySql('-- comment\r\nSELECT 1 FROM dual'), isTrue);
    });

    test('LF-terminated -- comment still works (regression)', () {
      expect(isQuerySql('-- comment\nSELECT 1 FROM dual'), isTrue);
    });
  });

  // Story 7.6 AC6 — SELECT ... FOR UPDATE is a query but is NOT cache-eligible.
  group('SELECT ... FOR UPDATE cache eligibility (Story 7.6 AC6)', () {
    test('plain SELECT remains cache-eligible', () {
      expect(isCacheEligibleSql('SELECT id FROM emp WHERE id = :1'), isTrue);
    });

    test('SELECT ... FOR UPDATE is still a query', () {
      expect(isQuerySql('SELECT id FROM emp WHERE id = :1 FOR UPDATE'), isTrue);
    });

    test('SELECT ... FOR UPDATE is excluded from caching', () {
      expect(
        isCacheEligibleSql('SELECT id FROM emp WHERE id = :1 FOR UPDATE'),
        isFalse,
      );
    });

    test('FOR UPDATE OF / NOWAIT / WAIT variants are all excluded', () {
      expect(isCacheEligibleSql('SELECT * FROM t FOR UPDATE OF c'), isFalse);
      expect(isCacheEligibleSql('SELECT * FROM t FOR UPDATE NOWAIT'), isFalse);
      expect(isCacheEligibleSql('SELECT * FROM t FOR UPDATE WAIT 5'), isFalse);
    });

    test('case-insensitive: lowercase for update is excluded', () {
      expect(isCacheEligibleSql('select * from t for update'), isFalse);
    });

    test('FOR UPDATE inside a subquery does not exclude the outer SELECT', () {
      // The locking clause belongs to the subquery (paren depth > 0); the outer
      // statement is an ordinary cacheable SELECT.
      expect(
        isCacheEligibleSql(
            'SELECT * FROM (SELECT id FROM t FOR UPDATE) WHERE id > 0'),
        isTrue,
      );
    });

    test("the literal 'FOR UPDATE' in a string does not exclude the SELECT",
        () {
      expect(
          isCacheEligibleSql("SELECT 'FOR UPDATE' AS note FROM dual"), isTrue);
    });

    test('WITH ... SELECT ... FOR UPDATE is excluded but stays a query', () {
      const sql = 'WITH c AS (SELECT 1 AS x FROM dual) '
          'SELECT x FROM c FOR UPDATE';
      expect(isQuerySql(sql), isTrue);
      expect(isCacheEligibleSql(sql), isFalse);
    });

    test('a column merely named FORWARD does not trip FOR detection', () {
      expect(isCacheEligibleSql('SELECT forward FROM t'), isTrue);
    });
  });

  // Story 7.6 AC9 — the three classifiers share one verb resolver and cannot
  // drift apart on any WITH shape.
  group('WITH classifier drift prevention (Story 7.6 AC9)', () {
    const withSelect = 'WITH c AS (SELECT 1 AS x FROM dual) SELECT x FROM c';
    const withInsert =
        'WITH c AS (SELECT 1 AS x FROM dual) INSERT INTO t SELECT x FROM c';
    const withUpdate = 'WITH c AS (SELECT 1 FROM dual) UPDATE t SET x = 1';
    const withMerge = 'WITH c AS (SELECT 1 FROM dual) '
        'MERGE INTO t USING c ON (1=1) WHEN MATCHED THEN UPDATE SET x = 1';

    test('WITH ... SELECT: query AND cache-eligible (aligned)', () {
      expect(isQuerySql(withSelect), isTrue);
      expect(isCacheEligibleSql(withSelect), isTrue);
    });

    test('WITH ... INSERT: not a query but cache-eligible (aligned)', () {
      expect(isQuerySql(withInsert), isFalse);
      expect(isCacheEligibleSql(withInsert), isTrue);
    });

    test('WITH ... UPDATE: not a query but cache-eligible (aligned)', () {
      expect(isQuerySql(withUpdate), isFalse);
      expect(isCacheEligibleSql(withUpdate), isTrue);
    });

    test('WITH ... MERGE: not a query but cache-eligible (aligned)', () {
      expect(isQuerySql(withMerge), isFalse);
      expect(isCacheEligibleSql(withMerge), isTrue);
    });

    test('leading paren stays unclassified across all three helpers', () {
      const sql = '(WITH c AS (SELECT 1 FROM dual) SELECT x FROM c)';
      expect(isQuerySql(sql), isFalse);
      expect(isPlSqlSql(sql), isFalse);
      expect(isCacheEligibleSql(sql), isFalse);
    });

    test('isQuerySql implies isCacheEligibleSql for any non-FOR-UPDATE query',
        () {
      // Property check: for the WITH ... SELECT shape the two helpers must agree
      // — the whole point of sharing _leadingVerb (no independent CTE scans).
      for (final sql in const [
        'SELECT 1 FROM dual',
        withSelect,
        '  /* c */ WITH c AS (SELECT 1 FROM dual) SELECT x FROM c',
      ]) {
        expect(isQuerySql(sql) && !isCacheEligibleSql(sql), isFalse,
            reason: 'drift detected for: $sql');
      }
    });
  });
}
