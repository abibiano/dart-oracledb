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

    // AC2: an entry that is in-use — held open by a live lazy OracleResultSet —
    // must never have its server cursor closed out from under its owner by an
    // LRU eviction. The cursor close is deferred until the owner releases it.
    group('in-use LRU eviction safety (AC2)', () {
      test('evicting an in-use entry defers its close and clears returnToCache',
          () {
        final cache = StatementCache(1);
        cache.store(StatementCacheEntry(key: _k('A'), cursorId: 10));
        final held = cache.acquire(_k('A'))!; // A is now in-use
        expect(held.inUse, isTrue);
        expect(held.returnToCache, isTrue);

        // Storing B exceeds maxSize (1) and evicts A — but A is in-use, so its
        // cursor must NOT be queued for close yet.
        cache.store(StatementCacheEntry(key: _k('B'), cursorId: 20));
        expect(held.returnToCache, isFalse,
            reason: 'an evicted in-use entry is marked not-to-cache');
        expect(cache.drainCursorsToClose(), isEmpty,
            reason: 'the in-use cursor is not queued until its owner releases');
        expect(cache.acquire(_k('A')), isNull,
            reason: 'the evicted entry is no longer acquireable');

        // When the owner finally releases, the cursor is queued exactly once.
        cache.release(held);
        expect(held.inUse, isFalse);
        expect(cache.drainCursorsToClose(), equals([10]),
            reason: 'release queues the deferred cursor id exactly once');
      });

      test('a not-in-use entry evicted by the same store is queued immediately',
          () {
        final cache = StatementCache(1);
        cache.store(StatementCacheEntry(key: _k('A'), cursorId: 10));
        final held = cache.acquire(_k('A'))!;
        cache.release(held); // A back in cache, no longer in use

        cache.store(StatementCacheEntry(key: _k('B'), cursorId: 20)); // evicts A
        expect(cache.drainCursorsToClose(), equals([10]),
            reason: 'a not-in-use evicted cursor is queued immediately');
      });

      test('release of an in-use-evicted entry never double-queues its cursor',
          () {
        final cache = StatementCache(1);
        cache.store(StatementCacheEntry(key: _k('A'), cursorId: 10));
        final held = cache.acquire(_k('A'))!;
        cache.store(StatementCacheEntry(key: _k('B'), cursorId: 20)); // evicts A
        cache.release(held);

        expect(cache.drainCursorsToClose(), equals([10]));
        expect(cache.drainCursorsToClose(), isEmpty,
            reason: 'the deferred cursor id is queued exactly once');
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

    // A held cursor must be reaped by its OWN id and must never collateral-evict
    // a NEWER entry stored under the same key. Pins E4 (release identity guard)
    // and E2/E3 (invalidateEntry). Each contrasts the old buggy primitive with
    // the fix so the leak is demonstrated, not just the corrected behaviour.
    group('identity-safe cursor reclamation (E2/E3/E4)', () {
      test(
          'E4: release of a stale in-use-evicted entry reaps its own cursor and '
          'leaves a newer same-key entry intact', () {
        final cache = StatementCache(10);
        final stale = StatementCacheEntry(key: _k('A'), cursorId: 10);
        cache.store(stale);
        cache.acquire(_k('A')); // stale now inUse
        // Models "evicted while in use" (state proven reachable by the AC2 group
        // above); a concurrent re-execute then stores a NEWER live entry.
        stale.returnToCache = false;
        cache.store(StatementCacheEntry(key: _k('A'), cursorId: 20));

        cache.release(stale);

        // The stale cursor is reaped by its own id...
        expect(cache.drainCursorsToClose(), equals([10]));
        // ...and the newer live entry survives. Before the identity guard,
        // release() removed it by key and leaked its cursor (20).
        final live = cache.acquire(_k('A'));
        expect(live, isNotNull,
            reason: 'newer same-key entry must survive release of the stale one');
        expect(live!.cursorId, equals(20));
      });

      test('E2: invalidateEntry leaves a newer same-key entry intact', () {
        // Buggy path: invalidate(key) drops whatever is currently at the key —
        // the newer live entry — leaking its cursor instead of the held one.
        final buggy = StatementCache(10);
        buggy.store(StatementCacheEntry(key: _k('A'), cursorId: 10)); // stale
        buggy.store(StatementCacheEntry(key: _k('A'), cursorId: 20)); // newer
        buggy.invalidate(_k('A'));
        expect(buggy.acquire(_k('A')), isNull,
            reason: 'demonstrates E2: invalidate(key) evicts the newer entry');
        expect(buggy.drainCursorsToClose(), equals([20]),
            reason: 'and queues the WRONG (newer) cursor');

        // Fixed path: invalidateEntry reaps the held entry by identity.
        final fixed = StatementCache(10);
        final stale = StatementCacheEntry(key: _k('A'), cursorId: 10);
        fixed.store(stale);
        fixed.store(StatementCacheEntry(key: _k('A'), cursorId: 20)); // newer
        fixed.invalidateEntry(stale);
        expect(fixed.drainCursorsToClose(), equals([10]),
            reason: 'the held cursor is reaped by its own id');
        final live = fixed.acquire(_k('A'));
        expect(live, isNotNull,
            reason: 'invalidateEntry must not drop a newer same-key entry');
        expect(live!.cursorId, equals(20));
      });

      test('E3: invalidateEntry reaps the held cursor after closeAll removed it',
          () {
        // Buggy path: invalidate(key) after closeAll is a silent no-op — leak.
        final buggy = StatementCache(10);
        final a = StatementCacheEntry(key: _k('A'), cursorId: 10);
        buggy.store(a);
        buggy.acquire(_k('A')); // inUse → closeAll defers its close to release
        buggy.closeAll();
        buggy.invalidate(_k('A')); // entry already gone → no-op
        expect(buggy.drainCursorsToClose(), isEmpty,
            reason: 'demonstrates E3: invalidate(key) reaps nothing → leak');

        // Fixed path: invalidateEntry queues the held cursor by its own id.
        final fixed = StatementCache(10);
        final held = StatementCacheEntry(key: _k('A'), cursorId: 10);
        fixed.store(held);
        fixed.acquire(_k('A'));
        fixed.closeAll();
        expect(fixed.pendingCloseCount, equals(0));
        fixed.invalidateEntry(held);
        expect(fixed.drainCursorsToClose(), equals([10]),
            reason: 'invalidateEntry reaps the held cursor even when gone');
      });

      test(
          'invalidateEntry on the current entry removes it and queues '
          '(regression)', () {
        final cache = StatementCache(10);
        final entry = StatementCacheEntry(key: _k('A'), cursorId: 10);
        cache.store(entry);

        cache.invalidateEntry(entry);

        expect(cache.acquire(_k('A')), isNull,
            reason: 'the current entry is removed from the cache');
        expect(cache.drainCursorsToClose(), equals([10]));
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

      test('no stale in-use entry remains acquireable after invalidateAll', () {
        // AC6: invalidateAll drops in-use entries from the map immediately, so a
        // later acquire of the same key can never resurrect a stale cursor.
        final cache = StatementCache(10);
        cache.store(StatementCacheEntry(key: _k('A'), cursorId: 5));
        cache.acquire(_k('A')); // mark in-use
        cache.invalidateAll();
        expect(cache.acquire(_k('A')), isNull,
            reason: 'an invalidated in-use entry is no longer acquireable');
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
