/// TTC LOB operation message (RPC function 96, `TNS_FUNC_LOB_OP`).
///
/// Implements the subset of node-oracledb's thin `LobOpMessage` this driver
/// uses: READ, WRITE and CREATE_TEMP (Stories 4.1/4.2), GET_CHUNK_SIZE (12.2),
/// and TRIM / GET_LENGTH (`OracleLob.trim()` / `refresh()`) — the last three
/// are plain `sendAmount` operations whose SB8 amount rides the
/// RETURN_PARAMETER reply. FREE_TEMP travels as a piggyback built by the
/// transport, mirroring node-oracledb `writeCloseTempLobsPiggyback`. The wire
/// format follows
/// `reference/node-oracledb/lib/thin/protocol/messages/lobOp.js` byte for
/// byte. Offsets and amounts are characters for CLOB and bytes for BLOB;
/// BLOB data payloads pass through unchanged (no charset conversion).
library;

import 'dart:typed_data';

import '../../errors.dart';
import '../buffer.dart';
import '../constants.dart';
import 'base.dart';
import 'execute_message.dart'
    show decodeTtcErrorBody, processServerSidePiggybackBody, skipTtcWarningBody;

/// TTC LOB operation request.
class LobOpRequest extends Message {
  /// Creates a LOB operation request.
  ///
  /// [operation] is one of the `tnsLobOp*` constants. For READ pass
  /// [sourceLocator], a 1-based [sourceOffset] (characters for CLOB, bytes
  /// for BLOB), `sendAmount: true` and the requested [amount]. For WRITE
  /// pass [sourceLocator], [sourceOffset] and [data]. For CREATE_TEMP pass
  /// a zeroed [sourceLocator] buffer, the charset form in [sourceOffset]
  /// (0 for BLOB), the Oracle type in [destOffset] and [tnsDurationSession]
  /// in [destLength] (node-oracledb `lob.js create()`).
  LobOpRequest({
    required this.operation,
    this.sourceLocator,
    this.sourceOffset = 0,
    this.destOffset = 0,
    this.destLength = 0,
    this.sendAmount = false,
    this.amount = 0,
    this.data,
    this.ttcFieldVersion = 24,
    super.sequence = 1,
  }) : super(messageType: ttcMsgTypeFunction);

  /// LOB operation code (`tnsLobOpRead`, `tnsLobOpWrite`, ...).
  final int operation;

  /// Source LOB locator bytes, when the operation targets an existing LOB.
  final Uint8List? sourceLocator;

  /// Source offset (UB8 on the wire). 1-based offset for read/write
  /// (characters for CLOB, bytes for BLOB); carries the charset form for
  /// CREATE_TEMP.
  final int sourceOffset;

  /// Destination offset (UB8 on the wire). Carries the Oracle type indicator
  /// for CREATE_TEMP.
  final int destOffset;

  /// Destination locator length field; carries [tnsDurationSession] for
  /// CREATE_TEMP.
  final int destLength;

  /// Whether the amount field is sent (and an SB8 amount is expected back in
  /// the RETURN_PARAMETER message).
  final bool sendAmount;

  /// Amount value written when [sendAmount] is true (characters to read for
  /// CLOB READ, bytes for BLOB READ).
  final int amount;

  /// Data payload for WRITE operations (UTF-8/UTF-16BE bytes for CLOB, raw
  /// bytes for BLOB).
  final Uint8List? data;

  /// Negotiated TTC field version.
  final int ttcFieldVersion;

  @override
  void encode(WriteBuffer buffer) {
    buffer.writeUint8(messageType); // TNS_MSG_TYPE_FUNCTION (3)
    buffer.writeUint8(ttcLobOp); // 96
    buffer.writeUint8(sequence & 0xFF);
    if (ttcFieldVersion >= ttcCcapFieldVersion23_1Ext1) {
      buffer.writeUB8(0); // token number
    }
    final locator = sourceLocator;
    if (locator == null) {
      buffer.writeUint8(0); // source locator pointer (null)
      buffer.writeUB4(0); // source locator length
    } else {
      buffer.writeUint8(1);
      buffer.writeUB4(locator.length);
    }
    buffer.writeUint8(0); // dest locator pointer (null)
    buffer.writeUB4(destLength); // dest locator length / temp-LOB duration
    buffer.writeUB4(0); // short source offset
    buffer.writeUB4(0); // short dest offset
    buffer.writeUint8(operation == tnsLobOpCreateTemp ? 1 : 0); // charset ptr
    buffer.writeUint8(0); // short amount pointer
    // Boolean-out pointer: set for operations that return a flag or create a
    // temporary LOB (node-oracledb lobOp.js `operations` list — of which
    // only CREATE_TEMP is used by this driver).
    buffer.writeUint8(operation == tnsLobOpCreateTemp ? 1 : 0);
    buffer.writeUB4(operation);
    buffer.writeUint8(0); // SCN pointer
    buffer.writeUint8(0); // SCN array length
    buffer.writeUB8(sourceOffset);
    buffer.writeUB8(destOffset);
    buffer.writeUint8(sendAmount ? 1 : 0); // amount pointer
    for (var i = 0; i < 3; i++) {
      buffer.writeUint16BE(0); // three fixed two-byte zero fields
    }
    if (locator != null) {
      buffer.writeBytes(locator);
    }
    if (operation == tnsLobOpCreateTemp) {
      // CREATE_TEMP charset id: AL16UTF16 for a national (NCLOB) temp LOB,
      // UTF-8 for every other temp LOB (CLOB and BLOB). The character set form
      // rides in [sourceOffset] for CREATE_TEMP (node-oracledb lob.js create()
      // passes `sourceOffset: dbType._csfrm`), so the NCHAR form selects the
      // UTF-16 charset here exactly as node-oracledb lobOp.js does. Without
      // this an NCLOB temp LOB would be created as a UTF-8 CLOB and its
      // UTF-16BE data would be corrupted.
      buffer.writeUB4(
        sourceOffset == ttcCsfrmNChar ? ttcCharsetAl16Utf16 : ttcCharsetUtf8,
      );
    }
    final writeData = data;
    if (writeData != null) {
      buffer.writeUint8(ttcMsgTypeLobData);
      buffer.writeBytesWithLength(writeData);
    }
    if (sendAmount) {
      buffer.writeUB8(amount);
    }
  }
}

/// Decoded result of a LOB operation response.
class LobOpResponse {
  /// Creates a LOB operation response.
  LobOpResponse({
    required this.isSuccess,
    this.data,
    this.updatedLocator,
    this.amount,
    this.errorCode,
    this.errorMessage,
  });

  /// Whether the operation succeeded (no Oracle error).
  final bool isSuccess;

  /// Concatenated LOB_DATA payload bytes (READ operations). Null when the
  /// response carried no LOB_DATA message.
  final Uint8List? data;

  /// Locator bytes echoed back by the server (updated state — e.g. the real
  /// locator after CREATE_TEMP). Null when the request had no source locator.
  final Uint8List? updatedLocator;

  /// SB8 amount from the RETURN_PARAMETER message when the request set
  /// `sendAmount` (e.g. LOB length for GET_LENGTH).
  final int? amount;

  /// Oracle error code if [isSuccess] is false.
  final int? errorCode;

  /// Oracle error message if [isSuccess] is false.
  final String? errorMessage;
}

class _LobDecodeState {
  final List<Uint8List> dataChunks = [];
  Uint8List? updatedLocator;
  int? amount;
  int? errorNum;
  String? errorMessage;
  bool endOfResponse = false;
}

void _walkLobOpMessage(
  int msgType,
  ReadBuffer buf,
  _LobDecodeState s, {
  required int operation,
  required int sourceLocatorLength,
  required bool sendAmount,
  required int ttcFieldVersion,
  required bool endOfRequestSupport,
}) {
  switch (msgType) {
    case ttcMsgTypeLobData:
      s.dataChunks.add(buf.readBytesWithLength());
      return;
    case ttcMsgTypeParameter:
      // RETURN_PARAMETER (node-oracledb lobOp.js processReturnParameter):
      // the server echoes the (possibly updated) locator as raw bytes of the
      // source-locator length, then CREATE_TEMP carries a UB2 charset and a
      // UB1 flag byte, while sendAmount operations carry an SB8 amount.
      if (sourceLocatorLength > 0) {
        s.updatedLocator = Uint8List.fromList(
          buf.readBytes(sourceLocatorLength),
        );
      }
      if (operation == tnsLobOpCreateTemp) {
        buf.skipUB2(); // charset
        buf.skipUB1(); // trailing flags
      } else if (sendAmount) {
        s.amount = buf.readSB8();
      }
      return;
    case ttcMsgTypeError:
      final err = decodeTtcErrorBody(buf, ttcFieldVersion: ttcFieldVersion);
      s.errorNum = err.num;
      if (err.num != 0) {
        s.errorMessage = err.message;
      }
      // Pre-23.4 servers emit no STATUS or END_OF_REQUEST after an ERROR —
      // the ERROR itself is the terminal message (same rule as the EXECUTE
      // decoder).
      if (!endOfRequestSupport) {
        s.endOfResponse = true;
      }
      return;
    case ttcMsgTypeWarning:
      skipTtcWarningBody(buf);
      return;
    case ttcMsgTypeStatus:
      buf.skipUB4(); // call status
      buf.skipUB2(); // end-to-end seq num
      s.endOfResponse = true;
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
        message:
            'Unknown TTC message type in LOB operation response: '
            '$msgType',
      );
  }
}

/// Returns true if the accumulated TTC bytes contain a complete LOB operation
/// response. Mirrors [ttcStreamIsComplete] for EXECUTE responses: used by the
/// transport to detect end-of-response on pre-23.4 servers, which emit no
/// TNS-level end-of-request flags. Returns false on buffer underrun
/// ([BufferUnderflowException] — more packets needed); any other
/// [BufferException] is a face-value malformation and is rethrown as an
/// [OracleException] with [oraProtocolError].
bool lobOpStreamIsComplete(
  Uint8List payload, {
  required int operation,
  required int sourceLocatorLength,
  required bool sendAmount,
  int ttcFieldVersion = 24,
  bool endOfRequestSupport = true,
}) {
  final buffer = ReadBuffer(payload);
  final state = _LobDecodeState();
  try {
    while (buffer.hasRemaining && !state.endOfResponse) {
      final msgType = buffer.readUint8();
      _walkLobOpMessage(
        msgType,
        buffer,
        state,
        operation: operation,
        sourceLocatorLength: sourceLocatorLength,
        sendAmount: sendAmount,
        ttcFieldVersion: ttcFieldVersion,
        endOfRequestSupport: endOfRequestSupport,
      );
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
          'Malformed TTC stream detected by the LOB completion probe: '
          '${e.message}',
      cause: e,
    );
  }
}

/// Incremental, amortized-linear counterpart of [lobOpStreamIsComplete].
///
/// The stateless probe re-walks (and, in the transport, re-concatenates) the
/// whole accumulated response once per inbound TNS packet, so a multi-megabyte
/// LOB_DATA message spanning N packets costs O(N x bytes). This probe keeps the
/// accumulated bytes in a doubling buffer and remembers where the last fully
/// parsed unit ended — a whole TTC message, or one chunk of a chunked
/// (`0xFE`-prefixed) LOB_DATA message — so each [add] only examines the bytes
/// that arrived since. Verdicts are identical to [lobOpStreamIsComplete] on the
/// same bytes.
class LobOpStreamProbe {
  LobOpStreamProbe({
    required this.operation,
    required this.sourceLocatorLength,
    required this.sendAmount,
    this.ttcFieldVersion = 24,
    this.endOfRequestSupport = true,
  });

  final int operation;
  final int sourceLocatorLength;
  final bool sendAmount;
  final int ttcFieldVersion;
  final bool endOfRequestSupport;

  static const int _longLengthIndicator = 0xFE;

  Uint8List _buf = Uint8List(0);
  int _length = 0;
  // Start of the first unparsed unit.
  int _pos = 0;
  // True while inside a chunked LOB_DATA message (after its 0xFE marker).
  bool _inChunkedLobData = false;
  final _LobDecodeState _state = _LobDecodeState();

  /// Every byte added so far. A view over the internal buffer when its spare
  /// capacity is small; an exact-size copy otherwise, so a caller that keeps
  /// the result (a decoded LOB value aliases it) never pins up to 2x the data.
  /// Call once, after the final [add].
  Uint8List get bytes {
    final view = Uint8List.sublistView(_buf, 0, _length);
    return _buf.length - _length > _length ~/ 8
        ? Uint8List.fromList(view)
        : view;
  }

  /// Appends [chunk] and returns whether the response is now complete.
  bool add(Uint8List chunk) {
    final needed = _length + chunk.length;
    if (needed > _buf.length) {
      var capacity = _buf.isEmpty ? 4096 : _buf.length;
      while (capacity < needed) {
        capacity *= 2;
      }
      final grown = Uint8List(capacity)..setRange(0, _length, _buf);
      _buf = grown;
    }
    _buf.setRange(_length, needed, chunk);
    _length = needed;
    return _advance();
  }

  bool _advance() {
    try {
      while (!_state.endOfResponse && _pos < _length) {
        final view = Uint8List.sublistView(_buf, _pos, _length);
        final buffer = ReadBuffer(view);
        if (_inChunkedLobData) {
          final chunkSize = buffer.readUB4();
          if (chunkSize == 0) {
            _inChunkedLobData = false;
          } else {
            buffer.skip(chunkSize);
          }
        } else if (view[0] == ttcMsgTypeLobData &&
            view.length > 1 &&
            view[1] == _longLengthIndicator) {
          // LOB_DATA with chunked payload: consume the marker and walk its
          // chunks one at a time instead of re-walking the whole message.
          buffer.skip(2);
          _inChunkedLobData = true;
        } else {
          final msgType = buffer.readUint8();
          _walkLobOpMessage(
            msgType,
            buffer,
            _state,
            operation: operation,
            sourceLocatorLength: sourceLocatorLength,
            sendAmount: sendAmount,
            ttcFieldVersion: ttcFieldVersion,
            endOfRequestSupport: endOfRequestSupport,
          );
        }
        _pos += buffer.position;
      }
    } on BufferUnderflowException {
      return false;
    } on BufferException catch (e) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'Malformed TTC stream detected by the LOB completion probe: '
            '${e.message}',
        cause: e,
      );
    }
    return _state.endOfResponse;
  }
}

/// Parses a complete LOB operation response payload into a [LobOpResponse].
LobOpResponse decodeLobOpResponse(
  Uint8List payload, {
  required int operation,
  required int sourceLocatorLength,
  required bool sendAmount,
  int ttcFieldVersion = 24,
  bool endOfRequestSupport = true,
}) {
  final buffer = ReadBuffer(payload);
  final state = _LobDecodeState();
  try {
    while (buffer.hasRemaining && !state.endOfResponse) {
      final msgType = buffer.readUint8();
      _walkLobOpMessage(
        msgType,
        buffer,
        state,
        operation: operation,
        sourceLocatorLength: sourceLocatorLength,
        sendAmount: sendAmount,
        ttcFieldVersion: ttcFieldVersion,
        endOfRequestSupport: endOfRequestSupport,
      );
    }
  } on BufferException catch (e) {
    throw OracleException(
      errorCode: oraProtocolError,
      message: 'Protocol error: buffer underrun in LOB operation response',
      cause: e,
    );
  }

  final isSuccess = state.errorNum == null || state.errorNum == 0;
  Uint8List? data;
  if (state.dataChunks.length == 1) {
    data = state.dataChunks.single;
  } else if (state.dataChunks.isNotEmpty) {
    final total = state.dataChunks.fold<int>(0, (sum, c) => sum + c.length);
    data = Uint8List(total);
    var offset = 0;
    for (final chunk in state.dataChunks) {
      data.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
  }
  return LobOpResponse(
    isSuccess: isSuccess,
    data: data,
    updatedLocator: state.updatedLocator,
    amount: state.amount,
    errorCode: isSuccess ? null : state.errorNum,
    errorMessage: isSuccess ? null : state.errorMessage,
  );
}
