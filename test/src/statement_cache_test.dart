import 'package:test/test.dart';

import 'package:oracledb/src/statement_cache.dart';

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
    });

    group('acquire / store / release', () {
      test('returns null on cache miss', () {
        final cache = StatementCache(10);
        expect(cache.acquire('SELECT 1 FROM dual'), isNull);
      });

      test('returns null when caching is disabled', () {
        final cache = StatementCache(0);
        final entry =
            StatementCacheEntry(sql: 'SELECT 1 FROM dual', cursorId: 5);
        cache.store(entry);
        expect(cache.acquire('SELECT 1 FROM dual'), isNull);
      });

      test('hit after store returns the entry and marks it inUse', () {
        final cache = StatementCache(10);
        final entry =
            StatementCacheEntry(sql: 'SELECT 1 FROM dual', cursorId: 5);
        cache.store(entry);

        final hit = cache.acquire('SELECT 1 FROM dual');
        expect(hit, isNotNull);
        expect(hit!.cursorId, equals(5));
        expect(hit.inUse, isTrue);
      });

      test('second acquire returns null while entry is inUse', () {
        final cache = StatementCache(10);
        final entry =
            StatementCacheEntry(sql: 'SELECT 1 FROM dual', cursorId: 5);
        cache.store(entry);

        cache.acquire('SELECT 1 FROM dual'); // first acquirer holds it
        expect(cache.acquire('SELECT 1 FROM dual'), isNull);
      });

      test('acquire available again after release', () {
        final cache = StatementCache(10);
        final entry =
            StatementCacheEntry(sql: 'SELECT 1 FROM dual', cursorId: 5);
        cache.store(entry);

        final held = cache.acquire('SELECT 1 FROM dual')!;
        cache.release(held);

        final hit2 = cache.acquire('SELECT 1 FROM dual');
        expect(hit2, isNotNull);
        expect(hit2!.inUse, isTrue);
      });

      test('store with cursorId == 0 does not cache the entry', () {
        final cache = StatementCache(10);
        final entry = StatementCacheEntry(sql: 'SELECT 1 FROM dual');
        cache.store(entry); // cursorId defaults to 0
        expect(cache.acquire('SELECT 1 FROM dual'), isNull);
      });

      test('exact SQL string is the cache key (different whitespace = miss)',
          () {
        final cache = StatementCache(10);
        final entry =
            StatementCacheEntry(sql: 'SELECT 1 FROM dual', cursorId: 7);
        cache.store(entry);

        expect(cache.acquire('SELECT  1 FROM dual'), isNull);
        expect(cache.acquire('select 1 from dual'), isNull);
        expect(cache.acquire('SELECT 1 FROM dual'), isNotNull);
      });
    });

    group('LRU recency refresh', () {
      test('acquire refreshes recency — later-used entry survives eviction',
          () {
        final cache = StatementCache(2);
        final e1 = StatementCacheEntry(sql: 'A', cursorId: 1);
        final e2 = StatementCacheEntry(sql: 'B', cursorId: 2);
        cache.store(e1);
        cache.store(e2);

        // Acquire A to refresh it to most-recently-used.
        final held = cache.acquire('A')!;
        cache.release(held);

        // Add C — should evict B (LRU), not A.
        final e3 = StatementCacheEntry(sql: 'C', cursorId: 3);
        cache.store(e3);

        expect(cache.acquire('A'), isNotNull, reason: 'A should survive');
        expect(cache.acquire('B'), isNull, reason: 'B should be evicted');
        expect(cache.acquire('C'), isNotNull, reason: 'C should be cached');
      });
    });

    group('LRU eviction order', () {
      test('oldest-inserted entry is evicted first', () {
        final cache = StatementCache(2);
        final e1 = StatementCacheEntry(sql: 'SQL1', cursorId: 1);
        final e2 = StatementCacheEntry(sql: 'SQL2', cursorId: 2);
        cache.store(e1);
        cache.store(e2);

        // size is 2 == maxSize; storing SQL3 must evict SQL1.
        final e3 = StatementCacheEntry(sql: 'SQL3', cursorId: 3);
        cache.store(e3);

        expect(cache.size, equals(2));
        expect(cache.acquire('SQL1'), isNull, reason: 'SQL1 evicted');
        expect(cache.acquire('SQL2'), isNotNull);
        expect(cache.acquire('SQL3'), isNotNull);
      });

      test('eviction queues cursor id for close', () {
        final cache = StatementCache(1);
        final e1 = StatementCacheEntry(sql: 'OLD', cursorId: 99);
        cache.store(e1);

        final e2 = StatementCacheEntry(sql: 'NEW', cursorId: 42);
        cache.store(e2); // evicts OLD (cursorId=99)

        final toClose = cache.drainCursorsToClose();
        expect(toClose, contains(99));
        expect(toClose, isNot(contains(42)));
      });

      test('drainCursorsToClose clears the queue', () {
        final cache = StatementCache(1);
        cache.store(StatementCacheEntry(sql: 'A', cursorId: 1));
        cache.store(StatementCacheEntry(sql: 'B', cursorId: 2));

        expect(cache.drainCursorsToClose(), isNotEmpty);
        expect(cache.drainCursorsToClose(), isEmpty);
      });

      test('evicted entry with cursorId == 0 does not queue for close', () {
        final cache = StatementCache(1);
        // cursorId == 0 means never stored via store(); simulate via a fresh
        // entry where we bypass the store guard by using maxSize=0 trick —
        // actually just verify store() ignores cursorId==0 entries.
        final e1 = StatementCacheEntry(sql: 'A', cursorId: 10);
        final e2 = StatementCacheEntry(sql: 'B', cursorId: 0);
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
        final entry = StatementCacheEntry(sql: 'BAD SQL', cursorId: 77);
        cache.store(entry);

        cache.invalidate('BAD SQL');

        expect(cache.acquire('BAD SQL'), isNull);
        expect(cache.drainCursorsToClose(), contains(77));
      });

      test('invalidate on missing key is a no-op', () {
        final cache = StatementCache(10);
        expect(() => cache.invalidate('MISSING'), returnsNormally);
        expect(cache.drainCursorsToClose(), isEmpty);
      });

      test('double invalidate does not double-queue cursor id', () {
        final cache = StatementCache(10);
        cache.store(StatementCacheEntry(sql: 'S', cursorId: 55));
        cache.invalidate('S'); // removes from cache
        cache.invalidate('S'); // entry already gone — no-op
        expect(cache.drainCursorsToClose(), equals([55]));
      });
    });

    group('closeAll', () {
      test('queues all non-inUse cursors and clears cache', () {
        final cache = StatementCache(10);
        cache.store(StatementCacheEntry(sql: 'A', cursorId: 1));
        cache.store(StatementCacheEntry(sql: 'B', cursorId: 2));
        cache.store(StatementCacheEntry(sql: 'C', cursorId: 3));

        cache.closeAll();

        expect(cache.size, equals(0));
        final toClose = cache.drainCursorsToClose();
        expect(toClose, containsAll([1, 2, 3]));
      });

      test('inUse entry is not queued for close by closeAll', () {
        final cache = StatementCache(10);
        cache.store(StatementCacheEntry(sql: 'A', cursorId: 5));
        final held = cache.acquire('A')!; // mark inUse

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
        cache.store(StatementCacheEntry(sql: 'S', cursorId: 9));
        expect(cache.acquire('S'), isNotNull);
      });

      test('second store evicts first', () {
        final cache = StatementCache(1);
        cache.store(StatementCacheEntry(sql: 'A', cursorId: 1));
        cache.store(StatementCacheEntry(sql: 'B', cursorId: 2));
        expect(cache.acquire('A'), isNull);
        expect(cache.acquire('B'), isNotNull);
        expect(cache.drainCursorsToClose(), contains(1));
      });
    });
  });
}
