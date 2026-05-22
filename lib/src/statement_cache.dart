import 'dart:collection';

import 'protocol/messages/execute_message.dart';

/// An entry in the per-connection statement cache.
///
/// Tracks the server-assigned cursor id and (for SELECT) the column metadata
/// so that re-execution can skip the parse phase and avoid resending SQL bytes.
class StatementCacheEntry {
  StatementCacheEntry({
    required this.sql,
    this.cursorId = 0,
    List<ColumnMetadata>? columnMetadata,
  }) : columnMetadata = columnMetadata ?? <ColumnMetadata>[];

  /// The exact SQL text used as the cache key.
  final String sql;

  /// Server-assigned cursor id (0 until first successful execution).
  int cursorId;

  /// Cached column metadata; populated for SELECT after first execution.
  List<ColumnMetadata> columnMetadata;

  /// Whether this entry is currently claimed by an active execution.
  bool inUse = false;

  /// Whether to return this entry to the cache after use.
  /// Set to false when the entry is evicted while still in use.
  bool returnToCache = true;
}

/// A per-connection LRU statement cache for Oracle cursor reuse.
///
/// Keyed by exact SQL text — no normalization, no whitespace collapsing.
/// LRU order is maintained by using [LinkedHashMap] and doing a remove +
/// reinsert on every cache hit (matching node-oracledb thin behavior).
///
/// Evicted cursor ids are queued in [_cursorsToClose]; callers drain
/// this queue and piggyback the IDs onto the next execute to avoid ORA-01000.
class StatementCache {
  /// Creates a statement cache.
  ///
  /// [maxSize] = 0 disables caching; any positive value sets the capacity.
  /// Throws [ArgumentError] if [maxSize] is negative.
  StatementCache(int maxSize)
      : _maxSize = maxSize >= 0
            ? maxSize
            : throw ArgumentError.value(maxSize, 'maxSize', 'must be >= 0');

  final int _maxSize;
  final LinkedHashMap<String, StatementCacheEntry> _entries = LinkedHashMap();
  // LinkedHashSet preserves insertion order AND de-duplicates cursor ids so a
  // pathological invalidate→store→evict sequence cannot enqueue the same id
  // twice (which would cause the server to fail the second close).
  final LinkedHashSet<int> _cursorsToClose = LinkedHashSet<int>();

  /// The configured maximum number of cached statements.
  int get maxSize => _maxSize;

  /// Whether caching is active (maxSize > 0).
  bool get isEnabled => _maxSize > 0;

  /// Number of entries currently held in the cache.
  int get size => _entries.length;

  /// Tries to acquire a cached entry for [sql].
  ///
  /// On a cache hit for a non-in-use entry, removes and reinserts the entry
  /// to refresh LRU recency, marks it [inUse], and returns it.
  ///
  /// Returns `null` on a cache miss or if the matching entry is already [inUse].
  /// The caller must then execute with [cursorId] = 0. The busy entry's LRU
  /// position is NOT refreshed — a denied acquire doesn't count as a hit.
  StatementCacheEntry? acquire(String sql) {
    if (!isEnabled) return null;
    final entry = _entries[sql];
    if (entry == null) return null;
    if (entry.inUse) {
      return null;
    }
    // Hit: refresh recency by removing and reinserting.
    _entries.remove(sql);
    _entries[sql] = entry;
    entry.inUse = true;
    return entry;
  }

  /// Stores a new or updated [entry] in the cache after a successful execution.
  ///
  /// No-op when caching is disabled or [entry.cursorId] == 0 (server did not
  /// assign a cursor — nothing reusable exists).
  /// Evicts the least recently used entry when [maxSize] is exceeded.
  void store(StatementCacheEntry entry) {
    if (!isEnabled || entry.cursorId == 0) return;
    _entries.remove(entry.sql); // Remove stale copy if present.
    _entries[entry.sql] = entry;
    _evictIfNeeded();
  }

  /// Returns [entry] to the cache after a successful execution.
  ///
  /// Marks the entry available for future callers. If [entry.returnToCache] is
  /// false (it was evicted while in use, or the cache was closed while it was
  /// held), the cursor is queued for close instead.
  void release(StatementCacheEntry entry) {
    if (entry.returnToCache) {
      entry.inUse = false;
    } else {
      _entries.remove(entry.sql);
      if (entry.cursorId != 0) {
        _cursorsToClose.add(entry.cursorId);
      }
      entry.inUse = false;
    }
  }

  /// Removes [sql] from the cache and queues its cursor id for close.
  ///
  /// Called when execution fails for a cached statement so the next attempt
  /// re-parses rather than reusing a potentially corrupt cursor.
  void invalidate(String sql) {
    final entry = _entries.remove(sql);
    if (entry != null && entry.cursorId != 0) {
      _cursorsToClose.add(entry.cursorId);
    }
  }

  /// Re-queues [cursorIds] for close after a failed flush attempt.
  ///
  /// Used by the execute path when `sendExecute` throws after the cursors
  /// were drained: the IDs never reached the server, so they must go back
  /// into the queue (deduplicated) and be retried on the next round trip.
  void requeueCursorsToClose(Iterable<int> cursorIds) {
    for (final id in cursorIds) {
      if (id != 0) {
        _cursorsToClose.add(id);
      }
    }
  }

  /// Removes and returns all queued cursor ids that must be closed.
  ///
  /// The caller piggybacks the IDs onto the next execute to avoid leaking
  /// server cursors after LRU eviction or execution error.
  List<int> drainCursorsToClose() {
    if (_cursorsToClose.isEmpty) return <int>[];
    final result = List<int>.of(_cursorsToClose);
    _cursorsToClose.clear();
    return result;
  }

  /// Clears the cache and queues all reusable cursor ids for close.
  ///
  /// Called from [OracleConnection.close]. For non-in-use entries the cursor
  /// id is queued so a final piggyback (if a request follows) can flush them.
  /// For in-use entries the map slot is dropped, but [returnToCache] is set
  /// to `false` so the eventual [release] call still queues the id rather
  /// than silently losing it.
  void closeAll() {
    for (final entry in _entries.values) {
      if (entry.inUse) {
        // Pending execution still owns the cursor; release() will queue it.
        entry.returnToCache = false;
      } else if (entry.cursorId != 0) {
        _cursorsToClose.add(entry.cursorId);
      }
    }
    _entries.clear();
  }

  void _evictIfNeeded() {
    while (_entries.length > _maxSize) {
      // LinkedHashMap iterates in insertion order — first key is LRU.
      final sql = _entries.keys.first;
      final evicted = _entries.remove(sql)!;
      if (evicted.inUse) {
        // Cursor is still active; prevent it from returning to the cache.
        evicted.returnToCache = false;
      } else if (evicted.cursorId != 0) {
        _cursorsToClose.add(evicted.cursorId);
      }
    }
  }
}
