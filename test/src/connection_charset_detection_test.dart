import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

/// Column metadata mirroring `SELECT parameter, value FROM
/// nls_database_parameters` — two VARCHAR2 columns.
const _nlsColumns = <ColumnMetadata>[
  ColumnMetadata(name: 'PARAMETER', oracleType: 1, maxLength: 128),
  ColumnMetadata(name: 'VALUE', oracleType: 1, maxLength: 128),
];

void main() {
  group('connection startup charset detection', () {
    test('charsetInfo throws StateError before detection runs (forTesting)',
        () {
      // forTesting bypasses connect(), so detection never runs. The getter must
      // fail loud rather than return a bogus default.
      final conn = OracleConnection.forTesting(transport: Transport());
      expect(() => conn.charsetInfo, throwsA(isA<StateError>()));
    });

    test('successful detection populates charsetInfo from the NLS query',
        () async {
      final t = _CharsetFakeTransport(
        ExecuteResponse(
          isSuccess: true,
          cursorId: 1,
          columnMetadata: _nlsColumns,
          rows: const [
            ['NLS_CHARACTERSET', 'AL32UTF8'],
            ['NLS_NCHAR_CHARACTERSET', 'AL16UTF16'],
          ],
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);

      await conn.detectCharsetInfoForTesting();

      expect(t.executeCalls, equals(1),
          reason: 'detection is a single round trip per physical connection');
      expect(conn.charsetInfo.databaseCharset, equals('AL32UTF8'));
      expect(conn.charsetInfo.nationalCharset, equals('AL16UTF16'));
      expect(conn.charsetInfo.supportsNationalCharacterSet, isTrue);
      // Detection left the connection open and reusable.
      expect(conn.isConnected, isTrue);
      expect(t.disconnectCalls, equals(0));
    });

    test('detection of an incompatible national charset still succeeds (UTF8)',
        () async {
      final t = _CharsetFakeTransport(
        ExecuteResponse(
          isSuccess: true,
          cursorId: 1,
          columnMetadata: _nlsColumns,
          rows: const [
            ['NLS_CHARACTERSET', 'AL32UTF8'],
            ['NLS_NCHAR_CHARACTERSET', 'UTF8'],
          ],
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);

      await conn.detectCharsetInfoForTesting();

      expect(conn.charsetInfo.nationalCharset, equals('UTF8'));
      expect(conn.charsetInfo.supportsNationalCharacterSet, isFalse,
          reason: 'UTF8 national charset is diagnosed as incompatible, not '
              'silently ignored');
      expect(conn.isConnected, isTrue);
    });

    test(
        'a detection query failure closes the connection before the error '
        'escapes', () async {
      final t = _CharsetFakeTransport(
        ExecuteResponse(
          isSuccess: false,
          errorCode: 942,
          errorMessage: 'ORA-00942: table or view does not exist',
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);

      await expectLater(
        conn.detectCharsetInfoForTesting(),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', 942)),
      );

      // AC5: the half-initialized connection must be torn down, not leaked.
      expect(t.disconnectCalls, greaterThanOrEqualTo(1),
          reason: 'transport must be disconnected on detection failure');
      expect(conn.isConnected, isFalse);
    });

    test(
        'detection failure on malformed rows (missing NLS_NCHAR_CHARACTERSET) '
        'closes the connection', () async {
      final t = _CharsetFakeTransport(
        ExecuteResponse(
          isSuccess: true,
          cursorId: 1,
          columnMetadata: _nlsColumns,
          // Only one of the two required parameters comes back.
          rows: const [
            ['NLS_CHARACTERSET', 'AL32UTF8'],
          ],
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);

      await expectLater(
        conn.detectCharsetInfoForTesting(),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraProtocolError)
            .having((e) => e.message, 'message',
                contains('NLS_NCHAR_CHARACTERSET'))),
      );
      expect(conn.isConnected, isFalse,
          reason: 'malformed detection data must fail loud and close the '
              'connection');
      expect(t.disconnectCalls, greaterThanOrEqualTo(1));
    });

    test('detection error message never contains connection credentials',
        () async {
      // The detection query carries no binds and no credentials; assert the
      // failure surface stays clean even on the error path.
      final t = _CharsetFakeTransport(
        ExecuteResponse(
          isSuccess: false,
          errorCode: 1031,
          errorMessage: 'ORA-01031: insufficient privileges',
        ),
      );
      final conn = OracleConnection.forTesting(transport: t);

      try {
        await conn.detectCharsetInfoForTesting();
        fail('expected detection to throw');
      } on OracleException catch (e) {
        expect(e.message, isNot(contains('password')));
        expect(e.message, isNot(contains('verifier')));
        expect(e.message, isNot(matches(RegExp('session.?key', caseSensitive: false))));
        expect(e.toString(), isNot(contains('password')));
        expect(e.toString(), isNot(contains('verifier')));
      }
    });
  });
}

/// Minimal [Transport] stand-in for startup charset-detection tests.
///
/// Returns a single canned [ExecuteResponse] for the detection query and
/// records whether the connection was disconnected (so cleanup-on-failure can
/// be asserted). [isConnected] starts `true` and flips to `false` once
/// [disconnect] runs, mirroring a real transport teardown.
class _CharsetFakeTransport extends Transport {
  _CharsetFakeTransport(this._response);

  final ExecuteResponse _response;
  bool _connected = true;
  int disconnectCalls = 0;
  int executeCalls = 0;

  @override
  bool get isConnected => _connected;

  @override
  bool get isCorrupted => false;

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _connected = false;
  }

  @override
  Future<ExecuteResponse> sendExecute(
    String sql, {
    required bool isQuery,
    bool isPlSql = false,
    List<Object?>? bindValues,
    List<String>? bindNames,
    List<BindMetadata>? bindMetadata,
    int prefetchRows = 50,
    Duration? timeout = const Duration(minutes: 2),
    int cursorId = 0,
    List<ColumnMetadata>? expectedColumns,
    List<int> cursorsToClose = const <int>[],
    bool preserveTimestampTimeZone = false,
  }) async {
    executeCalls++;
    return _response;
  }
}
