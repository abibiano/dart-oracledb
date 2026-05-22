/// SQL statement classification helpers used by [OracleConnection.execute].
///
/// These are package-internal functions; not part of the public API.
library;

/// Skips leading whitespace, block comments, line comments, and parentheses.
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
      // Line comment: -- …
      pos += 2;
      while (pos < n && sql.codeUnitAt(pos) != 0x0A) {
        pos++;
      }
    } else if (c == 0x28 /* ( */) {
      pos++;
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

/// Returns true when [sql] is a SELECT or WITH query.
bool isQuerySql(String sql) {
  final i = skipSqlPrefixes(sql, 0);
  if (i >= sql.length) return false;
  if (matchesKeyword(sql, i, 'SELECT')) return true;
  if (matchesKeyword(sql, i, 'WITH')) return true;
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
/// SELECT, WITH, INSERT, UPDATE, DELETE are eligible.
/// DDL and PL/SQL (BEGIN, DECLARE, CALL) are not.
bool isCacheEligibleSql(String sql) {
  if (isQuerySql(sql)) return true;
  final i = skipSqlPrefixes(sql, 0);
  if (i >= sql.length) return false;
  if (matchesKeyword(sql, i, 'INSERT')) return true;
  if (matchesKeyword(sql, i, 'UPDATE')) return true;
  if (matchesKeyword(sql, i, 'DELETE')) return true;
  return false;
}
