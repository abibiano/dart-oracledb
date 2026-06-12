/// Utility for parsing bind placeholders from SQL statements.
///
/// Oracle uses `:name` for named binds and `:n` for positional binds.
/// This parser identifies placeholders while ignoring string literals.
library;

import '../errors.dart';

/// Parses bind parameter placeholders from SQL statements.
///
/// Supports two Oracle bind parameter styles:
/// - Named: `:name`, `:dept_id`, `:val1` (starts with letter)
/// - Positional: `:1`, `:2`, `:10` (pure numbers)
///
/// String literals are properly handled - placeholders inside quotes
/// are not matched.
class BindParser {
  /// Regex to match bind placeholders (not inside strings).
  /// Named: :name, :dept_id (letter followed by word chars)
  /// Positional: :1, :2, :10 (pure digits)
  static final _bindPattern = RegExp(r':([a-zA-Z]\w*|\d+)');

  /// Regex to detect string literals (to exclude from bind matching).
  /// Handles escaped quotes (doubled single quotes).
  static final _stringLiteral = RegExp(r"'(?:[^']|'')*'");

  /// Parses named bind placeholders from SQL.
  ///
  /// Returns list of placeholder names in order of appearance.
  /// If the same name appears multiple times, it will be in the list
  /// multiple times.
  ///
  /// Example:
  /// ```dart
  /// final binds = BindParser.parseNamedBinds(
  ///   'SELECT * FROM emp WHERE dept = :dept AND id = :id'
  /// );
  /// // Returns: ['dept', 'id']
  /// ```
  static List<String> parseNamedBinds(String sql) {
    // Remove string literals to avoid false matches
    final sanitized = sql.replaceAll(_stringLiteral, '');

    final matches = _bindPattern.allMatches(sanitized);
    final names = <String>[];

    for (final match in matches) {
      final name = match.group(1)!;
      // Named binds start with a letter
      if (name.isNotEmpty && !_isDigit(name[0])) {
        names.add(name);
      }
    }

    return names;
  }

  /// Parses positional bind placeholders from SQL.
  ///
  /// Returns the count of positional binds and validates they are sequential.
  /// Positional binds must start at `:1` and be sequential (`:1`, `:2`, `:3`...).
  ///
  /// Example:
  /// ```dart
  /// final count = BindParser.parsePositionalBinds(
  ///   'SELECT * FROM emp WHERE dept = :1 AND id = :2'
  /// );
  /// // Returns: 2
  /// ```
  ///
  /// Throws [OracleException] if positional binds are not sequential.
  static int parsePositionalBinds(String sql) {
    final sanitized = sql.replaceAll(_stringLiteral, '');

    final matches = _bindPattern.allMatches(sanitized);
    final positions = <int>{};

    for (final match in matches) {
      final name = match.group(1)!;
      // Positional binds are pure digits
      if (name.isNotEmpty && _isDigit(name[0])) {
        positions.add(int.parse(name));
      }
    }

    if (positions.isEmpty) return 0;

    // Validate sequential: should be 1, 2, 3, ... n
    final sorted = positions.toList()..sort();
    for (var i = 0; i < sorted.length; i++) {
      if (sorted[i] != i + 1) {
        throw OracleException(
          errorCode: oraBindMismatch,
          message: 'Positional bind parameters must be sequential starting '
              'from :1. Found: ${sorted.join(', ')}',
        );
      }
    }

    return positions.length;
  }

  /// Detects if SQL uses named binds (returns true) or positional (returns false).
  ///
  /// Returns `false` if SQL has no bind parameters.
  ///
  /// Throws [OracleException] if SQL mixes named and positional binds.
  static bool isNamedBinds(String sql) {
    final sanitized = sql.replaceAll(_stringLiteral, '');
    final matches = _bindPattern.allMatches(sanitized);

    bool hasNamed = false;
    bool hasPositional = false;

    for (final match in matches) {
      final name = match.group(1)!;
      if (name.isNotEmpty) {
        if (_isDigit(name[0])) {
          hasPositional = true;
        } else {
          hasNamed = true;
        }
      }
    }

    if (hasNamed && hasPositional) {
      throw const OracleException(
        errorCode: oraBindMismatch,
        message: 'Cannot mix named (:name) and positional (:1) bind parameters',
      );
    }

    return hasNamed;
  }

  /// Validates that the number of unique named bind placeholders in
  /// [bindNames] matches [providedValueCount].
  ///
  /// Used by [OracleConnection.execute] to surface ORA-01008 when the caller
  /// supplies the wrong number of values for a named-bind SQL — including
  /// PL/SQL blocks that legitimately reuse a placeholder name in multiple
  /// SQL positions (e.g. `BEGIN p(:a, :a); END;`). Duplicates collapse via
  /// `toSet()` so the comparison is against the count of *distinct* names.
  ///
  /// Exposed as a top-level static helper so unit tests can exercise the
  /// guard without opening a live Oracle session.
  static void validateNamedBindCount(
    List<String> bindNames,
    int providedValueCount,
  ) {
    final uniqueNames = bindNames.toSet();
    if (uniqueNames.length != providedValueCount) {
      throw OracleException(
        errorCode: oraBindMismatch,
        message: 'Bind parameter count mismatch: SQL has '
            '${uniqueNames.length} unique placeholders but '
            '$providedValueCount values provided',
      );
    }
  }

  /// Checks if a character is a digit (0-9).
  static bool _isDigit(String char) =>
      char.codeUnitAt(0) >= 48 && char.codeUnitAt(0) <= 57;
}
