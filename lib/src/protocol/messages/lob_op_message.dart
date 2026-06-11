/// TTC LOB operation message (RPC function 96, `TNS_FUNC_LOB_OP`).
///
/// Implements the subset of node-oracledb's thin `LobOpMessage` needed for
/// Story 4.1 CLOB support: READ, WRITE, and CREATE_TEMP (FREE_TEMP travels as
/// a piggyback built by the transport, mirroring node-oracledb
/// `writeCloseTempLobsPiggyback`). The wire format follows
/// `reference/node-oracledb/lib/thin/protocol/messages/lobOp.js` byte for
/// byte.
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
  /// [sourceLocator], a 1-based [sourceOffset] (characters for CLOB),
  /// `sendAmount: true` and the requested [amount]. For WRITE pass
  /// [sourceLocator], [sourceOffset] and [data]. For CREATE_TEMP pass a
  /// zeroed [sourceLocator] buffer, the charset form in [sourceOffset], the
  /// Oracle type in [destOffset] and [tnsDurationSession] in [destLength]
  /// (node-oracledb `lob.js create()`).
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

  /// Source offset (UB8 on the wire). 1-based character offset for CLOB
  /// read/write; carries the charset form for CREATE_TEMP.
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
  /// CLOB READ).
  final int amount;

  /// Data payload for WRITE operations (UTF-8 bytes for CLOB).
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
      // Implicit (database) charset only — NCLOB is out of Story 4.1 scope.
      buffer.writeUB4(ttcCharsetUtf8);
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
        s.updatedLocator = Uint8List.fromList(buf.readBytes(sourceLocatorLength));
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
        message: 'Unknown TTC message type in LOB operation response: '
            '$msgType',
      );
  }
}

/// Returns true if the accumulated TTC bytes contain a complete LOB operation
/// response. Mirrors [ttcStreamIsComplete] for EXECUTE responses: used by the
/// transport to detect end-of-response on pre-23.4 servers, which emit no
/// TNS-level end-of-request flags. Returns false on buffer underrun
/// (more packets needed).
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
      _walkLobOpMessage(msgType, buffer, state,
          operation: operation,
          sourceLocatorLength: sourceLocatorLength,
          sendAmount: sendAmount,
          ttcFieldVersion: ttcFieldVersion,
          endOfRequestSupport: endOfRequestSupport);
    }
    return state.endOfResponse;
  } on BufferException {
    return false;
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
      _walkLobOpMessage(msgType, buffer, state,
          operation: operation,
          sourceLocatorLength: sourceLocatorLength,
          sendAmount: sendAmount,
          ttcFieldVersion: ttcFieldVersion,
          endOfRequestSupport: endOfRequestSupport);
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
  if (state.dataChunks.isNotEmpty) {
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
