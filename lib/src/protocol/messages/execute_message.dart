/// Real Oracle TTC EXECUTE message (RPC OALL8).
///
/// Implements the wire format used by Oracle Database 12.2+ (validated against
/// Oracle 23ai), modeled after node-oracledb's thin client. The previous
/// implementation in this file used an invented format that Oracle rejected
/// at the first byte after auth; it has since been replaced.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../errors.dart';
import '../../oracle_timestamp_tz.dart';
import '../buffer.dart';
import '../constants.dart';
import '../data_types.dart' as dt;
import '../lob_locator.dart';
import '../oson.dart';
import 'base.dart';

/// Direction of a [BindVariable] on the wire.
///
/// - [input] sends a value to the server; nothing comes back for this bind.
/// - [output] sends only type/maxSize metadata; the server allocates a return
///   buffer and writes a value back in the response ROW_DATA.
/// - [inputOutput] sends an input value AND receives a (possibly modified)
///   value back. Oracle reports it as TTC direction `tnsBindDirInputOutput`.
enum BindDir {
  /// Client → server (IN).
  input,

  /// Server → client only (OUT — procedure OUT parameter or function return).
  output,

  /// Bidirectional (IN OUT — value is sent and may be modified server-side).
  inputOutput,
}

/// One bind variable supplied to an [ExecuteRequest].
///
/// The Dart-level [value] is paired with the Oracle [oraType] expected on the
/// wire. The [oraType] is inferred from the Dart type when callers do not set
/// it explicitly. For OUT binds (function returns) pass [dir]: `BindDir.output`
/// and a `null` value — the server allocates a return buffer sized by
/// [maxSize].
class BindVariable {
  /// Creates a bind variable.
  BindVariable({
    required this.value,
    int? oraType,
    this.maxSize,
    this.dir = BindDir.input,
  }) : oraType = oraType ?? _inferType(value) {
    // JSON binds (inferred from a Map/List value or declared explicitly)
    // must hold a valid JSON structure. Validating at construction surfaces
    // bad nested members (DateTime, Uint8List, NaN, non-String keys, ...) at
    // the call site instead of mid-encode.
    if (this.oraType == oraTypeJson) {
      assertValidJsonBindValue(value, 'value');
    }
  }

  /// The Dart value to send (or null for SQL NULL / OUT bind).
  final Object? value;

  /// The Oracle data type indicator.
  final int oraType;

  /// Maximum buffer size declared to the server. Optional; defaults to a
  /// type-appropriate value.
  final int? maxSize;

  /// Direction (IN, OUT). IN is the default; OUT is used for PL/SQL return
  /// values such as `BEGIN :ret := func(...); END;`.
  final BindDir dir;

  /// Whether the server will return a value for this bind (OUT or IN OUT).
  bool get hasOutput => dir == BindDir.output || dir == BindDir.inputOutput;

  static int _inferType(Object? value) {
    final oraType = dt.inferOraTypeForValue(value);
    if (oraType == null) {
      throw OracleException(
        errorCode: oraBindTypeError,
        message:
            'Unsupported bind value type: ${value.runtimeType}. '
            'Supported types: String, int, double, DateTime, '
            'OracleTimestampTz, Uint8List, Map, List, null',
      );
    }
    return oraType;
  }
}

/// TTC EXECUTE (RPC function 94) request message.
class ExecuteRequest extends Message {
  /// Creates a full EXECUTE request.
  ///
  /// [isQuery] should be true for SELECT statements (so the server prepares to
  /// fetch and we set the right options); false for DML/DDL/PL/SQL.
  /// [isPlSql] should be true for BEGIN/DECLARE/CALL blocks; it clears
  /// NOT_PLSQL and sets PLSQL_BIND when bind values are present.
  ExecuteRequest({
    required this.sql,
    this.bindValues,
    this.bindNames,
    this.cursorId = 0,
    required this.isQuery,
    this.isPlSql = false,
    this.numIters = 50,
    this.ttcFieldVersion = 24,
    this.defineColumns,
    super.sequence = 1,
  }) : assert(
         !(isQuery && isPlSql),
         'a statement cannot be both query and PL/SQL',
       ),
       assert(
         defineColumns == null ||
             (isQuery && cursorId != 0 && bindValues == null),
         'define mode requires an open query cursor and carries no binds',
       ),
       super(messageType: ttcMsgTypeFunction) {
    // OUT and IN OUT binds are only meaningful in PL/SQL. Refuse mid-build
    // rather than emit malformed bytes that would surface as a confusing
    // server error.
    if (bindValues != null) {
      for (final v in bindValues!) {
        if (v is BindVariable && v.hasOutput && !isPlSql) {
          throw const OracleException(
            errorCode: oraBindTypeError,
            message: 'OUT/IN OUT binds are only supported in PL/SQL blocks',
          );
        }
      }
    }
  }

  /// The SQL text to execute.
  final String sql;

  /// Bind values in SQL order, wrapped in [BindVariable] or raw Dart values.
  final List<Object?>? bindValues;

  /// Bind names matching [bindValues] order, used for diagnostics only.
  final List<String>? bindNames;

  /// Server-assigned cursor id (0 for new statements).
  final int cursorId;

  /// Whether this is a query statement (changes options).
  final bool isQuery;

  /// Whether this is a PL/SQL block (BEGIN, DECLARE, CALL).
  final bool isPlSql;

  /// Initial prefetch / iteration count for queries.
  final int numIters;

  /// Negotiated TTC field version from protocol negotiation.
  final int ttcFieldVersion;

  /// When non-null, this message is a DEFINE call for an already-open query
  /// cursor: it establishes column defines — with the LOB
  /// prefetch cont-flag on CLOB columns — instead of executing. Mirrors
  /// node-oracledb's `requiresDefine` execute variant (`_handleDefines`):
  /// options carry DEFINE without EXECUTE/FETCH/PARSE, no binds travel, and
  /// the define metadata replaces the bind metadata block. Required because
  /// the server stops sending the LOB-prefetch shape (length + chunk size)
  /// on FETCH continuation rounds until defines are established.
  final List<ColumnMetadata>? defineColumns;

  /// Number of execute iterations for DML (always 1 here; bulk DML deferred).
  int get _numExecs => 1;

  @override
  void encode(WriteBuffer buffer) {
    // Header
    buffer.writeUint8(messageType); // TNS_MSG_TYPE_FUNCTION (3)
    buffer.writeUint8(ttcFuncExecute); // 94
    buffer.writeUint8(sequence & 0xFF);
    if (ttcFieldVersion >= ttcCcapFieldVersion23_1Ext1) {
      buffer.writeUB8(0); // token number
    }

    final sqlBytes = utf8.encode(sql);
    final binds = _normalizeBinds();
    final numParams = binds.length;
    if (bindNames != null && bindNames!.length != numParams) {
      throw OracleException(
        errorCode: oraBindMismatch,
        message:
            'Internal: bindNames.length (${bindNames!.length}) != '
            'bindValues.length ($numParams)',
      );
    }
    final hasSql = cursorId == 0 || sqlBytes.isNotEmpty;
    final effectiveNumIters = isQuery ? numIters : _numExecs;

    // Execute options + DML options
    var options = 0;
    var dmlOptions = 0;
    final defines = defineColumns;
    if (defines != null) {
      // Define mode (node-oracledb execute.js `requiresDefine`): DEFINE
      // replaces EXECUTE, no FETCH (rows come from later FETCH RPCs), no
      // PARSE (the cursor is open), and the implicit-resultset DML option
      // stays clear.
      options |= ttcExecOptionDefine | ttcExecOptionNotPlSql;
    } else {
      options |= ttcExecOptionExecute;
      if (cursorId == 0) {
        options |= ttcExecOptionParse;
      }
      if (isQuery) {
        options |= ttcExecOptionFetch;
      } else if (!isPlSql) {
        options |= ttcExecOptionNotPlSql;
      } else if (numParams > 0) {
        options |= ttcExecOptionPlSqlBind;
      }
      if (numParams > 0) {
        options |= ttcExecOptionBind;
      }
      dmlOptions |= ttcExecOptionImplicitResultset;
    }

    buffer.writeUB4(options);
    buffer.writeUB4(cursorId);

    // pointer (cursor id) / sql length
    if (cursorId == 0) {
      buffer.writeUint8(1); // ptr to SQL
      buffer.writeUB4(sqlBytes.length);
    } else {
      buffer.writeUint8(0);
      buffer.writeUB4(0);
    }

    buffer.writeUint8(1); // pointer (vector)
    buffer.writeUB4(13); // al8i4 array length

    buffer.writeUint8(0); // pointer (al8o4)
    buffer.writeUint8(0); // pointer (al8o4l)
    buffer.writeUint8(0); // prefetch buffer size
    buffer.writeUB4(effectiveNumIters); // prefetch num rows
    buffer.writeUB4(ttcMaxLongLength); // maximum long size

    if (numParams == 0) {
      buffer.writeUint8(0);
      buffer.writeUB4(0);
    } else {
      buffer.writeUint8(1);
      buffer.writeUB4(numParams);
    }

    buffer.writeUint8(0); // al8pp
    buffer.writeUint8(0); // al8txn
    buffer.writeUint8(0); // al8txl
    buffer.writeUint8(0); // al8kv
    buffer.writeUint8(0); // al8kvl

    // defines: normally absent (the server describes); the define
    // call announces one define per query column here (al8doac pointer).
    if (defines != null) {
      buffer.writeUint8(1);
      buffer.writeUB4(defines.length);
    } else {
      buffer.writeUint8(0);
      buffer.writeUB4(0);
    }

    buffer.writeUB4(0); // registration id

    buffer.writeUint8(0); // al8objlist (pointer = null)
    buffer.writeUint8(0); // al8objlen (must be 0 when pointer is 0)
    buffer.writeUint8(0); // al8blv
    buffer.writeUB4(0); // al8blv
    buffer.writeUint8(0); // al8dnam
    buffer.writeUB4(0); // al8dnaml
    buffer.writeUB4(0); // al8regid_msb

    // array dml row counts (off)
    buffer.writeUint8(0);
    buffer.writeUB4(0);
    buffer.writeUint8(0);

    // 12.2 fields
    if (ttcFieldVersion >= ttcCcapFieldVersion12_2) {
      buffer.writeUint8(0); // al8sqlsig
      buffer.writeUB4(0);
      buffer.writeUint8(0); // sql id
      buffer.writeUB4(0);
      buffer.writeUint8(0); // length of sql id
      // 12.2 ext1
      if (ttcFieldVersion >= ttcCcapFieldVersionExt1) {
        buffer.writeUint8(0); // chunk ids
        buffer.writeUB4(0);
      }
    }

    // SQL bytes (only when cursorId == 0 or it's DDL)
    if (cursorId == 0 && hasSql) {
      buffer.writeBytesWithLength(Uint8List.fromList(sqlBytes));
      buffer.writeUB4(1); // al8i4[0] parse
    } else {
      buffer.writeUB4(0); // al8i4[0]
    }

    // al8i4[1] execution count
    if (isQuery) {
      buffer.writeUB4(cursorId == 0 ? 0 : effectiveNumIters);
    } else {
      buffer.writeUB4(_numExecs);
    }

    buffer.writeUB4(0); // al8i4[2]
    buffer.writeUB4(0); // al8i4[3]
    buffer.writeUB4(0); // al8i4[4]
    buffer.writeUB4(0); // al8i4[5] SCN p1
    buffer.writeUB4(0); // al8i4[6] SCN p2
    buffer.writeUB4(isQuery ? 1 : 0); // al8i4[7]
    buffer.writeUB4(0); // al8i4[8]
    buffer.writeUB4(dmlOptions); // al8i4[9]
    buffer.writeUB4(0); // al8i4[10]
    buffer.writeUB4(0); // al8i4[11]
    buffer.writeUB4(0); // al8i4[12]

    // Define metadata (define mode) OR bind metadata + values — never both
    // (node-oracledb execute.js writes one or the other).
    if (defines != null) {
      _writeDefineMetadata(buffer, defines);
      return;
    }
    if (numParams > 0) {
      _writeBindMetadata(buffer, binds);
      // Single ROW_DATA message containing all bind values for one iteration.
      buffer.writeUint8(ttcMsgTypeRowData);
      // SQL (non-PL/SQL) statements must write values whose declared size
      // exceeds the 32767-byte string bind limit AFTER all other binds —
      // Oracle's long-data ordering, mirrored from node-oracledb
      // writeBindParamsRow (`foundLong`). PL/SQL never reaches this path:
      // oversized PL/SQL strings are converted to temporary CLOBs before
      // encoding.
      final deferredLongBinds = <BindVariable>[];
      for (final bind in binds) {
        // JSON is excluded from the deferral despite its 32 MB metadata
        // maxSize: node-oracledb classifies long binds by the variable's own
        // (small) maxSize, so JSON values stay in bind order on the wire.
        if (!isPlSql &&
            _wireTypeFor(bind) != oraTypeJson &&
            _maxSizeFor(bind) > ttcMaxVarcharBindBytes) {
          deferredLongBinds.add(bind);
          continue;
        }
        _writeBindValue(buffer, bind);
      }
      for (final bind in deferredLongBinds) {
        _writeBindValue(buffer, bind);
      }
    }
  }

  List<BindVariable> _normalizeBinds() {
    final values = bindValues;
    if (values == null || values.isEmpty) return const [];
    return [
      for (final v in values)
        if (v is BindVariable) v else BindVariable(value: v),
    ];
  }

  void _writeBindMetadata(WriteBuffer buffer, List<BindVariable> binds) {
    for (final bind in binds) {
      final oraType = _wireTypeFor(bind);
      final maxSize = _maxSizeFor(bind);
      final csfrm = _csfrmFor(oraType);

      buffer.writeUint8(oraType);
      buffer.writeUint8(ttcBindUseIndicators);
      buffer.writeUint8(0); // precision
      buffer.writeUint8(0); // scale
      buffer.writeUB4(maxSize);
      buffer.writeUB4(0); // max num elements (not array)
      // LOB and JSON binds request prefetch metadata — node-oracledb
      // writeColumnMetadata sets TNS_LOB_PREFETCH_FLAG for every LOB-typed
      // bind and for DB_TYPE_JSON (whose document then travels inline).
      buffer.writeUB4(
        oraType == oraTypeClob ||
                oraType == oraTypeBlob ||
                oraType == oraTypeJson
            ? tnsLobPrefetchFlag
            : 0,
      );
      buffer.writeUB4(0); // OID
      buffer.writeUB2(0); // version
      buffer.writeUB2(csfrm != 0 ? ttcCharsetUtf8 : 0);
      buffer.writeUint8(csfrm);
      // Max chars (LOB prefetch length): TNS_JSON_MAX_LENGTH for JSON
      // (node-oracledb sets lobPrefetchLength = maxSize = 32 MB), 0 otherwise.
      buffer.writeUB4(oraType == oraTypeJson ? tnsJsonMaxLength : 0);
      if (ttcFieldVersion >= ttcCcapFieldVersion12_2) {
        buffer.writeUB4(0); // oaccolid
      }
    }
  }

  /// Writes one define block per query column — the same field layout as
  /// bind metadata (node-oracledb shares `writeColumnMetadata` between the
  /// two). CLOB/BLOB defines carry the LOB prefetch cont-flag so the server
  /// keeps sending length + chunk size with every locator on FETCH rounds.
  void _writeDefineMetadata(WriteBuffer buffer, List<ColumnMetadata> columns) {
    for (final col in columns) {
      final oraType = col.oracleType == oraTypeVarchar2
          ? oraTypeVarchar
          : col.oracleType;
      buffer.writeUint8(oraType);
      buffer.writeUint8(ttcBindUseIndicators);
      // Precision and scale are always written as zero — the server
      // complains about any other value (node-oracledb writeColumnMetadata).
      buffer.writeUint8(0);
      buffer.writeUint8(0);
      buffer.writeUB4(_defineBufferSize(col));
      buffer.writeUB4(0); // max num elements (not array)
      buffer.writeUB4(
        oraType == oraTypeClob ||
                oraType == oraTypeBlob ||
                oraType == oraTypeJson
            ? tnsLobPrefetchFlag
            : 0,
      );
      buffer.writeUB4(0); // OID
      buffer.writeUB2(0); // version
      buffer.writeUB2(col.csfrm != 0 ? ttcCharsetUtf8 : 0);
      buffer.writeUint8(col.csfrm);
      // Max chars (LOB prefetch length): mirrors bind metadata — JSON
      // defines declare the 32 MB document bound.
      buffer.writeUB4(oraType == oraTypeJson ? tnsJsonMaxLength : 0);
      if (ttcFieldVersion >= ttcCcapFieldVersion12_2) {
        buffer.writeUB4(0); // oaccolid
      }
    }
  }

  /// Define buffer size per column type: byte-sized types use the described
  /// column width; fixed-width types use their wire size (node-oracledb
  /// DbType bufferSizeFactor values); CLOB/BLOB use the locator allocation.
  static int _defineBufferSize(ColumnMetadata col) {
    switch (col.oracleType) {
      case oraTypeClob:
      case oraTypeBlob:
        return _lobLocatorBindBufferSize;
      case oraTypeJson:
        return tnsJsonMaxLength;
      case oraTypeNumber:
      case oraTypeInteger:
      case oraTypeFloat:
      case oraTypeVarnum:
        return 22;
      case oraTypeDate:
        return 7;
      case oraTypeTimestamp:
      case oraTypeTimestampLtz:
        return 11;
      case oraTypeTimestampTz:
        return 13;
      default:
        return col.maxLength > 0 ? col.maxLength : 1;
    }
  }

  void _writeBindValue(WriteBuffer buffer, BindVariable bind) {
    final value = bind.value;
    final oraType = _wireTypeFor(bind);
    if (oraType == oraTypeJson) {
      // JSON binds always ship an OSON payload — node-oracledb excludes
      // JSON from the null-indicator shortcut and encodes null as the OSON
      // scalar null (writeBindParamsColumn → writeOson).
      _writeOsonValue(buffer, value);
      return;
    }
    if (value == null) {
      // NULL signaled by a zero-length indicator byte.
      buffer.writeUint8(0);
      return;
    }
    switch (oraType) {
      case oraTypeNumber:
        buffer.writeBytesWithLength(dt.encodeNumber(value as num));
        return;
      case oraTypeVarchar:
      case oraTypeString:
        buffer.writeBytesWithLength(
          Uint8List.fromList(utf8.encode(value as String)),
        );
        return;
      case oraTypeRaw:
        buffer.writeBytesWithLength(value as Uint8List);
        return;
      case oraTypeDate:
        buffer.writeBytesWithLength(dt.encodeDate(value as DateTime));
        return;
      case oraTypeTimestamp:
        buffer.writeBytesWithLength(dt.encodeTimestamp(value as DateTime));
        return;
      case oraTypeTimestampTz:
        // OracleTimestampTz binds carry their original offset on the wire.
        // A plain DateTime under an explicit TZ oraType is
        // encoded as its UTC instant wrapped at an explicit +00:00 offset
        // (full 13-byte payload): empirically (validated against 23ai
        // and 21c) the server mishandles an 11-byte offset-less TSTZ bind —
        // it echoes invalid all-zero zone bytes back, corrupting the value.
        if (value is OracleTimestampTz) {
          buffer.writeBytesWithLength(dt.encodeTimestampTz(value));
          return;
        }
        buffer.writeBytesWithLength(
          dt.encodeTimestampTz(
            OracleTimestampTz((value as DateTime).toUtc(), offsetMinutes: 0),
          ),
        );
        return;
      case oraTypeClob:
      case oraTypeBlob:
        // CLOB/BLOB binds put a locator on the wire, never the value bytes
        // (node-oracledb writeBindParamsColumn). The transport converts
        // String/Uint8List values into temporary-LOB locators before
        // encoding, so a raw value reaching this point is an internal
        // sequencing bug.
        if (value is LobLocator) {
          buffer.writeUB4(value.locator.length);
          buffer.writeBytesWithLength(value.locator);
          return;
        }
        throw OracleException(
          errorCode: oraBindTypeError,
          message:
              'Internal: ${oraType == oraTypeBlob ? 'BLOB' : 'CLOB'} '
              'bind value must be converted to a LOB locator before '
              'encoding (got ${value.runtimeType})',
        );
      default:
        throw OracleException(
          errorCode: oraBindTypeError,
          message: 'Unsupported bind oraType: $oraType',
        );
    }
  }

  /// Writes a JSON bind value: a 40-byte value-based "QLocator" followed by
  /// the OSON document as length-prefixed bytes (node-oracledb
  /// `packet.js writeOson` / `writeQLocator`, byte-for-byte).
  static void _writeOsonValue(WriteBuffer buffer, Object? value) {
    final oson = encodeOson(value);
    final locator = WriteBuffer()
      ..writeUint16BE(38) // internal length
      ..writeUint16BE(tnsLobQLocatorVersion)
      ..writeUint8(
        tnsLobLocFlagsValueBased | tnsLobLocFlagsBlob | tnsLobLocFlagsAbstract,
      )
      ..writeUint8(tnsLobLocFlagsInit)
      ..writeUint16BE(0) // additional flags
      ..writeUint16BE(1) // byt1
      ..writeUint32BE(0) // payload length (UInt64BE high word)
      ..writeUint32BE(oson.length) // payload length (UInt64BE low word)
      ..writeUint16BE(0) // unused
      ..writeUint16BE(0) // csid
      ..writeUint16BE(0) // unused
      ..writeUint32BE(0) // unused (UInt64BE × 2)
      ..writeUint32BE(0)
      ..writeUint32BE(0)
      ..writeUint32BE(0);
    final locatorBytes = locator.toBytes();
    assert(locatorBytes.length == 40, 'QLocator must be exactly 40 bytes');
    buffer.writeUB4(locatorBytes.length);
    buffer.writeBytesWithLength(locatorBytes);
    buffer.writeBytesWithLength(oson);
  }

  int _wireTypeFor(BindVariable bind) {
    // Normalize VARCHAR2 (9) to VARCHAR (1) for wire (Oracle accepts both but
    // node-oracledb sends type 1 / DB_TYPE_VARCHAR).
    if (bind.oraType == oraTypeVarchar2) return oraTypeVarchar;
    return bind.oraType;
  }

  /// Wire buffer size for a CLOB/BLOB bind: the locator allocation, matching
  /// node-oracledb's `DB_TYPE_CLOB`/`DB_TYPE_BLOB` bufferSizeFactor. The
  /// user-declared `maxSize` of a CLOB/BLOB [OracleBind] guards the
  /// materialized value length client-side and never reaches the wire.
  static const int _lobLocatorBindBufferSize = 112;

  int _maxSizeFor(BindVariable bind) {
    final wireType = _wireTypeFor(bind);
    if (wireType == oraTypeClob || wireType == oraTypeBlob) {
      return _lobLocatorBindBufferSize;
    }
    if (wireType == oraTypeJson) {
      // The wire metadata always declares the JSON maximum (node-oracledb
      // writeColumnMetadata); the user's OracleBind maxSize only guards the
      // returned document client-side and never reaches the wire.
      return tnsJsonMaxLength;
    }
    if (bind.maxSize != null) return bind.maxSize!;
    final v = bind.value;
    switch (_wireTypeFor(bind)) {
      case oraTypeNumber:
        return 22;
      case oraTypeVarchar:
      case oraTypeString:
        if (v is String) {
          final len = utf8.encode(v).length;
          return len <= 0 ? 1 : len;
        }
        return 1;
      case oraTypeRaw:
        if (v is Uint8List) {
          return v.isEmpty ? 1 : v.length;
        }
        return 1;
      case oraTypeDate:
        return 7;
      case oraTypeTimestamp:
        return 11;
      case oraTypeTimestampTz:
        return 13;
      default:
        return 1;
    }
  }

  int _csfrmFor(int oraType) {
    switch (oraType) {
      case oraTypeVarchar:
      case oraTypeString:
      case oraTypeClob:
        return ttcCsfrmImplicit;
      default:
        return 0;
    }
  }
}

/// TTC FETCH request — used to read more rows from an open cursor.
class FetchRequest extends Message {
  /// Creates a FETCH request for the given cursor.
  FetchRequest({
    required this.cursorId,
    required this.numRows,
    this.ttcFieldVersion = 24,
    super.sequence = 1,
  }) : super(messageType: ttcMsgTypeFunction);

  /// Cursor id to fetch from.
  final int cursorId;

  /// Number of rows requested.
  final int numRows;

  /// Negotiated TTC field version.
  final int ttcFieldVersion;

  @override
  void encode(WriteBuffer buffer) {
    buffer.writeUint8(messageType);
    buffer.writeUint8(ttcFuncFetch);
    buffer.writeUint8(sequence & 0xFF);
    if (ttcFieldVersion >= ttcCcapFieldVersion23_1Ext1) {
      buffer.writeUB8(0);
    }
    buffer.writeUB4(cursorId);
    buffer.writeUB4(numRows);
  }
}

/// Column metadata for a result set column.
class ColumnMetadata {
  /// Creates column metadata.
  const ColumnMetadata({
    required this.name,
    required this.oracleType,
    required this.maxLength,
    this.precision,
    this.scale,
    this.csfrm = 0,
  });

  /// Column name (uppercase as Oracle returns it).
  final String name;

  /// Oracle data type code.
  final int oracleType;

  /// Maximum column size in bytes.
  ///
  /// Meaningful for byte-sized types — `VARCHAR2`, `CHAR`, `NVARCHAR2`,
  /// `NCHAR`, and `RAW` — where it reflects the column's declared width
  /// (`RAW` uses the wire `maxSize` field; all other byte-sized types use the
  /// `size` field, matching node-oracledb `processColumnInfo`). For `NUMBER`,
  /// `DATE`, and other non-byte-sized types Oracle reports `size == 0`, so this
  /// value is **not meaningful** and must not be used to size allocations for
  /// those types — their precision/scale (NUMBER) or fixed wire width
  /// (DATE/TIMESTAMP) govern decoding instead.
  final int maxLength;

  /// Numeric precision.
  final int? precision;

  /// Numeric scale.
  final int? scale;

  /// Character set form (1 = implicit, 2 = NCHAR).
  final int csfrm;
}

/// Decoder-side bind metadata used to interpret OUT bind values returned in
/// the response stream. Order must match the order of binds sent on the wire.
class BindMetadata {
  /// Creates bind metadata for one bind variable.
  ///
  /// [dir] is required (no default): the IO_VECTOR consistency check in
  /// `_processIoVector` compares server-reported direction to this field, so
  /// silently defaulting to [BindDir.input] for an OUT/IN OUT bind would
  /// produce a spurious "client declared IN" protocol error at decode time.
  /// All call sites must pass the actual direction explicitly.
  const BindMetadata({required this.oraType, required this.dir, this.maxSize});

  /// Oracle wire-protocol type indicator.
  final int oraType;

  /// Maximum buffer size declared to the server (optional).
  final int? maxSize;

  /// Requested direction (IN or OUT) as declared by the client.
  final BindDir dir;
}

/// Result of an EXECUTE / FETCH response cycle.
///
/// Immutable: all fields are `final` and the list fields are
/// unmodifiable defensive copies, so decode state ([_DecodeState]) or any
/// caller-held list is never aliased into a response. Multi-round FETCH
/// accumulation happens in transport-local lists, never by mutating a
/// constructed response.
class ExecuteResponse {
  /// Creates an execute response. List arguments are defensively copied into
  /// unmodifiable views; empty inputs reuse canonical const empty lists so
  /// the common DML / COMMIT / fetch-round shapes allocate nothing per
  /// response for the lists they leave empty. (PL/SQL responses with OUT
  /// binds carry non-empty outBind lists by definition, so they always copy
  /// those.)
  ExecuteResponse({
    required this.isSuccess,
    this.cursorId = 0,
    List<ColumnMetadata> columnMetadata = const [],
    List<List<Object?>> rows = const [],
    List<Object?> outBindValues = const [],
    List<int> outBindIndices = const [],
    this.rowsAffected,
    this.moreRowsToFetch = false,
    this.errorCode,
    this.errorMessage,
    this.errorOffset,
  }) : columnMetadata = columnMetadata.isEmpty
           ? const <ColumnMetadata>[]
           : List<ColumnMetadata>.unmodifiable(columnMetadata),
       rows = rows.isEmpty
           ? const <List<Object?>>[]
           : List<List<Object?>>.unmodifiable(rows),
       outBindValues = outBindValues.isEmpty
           ? const <Object?>[]
           : List<Object?>.unmodifiable(outBindValues),
       outBindIndices = outBindIndices.isEmpty
           ? const <int>[]
           : List<int>.unmodifiable(outBindIndices);

  /// Whether the call succeeded (no Oracle error).
  final bool isSuccess;

  /// Server-assigned cursor id (0 if none).
  final int cursorId;

  /// Result column metadata (empty for DML). Unmodifiable.
  final List<ColumnMetadata> columnMetadata;

  /// Decoded rows (one `List<dynamic>` per row). The outer list is
  /// unmodifiable.
  final List<List<Object?>> rows;

  /// Decoded OUT bind values in the order they appear in the SQL. For
  /// non-PL/SQL responses this is always empty. Unmodifiable.
  final List<Object?> outBindValues;

  /// Index (in the bind list sent to the server) of each value in
  /// [outBindValues]. Lets higher layers map decoded values back to the
  /// original bind name or position. Unmodifiable.
  final List<int> outBindIndices;

  /// Rows affected by DML (null for SELECT before FETCH end).
  final int? rowsAffected;

  /// Whether the server reported more rows are available beyond [rows].
  final bool moreRowsToFetch;

  /// Oracle error code if [isSuccess] is false.
  final int? errorCode;

  /// Oracle error message if [isSuccess] is false.
  final String? errorMessage;

  /// Character offset into the SQL text where Oracle reports the error,
  /// when the server provided one. Null on success or when not applicable.
  final int? errorOffset;
}

/// Returns true if the accumulated TTC bytes contain a complete response
/// (i.e. a STATUS or END_OF_REQUEST terminal message). Returns false if the
/// scanner runs out of bytes mid-message ([BufferUnderflowException]),
/// signalling that more TNS DATA packets are still needed. Any other
/// [BufferException] means the stream is malformed on its face (no number
/// of additional packets can repair it) and is rethrown as an
/// [OracleException] with [oraProtocolError].
///
/// Used by the transport layer to detect end-of-response on Oracle pre-23.4
/// servers, which do not emit TNS-level end-of-request flags. Discards
/// decoded values; the actual response is decoded again by the caller via
/// [decodeExecuteResponse] once all bytes have arrived. The double pass is
/// cheap because typical responses fit in a single 8 KB SDU.
bool ttcStreamIsComplete(
  Uint8List data, {
  int ttcFieldVersion = 24,
  bool endOfRequestSupport = true,
  List<ColumnMetadata>? expectedColumns,
  List<BindMetadata>? bindMetadata,
}) {
  final buffer = ReadBuffer(data);
  final state = _DecodeState(
    isQuery: false,
    ttcFieldVersion: ttcFieldVersion,
    columns: expectedColumns != null
        ? List.of(expectedColumns)
        : <ColumnMetadata>[],
    bindMetadata: bindMetadata ?? const [],
    endOfRequestSupport: endOfRequestSupport,
    // The probe only needs to locate the terminal message; decode unsupported
    // types leniently here so an unsupported LONG column cannot make the probe
    // throw (the real decode pass raises the clear error).
    strictTypes: false,
  );
  try {
    while (buffer.hasRemaining && !state.endOfResponse) {
      final msgType = buffer.readUint8();
      _dispatch(msgType, buffer, state);
    }
    return state.endOfResponse;
  } on BufferUnderflowException {
    // The buffer genuinely ran out of bytes: more TNS packets are needed.
    return false;
  } on BufferException catch (e) {
    // Any other BufferException is a face-value malformation (sign-bit on an
    // unsigned read, integer-too-large, ...): waiting for more packets can
    // never repair it, so fail loud instead of spinning the receive loop.
    throw OracleException(
      errorCode: oraProtocolError,
      message:
          'Malformed TTC stream detected by the completion probe: '
          '${e.message}',
      cause: e,
    );
  }
}

/// Parses a complete TTC response payload (one or more TTC messages) into an
/// [ExecuteResponse]. Handles SELECT (DESCRIBE_INFO + ROW_HEADER + ROW_DATA +
/// ERROR-end-of-fetch) and DML (PARAMETER + ERROR) shapes plus piggybacks.
///
/// [previousRoundLastRow] is the last row accumulated by the transport from
/// the *previous* EXECUTE/FETCH round, when this payload is a continuation
/// FETCH. Oracle's duplicate-column optimization can mark a column of the
/// first row in a new round as "same as the previous row" — which lives in
/// the previous response. node-oracledb persists `statement.lastRowIndex`
/// across rounds (withData.js:250); this decoder is stateless per response,
/// so the transport threads the prior row in instead.
ExecuteResponse decodeExecuteResponse(
  Uint8List data, {
  required bool isQuery,
  int ttcFieldVersion = 24,
  bool endOfRequestSupport = true,
  List<ColumnMetadata>? expectedColumns,
  List<BindMetadata>? bindMetadata,
  bool preserveTimestampTimeZone = false,
  List<Object?>? previousRoundLastRow,
}) {
  final buffer = ReadBuffer(data);
  final state = _DecodeState(
    isQuery: isQuery,
    ttcFieldVersion: ttcFieldVersion,
    columns: expectedColumns != null
        ? List.of(expectedColumns)
        : <ColumnMetadata>[],
    bindMetadata: bindMetadata ?? const [],
    endOfRequestSupport: endOfRequestSupport,
    preserveTimestampTimeZone: preserveTimestampTimeZone,
    previousRoundLastRow: previousRoundLastRow,
  );

  try {
    while (buffer.hasRemaining && !state.endOfResponse) {
      final msgType = buffer.readUint8();
      _dispatch(msgType, buffer, state);
    }
  } on BufferException catch (e) {
    throw OracleException(
      errorCode: oraProtocolError,
      message: 'Protocol error: buffer underrun in execute response',
      cause: e,
    );
  }

  final isSuccess = state.errorNum == 0 || state.errorNum == null;
  // No ERROR message arrived at all for a successful query: the batch ended
  // without an end-of-fetch marker, so more rows are pending. Default to
  // fetching regardless of the echoed cursor id — node-oracledb thin
  // defaults moreRowsToFetch true and clears it ONLY on ORA-01403, and a
  // cached-cursor re-execute legitimately echoes cursorId == 0 while the
  // cursor stays open (the transport falls back to the request's own cursor
  // id). "Fetch when unsure" costs one round trip answered by ORA-01403;
  // "don't fetch when unsure" silently loses rows.
  if (isQuery && isSuccess && state.errorNum == null) {
    state.moreRowsToFetch = true;
  }
  return ExecuteResponse(
    isSuccess: isSuccess,
    cursorId: state.cursorId,
    columnMetadata: state.columns,
    rows: state.rows,
    outBindValues: state.outBindValues,
    outBindIndices: state.outBindIndices,
    rowsAffected: state.rowsAffected,
    moreRowsToFetch: state.moreRowsToFetch,
    errorCode: isSuccess ? null : state.errorNum,
    errorMessage: isSuccess ? null : state.errorMessage,
    errorOffset: isSuccess ? null : state.errorOffset,
  );
}

class _DecodeState {
  _DecodeState({
    required this.isQuery,
    required this.columns,
    this.bindMetadata = const [],
    this.ttcFieldVersion = 24,
    this.endOfRequestSupport = true,
    this.strictTypes = true,
    this.preserveTimestampTimeZone = false,
    this.previousRoundLastRow,
  });

  final bool isQuery;
  final int ttcFieldVersion;

  /// Opt-in: when true, `TIMESTAMP WITH TIME ZONE` columns
  /// decode to `OracleTimestampTz` instead of a UTC `DateTime`. Byte
  /// consumption is identical either way, so the completion probe can leave
  /// this false.
  final bool preserveTimestampTimeZone;

  /// When true (the real [decodeExecuteResponse] pass), decoding an
  /// unsupported column/bind type — currently LONG and LONG RAW — raises a
  /// clear [OracleException]. When false (the [ttcStreamIsComplete]
  /// completion probe), the same bytes are consumed leniently so the probe can
  /// still locate the terminal message; the real decode pass surfaces the
  /// unsupported error afterwards.
  final bool strictTypes;
  final List<BindMetadata> bindMetadata;
  final List<int> outBindIndices = [];
  final List<Object?> outBindValues = [];

  /// Set after the first PL/SQL OUT-bind ROW_DATA has been decoded. Tracked
  /// explicitly (not derived from `outBindValues.isEmpty`) so that an
  /// all-null first ROW_DATA does not re-enable decoding on a subsequent
  /// ROW_DATA packet. Each decode pass owns its own `_DecodeState`, so this
  /// flag resets naturally between `ttcStreamIsComplete` and
  /// `decodeExecuteResponse`.
  bool outBindsDecoded = false;

  /// Server-side TNS_CCAP_END_OF_REQUEST capability. On pre-23.4 servers
  /// (false), an ERROR TTC message terminates the response — no STATUS or
  /// END_OF_REQUEST follows. node-oracledb encodes the same rule via
  /// `endOfResponse = !endOfRequestSupport` in `base.js processErrorInfo`.
  final bool endOfRequestSupport;

  /// Last row accumulated by the transport from the previous FETCH round, if
  /// any. Used as the duplicate-column source when a duplicate bit appears on
  /// the first row of this response (see [decodeExecuteResponse]).
  final List<Object?>? previousRoundLastRow;
  List<ColumnMetadata> columns;
  final List<List<Object?>> rows = [];
  int cursorId = 0;
  int? rowsAffected;
  bool moreRowsToFetch = false;
  bool endOfResponse = false;
  int? errorNum;
  String? errorMessage;
  int? errorOffset;
  Uint8List? bitVector;
}

void _dispatch(int msgType, ReadBuffer buf, _DecodeState s) {
  switch (msgType) {
    case ttcMsgTypeDescribeInfo:
      _processDescribeInfo(buf, s);
      return;
    case ttcMsgTypeRowHeader:
      _processRowHeader(buf, s);
      return;
    case ttcMsgTypeRowData:
      _processRowData(buf, s);
      return;
    case ttcMsgTypeBitVector:
      _processBitVector(buf, s);
      return;
    case ttcMsgTypeIoVector:
      _processIoVector(buf, s);
      return;
    case ttcMsgTypeError:
      _processError(buf, s);
      return;
    case ttcMsgTypeWarning:
      skipTtcWarningBody(buf);
      return;
    case ttcMsgTypeStatus:
      _processStatus(buf, s);
      return;
    case ttcMsgTypeParameter:
      _processReturnParameter(buf);
      return;
    case ttcMsgTypeServerSidePiggyback:
      processServerSidePiggybackBody(buf);
      return;
    case ttcMsgTypeEndOfRequest:
      s.endOfResponse = true;
      return;
    default:
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'Unknown TTC message type in execute response: $msgType',
      );
  }
}

void _processDescribeInfo(ReadBuffer buf, _DecodeState s) {
  buf.readBytesWithLength(); // version bytes (chunked) — ignore
  buf.skipUB4(); // max row size
  final numCols = buf.readUB4();
  if (numCols > 0) {
    buf.skipUB1();
  }
  final columns = <ColumnMetadata>[];
  for (var i = 0; i < numCols; i++) {
    columns.add(_processColumnInfo(buf, s.ttcFieldVersion));
  }
  // "current date" — UB4 length, then chunked bytes if > 0.
  final dateBytes = buf.readUB4();
  if (dateBytes > 0) buf.readBytesWithLength();
  buf.skipUB4(); // dcbflag
  buf.skipUB4(); // dcbmdbz
  buf.skipUB4(); // dcbmnpr
  buf.skipUB4(); // dcbmxpr
  final tailBytes = buf.readUB4();
  if (tailBytes > 0) buf.readBytesWithLength();
  s.columns = columns;
}

ColumnMetadata _processColumnInfo(ReadBuffer buf, int ttcFieldVersion) {
  final dataType = buf.readUint8();
  buf.skipUB1(); // flags
  // Precision and scale are SIGNED Int8 on the wire (node-oracledb base.js
  // processColumnInfo uses readInt8): bare NUMBER and FLOAT report scale
  // -127 (0x81) as the "no declared scale" sentinel, which an unsigned read
  // would misparse as 129.
  final precisionRaw = buf.readUint8();
  final scaleRaw = buf.readUint8();
  final precision = precisionRaw > 127 ? precisionRaw - 256 : precisionRaw;
  final scale = scaleRaw > 127 ? scaleRaw - 256 : scaleRaw;
  final maxSize = buf.readUB4();
  buf.skipUB4(); // max num array elements
  buf.skipUB8(); // cont flags
  final oidLen = buf.readUB4();
  if (oidLen > 0) buf.readBytesWithLength();
  buf.skipUB2(); // version
  buf.skipUB2(); // charset id
  final csfrm = buf.readUint8();
  final size = buf.readUB4();
  // 12.2 oaccolid — only present when the server negotiated field version
  // >= 12.2. This mirrors the encode-side gate in
  // `ExecuteRequest._writeBindMetadata` and node-oracledb `processColumnInfo`
  // (base.js). Reading it unconditionally would misalign the buffer against a
  // pre-12.2 server that never sent the field.
  if (ttcFieldVersion >= ttcCcapFieldVersion12_2) {
    buf.skipUB4(); // oaccolid
  }
  buf.skipUB1(); // nullable
  buf.skipUB1(); // v7 name length
  // name
  String name = '';
  final nameLen = buf.readUB4();
  if (nameLen > 0) {
    final bytes = buf.readBytesWithLength();
    name = utf8.decode(bytes, allowMalformed: true);
  }
  // schema
  final schemaLen = buf.readUB4();
  if (schemaLen > 0) buf.readBytesWithLength();
  // type name
  final typeNameLen = buf.readUB4();
  if (typeNameLen > 0) buf.readBytesWithLength();
  buf.skipUB2(); // column position
  buf.skipUB4(); // uds flags
  // 23.1: domain schema / name — only present when server negotiated >= 23.1
  if (ttcFieldVersion >= ttcCcapFieldVersion23_1) {
    final domainSchemaLen = buf.readUB4();
    if (domainSchemaLen > 0) buf.readBytesWithLength();
    final domainNameLen = buf.readUB4();
    if (domainNameLen > 0) buf.readBytesWithLength();
  }
  // 23.1 ext 3: annotations
  if (ttcFieldVersion >= ttcCcapFieldVersion23_1Ext3) {
    final annoLen = buf.readUB4();
    if (annoLen > 0) {
      buf.skipUB1();
      final numAnno = buf.readUB4();
      buf.skipUB1();
      for (var i = 0; i < numAnno; i++) {
        buf.skipUB4();
        buf.readBytesWithLength(); // key
        final valBytes = buf.readUB4();
        if (valBytes > 0) buf.readBytesWithLength();
        buf.skipUB4(); // flags
      }
      buf.skipUB4(); // flags
    }
  }
  // 23.4 vector fields — only present when server negotiated field version >= 24
  if (ttcFieldVersion >= ttcCcapFieldVersion23_4) {
    buf.skipUB4(); // dimensions
    buf.skipUB1(); // format
    buf.skipUB1(); // flags
  }

  return ColumnMetadata(
    name: name,
    oracleType: dataType,
    maxLength: dataType == oraTypeRaw ? maxSize : size,
    precision: precision > 0 ? precision : null,
    scale: scale > 0 ? scale : null,
    csfrm: csfrm,
  );
}

void _processRowHeader(ReadBuffer buf, _DecodeState s) {
  buf.skipUB1(); // flags
  buf.skipUB2(); // num requests
  buf.skipUB4(); // iteration number
  buf.skipUB4(); // num iters
  buf.skipUB2(); // buffer length
  final bitVecLen = buf.readUB4();
  if (bitVecLen > 0) {
    s.bitVector = buf.readBytesWithLength();
  }
  final rxhridLen = buf.readUB4();
  if (rxhridLen > 0) buf.readBytesWithLength();
}

void _processRowData(ReadBuffer buf, _DecodeState s) {
  // PL/SQL responses use ROW_DATA after IO_VECTOR to ship OUT bind values.
  // SELECT responses use ROW_DATA after DESCRIBE_INFO + ROW_HEADER to ship
  // result rows. The two never mix on the same statement.
  if (!s.isQuery && s.outBindIndices.isNotEmpty) {
    // A single PL/SQL execution produces exactly one ROW_DATA with all
    // OUT bind values. `outBindsDecoded` is the authoritative guard against
    // re-decoding — relying on `outBindValues.isEmpty` would re-enable
    // decode whenever every OUT bind decoded to NULL.
    if (!s.outBindsDecoded) {
      for (final bindIdx in s.outBindIndices) {
        if (bindIdx >= s.bindMetadata.length) {
          // Server returned more OUT slots than the client declared binds.
          // Consume bytes conservatively so the stream stays aligned.
          buf.readBytesWithLength();
          buf.skipSB4();
          s.outBindValues.add(null);
          continue;
        }
        final meta = s.bindMetadata[bindIdx];
        final value = _decodeValueByOraType(
          buf,
          meta.oraType,
          strict: s.strictTypes,
          preserveTimestampTimeZone: s.preserveTimestampTimeZone,
          outMaxSize: meta.maxSize,
        );
        // After the value bytes, an OUT bind carries an SB4 "actual num bytes"
        // trailer (matches node-oracledb processColumnData !inFetch path).
        buf.skipSB4();
        s.outBindValues.add(value);
      }
      s.outBindsDecoded = true;
    }
    return;
  }

  final row = <Object?>[];
  for (var i = 0; i < s.columns.length; i++) {
    final col = s.columns[i];
    if (_isDuplicate(s.bitVector, i)) {
      // The duplicate source is the immediately preceding row: the last row
      // of this response, or — for the first row of a continuation FETCH —
      // the last row the transport accumulated in the previous round.
      final priorRow = s.rows.isNotEmpty ? s.rows.last : s.previousRoundLastRow;
      if (priorRow != null && priorRow.length <= i) {
        // The prior row is shorter than the duplicate column index. Reading
        // priorRow[i] would throw a RangeError deep in the decoder; fail
        // loud with a protocol error instead.
        throw OracleException(
          errorCode: oraProtocolError,
          message:
              'Duplicate-column bit set for column $i but the prior row '
              'only has ${priorRow.length} column(s) — duplicate-column '
              'prior-row length mismatch (stream misaligned or wrong '
              'previous-round row supplied)',
        );
      }
      if (priorRow == null) {
        // No prior row exists anywhere. A duplicate column ships no wire
        // bytes, so decoding it from the buffer would misalign the stream.
        // Real decode pass: fail loud instead of silently corrupting the
        // row. Lenient completion probe (which never receives a
        // previous-round row): skip the column without consuming bytes —
        // that is byte-accurate, and value correctness is irrelevant there.
        if (s.strictTypes) {
          throw OracleException(
            errorCode: oraProtocolError,
            message:
                'Duplicate-column bit set for column $i but no prior '
                'row is available (first row of the result set) — stream '
                'misaligned or previous-round row not supplied',
          );
        }
        row.add(null);
        continue;
      }
      row.add(priorRow[i]);
      continue;
    }
    row.add(
      _decodeColumnValue(
        buf,
        col,
        strict: s.strictTypes,
        preserveTimestampTimeZone: s.preserveTimestampTimeZone,
      ),
    );
  }
  s.rows.add(row);
  // A bit vector describes exactly ONE row: clear it after every decoded row
  // so a following ROW_DATA without its own BIT_VECTOR message decodes all
  // columns from the wire (node-oracledb withData.js:252 sets
  // `this.bitVector = null` at the end of processRowData). A stale vector
  // here would skip wire bytes and shear every later column in the batch.
  s.bitVector = null;
}

/// Decodes one length-prefixed value from [buf] using the Oracle type indicator
/// [oraType]. Shared by the OUT bind decode path and the SELECT column decode
/// path so both stay consistent under future type-handling changes.
///
/// [scale] is the column's declared scale when decoding a SELECT column
/// (null for bare `NUMBER`). The OUT-bind path always passes null:
/// `BindMetadata` carries no precision/scale, so OUT binds cannot honor the
/// fixed-scale-forces-double contract — they keep the int-vs-double
/// heuristic (documented limitation).
///
/// [csfrm] is the character set form when decoding a SELECT column (used to
/// reject NCLOB, which shares the CLOB type indicator). The OUT-bind path
/// passes 0: the public bind API cannot declare NCHAR types, and the
/// locator-level variable-length-charset flag is re-checked at read time.
///
/// [outMaxSize] is the OUT/IN OUT bind's declared `maxSize`, supplied only by
/// the OUT-bind decode path. Used by JSON (type 119) to enforce the declared
/// OSON byte bound on returned documents; CLOB/BLOB enforce theirs later in
/// the transport's materialize step, and other types are bounded server-side.
Object? _decodeValueByOraType(
  ReadBuffer buf,
  int oraType, {
  required bool strict,
  int? scale,
  bool preserveTimestampTimeZone = false,
  int csfrm = 0,
  int? outMaxSize,
}) {
  switch (oraType) {
    case oraTypeLong:
    case oraTypeLongRaw:
      // LONG / LONG RAW are not supported until proper
      // LONG/LOB streaming semantics are implemented. Decoding them through
      // the generic
      // length-prefix path (which treats a 0xFF prefix as null) would silently
      // corrupt a 255-byte LONG payload, so fail loud with a clear unsupported
      // error instead. The completion probe (strict == false) still consumes
      // the bytes so it can reach the terminal message.
      if (strict) {
        throw OracleException(
          errorCode: oraUnsupportedType,
          message:
              'LONG and LONG RAW columns are not supported yet (Oracle '
              'type $oraType). Support is planned (LOB/LONG '
              'streaming); until then these columns cannot be fetched.',
        );
      }
      buf.readBytesWithLength();
      return null;
    case oraTypeVarchar:
    case oraTypeVarchar2:
    case oraTypeString:
    case oraTypeChar:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      return utf8.decode(bytes, allowMalformed: true);
    case oraTypeRaw:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      return Uint8List.fromList(bytes);
    case oraTypeNumber:
    case oraTypeInteger:
    case oraTypeFloat:
    case oraTypeVarnum:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      if (!strict) return null; // probe pass: bytes consumed, value unused
      // The slice from readBytesWithLength already constrains the field, so we
      // do not need to pass `length` to decodeNumber here.
      // A declared fixed scale (> 0) forces double; scale null (bare
      // NUMBER) or 0 (e.g. NUMBER(10)) keeps the int heuristic.
      return dt.decodeNumber(ReadBuffer(bytes), forceDouble: (scale ?? 0) > 0);
    case oraTypeDate:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      // Probe pass stops after byte consumption: the value decoders below
      // can throw on data the wire legitimately carries (BCE dates,
      // region-id TIMESTAMP WITH TIME ZONE), and a probe throw poisons the
      // transport — the probe's contract is that decodable-shape bytes
      // never make it throw.
      if (!strict) return null;
      return dt.decodeDate(ReadBuffer(bytes));
    case oraTypeTimestampTz:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      if (!strict) return null; // probe pass: bytes consumed, value unused
      // Opt-in wrapper preserves the wire offset; default
      // stays the UTC DateTime contract.
      return preserveTimestampTimeZone
          ? dt.decodeTimestampTz(ReadBuffer(bytes))
          : dt.decodeTimestamp(ReadBuffer(bytes));
    case oraTypeTimestamp:
    case oraTypeTimestampLtz:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      if (!strict) return null; // probe pass: bytes consumed, value unused
      return dt.decodeTimestamp(ReadBuffer(bytes));
    case oraTypeClob:
    case oraTypeBlob:
    case oraTypeBfile:
      // LOB wire shape with the negotiated LOB-prefetch capability
      // (node-oracledb withData.js processColumnData): UB4 locator length
      // (0 ⇒ SQL NULL and nothing follows), then — except for BFILE — a UB8
      // LOB length (characters for CLOB, bytes for BLOB) and UB4 chunk
      // size, then the locator as length-prefixed bytes. CLOB and BLOB are
      // supported; BFILE/NCLOB fail loud rather than decode
      // silently. The lenient completion probe consumes the identical
      // bytes so the terminal message stays locatable.
      if (strict && oraType == oraTypeBfile) {
        throw OracleException(
          errorCode: oraUnsupportedType,
          message:
              'BFILE columns are not supported yet (Oracle type '
              '$oraType). Stories 4.1/4.2 implement CLOB and BLOB only.',
        );
      }
      if (strict && csfrm == ttcCsfrmNChar) {
        throw OracleException(
          errorCode: oraUnsupportedType,
          message:
              'NCLOB columns are not supported yet (Oracle type '
              '$oraType, NCHAR charset form). Stories 4.1/4.2 implement '
              'CLOB and BLOB only.',
        );
      }
      final locatorLen = buf.readUB4();
      if (locatorLen == 0) return null; // SQL NULL — no further bytes
      var lobLength = 0;
      var chunkSize = 0;
      if (oraType != oraTypeBfile) {
        lobLength = buf.readUB8();
        chunkSize = buf.readUB4();
      }
      final locator = buf.readBytesWithLength();
      if (!strict) return null; // probe pass: bytes consumed, value unused
      // Copy out of the response buffer view: the locator is sent back to
      // the server on subsequent LOB READ operations.
      return LobLocator(
        locator: Uint8List.fromList(locator),
        oracleType: oraType,
        length: lobLength,
        chunkSize: chunkSize,
      );
    case oraTypeJson:
      // Native JSON wire shape (node-oracledb packet.js readOson): the
      // LOB-prefetch form with the OSON document inline — UB4 locator-ish
      // length (0 ⇒ SQL NULL, nothing follows), UB8 size + UB4 chunk size
      // (both unused), length-prefixed OSON data, length-prefixed locator
      // (unused — the document already arrived, no LOB READ needed).
      final jsonMarker = buf.readUB4();
      if (jsonMarker == 0) return null; // SQL NULL
      buf.skipUB8(); // size (unused)
      buf.skipUB4(); // chunk size (unused)
      final osonBytes = buf.readBytesWithLength();
      buf.skipBytesChunked(); // locator (unused)
      if (!strict) return null; // probe pass: bytes consumed, value unused
      // OUT/IN OUT binds declare maxSize in OSON bytes; an oversized return
      // fails loud instead of truncating. Columns pass no
      // bound (outMaxSize == null).
      if (outMaxSize != null && osonBytes.length > outMaxSize) {
        throw OracleException(
          errorCode: oraBindTypeError,
          message:
              'JSON OUT bind returned ${osonBytes.length} OSON bytes '
              'but OracleBind maxSize is $outMaxSize — increase maxSize to '
              'at least the largest document the block can return',
        );
      }
      return decodeOson(Uint8List.fromList(osonBytes));
    default:
      buf.readBytesWithLength();
      return null;
  }
}

bool _isDuplicate(Uint8List? bitVector, int colIndex) {
  if (bitVector == null) return false;
  final byteNum = colIndex ~/ 8;
  final bitNum = colIndex % 8;
  if (byteNum >= bitVector.length) return false;
  return (bitVector[byteNum] & (1 << bitNum)) == 0;
}

Object? _decodeColumnValue(
  ReadBuffer buf,
  ColumnMetadata col, {
  required bool strict,
  bool preserveTimestampTimeZone = false,
}) => _decodeValueByOraType(
  buf,
  col.oracleType,
  strict: strict,
  scale: col.scale,
  preserveTimestampTimeZone: preserveTimestampTimeZone,
  csfrm: col.csfrm,
);

void _processBitVector(ReadBuffer buf, _DecodeState s) {
  final numColsSent = buf.readUB2();
  var numBytes = (s.columns.length / 8).floor();
  if (s.columns.length % 8 > 0) numBytes++;
  if (numBytes <= 0) numBytes = (numColsSent + 7) ~/ 8;
  s.bitVector = buf.readBytes(numBytes);
}

void _processIoVector(ReadBuffer buf, _DecodeState s) {
  buf.skipUB1(); // flag
  final temp16 = buf.readUB2();
  final temp32 = buf.readUB4();
  // Matches node-oracledb processIOVector (reference/node-oracledb/lib/thin/
  // protocol/messages/withData.js:399): `numBinds = temp32 * 256 + temp16`.
  // In practice the high field (`temp32`) is 0 for every call this driver
  // issues (PL/SQL is single-iter and bulk DML is not supported yet), so the
  // value collapses to `temp16`. The formula is preserved verbatim for
  // behavioral parity with the reference client.
  final numBinds = temp32 * 256 + temp16;
  buf.skipUB4(); // num iters this time
  buf.skipUB2(); // uac buffer length
  // Fast-fetch bit-vector length and rowid length are Oracle UB2
  // *variable-length* integers (a size byte then that many big-endian bytes),
  // NOT fixed two-byte raw lengths — confirmed against node-oracledb
  // processIOVector (reference/node-oracledb/lib/thin/protocol/messages/
  // withData.js:264-271), which reads both with `readUB2()` and then
  // `skipBytes(numBytes)`. Despite the "Len" suffix they must be read with
  // readUB2(), not readUint16BE(). The payloads (when present) are opaque
  // here — OUT-parameter handling does not consume fast-fetch or
  // rowid bytes — so they are skipped before the direction bytes are read.
  final fastFetchLen = buf.readUB2();
  if (fastFetchLen > 0) buf.skip(fastFetchLen);
  final rowidLen = buf.readUB2();
  if (rowidLen > 0) buf.skip(rowidLen);

  // Realistic Oracle bind counts are well under 65535 — Oracle's documented
  // hard limit is 65535 binds per statement. A computed `numBinds` beyond
  // that bound indicates either a corrupted stream or a server-protocol
  // change; bail out before iterating into unknown bytes.
  if (numBinds > 65535) {
    throw OracleException(
      errorCode: oraProtocolError,
      message: 'IO_VECTOR reports an implausible bind count: $numBinds',
    );
  }

  // Build the ordered list of OUT bind indices declared by the server. Reset
  // first so a re-decode pass (e.g. ttcStreamIsComplete + decodeExecuteResponse)
  // OR a second IO_VECTOR within the same pass does not double-count entries
  // or leak stale decoded values into the next ROW_DATA.
  s.outBindIndices.clear();
  s.outBindValues.clear();
  s.outBindsDecoded = false;
  for (var i = 0; i < numBinds; i++) {
    final dir = buf.readUint8();
    // Only the three documented TTC bind directions are valid. Any
    // other byte means the stream is misaligned or the server protocol has
    // drifted — raise a protocol error rather than silently treat unknown
    // bytes as outputs.
    if (dir != tnsBindDirInput &&
        dir != tnsBindDirOutput &&
        dir != tnsBindDirInputOutput) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'IO_VECTOR reports an unknown bind direction byte at bind '
            'index $i: $dir (expected 16, 32, or 48)',
      );
    }

    // When metadata is available for this bind, the server-reported
    // direction must agree with the client-declared one. A mismatch is a
    // hard error — silently following the server direction would re-decode
    // unexpected bytes and corrupt later result extraction. This check fires
    // for ALL direction flavors (including server-IN), so that a server
    // reporting IN for a client-declared OUT/IN OUT bind is caught as well
    // as the inverse cases. Missing metadata (i.e. `i >= bindMetadata.length`)
    // keeps the conservative stream behavior in `_processRowData`.
    if (i < s.bindMetadata.length) {
      final clientDir = s.bindMetadata[i].dir;
      final serverIsIn = dir == tnsBindDirInput;
      final serverIsOut = dir == tnsBindDirOutput;
      final serverName = serverIsIn ? 'IN' : (serverIsOut ? 'OUT' : 'IN OUT');
      if (clientDir == BindDir.input && !serverIsIn) {
        throw OracleException(
          errorCode: oraProtocolError,
          message:
              'IO_VECTOR bind direction mismatch at index $i: '
              'client declared IN but server reported $serverName ($dir)',
        );
      }
      if (clientDir == BindDir.output && !serverIsOut) {
        throw OracleException(
          errorCode: oraProtocolError,
          message:
              'IO_VECTOR bind direction mismatch at index $i: '
              'client declared output but server reported $serverName ($dir)',
        );
      }
      if (clientDir == BindDir.inputOutput && dir != tnsBindDirInputOutput) {
        throw OracleException(
          errorCode: oraProtocolError,
          message:
              'IO_VECTOR bind direction mismatch at index $i: '
              'client declared inputOutput but server reported $serverName ($dir)',
        );
      }
    }

    if (dir == tnsBindDirInput) continue;
    s.outBindIndices.add(i);
  }
}

/// Decoded fields of a TTC ERROR message body.
///
/// Produced by [decodeTtcErrorBody], which is shared between the EXECUTE
/// response decoder and the LOB operation decoder
/// (`lob_op_message.dart`) so the two cannot drift on the ERROR wire walk.
class TtcErrorInfo {
  /// Creates an error info record.
  const TtcErrorInfo({
    required this.num,
    this.message,
    this.offset,
    required this.cursorId,
    this.rowCount,
  });

  /// Oracle error number (0 = success / informational end-of-call).
  final int num;

  /// Server error message text (only present when [num] != 0).
  final String? message;

  /// Character offset into the SQL text, when the server provided one.
  final int? offset;

  /// Cursor id echoed by the server.
  final int cursorId;

  /// Row count from the extended error block (12.2+ servers only).
  final int? rowCount;
}

/// Walks the body of a TTC ERROR message (everything after the message-type
/// byte) and returns the decoded fields. Pure byte walk — response-level
/// semantics (ORA-01403 end-of-fetch, rowsAffected, terminal-on-pre-23.4)
/// stay with the callers.
TtcErrorInfo decodeTtcErrorBody(
  ReadBuffer buf, {
  required int ttcFieldVersion,
}) {
  buf.readUB4(); // end of call status
  buf.skipUB2(); // end-to-end seq num
  buf.skipUB4(); // current row number
  buf.skipUB2(); // error number (short)
  buf.skipUB2(); // array elem error
  buf.skipUB2(); // array elem error
  final cursorId = buf.readUB4(); // cursor id (node-oracledb uses readUB4)
  // Error position (SB4): character offset into the SQL text where Oracle
  // reports the parse/exec error. node-oracledb only surfaces it when >= 0
  // (negative is the "unknown" sentinel).
  final errorPos = buf.readSB4();
  buf.skipUB1(); // sql type
  buf.skipUB1(); // fatal?
  buf.skipUB1(); // flags
  buf.skipUB1(); // user cursor options
  buf.skipUB1(); // UPI param
  buf.skipUB1(); // warning flag
  // rowID — UB4 rba + UB2 partitionID + UB1 + UB4 blockNum + UB2 slotNum
  buf.skipUB4();
  buf.skipUB2();
  buf.skipUB1();
  buf.skipUB4();
  buf.skipUB2();
  buf.skipUB4(); // OS error
  buf.skipUB1(); // statement error
  buf.skipUB1(); // call number
  buf.skipUB2(); // padding
  buf.skipUB4(); // success iters
  final oerrddLen = buf.readUB4();
  if (oerrddLen > 0) buf.readBytesWithLength();
  // batch error codes
  final numErrs = buf.readUB2();
  if (numErrs > 0) {
    final firstByte = buf.readUint8();
    for (var i = 0; i < numErrs; i++) {
      if (firstByte == ttcLongLengthIndicator) buf.skipUB4();
      buf.readUB2();
    }
    if (firstByte == ttcLongLengthIndicator) buf.skip(1);
  }
  // batch error offsets
  final numOff = buf.readUB4();
  if (numOff > 0) {
    final firstByte = buf.readUint8();
    for (var i = 0; i < numOff; i++) {
      if (firstByte == ttcLongLengthIndicator) buf.skipUB4();
      buf.readUB4();
    }
    if (firstByte == ttcLongLengthIndicator) buf.skip(1);
  }
  // batch error messages
  final errMsgArr = buf.readUB2();
  if (errMsgArr > 0) {
    buf.skip(1);
    for (var i = 0; i < errMsgArr; i++) {
      buf.skipUB2();
      buf.readBytesWithLength();
      buf.skip(2);
    }
  }
  final num = buf.readUB4(); // extended error number
  // Extended row count and 20.1+ extras are version-gated (matches node-oracledb).
  // A pre-12.2 server does not send the UB8 row-count field at all, so
  // leave [rowCount] null rather than defaulting it to 0 — "the server reported
  // 0 rows" and "the server reported nothing" are distinct, and the public
  // `OracleResult.rowsAffected` contract surfaces the absence as null.
  int? rowCount;
  if (ttcFieldVersion >= ttcCcapFieldVersion12_2) {
    rowCount = buf.readUB8();
    if (ttcFieldVersion >= ttcCcapFieldVersion20_1) {
      buf.skipUB4(); // sql type
      buf.skipUB4(); // server checksum
    }
  }
  String? message;
  if (num != 0) {
    final bytes = buf.readBytesWithLength();
    message = utf8.decode(bytes, allowMalformed: true).trim();
  }
  return TtcErrorInfo(
    num: num,
    message: message,
    offset: errorPos >= 0 ? errorPos : null,
    cursorId: cursorId,
    rowCount: rowCount,
  );
}

void _processError(ReadBuffer buf, _DecodeState s) {
  final err = decodeTtcErrorBody(buf, ttcFieldVersion: s.ttcFieldVersion);
  final num = err.num;
  final rowCount = err.rowCount;
  s.cursorId = err.cursorId;
  // Always assign (including null) so a second _processError call on the
  // same state doesn't carry a stale offset value.
  s.errorOffset = err.offset;
  if (num != 0) {
    s.errorMessage = err.message;
  }
  s.errorNum = num;
  if (s.isQuery && num == 1403) {
    // ORA-01403 == end of fetch — not a real error for queries.
    s.errorNum = 0;
    s.moreRowsToFetch = false;
  } else if (s.isQuery && num == 0) {
    // ERROR num=0 on a query is a batch boundary, not end of fetch: the
    // requested iteration count was delivered and the cursor remains open
    // (node-oracledb thin only clears moreRowsToFetch on ORA-01403 —
    // statement.js defaults it true). Set it unconditionally: a cached-cursor
    // re-execute legitimately echoes cursorId == 0 while the original cursor
    // stays open, so gating on the echoed id silently truncated re-executed
    // multi-batch SELECTs to one prefetch window. The transport supplies the
    // request's own cursor id when the echo is 0.
    s.moreRowsToFetch = true;
  }
  if (!s.isQuery && num == 0) {
    s.rowsAffected = rowCount;
  }
  // Pre-23.4 servers emit no STATUS or END_OF_REQUEST after an ERROR — the
  // ERROR itself is the terminal message. Match node-oracledb thin
  // (`processErrorInfo`).
  if (!s.endOfRequestSupport) {
    s.endOfResponse = true;
  }
}

/// Skips the body of a TTC WARNING message. Shared with the LOB operation
/// decoder (`lob_op_message.dart`).
void skipTtcWarningBody(ReadBuffer buf) {
  buf.skipUB2(); // warning number (short)
  final numBytes = buf.readUB2();
  buf.skipUB2(); // flags
  if (numBytes > 0) buf.readBytesWithLength();
}

void _processStatus(ReadBuffer buf, _DecodeState s) {
  buf.skipUB4(); // call status
  buf.skipUB2(); // end-to-end seq num
  s.endOfResponse = true;
}

void _processReturnParameter(ReadBuffer buf) {
  // Drain the variable-length structure conservatively.
  final numParams = buf.readUB2();
  for (var i = 0; i < numParams; i++) {
    buf.skipUB4();
  }
  final txLen = buf.readUB2();
  if (txLen > 0) buf.skip(txLen);
  // The key/value-pairs and registration sections are always on the wire
  // (zero-length encoded as single 0x00 UB2 size bytes) — verified by live
  // capture on 23ai and 21c across DDL/DML/PL-SQL-CLOB-OUT shapes
  // (2026-06-11), matching node-oracledb `processReturnParameter`
  // (withData.js), which reads them unconditionally. An underflow here
  // surfaces BufferException, so the completion probe keeps its "need more
  // packets" semantics.
  final numKv = buf.readUB2();
  for (var i = 0; i < numKv; i++) {
    final keyLen = buf.readUB2();
    if (keyLen > 0) buf.readBytesWithLength();
    final valLen = buf.readUB2();
    if (valLen > 0) buf.readBytesWithLength();
    buf.readUB2(); // keyword num
  }
  final regLen = buf.readUB2();
  if (regLen > 0) buf.skip(regLen);
}

/// Consumes the body of a server-side piggyback message. Shared with the
/// LOB operation decoder (`lob_op_message.dart`).
///
/// Opcode numbering and wire shapes mirror node-oracledb's
/// `processServerSidePiggyBack` (`thin/protocol/messages/base.js`) and its
/// `TNS_SERVER_PIGGYBACK_*` constants. This driver carries no DRCP, edition,
/// or sessionless-transaction state, so every payload is drained and
/// discarded; what matters is consuming exactly the right number of bytes.
void processServerSidePiggybackBody(ReadBuffer buf) {
  final opcode = buf.readUint8();
  switch (opcode) {
    case 1: // QUERY_CACHE_INVALIDATION
    case 3: // TRACE_EVENT
      return;
    case 2: // OS_PID_MTS
      final numDtys = buf.readUB2();
      buf.skipUB1();
      buf.skip(numDtys);
      return;
    case 4: // SESS_RET (DRCP session state on return)
      buf.skipUB2();
      buf.skipUB1();
      final numElements = buf.readUB2();
      if (numElements > 0) {
        buf.skipUB1();
        for (var i = 0; i < numElements; i++) {
          if (buf.readUB2() > 0) buf.skipBytesChunked(); // key
          if (buf.readUB2() > 0) buf.skipBytesChunked(); // value
          buf.skipUB2(); // flags
        }
      }
      buf.skipUB4(); // session flags (DRCP session-changed: not supported)
      buf.skipUB4(); // session id
      buf.skipUB2(); // serial number
      return;
    case 5: // SYNC (session state change, e.g. after ALTER SESSION)
      buf.skipUB2(); // number of DTYs
      buf.skipUB1(); // length of DTYs
      final numElements = buf.readUB4();
      buf.skipUB1(); // length
      for (var i = 0; i < numElements; i++) {
        if (buf.readUB2() > 0) buf.skipBytesChunked(); // key
        if (buf.readUB2() > 0) buf.skipBytesChunked(); // value
        buf.skipUB2(); // keyword number (schema/edition/...: not tracked)
      }
      buf.skipUB4(); // overall flags
      return;
    case 7: // LTXID
      final n = buf.readUB4();
      if (n > 0) buf.readBytesWithLength();
      return;
    case 8: // AC_REPLAY_CONTEXT
      buf.skipUB2(); // number of DTYs
      buf.skipUB1(); // length of DTYs
      buf.skipUB4(); // flags
      buf.skipUB4(); // error code
      buf.skipUB1(); // queue
      final numBytes = buf.readUB4();
      if (numBytes > 0) buf.skipBytesChunked(); // replay context
      return;
    case 9: // EXT_SYNC
      buf.skipUB2();
      buf.skipUB1();
      return;
    case 10: // SESS_SIGNATURE
      buf.skipUB2(); // number of DTYs
      buf.skipUB1(); // length of DTY
      buf.skipUB8(); // signature flags
      buf.skipUB8(); // client signature
      buf.skipUB8(); // server signature
      return;
    default:
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'Unknown server-side piggyback opcode: $opcode',
      );
  }
}
