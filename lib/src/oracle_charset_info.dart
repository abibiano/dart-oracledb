import 'package:meta/meta.dart';

import 'errors.dart';

/// Immutable description of the character sets a physical [OracleConnection]
/// is talking to, detected once during connection startup (Story 10.1).
///
/// ## What this is — and is not — about
///
/// Oracle has two distinct character sets:
///
/// * the **database character set** ([databaseCharset], `NLS_CHARACTERSET`)
///   governs `VARCHAR2`, `CHAR`, and `CLOB`; and
/// * the **national character set** ([nationalCharset],
///   `NLS_NCHAR_CHARACTERSET`) governs `NCHAR`, `NVARCHAR2`, and `NCLOB`.
///
/// This driver follows node-oracledb's Thin model: **primary character data
/// always travels the wire as UTF-8 (AL32UTF8) and the database server
/// performs any required conversion to/from its own database character set.**
/// This object therefore does *not* select a client codec and does *not* make
/// primary text encoding configurable — it is a connection-level diagnostic
/// fact that later Epic 10 stories build on.
///
/// In particular [supportsNationalCharacterSet] is about NCHAR/NVARCHAR2/NCLOB
/// support only; normal VARCHAR2/CHAR/CLOB data is unaffected by it and works
/// regardless of the national character set.
@immutable
class OracleCharsetInfo {
  /// Creates a charset-capability record from already-normalized
  /// (uppercase, non-empty) character-set names.
  ///
  /// Prefer [OracleCharsetInfo.fromParameterRows] when building from raw
  /// `NLS_DATABASE_PARAMETERS` query rows — it normalizes and validates them.
  const OracleCharsetInfo({
    required this.databaseCharset,
    required this.nationalCharset,
  });

  /// The server's `NLS_CHARACTERSET` — the database character set that governs
  /// `VARCHAR2`, `CHAR`, and `CLOB` columns (e.g. `AL32UTF8`, `WE8MSWIN1252`).
  ///
  /// Normalized to uppercase (the canonical form Oracle reports). Informational
  /// only: this driver keeps primary character data on the UTF-8 wire path and
  /// relies on the server to convert to/from this character set.
  final String databaseCharset;

  /// The server's `NLS_NCHAR_CHARACTERSET` — the national character set that
  /// governs `NCHAR`, `NVARCHAR2`, and `NCLOB` columns.
  ///
  /// Normalized to uppercase. Thin mode supports exactly one national character
  /// set, [supportedNationalCharset]; see [supportsNationalCharacterSet].
  final String nationalCharset;

  /// The `PARAMETER` value identifying the database character set in
  /// `NLS_DATABASE_PARAMETERS`.
  static const String dbCharsetParameter = 'NLS_CHARACTERSET';

  /// The `PARAMETER` value identifying the national character set in
  /// `NLS_DATABASE_PARAMETERS`.
  static const String nationalCharsetParameter = 'NLS_NCHAR_CHARACTERSET';

  /// The only national character set this Thin driver can round-trip for
  /// `NCHAR`/`NVARCHAR2`/`NCLOB` values (node-oracledb Thin parity).
  ///
  /// `UTF8` (the deprecated national charset) is *not* supported in Thin mode
  /// and reports incompatible — see [supportsNationalCharacterSet].
  static const String supportedNationalCharset = 'AL16UTF16';

  /// Whether [nationalCharset] is the supported [supportedNationalCharset]
  /// (`AL16UTF16`) target.
  ///
  /// `true` only for `AL16UTF16`; every other value — including `UTF8` — is
  /// `false`, because Thin mode cannot round-trip national types under them.
  ///
  /// This concerns NCHAR/NVARCHAR2/NCLOB support exclusively. It says nothing
  /// about normal VARCHAR2/CHAR/CLOB columns, which always work on the UTF-8
  /// wire path regardless of this flag. When `true`, NCHAR/NVARCHAR2/NCLOB
  /// values round-trip as UTF-16BE (Story 10.4); when `false`, the driver
  /// fails loud on any national-charset column or bind rather than risk silent
  /// corruption.
  bool get supportsNationalCharacterSet =>
      nationalCharset == supportedNationalCharset;

  /// Builds an [OracleCharsetInfo] from `NLS_DATABASE_PARAMETERS` rows.
  ///
  /// Each entry in [rows] is a `(PARAMETER, VALUE)` pair as returned by the
  /// startup detection query. Parameter names are matched case-insensitively;
  /// unrelated parameters are ignored. Values are trimmed and normalized to
  /// uppercase.
  ///
  /// Fails loud with an [OracleException] (ORA-protocol) rather than silently
  /// defaulting (Story 10.1 AC5) when the rows are missing or malformed:
  ///
  /// * either [dbCharsetParameter] or [nationalCharsetParameter] is absent;
  /// * a required parameter is present but blank/null; or
  /// * a required parameter appears more than once with conflicting values.
  ///
  /// Duplicate rows that agree on the value are tolerated (idempotent).
  factory OracleCharsetInfo.fromParameterRows(
    Iterable<MapEntry<String, String?>> rows,
  ) {
    final collected = <String, String>{};
    for (final row in rows) {
      final name = row.key.trim().toUpperCase();
      if (name != dbCharsetParameter && name != nationalCharsetParameter) {
        // Defensive: ignore parameters the query did not ask for.
        continue;
      }
      final rawValue = row.value?.trim();
      if (rawValue == null || rawValue.isEmpty) {
        // A present-but-blank value is malformed detection data — fail loud.
        throw OracleException(
          errorCode: oraProtocolError,
          message:
              'Charset detection returned a blank value for $name in '
              'NLS_DATABASE_PARAMETERS',
        );
      }
      final value = rawValue.toUpperCase();
      final existing = collected[name];
      if (existing != null && existing != value) {
        throw OracleException(
          errorCode: oraProtocolError,
          message:
              'Charset detection returned conflicting values for $name in '
              'NLS_DATABASE_PARAMETERS ("$existing" vs "$value")',
        );
      }
      collected[name] = value;
    }

    final db = collected[dbCharsetParameter];
    final nchar = collected[nationalCharsetParameter];
    if (db == null || nchar == null) {
      final missing = <String>[
        if (db == null) dbCharsetParameter,
        if (nchar == null) nationalCharsetParameter,
      ];
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'Charset detection did not return ${missing.join(' and ')} from '
            'NLS_DATABASE_PARAMETERS',
      );
    }
    return OracleCharsetInfo(databaseCharset: db, nationalCharset: nchar);
  }

  @override
  bool operator ==(Object other) =>
      other is OracleCharsetInfo &&
      other.databaseCharset == databaseCharset &&
      other.nationalCharset == nationalCharset;

  @override
  int get hashCode => Object.hash(databaseCharset, nationalCharset);

  @override
  String toString() =>
      'OracleCharsetInfo(databaseCharset: $databaseCharset, '
      'nationalCharset: $nationalCharset, '
      'supportsNationalCharacterSet: $supportsNationalCharacterSet)';
}
