/// Real Oracle TTC EXECUTE message (RPC OALL8).
///
/// Implements the wire format used by Oracle Database 12.2+ (validated against
/// Oracle 23ai), modeled after node-oracledb's thin client. The previous
/// implementation in this file used an invented format that Oracle rejected
/// at the first byte after auth; Story 6.3 replaced it.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../errors.dart';
import '../buffer.dart';
import '../constants.dart';
import '../data_types.dart' as dt;
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
  }) : oraType = oraType ?? _inferType(value);

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
    if (value == null) return oraTypeVarchar;
    if (value is String) return oraTypeVarchar;
    if (value is int) return oraTypeNumber;
    if (value is double) return oraTypeNumber;
    if (value is DateTime) return oraTypeDate;
    if (value is Uint8List) return oraTypeRaw;
    throw OracleException(
      errorCode: oraBindTypeError,
      message: 'Unsupported bind value type: ${value.runtimeType}. '
          'Supported types: String, int, double, DateTime, Uint8List, null',
    );
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
    super.sequence = 1,
  })  : assert(!(isQuery && isPlSql),
            'a statement cannot be both query and PL/SQL'),
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
        message: 'Internal: bindNames.length (${bindNames!.length}) != '
            'bindValues.length ($numParams)',
      );
    }
    final hasSql = cursorId == 0 || sqlBytes.isNotEmpty;
    final effectiveNumIters = isQuery ? numIters : _numExecs;

    // Execute options + DML options
    var options = 0;
    var dmlOptions = 0;
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

    // no defines (we let server describe)
    buffer.writeUint8(0);
    buffer.writeUB4(0);

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

    // Bind metadata + values
    if (numParams > 0) {
      _writeBindMetadata(buffer, binds);
      // Single ROW_DATA message containing all bind values for one iteration.
      buffer.writeUint8(ttcMsgTypeRowData);
      for (final bind in binds) {
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
      buffer.writeUB4(0); // cont flag
      buffer.writeUB4(0); // OID
      buffer.writeUB2(0); // version
      buffer.writeUB2(csfrm != 0 ? ttcCharsetUtf8 : 0);
      buffer.writeUint8(csfrm);
      buffer.writeUB4(0); // max chars (LOB prefetch length)
      if (ttcFieldVersion >= ttcCcapFieldVersion12_2) {
        buffer.writeUB4(0); // oaccolid
      }
    }
  }

  void _writeBindValue(WriteBuffer buffer, BindVariable bind) {
    final value = bind.value;
    final oraType = _wireTypeFor(bind);
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
            Uint8List.fromList(utf8.encode(value as String)));
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
      default:
        throw OracleException(
          errorCode: oraBindTypeError,
          message: 'Unsupported bind oraType: $oraType',
        );
    }
  }

  int _wireTypeFor(BindVariable bind) {
    // Normalize VARCHAR2 (9) to VARCHAR (1) for wire (Oracle accepts both but
    // node-oracledb sends type 1 / DB_TYPE_VARCHAR).
    if (bind.oraType == oraTypeVarchar2) return oraTypeVarchar;
    return bind.oraType;
  }

  int _maxSizeFor(BindVariable bind) {
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
      default:
        return 1;
    }
  }

  int _csfrmFor(int oraType) {
    switch (oraType) {
      case oraTypeVarchar:
      case oraTypeString:
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

  /// Maximum size in bytes.
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
  const BindMetadata({
    required this.oraType,
    this.maxSize,
    this.dir = BindDir.input,
  });

  /// Oracle wire-protocol type indicator.
  final int oraType;

  /// Maximum buffer size declared to the server (optional).
  final int? maxSize;

  /// Requested direction (IN or OUT) as declared by the client.
  final BindDir dir;
}

/// Result of an EXECUTE / FETCH response cycle.
class ExecuteResponse {
  /// Creates an execute response.
  ExecuteResponse({
    required this.isSuccess,
    this.cursorId = 0,
    this.columnMetadata = const [],
    this.rows = const [],
    this.outBindValues = const [],
    this.outBindIndices = const [],
    this.rowsAffected,
    this.moreRowsToFetch = false,
    this.errorCode,
    this.errorMessage,
    this.errorOffset,
  });

  /// Whether the call succeeded (no Oracle error).
  final bool isSuccess;

  /// Server-assigned cursor id (0 if none).
  int cursorId;

  /// Result column metadata (empty for DML).
  List<ColumnMetadata> columnMetadata;

  /// Decoded rows (one `List<dynamic>` per row).
  List<List<Object?>> rows;

  /// Decoded OUT bind values in the order they appear in the SQL. For
  /// non-PL/SQL responses this is always empty.
  List<Object?> outBindValues;

  /// Index (in the bind list sent to the server) of each value in
  /// [outBindValues]. Lets higher layers map decoded values back to the
  /// original bind name or position.
  List<int> outBindIndices;

  /// Rows affected by DML (null for SELECT before FETCH end).
  int? rowsAffected;

  /// Whether the server reported more rows are available beyond [rows].
  bool moreRowsToFetch;

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
/// scanner runs out of bytes mid-message, signalling that more TNS DATA
/// packets are still needed.
///
/// Used by the transport layer to detect end-of-response on Oracle pre-23.4
/// servers, which do not emit TNS-level end-of-request flags. Discards
/// decoded values; the actual response is decoded again by the caller via
/// [decodeExecuteResponse] once all bytes have arrived. The double pass is
/// cheap because typical responses fit in a single 8 KB SDU.
bool ttcStreamIsComplete(Uint8List data,
    {int ttcFieldVersion = 24,
    bool endOfRequestSupport = true,
    List<ColumnMetadata>? expectedColumns,
    List<BindMetadata>? bindMetadata}) {
  final buffer = ReadBuffer(data);
  final state = _DecodeState(
    isQuery: false,
    ttcFieldVersion: ttcFieldVersion,
    columns:
        expectedColumns != null ? List.of(expectedColumns) : <ColumnMetadata>[],
    bindMetadata: bindMetadata ?? const [],
    endOfRequestSupport: endOfRequestSupport,
  );
  try {
    while (buffer.hasRemaining && !state.endOfResponse) {
      final msgType = buffer.readUint8();
      _dispatch(msgType, buffer, state);
    }
    return state.endOfResponse;
  } on BufferException {
    return false;
  }
}

/// Parses a complete TTC response payload (one or more TTC messages) into an
/// [ExecuteResponse]. Handles SELECT (DESCRIBE_INFO + ROW_HEADER + ROW_DATA +
/// ERROR-end-of-fetch) and DML (PARAMETER + ERROR) shapes plus piggybacks.
ExecuteResponse decodeExecuteResponse(Uint8List data,
    {required bool isQuery,
    int ttcFieldVersion = 24,
    bool endOfRequestSupport = true,
    List<ColumnMetadata>? expectedColumns,
    List<BindMetadata>? bindMetadata}) {
  final buffer = ReadBuffer(data);
  final state = _DecodeState(
    isQuery: isQuery,
    ttcFieldVersion: ttcFieldVersion,
    columns:
        expectedColumns != null ? List.of(expectedColumns) : <ColumnMetadata>[],
    bindMetadata: bindMetadata ?? const [],
    endOfRequestSupport: endOfRequestSupport,
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
  // Cursor is still open when: query succeeded, no ORA-01403 end-of-fetch
  // received, and the server assigned a non-zero cursor id. In that case the
  // first batch may be incomplete — signal the transport to FETCH more rows.
  if (isQuery && isSuccess && state.cursorId != 0 && state.errorNum == null) {
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
  _DecodeState(
      {required this.isQuery,
      required this.columns,
      this.bindMetadata = const [],
      this.ttcFieldVersion = 24,
      this.endOfRequestSupport = true});

  final bool isQuery;
  final int ttcFieldVersion;
  final List<BindMetadata> bindMetadata;
  final List<int> outBindIndices = [];
  final List<Object?> outBindValues = [];

  /// Server-side TNS_CCAP_END_OF_REQUEST capability. On pre-23.4 servers
  /// (false), an ERROR TTC message terminates the response — no STATUS or
  /// END_OF_REQUEST follows. node-oracledb encodes the same rule via
  /// `endOfResponse = !endOfRequestSupport` in `base.js processErrorInfo`.
  final bool endOfRequestSupport;
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
      _processWarning(buf);
      return;
    case ttcMsgTypeStatus:
      _processStatus(buf, s);
      return;
    case ttcMsgTypeParameter:
      _processReturnParameter(buf);
      return;
    case ttcMsgTypeServerSidePiggyback:
      _processServerSidePiggyback(buf);
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
  final precision = buf.readUint8();
  final scale = buf.readUint8();
  final maxSize = buf.readUB4();
  buf.skipUB4(); // max num array elements
  buf.skipUB8(); // cont flags
  final oidLen = buf.readUB4();
  if (oidLen > 0) buf.readBytesWithLength();
  buf.skipUB2(); // version
  buf.skipUB2(); // charset id
  final csfrm = buf.readUint8();
  final size = buf.readUB4();
  // 12.2 oaccolid
  buf.skipUB4();
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
    // Guard against double-decode: a single PL/SQL execution produces exactly
    // one ROW_DATA with all OUT bind values; if called again, skip.
    if (s.outBindValues.isEmpty) {
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
        final value = _decodeValueByOraType(buf, meta.oraType);
        // After the value bytes, an OUT bind carries an SB4 "actual num bytes"
        // trailer (matches node-oracledb processColumnData !inFetch path).
        buf.skipSB4();
        s.outBindValues.add(value);
      }
    }
    return;
  }

  final row = <Object?>[];
  for (var i = 0; i < s.columns.length; i++) {
    final col = s.columns[i];
    if (_isDuplicate(s.bitVector, i) && s.rows.isNotEmpty) {
      row.add(s.rows.last[i]);
      continue;
    }
    row.add(_decodeColumnValue(buf, col));
  }
  s.rows.add(row);
  // bitVector intentionally NOT cleared here — it persists for all ROW_DATA
  // messages under the same ROW_HEADER. It is reset only when a new
  // ROW_HEADER or BIT_VECTOR message arrives.
}

/// Decodes one length-prefixed value from [buf] using the Oracle type indicator
/// [oraType]. Shared by the OUT bind decode path and the SELECT column decode
/// path so both stay consistent under future type-handling changes.
Object? _decodeValueByOraType(ReadBuffer buf, int oraType) {
  switch (oraType) {
    case oraTypeVarchar:
    case oraTypeVarchar2:
    case oraTypeString:
    case oraTypeChar:
    case oraTypeLong:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      return utf8.decode(bytes, allowMalformed: true);
    case oraTypeRaw:
    case oraTypeLongRaw:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      return Uint8List.fromList(bytes);
    case oraTypeNumber:
    case oraTypeInteger:
    case oraTypeFloat:
    case oraTypeVarnum:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      return dt.decodeNumber(ReadBuffer(bytes));
    case oraTypeDate:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      return dt.decodeDate(ReadBuffer(bytes));
    case oraTypeTimestamp:
    case oraTypeTimestampTz:
    case oraTypeTimestampLtz:
      final bytes = buf.readBytesWithLength();
      if (bytes.isEmpty) return null;
      return dt.decodeTimestamp(ReadBuffer(bytes));
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

Object? _decodeColumnValue(ReadBuffer buf, ColumnMetadata col) =>
    _decodeValueByOraType(buf, col.oracleType);

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
  // node-oracledb: readUB2() | (readUB4() << 16) — low 16 bits | high 32 bits shifted
  final numBinds = temp16 | (temp32 << 16);
  buf.skipUB4(); // num iters this time
  buf.skipUB2(); // uac buffer length
  final fastFetchLen = buf.readUB2();
  if (fastFetchLen > 0) buf.skip(fastFetchLen);
  final rowidLen = buf.readUB2();
  if (rowidLen > 0) buf.skip(rowidLen);
  // Build the ordered list of OUT bind indices declared by the server. Reset
  // first so a re-decode pass (e.g. ttcStreamIsComplete + decodeExecuteResponse)
  // does not double-count entries.
  s.outBindIndices.clear();
  for (var i = 0; i < numBinds; i++) {
    final dir = buf.readUint8();
    // tnsBindDirOutput (16) and tnsBindDirInputOutput (48) both mean the
    // server will return a value for this bind in a subsequent ROW_DATA.
    if (dir != tnsBindDirInput) {
      s.outBindIndices.add(i);
    }
  }
}

void _processError(ReadBuffer buf, _DecodeState s) {
  buf.readUB4(); // end of call status
  buf.skipUB2(); // end-to-end seq num
  buf.skipUB4(); // current row number
  buf.skipUB2(); // error number (short)
  buf.skipUB2(); // array elem error
  buf.skipUB2(); // array elem error
  s.cursorId = buf.readUB4(); // cursor id (node-oracledb uses readUB4)
  // Error position (SB4): character offset into the SQL text where Oracle
  // reports the parse/exec error. node-oracledb only surfaces it when >= 0
  // (negative is the "unknown" sentinel). Always assign (including null) so
  // a second _processError call on the same state doesn't carry a stale value.
  final errorPos = buf.readSB4();
  s.errorOffset = errorPos >= 0 ? errorPos : null;
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
  // Extended row count and 20.1+ extras are version-gated (matches node-oracledb)
  var rowCount = 0;
  if (s.ttcFieldVersion >= ttcCcapFieldVersion12_2) {
    rowCount = buf.readUB8();
    if (s.ttcFieldVersion >= ttcCcapFieldVersion20_1) {
      buf.skipUB4(); // sql type
      buf.skipUB4(); // server checksum
    }
  }
  if (num != 0) {
    final bytes = buf.readBytesWithLength();
    s.errorMessage = utf8.decode(bytes, allowMalformed: true).trim();
  }
  s.errorNum = num;
  if (s.isQuery && num == 1403) {
    // ORA-01403 == end of fetch — not a real error for queries.
    s.errorNum = 0;
    s.moreRowsToFetch = false;
  } else if (s.isQuery && num == 0) {
    // Successful end of query response. moreRowsToFetch defaults false.
    s.moreRowsToFetch = false;
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

void _processWarning(ReadBuffer buf) {
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

void _processServerSidePiggyback(ReadBuffer buf) {
  final opcode = buf.readUint8();
  // Best-effort scan: try to consume well-known opcodes; unknowns terminate.
  switch (opcode) {
    case 4: // LTXID
      final n = buf.readUB4();
      if (n > 0) buf.readBytesWithLength();
      return;
    case 6: // QUERY_CACHE_INVALIDATION
    case 7: // TRACE_EVENT
      return;
    case 8: // OS_PID_MTS
      final numDtys = buf.readUB2();
      buf.skipUB1();
      buf.skip(numDtys);
      return;
    default:
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'Unknown server-side piggyback opcode: $opcode',
      );
  }
}
