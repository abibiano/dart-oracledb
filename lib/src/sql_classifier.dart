/// SQL statement classification helpers used by [OracleConnection.execute].
///
/// These are package-internal functions; not part of the public API.
///
/// Classification contract:
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
///
/// The depth-aware scanners recognize Oracle q-quote
/// (alternative quoting) literals — `q'[…]'`, `q'{…}'`, `q'(…)'`, `q'<…>'`,
/// and `q'X…X'` with any other delimiter — so an embedded raw `'` inside one
/// cannot break the CTE-header scan. National literals (`n'…'`, `nq'…'`)
/// remain unrecognized; their classification inside a CTE header is
/// undefined.
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

/// True when [c] is SQL whitespace (space, tab, LF, CR).
bool _isWhitespace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

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

/// If [pos] begins a string literal (`'...'`), q-quote literal
/// (`q'[…]'` and friends), quoted identifier (`"..."`), line comment
/// (`-- …`), or block comment (`/* … */`), returns the offset just past it;
/// otherwise returns [pos] unchanged.
///
/// Single shared skipper for every depth-aware scanner below so literals and
/// comments can never be mistaken for keywords — and so the skipping rules
/// (`''`/`""` escapes, q-quote delimiter pairs, CR-or-LF line-comment
/// termination, unterminated-block clamping) live in exactly one place.
///
/// National-character literals (`n'…'`, `nq'…'`) are NOT recognized here:
/// the identifier scan consumes the `n`/`nq` prefix and the remainder is
/// treated as an ordinary `'…'` literal, so an `nq` literal with an embedded
/// raw `'` can still mis-scan. They are vanishingly rare in CTE headers;
/// classification of such statements is undefined (plain q-quote only is
/// covered).
int _skipNonCode(String sql, int pos) {
  final n = sql.length;
  final c = sql.codeUnitAt(pos);

  // Oracle q-quote (alternative quoting) literal: q'X…X' where X is the
  // delimiter; `[ { ( <` pair with `] } ) >`, any other char closes with
  // itself. No escape sequence exists inside — the literal ends only at
  // closing-delimiter + quote, so an embedded raw ' is plain content.
  // Clamps to end-of-string when unterminated.
  if ((c == 0x71 || c == 0x51) && // q / Q
      pos + 2 < n &&
      sql.codeUnitAt(pos + 1) == 0x27) {
    final open = sql.codeUnitAt(pos + 2);
    final close = switch (open) {
      0x28 => 0x29, // ( )
      0x3C => 0x3E, // < >
      0x5B => 0x5D, // [ ]
      0x7B => 0x7D, // { }
      _ => open,
    };
    pos += 3;
    while (pos + 1 < n) {
      if (sql.codeUnitAt(pos) == close && sql.codeUnitAt(pos + 1) == 0x27) {
        return pos + 2;
      }
      pos++;
    }
    return n;
  }

  // Single-quoted string literal with '' escape sequence.
  if (c == 0x27) {
    pos++;
    while (pos < n) {
      if (sql.codeUnitAt(pos) == 0x27) {
        if (pos + 1 < n && sql.codeUnitAt(pos + 1) == 0x27) {
          pos += 2; // '' inside the literal: skip both quotes.
          continue;
        }
        return pos + 1;
      }
      pos++;
    }
    return pos;
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
        return pos + 1;
      }
      pos++;
    }
    return pos;
  }

  // Line comment — terminates on LF or CR.
  if (c == 0x2D && pos + 1 < n && sql.codeUnitAt(pos + 1) == 0x2D) {
    pos += 2;
    while (pos < n) {
      final ch = sql.codeUnitAt(pos);
      if (ch == 0x0A || ch == 0x0D) break;
      pos++;
    }
    return pos;
  }

  // Block comment — clamps to end-of-string when unterminated.
  if (c == 0x2F && pos + 1 < n && sql.codeUnitAt(pos + 1) == 0x2A) {
    pos += 2;
    while (pos + 1 < n) {
      if (sql.codeUnitAt(pos) == 0x2A && sql.codeUnitAt(pos + 1) == 0x2F) {
        return pos + 2;
      }
      pos++;
    }
    return n;
  }

  return pos;
}

/// Verbs that can appear directly at the head of a statement.
const List<String> _directVerbs = [
  'SELECT',
  'INSERT',
  'UPDATE',
  'DELETE',
  'MERGE',
  'BEGIN',
  'DECLARE',
  'CALL',
];

/// Verbs that can terminate a `WITH … ` CTE header.
const List<String> _cteVerbs = [
  'SELECT',
  'INSERT',
  'UPDATE',
  'DELETE',
  'MERGE',
];

/// Scans past a `WITH` CTE header to locate the terminal statement verb.
///
/// [pos] is the offset immediately after the `WITH` keyword. Returns the
/// offset of the first character of the terminal verb (`SELECT`, `INSERT`,
/// `UPDATE`, `DELETE`, or `MERGE`) at paren-depth 0, or `-1` if no
/// recognized verb is found before the end of [sql].
///
/// The scanner tracks paren depth and uses [_skipNonCode] to skip string
/// literals, quoted identifiers, and SQL comments so they cannot confuse the
/// keyword search. It is deliberately not a full SQL parser — just enough to
/// traverse `WITH name [(...)] AS (...) [, ...]` reliably.
int _findCteTerminalVerb(String sql, int pos) {
  final n = sql.length;
  var depth = 0;
  while (pos < n) {
    final skipped = _skipNonCode(sql, pos);
    if (skipped != pos) {
      pos = skipped;
      continue;
    }
    final c = sql.codeUnitAt(pos);
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
      for (final kw in _cteVerbs) {
        if (matchesKeyword(sql, pos, kw)) return pos;
      }
      // Skip the rest of this identifier so we don't re-test mid-word.
      pos++;
      while (pos < n && _isIdentChar(sql.codeUnitAt(pos))) {
        pos++;
      }
      continue;
    }
    // Explicit whitespace branch: space/tab/LF/CR are
    // consumed deliberately here, not via fallthrough, so a future early
    // exit added below cannot silently regress CR handling.
    if (_isWhitespace(c)) {
      pos++;
      continue;
    }
    // Any other character (operators, commas, digits, …) carries no
    // classification signal at this level — consume and move on.
    pos++;
  }
  return -1;
}

/// Resolves the effective leading verb of [sql] and the offset at which it
/// starts. Returns `(verb: '', pos: -1)` when nothing is recognized (including
/// a leading `(` — see library doc).
///
/// This is the single source of truth shared by [isQuerySql], [isPlSqlSql], and
/// [isCacheEligibleSql]: for `WITH … ` it resolves the CTE terminal verb
/// exactly once, so the three public helpers can never drift apart on how a SQL
/// shape is classified.
({String verb, int pos}) _leadingVerb(String sql) {
  final i = skipSqlPrefixes(sql, 0);
  if (i >= sql.length) return (verb: '', pos: -1);
  for (final kw in _directVerbs) {
    if (matchesKeyword(sql, i, kw)) return (verb: kw, pos: i);
  }
  if (matchesKeyword(sql, i, 'WITH')) {
    final v = _findCteTerminalVerb(sql, i + 'WITH'.length);
    if (v < 0) return (verb: '', pos: -1);
    for (final kw in _cteVerbs) {
      if (matchesKeyword(sql, v, kw)) return (verb: kw, pos: v);
    }
    return (verb: '', pos: -1);
  }
  return (verb: '', pos: -1);
}

/// Returns true when the SELECT body beginning at [pos] carries a top-level
/// `FOR UPDATE` clause.
///
/// Scans at paren-depth 0 (so `FOR UPDATE` inside a subquery, string literal, or
/// comment is ignored) for the keyword `FOR` immediately followed — across
/// whitespace/comments — by `UPDATE`. A top-level `FOR` only ever introduces the
/// row-locking clause in a SELECT, so the `FOR UPDATE` pair reliably identifies
/// a locking query.
bool _hasForUpdateClause(String sql, int pos) {
  final n = sql.length;
  var depth = 0;
  while (pos < n) {
    final skipped = _skipNonCode(sql, pos);
    if (skipped != pos) {
      pos = skipped;
      continue;
    }
    final c = sql.codeUnitAt(pos);
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
      if (matchesKeyword(sql, pos, 'FOR')) {
        final next = skipSqlPrefixes(sql, pos + 3);
        if (next < n && matchesKeyword(sql, next, 'UPDATE')) return true;
      }
      // Skip the rest of this identifier so we don't re-test mid-word.
      pos++;
      while (pos < n && _isIdentChar(sql.codeUnitAt(pos))) {
        pos++;
      }
      continue;
    }
    // Explicit whitespace branch — see _findCteTerminalVerb.
    if (_isWhitespace(c)) {
      pos++;
      continue;
    }
    pos++;
  }
  return false;
}

/// Returns true when [sql] is a SELECT or a `WITH ... SELECT` query.
///
/// CTE-backed DML (`WITH cte AS (...) INSERT/UPDATE/DELETE/MERGE ...`) is
/// classified by its terminal verb and reported as not-a-query so that
/// `OracleResult.rowsAffected` is populated for the execution. `SELECT ... FOR
/// UPDATE` is still a query (only its cache eligibility differs — see
/// [isCacheEligibleSql]).
bool isQuerySql(String sql) => _leadingVerb(sql).verb == 'SELECT';

/// Returns true when [sql] is a PL/SQL block: BEGIN, DECLARE, or CALL.
bool isPlSqlSql(String sql) {
  final verb = _leadingVerb(sql).verb;
  return verb == 'BEGIN' || verb == 'DECLARE' || verb == 'CALL';
}

/// Returns true when [sql] is eligible for statement caching.
///
/// SELECT, `WITH ... SELECT`, INSERT, UPDATE, DELETE, MERGE, and
/// `WITH ... {INSERT|UPDATE|DELETE|MERGE}` are eligible. DDL and PL/SQL
/// (BEGIN, DECLARE, CALL) are not.
///
/// `SELECT ... FOR UPDATE` is intentionally excluded. It remains a query
/// ([isQuerySql] is unchanged), but the locking clause is kept out of the cursor
/// cache so a reused cursor can never interact subtly with row-lock semantics.
/// Locking selects are rarely hot-looped, so reparsing each time costs little
/// while keeping correctness obvious. Shares [_leadingVerb] with the other
/// classifiers so the `WITH … SELECT` branch cannot drift.
bool isCacheEligibleSql(String sql) {
  final r = _leadingVerb(sql);
  if (r.verb.isEmpty) return false;
  if (r.verb == 'BEGIN' || r.verb == 'DECLARE' || r.verb == 'CALL') {
    return false;
  }
  if (r.verb == 'SELECT' && _hasForUpdateClause(sql, r.pos)) {
    return false; // SELECT ... FOR UPDATE excluded from caching.
  }
  return _cteVerbs.contains(r.verb);
}

/// Returns true when [sql] carries a DML `RETURNING ... INTO` clause — the
/// OUT-bind form of INSERT/UPDATE/DELETE/MERGE.
///
/// Scans at paren-depth 0 and uses [_skipNonCode] so a `RETURNING` or `INTO`
/// inside a subquery, string literal, quoted identifier, or comment is
/// ignored. Requires `RETURNING` to appear before an `INTO` at depth 0, so the
/// leading `INSERT INTO` cannot be mistaken for the clause (that `INTO`
/// precedes any `RETURNING`). Both are Oracle reserved words, so a
/// word-boundary match on non-literal text reliably identifies the clause.
bool hasReturningIntoClause(String sql) {
  final n = sql.length;
  var pos = 0;
  var depth = 0;
  var sawReturning = false;
  while (pos < n) {
    final skipped = _skipNonCode(sql, pos);
    if (skipped != pos) {
      pos = skipped;
      continue;
    }
    final c = sql.codeUnitAt(pos);
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
      if (!sawReturning && matchesKeyword(sql, pos, 'RETURNING')) {
        sawReturning = true;
      } else if (sawReturning && matchesKeyword(sql, pos, 'INTO')) {
        return true;
      }
      // Skip the rest of this identifier so we don't re-test mid-word.
      pos++;
      while (pos < n && _isIdentChar(sql.codeUnitAt(pos))) {
        pos++;
      }
      continue;
    }
    // Explicit whitespace branch — see _findCteTerminalVerb.
    if (_isWhitespace(c)) {
      pos++;
      continue;
    }
    pos++;
  }
  return false;
}

/// Bind tokens in the top-level DML `RETURNING ... INTO` target list, in SQL
/// order. The caller first establishes that this is a DML RETURNING statement.
/// Tokens are upper-cased because Oracle bind names are case-insensitive.
List<String> returningIntoBindTokens(String sql) {
  final tokens = <String>[];
  final n = sql.length;
  var pos = 0;
  var depth = 0;
  var sawReturning = false;
  var sawInto = false;
  while (pos < n) {
    final skipped = _skipNonCode(sql, pos);
    if (skipped != pos) {
      pos = skipped;
      continue;
    }
    final c = sql.codeUnitAt(pos);
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
      if (!sawReturning && matchesKeyword(sql, pos, 'RETURNING')) {
        sawReturning = true;
      } else if (sawReturning && !sawInto && matchesKeyword(sql, pos, 'INTO')) {
        sawInto = true;
      }
      pos++;
      while (pos < n && _isIdentChar(sql.codeUnitAt(pos))) {
        pos++;
      }
      continue;
    }
    if (sawInto && c == 0x3A && pos + 1 < n) {
      final next = sql.codeUnitAt(pos + 1);
      if (_isIdentStart(next) || (next >= 0x30 && next <= 0x39)) {
        final start = pos + 1;
        pos = start;
        while (pos < n && _isIdentChar(sql.codeUnitAt(pos))) {
          pos++;
        }
        tokens.add(sql.substring(start, pos).toUpperCase());
        continue;
      }
    }
    pos++;
  }
  return tokens;
}

/// For a DML `RETURNING ... INTO` statement, returns the first bind
/// placeholder token that appears BOTH before and after the (paren-depth-0)
/// `RETURNING` keyword, or null when no placeholder spans that boundary.
///
/// A placeholder before `RETURNING` is an input bind; a placeholder after it
/// is a `RETURNING ... INTO` target. The same placeholder cannot be both —
/// node-oracledb rejects it (NJS-149, statement.js `_addBind`). This scanner
/// mirrors that structural rule: named binds compare by name, positional
/// binds by number (both upper-cased for the named comparison). Placeholders
/// are recognized at any paren depth (INSERT `VALUES (:1)` nests them), but
/// the `RETURNING` boundary keyword is only recognized at depth 0. Literals,
/// comments, and quoted identifiers are skipped via [_skipNonCode], and a
/// `:=`/`::` is never treated as a placeholder.
///
/// Call only for SQL already known to carry a `RETURNING ... INTO` clause.
String? returningBindReusedName(String sql) {
  final n = sql.length;
  var pos = 0;
  var depth = 0;
  var afterReturning = false;
  // Upper-cased key (Oracle bind names are case-insensitive) → original-case
  // token, so the reported name reads like the SQL the caller wrote.
  final before = <String, String>{};
  final after = <String, String>{};
  while (pos < n) {
    final skipped = _skipNonCode(sql, pos);
    if (skipped != pos) {
      pos = skipped;
      continue;
    }
    final c = sql.codeUnitAt(pos);
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
    // Bind placeholder `:name` / `:1` — recognized at any depth. A `:=`
    // assignment or `::` cast is not a placeholder.
    if (c == 0x3A && pos + 1 < n) {
      final next = sql.codeUnitAt(pos + 1);
      if (_isIdentStart(next) || (next >= 0x30 && next <= 0x39)) {
        final start = pos + 1;
        var p = start;
        while (p < n && _isIdentChar(sql.codeUnitAt(p))) {
          p++;
        }
        final token = sql.substring(start, p);
        (afterReturning ? after : before)[token.toUpperCase()] = token;
        pos = p;
        continue;
      }
    }
    if (depth == 0 && _isIdentStart(c)) {
      if (!afterReturning && matchesKeyword(sql, pos, 'RETURNING')) {
        afterReturning = true;
      }
      pos++;
      while (pos < n && _isIdentChar(sql.codeUnitAt(pos))) {
        pos++;
      }
      continue;
    }
    pos++;
  }
  for (final entry in before.entries) {
    if (after.containsKey(entry.key)) return entry.value;
  }
  return null;
}
