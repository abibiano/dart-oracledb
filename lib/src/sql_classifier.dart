/// SQL statement classification helpers used by [OracleConnection.execute].
///
/// These are package-internal functions; not part of the public API.
///
/// Story 7.3 contract:
///   - `skipSqlPrefixes` skips whitespace and comments. It does NOT skip
///     leading `(` — a SQL string that opens with `(` is treated as a
///     malformed prefix and classified as none of {query, PL/SQL, cache
///     eligible}. This prevents `(BEGIN ... END;)` from being misread as
///     PL/SQL and `(DELETE FROM t)` from being misread as DML.
///   - Line comments terminate on both `\n` and `\r` so CR-only line
///     endings (classic Mac, some hand-edited fixtures) do not swallow the
///     real statement that follows.
///   - `WITH` is no longer an unconditional query shortcut. CTE-backed DML
///     (`WITH cte AS (...) INSERT/UPDATE/DELETE/MERGE ...`) is detected by
///     scanning past the CTE header to the terminal verb at paren-depth 0.
///   - `MERGE` is recognized as a cache-eligible DML verb (parity with
///     INSERT/UPDATE/DELETE).
library;

/// Skips leading whitespace, block comments, and line comments.
///
/// Returns the offset of the first non-whitespace, non-comment character.
/// Leading `(` is intentionally NOT skipped — see library doc.
int skipSqlPrefixes(String sql, int pos) {
  final n = sql.length;
  while (pos < n) {
    final c = sql.codeUnitAt(pos);
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
      pos++;
    } else if (c == 0x2F && pos + 1 < n && sql.codeUnitAt(pos + 1) == 0x2A) {
      // Block comment: /* … */
      pos += 2;
      while (pos + 1 < n) {
        if (sql.codeUnitAt(pos) == 0x2A && sql.codeUnitAt(pos + 1) == 0x2F) {
          pos += 2;
          break;
        }
        pos++;
      }
      if (pos + 1 >= n) pos = n;
    } else if (c == 0x2D && pos + 1 < n && sql.codeUnitAt(pos + 1) == 0x2D) {
      // Line comment: -- … (terminates on LF OR CR)
      pos += 2;
      while (pos < n) {
        final ch = sql.codeUnitAt(pos);
        if (ch == 0x0A || ch == 0x0D) break;
        pos++;
      }
    } else {
      break;
    }
  }
  return pos;
}

/// True when [c] is a valid Oracle identifier continuation character
/// (`A–Z`, `a–z`, `0–9`, `_`, `$`, `#`). Anything else terminates a keyword.
bool _isIdentChar(int c) {
  return (c >= 0x41 && c <= 0x5A) || // A-Z
      (c >= 0x61 && c <= 0x7A) || // a-z
      (c >= 0x30 && c <= 0x39) || // 0-9
      c == 0x5F || // _
      c == 0x24 || // $
      c == 0x23; // #
}

/// True when [c] can start an Oracle identifier (letter, `_`, `$`, or `#`).
bool _isIdentStart(int c) {
  return (c >= 0x41 && c <= 0x5A) || // A-Z
      (c >= 0x61 && c <= 0x7A) || // a-z
      c == 0x5F || // _
      c == 0x24 || // $
      c == 0x23; // #
}

/// Matches [keyword] at [pos] in [sql] case-insensitively, requiring the
/// next character to be a non-identifier char or end-of-string (word boundary).
bool matchesKeyword(String sql, int pos, String keyword) {
  final n = sql.length;
  final klen = keyword.length;
  if (pos + klen > n) return false;
  for (var k = 0; k < klen; k++) {
    final c = sql.codeUnitAt(pos + k);
    final upper = (c >= 0x61 && c <= 0x7A) ? c - 0x20 : c;
    if (upper != keyword.codeUnitAt(k)) return false;
  }
  if (pos + klen == n) return true;
  return !_isIdentChar(sql.codeUnitAt(pos + klen));
}

/// Scans past a `WITH` CTE header to locate the terminal statement verb.
///
/// [pos] is the offset immediately after the `WITH` keyword. Returns the
/// offset of the first character of the terminal verb (`SELECT`, `INSERT`,
/// `UPDATE`, `DELETE`, or `MERGE`) at paren-depth 0, or `-1` if no
/// recognized verb is found before the end of [sql].
///
/// The scanner tracks paren depth and skips string literals (`'...'` with
/// `''` escapes), quoted identifiers (`"..."`), and SQL comments so they
/// cannot confuse the keyword search. It is deliberately not a full SQL
/// parser — just enough to traverse `WITH name [(...)] AS (...) [, ...]`
/// reliably for the CTE shapes Oracle accepts.
int _findCteTerminalVerb(String sql, int pos) {
  final n = sql.length;
  var depth = 0;
  while (pos < n) {
    final c = sql.codeUnitAt(pos);

    // Single-quoted string literal with '' escape sequence.
    if (c == 0x27) {
      pos++;
      while (pos < n) {
        if (sql.codeUnitAt(pos) == 0x27) {
          if (pos + 1 < n && sql.codeUnitAt(pos + 1) == 0x27) {
            // '' inside the literal: skip both quotes and continue.
            pos += 2;
            continue;
          }
          pos++;
          break;
        }
        pos++;
      }
      continue;
    }

    // Double-quoted identifier with "" escape sequence.
    if (c == 0x22) {
      pos++;
      while (pos < n) {
        if (sql.codeUnitAt(pos) == 0x22) {
          if (pos + 1 < n && sql.codeUnitAt(pos + 1) == 0x22) {
            pos += 2;
            continue;
          }
          pos++;
          break;
        }
        pos++;
      }
      continue;
    }

    // Line comment — stops on LF or CR.
    if (c == 0x2D && pos + 1 < n && sql.codeUnitAt(pos + 1) == 0x2D) {
      pos += 2;
      while (pos < n) {
        final ch = sql.codeUnitAt(pos);
        if (ch == 0x0A || ch == 0x0D) break;
        pos++;
      }
      continue;
    }

    // Block comment.
    if (c == 0x2F && pos + 1 < n && sql.codeUnitAt(pos + 1) == 0x2A) {
      pos += 2;
      while (pos + 1 < n) {
        if (sql.codeUnitAt(pos) == 0x2A && sql.codeUnitAt(pos + 1) == 0x2F) {
          pos += 2;
          break;
        }
        pos++;
      }
      if (pos + 1 >= n) pos = n;
      continue;
    }

    if (c == 0x28) {
      depth++;
      pos++;
      continue;
    }
    if (c == 0x29) {
      if (depth > 0) depth--;
      pos++;
      continue;
    }

    if (depth == 0 && _isIdentStart(c)) {
      if (matchesKeyword(sql, pos, 'SELECT')) return pos;
      if (matchesKeyword(sql, pos, 'INSERT')) return pos;
      if (matchesKeyword(sql, pos, 'UPDATE')) return pos;
      if (matchesKeyword(sql, pos, 'DELETE')) return pos;
      if (matchesKeyword(sql, pos, 'MERGE')) return pos;
      // Skip the rest of this identifier so we don't re-test mid-word.
      pos++;
      while (pos < n && _isIdentChar(sql.codeUnitAt(pos))) {
        pos++;
      }
      continue;
    }

    pos++;
  }
  return -1;
}

/// Returns true when [sql] is a SELECT or a `WITH ... SELECT` query.
///
/// CTE-backed DML (`WITH cte AS (...) INSERT/UPDATE/DELETE/MERGE ...`) is
/// classified by its terminal verb and reported as not-a-query so that
/// `OracleResult.rowsAffected` is populated for the execution.
bool isQuerySql(String sql) {
  final i = skipSqlPrefixes(sql, 0);
  if (i >= sql.length) return false;
  if (matchesKeyword(sql, i, 'SELECT')) return true;
  if (matchesKeyword(sql, i, 'WITH')) {
    final verb = _findCteTerminalVerb(sql, i + 'WITH'.length);
    if (verb < 0) return false;
    return matchesKeyword(sql, verb, 'SELECT');
  }
  return false;
}

/// Returns true when [sql] is a PL/SQL block: BEGIN, DECLARE, or CALL.
bool isPlSqlSql(String sql) {
  final i = skipSqlPrefixes(sql, 0);
  if (i >= sql.length) return false;
  if (matchesKeyword(sql, i, 'BEGIN')) return true;
  if (matchesKeyword(sql, i, 'DECLARE')) return true;
  if (matchesKeyword(sql, i, 'CALL')) return true;
  return false;
}

/// Returns true when [sql] is eligible for statement caching.
///
/// SELECT, `WITH ... SELECT`, INSERT, UPDATE, DELETE, MERGE, and
/// `WITH ... {INSERT|UPDATE|DELETE|MERGE}` are eligible. DDL and PL/SQL
/// (BEGIN, DECLARE, CALL) are not.
bool isCacheEligibleSql(String sql) {
  final i = skipSqlPrefixes(sql, 0);
  if (i >= sql.length) return false;
  if (matchesKeyword(sql, i, 'SELECT')) return true;
  if (matchesKeyword(sql, i, 'INSERT')) return true;
  if (matchesKeyword(sql, i, 'UPDATE')) return true;
  if (matchesKeyword(sql, i, 'DELETE')) return true;
  if (matchesKeyword(sql, i, 'MERGE')) return true;
  if (matchesKeyword(sql, i, 'WITH')) {
    final verb = _findCteTerminalVerb(sql, i + 'WITH'.length);
    if (verb < 0) return false;
    return matchesKeyword(sql, verb, 'SELECT') ||
        matchesKeyword(sql, verb, 'INSERT') ||
        matchesKeyword(sql, verb, 'UPDATE') ||
        matchesKeyword(sql, verb, 'DELETE') ||
        matchesKeyword(sql, verb, 'MERGE');
  }
  return false;
}
