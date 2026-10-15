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
}
