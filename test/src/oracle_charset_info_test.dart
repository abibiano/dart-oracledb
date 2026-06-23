import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

/// Convenience: build the `(PARAMETER, VALUE)` row iterable the detection query
/// produces, from a list of 2-tuples.
Iterable<MapEntry<String, String?>> rows(
  List<(String, String?)> pairs,
) =>
    pairs.map((p) => MapEntry(p.$1, p.$2));

void main() {
  group('OracleCharsetInfo', () {
    group('constants', () {
      test('supportedNationalCharset is AL16UTF16', () {
        expect(OracleCharsetInfo.supportedNationalCharset, equals('AL16UTF16'));
      });

      test('parameter names match NLS_DATABASE_PARAMETERS', () {
        expect(OracleCharsetInfo.dbCharsetParameter, equals('NLS_CHARACTERSET'));
        expect(OracleCharsetInfo.nationalCharsetParameter,
            equals('NLS_NCHAR_CHARACTERSET'));
      });
    });

    group('fromParameterRows — normal parsing', () {
      test('AL32UTF8 / AL16UTF16 parses and reports national support', () {
        final info = OracleCharsetInfo.fromParameterRows(rows([
          ('NLS_CHARACTERSET', 'AL32UTF8'),
          ('NLS_NCHAR_CHARACTERSET', 'AL16UTF16'),
        ]));
        expect(info.databaseCharset, equals('AL32UTF8'));
        expect(info.nationalCharset, equals('AL16UTF16'));
        expect(info.supportsNationalCharacterSet, isTrue);
      });

      test('a non-AL32UTF8 database charset still parses (diagnostic only)', () {
        // The database charset is informational; a single-byte DB charset is a
        // perfectly valid detection result. National support is independent.
        final info = OracleCharsetInfo.fromParameterRows(rows([
          ('NLS_CHARACTERSET', 'WE8MSWIN1252'),
          ('NLS_NCHAR_CHARACTERSET', 'AL16UTF16'),
        ]));
        expect(info.databaseCharset, equals('WE8MSWIN1252'));
        expect(info.supportsNationalCharacterSet, isTrue);
      });

      test('parameter names and values are normalized to uppercase', () {
        final info = OracleCharsetInfo.fromParameterRows(rows([
          ('nls_characterset', 'al32utf8'),
          ('Nls_Nchar_Characterset', 'al16utf16'),
        ]));
        expect(info.databaseCharset, equals('AL32UTF8'));
        expect(info.nationalCharset, equals('AL16UTF16'));
        expect(info.supportsNationalCharacterSet, isTrue);
      });

      test('values are trimmed before normalization', () {
        final info = OracleCharsetInfo.fromParameterRows(rows([
          ('NLS_CHARACTERSET', '  AL32UTF8  '),
          ('NLS_NCHAR_CHARACTERSET', ' AL16UTF16 '),
        ]));
        expect(info.databaseCharset, equals('AL32UTF8'));
        expect(info.nationalCharset, equals('AL16UTF16'));
      });

      test('unrelated NLS parameters are ignored', () {
        final info = OracleCharsetInfo.fromParameterRows(rows([
          ('NLS_LANGUAGE', 'AMERICAN'),
          ('NLS_CHARACTERSET', 'AL32UTF8'),
          ('NLS_TERRITORY', 'AMERICA'),
          ('NLS_NCHAR_CHARACTERSET', 'AL16UTF16'),
        ]));
        expect(info.databaseCharset, equals('AL32UTF8'));
        expect(info.nationalCharset, equals('AL16UTF16'));
      });
    });

    group('fromParameterRows — national charset compatibility', () {
      test('UTF8 national charset reports INCOMPATIBLE (Thin cannot use it)',
          () {
        final info = OracleCharsetInfo.fromParameterRows(rows([
          ('NLS_CHARACTERSET', 'AL32UTF8'),
          ('NLS_NCHAR_CHARACTERSET', 'UTF8'),
        ]));
        expect(info.nationalCharset, equals('UTF8'));
        expect(info.supportsNationalCharacterSet, isFalse,
            reason: 'UTF8 national charset is unsupported in Thin mode');
      });

      test('any non-AL16UTF16 national charset reports incompatible', () {
        final info = OracleCharsetInfo.fromParameterRows(rows([
          ('NLS_CHARACTERSET', 'AL32UTF8'),
          ('NLS_NCHAR_CHARACTERSET', 'AL32UTF8'),
        ]));
        expect(info.supportsNationalCharacterSet, isFalse);
      });
    });

    group('fromParameterRows — duplicate rows', () {
      test('duplicate identical rows are tolerated (idempotent)', () {
        final info = OracleCharsetInfo.fromParameterRows(rows([
          ('NLS_CHARACTERSET', 'AL32UTF8'),
          ('NLS_CHARACTERSET', 'AL32UTF8'),
          ('NLS_NCHAR_CHARACTERSET', 'AL16UTF16'),
          ('NLS_NCHAR_CHARACTERSET', 'AL16UTF16'),
        ]));
        expect(info.databaseCharset, equals('AL32UTF8'));
        expect(info.nationalCharset, equals('AL16UTF16'));
      });

      test('duplicate rows differing only by case are tolerated', () {
        final info = OracleCharsetInfo.fromParameterRows(rows([
          ('NLS_CHARACTERSET', 'AL32UTF8'),
          ('NLS_CHARACTERSET', 'al32utf8'),
          ('NLS_NCHAR_CHARACTERSET', 'AL16UTF16'),
        ]));
        expect(info.databaseCharset, equals('AL32UTF8'));
      });

      test('conflicting duplicate values fail loud', () {
        expect(
          () => OracleCharsetInfo.fromParameterRows(rows([
            ('NLS_CHARACTERSET', 'AL32UTF8'),
            ('NLS_CHARACTERSET', 'WE8MSWIN1252'),
            ('NLS_NCHAR_CHARACTERSET', 'AL16UTF16'),
          ])),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('conflicting'))),
        );
      });
    });

    group('fromParameterRows — missing / malformed (fail loud)', () {
      test('missing NLS_CHARACTERSET throws naming the parameter', () {
        expect(
          () => OracleCharsetInfo.fromParameterRows(rows([
            ('NLS_NCHAR_CHARACTERSET', 'AL16UTF16'),
          ])),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('NLS_CHARACTERSET'))),
        );
      });

      test('missing NLS_NCHAR_CHARACTERSET throws naming the parameter', () {
        expect(
          () => OracleCharsetInfo.fromParameterRows(rows([
            ('NLS_CHARACTERSET', 'AL32UTF8'),
          ])),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message',
                  contains('NLS_NCHAR_CHARACTERSET'))),
        );
      });

      test('empty row set throws naming both parameters', () {
        expect(
          () => OracleCharsetInfo.fromParameterRows(rows([])),
          throwsA(isA<OracleException>()
              .having((e) => e.message, 'message', contains('NLS_CHARACTERSET'))
              .having((e) => e.message, 'message',
                  contains('NLS_NCHAR_CHARACTERSET'))),
        );
      });

      test('a present-but-blank value is malformed and fails loud', () {
        expect(
          () => OracleCharsetInfo.fromParameterRows(rows([
            ('NLS_CHARACTERSET', '   '),
            ('NLS_NCHAR_CHARACTERSET', 'AL16UTF16'),
          ])),
          throwsA(isA<OracleException>()
              .having((e) => e.errorCode, 'errorCode', oraProtocolError)
              .having((e) => e.message, 'message', contains('blank'))),
        );
      });

      test('a null value is malformed and fails loud', () {
        expect(
          () => OracleCharsetInfo.fromParameterRows(rows([
            ('NLS_CHARACTERSET', 'AL32UTF8'),
            ('NLS_NCHAR_CHARACTERSET', null),
          ])),
          throwsA(isA<OracleException>()
              .having((e) => e.message, 'message', contains('blank'))),
        );
      });
    });

    group('const constructor + value semantics', () {
      test('default constructor reports support from the national charset', () {
        const compatible = OracleCharsetInfo(
            databaseCharset: 'AL32UTF8', nationalCharset: 'AL16UTF16');
        const incompatible = OracleCharsetInfo(
            databaseCharset: 'AL32UTF8', nationalCharset: 'UTF8');
        expect(compatible.supportsNationalCharacterSet, isTrue);
        expect(incompatible.supportsNationalCharacterSet, isFalse);
      });

      test('equality and hashCode are value-based', () {
        const a = OracleCharsetInfo(
            databaseCharset: 'AL32UTF8', nationalCharset: 'AL16UTF16');
        const b = OracleCharsetInfo(
            databaseCharset: 'AL32UTF8', nationalCharset: 'AL16UTF16');
        const c = OracleCharsetInfo(
            databaseCharset: 'WE8MSWIN1252', nationalCharset: 'AL16UTF16');
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
        expect(a, isNot(equals(c)));
      });

      test('toString surfaces all three diagnostic facts', () {
        const info = OracleCharsetInfo(
            databaseCharset: 'AL32UTF8', nationalCharset: 'AL16UTF16');
        final s = info.toString();
        expect(s, contains('AL32UTF8'));
        expect(s, contains('AL16UTF16'));
        expect(s, contains('supportsNationalCharacterSet: true'));
      });
    });
  });
}
