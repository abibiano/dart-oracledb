/// Base message class for all TTC RPC messages.
///
/// Ported from node-oracledb lib/thin/protocol/messages/base.js
library;

import 'dart:typed_data';

import '../constants.dart';
import '../packet.dart';

/// Error information returned from Oracle.
class ErrorInfo {
  int num = 0;
  int cursorId = 0;
  int pos = -1;
  String message = '';
  RowID? rowID;
  int rowCount = 0;
  bool isRecoverable = false;
  List<BatchError>? batchErrors;
}

/// Batch error for array DML operations.
class BatchError {
  final int errorCode;
  String message = '';
  int offset = 0;

  BatchError(this.errorCode);
}

/// Base class for all RPC messages supporting encode/decode functions.
class Message {
  /// Associated connection
  final dynamic connection;

  /// Error information from response
  final ErrorInfo errorInfo = ErrorInfo();

  /// Message type (TNS_MSG_TYPE_*)
  int messageType = tnsMsgTypeFunction;

  /// Function code (TNS_FUNC_*)
  int functionCode = 0;

  /// Call status from response
  int callStatus = 0;

  /// Whether to flush out binds
  bool flushOutBinds = false;

  /// Whether response is complete
  bool endOfResponse = false;

  /// End-to-end sequence number
  int endToEndSeqNum = 0;

  /// Whether an error occurred
  bool errorOccurred = false;

  /// Warning from response
  Object? warning;

  /// Deferred error for later processing
  Object? deferredErr;

  Message(this.connection);

  /// Pre-process hook called before encoding.
  void preProcess() {}

  /// Post-process hook called after decoding.
  Future<void> postProcess() async {}

  /// Encodes the message to the write buffer.
  void encode(WritePacket buf) {
    // Override in subclasses
  }

  /// Writes the function header to the buffer.
  void writeFunctionHeader(WritePacket buf) {
    writePiggybacks(buf);
    buf.writeUInt8(messageType);
    buf.writeUInt8(functionCode);
    buf.writeSeqNum();
    final ttcVersion = buf.caps.ttcFieldVersion as int? ?? 0;
    if (ttcVersion >= tnsCcapFieldVersion231Ext1) {
      buf.writeUB8(0); // token number
    }
  }

  /// Processes error information from the response.
  void processErrorInfo(ReadPacket buf) {
    callStatus = buf.readUB4(); // end of call status
    buf.skipUB2(); // end to end seq number
    buf.skipUB4(); // current row number
    buf.skipUB2(); // error number
    buf.skipUB2(); // array elem error
    buf.skipUB2(); // array elem error
    errorInfo.cursorId = buf.readUB2(); // cursor id
    final errorPos = buf.readSB2(); // error position
    buf.skipUB1(); // sql type (19c and earlier)
    buf.skipUB1(); // fatal?
    buf.skipUB1(); // flags
    buf.skipUB1(); // user cursor options
    buf.skipUB1(); // UPI parameter
    final warnFlag = buf.readUInt8(); // warning flag
    if ((warnFlag & tnsWarnCompilationCreate) != 0) {
      warning = 'Compilation warning';
    }
    errorInfo.rowID = buf.readRowID(); // rowid
    buf.skipUB4(); // OS error
    buf.skipUB1(); // statement error
    buf.skipUB1(); // call number
    buf.skipUB2(); // padding
    buf.skipUB4(); // success iters

    final numBytes = buf.readUB4(); // oerrdd (logical rowid)
    if (numBytes > 0) {
      buf.skipBytesChunked();
    }

    // batch error codes
    final numErrors = buf.readUB2();
    if (numErrors > 0) {
      errorInfo.batchErrors = [];
      final firstByte = buf.readUInt8();
      for (var i = 0; i < numErrors; i++) {
        if (firstByte == tnsLongLengthIndicator) {
          buf.skipUB4(); // chunk length ignored
        }
        final errorCode = buf.readUB2();
        errorInfo.batchErrors!.add(BatchError(errorCode));
      }
      if (firstByte == tnsLongLengthIndicator) {
        buf.skipBytes(1); // ignore end marker
      }
    }

    // batch error offset
    final numOffsets = buf.readUB4();
    if (numOffsets > 0) {
      if (numOffsets > 65535) {
        throw StateError('Too many batch errors');
      }
      final firstByte = buf.readUInt8();
      for (var i = 0; i < numOffsets; i++) {
        if (firstByte == tnsLongLengthIndicator) {
          buf.skipUB4(); // chunk length ignored
        }
        final offset = buf.readUB4();
        if (i < numErrors && errorInfo.batchErrors != null) {
          errorInfo.batchErrors![i].offset = offset;
        }
      }
      if (firstByte == tnsLongLengthIndicator) {
        buf.skipBytes(1); // ignore end marker
      }
    }

    // batch error messages
    final errMsgArr = buf.readUB2();
    if (errMsgArr > 0) {
      buf.skipBytes(1); // ignore packed size
      for (var i = 0; i < errMsgArr; i++) {
        buf.skipUB2(); // skip chunk length
        final msg = buf.readStr(csfrm: csfrmImplicit);
        if (msg != null && errorInfo.batchErrors != null && i < errorInfo.batchErrors!.length) {
          errorInfo.batchErrors![i].message = msg;
        }
        buf.skipBytes(2); // ignore end marker
      }
    }

    errorInfo.num = buf.readUB4(); // error number (extended)
    errorInfo.rowCount = buf.readUB8(); // row number (extended)

    // fields added in Oracle Database 20c
    final ttcFieldVersion = buf.caps.ttcFieldVersion;
    if (ttcFieldVersion >= tnsCcapFieldVersion201) {
      buf.skipUB4(); // sql type
      buf.skipUB4(); // server checksum
    }

    // error message
    if (errorInfo.num != 0) {
      errorOccurred = true;
      if (errorPos >= 0) {
        errorInfo.pos = errorPos;
      }
      final msg = buf.readStr(csfrm: csfrmImplicit);
      if (msg != null) {
        errorInfo.message = msg.trim();
      }
    }
    errorInfo.isRecoverable = recoverableErrors.contains(errorInfo.num);

    final endOfReqSupport = connection?.nscon?.endOfRequestSupport as bool? ?? false;
    endOfResponse = !endOfReqSupport;
  }

  /// Processes return parameters from the response.
  void processReturnParameter(ReadPacket buf) {
    // Override in subclasses
  }

  /// Processes warning information from the response.
  void processWarningInfo(ReadPacket buf) {
    final errNum = buf.readUB2(); // warning number
    final numBytes = buf.readUB2(); // length of warning message
    buf.skipUB2(); // flags
    if (errNum != 0 && numBytes > 0) {
      final message = buf.readStr(csfrm: csfrmImplicit);
      if (message != null) {
        warning = Exception(message.trim());
      }
    }
  }

  /// Decodes the response from the read buffer.
  void decode(ReadPacket buf) {
    process(buf);
  }

  /// Main response processing loop.
  void process(ReadPacket buf) {
    endOfResponse = false;
    flushOutBinds = false;
    do {
      savePoint(buf);
      final msgType = buf.readUInt8();
      processMessage(buf, msgType);
    } while (!endOfResponse);
  }

  /// Saves the current buffer position for potential restore.
  void savePoint(ReadPacket buf) {
    buf.savePoint();
  }

  /// Processes a single message based on its type.
  void processMessage(ReadPacket buf, int messageType) {
    switch (messageType) {
      case tnsMsgTypeError:
        processErrorInfo(buf);
      case tnsMsgTypeWarning:
        processWarningInfo(buf);
      case tnsMsgTypeStatus:
        callStatus = buf.readUB4();
        endToEndSeqNum = buf.readUB2();
        final statusEndOfReqSupport = connection?.nscon?.endOfRequestSupport as bool? ?? false;
        endOfResponse = !statusEndOfReqSupport;
      case tnsMsgTypeParameter:
        processReturnParameter(buf);
      case tnsMsgTypeServerSidePiggyback:
        processServerSidePiggyBack(buf);
      case tnsMsgTypeEndOfRequest:
        endOfResponse = true;
      default:
        throw StateError(
          'Unexpected message type: $messageType at pos ${buf.pos}, packet ${buf.packetNum}',
        );
    }
  }

  /// Processes server-side piggyback messages.
  void processServerSidePiggyBack(ReadPacket buf) {
    final opcode = buf.readUInt8();
    switch (opcode) {
      case tnsServerPiggybackLtxid:
        final numBytes = buf.readUB4();
        if (numBytes > 0) {
          final ltxid = buf.readBytesWithLength();
          if (ltxid != null && connection != null) {
            connection._ltxid = Uint8List.fromList(ltxid);
          }
        }
      case tnsServerPiggybackQueryCacheInvalidation:
      case tnsServerPiggybackTraceEvent:
        // pass
        break;
      case tnsServerPiggybackOsPidMts:
        final numDtys = buf.readUB2();
        buf.skipUB1();
        buf.skipBytes(numDtys);
      case tnsServerPiggybackSync:
        buf.skipUB2(); // skip number of DTYs
        buf.skipUB1(); // skip length of DTYs
        final numElements = buf.readUB4();
        buf.skipBytes(1); // skip length
        for (var i = 0; i < numElements; i++) {
          var numBytes = buf.readUB2();
          String? keyTextValue;
          Uint8List? value;
          if (numBytes > 0) {
            keyTextValue = buf.readStr(csfrm: csfrmImplicit);
          }
          numBytes = buf.readUB2();
          if (numBytes > 0) {
            value = buf.readBytesWithLength();
          }
          final keywordNum = buf.readUB2();
          if (keywordNum == tnsKeywordNumTransactionId && value != null) {
            _updateSessionlessTxnState(value);
          } else if (keywordNum == tnsKeywordNumCurrentSchema && connection != null) {
            connection.currentSchema = keyTextValue;
          } else if (keywordNum == tnsKeywordNumEdition && connection != null) {
            connection._edition = keyTextValue;
          }
        }
        buf.skipUB4(); // skip overall flags
      case tnsServerPiggybackExtSync:
        buf.skipUB2();
        buf.skipUB1();
      case tnsServerPiggybackAcReplayContext:
        buf.skipUB2(); // skip number of DTYs
        buf.skipUB1(); // skip length of DTYs
        buf.skipUB4(); // skip flags
        buf.skipUB4(); // skip error code
        buf.skipUB1(); // skip queue
        final numBytes = buf.readUB4();
        if (numBytes > 0) {
          buf.skipBytesChunked();
        }
      case tnsServerPiggybackSessRet:
        buf.skipUB2();
        buf.skipUB1();
        final numElements = buf.readUB2();
        if (numElements > 0) {
          buf.skipUB1();
          for (var i = 0; i < numElements; i++) {
            var temp16 = buf.readUB2();
            if (temp16 > 0) {
              buf.skipBytesChunked();
            }
            temp16 = buf.readUB2();
            if (temp16 > 0) {
              buf.skipBytesChunked();
            }
            buf.skipUB2();
          }
        }
        final flags = buf.readUB4();
        if ((flags & tnsSessgetSessionChanged) != 0) {
          if (connection?._drcpEstablishSession == true) {
            connection?.statementCache?.clearCursors();
          }
        }
        if (connection != null) {
          connection._drcpEstablishSession = false;
        }
        buf.skipUB4(); // session id
        buf.skipUB2(); // serial number
      case tnsServerPiggybackSessSignature:
        buf.skipUB2(); // number of dtys
        buf.skipUB1(); // length of dty
        buf.skipUB8(); // signature flags
        buf.skipUB8(); // client signature
        buf.skipUB8(); // server signature
      default:
        throw StateError('Unknown server side piggyback: $opcode');
    }
  }

  /// Writes piggybacks to the buffer.
  void writePiggybacks(WritePacket buf) {
    // Don't write piggybacks if not authenticated yet
    if (connection?._protocol?.connInProgress == true) {
      return;
    }

    if (connection?._currentSchemaModified == true) {
      _writeCurrentSchemaPiggyback(buf);
    }
    if (connection?.statementCache?._cursorsToClose?.isNotEmpty == true &&
        connection?._drcpEstablishSession != true) {
      writeCloseCursorsPiggyBack(buf);
    }
    if (connection?._actionModified == true ||
        connection?._clientIdentifierModified == true ||
        connection?._dbopModified == true ||
        connection?._clientInfoModified == true ||
        connection?._moduleModified == true) {
      _writeEndToEndPiggybacks(buf);
    }
    final tempLobsSize = (connection?._tempLobsTotalSize as int?) ?? 0;
    if (tempLobsSize > 0) {
      writeCloseTempLobsPiggyback(buf);
    }
  }

  /// Writes piggyback header.
  void writePiggybackHeader(WritePacket buf, int funcCode) {
    buf.writeUInt8(tnsMsgTypePiggyback);
    buf.writeUInt8(funcCode);
    buf.writeSeqNum();
    if (buf.caps.ttcFieldVersion >= tnsCcapFieldVersion231Ext1) {
      buf.writeUB8(0); // token number
    }
  }

  /// Writes close cursors piggyback.
  void writeCloseCursorsPiggyBack(WritePacket buf) {
    writePiggybackHeader(buf, tnsFuncCloseCursors);
    buf.writeUInt8(1);
    connection?.statementCache?.writeCursorsToClose(buf);
  }

  /// Writes close temp LOBs piggyback.
  void writeCloseTempLobsPiggyback(WritePacket buf) {
    final lobsToClose = (connection?._tempLobsToClose as List<Uint8List>?) ?? <Uint8List>[];
    // ignore: prefer_const_declarations
    final opCode = tnsLobOpFreeTemp | tnsLobOpArray;

    writePiggybackHeader(buf, tnsFuncLobOp);

    buf.writeUInt8(1); // pointer
    buf.writeUB4((connection?._tempLobsTotalSize as int?) ?? 0);
    buf.writeUInt8(0); // dest LOB locator
    buf.writeUB4(0);
    buf.writeUB4(0); // source LOB locator
    buf.writeUB4(0);
    buf.writeUInt8(0); // source LOB offset
    buf.writeUInt8(0); // dest LOB offset
    buf.writeUInt8(0); // charset
    buf.writeUB4(opCode);
    buf.writeUInt8(0); // scn
    buf.writeUB4(0); // LOB scn
    buf.writeUB8(0); // LOB scnl
    buf.writeUB8(0);
    buf.writeUInt8(0);

    // array LOB fields
    buf.writeUInt8(0);
    buf.writeUB4(0);
    buf.writeUInt8(0);
    buf.writeUB4(0);
    buf.writeUInt8(0);
    buf.writeUB4(0);
    for (final val in lobsToClose) {
      buf.writeBytes(val);
    }

    // Reset values
    if (connection != null) {
      connection._tempLobsToClose = <Uint8List>[];
      connection._tempLobsTotalSize = 0;
    }
  }

  void _writeCurrentSchemaPiggyback(WritePacket buf) {
    writePiggybackHeader(buf, tnsFuncSetSchema);
    buf.writeUInt8(1);
    final schema = (connection?.currentSchema as String?) ?? '';
    final bytes = Uint8List.fromList(schema.codeUnits);
    buf.writeUB4(bytes.length);
    buf.writeBytesWithLength(bytes);
  }

  void _writeEndToEndPiggybacks(WritePacket buf) {
    var flags = 0;

    // determine which flags to send
    if (connection?._actionModified == true) {
      flags |= tnsEndToEndAction;
    }
    if (connection?._clientIdentifierModified == true) {
      flags |= tnsEndToEndClientIdentifier;
    }
    if (connection?._clientInfoModified == true) {
      flags |= tnsEndToEndClientInfo;
    }
    if (connection?._moduleModified == true) {
      flags |= tnsEndToEndModule;
    }
    if (connection?._dbOpModified == true) {
      flags |= tnsEndToEndDbop;
    }

    // write initial packet data
    writePiggybackHeader(buf, tnsFuncSetEndToEndAttr);
    buf.writeUInt8(0); // pointer (cidnam)
    buf.writeUInt8(0); // pointer (cidser)
    buf.writeUB4(flags);

    final clientIdBytes = _writeEndEndTraceValue(
      buf,
      connection?._clientIdentifier as String?,
      (connection?._clientIdentifierModified as bool?) ?? false,
    );
    final moduleBytes = _writeEndEndTraceValue(
      buf,
      connection?._module as String?,
      (connection?._moduleModified as bool?) ?? false,
    );
    final actionBytes = _writeEndEndTraceValue(
      buf,
      connection?._action as String?,
      (connection?._actionModified as bool?) ?? false,
    );

    // write unsupported bits
    buf.writeUInt8(0); // pointer (cideci)
    buf.writeUB4(0); // length (cideci)
    buf.writeUInt8(0); // cidcct
    buf.writeUB4(0); // cidecs

    final clientInfoBytes = _writeEndEndTraceValue(
      buf,
      connection?._clientInfo as String?,
      (connection?._clientInfoModified as bool?) ?? false,
    );

    // write unsupported bits
    buf.writeUInt8(0); // pointer (cideci)
    buf.writeUB4(0); // length (cideci)
    buf.writeUInt8(0); // cidcct
    buf.writeUB4(0); // cidecs

    final dbOpBytes = _writeEndEndTraceValue(
      buf,
      connection?._dbOp as String?,
      (connection?._dbOpModified as bool?) ?? false,
    );

    // write strings
    if (connection?._clientIdentifierModified == true && connection?._clientIdentifier != null) {
      buf.writeBytesWithLength(clientIdBytes!);
    }
    if (connection?._moduleModified == true && connection?._module != null) {
      buf.writeBytesWithLength(moduleBytes!);
    }
    if (connection?._actionModified == true && connection?._action != null) {
      buf.writeBytesWithLength(actionBytes!);
    }
    if (connection?._clientInfoModified == true && connection?._clientInfo != null) {
      buf.writeBytesWithLength(clientInfoBytes!);
    }
    if (connection?._dbOpModified == true && connection?._dbOp != null) {
      buf.writeBytesWithLength(dbOpBytes!);
    }

    // reset flags and values
    if (connection != null) {
      connection._actionModified = false;
      connection._action = '';
      connection._clientIdentifierModified = false;
      connection._clientIdentifier = '';
      connection._clientInfoModified = false;
      connection._clientInfo = '';
      connection._dbOpModified = false;
      connection._dbOp = '';
      connection._moduleModified = false;
      connection._module = '';
    }
  }

  Uint8List? _writeEndEndTraceValue(WritePacket buf, String? value, bool modified) {
    Uint8List? writtenBytes;
    if (modified) {
      buf.writeUInt8(1); // pointer
      if (value != null && value.isNotEmpty) {
        writtenBytes = Uint8List.fromList(value.codeUnits);
        buf.writeUB4(writtenBytes.length);
      } else {
        buf.writeUB4(0);
      }
    } else {
      buf.writeUInt8(0); // pointer
      buf.writeUB4(0); // length
    }
    return writtenBytes;
  }

  /// Saves a deferred error for later processing.
  void saveDeferredErr(Object error) {
    deferredErr ??= error;
  }

  void _updateSessionlessTxnState(Uint8List buf) {
    final length = buf.length;
    final sessionlessState = buf[length - 2];
    final syncVersion = buf[length - 1];

    if (syncVersion == tnsTpcTransTransactionIdSyncVersion1) {
      // transactionId got unset for this session
      if ((sessionlessState & tnsTpcTransTransactionIdSyncUnset) != 0) {
        if (connection != null) {
          connection._sessionlessData = null;
          connection._protocol?.txnInProgress = false;
        }
      // transactionId got set for this session
      } else if ((sessionlessState & tnsTpcTransTransactionIdSyncSet) != 0) {
        bool? startedOnServer;
        if ((sessionlessState & tnsTpcTransTransactionIdSyncServer) != 0) {
          startedOnServer = true;
        } else if ((sessionlessState & tnsTpcTransTransactionIdSyncClient) != 0) {
          startedOnServer = false;
        }

        if (connection != null) {
          connection._sessionlessData = {'startedOnServer': startedOnServer};
          connection._protocol?.txnInProgress = true;
        }
      }
    } else {
      throw StateError(
        'Unexpected TransactionId sync version in session sync piggyback.',
      );
    }
  }
}
