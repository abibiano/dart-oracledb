/// OSON (Oracle binary JSON) support for the native `JSON` data type
/// (type 119, Oracle 21c+).
///
/// Ported from the bundled node-oracledb reference implementation:
/// `reference/node-oracledb/lib/impl/datahandlers/oson.js` (encoder/decoder)
/// and `reference/node-oracledb/lib/impl/datahandlers/constants.js` (format
/// constants). Scope is standard JSON documents (Story 4.4): objects, arrays,
/// strings, numbers, booleans, and null. Oracle-specific OSON scalar kinds
/// (dates, timestamps, intervals, binary, vector, JsonId, ...) fail loud.
///
/// The encoder always emits OSON **version 1** (field names ≤ 255 UTF-8
/// bytes), which both Oracle 21c and 23ai accept; version-3 long field names
/// are rejected at encode time and supported on decode only.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';
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

/// OSON version with field names up to 65535 bytes (decode-only here).
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

/// Maximum UTF-8 byte length of an encoded field name. Fixed at the OSON
/// version-1 limit so encoded documents are valid on every supported server
/// (Oracle pre-23.1 rejects long field names).
const int _maxFieldNameBytes = 255;

// ============================================================================
// Bind-value validation (shared with the public OracleBind API)
// ============================================================================

/// Validates that [value] is a supported JSON bind structure: a
/// `Map` with `String` keys, a `List`, or `null` at the top level, with every
/// nested member being `null`, `bool`, a finite `num`, `String`, `Map` with
/// `String` keys, or `List`.
///
/// Throws [ArgumentError] naming the offending member so the failure surfaces
/// at the call site, not deep inside wire encoding. [name] is the parameter
/// name reported in the error.
///
/// `Uint8List` is deliberately rejected even though it is a `List<int>`:
/// plain bytes must remain RAW/BLOB behavior (Story 4.4 regression trap), and
/// the OSON binary scalar is not part of the supported standard-JSON scope.
void assertValidJsonBindValue(Object? value, String name) {
  if (value == null) return;
  if (value is! Map && value is! List || value is Uint8List) {
    throw ArgumentError.value(
        value,
        name,
        'JSON bind values must be Map<String, Object?>, List<Object?>, or '
        'null (got ${value.runtimeType})');
  }
  _assertValidJsonMember(value, name, name);
}

void _assertValidJsonMember(Object? value, String name, String path) {
  if (value == null || value is bool || value is String) return;
  if (value is num) {
    if (value is double && !value.isFinite) {
      throw ArgumentError.value(
          value, name, 'JSON numbers cannot be NaN or Infinity (at $path)');
    }
    return;
  }
  // Uint8List is a List<int>; check it before the generic List branch.
  if (value is Uint8List) {
    throw ArgumentError.value(
        value,
        name,
        'Uint8List is not a supported JSON member — bytes stay RAW/BLOB '
        '(at $path)');
  }
  if (value is List) {
    for (var i = 0; i < value.length; i++) {
      _assertValidJsonMember(value[i], name, '$path[$i]');
    }
    return;
  }
  if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw ArgumentError.value(
            value,
            name,
            'JSON object keys must be String '
            '(got ${key.runtimeType} at $path)');
      }
      _assertValidJsonMember(entry.value, name, "$path['$key']");
    }
    return;
  }
  throw ArgumentError.value(
      value,
      name,
      'Unsupported JSON member type ${value.runtimeType} (at $path). '
      'Supported: Map<String, Object?>, List<Object?>, String, finite num, '
      'bool, null');
}

// ============================================================================
// Encoder
// ============================================================================

/// Encodes a Dart JSON structure (`Map<String, Object?>`, `List<Object?>`,
/// `String`, finite `num`, `bool`, or `null`) into OSON bytes.
///
/// Throws [OracleException] for unsupported member types, non-finite doubles,
/// non-`String` map keys, and field names longer than 255 UTF-8 bytes.
Uint8List encodeOson(Object? value) => _OsonEncoder().encode(value);

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

  Uint8List toBytes() => Uint8List.fromList(Uint8List.sublistView(_buf, 0, pos));
}

class _OsonFieldName {
  _OsonFieldName(this.name)
      : nameBytes = Uint8List.fromList(utf8.encode(name)),
        hashId = 0 {
    if (nameBytes.length > _maxFieldNameBytes) {
      throw OracleException(
        errorCode: oraUnsupportedType,
        message: 'JSON field names longer than $_maxFieldNameBytes UTF-8 '
            'bytes are not supported (got ${nameBytes.length} bytes)',
      );
    }
    hashId = _hash(nameBytes);
  }

  final String name;
  final Uint8List nameBytes;

  /// FNV-1a 32-bit hash truncated to its lowest byte (the OSON "hash id").
  /// The 32-bit intermediate state needs 64-bit int semantics (the multiply
  /// peaks near 2^56) — fine on every supported platform; this package does
  /// not target the web.
  int hashId;

  /// Byte offset of this name inside the field names segment.
  int offset = 0;

  /// 1-based id used by object nodes in the tree segment.
  int fieldId = 0;

  static int _hash(Uint8List bytes) {
    var h = 0x811C9DC5;
    for (final b in bytes) {
      h = ((h ^ b) * 16777619) & 0xffffffff;
    }
    return h & 0xff;
  }
}

class _OsonEncoder {
  final _fieldNamesMap = <String, _OsonFieldName>{};
  final _fieldNames = <_OsonFieldName>[];
  final _namesSeg = _OsonWriteBuffer();
  final _treeSeg = _OsonWriteBuffer();
  int _fieldIdSize = 1;

  Uint8List encode(Object? value) {
    final isContainer =
        (value is Map || value is List) && value is! Uint8List;

    var flags = _flagInlineLeaf;
    if (isContainer) {
      _examine(value);
      // Sort field names exactly like the reference (`_processFieldNames`):
      // by hash id, then byte length, then UTF-16 code-unit name order.
      _fieldNames.sort((a, b) {
        if (a.hashId != b.hashId) return a.hashId.compareTo(b.hashId);
        if (a.nameBytes.length != b.nameBytes.length) {
          return a.nameBytes.length.compareTo(b.nameBytes.length);
        }
        return a.name.compareTo(b.name);
      });
      for (var i = 0; i < _fieldNames.length; i++) {
        _fieldNames[i].fieldId = i + 1;
      }
      flags |= _flagHashIdUint8 | _flagTinyNodesStat;
      if (_fieldNames.length > 65535) {
        flags |= _flagNumFnamesUint32;
        _fieldIdSize = 4;
      } else if (_fieldNames.length > 255) {
        flags |= _flagNumFnamesUint16;
        _fieldIdSize = 2;
      } else {
        _fieldIdSize = 1;
      }
      if (_namesSeg.pos > 65535) {
        flags |= _flagFnamesSegUint32;
      }
    } else {
      flags |= _flagIsScalar;
    }

    _encodeNode(value);
    if (_treeSeg.pos > 65535) {
      flags |= _flagTreeSegUint32;
    }

    final out = _OsonWriteBuffer()
      ..writeUint8(_magic1)
      ..writeUint8(_magic2)
      ..writeUint8(_magic3)
      ..writeUint8(_versionMaxFname255)
      ..writeUint16BE(flags);

    if (isContainer) {
      // Extended header: number of (short) field names, then the size of the
      // field names segment.
      if (_fieldIdSize == 1) {
        out.writeUint8(_fieldNames.length);
      } else if (_fieldIdSize == 2) {
        out.writeUint16BE(_fieldNames.length);
      } else {
        out.writeUint32BE(_fieldNames.length);
      }
      if (_namesSeg.pos < 65536) {
        out.writeUint16BE(_namesSeg.pos);
      } else {
        out.writeUint32BE(_namesSeg.pos);
      }
    }

    if (_treeSeg.pos < 65536) {
      out.writeUint16BE(_treeSeg.pos);
    } else {
      out.writeUint32BE(_treeSeg.pos);
    }

    if (isContainer) {
      out.writeUint16BE(0); // number of "tiny" nodes (always zero)
      // Hash id array, then name-offset array (both in sorted-id order),
      // then the name bytes themselves (in first-appearance order).
      for (final f in _fieldNames) {
        out.writeUint8(f.hashId);
      }
      final wideOffsets = _namesSeg.pos >= 65536;
      for (final f in _fieldNames) {
        if (wideOffsets) {
          out.writeUint32BE(f.offset);
        } else {
          out.writeUint16BE(f.offset);
        }
      }
      out.writeBytes(Uint8List.sublistView(_namesSeg._buf, 0, _namesSeg.pos));
    }

    out.writeBytes(Uint8List.sublistView(_treeSeg._buf, 0, _treeSeg.pos));
    return out.toBytes();
  }

  /// Collects unique field names depth-first, registering each name before
  /// examining its value (reference `_examineNode` order — segment offsets
  /// depend on it).
  void _examine(Object? value) {
    if (value is Uint8List) {
      throw _unsupportedValue(value);
    }
    if (value is List) {
      for (final element in value) {
        _examine(element);
      }
    } else if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) {
          throw OracleException(
            errorCode: oraUnsupportedType,
            message: 'JSON object keys must be String '
                '(got ${key.runtimeType})',
          );
        }
        if (!_fieldNamesMap.containsKey(key)) {
          final fieldName = _OsonFieldName(key);
          fieldName.offset = _namesSeg.pos;
          _namesSeg.writeUint8(fieldName.nameBytes.length);
          _namesSeg.writeBytes(fieldName.nameBytes);
          _fieldNamesMap[key] = fieldName;
          _fieldNames.add(fieldName);
        }
        _examine(entry.value);
      }
    }
  }

  void _encodeNode(Object? value) {
    if (value == null) {
      _treeSeg.writeUint8(_nodeNull);
    } else if (value is bool) {
      _treeSeg.writeUint8(value ? _nodeTrue : _nodeFalse);
    } else if (value is num) {
      // encodeNumber rejects NaN/±Infinity and out-of-range doubles with a
      // clear OracleException, so no pre-check is needed here.
      final numberBytes = dt.encodeNumber(value);
      _treeSeg.writeUint8(_nodeNumberLenUint8);
      _treeSeg.writeUint8(numberBytes.length);
      _treeSeg.writeBytes(numberBytes);
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
    } else if (value is Uint8List) {
      throw _unsupportedValue(value);
    } else if (value is List) {
      _encodeArray(value);
    } else if (value is Map) {
      _encodeObject(value);
    } else {
      throw _unsupportedValue(value);
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
        message: 'Unsupported JSON member type ${value.runtimeType}. '
            'Supported: Map<String, Object?>, List<Object?>, String, '
            'finite num, bool, null',
      );
}

// ============================================================================
// Decoder
// ============================================================================

/// Decodes OSON bytes into Dart JSON values: `Map<String, Object?>` for
/// objects, `List<Object?>` for arrays, and `null` / `bool` / `num` /
/// `String` for scalar members.
///
/// Throws [OracleException]:
/// - `oraProtocolError` for malformed/truncated payloads or bad magic bytes;
/// - `oraUnsupportedType` for unsupported OSON versions and Oracle-specific
///   scalar node types outside the standard-JSON scope (AC5 — never decode
///   them silently to `null`).
Object? decodeOson(Uint8List data) {
  try {
    return _OsonDecoder(data).decode();
  } on BufferException catch (e) {
    throw OracleException(
      errorCode: oraProtocolError,
      message: 'Truncated or corrupt OSON payload',
      cause: e,
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
        message: 'OSON magic bytes mismatch: '
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

    _fieldNames =
        List<String>.filled(numShortFieldNames + numLongFieldNames, '');
    if (numShortFieldNames > 0) {
      _readFieldNames(0, numShortFieldNames, shortFieldNameOffsetsSize,
          shortFieldNamesSegSize, 1);
    }
    if (numLongFieldNames > 0) {
      _readFieldNames(numShortFieldNames, numLongFieldNames,
          longFieldNameOffsetsSize, longFieldNamesSegSize, 2);
    }

    _treeSegPos = _buf.position;
    return _decodeNode();
  }

  /// Reads one field-names segment: a hash-id array (skipped), a name-offset
  /// array, and the packed length-prefixed names. [fieldNamesSize] is 1 for
  /// short names (uint8 hash + uint8 length) and 2 for long names (uint16
  /// hash + uint16 length).
  void _readFieldNames(int arrStartPos, int numFields, int offsetsSize,
      int fieldNamesSegSize, int fieldNamesSize) {
    _buf.skip(numFields * fieldNamesSize); // hash id array
    final offsetsPos = _buf.position;
    _buf.skip(numFields * offsetsSize);
    final seg = _buf.readBytes(fieldNamesSegSize);
    final finalPos = _buf.position;

    _buf.seek(offsetsPos);
    for (var i = arrStartPos; i < arrStartPos + numFields; i++) {
      final offset =
          offsetsSize == 2 ? _buf.readUint16BE() : _buf.readUint32BE();
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
      _fieldNames[i] =
          utf8.decode(Uint8List.sublistView(seg, start, start + nameLen));
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
        return _decodeNumber(_buf.readUint8());
      // Oracle-specific scalar kinds are out of the Story 4.4 standard-JSON
      // scope: fail loud (AC5) rather than decode silently to null. Each
      // case is named so the error message tells callers what the document
      // actually contains.
      case _nodeDate:
        throw _unsupportedNode(nodeType, 'DATE');
      case _nodeTimestamp7:
        throw _unsupportedNode(nodeType, 'TIMESTAMP (7-byte)');
      case _nodeTimestamp:
        throw _unsupportedNode(nodeType, 'TIMESTAMP');
      case _nodeTimestampTz:
        throw _unsupportedNode(nodeType, 'TIMESTAMP WITH TIME ZONE');
      case _nodeBinaryFloat:
        throw _unsupportedNode(nodeType, 'BINARY_FLOAT');
      case _nodeBinaryDouble:
        throw _unsupportedNode(nodeType, 'BINARY_DOUBLE');
      case _nodeIntervalYM:
        throw _unsupportedNode(nodeType, 'INTERVAL YEAR TO MONTH');
      case _nodeIntervalDS:
        throw _unsupportedNode(nodeType, 'INTERVAL DAY TO SECOND');
      case _nodeId:
        throw _unsupportedNode(nodeType, 'JsonId');
      case _nodeBinaryLenUint16:
      case _nodeBinaryLenUint32:
        throw _unsupportedNode(nodeType, 'binary (RAW scalar)');
      case _nodeExtended:
        throw _unsupportedNode(nodeType, 'extended (VECTOR)');
    }

    // Number/decimal with the length packed into the node type itself.
    final typeBits = nodeType & 0xf0;
    if (typeBits == 0x20 || typeBits == 0x60) {
      return _decodeNumber((nodeType & 0x0f) + 1);
    }
    // Integer with the length packed into the node type itself.
    if (typeBits == 0x40 || typeBits == 0x50) {
      return _decodeNumber(nodeType & 0x0f);
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
            'OSON shared container points at another shared container');
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
          throw BufferException('OSON field id $fieldId out of range '
              '(have ${_fieldNames.length} names)');
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
        message: 'Unsupported OSON node type '
            '0x${nodeType.toRadixString(16)} ($kind). Story 4.4 supports '
            'standard JSON values only: objects, arrays, strings, numbers, '
            'booleans, and null.',
      );
}
