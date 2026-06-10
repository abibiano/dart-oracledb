import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../errors.dart';
import '../protocol/buffer.dart';
import '../protocol/constants.dart';
import '../protocol/messages/auth_message.dart';
import '../protocol/messages/execute_message.dart';
import '../protocol/messages/fast_auth_message.dart';
import '../protocol/messages/ping_message.dart';
import '../protocol/messages/protocol_message.dart';
import 'packet.dart';
import 'socket.dart';
import 'tls.dart';

final _log = Logger('Transport');

/// High-level transport abstraction for Oracle TNS protocol communication.
///
/// The Transport class handles sending and receiving TNS packets over a TCP
/// connection. It manages the underlying socket and handles partial reads
/// (TCP may deliver data in chunks).
///
/// Example usage:
/// ```dart
/// final transport = Transport();
/// await transport.connect('localhost', 1521);
///
/// // Send a packet
/// final connectPacket = TnsPacket(type: tnsPacketConnect, payload: ...);
/// await transport.send(connectPacket);
///
/// // Receive response
/// final response = await transport.receive();
///
/// await transport.disconnect();
/// ```
class Transport {
  /// Creates an unconnected transport.
  Transport();

  final OracleSocket _socket = OracleSocket();

  /// Whether to use large SDU (4-byte packet length) format.
  /// Set after parsing ACCEPT packet if server version >= 315.
  bool _useLargeSdu = false;

  /// Negotiated SDU (Session Data Unit) size in bytes.
  ///
  /// Captured from the ACCEPT packet ([sendConnectReceiveAccept]); defaults to
  /// [tnsDefaultSdu] until then. A single [sendData] call is emitted as one TNS
  /// packet (no fragmentation), so the SDU bounds how large a single TTC message
  /// — including any prepended close-cursor piggyback — may be (AC4).
  int _sdu = tnsDefaultSdu;

  /// Whether the server supports end-of-request markers.
  /// Set after parsing ACCEPT packet flag2 field.
  bool _supportsEndOfRequest = false;

  /// Buffered data from FAST_AUTH response (AUTH_PHASE_ONE response).
  /// When FAST_AUTH returns multiple messages in one packet, the AUTH response
  /// is buffered here so the next receiveData() call can return it.
  Uint8List? _bufferedAuthResponse;

  /// Oracle server major version, parsed from the server banner after
  /// protocol negotiation. Defaults to 23 (23ai) until the banner is received.
  int _serverMajorVersion = 23;

  /// Returns the Oracle server major version (e.g. 19, 21, 23).
  int get serverMajorVersion => _serverMajorVersion;

  bool _supportsFastAuth = true;

  /// Whether the server advertised FAST_AUTH in the ACCEPT flag2 byte.
  /// Defaults to `true` so any failure to parse leaves the 23ai-style path in
  /// place. Routing source of truth for [AuthFlow.authenticate].
  bool get supportsFastAuth => _supportsFastAuth;

  /// TTC field version - adjusted after protocol negotiation.
  /// Used to determine whether token numbers should be written.
  /// TNS_CCAP_FIELD_VERSION_23_1_EXT_1 = 18 is threshold for token numbers.
  int _ttcFieldVersion = 24; // TNS_CCAP_FIELD_VERSION_MAX

  /// Returns the negotiated TTC field version.
  int get ttcFieldVersion => _ttcFieldVersion;

  /// TTC function message sequence number.
  /// Incremented for each TTC function message sent (1, 2, 3, ...).
  /// Starts at 1 to match node-oracledb behavior.
  int _sequence = 1;

  /// Returns true if auth messages should include token numbers.
  /// Token numbers are written when ttcFieldVersion >= 18.
  bool get shouldWriteTokenNumber => _ttcFieldVersion >= 18;

  /// AC8: whether the AUTH_PHASE_TWO 23ai token-number field should be written.
  ///
  /// Gated on BOTH the negotiated field version ([shouldWriteTokenNumber]) AND
  /// the server-advertised FAST_AUTH capability ([supportsFastAuth]). A pre-23
  /// (classical) server may leave [ttcFieldVersion] at its default 24 when it
  /// sends no — or too short — compile capabilities, so the field-version check
  /// alone would incorrectly emit the 23ai token. FAST_AUTH is the protocol
  /// presence signal that a pre-23 server is never given the 23ai format.
  bool get shouldWriteAuthPhaseTwoToken =>
      _supportsFastAuth && shouldWriteTokenNumber;

  /// AC3: gets the one-byte TTC function sequence number for the next message
  /// and advances the counter.
  ///
  /// Oracle's TTC sequence is a single byte: node-oracledb's `writeSeqNum`
  /// writes the current value then advances `(seq + 1) % 256`, starting at 1.
  /// The cycle is therefore `1, 2, …, 255, 0, 1, …` (0 is a valid value the
  /// counter passes through). Pinning the wrap here keeps the counter inside
  /// one byte for long-lived connections rather than growing unbounded and
  /// relying solely on `& 0xFF` masking at each encode callsite.
  int nextSequence() {
    final current = _sequence;
    _sequence = (_sequence + 1) % 256;
    return current;
  }

  /// Test-only seam to drive [ttcFieldVersion] without a live negotiation.
  ///
  /// Used to exercise the token-number gating boundaries (AC4) and the pre-23
  /// classical-server case (AC8) deterministically. Not part of the public API.
  @visibleForTesting
  set debugTtcFieldVersion(int version) => _ttcFieldVersion = version;

  /// Test-only seam to drive [supportsFastAuth] without a live ACCEPT packet.
  ///
  /// Used to exercise the AUTH_PHASE_TWO token gating for both 23ai (FAST_AUTH)
  /// and pre-23 classical servers (AC8). Not part of the public API.
  @visibleForTesting
  set debugSupportsFastAuth(bool value) => _supportsFastAuth = value;

  /// Test-only seam to drive the negotiated SDU without a live ACCEPT packet,
  /// used to exercise [closeCursorChunkLimit] boundaries (AC4).
  @visibleForTesting
  set debugSdu(int value) => _sdu = value;

  /// Worst-case bytes a single cursor id occupies in a close-cursor piggyback:
  /// a UB4 is encoded as a 1-byte length plus up to 4 value bytes.
  static const int _closeCursorIdBytes = 5;

  /// Fixed overhead of a close-cursor piggyback before the cursor-id list:
  /// message type + function + sequence (3) + optional UB8 token (up to 9) +
  /// pointer (1) + UB4 count (up to 5), rounded up for safety.
  ///
  /// The UB8 token (9 bytes) is only written on 23ai servers
  /// (`shouldWriteAuthPhaseTwoToken == true`), but this constant uses the
  /// worst-case size unconditionally so [closeCursorChunkLimit] is always
  /// conservative — better to chunk slightly earlier than to overflow the SDU.
  static const int _closeCursorPiggybackHeader = 32;

  /// Maximum number of cursor ids to flush in a single close-cursor piggyback so
  /// the combined packet stays within the negotiated SDU (AC4).
  ///
  /// The piggyback is prepended to the execute message and the two travel in one
  /// un-fragmented TNS packet, so the cursor list must leave room for the execute
  /// itself. Half the SDU is reserved for the execute message and headers; the
  /// remainder is divided by the worst-case [_closeCursorIdBytes]. Returns at
  /// least 1 so progress is always made. Callers flush this many per execute and
  /// requeue the rest, draining a large backlog across successive round trips
  /// without ever sending a standalone close-cursor RPC.
  int get closeCursorChunkLimit {
    final budget = (_sdu ~/ 2) - _closeCursorPiggybackHeader;
    final limit = budget ~/ _closeCursorIdBytes;
    return limit < 1 ? 1 : limit;
  }

  /// Set once an RPC has timed out (or another unrecoverable framing hazard has
  /// occurred). Because `Future.timeout` does not cancel the in-flight socket
  /// read, a poisoned transport may still have an orphaned server response
  /// queued on the wire; reusing it would misalign the next request/response
  /// pair. Once poisoned, every send/receive fails fast via [_ensureUsable].
  bool _corrupted = false;

  /// Whether this transport has been poisoned by a timed-out RPC and can no
  /// longer be safely reused. The owning connection must be closed and a new
  /// one opened.
  bool get isCorrupted => _corrupted;

  /// Whether the transport is currently connected.
  ///
  /// A corrupted transport reports `false` even before its socket finishes
  /// tearing down, so callers fail fast instead of issuing an RPC that could
  /// read a previous call's orphaned response.
  bool get isConnected => _socket.isConnected && !_corrupted;

  /// Poisons the transport and forcibly destroys the socket.
  ///
  /// Called when an RPC times out: the pending socket read is not cancellable,
  /// so we destroy the socket to guarantee a late response can never be
  /// delivered, and flag the transport corrupted so any further use fails fast.
  void _poison() {
    _corrupted = true;
    _socket.destroy();
  }

  /// Throws if the transport has been poisoned by a previous timed-out RPC.
  ///
  /// The error code ([oraConnectionClosed]) is intentionally distinct from the
  /// timeout error ([oraConnectTimeout]) so callers and tests can tell that the
  /// transport itself is no longer usable, not merely that one call was slow.
  void _ensureUsable() {
    if (_corrupted) {
      throw const OracleException(
        errorCode: oraConnectionClosed,
        message: 'Transport is no longer usable: a previous RPC timed out and '
            'may have left an unread response on the connection. Close this '
            'connection and open a new one.',
      );
    }
  }

  /// Connects to an Oracle database at the specified host and port.
  ///
  /// If [tlsConfig] is provided and enabled, the connection will be upgraded
  /// to TLS after the initial TCP connection but BEFORE the TNS handshake.
  ///
  /// Throws [OracleException] if the connection fails.
  Future<void> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 60),
    TlsConfig? tlsConfig,
  }) async {
    _log.info('Connecting transport to $host:$port');
    await _socket.connect(host, port, timeout: timeout);
    _log.info('Transport connected');

    // Upgrade to TLS if enabled (BEFORE TNS handshake)
    if (tlsConfig != null && tlsConfig.enabled) {
      _log.info('Upgrading to TLS');
      await _socket.upgradeToTls(
        host: host,
        verifyCertificate: tlsConfig.verifyCertificate,
        securityContext: tlsConfig.securityContext,
      );
      _log.info('TLS upgrade complete');
    }
  }

  /// Disconnects from the database.
  ///
  /// Safe to call on an already disconnected transport.
  Future<void> disconnect() async {
    _log.info('Disconnecting transport');
    await _socket.close();
  }

  /// Sends a TNS packet to the connected server.
  ///
  /// Throws [OracleException] if the send fails or if not connected.
  Future<void> send(TnsPacket packet) async {
    _ensureUsable();
    final bytes = encodeTnsPacket(packet, useLargeSdu: _useLargeSdu);
    _log.fine(
        'Sending TNS packet: type=${packet.type}, length=${bytes.length}, '
        'largeSdu=$_useLargeSdu');
    await _socket.send(bytes);
    _log.fine('Packet sent successfully');
  }

  /// Receives a TNS packet from the server.
  ///
  /// This method handles partial reads by first reading the 8-byte header,
  /// extracting the packet length, then reading the remaining payload.
  ///
  /// Throws [OracleException] if receiving fails or the packet is invalid.
  Future<TnsPacket> receive() async {
    _ensureUsable();
    _log.fine('Waiting for TNS packet (largeSdu=$_useLargeSdu)...');

    // Read header first (8 bytes)
    final header = await _socket.read(tnsHeaderSize);
    _log.fine('Received header: ${header.length} bytes');

    // Extract total packet length from header (uses large SDU if enabled)
    final packetLength = readTnsPacketLength(header, useLargeSdu: _useLargeSdu);
    final payloadLength = packetLength - tnsHeaderSize;

    _log.fine('Packet length: $packetLength, payload: $payloadLength bytes');

    // Read remaining payload if any
    Uint8List payload;
    if (payloadLength > 0) {
      payload = await _socket.read(payloadLength);
      _log.fine('Received payload: ${payload.length} bytes');
    } else {
      payload = Uint8List(0);
    }

    // Combine header and payload for decoding
    final fullPacket = Uint8List(packetLength);
    fullPacket.setRange(0, tnsHeaderSize, header);
    if (payloadLength > 0) {
      fullPacket.setRange(tnsHeaderSize, packetLength, payload);
    }

    final packet = decodeTnsPacket(fullPacket, useLargeSdu: _useLargeSdu);
    _log.fine(
        'Decoded TNS packet: type=${packet.type}, payload=${packet.payload.length} bytes');

    return packet;
  }

  /// Encodes a TNS packet into bytes for transmission.
  Uint8List encodePacket(TnsPacket packet) {
    return packet.encode();
  }

  /// Decodes bytes into a TNS packet.
  ///
  /// Throws [TnsPacketException] if the data is invalid.
  TnsPacket decodePacket(Uint8List data) {
    return TnsPacket.decode(data);
  }

  /// Reads the packet length from the TNS header.
  ///
  /// The length is stored as a big-endian 16-bit value in the first 2 bytes.
  int readPacketLength(Uint8List header) {
    if (header.length < 2) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'Header too short to read packet length: ${header.length} bytes',
      );
    }
    return (header[0] << 8) | header[1];
  }

  /// Reads the packet type from the TNS header.
  ///
  /// The type is stored as a single byte at offset 4.
  int readPacketType(Uint8List header) {
    if (header.length < 5) {
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'Header too short to read packet type: ${header.length} bytes',
      );
    }
    return header[4];
  }

  /// Maximum number of RESEND retries before giving up.
  static const int _maxResendRetries = 3;

  /// Sends a SQL statement for execution and returns the response.
  ///
  /// Creates an EXECUTE request message, sends it to the database,
  /// and decodes the response.
  ///
  /// For queries with bind parameters, provide [bindValues] as a List
  /// containing the values in order. For named binds, also provide
  /// [bindNames] with the parameter names in SQL order.
  ///
  /// The [timeout] parameter specifies how long to wait for a response.
  /// Defaults to 2 minutes. Set to `null` for no timeout.
  ///
  /// Throws [OracleException] if execution fails, times out, or protocol error occurs.
  // Data flags that indicate no more packets will follow.
  static const int _tnsDataFlagsEof = 0x0040;
  static const int _tnsDataFlagsEndOfRequest = 0x2000;

  // Safety cap: prevent infinite FETCH loops when moreRowsToFetch stays true.
  static const int _maxFetchIterations = 1000;

  /// Safety cap (AC10): the maximum number of TNS packets a single
  /// [_receiveAllTtcData] call will read while assembling one TTC response.
  ///
  /// On the pre-23.4 path there is no TNS-level end-of-response marker — the
  /// loop keeps reading packets until [ttcStreamIsComplete] returns true. A
  /// server that never sends a response satisfying the completion probe (a
  /// protocol drift or a corrupted stream) would otherwise loop forever. The
  /// 23.4+ path trusts explicit data-flags, but it shares the same loop and is
  /// bounded by the same cap as a backstop.
  ///
  /// The bound is deliberately enormous relative to any real response: a single
  /// execute/fetch round returns at most `prefetchRows` rows (default 50) and
  /// almost always fits in one ≤8 KB SDU packet (LONG/LOB streaming, which
  /// could span many packets, is not yet supported). Reaching this many packets
  /// means the stream is not terminating, not that a legitimate response is
  /// large. Overridable in tests via [debugMaxReceivePackets].
  static const int _defaultMaxReceivePackets = 100000;
  int _maxReceivePackets = _defaultMaxReceivePackets;

  /// Test-only seam to lower the receive-loop packet cap (AC10) so the
  /// never-terminating-stream guard can be exercised deterministically without
  /// flooding the loop with 100k packets. Not part of the public API.
  @visibleForTesting
  set debugMaxReceivePackets(int value) => _maxReceivePackets = value;

  /// Count of EXECUTE messages sent with `cursorId == 0` (a full parse — the
  /// SQL text and a fresh parse are sent). See [debugFullParseExecutes].
  int _fullParseExecutes = 0;

  /// Count of EXECUTE messages sent with `cursorId != 0` (parse bit cleared —
  /// the cached server cursor is reused and no SQL text is resent). See
  /// [debugReuseExecutes].
  int _reuseExecutes = 0;

  /// Number of full-parse EXECUTEs sent (cursorId == 0).
  ///
  /// AC8 instrumentation: lets integration tests prove cursor reuse / parse
  /// skipping at the transport layer without requiring `V$OPEN_CURSOR` or other
  /// privileged views. Surfaced to callers via
  /// `OracleConnection.debugFullParseExecutes`; not a public API.
  int get debugFullParseExecutes => _fullParseExecutes;

  /// Number of cursor-reuse EXECUTEs sent (cursorId != 0, parse skipped).
  int get debugReuseExecutes => _reuseExecutes;

  Future<ExecuteResponse> sendExecute(
    String sql, {
    required bool isQuery,
    bool isPlSql = false,
    List<Object?>? bindValues,
    List<String>? bindNames,
    List<BindMetadata>? bindMetadata,
    int prefetchRows = 50,
    Duration? timeout = const Duration(minutes: 2),
    int cursorId = 0,
    List<ColumnMetadata>? expectedColumns,
    List<int> cursorsToClose = const [],
    bool preserveTimestampTimeZone = false,
  }) async {
    _log.fine('Sending execute request (isQuery=$isQuery, isPlSql=$isPlSql, '
        'cursorId=$cursorId)...');

    // AC8: record whether this execute reuses a cached server cursor (parse bit
    // cleared) or performs a full parse. The cursorId sent on the wire is the
    // authoritative signal — a non-zero id skips parse and omits the SQL bytes.
    if (cursorId == 0) {
      _fullParseExecutes++;
    } else {
      _reuseExecutes++;
    }

    final request = ExecuteRequest(
      sql: sql,
      bindValues: bindValues,
      bindNames: bindNames,
      isQuery: isQuery,
      isPlSql: isPlSql,
      numIters: prefetchRows,
      ttcFieldVersion: _ttcFieldVersion,
      sequence: nextSequence(),
      cursorId: cursorId,
    );

    // Prepend close-cursor piggyback when LRU evictions produced pending IDs.
    final executeData = request.toBytes();
    final Uint8List requestData;
    if (cursorsToClose.isNotEmpty) {
      final closeData = _buildCloseCursorPiggyback(cursorsToClose);
      requestData = Uint8List(closeData.length + executeData.length)
        ..setRange(0, closeData.length, closeData)
        ..setRange(closeData.length, closeData.length + executeData.length,
            executeData);
    } else {
      requestData = executeData;
    }

    await sendData(requestData);
    final payload = await _receiveDataWithTimeout(timeout,
        expectedColumns: expectedColumns);

    final response = decodeExecuteResponse(
      payload,
      isQuery: isQuery,
      ttcFieldVersion: _ttcFieldVersion,
      endOfRequestSupport: _supportsEndOfRequest,
      expectedColumns: expectedColumns,
      bindMetadata: bindMetadata,
      preserveTimestampTimeZone: preserveTimestampTimeZone,
    );

    // If this is a SELECT and the server kept the cursor open with more rows
    // pending, drain them via FETCH calls until EOF. ExecuteResponse is
    // immutable (Story 7.9 AC3), so rows accumulate in a local list and a
    // single final response is built after the loop — on both the success
    // and the fetch-failure paths.
    if (isQuery && response.cursorId != 0 && response.isSuccess) {
      // Use column metadata from this response (populated from DESCRIBE or
      // expectedColumns) so fetch rounds can decode rows without DESCRIBE.
      final fetchColumns = response.columnMetadata.isNotEmpty
          ? response.columnMetadata
          : expectedColumns;
      final allRows = List<List<Object?>>.of(response.rows);
      var moreRowsToFetch = response.moreRowsToFetch;
      var fetchCount = 0;
      while (moreRowsToFetch) {
        if (++fetchCount > _maxFetchIterations) {
          // Backstop against an unbounded drain. Leave moreRowsToFetch as-is
          // (true) so the returned response is honestly reported as
          // incomplete rather than indistinguishable from a fully-drained
          // result set (which would silently truncate rows).
          _log.warning('Reached max fetch iterations ($_maxFetchIterations); '
              'stopping with rows still pending — result is incomplete');
          break;
        }
        final fetched = await _sendFetch(
            response.cursorId, prefetchRows, timeout,
            expectedColumns: fetchColumns,
            preserveTimestampTimeZone: preserveTimestampTimeZone);
        allRows.addAll(fetched.rows);
        moreRowsToFetch = fetched.moreRowsToFetch;
        if (!fetched.isSuccess) {
          return ExecuteResponse(
            isSuccess: false,
            cursorId: response.cursorId,
            columnMetadata: response.columnMetadata,
            rows: allRows,
            rowsAffected: fetched.rowsAffected,
            moreRowsToFetch: fetched.moreRowsToFetch,
            errorCode: fetched.errorCode,
            errorMessage: fetched.errorMessage,
            errorOffset: fetched.errorOffset,
          );
        }
      }
      if (fetchCount > 0) {
        return ExecuteResponse(
          isSuccess: true,
          cursorId: response.cursorId,
          columnMetadata: response.columnMetadata,
          rows: allRows,
          outBindValues: response.outBindValues,
          outBindIndices: response.outBindIndices,
          rowsAffected: response.rowsAffected,
          moreRowsToFetch: moreRowsToFetch,
        );
      }
    }

    return response;
  }

  /// Builds a close-cursor piggyback TTC message (prepended to another message).
  ///
  /// Matches node-oracledb thin `writeCloseCursorsPiggyBack` — close-cursor
  /// is exclusively a piggyback prefix on outgoing TTC messages. There is no
  /// standalone close-cursors round trip; pending cursor IDs are abandoned
  /// at session teardown and reaped by Oracle when the session ends.
  Uint8List _buildCloseCursorPiggyback(List<int> cursorIds) {
    final buf = WriteBuffer();
    buf.writeUint8(ttcMsgTypePiggyback);
    buf.writeUint8(ttcFuncCloseCursors);
    buf.writeUint8(nextSequence() & 0xFF);
    if (_ttcFieldVersion >= ttcCcapFieldVersion23_1Ext1) {
      buf.writeUB8(0); // token number
    }
    buf.writeUint8(1); // pointer — non-null signals cursor list follows
    buf.writeUB4(cursorIds.length);
    for (final id in cursorIds) {
      buf.writeUB4(id);
    }
    return buf.toBytes();
  }

  /// Sends a TTC COMMIT message and waits for the server's acknowledgement.
  ///
  /// [timeout] bounds how long to wait for Oracle's commit acknowledgement.
  /// Throws [OracleException] if the commit fails, times out, or the connection is broken.
  Future<void> sendCommit(
      {Duration timeout = const Duration(seconds: 30)}) async {
    final buf = WriteBuffer();
    buf.writeUint8(ttcMsgTypeFunction);
    buf.writeUint8(ttcFuncCommit);
    buf.writeUint8(nextSequence() & 0xFF);
    if (_ttcFieldVersion >= ttcCcapFieldVersion23_1Ext1) {
      buf.writeUB8(0);
    }
    await sendData(buf.toBytes());
    final payload = await _receiveDataWithTimeout(timeout, operation: 'Commit');
    final response = decodeExecuteResponse(payload,
        isQuery: false,
        ttcFieldVersion: _ttcFieldVersion,
        endOfRequestSupport: _supportsEndOfRequest);
    if (!response.isSuccess) {
      throw OracleException(
        errorCode: response.errorCode ?? oraProtocolError,
        message: response.errorMessage ?? 'Commit failed',
      );
    }
  }

  /// Sends a TTC ROLLBACK message and waits for the server's acknowledgement.
  ///
  /// [timeout] bounds how long to wait for Oracle's rollback acknowledgement.
  /// Throws [OracleException] if the rollback fails, times out, or the connection is broken.
  Future<void> sendRollback(
      {Duration timeout = const Duration(seconds: 30)}) async {
    final buf = WriteBuffer();
    buf.writeUint8(ttcMsgTypeFunction);
    buf.writeUint8(ttcFuncRollback);
    buf.writeUint8(nextSequence() & 0xFF);
    if (_ttcFieldVersion >= ttcCcapFieldVersion23_1Ext1) {
      buf.writeUB8(0);
    }
    await sendData(buf.toBytes());
    final payload =
        await _receiveDataWithTimeout(timeout, operation: 'Rollback');
    final response = decodeExecuteResponse(payload,
        isQuery: false,
        ttcFieldVersion: _ttcFieldVersion,
        endOfRequestSupport: _supportsEndOfRequest);
    if (!response.isSuccess) {
      throw OracleException(
        errorCode: response.errorCode ?? oraProtocolError,
        message: response.errorMessage ?? 'Rollback failed',
      );
    }
  }

  Future<ExecuteResponse> _sendFetch(
      int cursorId, int numRows, Duration? timeout,
      {List<ColumnMetadata>? expectedColumns,
      bool preserveTimestampTimeZone = false}) async {
    final fetch = FetchRequest(
      cursorId: cursorId,
      numRows: numRows,
      ttcFieldVersion: _ttcFieldVersion,
      sequence: nextSequence(),
    );
    await sendData(fetch.toBytes());
    final payload = await _receiveDataWithTimeout(timeout,
        expectedColumns: expectedColumns);
    return decodeExecuteResponse(
      payload,
      isQuery: true,
      ttcFieldVersion: _ttcFieldVersion,
      endOfRequestSupport: _supportsEndOfRequest,
      expectedColumns: expectedColumns,
      preserveTimestampTimeZone: preserveTimestampTimeZone,
    );
  }

  Future<Uint8List> _receiveDataWithTimeout(Duration? timeout,
      {String operation = 'Query',
      List<ColumnMetadata>? expectedColumns}) async {
    _ensureUsable();
    final future = _receiveAllTtcData(expectedColumns: expectedColumns);
    if (timeout == null) return future;
    return future.timeout(
      timeout,
      onTimeout: () {
        // `Future.timeout` abandons the returned future but does NOT cancel the
        // underlying socket read: the server's (late) response may still arrive
        // and would otherwise be misread as the reply to the next RPC. Poison
        // the transport and destroy the socket so that can never happen. The
        // message carries the operation name and elapsed wait (AC1); the
        // poisoned state makes every subsequent send/receive fail fast (AC2).
        _poison();
        throw OracleException(
          errorCode: oraConnectTimeout,
          message: '$operation timed out after ${timeout.inMilliseconds}ms; '
              'transport poisoned — no further RPCs are permitted on this '
              'connection',
        );
      },
    );
  }

  /// Reads one or more TNS DATA packets and concatenates their TTC payloads.
  ///
  /// Termination differs by server capability:
  ///   * `_supportsEndOfRequest == true` (Oracle 23.4+) — the server signals
  ///     end-of-response with the `TNS_DATA_FLAGS_END_OF_REQUEST` (0x2000)
  ///     data-flag, or by sending the single-byte `TNS_MSG_TYPE_END_OF_REQUEST`
  ///     (0x1D) marker as the last payload byte. The EOF (0x0040) data-flag
  ///     also terminates the stream.
  ///   * `_supportsEndOfRequest == false` (Oracle pre-23.4 / 21c / 19c) — there
  ///     is no TNS-level end-of-response marker. End-of-response is encoded in
  ///     the TTC message stream itself (STATUS / ERROR / END_OF_REQUEST). We
  ///     scan accumulated bytes after each packet using [_ttcStreamEndsResponse]
  ///     and keep reading more packets if the response is incomplete. This
  ///     matches node-oracledb thin (`packet.js waitForPackets`), which only
  ///     batches packets for `endOfRequestSupport == true`.
  Future<Uint8List> _receiveAllTtcData(
      {List<ColumnMetadata>? expectedColumns}) async {
    final chunks = <Uint8List>[];
    var packetsRead = 0;
    while (true) {
      // AC10: bound the loop so a server response that never satisfies the
      // completion probe cannot spin forever. Poison the transport before
      // throwing — a partially-read, non-terminating stream is a framing hazard
      // and the connection must not be reused.
      if (++packetsRead > _maxReceivePackets) {
        _poison();
        throw OracleException(
          errorCode: oraProtocolError,
          message: 'Protocol receive-loop exhaustion: read $_maxReceivePackets '
              'TNS packets without a complete TTC response; the server stream '
              'is not terminating. Transport poisoned — close this connection '
              'and open a new one.',
        );
      }
      var packet = await receive();
      while (packet.type == tnsPacketMarker) {
        // Marker payload: [markerType(1B), pad(1B), dataType(1B)]
        // dataType: 1=BREAK(NIQBMARK), 2=RESET(NIQRMARK), 3=INTERRUPT(NIQIMARK)
        // When Oracle sends a BREAK marker it means "I have an error; acknowledge
        // with a RESET marker before I send the DATA response."
        //
        // Count MARKER packets against the cap (review patch): a server that
        // floods MARKER packets would otherwise bypass the AC10 guard entirely.
        if (++packetsRead > _maxReceivePackets) {
          _poison();
          throw OracleException(
            errorCode: oraProtocolError,
            message:
                'Protocol receive-loop exhaustion: read $_maxReceivePackets '
                'TNS packets without a complete TTC response; the server stream '
                'is not terminating. Transport poisoned — close this connection '
                'and open a new one.',
          );
        }
        if (packet.payload.length >= 3 && packet.payload[2] == 1) {
          await _sendResetMarker();
        }
        packet = await receive();
      }
      if (packet.type == tnsPacketRefuse) {
        // A REFUSE arriving mid-query (post-auth) is NOT a credential failure —
        // mapping it to ORA-01017 would mislead the caller. Surface the actual
        // refuse reason carried in the packet instead (AC7). Auth-time REFUSE is
        // handled separately in receiveData() where ORA-01017 is correct.
        // Poison the transport — the server has unilaterally terminated the
        // session; subsequent RPCs must fail fast rather than read stale bytes.
        _poison();
        throw _refusePacketException(packet);
      }
      if (packet.type != tnsPacketData) {
        throw OracleException(
          errorCode: oraProtocolError,
          message: 'Expected DATA packet, got type ${packet.type}',
        );
      }
      if (packet.payload.length < 2) {
        chunks.add(packet.payload);
        break;
      }
      final flags = (packet.payload[0] << 8) | packet.payload[1];
      final ttcData = Uint8List.sublistView(packet.payload, 2);
      chunks.add(ttcData);
      if (_supportsEndOfRequest) {
        // Oracle 23.4+: the server provides explicit end-of-request markers.
        // The TNS-level data-flags are authoritative — a success response sets
        // END_OF_REQUEST (0x2000) and EOF (0x0040) is terminal too. Trust them
        // directly; this is the common path and is unaffected by data content.
        if ((flags & _tnsDataFlagsEof) != 0 ||
            (flags & _tnsDataFlagsEndOfRequest) != 0) {
          break;
        }
        // Error responses (e.g. ORA-00001) instead carry flags=0x0000 and end
        // the payload with the single-byte END_OF_REQUEST marker (0x1D). But
        // 0x1D can also occur legitimately as the final data byte of a NON-final
        // packet (e.g. inside NUMBER/RAW column data), so trusting it blindly
        // could terminate a multi-packet response early. AC5 follow-up guard:
        // only treat a trailing 0x1D as terminal once the accumulated TTC stream
        // actually parses to a complete response; otherwise keep reading.
        //
        // AC11 cost note: like the pre-23.4 probe below, this sub-path
        // re-concatenates and re-walks the full accumulation once per packet
        // when a flags=0x0000 error response spans multiple packets — O(N x
        // bytes). The trailing-0x1D check short-circuits the expensive probe so
        // the re-walk only runs on packets that *look* terminal, and error
        // responses on 23ai are small (a single ORA-xxxxx message, almost
        // always one packet), so N is effectively 1. The same bound that covers
        // the pre-23.4 probe is exercised for this branch by the benchmark in
        // test/src/transport/ttc_stream_benchmark_test.dart. The long-term fix
        // (a stateful/lazy parser) is the shared follow-up tracked below.
        if (ttcData.isNotEmpty &&
            ttcData.last == ttcMsgTypeEndOfRequest &&
            ttcStreamIsComplete(_concatChunks(chunks),
                ttcFieldVersion: _ttcFieldVersion,
                endOfRequestSupport: _supportsEndOfRequest,
                expectedColumns: expectedColumns)) {
          break;
        }
      } else {
        // Pre-23.4 (Oracle 21c / 19c): no TNS-level boundary. Scan the
        // accumulated TTC bytes for STATUS / END_OF_REQUEST. If the response
        // is complete, stop; otherwise wait for the next packet.
        //
        // AC6 cost note: this probe re-walks the full accumulated buffer once
        // per inbound packet, so a response spanning N packets costs
        // O(N x bytes) — quadratic in the worst case. That worst case does not
        // arise in practice on the pre-23.4 path: fetches are batched by
        // `prefetchRows` (default 50) and a single fetch round's rows almost
        // always fit in one SDU (<= 8 KB), so N is typically 1 and rarely more
        // than a handful. The bound is exercised by the regression benchmark in
        // test/src/transport/ttc_stream_benchmark_test.dart. A full lazy /
        // stateful-parser refactor (node-oracledb `waitForPackets` style) is the
        // long-term fix and is tracked as a follow-up; it is intentionally NOT
        // done here to avoid destabilising the working decode path.
        if (ttcStreamIsComplete(_concatChunks(chunks),
            ttcFieldVersion: _ttcFieldVersion,
            endOfRequestSupport: _supportsEndOfRequest,
            expectedColumns: expectedColumns)) {
          break;
        }
      }
    }
    return _concatChunks(chunks);
  }

  static Uint8List _concatChunks(List<Uint8List> chunks) {
    if (chunks.length == 1) return chunks.first;
    final total = chunks.fold(0, (sum, c) => sum + c.length);
    final result = Uint8List(total);
    var offset = 0;
    for (final chunk in chunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }

  /// Builds a protocol-level [OracleException] describing a mid-query REFUSE
  /// packet, surfacing the server's actual refuse reason (AC7).
  ///
  /// REFUSE payload layout (offsets relative to the stripped TNS payload, i.e.
  /// node-oracledb's absolute offsets minus the 8-byte header):
  ///   [0]    user (application) refuse reason
  ///   [1]    system (NS) refuse reason
  ///   [2..3] refuse data length (big-endian)
  ///   [4..]  refuse data (ASCII, typically a `(DESCRIPTION=(ERR=...)...)` blob)
  ///
  /// The data is a server-generated diagnostic descriptor; it never contains
  /// client credentials, so it is safe to include verbatim.
  static OracleException _refusePacketException(TnsPacket packet) {
    final p = packet.payload;
    final userReason = p.isNotEmpty ? p[0] : 0;
    final systemReason = p.length > 1 ? p[1] : 0;
    String detail;
    if (p.length >= 4) {
      // Read the declared data length from bytes [2..3] (big-endian), clamped
      // to the actual payload bounds to guard against a malformed packet.
      final declaredLen = (p[2] << 8) | p[3];
      final end = (4 + declaredLen).clamp(4, p.length);
      // Decode the data region as printable ASCII; drop control bytes so a
      // malformed payload cannot inject newlines/escapes into the message.
      final sb = StringBuffer();
      for (var i = 4; i < end; i++) {
        final b = p[i];
        if (b >= 0x20 && b < 0x7F) sb.writeCharCode(b);
      }
      final text = sb.toString().trim();
      detail = text.isEmpty ? '<no reason text>' : text;
    } else {
      detail = '<no reason text>';
    }
    return OracleException(
      errorCode: oraProtocolError,
      message: 'Server refused the request mid-session '
          '(REFUSE userReason=0x${userReason.toRadixString(16)}, '
          'systemReason=0x${systemReason.toRadixString(16)}): $detail',
    );
  }

  /// Sends a TTC PING message to verify connection health.
  ///
  /// Throws [OracleException] if ping fails or times out.
  Future<void> sendPing({Duration timeout = const Duration(seconds: 5)}) async {
    _log.fine('Sending ping...');

    final pingMessage = PingMessage();
    final pingData = pingMessage.toBytes();

    final packet = TnsPacket(type: tnsPacketData, payload: pingData);
    await send(packet);

    // Wait for response with timeout; poison the transport on timeout so the
    // orphaned server response cannot be misread as the reply to a subsequent RPC.
    final response = await receive().timeout(
      timeout,
      onTimeout: () {
        _poison();
        throw OracleException(
          errorCode: oraConnectTimeout,
          message:
              'Ping timed out after ${timeout.inMilliseconds}ms; transport poisoned',
        );
      },
    );
    _log.fine('Ping response received: type=${response.type}');
  }

  /// Sends a TNS CONNECT packet and waits for an ACCEPT response.
  ///
  /// Returns the ACCEPT packet on success. Also configures large SDU mode
  /// based on the negotiated protocol version.
  /// Throws [OracleException] on connection refusal or protocol error.
  Future<TnsPacket> sendConnectReceiveAccept(Uint8List connectData) async {
    // Send CONNECT packet (large SDU not enabled yet)
    final connectPacket = TnsPacket(
      type: tnsPacketConnect,
      payload: connectData,
    );
    await send(connectPacket);

    var resendCount = 0;

    while (true) {
      // AC12: fail fast if the transport was poisoned by a prior timeout on
      // this instance. `_receiveRawPacket` reads directly from the socket and,
      // unlike `send`/`receive`, has no built-in poisoned-state check; without
      // this guard a reused-after-timeout transport could read stale bytes left
      // on the wire and misframe the handshake. Normal connects never hit this
      // (CONNECT/ACCEPT precedes any RPC timeout); it is an invariant guard
      // against accidental transport reuse.
      _ensureUsable();
      // Wait for response - receive raw packet to parse ACCEPT fields
      final rawPacketData = await _receiveRawPacket();
      final response = decodeTnsPacket(rawPacketData, useLargeSdu: false);

      switch (response.type) {
        case tnsPacketAccept:
          _log.info('Connection accepted');

          // Parse ACCEPT to get negotiated version and enable large SDU
          final acceptInfo = AcceptPacketInfo.parse(rawPacketData);
          _useLargeSdu = acceptInfo.useLargeSdu;
          _supportsEndOfRequest = acceptInfo.supportsEndOfRequest;
          _supportsFastAuth = acceptInfo.supportsFastAuth;
          if (acceptInfo.sdu > 0) _sdu = acceptInfo.sdu;
          _log.info('Negotiated version=${acceptInfo.version}, '
              'sdu=${acceptInfo.sdu}, largeSdu=$_useLargeSdu, '
              'endOfRequest=$_supportsEndOfRequest, '
              'supportsFastAuth=$_supportsFastAuth');

          return response;

        case tnsPacketRefuse:
          _log.warning('Connection refused');
          throw const OracleException(
            errorCode: oraConnectionRefused,
            message: 'Connection refused by server',
          );

        case tnsPacketRedirect:
          _log.info('Redirect received');
          // Redirect handling deferred to future story
          throw const OracleException(
            errorCode: oraProtocolError,
            message: 'Redirect not yet supported',
          );

        case tnsPacketResend:
          resendCount++;
          if (resendCount > _maxResendRetries) {
            _log.warning('Exceeded maximum RESEND retries ($resendCount)');
            throw OracleException(
              errorCode: oraProtocolError,
              message: 'Server requested too many resends ($resendCount)',
            );
          }
          _log.fine(
              'Server requested resend (attempt $resendCount/$_maxResendRetries)');
          await send(connectPacket);
          continue; // Loop to receive next response

        default:
          throw OracleException(
            errorCode: oraProtocolError,
            message: 'Unexpected response type: ${response.type}',
          );
      }
    }
  }

  /// Receives a raw TNS packet (header + payload) without decoding.
  ///
  /// Used internally when we need access to raw packet bytes.
  Future<Uint8List> _receiveRawPacket() async {
    // Read header first (8 bytes)
    final header = await _socket.read(tnsHeaderSize);

    // Extract packet length (standard format for CONNECT/ACCEPT)
    final packetLength = readTnsPacketLength(header, useLargeSdu: false);
    final payloadLength = packetLength - tnsHeaderSize;

    // Read remaining payload if any
    Uint8List payload;
    if (payloadLength > 0) {
      payload = await _socket.read(payloadLength);
    } else {
      payload = Uint8List(0);
    }

    // Combine header and payload
    final fullPacket = Uint8List(packetLength);
    fullPacket.setRange(0, tnsHeaderSize, header);
    if (payloadLength > 0) {
      fullPacket.setRange(tnsHeaderSize, packetLength, payload);
    }

    return fullPacket;
  }

  /// Performs TTC protocol negotiation after TNS connection.
  ///
  /// This must be called after [sendConnectReceiveAccept] but before
  /// authentication. Exchanges protocol version, capabilities, and data types
  /// with server.
  ///
  /// Returns the [ProtocolResponse] containing server capabilities.
  /// Throws [OracleException] on protocol error.
  Future<ProtocolResponse> sendProtocolNegotiation() async {
    _log.info('Starting TTC protocol negotiation');

    // Step 1: Send protocol request — version not yet known, force safe flags.
    final request = ProtocolRequest();
    final requestData = request.toBytes();
    await sendData(requestData, dataFlags: 0x0000);

    // Receive protocol response
    final ttcData = await receiveData();
    final protocolResponse = ProtocolResponse.decode(ttcData);
    _log.info('Protocol negotiation complete: '
        'serverVersion=${protocolResponse.serverVersion}');

    // Store server major version for subsequent flag decisions.
    _serverMajorVersion =
        _extractMajorVersion(protocolResponse.serverBanner) ?? 23;
    _log.fine('Server major version: $_serverMajorVersion '
        '(banner: ${protocolResponse.serverBanner})');

    // Adjust ttcFieldVersion based on server compile caps
    _adjustFieldVersion(protocolResponse.compileCaps);

    // Step 2: Send data types negotiation (required before auth)
    await _sendDataTypesNegotiation(protocolResponse);

    return protocolResponse;
  }

  /// Sends a standalone AUTH_PHASE_ONE message and returns the raw TTC
  /// response data. Used by the classical (pre-23) authentication path, after
  /// [sendProtocolNegotiation] has completed.
  Future<Uint8List> sendAuthPhaseOne(AuthPhaseOneRequest request,
      {Duration? timeout}) async {
    final bytes = request.toBytes();
    await sendData(bytes, dataFlags: 0x0000);
    final future = receiveData();
    if (timeout == null) return future;
    // Mirror the timeout-poisoning contract of _receiveDataWithTimeout: on
    // timeout the in-flight socket read is not cancelled, so destroy the socket
    // to guarantee the orphaned response cannot be misread as a later reply.
    return future.timeout(timeout, onTimeout: () {
      _poison();
      throw OracleException(
        errorCode: oraConnectTimeout,
        message:
            'AUTH_PHASE_ONE timed out after ${timeout.inMilliseconds}ms; transport poisoned',
      );
    });
  }

  /// Sends FAST_AUTH message containing protocol negotiation, data types
  /// negotiation, and AUTH_PHASE_ONE in a single optimized message.
  ///
  /// This is Oracle 23ai's Fast Authentication protocol that reduces round trips
  /// by combining three separate messages into one FAST_AUTH envelope.
  Future<ProtocolResponse> sendFastAuth({
    required String username,
    required Uint8List clientNonce,
  }) async {
    _log.info('Starting FAST_AUTH protocol with username: $username');

    // Build compile and runtime capabilities
    final compileCaps = _buildCompileCapabilities();
    final runtimeCaps = _buildRuntimeCapabilities();

    // Create FAST_AUTH message
    final fastAuthRequest = FastAuthRequest(
      username: username,
      clientNonce: clientNonce,
      compileCaps: compileCaps,
      runtimeCaps: runtimeCaps,
      dataTypes: _dataTypes,
      ttcFieldVersion: _ttcFieldVersion,
      sequence: nextSequence(), // Get next sequence number
    );

    final fastAuthBytes = fastAuthRequest.toBytes();
    _log.info('Sending FAST_AUTH message: ${fastAuthBytes.length} bytes');

    // Send FAST_AUTH message in single TNS DATA packet.
    // Bootstrap packet: server version not yet known, use 0x0000 explicitly.
    await sendData(fastAuthBytes, dataFlags: 0x0000);

    // CRITICAL: Oracle responds with ONE packet containing MULTIPLE TTC messages
    // We must parse messages sequentially from the single response buffer
    final responseData = await receiveData();
    _log.fine('Received FAST_AUTH response: ${responseData.length} bytes');

    // Parse Protocol response (first message, type 1)
    final protocolResponse = ProtocolResponse.decode(responseData);
    _log.info('Protocol negotiation complete: '
        'serverVersion=${protocolResponse.serverVersion}');

    // Store server major version now that the response is available.
    _serverMajorVersion =
        _extractMajorVersion(protocolResponse.serverBanner) ?? 23;
    _log.fine('Server major version: $_serverMajorVersion '
        '(banner: ${protocolResponse.serverBanner})');

    // Adjust ttcFieldVersion based on server compile caps
    _adjustFieldVersion(protocolResponse.compileCaps);

    // Find where Protocol message ended by re-parsing with tracking buffer
    // This advances buffer.position to the end of Protocol message
    final tempBuffer = ReadBuffer(responseData);
    ProtocolResponse.decode(responseData); // Decodes using internal buffer
    // Manually scan to find protocol end - skip message type + server version + banner
    tempBuffer.readUint8(); // type
    tempBuffer.readUint8(); // server version
    tempBuffer.skip(1); // skip byte
    // Skip banner (null-terminated)
    while (tempBuffer.hasRemaining && tempBuffer.readUint8() != 0) {}
    // Skip rest of protocol message structure
    if (tempBuffer.hasRemaining) {
      tempBuffer.readUint16LE(); // charset
      tempBuffer.readUint8(); // flags
      final numElem = tempBuffer.readUint16LE();
      if (numElem > 0) tempBuffer.skip(numElem * 5);
      final fdoLen = tempBuffer.readUint16BE();
      tempBuffer.skip(fdoLen);
      // Skip compile + runtime caps
      if (tempBuffer.hasRemaining) {
        final compileLen = tempBuffer.readUint8();
        if (compileLen > 0) tempBuffer.skip(compileLen);
      }
      if (tempBuffer.hasRemaining) {
        final runtimeLen = tempBuffer.readUint8();
        if (runtimeLen > 0) tempBuffer.skip(runtimeLen);
      }
    }

    final protocolEndPos = tempBuffer.position;
    _log.fine(
        'DEBUG: protocolEndPos=$protocolEndPos, total responseData=${responseData.length} bytes');

    // Parse DataTypes response from remaining bytes
    int dataTypesEndPos = protocolEndPos;
    if (protocolEndPos < responseData.length) {
      final dataTypesData = Uint8List.sublistView(responseData, protocolEndPos);
      _log.fine(
          'DEBUG: dataTypesData starts at byte $protocolEndPos, first byte: ${dataTypesData[0]}');
      DataTypesResponse.decode(dataTypesData);
      _log.info('Data types negotiation complete');

      // Track DataTypes end position by parsing its structure
      final dtBuffer = ReadBuffer(dataTypesData);
      dtBuffer.readUint8(); // type

      // Skip charset fields (4 bytes) + encoding flags (1 byte)
      if (dtBuffer.remaining >= 5) {
        dtBuffer
            .skip(5); // charset (2 bytes) + nCharset (2 bytes) + flags (1 byte)
      }

      // Skip compile caps (length-prefixed)
      if (dtBuffer.hasRemaining) {
        final compileLen = dtBuffer.readUint8();
        if (compileLen > 0) dtBuffer.skip(compileLen);
      }

      // Skip runtime caps (length-prefixed)
      if (dtBuffer.hasRemaining) {
        final runtimeLen = dtBuffer.readUint8();
        if (runtimeLen > 0) dtBuffer.skip(runtimeLen);
      }

      // Skip data type mappings until terminator (0x0000)
      // Format: [dataType(2), convType(2), repType(2), 0(2)] each as UInt16BE
      while (dtBuffer.hasRemaining) {
        final dataType = dtBuffer.readUint16BE();
        if (dataType == 0) break; // Terminator found
        dtBuffer.readUint16BE(); // conv type
        if (dtBuffer.hasRemaining) {
          final repType = dtBuffer.readUint16BE();
          if (repType != 0 && dtBuffer.remaining >= 4) {
            dtBuffer.skip(4); // Additional bytes for non-zero repType
          }
        }
      }

      // Skip padding bytes after terminator and find AUTH message start
      // AUTH message should start with type 8 (parameter) or 3 (function)
      while (dtBuffer.hasRemaining) {
        final currentPos = dtBuffer.position;
        final b = dtBuffer.readUint8();

        // Check if this is the start of AUTH message (type 8 = parameter)
        if (b == 8) {
          // Found AUTH message start - back up one byte
          dataTypesEndPos = protocolEndPos + currentPos;
          _log.fine(
              'DEBUG: Found AUTH parameter message at byte $currentPos (absolute: $dataTypesEndPos)');
          break;
        }

        // If we've skipped more than 50 bytes of padding, something is wrong
        if (dtBuffer.position - (protocolEndPos + dtBuffer.position) > 50) {
          _log.warning('Scanned >50 bytes looking for AUTH message, stopping');
          break;
        }
      }

      if (dataTypesEndPos == protocolEndPos) {
        dataTypesEndPos = protocolEndPos + dtBuffer.position;
      }
      _log.fine(
          'DEBUG: dataTypesEndPos=$dataTypesEndPos, dtBuffer.position=${dtBuffer.position}');
    }

    // Buffer the AUTH response (remaining bytes) for next receiveData() call
    if (dataTypesEndPos < responseData.length) {
      _bufferedAuthResponse =
          Uint8List.sublistView(responseData, dataTypesEndPos);
      _log.fine(
          'Buffered AUTH response: ${_bufferedAuthResponse!.length} bytes, starts with byte: ${_bufferedAuthResponse![0]}');
      _log.fine(
          'First 32 bytes of AUTH response: ${_bufferedAuthResponse!.sublist(0, _bufferedAuthResponse!.length > 32 ? 32 : _bufferedAuthResponse!.length).map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');
    }

    // Auth response will be handled by auth module via receiveData()
    return protocolResponse;
  }

  /// Legacy method - deprecated in favor of sendFastAuth.
  @Deprecated('Use sendFastAuth for Oracle 23ai compatibility')
  Future<ProtocolResponse> sendBatchedProtocolAndAuth(
      Uint8List authPhaseOneBytes) async {
    throw UnsupportedError(
        'Manual batching is deprecated. Use sendFastAuth instead.');
  }

  /// Builds the data types negotiation TTC message without sending it.
  /// Adjusts the TTC field version based on server compile capabilities.
  void _adjustFieldVersion(Uint8List? serverCompileCaps) {
    if (serverCompileCaps != null &&
        serverCompileCaps.length > _ccapFieldVersion) {
      final serverFieldVersion = serverCompileCaps[_ccapFieldVersion];
      if (serverFieldVersion < _ttcFieldVersion) {
        _ttcFieldVersion = serverFieldVersion;
        _log.fine('Adjusted ttcFieldVersion to $serverFieldVersion '
            '(server limit)');
      } else {
        _log.fine('ttcFieldVersion remains $_ttcFieldVersion '
            '(server supports $serverFieldVersion)');
      }
    }
  }

  /// Performs TTC protocol negotiation without data types exchange.
  ///
  /// This is the minimal protocol negotiation for testing purposes.
  Future<ProtocolResponse> sendProtocolNegotiationMinimal() async {
    _log.info('Starting TTC protocol negotiation (minimal)');

    // Send protocol request
    final request = ProtocolRequest();
    final requestData = request.toBytes();
    // Bootstrap packet: server version not yet known, use 0x0000 explicitly.
    await sendData(requestData, dataFlags: 0x0000);

    // Receive protocol response
    final ttcData = await receiveData();
    final protocolResponse = ProtocolResponse.decode(ttcData);
    _log.info('Protocol negotiation complete (minimal): '
        'serverVersion=${protocolResponse.serverVersion}');

    return protocolResponse;
  }

  /// Sends the data types negotiation message.
  Future<void> _sendDataTypesNegotiation(ProtocolResponse protoResponse) async {
    _log.info('Starting data types negotiation');

    // Build client capabilities
    final compileCaps = _buildCompileCapabilities();
    final runtimeCaps = _buildRuntimeCapabilities();

    // Build data types message
    final buffer = WriteBuffer();

    // Message type
    buffer.writeUint8(2); // TNS_MSG_TYPE_DATA_TYPES

    // Character set (UTF-8 = 873)
    buffer.writeUint16LE(873);
    buffer.writeUint16LE(873);

    // Encoding flags
    buffer.writeUint8(0x01 | 0x02); // MULTI_BYTE | CONV_LENGTH

    // Compile caps (length-prefixed)
    buffer.writeUint8(compileCaps.length);
    buffer.writeBytes(compileCaps);

    // Runtime caps (length-prefixed)
    buffer.writeUint8(runtimeCaps.length);
    buffer.writeBytes(runtimeCaps);

    // Data type mappings (matching node-oracledb format)
    // Format: [dataType, convType, repType, 0] each as UInt16BE
    // repType: 0=NATIVE, 1=UNIVERSAL, 10=ORACLE
    for (final dt in _dataTypes) {
      _writeDataTypeMapping(buffer, dt[0], dt[1], dt[2]);
    }

    // Terminator
    buffer.writeUint16BE(0);

    await sendData(buffer.toBytes());

    // Receive data types response
    final respData = await receiveData();
    _log.fine('Received data types response: ${respData.length} bytes');

    // Parse response - skip data type mappings
    final respBuffer = ReadBuffer(respData);
    final msgType = respBuffer.readUint8();
    if (msgType != 2) {
      _log.warning('Unexpected data types response type: $msgType');
    }

    // Read and skip data type mappings until terminator
    while (respBuffer.hasRemaining) {
      final dataType = respBuffer.readUint16BE();
      if (dataType == 0) break;
      respBuffer.readUint16BE(); // conv type
      if (respBuffer.hasRemaining) {
        final hasRep = respBuffer.readUint16BE();
        if (hasRep != 0 && respBuffer.remaining >= 4) {
          respBuffer.skip(4);
        }
      }
    }

    _log.info('Data types negotiation complete');
  }

  /// Writes a data type mapping entry.
  void _writeDataTypeMapping(WriteBuffer buffer, int type, int conv, int rep) {
    buffer.writeUint16BE(type);
    buffer.writeUint16BE(conv);
    buffer.writeUint16BE(rep);
    buffer.writeUint16BE(0);
  }

  // Data type mappings [dataType, convType, repType]
  // repType: 0=NATIVE, 1=UNIVERSAL, 10=ORACLE
  // From node-oracledb dataType.js - all types needed for authentication
  static const List<List<int>> _dataTypes = [
    [1, 1, 1], // varchar
    [2, 2, 10], // number
    [8, 8, 1], // long
    [12, 12, 10], // date
    [23, 23, 1], // raw
    [24, 24, 1], // long_raw
    [25, 25, 1], // ub2
    [26, 26, 1], // ub4
    [27, 27, 10], // sb1
    [28, 28, 1], // sb2
    [29, 29, 1], // sb4
    [30, 30, 1], // sword
    [31, 31, 1], // uword
    [32, 32, 1], // ptrb
    [33, 33, 1], // ptrw
    [10, 10, 1], // tiddef
    [11, 11, 1], // rowid
    [40, 40, 1], // ams
    [41, 41, 1], // brn
    [117, 117, 1], // cwd
    [120, 120, 1], // oac122
    [290, 290, 1], // oer8
    [291, 291, 1], // fun
    [292, 292, 1], // aua
    [293, 293, 1], // rxh7
    [294, 294, 1], // na6
    [298, 298, 1], // brp
    [299, 299, 1], // brv
    [300, 300, 1], // kva
    [301, 301, 1], // cls
    [302, 302, 1], // cui
    [303, 303, 1], // dfn
    [304, 304, 1], // dqr
    [305, 305, 1], // dsc
    [306, 306, 1], // exe
    [307, 307, 1], // fch
    [308, 308, 1], // gbv
    [309, 309, 1], // gem
    [310, 310, 1], // giv
    [311, 311, 1], // okg
    [312, 312, 1], // hmi
    [313, 313, 1], // ino
    [315, 315, 1], // lnf
    [316, 316, 1], // ont
    [317, 317, 1], // ope
    [318, 318, 1], // osq
    [319, 319, 1], // sfe
    [320, 320, 1], // spf
    [321, 321, 1], // vsn
    [322, 322, 1], // ud7
    [323, 323, 1], // dsa
    [327, 327, 1], // pin
    [328, 328, 1], // pfn
    [329, 329, 1], // ppt
    [331, 331, 1], // sto
    [333, 333, 1], // arc
    [334, 334, 1], // mrs
    [335, 335, 1], // mrt
    [336, 336, 1], // mrg
    [337, 337, 1], // mrr
    [338, 338, 1], // mrc
    [339, 339, 1], // ver
    [340, 340, 1], // lon2
    [341, 341, 1], // ino2
    [342, 342, 1], // all
    [343, 343, 1], // udb
    [344, 344, 1], // aqi
    [345, 345, 1], // ulb
    [346, 346, 1], // uld
    [348, 348, 1], // sid
    [349, 349, 1], // na7
    [354, 354, 1], // al7
    [355, 355, 1], // k2rpc
    [359, 359, 1], // xdp
    [363, 363, 1], // oko8
    [380, 380, 1], // ud12
    [381, 381, 1], // al8
    [382, 382, 1], // lfop
    [383, 383, 1], // fcrt
    [384, 384, 1], // dny
    [385, 385, 1], // opr
    [386, 386, 1], // pls
    [387, 387, 1], // xid
    [388, 388, 1], // txn
    [389, 389, 1], // dcb
    [390, 390, 1], // cca
    [391, 391, 1], // wrn
    [393, 393, 1], // tlh
    [394, 394, 1], // toh
    [395, 395, 1], // foi
    [396, 396, 1], // sid2
    [397, 397, 1], // tch
    [398, 398, 1], // pii
    [399, 399, 1], // pfi
    [400, 400, 1], // ppu
    [401, 401, 1], // pte
    [404, 404, 1], // rxh8
    [405, 405, 1], // n12
    [406, 406, 1], // auth
    [407, 407, 1], // kval
    [413, 413, 1], // fgi
    [414, 414, 1], // dsy
    [415, 415, 1], // dsyr8
    [416, 416, 1], // dsyh8
    [417, 417, 1], // dsyl
    [418, 418, 1], // dsyt8
    [419, 419, 1], // dsyv8
    [420, 420, 1], // dsyp
    [421, 421, 1], // dsyf
    [422, 422, 1], // dsyk
    [423, 423, 1], // dsyy
    [424, 424, 1], // dsyq
    [425, 425, 1], // dsyc
    [426, 426, 1], // dsya
    [427, 427, 1], // ot8
    [429, 429, 1], // dsyty
    [430, 430, 1], // aqe
    [431, 431, 1], // kv
    [432, 432, 1], // aqd
    [433, 433, 1], // aq8
    [449, 449, 1], // rfs
    [450, 450, 1], // rxh10
    [454, 454, 1], // kpn
    [455, 455, 1], // kpdnr
    [456, 456, 1], // dsyd
    [457, 457, 1], // dsys
    [458, 458, 1], // dsyr
    [459, 459, 1], // dsyh
    [460, 460, 1], // dsyt
    [461, 461, 1], // dsyv
    [462, 462, 1], // aqm
    [463, 463, 1], // oer11
    [466, 466, 1], // aql
    [467, 467, 1], // otc
    [468, 468, 1], // kfno
    [469, 469, 1], // kfnp
    [470, 470, 1], // kgt8
    [471, 471, 1], // rasb4
    [472, 472, 1], // raub2
    [473, 473, 1], // raub1
    [474, 474, 1], // ratxt
    [475, 475, 1], // rssb4
    [476, 476, 1], // rsub2
    [477, 477, 1], // rsub1
    [478, 478, 1], // rstxt
    [479, 479, 1], // ridl
    [480, 480, 1], // glrdd
    [481, 481, 1], // glrdg
    [482, 482, 1], // glrdc
    [483, 483, 1], // oko
    [484, 484, 1], // dpp
    [485, 485, 1], // dpls
    [486, 486, 1], // dpmop
    [490, 490, 1], // stat
    [491, 491, 1], // rfx
    [492, 492, 1], // fal
    [493, 493, 1], // ckv
    [494, 494, 1], // drcx
    [495, 495, 1], // kgh
    [496, 496, 1], // aqo
    [498, 498, 1], // okgt
    [499, 499, 1], // kpfc
    [500, 500, 1], // fe2
    [501, 501, 1], // spfp
    [502, 502, 1], // dpuls
    [509, 509, 1], // aqa
    [510, 510, 1], // kpbf
    [513, 513, 1], // tsm
    [514, 514, 1], // mss
    [516, 516, 1], // kpc
    [517, 517, 1], // crs
    [518, 518, 1], // kks
    [519, 519, 1], // ksp
    [520, 520, 1], // ksptop
    [521, 521, 1], // kspval
    [522, 522, 1], // pss
    [523, 523, 1], // nls
    [524, 524, 1], // als
    [525, 525, 1], // ksdevtval
    [526, 526, 1], // ksdevttop
    [527, 527, 1], // kpspp
    [528, 528, 1], // kol
    [529, 529, 1], // lst
    [530, 530, 1], // acx
    [531, 531, 1], // scs
    [532, 532, 1], // rxh
    [533, 533, 1], // kpdns
    [534, 534, 1], // kpdcn
    [535, 535, 1], // kpnns
    [536, 536, 1], // kpncn
    [537, 537, 1], // kps
    [538, 538, 1], // apinf
    [539, 539, 1], // ten
    [540, 540, 1], // xsscs
    [541, 541, 1], // xssso
    [542, 542, 1], // xssao
    [543, 543, 1], // ksrpc
    [560, 560, 1], // kvl
    [565, 565, 1], // xssdef
    [572, 572, 1], // pdqcinv
    [573, 573, 1], // pdqidc
    [574, 574, 1], // kpdqcsta
    [575, 575, 1], // kprs
    [576, 576, 1], // kpdqidc
    [578, 578, 1], // rtstrm
    [563, 563, 1], // sessget
    [564, 564, 1], // sessrel
    [579, 579, 1], // sessret
    [580, 580, 1], // scn6
    [581, 581, 1], // kecpa
    [582, 582, 1], // kecpp
    [583, 583, 1], // sxa
    [584, 584, 1], // kvarr
    [585, 585, 1], // kpngn
    [3, 2, 10], // binary_integer
    [4, 2, 10], // float
    [5, 1, 1], // str
    [6, 2, 10], // vnu
    [7, 2, 10], // pdn
    [9, 1, 1], // vcs
    [15, 1, 1], // vbi
    [39, 39, 1], // oac9
    [68, 2, 10], // uin
    [91, 2, 10], // sls
    [94, 1, 1], // lvc
    [95, 23, 1], // lvb
    [96, 96, 1], // char
    [97, 96, 1], // avc
    [100, 100, 1], // binary_float
    [101, 101, 1], // binary_double
    [102, 102, 1], // cursor
    [104, 11, 1], // rdd
    [106, 106, 1], // osl
    [108, 109, 1], // ext_named
    [109, 109, 1], // int_named
    [110, 111, 1], // ext_ref
    [111, 111, 1], // int_ref
    [112, 112, 1], // clob
    [113, 113, 1], // blob
    [114, 114, 1], // bfile
    [115, 115, 1], // cfile
    [116, 102, 1], // rset
    [119, 119, 1], // json
    [198, 198, 1], // djson
    [146, 146, 1], // clv
    [152, 2, 10], // dtr
    [153, 2, 10], // dun
    [154, 2, 10], // dop
    [155, 1, 1], // vst
    [156, 12, 10], // odt
    [172, 2, 10], // dol
    [178, 178, 1], // time
    [179, 179, 1], // time_tz
    [180, 180, 1], // timestamp
    [181, 181, 1], // timestamp_tz
    [182, 182, 1], // interval_ym
    [183, 183, 1], // interval_ds
    [184, 12, 10], // edate
    [185, 185, 1], // etime
    [186, 186, 1], // ettz
    [187, 187, 1], // estamp
    [188, 188, 1], // estz
    [189, 189, 1], // eiym
    [190, 190, 1], // eids
    [195, 112, 1], // dclob
    [196, 113, 1], // dblob
    [197, 114, 1], // dbfile
    [208, 208, 1], // urowid
    [231, 231, 1], // timestamp_ltz
    [232, 231, 1], // esitz
    [233, 233, 1], // ub8
    [241, 109, 1], // pnty
    [252, 252, 1], // boolean
    [590, 590, 1], // xsnsop
    [591, 591, 1], // xsattr
    [592, 592, 1], // xsns
    [613, 613, 1], // ub1array
    [614, 614, 1], // sessstate
    [615, 615, 1], // ac_replay
    [616, 616, 1], // ac_cont
    [611, 611, 1], // implres
    [612, 612, 1], // oer19
    [593, 593, 1], // txt
    [594, 594, 1], // xssessns
    [595, 595, 1], // xsattop
    [596, 596, 1], // xscreop
    [597, 597, 1], // xsdetop
    [598, 598, 1], // xsdesop
    [599, 599, 1], // xssetsp
    [600, 600, 1], // xssidp
    [601, 601, 1], // xsprin
    [602, 602, 1], // xskvl
    [603, 603, 1], // xsssdef2
    [604, 604, 1], // xsnsop2
    [605, 605, 1], // xsns2
    [622, 622, 1], // kpdnreq
    [623, 623, 1], // kpdnrnf
    [624, 624, 1], // kpngnc
    [625, 625, 1], // kpnri
    [626, 626, 1], // aqenq
    [627, 627, 1], // aqdeq
    [628, 628, 1], // aqjms
    [629, 629, 1], // kpdnrpay
    [630, 630, 1], // kpdnrack
    [631, 631, 1], // kpdnrmp
    [632, 632, 1], // kpdnrdq
    [637, 637, 1], // scn
    [638, 638, 1], // scn8
    [636, 636, 1], // chunkinfo
    [639, 639, 1], // ud21
    [663, 663, 1], // uds
    [640, 640, 1], // tnp
    [652, 652, 1], // oer
    [646, 646, 1], // oac
    [647, 647, 1], // sesssign
    [127, 127, 1], // vector
  ];

  // Compile capability indices (from node-oracledb constants.js)
  static const int _ccapSqlVersion = 0;
  static const int _ccapLogonTypes = 4;
  static const int _ccapCtbFeatureBackport = 5;
  static const int _ccapFieldVersion = 7;
  static const int _ccapServerDefineConv = 8;
  static const int _ccapDequeueWithSelector = 9;
  static const int _ccapTtc1 = 15;
  static const int _ccapOci1 = 16;
  static const int _ccapTdsVersion = 17;
  static const int _ccapRpcVersion = 18;
  static const int _ccapRpcSig = 19;
  static const int _ccapDbfVersion = 21;
  static const int _ccapLob = 23;
  static const int _ccapTtc2 = 26;
  static const int _ccapUb2Dty = 27;
  static const int _ccapOci2 = 31;
  static const int _ccapClientFn = 34;
  static const int _ccapOci3 = 35;
  static const int _ccapTtc3 = 37;
  static const int _ccapSessSignatureVersion = 39;
  static const int _ccapTtc4 = 40;
  static const int _ccapLob2 = 42;
  static const int _ccapTtc5 = 44;
  static const int _ccapVectorFeatures = 52;
  static const int _ccapMax = 53;

  // Runtime capability indices
  static const int _rcapCompat = 0;
  static const int _rcapTtc = 6;
  static const int _rcapMax = 7;

  /// Builds client compile-time capabilities.
  /// Buffer size must be TNS_CCAP_MAX (53 bytes).
  Uint8List _buildCompileCapabilities() {
    final caps = Uint8List(_ccapMax);

    // SQL version (index 0)
    caps[_ccapSqlVersion] = 6; // TNS_CCAP_SQL_VERSION_MAX

    // Logon types (index 4) - support O5LOGON, O7LOGON, O8LOGON, O9LOGON
    // O5LOGON=8, O5LOGON_NP=2, O7LOGON=32, O8LOGON_LONG_IDENTIFIER=64, O9LOGON_LONG_PASSWORD=0x80
    caps[_ccapLogonTypes] = 8 | 2 | 32 | 64 | 0x80; // = 0xBE

    // CTB feature backport (index 5) - implicit pool + oauth msg on err
    caps[_ccapCtbFeatureBackport] = 0x08 | 0x10; // = 0x18

    // Field version (index 7) - Oracle 23.4 max
    caps[_ccapFieldVersion] = 24; // TNS_CCAP_FIELD_VERSION_MAX

    // Server define conv (index 8)
    caps[_ccapServerDefineConv] = 1;

    // Dequeue with selector (index 9)
    caps[_ccapDequeueWithSelector] = 1;

    // TTC1 flags (index 15) - FAST_BVEC | END_OF_CALL_STATUS | IND_RCD
    caps[_ccapTtc1] = 0x20 | 0x01 | 0x08; // = 0x29

    // OCI1 flags (index 16) - FAST_SESSION_PROPAGATE | APP_CTX_PIGGYBACK
    caps[_ccapOci1] = 0x10 | 0x80; // = 0x90

    // TDS version (index 17)
    caps[_ccapTdsVersion] = 3; // TNS_CCAP_TDS_VERSION_MAX

    // RPC version (index 18)
    caps[_ccapRpcVersion] = 7; // TNS_CCAP_RPC_VERSION_MAX

    // RPC sig (index 19)
    caps[_ccapRpcSig] = 3; // TNS_CCAP_RPC_SIG_VALUE

    // DBF version (index 21)
    caps[_ccapDbfVersion] = 1; // TNS_CCAP_DBF_VERSION_MAX

    // LOB flags (index 23) - UB8_SIZE | ENCS | PREFETCH_DATA | TEMP_SIZE | PREFETCH | 12C
    caps[_ccapLob] = 0x01 | 0x02 | 0x04 | 0x08 | 0x40 | 0x80; // = 0xCF

    // TTC2 flags (index 26) - ZLNP
    caps[_ccapTtc2] = 0x04;

    // UB2 DTY (index 27)
    caps[_ccapUb2Dty] = 1;

    // OCI2 flags (index 31) - DRCP
    caps[_ccapOci2] = 0x10;

    // Client FN (index 34)
    caps[_ccapClientFn] = 12; // TNS_CCAP_CLIENT_FN_MAX

    // OCI3 flags (index 35) - OCSSYNC
    caps[_ccapOci3] = 0x20;

    // TTC3 flags (index 37) - IMPLICIT_RESULTS | BIG_CHUNK_CLR | KEEP_OUT_ORDER | LTXID
    caps[_ccapTtc3] = 0x10 | 0x20 | 0x80 | 0x08; // = 0xB8

    // Session signature version (index 39)
    caps[_ccapSessSignatureVersion] = 8; // TNS_CCAP_FIELD_VERSION_12_2

    // TTC4 flags (index 40) - INBAND_NOTIFICATION (+ END_OF_REQUEST if supported)
    caps[_ccapTtc4] = 0x04; // INBAND_NOTIFICATION
    if (_supportsEndOfRequest) {
      caps[_ccapTtc4] |= 0x20; // END_OF_REQUEST
    }

    // LOB2 flags (index 42) - QUASI | 2GB_PREFETCH
    caps[_ccapLob2] = 0x01 | 0x04; // = 0x05

    // TTC5 flags (index 44) - VECTOR_SUPPORT | SESSIONLESS_TXNS
    caps[_ccapTtc5] = 0x08 | 0x20; // = 0x28

    // Vector features (index 52) - BINARY | SPARSE
    caps[_ccapVectorFeatures] = 0x01 | 0x02; // = 0x03

    return caps;
  }

  /// Builds client runtime capabilities.
  /// Buffer size must be TNS_RCAP_MAX (7 bytes).
  Uint8List _buildRuntimeCapabilities() {
    final caps = Uint8List(_rcapMax);

    // Compat (index 0)
    caps[_rcapCompat] = 2; // TNS_RCAP_COMPAT_81

    // TTC flags (index 6) - ZERO_COPY | 32K
    caps[_rcapTtc] = 0x01 | 0x04; // = 0x05

    return caps;
  }

  // END_OF_RPC bit written in the client's final DATA packet — required by
  // Oracle 23ai to signal the end of each client request. node-oracledb uses
  // this same value (FAST_AUTH_END_OF_RPC_VALUE = 0x800) for every sendPacket.
  static const int _tnsDataFlagsEndOfRpc = 0x0800;

  /// Extracts the Oracle major version number from a server banner string.
  ///
  /// Tries "Release X." or "Version X." first, then falls back to the first
  /// two-or-more digit token. Returns `null` if no version can be found.
  static int? _extractMajorVersion(String banner) {
    final match = RegExp(r'(?:Release|Version)\s+(\d+)\.').firstMatch(banner);
    if (match != null) return int.tryParse(match.group(1)!);
    final fallback = RegExp(r'\b(\d{2,})\b').firstMatch(banner);
    return fallback != null ? int.tryParse(fallback.group(1)!) : null;
  }

  /// Sends TTC data in a TNS DATA packet with proper data flags.
  ///
  /// TNS DATA packets have a 2-byte data flags field at the start of
  /// the payload, followed by the actual TTC message data.
  ///
  /// DATA-flags contract (AC9 — the default is intentionally version-gated, not
  /// a constant, and is the Oracle-protocol-required behaviour):
  ///   * Oracle 23ai (`serverMajorVersion >= 23`): the default is
  ///     `_tnsDataFlagsEndOfRpc` (0x0800). 23ai requires the END_OF_RPC bit on
  ///     every client request; without it the server waits for more client data
  ///     after its first response and ignores subsequent commands.
  ///   * Pre-23ai servers: the default is `0x0000` — they do not understand the
  ///     END_OF_RPC bit.
  ///   * Bootstrap callsites (protocol negotiation, data-types negotiation,
  ///     classical AUTH_PHASE_ONE, FAST_AUTH) run before the server version is
  ///     known and therefore pass `dataFlags: 0x0000` explicitly to override
  ///     this default safely. AUTH_PHASE_TWO passes `0x0800` only on the
  ///     FAST_AUTH path (see [AuthFlow.authenticate]).
  /// Callers that need a non-default flag must pass [dataFlags] explicitly; the
  /// default deliberately encodes the per-version steady-state requirement so
  /// ordinary execute/commit/rollback/fetch callsites do not have to repeat it.
  Future<void> sendData(Uint8List ttcData, {int? dataFlags}) async {
    dataFlags ??= _serverMajorVersion >= 23 ? _tnsDataFlagsEndOfRpc : 0x0000;

    // Build payload with 2-byte data flags prefix
    final payload = Uint8List(2 + ttcData.length);
    payload[0] = (dataFlags >> 8) & 0xFF; // Data flags high byte (BE)
    payload[1] = dataFlags & 0xFF; // Data flags low byte (BE)
    payload.setRange(2, payload.length, ttcData);

    final packet = TnsPacket(type: tnsPacketData, payload: payload);
    await send(packet);
  }

  /// Sends a TNS MARKER packet with RESET data (NIQRMARK=2).
  ///
  /// Required after receiving an Oracle BREAK MARKER: Oracle will not send the
  /// DATA error response until the client acknowledges with a RESET MARKER.
  /// Marker payload: [1 (NSPMKTD1=with-data), 0 (pad), 2 (NIQRMARK=reset)]
  Future<void> _sendResetMarker() async {
    final payload = Uint8List(3);
    payload[0] = 1; // NSPMKTD1 — data marker with 1 data byte
    payload[1] = 0; // padding
    payload[2] = 2; // NIQRMARK — reset
    final packet = TnsPacket(type: tnsPacketMarker, payload: payload);
    await send(packet);
  }

  /// Receives TTC data from a TNS DATA packet, stripping data flags.
  ///
  /// Returns the TTC message data with the 2-byte data flags prefix removed.
  /// If there's buffered data from FAST_AUTH, returns that instead.
  Future<Uint8List> receiveData() async {
    // Check if we have buffered AUTH response from FAST_AUTH
    if (_bufferedAuthResponse != null) {
      final buffered = _bufferedAuthResponse!;
      _bufferedAuthResponse = null; // Clear buffer after returning
      _log.fine('Returning buffered AUTH response: ${buffered.length} bytes');
      return buffered;
    }

    var response = await receive();

    // Handle MARKER packets - Oracle may send these during authentication
    // Simply skip them and read the next packet
    while (response.type == tnsPacketMarker) {
      _log.fine(
          'Received MARKER packet (${response.payload.length} bytes), reading next packet');
      response = await receive();
    }

    // Handle REFUSE packet - Oracle sends this when authentication fails
    if (response.type == tnsPacketRefuse) {
      _log.warning('Authentication refused by server');
      throw const OracleException(
        errorCode: oraInvalidCredentials,
        message: 'Authentication failed: invalid username or password',
      );
    }

    if (response.type != tnsPacketData) {
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'Expected DATA packet, got type ${response.type}',
      );
    }

    // Skip 2-byte data flags prefix
    if (response.payload.length < 2) {
      return response.payload;
    }
    return response.payload.sublist(2);
  }
}
