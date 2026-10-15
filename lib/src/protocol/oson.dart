/// OSON (Oracle binary JSON) support for the native `JSON` data type
/// (type 119, Oracle 21c+).
///
/// Ported from the bundled node-oracledb reference implementation:
/// `reference/node-oracledb/lib/impl/datahandlers/oson.js` (encoder/decoder)
/// and `reference/node-oracledb/lib/impl/datahandlers/constants.js` (format
/// constants). Both directions cover standard JSON (objects, arrays, strings,
/// numbers, booleans, null) plus the Oracle-specific OSON scalar kinds the
/// driver has a Dart type for, so every value the decoder produces binds back
/// as the same Dart type:
///
/// | Dart value                       | encoded node        | decoded as        |
/// | -------------------------------- | ------------------- | ----------------- |
/// | local `DateTime` (no sub-second part) | TIMESTAMP7 (7 B) | `DateTime`     |
/// | local `DateTime` (sub-second part) | TIMESTAMP (11 B)  | `DateTime`        |
/// | UTC `DateTime` (`isUtc`)         | TIMESTAMP_TZ (13 B, `+00:00`) | `OracleTimestampTz` |
/// | `OracleTimestampTz`              | TIMESTAMP_TZ (13 B) | `OracleTimestampTz` |
/// | `Uint8List`                      | binary (RAW)        | `Uint8List`       |
/// | out-of-NUMBER-range finite `double` | BINARY_DOUBLE    | `double`          |
/// | NaN / ±Infinity (opt-in only)    | BINARY_DOUBLE       | `double`          |
///
/// The node choices follow node-oracledb, with three Dart-driver differences:
/// a UTC `DateTime` keeps its zone (node-oracledb has no UTC-flagged date, so
/// it always writes the zone-less TIMESTAMP forms), ±Infinity and non-zero
/// doubles outside NUMBER's range travel as BINARY_DOUBLE (node-oracledb sends
/// only NaN that way), and non-finite numbers are rejected unless the bind
/// opts in with `allowNonFinite` (node-oracledb accepts NaN silently).
///
/// The decoder also maps DATE (→ `DateTime`) and BINARY_FLOAT (→ `double`)
/// nodes, which the encoder never emits (node-oracledb parity); the remaining
/// Oracle-specific kinds (intervals, JsonId, extended/VECTOR, unknown) fail
/// loud in both directions.
///
/// The encoder emits OSON **version 1** (field names ≤ 255 UTF-8 bytes), which
/// both Oracle 21c and 23ai accept, for every document whose field names fit.
/// A document holding a field name of 256..65535 UTF-8 bytes — which only an
/// Oracle 23ai (23.1+) server stores, and which the decoder reads back from a
/// version-3 document — is emitted as **version 3** with a second, long
/// field-names segment (node-oracledb `oson.js` `_writeExtendedHeader` /
/// `_writeFieldNamesSeg`), so a fetched document always re-binds on 23ai.
/// Such names fail loud for a pre-23 server instead (`allowLongFieldNames:
/// false`, node-oracledb's `_osonMaxFieldNameSize` of 255): Oracle 21c stores
/// a bound version-3 document without complaint but cannot read it back
/// (`JSON_SERIALIZE` raises ORA-40441, `JSON_VALUE` returns NULL even for its
/// short names). Field names over 65535 bytes always fail loud, in both the
/// validator and the encoder.
///
/// Containers may nest at most [maxJsonNestingDepth] levels (Oracle's
/// documented JSON limit); deeper and self-containing (cyclic) values fail
/// loud instead of recursing until the stack overflows.
///
/// [decodeJsonBlobBytes] covers JSON stored the Oracle 12c way — a `BLOB`
/// column with an `IS JSON` check constraint — routing OSON-magic bytes to
/// [decodeOson] and everything else through a text-JSON decode.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';
import '../oracle_timestamp_tz.dart';
import 'buffer.dart';
import 'constants.dart';
import 'data_types.dart' as dt;

// ============================================================================
// Format constants (TNS_JSON_* in node-oracledb constants.js)
// ============================================================================

const int _magic1 = 0xff;
const int _magic2 = 0x4a; // 'J'
const int _magic3 = 0x5a; // 'Z'

/// OSON version with field names up to 255 bytes.
const int _versionMaxFname255 = 1;

/// OSON version with field names up to 65535 bytes (Oracle 23.1+). The encoder
/// emits it only for a document holding a field name over 255 bytes.
const int _versionMaxFname65535 = 3;

// Primary header flags.
const int _flagRelOffsetMode = 0x01;
const int _flagInlineLeaf = 0x02;
const int _flagNumFnamesUint32 = 0x08;
const int _flagIsScalar = 0x10;
const int _flagHashIdUint8 = 0x0100;
const int _flagNumFnamesUint16 = 0x0400;
const int _flagFnamesSegUint32 = 0x0800;
const int _flagTreeSegUint32 = 0x1000;
const int _flagTinyNodesStat = 0x2000;

// Secondary header flags (version 3 only).
const int _flagSecFnamesSegUint16 = 0x100;

// Tree-segment node types.
const int _nodeNull = 0x30;
const int _nodeTrue = 0x31;
const int _nodeFalse = 0x32;
const int _nodeStringLenUint8 = 0x33;
const int _nodeNumberLenUint8 = 0x34;
const int _nodeBinaryDouble = 0x36;
const int _nodeStringLenUint16 = 0x37;
const int _nodeStringLenUint32 = 0x38;
const int _nodeTimestamp = 0x39;
const int _nodeBinaryLenUint16 = 0x3a;
const int _nodeBinaryLenUint32 = 0x3b;
const int _nodeDate = 0x3c;
const int _nodeIntervalYM = 0x3d;
const int _nodeIntervalDS = 0x3e;
const int _nodeExtended = 0x7b;
const int _nodeTimestampTz = 0x7c;
const int _nodeTimestamp7 = 0x7d;
const int _nodeId = 0x7e;
const int _nodeBinaryFloat = 0x7f;
const int _nodeObject = 0x84;
const int _nodeArray = 0xc0;

/// Maximum UTF-8 byte length of a "short" field name — the OSON version-1
/// limit every supported server accepts, and the limit for any field name on
/// a pre-23 server. A document whose field names all fit is encoded as
/// version 1, byte-identical to node-oracledb.
const int _maxShortFieldNameBytes = 255;

/// Maximum UTF-8 byte length of any field name (the OSON version-3 limit,
/// Oracle 23.1+). Longer names fail loud in the validator and the encoder.
const int _maxFieldNameBytes = 65535;

/// Maximum nesting depth of objects and arrays in a JSON bind value, counting
/// the root container as level 1 — Oracle's documented JSON nesting limit
/// (1000 levels). Deeper values, and cyclic ones (a container that contains
/// itself, which would nest forever), fail loud in both the validator and the
/// encoder instead of recursing until the stack overflows.
const int maxJsonNestingDepth = 1000;

// ============================================================================
// Bind-value validation (shared with the public OracleBind API)
// ============================================================================

/// The Dart value kinds a JSON bind accepts, named in validation and encoder
/// errors.
const String _supportedJsonKinds =
    'Map<String, Object?>, List<Object?>, String, num, bool, null, DateTime, '
    'OracleTimestampTz, Uint8List';

/// Validates that [value] is a supported JSON bind value, before any wire
/// work.
///
/// The root must be a `Map` with `String` keys, a `List`, or `null` — or,
/// when [allowScalarRoot] is set (the bind type was declared explicitly as
/// JSON: `OracleDbType.json`), any supported scalar. A declared-JSON `String`
/// root is a JSON **string scalar**, never parsed: `'{"a":1}'` binds as the
/// string `"{\"a\":1}"`, not as an object (bind the `Map` itself, not
/// `jsonEncode(map)`). Every nested member must be `null`, `bool`, `num`,
/// `String`, `DateTime`, `OracleTimestampTz`, `Uint8List`, a `Map` with
/// `String` keys, or a `List` — exactly the kinds [decodeOson] produces.
/// Dates and timestamps must fall in Oracle's AD range (years 1..9999), field
/// names must fit in 65535 UTF-8 bytes — in 255 bytes unless
/// [allowLongFieldNames] (the server is Oracle 23ai or later: the encoder then
/// emits OSON version 3) — and containers may nest at most
/// [maxJsonNestingDepth] levels with no container inside itself (a cycle).
///
/// Non-finite numbers (NaN, ±Infinity) are rejected unless [allowNonFinite]
/// is set (`OracleBind.inOut(..., allowNonFinite: true)`), in which case they
/// travel as BINARY_DOUBLE. Strict JSON has no such values, so a stray NaN
/// from an arithmetic bug fails at the call site instead of being stored.
/// Finite doubles outside Oracle NUMBER's range are always accepted (they
/// travel as BINARY_DOUBLE).
///
/// A `Uint8List` root is a scalar (the OSON binary node), not an array: it is
/// accepted only under [allowScalarRoot]. Type inference never routes bytes
/// here — a bare `Uint8List` bind stays RAW.
///
/// Returns the path of the first object holding a field name longer than 255
/// UTF-8 bytes (accepted under [allowLongFieldNames]), or `null` when every
/// name fits OSON version 1 — so a caller that validates before it knows the
/// server (an `OracleBind`) can later refuse a pre-23 server without walking
/// the document again.
///
/// Throws [ArgumentError] naming the offending member's path and runtime type
/// so the failure surfaces at the call site, not deep inside wire encoding.
/// [name] is the parameter name reported in the error and the root of the
/// path; below it, list elements appear by index (`[2]`) and object members
/// by 1-based position (`[member #3]`). The error never carries the bind
/// value — no member values and no object keys (the `OracleBind` redaction
/// policy): JSON documents routinely hold credentials and personal data.
String? assertValidJsonBindValue(
  Object? value,
  String name, {
  bool allowScalarRoot = false,
  bool allowNonFinite = false,
  bool allowLongFieldNames = true,
}) {
  if (value == null) return null;
  final isContainer = (value is Map || value is List) && value is! Uint8List;
  if (!isContainer && !allowScalarRoot) {
    throw ArgumentError(
      'JSON bind values must be Map<String, Object?>, List<Object?>, or '
      'null (got ${value.runtimeType}); declare the bind type as '
      'OracleDbType.json to bind a scalar JSON value',
      name,
    );
  }
  final validator = _JsonBindValidator(
    name,
    allowNonFinite: allowNonFinite,
    allowLongFieldNames: allowLongFieldNames,
  )..check(value);
  return validator.firstLongFieldNamePath;
}

/// The error for a field name over 255 UTF-8 bytes bound to a pre-23
/// server, at [where] (the path of the object holding it). Shared by the
/// validator and the connection's check of an already-validated `OracleBind`
/// value; the name itself is never echoed.
String longJsonFieldNameUnsupportedMessage(String where, [int? byteLength]) =>
    'JSON field names longer than $_maxShortFieldNameBytes UTF-8 bytes need '
    'Oracle Database 23ai or later (OSON version 3), and this server is older '
    '(${byteLength == null ? '' : 'got $byteLength bytes '}at $where)';

/// One validation walk of a JSON bind value (see [assertValidJsonBindValue]).
///
/// The member path is kept as a stack of segments and rendered only when an
/// error is thrown, so a valid document costs no path strings. The recursion
/// is bounded by [maxJsonNestingDepth]: [_open] holds the containers on the
/// current path, which both measures the depth and detects a cycle (a
/// container met again while it is still open is its own ancestor). A
/// container shared by two siblings (a DAG) is not a cycle and is accepted.
class _JsonBindValidator {
  _JsonBindValidator(
    this.name, {
    required this.allowNonFinite,
    required this.allowLongFieldNames,
  });

  final String name;
  final bool allowNonFinite;
  final bool allowLongFieldNames;

  /// Path of the first object holding a field name over 255 UTF-8 bytes.
  String? firstLongFieldNamePath;

  /// Path segments below the root: a list index (`>= 0`) or the negated
  /// 1-based ordinal of an object member (`< 0`).
  final List<int> _path = <int>[];

  /// Containers on the current path, by identity.
  final Set<Object> _open = HashSet<Object>.identity();

  /// The current path, e.g. `value[member #2][0]`. Object members appear by
  /// position, never by key: keys are document content too (an e-mail
  /// address, an account id) and must not reach error messages.
  String get _where {
    final out = StringBuffer(name);
    for (final segment in _path) {
      out.write(segment >= 0 ? '[$segment]' : '[member #${-segment}]');
    }
    return out.toString();
  }

  void check(Object? value) {
    if (value == null || value is bool || value is String) return;
    if (value is num) {
      // Finite values in NUMBER's range encode as NUMBER, other finite
      // values as BINARY_DOUBLE; NaN / ±Infinity only on opt-in. The message
      // names neither which non-finite value it was nor the number itself.
      if (!allowNonFinite && value is double && !value.isFinite) {
        throw ArgumentError(
          'JSON number is not finite (NaN or ±Infinity) at $_where; '
          'non-finite JSON numbers are rejected by default. Bind through '
          'OracleBind.inOut(type: OracleDbType.json, allowNonFinite: true) '
          'to send them as BINARY_DOUBLE',
          name,
        );
      }
      return;
    }
    if (value is DateTime) {
      final reason = _unsupportedYearReason(value.year);
      if (reason != null) {
        throw ArgumentError('JSON DateTime member $reason (at $_where)', name);
      }
      return;
    }
    if (value is OracleTimestampTz) {
      final reason = _unsupportedYearReason(value.utc.year);
      if (reason != null) {
        throw ArgumentError(
          'JSON OracleTimestampTz member $reason (at $_where)',
          name,
        );
      }
      return;
    }
    // Uint8List is a List<int>; check it before the generic List branch so it
    // stays one binary scalar instead of an array of numbers.
    if (value is Uint8List) return;
    if (value is List) {
      _enter(value);
      for (var i = 0; i < value.length; i++) {
        _path.add(i);
        check(value[i]);
        _path.removeLast();
      }
      _open.remove(value);
      return;
    }
    if (value is Map) {
      _enter(value);
      var ordinal = 0;
      for (final entry in value.entries) {
        ordinal++;
        final key = entry.key;
        if (key is! String) {
          throw ArgumentError(
            'JSON object keys must be String '
            '(got ${key.runtimeType} at $_where)',
            name,
          );
        }
        // Cheap pre-check: a UTF-16 code unit is at most 3 UTF-8 bytes.
        if (key.length * 3 > _maxShortFieldNameBytes) {
          final byteLength = utf8.encode(key).length;
          if (byteLength > _maxFieldNameBytes) {
            throw ArgumentError(
              'JSON field names longer than $_maxFieldNameBytes UTF-8 bytes '
              'are not supported (got $byteLength bytes at $_where)',
              name,
            );
          }
          if (byteLength > _maxShortFieldNameBytes) {
            if (!allowLongFieldNames) {
              throw ArgumentError(
                longJsonFieldNameUnsupportedMessage(_where, byteLength),
                name,
              );
            }
            firstLongFieldNamePath ??= _where;
          }
        }
        _path.add(-ordinal);
        check(entry.value);
        _path.removeLast();
      }
      _open.remove(value);
      return;
    }
    throw ArgumentError(
      'Unsupported JSON member type ${value.runtimeType} (at $_where). '
      'Supported: $_supportedJsonKinds',
      name,
    );
  }

  /// Opens [container] on the current path, failing on a cycle or on nesting
  /// beyond [maxJsonNestingDepth]. The error names the path of the container
  /// that closes the cycle (bounded by the depth limit) but not, for the depth
  /// error, the up-to-1000-segment path itself.
  void _enter(Object container) {
    if (_open.contains(container)) {
      throw ArgumentError(
        'JSON bind value is cyclic: the object or array at $_where contains '
        'itself (directly or through nested members)',
        name,
      );
    }
    if (_open.length >= maxJsonNestingDepth) {
      throw ArgumentError(
        'JSON bind value nests objects and arrays more than '
        '$maxJsonNestingDepth levels deep (Oracle\'s JSON nesting limit)',
        name,
      );
    }
    _open.add(container);
  }
}

/// Why a date/time member with this [year] cannot be encoded, or `null`
/// when it can. Oracle dates span years -4712..9999; BCE years are rejected
/// like the column codecs reject them, and years past 9999 have no valid
/// Oracle encoding (from year 25600 the century byte would not even fit in a
/// byte and would silently wrap). The year itself is deliberately left out
/// of the reason — it is part of the bind value.
String? _unsupportedYearReason(int year) {
  if (year < 1) return 'has a BCE year, which is not supported';
  if (year > 9999) return 'has a year beyond the Oracle maximum of 9999';
  return null;
}

// ============================================================================
// Encoder
// ============================================================================

/// Encodes a Dart JSON value into OSON bytes (modeled on node-oracledb
/// `oson.js` `encodeNode`). [value] may be a `Map<String, Object?>` or
/// `List<Object?>` document, or a scalar root, which travels as an OSON
/// scalar document.
///
/// Members encode as: `null` / `bool` / `String` as their JSON nodes; a `num`
/// as an Oracle NUMBER node when NUMBER can hold it (`0.0` / `-0.0`
/// included), otherwise as a BINARY_DOUBLE node — a finite non-zero magnitude
/// outside `[1E-130, 1E126)` always (a Dart-driver extension: node-oracledb
/// cannot bind those), NaN / ±Infinity only when [allowNonFinite] is set;
/// a local `DateTime` as TIMESTAMP7 (7 bytes) when it has no sub-second part,
/// else TIMESTAMP (11 bytes) — its local wall-clock fields, exactly like a
/// DATE / TIMESTAMP column bind; a UTC `DateTime` (`isUtc`) as TIMESTAMP WITH
/// TIME ZONE at offset `+00:00`, so its zone survives (it decodes back as an
/// `OracleTimestampTz` holding the same instant); `OracleTimestampTz` as
/// TIMESTAMP WITH TIME ZONE (13 bytes: UTC instant plus its reported offset;
/// a decoded region-id value reports `+00:00`);
/// `Uint8List` as a binary node (uint16 length, uint32 from 65536 bytes).
///
/// The document is OSON version 1 — byte-identical to node-oracledb — unless
/// a field name exceeds 255 UTF-8 bytes; then it is version 3 with a second
/// (long) field-names segment, which only Oracle 23ai reads. Pass
/// [allowLongFieldNames] `false` for a pre-23 server (node-oracledb
/// `_osonMaxFieldNameSize` 255): such a name then fails loud instead.
///
/// Throws [OracleException] (`oraUnsupportedType`) for unsupported member
/// types, non-`String` map keys, field names longer than 65535 UTF-8 bytes
/// (255 without [allowLongFieldNames]), dates outside years 1..9999,
/// containers nested deeper than [maxJsonNestingDepth] or containing
/// themselves (cyclic), and — unless [allowNonFinite] — NaN / ±Infinity. Bind
/// paths call [assertValidJsonBindValue] first, so these surface as call-site
/// `ArgumentError`s there; the encoder's own checks are the backstop for a
/// value mutated after it was validated.
Uint8List encodeOson(
  Object? value, {
  bool allowNonFinite = false,
  bool allowLongFieldNames = true,
}) => _OsonEncoder(
  allowNonFinite: allowNonFinite,
  allowLongFieldNames: allowLongFieldNames,
).encode(value);

/// Growable byte buffer with explicit big-endian writes and random-access
/// patching. [WriteBuffer] is append-only ([BytesBuilder]-backed), but the
/// OSON tree segment must reserve offset slots and patch them after child
/// nodes are written, so the encoder carries its own buffer (mirrors
/// node-oracledb's `GrowableBuffer`).
class _OsonWriteBuffer {
  Uint8List _buf = Uint8List(512);

  /// Number of bytes written so far (also the next write position).
  int pos = 0;

  void _ensure(int extra) {
    if (pos + extra <= _buf.length) return;
    var newLen = _buf.length * 2;
    while (newLen < pos + extra) {
      newLen *= 2;
    }
    final grown = Uint8List(newLen);
    grown.setRange(0, pos, _buf);
    _buf = grown;
  }

  void writeUint8(int value) {
    _ensure(1);
    _buf[pos++] = value & 0xff;
  }

  void writeUint16BE(int value) {
    _ensure(2);
    _buf[pos++] = (value >> 8) & 0xff;
    _buf[pos++] = value & 0xff;
  }

  void writeUint32BE(int value) {
    _ensure(4);
    _buf[pos++] = (value >> 24) & 0xff;
    _buf[pos++] = (value >> 16) & 0xff;
    _buf[pos++] = (value >> 8) & 0xff;
    _buf[pos++] = value & 0xff;
  }

  void writeBytes(List<int> bytes) {
    _ensure(bytes.length);
    _buf.setRange(pos, pos + bytes.length, bytes);
    pos += bytes.length;
  }

  /// Reserves [count] zeroed bytes and returns their start position.
  int reserve(int count) {
    _ensure(count);
    final start = pos;
    _buf.fillRange(start, start + count, 0);
    pos += count;
    return start;
  }

  void patchUint8(int at, int value) {
    _buf[at] = value & 0xff;
  }

  void patchUint16BE(int at, int value) {
    _buf[at] = (value >> 8) & 0xff;
    _buf[at + 1] = value & 0xff;
  }

  void patchUint32BE(int at, int value) {
    _buf[at] = (value >> 24) & 0xff;
    _buf[at + 1] = (value >> 16) & 0xff;
    _buf[at + 2] = (value >> 8) & 0xff;
    _buf[at + 3] = value & 0xff;
  }

  Uint8List toBytes() =>
      Uint8List.fromList(Uint8List.sublistView(_buf, 0, pos));
}

class _OsonFieldName {
  _OsonFieldName(this.name)
    : nameBytes = Uint8List.fromList(utf8.encode(name)),
      hash = 0 {
    if (nameBytes.length > _maxFieldNameBytes) {
      throw OracleException(
        errorCode: oraUnsupportedType,
        message:
            'JSON field names longer than $_maxFieldNameBytes UTF-8 '
            'bytes are not supported (got ${nameBytes.length} bytes)',
      );
    }
    hash = _hash(nameBytes);
  }

  final String name;
  final Uint8List nameBytes;

  /// FNV-1a 32-bit hash of [nameBytes], from which the OSON "hash ids" names
  /// are sorted and looked up by derive ([hashId], [longHashId]). The 32-bit
  /// intermediate state needs 64-bit int semantics (the multiply peaks near
  /// 2^56) — fine on every supported platform; this package does not target
  /// the web.
  int hash;

  /// The 8-bit OSON hash id of a short name: the low byte of [hash].
  int get hashId => hash & 0xff;

  /// The 16-bit OSON hash id of a long (version-3) name, as Oracle 23ai
  /// writes it big-endian: the low byte of [hash], then its second byte.
  /// Measured live: a server-encoded `IS JSON FORMAT OSON` document carries
  /// exactly these two bytes per long name and orders long names by this
  /// value (then byte length, then name) — and the server's own field
  /// lookups (`JSON_VALUE`, dot notation) binary-search on it, so a long
  /// name filed out of this order is not found server-side.
  int get longHashId => ((hash & 0xff) << 8) | ((hash >> 8) & 0xff);

  /// Whether this name lives in the version-3 long field-names segment.
  bool get isLong => nameBytes.length > _maxShortFieldNameBytes;

  /// Byte offset of this name inside its field names segment.
  int offset = 0;

  /// 1-based id used by object nodes in the tree segment.
  int fieldId = 0;

  static int _hash(Uint8List bytes) {
    var h = 0x811C9DC5;
    for (final b in bytes) {
      h = ((h ^ b) * 16777619) & 0xffffffff;
    }
    return h;
  }
}

/// One OSON field-names segment (node-oracledb `OsonFieldNamesSegment`): the
/// short segment (names ≤ 255 bytes, uint8 length prefix and hash id) or the
/// version-3 long segment (uint16 length prefix and 2-byte hash id).
class _OsonFieldNamesSegment {
  _OsonFieldNamesSegment({required this.long});

  /// Whether this is the version-3 long field-names segment.
  final bool long;

  /// Names in first-appearance order until [assignFieldIds] sorts them.
  final List<_OsonFieldName> names = <_OsonFieldName>[];

  /// The packed, length-prefixed name bytes (first-appearance order).
  final _OsonWriteBuffer bytes = _OsonWriteBuffer();

  /// Size of the packed name bytes.
  int get size => bytes.pos;

  /// Whether name offsets need uint32 slots (segment beyond 65535 bytes).
  bool get wideOffsets => bytes.pos > 65535;

  void add(_OsonFieldName fieldName) {
    fieldName.offset = bytes.pos;
    if (long) {
      bytes.writeUint16BE(fieldName.nameBytes.length);
    } else {
      bytes.writeUint8(fieldName.nameBytes.length);
    }
    bytes.writeBytes(fieldName.nameBytes);
    names.add(fieldName);
  }

  /// Sorts the names by hash id, then byte length, then UTF-16 code-unit
  /// name order, and numbers them from `firstId + 1` (long names follow
  /// every short name).
  ///
  /// The short segment sorts exactly like the reference
  /// (`_processFieldNames`) on the 8-bit [_OsonFieldName.hashId], so a
  /// version-1 document stays byte-identical to node-oracledb. The long
  /// segment sorts on the 16-bit [_OsonFieldName.longHashId] instead — the
  /// order Oracle 23ai itself writes and searches. node-oracledb and
  /// python-oracledb sort long names on the 8-bit id too, which files two
  /// long names sharing a low hash byte in length order; the server then
  /// cannot find one of them (`JSON_VALUE` returns NULL for it).
  void assignFieldIds(int firstId) {
    names.sort((a, b) {
      final aHash = long ? a.longHashId : a.hashId;
      final bHash = long ? b.longHashId : b.hashId;
      if (aHash != bHash) return aHash.compareTo(bHash);
      if (a.nameBytes.length != b.nameBytes.length) {
        return a.nameBytes.length.compareTo(b.nameBytes.length);
      }
      return a.name.compareTo(b.name);
    });
    for (var i = 0; i < names.length; i++) {
      names[i].fieldId = firstId + i + 1;
    }
  }

  /// Writes the hash-id array, then the name-offset array (both in sorted-id
  /// order), then the name bytes themselves.
  ///
  /// A long name's hash id is the 2-byte [_OsonFieldName.longHashId] — the
  /// layout Oracle 23ai itself writes (captured live from server-encoded
  /// `IS JSON FORMAT OSON` documents). node-oracledb writes the 8-bit id as a
  /// big-endian uint16 (`00 id`) and python-oracledb the FNV hash's low 16
  /// bits big-endian; this driver's decoder skips the array either way.
  void writeTo(_OsonWriteBuffer out) {
    for (final f in names) {
      if (long) {
        out.writeUint16BE(f.longHashId);
      } else {
        out.writeUint8(f.hashId);
      }
    }
    final wide = wideOffsets;
    for (final f in names) {
      if (wide) {
        out.writeUint32BE(f.offset);
      } else {
        out.writeUint16BE(f.offset);
      }
    }
    out.writeBytes(Uint8List.sublistView(bytes._buf, 0, bytes.pos));
  }
}

class _OsonEncoder {
  _OsonEncoder({
    required this.allowNonFinite,
    required this.allowLongFieldNames,
  });

  /// Whether NaN / ±Infinity may be encoded (as BINARY_DOUBLE).
  final bool allowNonFinite;

  /// Whether field names over 255 UTF-8 bytes may be encoded (OSON version
  /// 3, Oracle 23ai or later).
  final bool allowLongFieldNames;

  final _fieldNamesMap = <String, _OsonFieldName>{};
  final _shortNames = _OsonFieldNamesSegment(long: false);
  _OsonFieldNamesSegment? _longNames;
  final _treeSeg = _OsonWriteBuffer();
  int _fieldIdSize = 1;

  /// Containers on the [_examine] path, by identity (depth and cycle guard).
  final Set<Object> _open = HashSet<Object>.identity();

  Uint8List encode(Object? value) {
    final isContainer = (value is Map || value is List) && value is! Uint8List;

    var flags = _flagInlineLeaf;
    if (isContainer) {
      // _examine bounds the nesting depth and rejects cycles, so the
      // _encodeNode walk below — over the very same (synchronously
      // unchangeable) structure — recurses at most maxJsonNestingDepth deep.
      _examine(value);
      _shortNames.assignFieldIds(0);
      final numShort = _shortNames.names.length;
      _longNames?.assignFieldIds(numShort);
      final totalNames = numShort + (_longNames?.names.length ?? 0);
      flags |= _flagHashIdUint8 | _flagTinyNodesStat;
      if (totalNames > 65535) {
        flags |= _flagNumFnamesUint32;
        _fieldIdSize = 4;
      } else if (totalNames > 255) {
        flags |= _flagNumFnamesUint16;
        _fieldIdSize = 2;
      } else {
        _fieldIdSize = 1;
      }
      if (_shortNames.wideOffsets) {
        flags |= _flagFnamesSegUint32;
      }
    } else {
      flags |= _flagIsScalar;
    }

    _encodeNode(value);
    if (_treeSeg.pos > 65535) {
      flags |= _flagTreeSegUint32;
    }

    final longNames = _longNames;
    final out = _OsonWriteBuffer()
      ..writeUint8(_magic1)
      ..writeUint8(_magic2)
      ..writeUint8(_magic3)
      ..writeUint8(
        longNames == null ? _versionMaxFname255 : _versionMaxFname65535,
      )
      ..writeUint16BE(flags);

    if (isContainer) {
      // Extended header: number of short field names, then the size of the
      // short field names segment.
      final numShort = _shortNames.names.length;
      if (_fieldIdSize == 1) {
        out.writeUint8(numShort);
      } else if (_fieldIdSize == 2) {
        out.writeUint16BE(numShort);
      } else {
        out.writeUint32BE(numShort);
      }
      if (_shortNames.wideOffsets) {
        out.writeUint32BE(_shortNames.size);
      } else {
        out.writeUint16BE(_shortNames.size);
      }
      // Version 3 only: secondary flags, then the long names' count and
      // segment size (both always uint32).
      if (longNames != null) {
        out
          ..writeUint16BE(longNames.wideOffsets ? 0 : _flagSecFnamesSegUint16)
          ..writeUint32BE(longNames.names.length)
          ..writeUint32BE(longNames.size);
      }
    }

    if (_treeSeg.pos < 65536) {
      out.writeUint16BE(_treeSeg.pos);
    } else {
      out.writeUint32BE(_treeSeg.pos);
    }

    if (isContainer) {
      out.writeUint16BE(0); // number of "tiny" nodes (always zero)
      _shortNames.writeTo(out);
      longNames?.writeTo(out);
    }

    out.writeBytes(Uint8List.sublistView(_treeSeg._buf, 0, _treeSeg.pos));
    return out.toBytes();
  }

  /// Collects unique field names depth-first, registering each name before
  /// examining its value (reference `_examineNode` order — segment offsets
  /// depend on it). Names over 255 bytes go to the version-3 long segment.
  void _examine(Object? value) {
    // A Uint8List is one binary scalar, never an array to walk.
    if (value is Uint8List) return;
    if (value is List) {
      _enter(value);
      for (final element in value) {
        _examine(element);
      }
      _open.remove(value);
    } else if (value is Map) {
      _enter(value);
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) {
          throw OracleException(
            errorCode: oraUnsupportedType,
            message:
                'JSON object keys must be String '
                '(got ${key.runtimeType})',
          );
        }
        if (!_fieldNamesMap.containsKey(key)) {
          final fieldName = _OsonFieldName(key);
          _fieldNamesMap[key] = fieldName;
          if (fieldName.isLong) {
            if (!allowLongFieldNames) {
              throw OracleException(
                errorCode: oraUnsupportedType,
                message:
                    'JSON field names longer than $_maxShortFieldNameBytes '
                    'UTF-8 bytes need Oracle Database 23ai or later (OSON '
                    'version 3), and this server is older (got '
                    '${fieldName.nameBytes.length} bytes)',
              );
            }
            (_longNames ??= _OsonFieldNamesSegment(long: true)).add(fieldName);
          } else {
            _shortNames.add(fieldName);
          }
        }
        _examine(entry.value);
      }
      _open.remove(value);
    }
  }

  /// The encoder's own depth / cycle guard (see [maxJsonNestingDepth]).
  void _enter(Object container) {
    if (_open.contains(container)) {
      throw const OracleException(
        errorCode: oraUnsupportedType,
        message:
            'JSON value is cyclic: an object or array contains itself '
            '(directly or through nested members)',
      );
    }
    if (_open.length >= maxJsonNestingDepth) {
      throw const OracleException(
        errorCode: oraUnsupportedType,
        message:
            'JSON value nests objects and arrays more than '
            '$maxJsonNestingDepth levels deep (Oracle\'s JSON nesting limit)',
      );
    }
    _open.add(container);
  }

  void _encodeNode(Object? value) {
    if (value == null) {
      _treeSeg.writeUint8(_nodeNull);
    } else if (value is bool) {
      _treeSeg.writeUint8(value ? _nodeTrue : _nodeFalse);
    } else if (value is num) {
      if (dt.isOracleNumberRepresentable(value)) {
        final numberBytes = dt.encodeNumber(value);
        _treeSeg.writeUint8(_nodeNumberLenUint8);
        _treeSeg.writeUint8(numberBytes.length);
        _treeSeg.writeBytes(numberBytes);
      } else {
        // Non-zero finite doubles beyond NUMBER's range (a Dart-driver
        // extension — node-oracledb cannot bind those), plus NaN / ±Infinity
        // on opt-in only: BINARY_DOUBLE holds every IEEE double exactly.
        // (Only a double can fall outside NUMBER: every Dart int fits.)
        final d = value as double;
        if (!d.isFinite && !allowNonFinite) {
          throw const OracleException(
            errorCode: oraUnsupportedType,
            message:
                'JSON number is not finite (NaN or ±Infinity); non-finite '
                'JSON numbers are rejected by default. Bind through '
                'OracleBind.inOut(type: OracleDbType.json, allowNonFinite: '
                'true) to send them as BINARY_DOUBLE',
          );
        }
        _treeSeg.writeUint8(_nodeBinaryDouble);
        _treeSeg.writeBytes(_encodeBinaryDouble(d));
      }
    } else if (value is String) {
      final bytes = utf8.encode(value);
      if (bytes.length < 256) {
        _treeSeg.writeUint8(_nodeStringLenUint8);
        _treeSeg.writeUint8(bytes.length);
      } else if (bytes.length < 65536) {
        _treeSeg.writeUint8(_nodeStringLenUint16);
        _treeSeg.writeUint16BE(bytes.length);
      } else {
        _treeSeg.writeUint8(_nodeStringLenUint32);
        _treeSeg.writeUint32BE(bytes.length);
      }
      if (bytes.isNotEmpty) {
        _treeSeg.writeBytes(bytes);
      }
    } else if (value is DateTime) {
      _checkYear(value.year);
      // A UTC DateTime names an instant, not a wall clock: write it as a
      // TIMESTAMP WITH TIME ZONE at +00:00 so the zone survives (a zone-less
      // TIMESTAMP would store its UTC fields as if they were local time). It
      // decodes back as an OracleTimestampTz holding the same instant.
      if (value.isUtc) {
        _treeSeg.writeUint8(_nodeTimestampTz);
        _treeSeg.writeBytes(
          dt.encodeTimestampTz(OracleTimestampTz(value, offsetMinutes: 0)),
        );
        return;
      }
      // node-oracledb writes a Date with zero milliseconds as the DATE-shaped
      // TIMESTAMP7 node, anything finer as an 11-byte TIMESTAMP. Both reuse
      // the column codecs (local wall-clock fields, like a DATE / TIMESTAMP
      // column bind) so a fetched value re-binds unshifted.
      if (value.millisecond == 0 && value.microsecond == 0) {
        _treeSeg.writeUint8(_nodeTimestamp7);
        _treeSeg.writeBytes(dt.encodeDate(value));
      } else {
        _treeSeg.writeUint8(_nodeTimestamp);
        _treeSeg.writeBytes(dt.encodeTimestamp(value));
      }
    } else if (value is OracleTimestampTz) {
      _checkYear(value.utc.year);
      // 13 bytes: the UTC instant plus the reported offset, as the TSTZ
      // column bind writes it and the decoder reads it back.
      _treeSeg.writeUint8(_nodeTimestampTz);
      _treeSeg.writeBytes(dt.encodeTimestampTz(value));
    } else if (value is Uint8List) {
      // Checked before List: bytes are one binary scalar, not an array.
      if (value.length < 65536) {
        _treeSeg.writeUint8(_nodeBinaryLenUint16);
        _treeSeg.writeUint16BE(value.length);
      } else {
        _treeSeg.writeUint8(_nodeBinaryLenUint32);
        _treeSeg.writeUint32BE(value.length);
      }
      _treeSeg.writeBytes(value);
    } else if (value is List) {
      _encodeArray(value);
    } else if (value is Map) {
      _encodeObject(value);
    } else {
      throw _unsupportedValue(value);
    }
  }

  /// The 8-byte Oracle BINARY_DOUBLE form of [value] (node-oracledb
  /// `buffer.js` `writeBinaryDouble`): IEEE 754 big-endian bits made
  /// byte-comparable — a non-negative value gets its sign bit set, a negative
  /// one has every bit inverted. NaN is canonicalized to the quiet NaN
  /// `0x7FF8000000000000` first: a NaN's sign and payload bits vary by
  /// platform (x64 computes `0.0 / 0.0` as a negative NaN), and the server
  /// stores BINARY_DOUBLE_NAN as exactly that canonical pattern.
  static Uint8List _encodeBinaryDouble(double value) {
    final bytes = Uint8List(8);
    final data = ByteData.sublistView(bytes);
    if (value.isNaN) {
      data.setUint32(0, 0x7ff80000, Endian.big);
    } else {
      data.setFloat64(0, value, Endian.big);
    }
    if ((bytes[0] & 0x80) == 0) {
      bytes[0] |= 0x80;
    } else {
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] ^= 0xff;
      }
    }
    return bytes;
  }

  /// Fails loud on a date/time year outside 1..9999 instead of letting the
  /// column codecs reject it (BCE) or, past 9999, write an invalid (and from
  /// year 25600 silently wrapped) century byte. The year is deliberately not
  /// echoed: it is part of the bind value.
  static void _checkYear(int year) {
    final reason = _unsupportedYearReason(year);
    if (reason != null) {
      throw OracleException(
        errorCode: oraUnsupportedType,
        message: 'JSON date/time member $reason',
      );
    }
  }

  /// Writes a container's node type and child count. Offsets are always
  /// uint32 on encode (`| 0x20`), matching the reference encoder.
  void _encodeContainerHeader(int nodeType, int numChildren) {
    var type = nodeType | 0x20;
    if (numChildren > 65535) {
      type |= 0x10; // child count is uint32
    } else if (numChildren > 255) {
      type |= 0x08; // child count is uint16
    }
    _treeSeg.writeUint8(type);
    if (numChildren < 256) {
      _treeSeg.writeUint8(numChildren);
    } else if (numChildren < 65536) {
      _treeSeg.writeUint16BE(numChildren);
    } else {
      _treeSeg.writeUint32BE(numChildren);
    }
  }

  void _encodeArray(List<Object?> value) {
    _encodeContainerHeader(_nodeArray, value.length);
    var offsetSlot = _treeSeg.reserve(value.length * 4);
    for (final element in value) {
      _treeSeg.patchUint32BE(offsetSlot, _treeSeg.pos);
      offsetSlot += 4;
      _encodeNode(element);
    }
  }

  void _encodeObject(Map<Object?, Object?> value) {
    final numChildren = value.length;
    _encodeContainerHeader(_nodeObject, numChildren);
    var idSlot = _treeSeg.reserve(numChildren * _fieldIdSize);
    var offsetSlot = _treeSeg.reserve(numChildren * 4);
    for (final entry in value.entries) {
      // _examine already validated keys and registered every name.
      final fieldName = _fieldNamesMap[entry.key]!;
      if (_fieldIdSize == 1) {
        _treeSeg.patchUint8(idSlot, fieldName.fieldId);
      } else if (_fieldIdSize == 2) {
        _treeSeg.patchUint16BE(idSlot, fieldName.fieldId);
      } else {
        _treeSeg.patchUint32BE(idSlot, fieldName.fieldId);
      }
      idSlot += _fieldIdSize;
      _treeSeg.patchUint32BE(offsetSlot, _treeSeg.pos);
      offsetSlot += 4;
      _encodeNode(entry.value);
    }
  }

  static OracleException _unsupportedValue(Object value) => OracleException(
    errorCode: oraUnsupportedType,
    message:
        'Unsupported JSON member type ${value.runtimeType}. '
        'Supported: $_supportedJsonKinds',
  );
}

// ============================================================================
// Decoder
// ============================================================================

/// Decodes OSON bytes into Dart JSON values: `Map<String, Object?>` for
/// objects, `List<Object?>` for arrays, and `null` / `bool` / `num` /
/// `String` for standard scalar members.
///
/// Oracle-specific scalar nodes decode as follows (node-oracledb `oson.js`
/// `_decodeNode` byte layouts; date/time nodes reuse the column codecs):
/// - DATE and 7-byte TIMESTAMP → `DateTime` (local wall clock, like a DATE
///   column);
/// - TIMESTAMP (11 bytes) → `DateTime` with fractional seconds (truncated to
///   microseconds, like a TIMESTAMP column);
/// - TIMESTAMP WITH TIME ZONE (13 bytes) → `OracleTimestampTz` (UTC instant
///   plus its reported offset) always — unlike a column, this does not
///   depend on `preserveTimestampTimeZone`. A region-id zone (e.g.
///   `US/Pacific`) yields the UTC instant at a `+00:00` offset, exactly as
///   `decodeTimestampTz` does for a column (the region is not resolved);
/// - BINARY_FLOAT / BINARY_DOUBLE → `double` (NaN and ±Infinity included);
/// - binary (RAW) → `Uint8List` (a copy, never a view of [data]).
///
/// Throws [OracleException]:
/// - `oraProtocolError` for malformed/truncated payloads or bad magic bytes;
/// - `oraUnsupportedType` for unsupported OSON versions, BCE dates/timestamps,
///   and Oracle-specific scalar node types without a driver type yet
///   (intervals, JsonId, extended/VECTOR, unknown) — never decoded silently
///   to `null`, and never returned partially.
Object? decodeOson(Uint8List data) {
  try {
    return _OsonDecoder(data).decode();
  } on BufferException catch (e) {
    throw OracleException(
      errorCode: oraProtocolError,
      message: 'Truncated or corrupt OSON payload',
      cause: e,
    );
  } on FormatException catch (e) {
    // Malformed UTF-8 in a field name or string node. The message never
    // echoes the document content.
    throw OracleException(
      errorCode: oraProtocolError,
      message: 'Corrupt OSON payload: ${_formatErrorSummary(e)}',
    );
  }
}

class _OsonDecoder {
  _OsonDecoder(Uint8List data) : _buf = ReadBuffer(data);

  final ReadBuffer _buf;
  late final List<String> _fieldNames;
  int _fieldIdLength = 1;
  bool _relativeOffsets = false;
  int _treeSegPos = 0;

  Object? decode() {
    final m1 = _buf.readUint8();
    final m2 = _buf.readUint8();
    final m3 = _buf.readUint8();
    if (m1 != _magic1 || m2 != _magic2 || m3 != _magic3) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'OSON magic bytes mismatch: '
            '${m1.toRadixString(16)} ${m2.toRadixString(16)} '
            '${m3.toRadixString(16)}',
      );
    }
    final version = _buf.readUint8();
    if (version != _versionMaxFname255 && version != _versionMaxFname65535) {
      throw OracleException(
        errorCode: oraUnsupportedType,
        message: 'Unsupported OSON version: $version',
      );
    }
    final primaryFlags = (_buf.readUint8() << 8) | _buf.readUint8();
    _relativeOffsets = (primaryFlags & _flagRelOffsetMode) != 0;

    // Scalar documents skip the field-name machinery entirely.
    if ((primaryFlags & _flagIsScalar) != 0) {
      _buf.skip((primaryFlags & _flagTreeSegUint32) != 0 ? 4 : 2);
      _treeSegPos = _buf.position;
      return _decodeNode();
    }

    // Number of short field names + field id width.
    int numShortFieldNames;
    if ((primaryFlags & _flagNumFnamesUint32) != 0) {
      numShortFieldNames = _buf.readUint32BE();
      _fieldIdLength = 4;
    } else if ((primaryFlags & _flagNumFnamesUint16) != 0) {
      numShortFieldNames = _buf.readUint16BE();
      _fieldIdLength = 2;
    } else {
      numShortFieldNames = _buf.readUint8();
      _fieldIdLength = 1;
    }

    // Size of the short field names segment.
    int shortFieldNameOffsetsSize;
    int shortFieldNamesSegSize;
    if ((primaryFlags & _flagFnamesSegUint32) != 0) {
      shortFieldNameOffsetsSize = 4;
      shortFieldNamesSegSize = _buf.readUint32BE();
    } else {
      shortFieldNameOffsetsSize = 2;
      shortFieldNamesSegSize = _buf.readUint16BE();
    }

    // Version 3: long field names (> 255 bytes) live in a second segment.
    var numLongFieldNames = 0;
    var longFieldNameOffsetsSize = 4;
    var longFieldNamesSegSize = 0;
    if (version == _versionMaxFname65535) {
      final secondaryFlags = (_buf.readUint8() << 8) | _buf.readUint8();
      if ((secondaryFlags & _flagSecFnamesSegUint16) != 0) {
        longFieldNameOffsetsSize = 2;
      }
      numLongFieldNames = _buf.readUint32BE();
      longFieldNamesSegSize = _buf.readUint32BE();
    }

    // Tree segment size (unused — the root node walk bounds itself) and the
    // "tiny nodes" statistic.
    _buf.skip((primaryFlags & _flagTreeSegUint32) != 0 ? 4 : 2);
    _buf.skip(2);

    _fieldNames = List<String>.filled(
      numShortFieldNames + numLongFieldNames,
      '',
    );
    if (numShortFieldNames > 0) {
      _readFieldNames(
        0,
        numShortFieldNames,
        shortFieldNameOffsetsSize,
        shortFieldNamesSegSize,
        1,
      );
    }
    if (numLongFieldNames > 0) {
      _readFieldNames(
        numShortFieldNames,
        numLongFieldNames,
        longFieldNameOffsetsSize,
        longFieldNamesSegSize,
        2,
      );
    }

    _treeSegPos = _buf.position;
    return _decodeNode();
  }

  /// Reads one field-names segment: a hash-id array (skipped), a name-offset
  /// array, and the packed length-prefixed names. [fieldNamesSize] is 1 for
  /// short names (uint8 hash + uint8 length) and 2 for long names (uint16
  /// hash + uint16 length).
  void _readFieldNames(
    int arrStartPos,
    int numFields,
    int offsetsSize,
    int fieldNamesSegSize,
    int fieldNamesSize,
  ) {
    _buf.skip(numFields * fieldNamesSize); // hash id array
    final offsetsPos = _buf.position;
    _buf.skip(numFields * offsetsSize);
    final seg = _buf.readBytes(fieldNamesSegSize);
    final finalPos = _buf.position;

    _buf.seek(offsetsPos);
    for (var i = arrStartPos; i < arrStartPos + numFields; i++) {
      final offset = offsetsSize == 2
          ? _buf.readUint16BE()
          : _buf.readUint32BE();
      if (offset + fieldNamesSize > seg.length) {
        throw const BufferException('OSON field name offset out of range');
      }
      final nameLen = fieldNamesSize == 1
          ? seg[offset]
          : (seg[offset] << 8) | seg[offset + 1];
      final start = offset + fieldNamesSize;
      if (start + nameLen > seg.length) {
        throw const BufferException('OSON field name length out of range');
      }
      _fieldNames[i] = utf8.decode(
        Uint8List.sublistView(seg, start, start + nameLen),
      );
    }
    _buf.seek(finalPos);
  }

  Object? _decodeNode() {
    final nodeType = _buf.readUint8();
    if ((nodeType & 0x80) != 0) {
      return _decodeContainerNode(nodeType);
    }

    switch (nodeType) {
      case _nodeNull:
        return null;
      case _nodeTrue:
        return true;
      case _nodeFalse:
        return false;
      case _nodeStringLenUint8:
        return utf8.decode(_buf.readBytes(_buf.readUint8()));
      case _nodeStringLenUint16:
        return utf8.decode(_buf.readBytes(_buf.readUint16BE()));
      case _nodeStringLenUint32:
        return utf8.decode(_buf.readBytes(_buf.readUint32BE()));
      case _nodeNumberLenUint8:
        // Zero-length numbers decode to 0 — the same parity rule as the
        // packed 0x40/0x50 nodes, with the length in a separate uint8.
        final numberLength = _buf.readUint8();
        return numberLength == 0 ? 0 : _decodeNumber(numberLength);
      // Oracle-specific scalar kinds with an existing Dart type decode over
      // fixed-length payloads (node-oracledb oson.js `_decodeNode`: 7 / 7 /
      // 11 / 13-byte dates through the column codecs, 4 / 8-byte binary
      // float / double through _decodeBinaryFloatingPoint). Codec errors
      // (BCE century, out-of-range numeric zone offset) propagate unchanged
      // — a region-id zone is not an error and decodes like a column; a
      // short payload underflows into the BufferException → oraProtocolError
      // path.
      case _nodeDate:
        return dt.decodeDate(_fixedPayload(7));
      case _nodeTimestamp7:
        // A TIMESTAMP whose fractional seconds are zero: the DATE-shaped
        // 7-byte form. Decoded by the TIMESTAMP codec so a BCE value names
        // TIMESTAMP; the resulting DateTime is identical to decodeDate's.
        return dt.decodeTimestamp(_fixedPayload(7));
      case _nodeTimestamp:
        return dt.decodeTimestamp(_fixedPayload(11));
      case _nodeTimestampTz:
        return dt.decodeTimestampTz(_fixedPayload(13));
      case _nodeBinaryFloat:
        return _decodeBinaryFloatingPoint(4);
      case _nodeBinaryDouble:
        return _decodeBinaryFloatingPoint(8);
      case _nodeBinaryLenUint16:
        // Copy out of the OSON document: a view would alias the caller's
        // [data] buffer and keep the whole document alive (and reachable via
        // `.buffer`) for as long as the decoded value is held.
        return Uint8List.fromList(_buf.readBytes(_buf.readUint16BE()));
      case _nodeBinaryLenUint32:
        return Uint8List.fromList(_buf.readBytes(_buf.readUint32BE()));
      // Oracle-specific kinds with no driver type yet (intervals and VECTOR
      // arrive with Epics 14/15): fail loud rather than decode silently to
      // null. Each case is named so the error message tells callers what the
      // document actually contains.
      case _nodeIntervalYM:
        throw _unsupportedNode(nodeType, 'INTERVAL YEAR TO MONTH');
      case _nodeIntervalDS:
        throw _unsupportedNode(nodeType, 'INTERVAL DAY TO SECOND');
      case _nodeId:
        throw _unsupportedNode(nodeType, 'JsonId');
      case _nodeExtended:
        throw _unsupportedNode(nodeType, 'extended (VECTOR)');
    }

    // Number/decimal with the length packed into the node type itself.
    final typeBits = nodeType & 0xf0;
    if (typeBits == 0x20 || typeBits == 0x60) {
      return _decodeNumber((nodeType & 0x0f) + 1);
    }
    // Integer with the length packed into the node type itself. A
    // zero-length integer node decodes to 0 (reference oson.js parity:
    // parseOracleNumber over zero bytes yields "0" rather than throwing).
    if (typeBits == 0x40 || typeBits == 0x50) {
      final length = nodeType & 0x0f;
      if (length == 0) return 0;
      return _decodeNumber(length);
    }
    // String with the length packed into the node type itself.
    if ((nodeType & 0xe0) == 0) {
      if (nodeType == 0) return '';
      return utf8.decode(_buf.readBytes(nodeType));
    }

    throw _unsupportedNode(nodeType, 'unknown');
  }

  /// Decodes [length] Oracle NUMBER bytes. Returns `int` for integral values
  /// within the safe range, `double` otherwise — the same contract as NUMBER
  /// column decoding (the reference returns JS `number` for both).
  num _decodeNumber(int length) =>
      dt.decodeNumber(ReadBuffer(_buf.readBytes(length)));

  /// Reads a fixed [length]-byte scalar payload into its own [ReadBuffer] so
  /// the column codecs see exactly the bytes of this node (their tolerant
  /// length handling keys off `remaining`).
  ReadBuffer _fixedPayload(int length) => ReadBuffer(_buf.readBytes(length));

  /// Decodes an Oracle BINARY_FLOAT ([length] 4) or BINARY_DOUBLE ([length]
  /// 8) payload; see [dt.decodeBinaryFloatingPoint].
  double _decodeBinaryFloatingPoint(int length) =>
      dt.decodeBinaryFloatingPoint(_buf.readBytes(length));

  Object? _decodeContainerNode(int nodeType) {
    // Offset of this container's node-type byte within the tree segment —
    // the base for relative child offsets.
    final containerOffset = _buf.position - _treeSegPos - 1;
    final isObject = (nodeType & 0x40) == 0;

    var numChildren = _readNumChildren(nodeType);
    int fieldIdsPos;
    int offsetsPos;
    if (numChildren == null) {
      // Field ids (and child count) are shared with another object at the
      // given tree offset.
      final offset = _readOffset(nodeType);
      offsetsPos = _buf.position;
      _buf.seek(_treeSegPos + offset);
      final sharedNodeType = _buf.readUint8();
      numChildren = _readNumChildren(sharedNodeType);
      if (numChildren == null) {
        throw const BufferException(
          'OSON shared container points at another shared container',
        );
      }
      fieldIdsPos = _buf.position;
    } else if (isObject) {
      fieldIdsPos = _buf.position;
      offsetsPos = fieldIdsPos + _fieldIdLength * numChildren;
    } else {
      fieldIdsPos = 0; // unused for arrays
      offsetsPos = _buf.position;
    }

    final Object container = isObject
        ? <String, Object?>{}
        : List<Object?>.filled(numChildren, null, growable: true);

    for (var i = 0; i < numChildren; i++) {
      String? name;
      if (isObject) {
        _buf.seek(fieldIdsPos);
        final int fieldId;
        if (_fieldIdLength == 1) {
          fieldId = _buf.readUint8();
        } else if (_fieldIdLength == 2) {
          fieldId = _buf.readUint16BE();
        } else {
          fieldId = _buf.readUint32BE();
        }
        fieldIdsPos = _buf.position;
        if (fieldId < 1 || fieldId > _fieldNames.length) {
          throw BufferException(
            'OSON field id $fieldId out of range '
            '(have ${_fieldNames.length} names)',
          );
        }
        name = _fieldNames[fieldId - 1];
      }
      _buf.seek(offsetsPos);
      var offset = _readOffset(nodeType);
      if (_relativeOffsets) {
        offset += containerOffset;
      }
      offsetsPos = _buf.position;
      _buf.seek(_treeSegPos + offset);
      final child = _decodeNode();
      if (isObject) {
        (container as Map<String, Object?>)[name!] = child;
      } else {
        (container as List<Object?>)[i] = child;
      }
    }
    return container;
  }

  /// Child count per the 4th/5th most significant bits of the node type, or
  /// null when the count is shared with another object (bits `11`).
  int? _readNumChildren(int nodeType) {
    switch (nodeType & 0x18) {
      case 0x00:
        return _buf.readUint8();
      case 0x08:
        return _buf.readUint16BE();
      case 0x10:
        return _buf.readUint32BE();
      default:
        return null; // 0x18: shared field ids
    }
  }

  /// Offsets are uint32 when the 3rd most significant bit is set, else uint16.
  int _readOffset(int nodeType) =>
      (nodeType & 0x20) != 0 ? _buf.readUint32BE() : _buf.readUint16BE();

  static OracleException _unsupportedNode(int nodeType, String kind) =>
      OracleException(
        errorCode: oraUnsupportedType,
        message:
            'Unsupported OSON node type '
            '0x${nodeType.toRadixString(16)} ($kind). This driver decodes '
            'standard JSON values (objects, arrays, strings, numbers, '
            'booleans, null) and the Oracle DATE, TIMESTAMP, TIMESTAMP WITH '
            'TIME ZONE, BINARY_FLOAT, BINARY_DOUBLE and binary (RAW) '
            'scalars; Oracle-specific JSON scalars beyond date/time, binary '
            'and float/double (intervals, JsonId, VECTOR) are not supported.',
      );
}

// ============================================================================
// JSON stored in a BLOB (the Oracle 12c `IS JSON` pattern)
// ============================================================================

/// Decodes the content of a `BLOB` column the describe flags as JSON
/// (`IS JSON` / `IS JSON FORMAT OSON` — `ColumnMetadata.isJson` /
/// `ColumnMetadata.isOson`) into the same Dart mapping native `JSON` columns
/// use: `Map<String, Object?>`, `List<Object?>`, `String`, `num`, `bool`, or
/// `null` for a JSON `null` document.
///
/// Ports the node-oracledb `resultset.js` output converter (`isOson` →
/// `OsonDecoder`, `isJson` → `JSON.parse`) — but it is NOT a default-behavior
/// parity claim: node-oracledb installs that converter only when
/// `oracledb.future.oldJsonColumnAsObj` is enabled (default `false`), so out of
/// the box it returns such a column as a raw `Buffer`. This driver decodes by
/// default instead; `OracleExecuteOptions(rawJsonBlobs: true)` (or `fetchLobs:
/// true`, for an `OracleLob`) is the per-call way back to the raw bytes. It also
/// picks OSON vs text from the bytes rather than from the flag, so either
/// storage form decodes whichever flag the server reported:
///
/// 1. Bytes starting with the OSON magic `FF 4A 5A` decode through
///    [decodeOson]; its errors propagate unchanged (`oraProtocolError` for a
///    truncated or corrupt document, including malformed UTF-8 names/strings, `oraUnsupportedType` for unsupported
///    nodes).
/// 2. Anything else is JSON text. A byte-order mark selects the encoding and is
///    stripped (`EF BB BF` UTF-8, `FF FE` UTF-16LE, `FE FF` UTF-16BE). Without
///    one, a zero byte in exactly one of the first two bytes selects UTF-16
///    (big-endian when the zero comes first) — RFC 8259 JSON text never holds
///    an unescaped NUL, so this cannot misread a UTF-8 document, and Oracle's
///    `IS JSON` check accepts BOM-less UTF-16 — and everything else is UTF-8.
///    The text is then parsed by `jsonDecode` (strict RFC 8259); integral
///    numbers (`1.0`, `1e2`) decode to `int` as OSON NUMBER does, and a
///    non-finite literal such as `1e999` is rejected.
///
/// Fail loud — never the raw bytes, never a silent `null`: throws
/// [OracleException] with `oraUnsupportedType` for a zero-length value, an
/// undecodable encoding (malformed UTF-8, an odd UTF-16 byte count, an
/// unpaired surrogate), or text that is not strict JSON. That includes
/// Oracle's lax JSON syntax (unquoted field names, single-quoted strings,
/// upper-case `TRUE`), which the default (lax) `IS JSON` constraint accepts
/// but this decoder does not. Messages never echo the document content.
Object? decodeJsonBlobBytes(Uint8List data) {
  if (data.isEmpty) {
    throw _jsonBlobError(
      'the value is empty (zero bytes), which is not a JSON document',
    );
  }
  if (data.length >= 3 &&
      data[0] == _magic1 &&
      data[1] == _magic2 &&
      data[2] == _magic3) {
    return decodeOson(data);
  }
  final text = _decodeJsonText(data);
  try {
    return jsonDecode(text, reviver: _textJsonReviver);
  } on FormatException catch (e) {
    throw _jsonBlobError(
      'the content is not strict JSON text (${_formatErrorSummary(e)}). '
      "Oracle's lax JSON syntax, which a default IS JSON constraint "
      'accepts, is not supported; IS JSON STRICT keeps such values out',
    );
  }
}

/// Aligns text-JSON numbers with OSON NUMBER decoding: an integral double
/// within the safe range (`1.0`, `1e2`) becomes `int`, like `decodeNumber`,
/// and a non-finite literal (`1e999` parses to Infinity) is rejected, since
/// strict JSON has no Infinity and it would re-bind as BINARY_DOUBLE.
Object? _textJsonReviver(Object? key, Object? value) {
  if (value is! double) return value;
  if (!value.isFinite) {
    throw const FormatException('number literal out of double range');
  }
  if (value == value.truncateToDouble() && value.abs() <= 9007199254740992) {
    return value.toInt();
  }
  return value;
}

/// Decodes JSON text bytes to a Dart string, choosing the encoding as
/// documented on [decodeJsonBlobBytes].
String _decodeJsonText(Uint8List data) {
  // `utf16BigEndian` is null for UTF-8; `start` skips a byte-order mark.
  final String encoding;
  final int start;
  final bool? utf16BigEndian;
  if (data.length >= 3 &&
      data[0] == 0xef &&
      data[1] == 0xbb &&
      data[2] == 0xbf) {
    (encoding, start, utf16BigEndian) = ('UTF-8', 3, null);
  } else if (data.length >= 2 && data[0] == 0xff && data[1] == 0xfe) {
    (encoding, start, utf16BigEndian) = ('UTF-16LE', 2, false);
  } else if (data.length >= 2 && data[0] == 0xfe && data[1] == 0xff) {
    (encoding, start, utf16BigEndian) = ('UTF-16BE', 2, true);
  } else if (data.length >= 2 && (data[0] == 0) != (data[1] == 0)) {
    // BOM-less UTF-16: the zero byte is the high half of an ASCII code unit.
    final bigEndian = data[0] == 0;
    (encoding, start, utf16BigEndian) = (
      bigEndian ? 'UTF-16BE' : 'UTF-16LE',
      0,
      bigEndian,
    );
  } else {
    (encoding, start, utf16BigEndian) = ('UTF-8', 0, null);
  }
  try {
    return utf16BigEndian == null
        ? utf8.decode(Uint8List.sublistView(data, start))
        : _decodeUtf16Strict(data, start, bigEndian: utf16BigEndian);
  } on FormatException catch (e) {
    throw _jsonBlobError(
      'the bytes are not valid $encoding text (${_formatErrorSummary(e)})',
    );
  }
}

/// Decodes UTF-16 code units from [data] starting at byte [start], rejecting
/// an odd byte count and unpaired surrogates (a lenient decode would hand
/// `jsonDecode` a string no UTF-16 encoder could have produced).
String _decodeUtf16Strict(
  Uint8List data,
  int start, {
  required bool bigEndian,
}) {
  final byteCount = data.length - start;
  if (byteCount.isOdd) {
    throw FormatException('odd byte count $byteCount', null, data.length - 1);
  }
  final units = Uint16List(byteCount ~/ 2);
  for (var i = 0; i < units.length; i++) {
    final first = data[start + i * 2];
    final second = data[start + i * 2 + 1];
    units[i] = bigEndian ? (first << 8) | second : (second << 8) | first;
  }
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      final hasLow =
          i + 1 < units.length &&
          units[i + 1] >= 0xdc00 &&
          units[i + 1] <= 0xdfff;
      if (!hasLow) {
        throw FormatException('unpaired high surrogate', null, start + i * 2);
      }
      i++; // the low half of a valid pair
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw FormatException('unpaired low surrogate', null, start + i * 2);
    }
  }
  return String.fromCharCodes(units);
}

/// The reason and position of [e] without its `source` — the source is the
/// document itself, which must not leak into error messages or logs.
String _formatErrorSummary(FormatException e) {
  final offset = e.offset;
  return offset == null ? e.message : '${e.message} at offset $offset';
}

OracleException _jsonBlobError(String reason) => OracleException(
  errorCode: oraUnsupportedType,
  message:
      'Cannot decode JSON stored in a BLOB: $reason. Fetch the data with a '
      'separate execute() SELECT and OracleExecuteOptions(rawJsonBlobs: true) '
      'to read raw bytes as a Uint8List, or with fetchLobs: true to read them '
      'through an OracleLob. For large results, add resultSet: true. '
      'queryStream() and executeStream() have no fetch options; executeMany() '
      'has no rawJsonBlobs option for implicit result rows. Do not replay a '
      'statement with side effects just to fetch the bytes.',
);
