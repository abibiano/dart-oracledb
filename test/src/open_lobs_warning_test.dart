/// DW-123: a one-shot warning once fetched LOB handles pile up on a connection.
library;

import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:oracledb/oracledb.dart';
import 'package:oracledb/src/protocol/lob_locator.dart';
import 'package:oracledb/src/transport/transport.dart';
import 'package:test/test.dart';

LobLocator _locator() => LobLocator(
  locator: Uint8List(40),
  oracleType: 113,
  length: 0,
  chunkSize: 0,
);

void main() {
  test(
    'warns exactly once when open fetched handles pass the threshold',
    () async {
      final conn = OracleConnection.forTesting(transport: Transport());
      final records = <LogRecord>[];
      final oldLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger('OracleConnection').onRecord.listen(records.add);
      addTearDown(() {
        sub.cancel();
        Logger.root.level = oldLevel;
      });

      conn.debugRegisterLob(_locator(), createdTemporary: true);
      OracleLob? lastFetched;
      for (var i = 0; i < OracleConnection.openLobsWarnThreshold; i++) {
        lastFetched = conn.debugRegisterLob(_locator());
      }
      expect(records.where((r) => r.level == Level.WARNING), isEmpty);

      await lastFetched!.close();
      conn.debugRegisterLob(_locator());
      expect(records.where((r) => r.level == Level.WARNING), isEmpty);
      conn.debugRegisterLob(_locator());
      final warnings = records.where((r) => r.level == Level.WARNING).toList();
      expect(warnings, hasLength(1));
      expect(warnings.single.message, contains('close()'));
    },
  );

  test('closing a TEMPORARY fetched handle (an ABSTRACT expression LOB or an '
      'IN OUT replacement) decrements the fetched-handle count', () async {
    // `_registerLob` counts every fetched handle; the release used to skip the
    // decrement for a temporary one, so each closed `TO_CLOB(...)` handle
    // (temporary since DW-122) would have drifted the count upward until a
    // spurious warning fired with nothing open.
    final conn = OracleConnection.forTesting(transport: Transport());
    final records = <LogRecord>[];
    final oldLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final sub = Logger('OracleConnection').onRecord.listen(records.add);
    addTearDown(() {
      sub.cancel();
      Logger.root.level = oldLevel;
    });

    LobLocator abstractLocator() => LobLocator(
      locator: Uint8List(40)..[4] = 0xC2,
      oracleType: 112,
      length: 0,
      chunkSize: 0,
    );
    LobLocator tempFlagged() => LobLocator(
      locator: Uint8List(40)..[7] = 0x01,
      oracleType: 113,
      length: 0,
      chunkSize: 0,
    );
    for (var i = 0; i < OracleConnection.openLobsWarnThreshold; i++) {
      final lob = conn.debugRegisterLob(
        i.isEven ? abstractLocator() : tempFlagged(),
      );
      expect(lob.isTemporary, isTrue);
      await lob.close();
    }
    // Every handle above was closed: one more open handle is nowhere near the
    // threshold, so nothing may warn.
    conn.debugRegisterLob(_locator());
    conn.debugRegisterLob(_locator());
    expect(records.where((r) => r.level == Level.WARNING), isEmpty);
  });
}
