import 'dart:collection';

import 'package:meta/meta.dart';

import 'protocol/messages/execute_message.dart';

/// Hard upper bound on the per-connection statement cache size.
///
/// A statement cache is fundamentally a pool of *open server cursors*: every
/// cached entry pins one Oracle cursor for reuse. Oracle limits simultaneously
/// open cursors per session with the `OPEN_CURSORS` init parameter (default 50
/// on a fresh database, a few thousand when tuned). A client cache larger than
/// `OPEN_CURSORS` cannot help — it just guarantees `ORA-01000: maximum open
/// cursors exceeded` — and an unbounded value (e.g. `1 << 31`) lets the
/// per-connection [LinkedHashMap] grow without practical limit and exhaust
/// memory long before it is useful.
///
/// 65535 is therefore a deliberate sanity ceiling, not a tuning recommendation:
/// it is far above any realistic `OPEN_CURSORS`, keeps the key/entry bookkeeping
/// bounded, and still leaves the value expressible in 16 bits for any future
/// wire use. Values above it are rejected with [ArgumentError] rather than
/// silently clamped, so a misconfiguration fails loudly at connect time.
const int maxStatementCacheSize = 65535;

/// One bind slot's contribution to a statement's cache identity.
///
/// Two executions of the *same* SQL text are only cursor-compatible when their
/// binds agree on type, direction, and any declared max size that affects the
/// server-side buffer the cursor was parsed with. Reusing a cursor parsed for a
/// NUMBER bind to run the same SQL with a VARCHAR2 bind is exactly what produces
/// `ORA-01007`, stale bind metadata, or silent coercion — so the slot signature
/// participates in the cache key instead of the raw SQL alone.
@immutable
class BindSlotSignature {
  /// Creates a bind slot signature.
  const BindSlotSignature({
    required this.oraType,
    required this.dir,
    this.maxSize,
  });

  /// Oracle wire-protocol type indicator for this slot.
  final int oraType;

  /// Declared bind direction (IN / OUT / IN OUT).
  final BindDir dir;

  /// Declared max buffer size, when the caller pinned one. `null` means the
  /// driver inferred a type-default size; a later non-null hint that changes
  /// the wire allocation therefore reparses rather than reusing the cursor.
  final int? maxSize;

  @override
  bool operator ==(Object other) =>
      other is BindSlotSignature &&
      other.oraType == oraType &&
      other.dir == dir &&
      other.maxSize == maxSize;

  @override
  int get hashCode => Object.hash(oraType, dir, maxSize);

  @override
  String toString() =>
      'BindSlotSignature(oraType: $oraType, dir: $dir, maxSize: $maxSize)';
}

/// Immutable composite cache identity: exact SQL text plus bind signature.
///
/// The SQL text is preserved verbatim — no whitespace, comment, or case
/// normalization (a cursor is parsed for the exact text Oracle saw). The bind
/// signature is an ordered list of per-slot [BindSlotSignature]s; an empty list
/// represents a bind-free statement. Equality and hashing are value-based and
/// deep over the signature so the key can back a [LinkedHashMap] directly.
@immutable
class StatementCacheKey {
  /// Creates a cache key for [sql] with the given ordered [bindSignature].
  StatementCacheKey(this.sql, List<BindSlotSignature> bindSignature)
      : bindSignature = List<BindSlotSignature>.unmodifiable(bindSignature),
        _hash = Object.hash(sql, Object.hashAll(bindSignature));

  /// Convenience key for a statement with no binds.
  StatementCacheKey.noBinds(String sql)
      : this(sql, const <BindSlotSignature>[]);

  /// Exact SQL text (never normalized).
  final String sql;

  /// Ordered per-slot bind signature; empty for bind-free statements.
  final List<BindSlotSignature> bindSignature;

  final int _hash;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! StatementCacheKey) return false;
    if (other.sql != sql) return false;
    final a = bindSignature;
    final b = other.bindSignature;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => _hash;

  @override
  String toString() => 'StatementCacheKey($sql, $bindSignature)';
}

/// An entry in the per-connection statement cache.
///
/// Tracks the server-assigned cursor id and (for SELECT) the column metadata
/// so that re-execution can skip the parse phase and avoid resending SQL bytes.
class StatementCacheEntry {
  StatementCacheEntry({
    required this.key,
    this.cursorId = 0,
    List<ColumnMetadata>? columnMetadata,
  }) : columnMetadata = columnMetadata ?? <ColumnMetadata>[];

  /// The composite cache key (exact SQL + bind signature) identifying this
  /// entry.
  final StatementCacheKey key;

  /// The exact SQL text used as part of the cache key.
  String get sql => key.sql;

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
/// Keyed by [StatementCacheKey] — exact SQL text plus bind signature, no
/// normalization or whitespace collapsing. LRU order is maintained by using
/// [LinkedHashMap] and doing a remove + reinsert on every cache hit (matching
/// node-oracledb thin behavior).
///
/// Evicted cursor ids are queued in [_cursorsToClose]; callers drain
/// this queue and piggyback the IDs onto the next execute to avoid ORA-01000.
class StatementCache {
  /// Creates a statement cache.
  ///
  /// [maxSize] = 0 disables caching; any positive value up to
  /// [maxStatementCacheSize] sets the capacity. Throws [ArgumentError] if
  /// [maxSize] is negative or exceeds [maxStatementCacheSize] — the bound
  /// is enforced here so production ([OracleConnection.connect]) and test-only
  /// ([OracleConnection.forTesting]) constructors cannot diverge.
  StatementCache(int maxSize) : _maxSize = _checkSize(maxSize);

  static int _checkSize(int maxSize) {
    if (maxSize < 0) {
      throw ArgumentError.value(maxSize, 'maxSize', 'must be >= 0');
    }
    if (maxSize > maxStatementCacheSize) {
      throw ArgumentError.value(maxSize, 'maxSize',
          'must be <= $maxStatementCacheSize (the maximum statement cache size)');
    }
    return maxSize;
  }

  final int _maxSize;
  final LinkedHashMap<StatementCacheKey, StatementCacheEntry> _entries =
      LinkedHashMap();
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

  /// Tries to acquire a cached entry for [key].
  ///
  /// On a cache hit for a non-in-use entry, removes and reinserts the entry
  /// to refresh LRU recency, marks it [inUse], and returns it.
  ///
  /// Returns `null` on a cache miss or if the matching entry is already [inUse].
  /// The caller must then execute with [cursorId] = 0. The busy entry's LRU
  /// position is NOT refreshed — a denied acquire doesn't count as a hit.
  StatementCacheEntry? acquire(StatementCacheKey key) {
    if (!isEnabled) return null;
    final entry = _entries[key];
    if (entry == null) return null;
    if (entry.inUse) {
      return null;
    }
    // Hit: refresh recency by removing and reinserting.
    _entries.remove(key);
    _entries[key] = entry;
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
    _entries.remove(entry.key); // Remove stale copy if present.
    _entries[entry.key] = entry;
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
      // Evicted while in use, or the cache was closed while this entry was held:
      // reclaim the cursor. Delegate to [invalidateEntry] so the identity-guarded
      // removal + always-queue logic lives in ONE place — critically, it removes
      // the cache slot ONLY if it still holds THIS entry (a newer same-key entry
      // stored during the in-use window is not collateral-evicted) while always
      // queuing this entry's own cursor so it can never leak.
      invalidateEntry(entry);
      entry.inUse = false;
    }
  }

  /// Removes [key] from the cache and queues its cursor id for close.
  ///
  /// Called when execution fails for a cached statement so the next attempt
  /// re-parses rather than reusing a potentially corrupt cursor.
  void invalidate(StatementCacheKey key) {
    final entry = _entries.remove(key);
    if (entry != null && entry.cursorId != 0) {
      _cursorsToClose.add(entry.cursorId);
    }
  }

  /// Invalidates a specific held [entry] after a failed result set / mid-stream
  /// error, queuing its cursor for close.
  ///
  /// Unlike [invalidate], which removes by key, this is identity-aware and is
  /// the correct primitive for the held-cursor close path:
  /// - it always queues [entry]'s OWN cursor id for close, so a held cursor is
  ///   reaped even when the entry was already removed by [closeAll] /
  ///   [invalidateAll] (where `invalidate(key)` would be a silent no-op); and
  /// - it drops the cache slot only if it still `identical`-holds [entry], so a
  ///   newer entry stored under the same key (re-execute after `invalidateAll`)
  ///   is never collateral-damaged.
  ///
  /// Mirrors node-oracledb's identity-keyed cursor tracking (statementCache.js
  /// `_addCursorToClose(statement)`).
  void invalidateEntry(StatementCacheEntry entry) {
    if (identical(_entries[entry.key], entry)) {
      _entries.remove(entry.key);
    }
    if (entry.cursorId != 0) {
      _cursorsToClose.add(entry.cursorId);
    }
  }

  /// Invalidates every cached statement, queuing all reusable cursor ids for
  /// close.
  ///
  /// Called after a successful DDL statement: DDL can alter the result shape or
  /// invalidate server-side cursors of *any* cached SELECT/DML, and there is no
  /// cheap way to map arbitrary SQL back to the schema objects it touches.
  /// Dropping the whole per-connection cache forces the next execution of each
  /// statement to reparse and re-DESCRIBE against the new shape rather than
  /// decode rows with stale metadata. Unlike [closeAll] this keeps the cache
  /// usable afterwards (the connection is not closing).
  void invalidateAll() {
    for (final entry in _entries.values) {
      if (entry.inUse) {
        // A concurrent execution still owns the cursor; release() queues it.
        entry.returnToCache = false;
      } else if (entry.cursorId != 0) {
        _cursorsToClose.add(entry.cursorId);
      }
    }
    _entries.clear();
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

  /// Number of cursor ids currently queued for close, without draining them.
  ///
  /// Used by the connection's close-cursor chunking and its test seam to
  /// observe the piggyback backlog.
  int get pendingCloseCount => _cursorsToClose.length;

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
      final key = _entries.keys.first;
      final evicted = _entries.remove(key)!;
      if (evicted.inUse) {
        // Cursor is still active; prevent it from returning to the cache.
        evicted.returnToCache = false;
      } else if (evicted.cursorId != 0) {
        _cursorsToClose.add(evicted.cursorId);
      }
    }
  }
}
