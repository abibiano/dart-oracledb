/// Integration smoke test for the TTC sequence-counter wrap at 256.
///
/// Must pass against both supported environments:
///
///   RUN_INTEGRATION_TESTS=true dart test test/integration/sequence_wrap_integration_test.dart --no-color
///   RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/sequence_wrap_integration_test.dart --no-color
///
/// Background: the production wrap —
/// `Transport.nextSequence()` advances `(seq + 1) % 256`, cycling
/// `1…255, 0, 1…` byte-identical to node-oracledb `packet.js`
/// `writeSeqNum()` — and a unit test pins the full 257-call cycle. What was
/// never proven is that a REAL server accepts the wrapped sequence at message
/// 257+ on one long-lived connection (the pooled-connection case). These
/// tests drive 300+ sequential executes over a single connection, observe the
/// wrap through the `debugSequence` seam, and exercise post-wrap DML.
@Tags(['integration', 'slow'])
library;

import 'package:oracledb/oracledb.dart';
import 'package:test/test.dart';

import 'test_helper.dart';

void main() {
  if (!integrationEnabled) {
    test('skipped — set RUN_INTEGRATION_TESTS=true to run', () {}, skip: true);
    return;
  }

  group('Sequence counter wrap at 256 — live-server smoke', () {
    // Nullable handle assigned only once connect() succeeds; tearDown cleans
    // up null-safely. `conn` is the non-null alias used by test bodies.
    OracleConnection? connHandle;
    late OracleConnection conn;
    final testTable = uniqueTableName('seq_wrap');

    setUp(() async {
      connHandle = await connectForTest();
      conn = connHandle!;
      await _ignoreOraCodes(
        () => conn.execute(
          'CREATE TABLE $testTable (id NUMBER, v VARCHAR2(100))',
        ),
        const [955], // ORA-00955: name already used
      );
    });

    tearDown(() async {
      final c = connHandle;
      connHandle = null;
      // close() is guaranteed even if the DROP fails, and a close failure
      // never masks the DROP error.
      await cleanUpConnection(
        c,
        dropStatements: ['DROP TABLE $testTable PURGE'],
      );
    });

    test(
        '300+ sequential executes cross the sequence wrap without protocol '
        'corruption', () async {
      final samples = <int>[];
      for (var i = 1; i <= 300; i++) {
        final result = await conn.execute(
          'SELECT :v AS v FROM dual',
          {'v': i},
        );
        expect(result.rows.single['V'], equals(i),
            reason: 'bind round-trip corrupted at iteration $i '
                '(sequence counter now at ${conn.debugSequence})');
        samples.add(conn.debugSequence);
      }

      expect(
        samples,
        everyElement(allOf(greaterThanOrEqualTo(0), lessThanOrEqualTo(0xFF))),
        reason: 'sequence samples must stay within the one-byte 0..255 range',
      );
      expect(_hasDescent(samples), isTrue,
          reason: '300 executes advance the one-byte counter by more than '
              '256, so a descent (e.g. 255 -> 0) must appear in the samples; '
              'none did (first=${samples.first}, last=${samples.last}) — '
              'the counter never passed through the wrap');
      expect(_cumulativeModularAdvance(samples), greaterThanOrEqualTo(256),
          reason: 'the total forward (mod-256) advance across the sampled '
              'window must cover at least one full cycle — independent of '
              'how many sequence numbers a single execute consumes');
    });

    test('post-wrap mixed RPCs still work', () async {
      // Drive the counter through the wrap on THIS connection first. Each
      // execute advances the one-byte counter by at least one, so within 300
      // executes a descent must be observed; bail out as soon as it is.
      var previous = conn.debugSequence;
      var wrapped = false;
      for (var i = 1; i <= 300 && !wrapped; i++) {
        final result = await conn.execute(
          'SELECT :v AS v FROM dual',
          {'v': i},
        );
        expect(result.rows.single['V'], equals(i),
            reason: 'bind round-trip corrupted at iteration $i while driving '
                'the counter to the wrap '
                '(sequence counter now at ${conn.debugSequence})');
        final current = conn.debugSequence;
        wrapped = current < previous;
        previous = current;
      }
      expect(wrapped, isTrue,
          reason: 'the counter must wrap within 300 executes before the '
              'post-wrap DML phase can prove anything');

      // Post-wrap mixed RPC types on the same connection: INSERT with binds,
      // COMMIT, then SELECT the committed row back.
      final id = nextTestId();
      const value = 'post-wrap survivor';
      await conn.execute(
        'INSERT INTO $testTable (id, v) VALUES (:id, :v)',
        {'id': id, 'v': value},
      );
      await conn.commit();

      final readBack = await conn.execute(
        'SELECT v FROM $testTable WHERE id = :id',
        {'id': id},
      );
      expect(readBack.rows.single['V'], equals(value),
          reason: 'committed row must read back correctly after the wrap');
    });
  });
}

/// Returns true if any adjacent pair in [samples] descends — on a counter
/// that only ever advances within 0..255, a descent proves it passed through
/// the top of the byte range (the 256 wrap).
bool _hasDescent(List<int> samples) {
  for (var i = 0; i < samples.length - 1; i++) {
    if (samples[i + 1] < samples[i]) return true;
  }
  return false;
}

/// Sums the forward (mod-256) steps between adjacent samples. On a counter
/// that only ever advances, a total of >= 256 proves at least one full cycle
/// was traversed — a wrap proof that stays valid even if a single execute
/// consumes several sequence numbers (piggyback messages).
int _cumulativeModularAdvance(List<int> samples) {
  var total = 0;
  for (var i = 0; i < samples.length - 1; i++) {
    total += (samples[i + 1] - samples[i]) % 256;
  }
  return total;
}

Future<void> _ignoreOraCodes(
  Future<void> Function() fn,
  List<int> expectedCodes,
) async {
  try {
    await fn();
  } on OracleException catch (e) {
    if (!expectedCodes.contains(e.errorCode)) rethrow;
  }
}
