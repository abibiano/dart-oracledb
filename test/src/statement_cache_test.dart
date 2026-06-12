import 'package:test/test.dart';

import 'package:oracledb/src/protocol/messages/execute_message.dart';
import 'package:oracledb/src/statement_cache.dart';

/// Bind-free key helper for the legacy exact-SQL tests.
StatementCacheKey _k(String sql) => StatementCacheKey.noBinds(sql);

void main() {
  group('StatementCache', () {
    group('constructor', () {
      test('accepts maxSize = 0 (disabled)', () {
        final cache = StatementCache(0);
        expect(cache.maxSize, equals(0));
        expect(cache.isEnabled, isFalse);
      });

      test('accepts positive maxSize', () {
        final cache = StatementCache(50);
        expect(cache.maxSize, equals(50));
        expect(cache.isEnabled, isTrue);
      });

      test('rejects negative maxSize with ArgumentError', () {
        expect(() => StatementCache(-1), throwsArgumentError);
        expect(() => StatementCache(-100), throwsArgumentError);
      });

      // Pathological sizes are rejected, never silently clamped.
      test('accepts maxSize exactly at maxStatementCacheSize cap', () {
        final cache = StatementCache(maxStatementCacheSize);
        expect(cache.maxSize, equals(maxStatementCacheSize));
      });

      test('rejects maxSize one above the cap with ArgumentError', () {
        expect(() => StatementCache(maxStatementCacheSize + 1),
            throwsArgumentError);
      });

      test('rejects pathological maxSize (1 << 31) with ArgumentError', () {
        expect(() => StatementCache(1 << 31), throwsArgumentError);
      });
    });

    group('acquire / store / release', () {
      test('returns null on cache miss', () {
        final cache = StatementCache(10);
        expect(cache.acquire(_k('SELECT 1 FROM dual')), isNull);
      });

      test('returns null when caching is disabled', () {
        final cache = StatementCache(0);
        final entry =
            StatementCacheEntry(key: _k('SELECT 1 FROM dual'), cursorId: 5);
        cache.store(entry);
        expect(cache.acquire(_k('SELECT 1 FROM dual')), isNull);
      });

      test('hit after store returns the entry and marks it inUse', () {
        final cache = StatementCache(10);
        final entry =
            StatementCacheEntry(key: _k('SELECT 1 FROM dual'), cursorId: 5);
        cache.store(entry);

        final hit = cache.acquire(_k('SELECT 1 FROM dual'));
        expect(hit, isNotNull);
        expect(hit!.cursorId, equals(5));
        expect(hit.inUse, isTrue);
      });

      test('second acquire returns null while entry is inUse', () {
        final cache = StatementCache(10);
        final entry =
            StatementCacheEntry(key: _k('SELECT 1 FROM dual'), cursorId: 5);
        cache.store(entry);

        cache.acquire(_k('SELECT 1 FROM dual')); // first acquirer holds it
        expect(cache.acquire(_k('SELECT 1 FROM dual')), isNull);
      });

      test('acquire available again after release', () {
        final cache = StatementCache(10);
        final entry =
            StatementCacheEntry(key: _k('SELECT 1 FROM dual'), cursorId: 5);
        cache.store(entry);

        final held = cache.acquire(_k('SELECT 1 FROM dual'))!;
        cache.release(held);

        final hit2 = cache.acquire(_k('SELECT 1 FROM dual'));
        expect(hit2, isNotNull);
        expect(hit2!.inUse, isTrue);
      });

      test('store with cursorId == 0 does not cache the entry', () {
        final cache = StatementCache(10);
        final entry = StatementCacheEntry(key: _k('SELECT 1 FROM dual'));
        cache.store(entry); // cursorId defaults to 0
        expect(cache.acquire(_k('SELECT 1 FROM dual')), isNull);
      });

      test('exact SQL string is part of the cache key (whitespace = miss)', () {
        final cache = StatementCache(10);
        final entry =
            StatementCacheEntry(key: _k('SELECT 1 FROM dual'), cursorId: 7);
        cache.store(entry);

        expect(cache.acquire(_k('SELECT  1 FROM dual')), isNull);
        expect(cache.acquire(_k('select 1 from dual')), isNull);
        expect(cache.acquire(_k('SELECT 1 FROM dual')), isNotNull);
      });
    });

    // The bind signature participates in cache identity.
    group('bind-signature keys', () {
      StatementCacheKey numberKey(String sql) => StatementCacheKey(sql, const [
            BindSlotSignature(oraType: 2, dir: BindDir.input), // NUMBER
          ]);
      StatementCacheKey varcharKey(String sql) => StatementCacheKey(sql, const [
            BindSlotSignature(oraType: 1, dir: BindDir.input), // VARCHAR2
          ]);

      test('same SQL with different bind signatures are separate entries', () {
        final cache = StatementCache(10);
        const sql = 'SELECT :1 AS VAL FROM DUAL';
        cache.store(StatementCacheEntry(key: numberKey(sql), cursorId: 11));
        cache.store(StatementCacheEntry(key: varcharKey(sql), cursorId: 22));

        expect(cache.size, equals(2),
            reason: 'distinct signatures must not collide on SQL text alone');

        final numberHit = cache.acquire(numberKey(sql));
        final varcharHit = cache.acquire(varcharKey(sql));
        expect(numberHit!.cursorId, equals(11));
        expect(varcharHit!.cursorId, equals(22));
      });

      test('a number-bind key does not hit a varchar-bind entry', () {
        final cache = StatementCache(10);
        const sql = 'SELECT :1 AS VAL FROM DUAL';
        cache.store(StatementCacheEntry(key: numberKey(sql), cursorId: 11));

        // Same SQL text, different bind type → must reparse (cache miss).
        expect(cache.acquire(varcharKey(sql)), isNull);
      });

      test('bind direction is part of the signature', () {
        const sql = 'BEGIN :1 := 1; END;'; // shape only — testing key identity
        final inKey = StatementCacheKey(
            sql, const [BindSlotSignature(oraType: 2, dir: BindDir.input)]);
        final outKey = StatementCacheKey(
            sql, const [BindSlotSignature(oraType: 2, dir: BindDir.output)]);
        expect(inKey == outKey, isFalse);
        expect(inKey.hashCode == outKey.hashCode, isFalse,
            reason: 'distinct directions should (practically) differ in hash');
      });

      test('declared max size participates in the signature', () {
        const sql = 'SELECT :1 FROM DUAL';
        final small = StatementCacheKey(sql, const [
          BindSlotSignature(oraType: 1, dir: BindDir.input, maxSize: 10)
        ]);
        final large = StatementCacheKey(sql, const [
          BindSlotSignature(oraType: 1, dir: BindDir.input, maxSize: 4000)
        ]);
        expect(small == large, isFalse);
      });

      test('value equality: identical keys are equal and hash equally', () {
        const sql = 'SELECT :1 FROM DUAL';
        final a = numberKey(sql);
        final b = numberKey(sql);
        expect(a == b, isTrue);
        expect(a.hashCode, equals(b.hashCode));
      });

      test(
          'LRU eviction stays deterministic across signatures, cursor queued '
          'exactly once', () {
        final cache = StatementCache(2);
        const sql = 'SELECT :1 FROM DUAL';
        cache.store(StatementCacheEntry(key: numberKey(sql), cursorId: 1));
        cache.store(StatementCacheEntry(key: varcharKey(sql), cursorId: 2));
        // Third distinct signature evicts the LRU (number, cursorId 1).
        final thirdKey = StatementCacheKey(sql,
            const [BindSlotSignature(oraType: 12, dir: BindDir.input)]); // DATE
        cache.store(StatementCacheEntry(key: thirdKey, cursorId: 3));

        expect(cache.size, equals(2));
        expect(cache.acquire(numberKey(sql)), isNull, reason: 'number evicted');
        final toClose = cache.drainCursorsToClose();
        expect(toClose, equals([1]),
            reason: 'evicted cursor queued exactly once');
      });
    });

    group('LRU recency refresh', () {
      test('acquire refreshes recency — later-used entry survives eviction',
          () {
        final cache = StatementCache(2);
        final e1 = StatementCacheEntry(key: _k('A'), cursorId: 1);
        final e2 = StatementCacheEntry(key: _k('B'), cursorId: 2);
        cache.store(e1);
        cache.store(e2);

        // Acquire A to refresh it to most-recently-used.
        final held = cache.acquire(_k('A'))!;
        cache.release(held);

        // Add C — should evict B (LRU), not A.
        final e3 = StatementCacheEntry(key: _k('C'), cursorId: 3);
        cache.store(e3);

        expect(cache.acquire(_k('A')), isNotNull, reason: 'A should survive');
        expect(cache.acquire(_k('B')), isNull, reason: 'B should be evicted');
        expect(cache.acquire(_k('C')), isNotNull, reason: 'C should be cached');
      });
    });

    group('LRU eviction order', () {
      test('oldest-inserted entry is evicted first', () {
        final cache = StatementCache(2);
        final e1 = StatementCacheEntry(key: _k('SQL1'), cursorId: 1);
        final e2 = StatementCacheEntry(key: _k('SQL2'), cursorId: 2);
        cache.store(e1);
        cache.store(e2);

        // size is 2 == maxSize; storing SQL3 must evict SQL1.
        final e3 = StatementCacheEntry(key: _k('SQL3'), cursorId: 3);
        cache.store(e3);

        expect(cache.size, equals(2));
        expect(cache.acquire(_k('SQL1')), isNull, reason: 'SQL1 evicted');
        expect(cache.acquire(_k('SQL2')), isNotNull);
        expect(cache.acquire(_k('SQL3')), isNotNull);
      });

      test('eviction queues cursor id for close', () {
        final cache = StatementCache(1);
        final e1 = StatementCacheEntry(key: _k('OLD'), cursorId: 99);
        cache.store(e1);

        final e2 = StatementCacheEntry(key: _k('NEW'), cursorId: 42);
        cache.store(e2); // evicts OLD (cursorId=99)

        final toClose = cache.drainCursorsToClose();
        expect(toClose, contains(99));
        expect(toClose, isNot(contains(42)));
      });

      test('drainCursorsToClose clears the queue', () {
        final cache = StatementCache(1);
        cache.store(StatementCacheEntry(key: _k('A'), cursorId: 1));
        cache.store(StatementCacheEntry(key: _k('B'), cursorId: 2));

        expect(cache.drainCursorsToClose(), isNotEmpty);
        expect(cache.drainCursorsToClose(), isEmpty);
      });

      test('evicted entry with cursorId == 0 does not queue for close', () {
        final cache = StatementCache(1);
        final e1 = StatementCacheEntry(key: _k('A'), cursorId: 10);
        final e2 = StatementCacheEntry(key: _k('B'), cursorId: 0);
        cache.store(e1); // stored (cursorId=10)
        cache.store(e2); // NOT stored (cursorId==0 guard)

        // e1 never got evicted because e2 was not stored.
        expect(cache.drainCursorsToClose(), isEmpty);
        expect(cache.size, equals(1)); // only e1
      });
    });

    group('invalidate', () {
      test('removes entry and queues cursor id for close', () {
        final cache = StatementCache(10);
        final entry = StatementCacheEntry(key: _k('BAD SQL'), cursorId: 77);
        cache.store(entry);

        cache.invalidate(_k('BAD SQL'));

        expect(cache.acquire(_k('BAD SQL')), isNull);
        expect(cache.drainCursorsToClose(), contains(77));
      });

      test('invalidate on missing key is a no-op', () {
        final cache = StatementCache(10);
        expect(() => cache.invalidate(_k('MISSING')), returnsNormally);
        expect(cache.drainCursorsToClose(), isEmpty);
      });

      test('double invalidate does not double-queue cursor id', () {
        final cache = StatementCache(10);
        cache.store(StatementCacheEntry(key: _k('S'), cursorId: 55));
        cache.invalidate(_k('S')); // removes from cache
        cache.invalidate(_k('S')); // entry already gone — no-op
        expect(cache.drainCursorsToClose(), equals([55]));
      });
    });

    // DDL invalidates the whole per-connection cache.
    group('invalidateAll', () {
      test('queues all non-inUse cursors and clears cache, stays usable', () {
        final cache = StatementCache(10);
        cache.store(StatementCacheEntry(key: _k('A'), cursorId: 1));
        cache.store(StatementCacheEntry(key: _k('B'), cursorId: 2));

        cache.invalidateAll();

        expect(cache.size, equals(0));
        expect(cache.drainCursorsToClose(), containsAll([1, 2]));
        // Still usable afterwards (unlike closeAll on a closing connection).
        cache.store(StatementCacheEntry(key: _k('C'), cursorId: 3));
        expect(cache.acquire(_k('C')), isNotNull);
      });

      test('inUse entry is dropped but its cursor is queued on later release',
          () {
        final cache = StatementCache(10);
        cache.store(StatementCacheEntry(key: _k('A'), cursorId: 5));
        final held = cache.acquire(_k('A'))!; // mark inUse

        cache.invalidateAll();
        expect(cache.drainCursorsToClose(), isNot(contains(5)),
            reason: 'in-use cursor not queued until released');

        cache.release(held); // returnToCache was cleared → queue now
        expect(cache.drainCursorsToClose(), contains(5));
      });
    });

    group('closeAll', () {
      test('queues all non-inUse cursors and clears cache', () {
        final cache = StatementCache(10);
        cache.store(StatementCacheEntry(key: _k('A'), cursorId: 1));
        cache.store(StatementCacheEntry(key: _k('B'), cursorId: 2));
        cache.store(StatementCacheEntry(key: _k('C'), cursorId: 3));

        cache.closeAll();

        expect(cache.size, equals(0));
        final toClose = cache.drainCursorsToClose();
        expect(toClose, containsAll([1, 2, 3]));
      });

      test('inUse entry is not queued for close by closeAll', () {
        final cache = StatementCache(10);
        cache.store(StatementCacheEntry(key: _k('A'), cursorId: 5));
        final held = cache.acquire(_k('A'))!; // mark inUse

        cache.closeAll();

        // held entry is inUse — closeAll should not queue it.
        final toClose = cache.drainCursorsToClose();
        expect(toClose, isNot(contains(held.cursorId)));
        expect(held.inUse, isTrue); // still held
      });
    });

    group('maxSize == 1 edge cases', () {
      test('stores and retrieves single entry', () {
        final cache = StatementCache(1);
        cache.store(StatementCacheEntry(key: _k('S'), cursorId: 9));
        expect(cache.acquire(_k('S')), isNotNull);
      });

      test('second store evicts first', () {
        final cache = StatementCache(1);
        cache.store(StatementCacheEntry(key: _k('A'), cursorId: 1));
        cache.store(StatementCacheEntry(key: _k('B'), cursorId: 2));
        expect(cache.acquire(_k('A')), isNull);
        expect(cache.acquire(_k('B')), isNotNull);
        expect(cache.drainCursorsToClose(), contains(1));
      });
    });
  });
}
