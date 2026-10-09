import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../errors.dart';
import '../protocol/buffer.dart';
import '../protocol/constants.dart';
import '../protocol/lob_locator.dart';
import '../protocol/messages/auth_message.dart';
import '../protocol/messages/execute_message.dart';
import '../protocol/messages/fast_auth_message.dart';
import '../protocol/messages/lob_op_message.dart';
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
  /// — including any prepended close-cursor piggyback — may be.
  int _sdu = tnsDefaultSdu;

  /// Whether the server supports end-of-request markers.
  /// Set after parsing ACCEPT packet flag2 field.
  bool _supportsEndOfRequest = false;

  /// Whether this connection's national character set (AL16UTF16) can
  /// round-trip NCHAR/NVARCHAR2/NCLOB values as UTF-16BE.
  ///
  /// Set once by the connection after startup charset detection (Story 10.1)
  /// from [OracleCharsetInfo.supportsNationalCharacterSet], and threaded into
  /// every execute/fetch response decode. When `false`, decoding a
  /// national-charset value fails loud instead of risking silent corruption.
  /// Defaults to `true` so the startup detection query itself (and any decode
  /// before detection completes, which never touches national types) is
  /// unaffected.
  bool supportsNationalCharset = true;

  /// National charset name reported by the connection startup detection query.
  ///
  /// Used only in fail-loud diagnostics. Defaults to the supported value so
  /// unit-test and pre-detection transport paths keep their historical behavior.
  String nationalCharset = 'AL16UTF16';

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

  /// Whether the AUTH_PHASE_TWO 23ai token-number field should be written.
  ///
  /// Gated on BOTH the negotiated field version ([shouldWriteTokenNumber]) AND
  /// the server-advertised FAST_AUTH capability ([supportsFastAuth]). A pre-23
  /// (classical) server may leave [ttcFieldVersion] at its default 24 when it
  /// sends no — or too short — compile capabilities, so the field-version check
  /// alone would incorrectly emit the 23ai token. FAST_AUTH is the protocol
  /// presence signal that a pre-23 server is never given the 23ai format.
  bool get shouldWriteAuthPhaseTwoToken =>
      _supportsFastAuth && shouldWriteTokenNumber;

  /// Gets the one-byte TTC function sequence number for the next message
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
  /// Used to exercise the token-number gating boundaries and the pre-23
  /// classical-server case deterministically. Not part of the public API.
  @visibleForTesting
  set debugTtcFieldVersion(int version) => _ttcFieldVersion = version;

  /// Test-only seam to drive [supportsFastAuth] without a live ACCEPT packet.
  ///
  /// Used to exercise the AUTH_PHASE_TWO token gating for both 23ai (FAST_AUTH)
  /// and pre-23 classical servers. Not part of the public API.
  @visibleForTesting
  set debugSupportsFastAuth(bool value) => _supportsFastAuth = value;

  /// Test-only seam to drive the negotiated SDU without a live ACCEPT packet,
  /// used to exercise [closeCursorChunkLimit] boundaries.
  @visibleForTesting
  set debugSdu(int value) => _sdu = value;

  /// Test-only seam exposing the current TTC sequence counter.
  ///
  /// Exists for the sequence-wrap integration smoke test, which samples the
  /// counter across 300+ executes to prove it passes through the 256 wrap on
  /// a live connection. Surfaced to tests via
  /// `OracleConnection.debugSequence`; not a public API.
  int get debugSequence => _sequence;

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
  /// the combined packet stays within the negotiated SDU.
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
        message:
            'Transport is no longer usable: a previous RPC timed out and '
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
      'largeSdu=$_useLargeSdu',
    );
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
      'Decoded TNS packet: type=${packet.type}, payload=${packet.payload.length} bytes',
    );

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

  // Safety cap: prevent unbounded FETCH loops when moreRowsToFetch stays true.
  // Applied only to EAGER materialization (OracleConnection.execute drains the
  // cursor engine bounded by this many FETCH rounds). Lazy OracleResultSet
  // consumption is deliberately uncapped — the caller controls how far it
  // fetches, so a huge result set cannot loop forever inside a single call.
  static const int _defaultMaxFetchIterations = 1000;
  int _maxFetchIterations = _defaultMaxFetchIterations;

  /// The eager-materialization FETCH-round safety cap. Read by
  /// `OracleConnection.execute` when draining the shared cursor engine; not a
  /// public API.
  @internal
  int get maxFetchIterations => _maxFetchIterations;

  /// Test-only seam to lower the fetch-drain iteration cap so the
  /// incomplete-result path (`moreRowsToFetch == true` after hitting the cap)
  /// can be exercised deterministically without draining 1,000 fetch rounds.
  /// Not part of the public API.
  @visibleForTesting
  set debugMaxFetchIterations(int value) => _maxFetchIterations = value;

  /// Safety cap: the maximum number of TNS packets a single
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

  /// Test-only seam to lower the receive-loop packet cap so the
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
  /// Instrumentation: lets integration tests prove cursor reuse / parse
  /// skipping at the transport layer without requiring `V$OPEN_CURSOR` or other
  /// privileged views. Surfaced to callers via
  /// `OracleConnection.debugFullParseExecutes`; not a public API.
  int get debugFullParseExecutes => _fullParseExecutes;

  /// Number of cursor-reuse EXECUTEs sent (cursorId != 0, parse skipped).
  int get debugReuseExecutes => _reuseExecutes;

  /// Resets the execute instrumentation counters ([debugFullParseExecutes] /
  /// [debugReuseExecutes]) to zero.
  ///
  /// Called once by [OracleConnection] immediately after the internal
  /// connection-startup charset-detection query (Story 10.1), so that the
  /// detection round trip — which user code never issued — is invisible to the
  /// post-connect instrumentation that tests and pool diagnostics observe.
  /// Detection runs as an uncacheable query (no cache entry, server-closed
  /// cursor on fetch EOF), so only these parse/reuse counters need resetting.
  /// Not part of the public API.
  ///
  /// SCOPE BOUNDARY — counters this method deliberately does NOT reset, and the
  /// invariant that makes the exclusion correct *for the current detection
  /// query* (`SELECT parameter, value FROM nls_database_parameters …`, two
  /// VARCHAR2 columns, uncacheable — see [OracleConnection] `_charsetDetectionSql`):
  ///
  /// - [_sequence] (TTC packet sequence byte) — this is wire protocol state, not
  ///   a footprint counter. The detection round trip *does* advance it, and it
  ///   MUST stay advanced: rewinding it would desync the server's sequence
  ///   tracking on the next message. Never add it here.
  /// - [_lobReadOps] — incremented only by [sendLobOp] with `tnsLobOpRead`. The
  ///   current detection query selects only VARCHAR2 columns, so it issues no
  ///   LOB READ and this counter is still 0 when reset runs. Nothing to reset.
  /// - `OracleConnection._describeRetries` — incremented only by a cached-query
  ///   ORA-01007/00932 describe-mismatch re-execute. Detection is forced
  ///   uncacheable, and a fresh connection has nothing to mismatch against, so
  ///   it can never fire for the detection query. Nothing to reset.
  ///
  /// WARNING for a future change: if any later Epic 10 story rewrites the
  /// detection query to read a **LOB column** (advancing [_lobReadOps]) — or
  /// otherwise makes it cacheable in a way that could trip a describe-mismatch
  /// retry — that detection footprint would then leak into the post-connect
  /// instrumentation that tests/pool diagnostics assert on. In that case extend
  /// this reset to cover the newly-advanced counter (and reset
  /// `_describeRetries` from the connection-side reset path, since it lives on
  /// [OracleConnection], not here). [_sequence] always stays excluded.
  @internal
  void resetExecuteInstrumentation() {
    _fullParseExecutes = 0;
    _reuseExecutes = 0;
    // Intentionally NOT reset: _sequence (wire state, must stay advanced),
    // _lobReadOps (detection issues no LOB READ today), and
    // OracleConnection._describeRetries (detection is uncacheable, never
    // mismatches). See the SCOPE BOUNDARY note in this method's doc comment
    // before changing the detection query to read a LOB column.
  }

  /// Temporary LOB locators awaiting a free-temp piggyback.
  ///
  /// Internal temporary CLOBs created for bind values are not freed with a
  /// standalone RPC — node-oracledb frees them via a `TNS_FUNC_LOB_OP`
  /// piggyback (`FREE_TEMP | ARRAY`) prepended to the next message
  /// (base.js `writeCloseTempLobsPiggyback`). Locators queue here after the
  /// execute that bound them and ride the next [sendExecute]; any remainder
  /// at session end is reaped by the server at teardown, like cached cursors.
  final List<Uint8List> _tempLobsToClose = [];
  int _tempLobsTotalSize = 0;

  /// Content keys of every locator currently on [_tempLobsToClose], so
  /// [queueTempLobToFree]'s dedupe backstop is O(1) instead of a linear scan.
  ///
  /// MUST be kept in lockstep with [_tempLobsToClose] at all three mutation
  /// sites (queue, drain, and the drain's restore-on-bind-failure) — a stale key
  /// would silently swallow a free that was genuinely needed, and a missing one
  /// would let a double free through.
  ///
  /// Why a parallel index rather than a `Set` replacing the list: the piggyback
  /// sends the locator BYTES in queue order and needs the original `Uint8List`
  /// instances (which `copyBackLocator` may have updated in place — node-oracledb
  /// likewise frees its copy-back-updated locator), so the list stays
  /// authoritative for what is sent and this set answers only "is it already in
  /// there?".
  final Set<String> _tempLobKeysToClose = <String>{};

  /// Content key for a locator buffer: its bytes as a `String` (every byte is a
  /// valid UTF-16 code unit, so this is a lossless, cheap, hashable snapshot of
  /// the 40-odd bytes — no allocation-heavy hex formatting).
  ///
  /// Snapshot semantics, deliberately: the key is derived when the locator is
  /// QUEUED, and it exactly reproduces the live byte-for-byte scan it replaces on
  /// every measured path.
  ///
  /// Do NOT read that as "a pending buffer cannot mutate" — it can.
  /// [copyBackLocator] does `source.setRange(0, source.length, updated)`, i.e. it
  /// writes INTO the live locator buffer, which is precisely the instance
  /// [_createTempClob] queues and the instance an `OracleLob` later hands to
  /// [queueTempLobToFree]. So this key is a snapshot of a buffer the driver keeps
  /// updating, and the dedupe's real basis is **byte-equality between two echoes
  /// of ONE locator taken at different points in its life** (the create helper's
  /// post-WRITE echo vs the handle's or the materialize path's post-READ echo) —
  /// an empirical invariant, proven on both the 23ai and 21c fixtures, not a
  /// structural one. Node-oracledb likewise frees its copy-back-updated locator,
  /// which is why snapshotting is not obviously the wrong call. Hardening the
  /// comparison to a locator identity SUBRANGE (so in-place mutation could not
  /// matter at all) is the robust form and a tracked follow-up; if the two echoes
  /// ever diverge, the stale key degrades to the same double-queue this backstop
  /// already documents as its residual risk, not to something new.
  static String _tempLobKey(Uint8List locator) => String.fromCharCodes(locator);

  /// Number of temp-LOB locators queued for the free piggyback. Exposed for
  /// integration tests (temp-LOB lifecycle) via
  /// `OracleConnection.debugPendingTempLobCount`; not a public API.
  ///
  /// Three kinds of locator land on the queue: the driver's own bind-conversion
  /// temp LOBs ([_createTempClob] / [_createTempBlob], queued right after the
  /// execute that bound them); since Story 12.2, a **caller-owned** temporary
  /// LOB whose public `OracleLob.close()` released it (queued via
  /// [queueTempLobToFree]); and since Story 12.4, a **server-allocated**
  /// temporary locator the `fetchLobs`-off materialize path read and discarded
  /// ([_materializeLobValues], the `IN OUT` LOB-bind OUT locator). Either way the
  /// count drains to zero on the next [sendExecute].
  int get debugPendingTempLobCount => _tempLobsToClose.length;

  /// Queues [locator]'s raw bytes for the free-temporary-LOB piggyback that
  /// rides the NEXT [sendExecute], keeping [_tempLobsTotalSize] in step (that
  /// total is a single UB4 in the piggyback header covering the concatenated
  /// locator bytes, so the two must never diverge).
  ///
  /// Package-internal seam for `OracleConnection.releaseLob`, so a caller-owned
  /// temporary `OracleLob` frees its server-side resource on `close()` without
  /// `oracle_lob.dart` ever reaching into the transport. Issues no wire traffic
  /// and cannot fail — safe to call from a `close()` that is contractually
  /// exception-free, and from the pool's reclaim path.
  ///
  /// Callers must still queue each locator at most once — a double queue would
  /// send the same locator twice in one piggyback, and because the piggyback
  /// rides an unrelated statement's message a double free surfaces as an error on
  /// THAT statement, not here.
  ///
  /// Since Story 12.4 that caller obligation is the PRIMARY guarantee, not the
  /// only one: this method also dedupes at the locator level as a backstop,
  /// skipping bytes that are already pending (see [_tempLobKeysToClose] and
  /// the "Locator-level dedupe backstop" section below, which is the authority on
  /// why the backstop is both necessary and safe). The structural invariant the
  /// code is still designed around is **one temporary locator has exactly one
  /// owner responsible for queueing it**, and there are exactly two kinds of
  /// owner:
  ///
  /// 1. **An `OracleLob` handle** (`wrapLob != null`, i.e. `fetchLobs: true`, and
  ///    every `createTemporary*` handle). `OracleLob.close()` is idempotent — it
  ///    queues only on the first call, via `OracleConnection.releaseLob` — so a
  ///    double free is impossible. Every created-temporary handle owns a locator
  ///    freshly returned by [createTemporaryLob], and the only FETCHED shape
  ///    measured to carry the TEMP flag is an `IN OUT` bind's returned OUT
  ///    locator, which is wrapped exactly once.
  /// 2. **The materialize path** (`wrapLob == null`, i.e. `fetchLobs: false`),
  ///    since Story 12.4: there is no handle at all, so `_materializeLobValues`
  ///    queues the locator itself right after reading it. It runs behind that
  ///    method's per-response `materialized` dedup map, so an aliased locator
  ///    (Oracle's duplicate-column optimization) is queued at most once per
  ///    response.
  ///
  /// The two are **mutually exclusive by construction** — one `materializeLobs`
  /// call either wraps a locator or materializes it, never both — which is what
  /// keeps a locator from being queued twice, once by each owner class.
  ///
  /// **Locator-level dedupe backstop (Story 12.4).** Because owner class 2 is a
  /// path with no handle, one case CAN present the same LOB to both: a PL/SQL
  /// `IN OUT` LOB bind whose body does not allocate a new LOB (`p := p`) returns
  /// the very locator the driver created for the INPUT value — which
  /// [_createTempClob] / [_createTempBlob] already queued. Queueing it again
  /// would put the same locator twice in ONE piggyback, and because that
  /// piggyback rides an unrelated statement's message the resulting double free
  /// would surface as an error on THAT statement. So this method now skips a
  /// locator whose bytes are already pending — exactly the "locator-level
  /// dedupe here" this docstring has always prescribed for that situation.
  /// Distinct temporary LOBs never share locator bytes (a locator encodes the
  /// LOB's unique server-side identity), and a locator can only be re-created
  /// after its free was actually SENT — i.e. after it left this list — so the
  /// dedupe can never swallow a free that was genuinely needed.
  ///
  /// **The backstop's guarantee is COUPLED to the fetched-handle slot rule, and
  /// that rule is scheduled for review.** For the `fetchLobs: true` version of
  /// `p := p`, `_createTempClob` queues locator L and the wrapping handle queues
  /// the same bytes again when it closes. Both attempts land in ONE pending
  /// window — which is the only reason the dedupe sees the second one at all —
  /// and that window is guaranteed solely because an open fetched handle trips
  /// `OracleConnection._rejectConcurrentOperation`, so no [sendExecute] can drain
  /// the queue while the handle lives. `_validateLobBindValue`'s dartdoc names
  /// relaxing that slot rule as an open Epic 12 follow-up. Relaxing it re-opens a
  /// genuine DOUBLE FREE for this shape (the intervening execute drains L, then
  /// the handle's close queues L again) AND leaves the handle dangling (its LOB
  /// already freed → ORA-22922 on the next `read()`). Whoever relaxes it owns
  /// both. Note the existing regression test for this shape closes the handle
  /// BEFORE any further execute, so it cannot catch that regression.
  ///
  /// The check is **O(1)**, via the [_tempLobKeysToClose] content index. It has
  /// to be: the queue is NOT "at most a handful of entries" on every shape —
  /// `_prepareBulkRowLobs` queues one locator per row BEFORE the single array
  /// execute, so an N-row `executeMany()` with a CLOB/BLOB column would perform
  /// ~N²/2 whole-locator byte comparisons under a linear scan (a real
  /// bulk-load regression), and an application may likewise open many
  /// `createTemporary*` handles between two executes.
  @internal
  void queueTempLobToFree(Uint8List locator) {
    if (!_tempLobKeysToClose.add(_tempLobKey(locator))) return;
    _tempLobsToClose.add(locator);
    _tempLobsTotalSize += locator.length;
  }

  /// Creates an EMPTY session-duration temporary LOB on the server and returns
  /// its locator, seeded with the server's real chunk size.
  ///
  /// Mirrors node-oracledb `thin/lob.js create()` exactly: one CREATE_TEMP over
  /// a zeroed 40-byte source locator with the charset form in the source offset
  /// ([csfrm] — [ttcCsfrmImplicit] for CLOB, [ttcCsfrmNChar] for NCLOB, `0` for
  /// BLOB), the Oracle type in the dest offset ([oraType]) and
  /// [tnsDurationSession] in the dest length, followed by one GET_CHUNK_SIZE
  /// (`sendAmount: true`, whose SB8 reply carries the chunk size —
  /// `_getChunkSizeAsync()`). The returned locator is marked
  /// `isTemporary: true` and reports `length: 0`: a temp LOB is created empty
  /// and filled by later WRITEs.
  ///
  /// This is the sibling of [_createTempClob] / [_createTempBlob] (the IMPLICIT
  /// bind conversion, which creates AND fills AND self-queues for the free
  /// piggyback). Here the caller owns the lifetime: nothing is queued on the
  /// success path — `OracleConnection.releaseLob` queues it when the public
  /// `OracleLob` closes. If any step AFTER a successful CREATE_TEMP throws, the
  /// just-created locator IS queued before the exception propagates, so a
  /// partially-created temp LOB can never leak (same discipline as the create
  /// helpers' `finally`).
  ///
  /// Throws [OracleException] when the server rejects the operation or returns
  /// no locator.
  @internal
  Future<LobLocator> createTemporaryLob({
    required int oraType,
    required int csfrm,
    Duration? timeout = const Duration(minutes: 2),
  }) async {
    final created = await sendLobOp(
      operation: tnsLobOpCreateTemp,
      sourceLocator: Uint8List(tnsLobLocatorBufferSize),
      sourceOffset: csfrm,
      destOffset: oraType,
      destLength: tnsDurationSession,
      timeout: timeout,
    );
    final locator = created.updatedLocator;
    if (locator == null) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'Temporary '
            '${oraType == oraTypeBlob ? 'BLOB' : 'CLOB'} creation returned no '
            'locator',
      );
    }
    try {
      // node-oracledb `create()` follows CREATE_TEMP with _getChunkSizeAsync()
      // so the handle reports the server's real chunk size instead of 0. No
      // wire-format change is needed: `sendAmount` alone drives both the
      // trailing UB8 on the request and the SB8 amount in the reply.
      final chunk = await sendLobOp(
        operation: tnsLobOpGetChunkSize,
        sourceLocator: locator,
        sendAmount: true,
        timeout: timeout,
      );
      // Keep the live locator buffer tracking the server's latest echo, exactly
      // like every other LOB op (lobOp.js processReturnParameter).
      copyBackLocator(locator, chunk.updatedLocator);
      final amount = chunk.amount;
      if (amount == null) {
        throw const OracleException(
          errorCode: oraProtocolError,
          message: 'Temporary LOB creation: GET_CHUNK_SIZE returned no amount',
        );
      }
      return LobLocator(
        locator: locator,
        oracleType: oraType,
        length: 0, // a temporary LOB is created empty
        chunkSize: amount,
        isNChar: csfrm == ttcCsfrmNChar,
        isTemporary: true,
      );
    } catch (_) {
      // The temp LOB already exists on the server. Queue it for the free
      // piggyback BEFORE propagating, so a half-created handle the caller never
      // receives cannot leak session temp-LOB space.
      queueTempLobToFree(locator);
      rethrow;
    }
  }

  /// Count of TTC LOB READ operations sent (one per [sendLobOp] call with
  /// `tnsLobOpRead`). See [debugLobReadOps].
  int _lobReadOps = 0;

  /// Number of LOB READ operations sent on this transport.
  ///
  /// Instrumentation for the CLOB/BLOB drain integration tests: proves how
  /// many READ round trips materialized a locator value without privileged
  /// Oracle views. Surfaced to tests via `OracleConnection.debugLobReadOps`;
  /// not a public API.
  int get debugLobReadOps => _lobReadOps;

  /// TEST-ONLY per-piece cap for [readLobRange], `null` (off) in production.
  ///
  /// **Never a public knob**, and deliberately not a caller-facing `pieceSize`
  /// for `OracleLob.read()` — see [debugLobReadPieceUnits] for why it exists.
  int? _debugLobReadPieceUnits;

  /// TEST-ONLY: forces [readLobRange] to request at most this many units per
  /// `tnsLobOpRead`, making its continuation loop reachable against a real
  /// server. `null` (the default) leaves the production single-READ fast path
  /// **byte-for-byte unchanged**.
  ///
  /// Why it exists (Story 12.4 AC5): no live server was ever measured to
  /// short-read a LOB READ — the server's SB8 `amount` always equalled the
  /// request, up to 33.5 M units on 23ai and 8.4 M on 21c — so [readLobRange]'s
  /// continuation loop, its no-progress throw and its overshoot throw were
  /// provable only by fake transports. `readLobRange(pieceUnits:)` already
  /// existed but was reachable from no caller. This seam makes it reachable from
  /// a test without adding a wire message, a queue or a shape-specific branch.
  ///
  /// **Reach is deliberate.** It applies to [readLobRange] and therefore to both
  /// callers that need it — `OracleLob.read()` (via
  /// `OracleConnection.runLobRead`) and the `fetchLobs`-off materialize path
  /// ([_readClobAsString] / [_readBlobAsBytes]). It does **not** reach
  /// `OracleConnection.runLobReadPiece`, which issues its own single READ
  /// directly: `textStream()` / `byteStream()` already choose their own piece
  /// size, so double-capping them would prove nothing.
  ///
  /// An explicit `pieceUnits` argument always wins over this cap (the argument
  /// is the caller's own choice; the cap is only a default for callers that pass
  /// none). Surfaced to tests via `OracleConnection.debugLobReadPieceUnits`.
  @internal
  int? get debugLobReadPieceUnits => _debugLobReadPieceUnits;

  @internal
  set debugLobReadPieceUnits(int? units) {
    if (units != null && units <= 0) {
      throw ArgumentError.value(
        units,
        'units',
        'the test-only LOB read piece cap must be a positive number of units; '
            'pass null to turn it off',
      );
    }
    _debugLobReadPieceUnits = units;
  }

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
    List<List<Object?>>? bulkRows,
    int? executeManyIters,
    bool batchErrors = false,
    bool dmlRowCounts = false,
    bool dmlReturning = false,
  }) async {
    _log.fine(
      'Sending execute request (isQuery=$isQuery, isPlSql=$isPlSql, '
      'cursorId=$cursorId'
      '${bulkRows != null ? ', bulkRows=${bulkRows.length}' : ''}'
      '${executeManyIters != null ? ', executeManyIters=$executeManyIters' : ''}'
      '${dmlReturning ? ', dmlReturning' : ''}'
      ')...',
    );

    // PL/SQL executeMany responses ship one OUT-bind ROW_DATA per iteration;
    // both the completion probe and the real decode pass must know to consume
    // every one of them (single-execute PL/SQL stops after the first).
    final plSqlExecuteMany = isPlSql && executeManyIters != null;

    // DML RETURNING ships no IO_VECTOR (node-oracledb sets `outVariables` up
    // front from the return binds in `preProcess`). Seed the OUT-bind order
    // from the client-declared return-bind positions (OUT / IN OUT slots) so
    // both the completion probe and the real decode pass know which slots the
    // per-iteration ROW_DATA carries. Computed here (not in the connection
    // layer) so the transport owns the wire-order contract end to end.
    final List<int>? returningOutBindIndices =
        dmlReturning && bindMetadata != null
        ? <int>[
            for (var i = 0; i < bindMetadata.length; i++)
              if (bindMetadata[i].dir != BindDir.input) i,
          ]
        : null;

    // Record whether this execute reuses a cached server cursor (parse bit
    // cleared) or performs a full parse. The cursorId sent on the wire is the
    // authoritative signal — a non-zero id skips parse and omits the SQL bytes.
    if (cursorId == 0) {
      _fullParseExecutes++;
    } else {
      _reuseExecutes++;
    }

    // Drain the temp-LOB free list BEFORE creating this call's
    // temp LOBs, so a locator bound by this execute can never be freed by
    // its own piggyback.
    final lobsToFree = List<Uint8List>.of(_tempLobsToClose);
    final lobsToFreeSize = _tempLobsTotalSize;
    _tempLobsToClose.clear();
    _tempLobsTotalSize = 0;
    // Lockstep with the list (see _tempLobKeysToClose): once these locators are
    // no longer pending, a re-created locator with the same bytes must be
    // queueable again.
    _tempLobKeysToClose.clear();

    // CLOB-typed String binds, BLOB-typed Uint8List binds
    // (and PL/SQL strings beyond the 32767-byte VARCHAR limit) travel as
    // temporary-LOB locators, created here via LOB operations on this same
    // connection before the execute.
    final List<Object?>? effectiveBinds;
    List<List<Object?>>? effectiveBulkRows = bulkRows;
    if (bindValues == null) {
      effectiveBinds = null;
    } else {
      try {
        effectiveBinds = await _prepareLobBinds(
          bindValues,
          isPlSql: isPlSql,
          timeout: timeout,
        );
        // executeMany rows carry the per-iteration values; CLOB/BLOB-typed
        // slots need each row's String / Uint8List converted to a
        // temporary-LOB locator, exactly like the scalar bind path above.
        effectiveBulkRows = await _prepareBulkRowLobs(
          bindValues,
          bulkRows,
          timeout,
        );
      } catch (_) {
        // Bind preparation failed after we drained the previous call's
        // temp-LOB free list (above). Without this restore, those server-side
        // temp LOBs would be orphaned: this execute never sends its
        // free-temp piggyback, and the next one drains an empty list. Put the
        // drained locators back so the next execute frees them. (Temp LOBs
        // already created by THIS call queued themselves in the create
        // helpers' finally blocks, so they ride the same restored list.)
        // Restore the drained locators AND their content keys together. Any
        // locator this failed call already queued in a create helper's `finally`
        // is on the list (and in the key set) too; `addAll` is idempotent, so a
        // restored locator that is somehow already keyed stays single-entry.
        _tempLobsToClose.insertAll(0, lobsToFree);
        _tempLobsTotalSize += lobsToFreeSize;
        _tempLobKeysToClose.addAll(lobsToFree.map(_tempLobKey));
        rethrow;
      }
    }

    // PL/SQL executeMany runs as TWO RPCs, mirroring node-oracledb thin
    // (connection.js _execute): a full EXECUTE with numExecs = 1 — one
    // iteration only, letting the server determine the block's actual bind
    // directions — followed by a REEXECUTE (function 4) that runs the
    // remaining iterations against the now-open cursor (see
    // _reExecutePlSqlBatch). Sending numExecs = N with OUT binds on the first
    // parse draws ORA-03106 (live-verified against 23ai). Array DML keeps its
    // single-RPC shape.
    final request = ExecuteRequest(
      sql: sql,
      bindValues: effectiveBinds,
      bindNames: bindNames,
      isQuery: isQuery,
      isPlSql: isPlSql,
      numIters: prefetchRows,
      ttcFieldVersion: _ttcFieldVersion,
      sequence: nextSequence(),
      cursorId: cursorId,
      bulkRows: plSqlExecuteMany && effectiveBulkRows != null
          ? [effectiveBulkRows[0]]
          : effectiveBulkRows,
      executeManyIters: plSqlExecuteMany ? 1 : executeManyIters,
      // Keep the cursor alive for the follow-up REEXECUTE iterations.
      noImplicitRelease: plSqlExecuteMany && executeManyIters > 1,
      // Array-DML row-level reporting (DML-only; rejected for PL/SQL before the
      // wire, so these are always false on the PL/SQL two-RPC path above).
      batchErrors: batchErrors,
      dmlRowCounts: dmlRowCounts,
      // DML RETURNING: permit the OUT / IN OUT return binds on this non-PL/SQL
      // statement and omit them from the per-iteration row data. Single-RPC,
      // numExecs = N (no REEXECUTE split).
      dmlReturning: dmlReturning,
    );

    // Prepend piggybacks: close-cursor (LRU evictions) and free-temp-LOBs
    // (temp CLOBs bound by a previous execute).
    final executeData = request.toBytes();
    final piggybacks = <Uint8List>[
      if (lobsToFree.isNotEmpty)
        _buildFreeTempLobsPiggyback(lobsToFree, lobsToFreeSize),
      if (cursorsToClose.isNotEmpty) _buildCloseCursorPiggyback(cursorsToClose),
    ];
    final Uint8List requestData;
    if (piggybacks.isEmpty) {
      requestData = executeData;
    } else {
      final builder = BytesBuilder(copy: false);
      for (final p in piggybacks) {
        builder.add(p);
      }
      builder.add(executeData);
      requestData = builder.toBytes();
    }

    await sendData(requestData);
    final payload = await _receiveDataWithTimeout(
      timeout,
      expectedColumns: expectedColumns,
      bindMetadata: bindMetadata,
      plSqlExecuteMany: plSqlExecuteMany,
      dmlReturning: dmlReturning,
      dmlRowCounts: dmlRowCounts,
      presetOutBindIndices: returningOutBindIndices,
    );

    var response = decodeExecuteResponse(
      payload,
      isQuery: isQuery,
      ttcFieldVersion: _ttcFieldVersion,
      endOfRequestSupport: _supportsEndOfRequest,
      expectedColumns: expectedColumns,
      bindMetadata: bindMetadata,
      preserveTimestampTimeZone: preserveTimestampTimeZone,
      supportsNationalCharset: supportsNationalCharset,
      nationalCharset: nationalCharset,
      plSqlExecuteMany: plSqlExecuteMany,
      dmlReturning: dmlReturning,
      dmlRowCounts: dmlRowCounts,
      presetOutBindIndices: returningOutBindIndices,
    );

    // DML RETURNING error path: the server ended the execute response with a
    // FLUSH_OUT_BINDS marker and now expects a matching flush request before
    // it will accept the next RPC. The DML outcome — a statement error
    // (ORA-00001, first-error mode) OR the row-level batch errors
    // (batchErrors: true) — travels in the FLUSH response, while the
    // per-iteration returning OUT rows (for the rows that DID apply) are in the
    // execute response above. Send the flush here (inside the concurrency
    // guard, keeping the connection usable) and MERGE the two so neither the
    // returned values nor the error signal is lost.
    if (response.flushOutBinds) {
      final flushResponse = await _flushOutBinds(
        timeout,
        dmlRowCounts: dmlRowCounts,
      );
      response = ExecuteResponse(
        isSuccess: flushResponse.isSuccess,
        cursorId: flushResponse.cursorId != 0
            ? flushResponse.cursorId
            : response.cursorId,
        outBindIndices: response.outBindIndices,
        outBindRows: response.outBindRows,
        rowsAffected: flushResponse.rowsAffected ?? response.rowsAffected,
        batchErrors: flushResponse.batchErrors,
        dmlRowCounts: flushResponse.dmlRowCounts.isNotEmpty
            ? flushResponse.dmlRowCounts
            : response.dmlRowCounts,
        errorCode: flushResponse.errorCode,
        errorMessage: flushResponse.errorMessage,
        errorOffset: flushResponse.errorOffset,
      );
    }

    // PL/SQL executeMany, second RPC: run iterations 2..N via REEXECUTE
    // against the cursor the first execution opened, then merge the
    // per-iteration OUT rows. A failed first iteration skips this — its
    // error propagates through the normal path below.
    if (plSqlExecuteMany && executeManyIters > 1 && response.isSuccess) {
      return _reExecutePlSqlBatch(
        firstResponse: response,
        binds: effectiveBinds,
        rows: effectiveBulkRows,
        numIters: executeManyIters,
        bindMetadata: bindMetadata,
        preserveTimestampTimeZone: preserveTimestampTimeZone,
        timeout: timeout,
      );
    }

    // sendExecute returns only the FIRST batch. The FETCH drain loop (and its
    // safety cap) now lives in the lazy cursor engine
    // (lib/src/protocol/result_set_cursor.dart) so eager execute() and
    // OracleResultSet share one fetch path. Row-LOB and OUT-bind locators are
    // NOT materialized here: the caller materializes via [materializeLobs] so
    // eager execute() can accumulate raw locator rows across batches and
    // materialize once (result-wide dedup), while OracleResultSet materializes
    // per batch as rows are consumed.
    //
    // The server may echo cursorId == 0 on a cached-cursor re-execute while the
    // original cursor stays open, so the usable fetch cursor falls back to the
    // request's own id. The returned response carries that effective id when
    // more rows remain, so the caller's fetch loop can continue.
    final effectiveCursorId = response.cursorId != 0
        ? response.cursorId
        : cursorId;
    if (isQuery &&
        response.isSuccess &&
        effectiveCursorId != 0 &&
        response.moreRowsToFetch) {
      // Use column metadata from this response (populated from DESCRIBE or
      // expectedColumns) so fetch rounds can decode rows without DESCRIBE.
      final fetchColumns = response.columnMetadata.isNotEmpty
          ? response.columnMetadata
          : expectedColumns;
      // For locator-LOB (CLOB/BLOB) and native JSON queries the server defers
      // row delivery — the first execute returns DESCRIBE only (zero rows). A
      // DEFINE call (defines carrying the LOB-prefetch cont-flag) re-executes
      // the cursor and returns the first row batch in the prefetch shape;
      // subsequent FETCH rounds keep that shape. Without it, FETCH rounds ship
      // bare locators / bare JSON values (no length/chunk prefix) that cannot
      // be decoded — validated live on 23ai: a JSON FETCH round without defines
      // misaligns the stream. Mirrors node-oracledb `_handleDefines` and its
      // `requiresDefine = true` for CLOB/BLOB/JSON query columns.
      if (fetchColumns != null &&
          response.rows.isEmpty &&
          fetchColumns.any(
            (c) =>
                c.oracleType == oraTypeClob ||
                c.oracleType == oraTypeBlob ||
                c.oracleType == oraTypeJson,
          )) {
        final defineResponse = await _sendLobDefines(
          sql,
          effectiveCursorId,
          fetchColumns,
          prefetchRows,
          timeout,
        );
        return ExecuteResponse(
          isSuccess: true,
          cursorId: effectiveCursorId,
          columnMetadata: response.columnMetadata,
          rows: defineResponse.rows,
          outBindValues: response.outBindValues,
          outBindIndices: response.outBindIndices,
          rowsAffected: response.rowsAffected,
          moreRowsToFetch: defineResponse.moreRowsToFetch,
        );
      }
      // Normalize the cursor id to [effectiveCursorId] so the caller's fetch
      // loop can continue even when the server echoed 0.
      return ExecuteResponse(
        isSuccess: true,
        cursorId: effectiveCursorId,
        columnMetadata: response.columnMetadata,
        rows: response.rows,
        outBindValues: response.outBindValues,
        outBindIndices: response.outBindIndices,
        rowsAffected: response.rowsAffected,
        moreRowsToFetch: response.moreRowsToFetch,
      );
    }

    if (isQuery &&
        response.isSuccess &&
        effectiveCursorId == 0 &&
        response.moreRowsToFetch) {
      // The server signalled more rows pending, but neither the response nor
      // the request carries a usable cursor id, so the fetch loop cannot run.
      _log.warning(
        'Server reports more rows pending but no usable cursor id '
        'is available to continue fetching; result is reported incomplete '
        '(moreRowsToFetch=true)',
      );
    }

    // Single-batch / non-query / no-usable-cursor: return the first response
    // unchanged (raw, not materialized). The caller materializes via
    // [materializeLobs].
    return response;
  }

  /// Runs iterations 2..N of a PL/SQL executeMany via a TTC REEXECUTE and
  /// merges the per-iteration OUT rows with the first execution's.
  ///
  /// node-oracledb parity (thin/connection.js `_execute`, execute.js
  /// `writeReExecuteMessage`): the REEXECUTE rows carry values for the
  /// **non-OUT** binds only, and its response ships the remaining OUT
  /// ROW_DATA payloads **without** a fresh IO_VECTOR — the OUT bind order is
  /// seeded from the first response. The merged response reports the first
  /// execution's cursor id and the full N-row [ExecuteResponse.outBindRows].
  Future<ExecuteResponse> _reExecutePlSqlBatch({
    required ExecuteResponse firstResponse,
    required List<Object?>? binds,
    required List<List<Object?>>? rows,
    required int numIters,
    required List<BindMetadata>? bindMetadata,
    required bool preserveTimestampTimeZone,
    required Duration? timeout,
  }) async {
    final reExecCursorId = firstResponse.cursorId;
    if (reExecCursorId == 0) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message:
            'PL/SQL executeMany: the first execution returned no usable '
            'server cursor (cursor id = 0), so the remaining iterations '
            'cannot be re-executed',
      );
    }

    // Exclude OUT-only slots entirely from the re-execute rows; IN and
    // IN OUT slots keep their per-iteration values. The first execution's
    // IO_VECTOR check already enforced server directions match the declared
    // ones, so the client-declared direction is authoritative here.
    List<Object?>? reBinds;
    List<List<Object?>>? reRows;
    if (binds != null && rows != null) {
      final inSlots = <int>[
        for (var i = 0; i < binds.length; i++)
          if (!(binds[i] is BindVariable &&
              (binds[i]! as BindVariable).dir == BindDir.output))
            i,
      ];
      if (inSlots.isNotEmpty) {
        reBinds = [for (final i in inSlots) binds[i]];
        reRows = [
          for (var r = 1; r < rows.length; r++)
            [for (final i in inSlots) rows[r][i]],
        ];
      }
    }

    final request = ReExecuteRequest(
      cursorId: reExecCursorId,
      numIters: numIters - 1,
      bindValues: reBinds,
      bulkRows: reRows,
      ttcFieldVersion: _ttcFieldVersion,
      sequence: nextSequence(),
    );
    await sendData(request.toBytes());
    final payload = await _receiveDataWithTimeout(
      timeout,
      bindMetadata: bindMetadata,
      plSqlExecuteMany: true,
      presetOutBindIndices: firstResponse.outBindIndices,
    );
    final response = decodeExecuteResponse(
      payload,
      isQuery: false,
      ttcFieldVersion: _ttcFieldVersion,
      endOfRequestSupport: _supportsEndOfRequest,
      bindMetadata: bindMetadata,
      preserveTimestampTimeZone: preserveTimestampTimeZone,
      supportsNationalCharset: supportsNationalCharset,
      nationalCharset: nationalCharset,
      plSqlExecuteMany: true,
      presetOutBindIndices: firstResponse.outBindIndices,
    );

    // A failed iteration surfaces the server error exactly like the
    // single-RPC path; iterations that already ran remain pending in the
    // transaction (Oracle array semantics without batchErrors).
    if (!response.isSuccess) return response;

    return ExecuteResponse(
      isSuccess: true,
      cursorId: reExecCursorId,
      outBindIndices: firstResponse.outBindIndices,
      outBindRows: [...firstResponse.outBindRows, ...response.outBindRows],
      implicitResults: [
        ...firstResponse.implicitResults,
        ...response.implicitResults,
      ],
    );
  }

  /// Fetches one more batch of rows from an open server cursor and returns the
  /// decoded response (raw — locators are NOT materialized; the caller uses
  /// [materializeLobs]).
  ///
  /// This is the single-batch FETCH primitive the lazy cursor engine
  /// (`ResultSetCursor`) drives for both eager `execute()` drains and
  /// `OracleResultSet` row consumption, so the two share one fetch path.
  /// [previousRoundLastRow] supplies the duplicate-column dedup source for the
  /// first row of this round (Oracle may encode it as a copy of the prior
  /// round's last row).
  @internal
  Future<ExecuteResponse> fetchRows(
    int cursorId,
    int numRows, {
    List<ColumnMetadata>? columns,
    Duration? timeout = const Duration(minutes: 2),
    bool preserveTimestampTimeZone = false,
    List<Object?>? previousRoundLastRow,
  }) {
    return _sendFetch(
      cursorId,
      numRows,
      timeout,
      expectedColumns: columns,
      preserveTimestampTimeZone: preserveTimestampTimeZone,
      previousRoundLastRow: previousRoundLastRow,
    );
  }

  /// Materializes any CLOB/BLOB locators in [response]'s rows and OUT binds
  /// into Strings / byte buffers via TTC LOB READ round trips, returning a new
  /// response with the materialized values (or the same response when there is
  /// nothing to read).
  ///
  /// Exposed so the connection layer can materialize a fully-drained eager
  /// result in one pass (result-wide locator dedup) and `ResultSetCursor` can
  /// materialize per batch as rows are consumed. Sends no traffic for a
  /// locator-free or unsuccessful response.
  ///
  /// When [wrapLob] is supplied (the `OracleExecuteOptions(fetchLobs: true)`
  /// path, Story 12.1) each [LobLocator] is passed to it and replaced by whatever
  /// it returns — a connection-owned `OracleLob` handle — instead of being read
  /// into a `String` / `Uint8List`. No LOB READ round trip is issued in that
  /// case (the handle reads lazily), and the OUT-bind `maxSize` guard is skipped
  /// (a handle materializes nothing, so no return-buffer bound applies). The
  /// callback is threaded through EVERY shape below (rows, OUT-bind values,
  /// OUT-bind rows, DML RETURNING nesting) so a LOB is never materialized on one
  /// shape while handle-wrapped on another.
  @internal
  Future<ExecuteResponse> materializeLobs(
    ExecuteResponse response, {
    List<BindMetadata>? bindMetadata,
    bool dmlReturning = false,
    Duration? timeout = const Duration(minutes: 2),
    Object Function(LobLocator locator)? wrapLob,
  }) {
    return _materializeLobValues(
      response,
      bindMetadata: bindMetadata,
      dmlReturning: dmlReturning,
      timeout: timeout,
      wrapLob: wrapLob,
    );
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

  /// Builds a free-temporary-LOBs piggyback, byte-for-byte after
  /// node-oracledb `writeCloseTempLobsPiggyback` (base.js): a piggybacked
  /// `TNS_FUNC_LOB_OP` with operation `FREE_TEMP | ARRAY` followed by the raw
  /// locator bytes. Like close-cursor, it only ever rides another message —
  /// there is no standalone free-temp round trip.
  Uint8List _buildFreeTempLobsPiggyback(
    List<Uint8List> locators,
    int totalSize,
  ) {
    final buf = WriteBuffer();
    buf.writeUint8(ttcMsgTypePiggyback);
    buf.writeUint8(ttcLobOp);
    buf.writeUint8(nextSequence() & 0xFF);
    if (_ttcFieldVersion >= ttcCcapFieldVersion23_1Ext1) {
      buf.writeUB8(0); // token number
    }
    buf.writeUint8(1); // pointer
    buf.writeUB4(totalSize); // combined byte size of all locators
    buf.writeUint8(0); // dest LOB locator
    buf.writeUB4(0);
    buf.writeUB4(0); // source LOB locator
    buf.writeUB4(0);
    buf.writeUint8(0); // source LOB offset
    buf.writeUint8(0); // dest LOB offset
    buf.writeUint8(0); // charset
    buf.writeUB4(tnsLobOpFreeTemp | tnsLobOpArray);
    buf.writeUint8(0); // SCN
    buf.writeUB4(0); // LOB scn
    buf.writeUB8(0); // LOB scnl
    buf.writeUB8(0);
    buf.writeUint8(0);
    // array LOB fields
    buf.writeUint8(0);
    buf.writeUB4(0);
    buf.writeUint8(0);
    buf.writeUB4(0);
    buf.writeUint8(0);
    buf.writeUB4(0);
    for (final locator in locators) {
      buf.writeBytes(locator);
    }
    return buf.toBytes();
  }

  /// Sends one TTC LOB operation and decodes its response.
  ///
  /// Used internally by [sendExecute] for temp-CLOB creation/writes and for
  /// materializing CLOB locators into Strings, and by the connection's
  /// `OracleLob` read/write seam (`runLobRead` / `runLobWrite`, Story 12.1).
  /// Every caller brackets the round trip through the connection's in-flight
  /// guard (the eager-execute flag or the `_runLobOp` bracket), so a LOB
  /// operation never interleaves with another statement on the same connection.
  ///
  /// Throws [OracleException] when the server reports an error.
  Future<LobOpResponse> sendLobOp({
    required int operation,
    Uint8List? sourceLocator,
    int sourceOffset = 0,
    int destOffset = 0,
    int destLength = 0,
    bool sendAmount = false,
    int amount = 0,
    Uint8List? data,
    Duration? timeout = const Duration(minutes: 2),
  }) async {
    final request = LobOpRequest(
      operation: operation,
      sourceLocator: sourceLocator,
      sourceOffset: sourceOffset,
      destOffset: destOffset,
      destLength: destLength,
      sendAmount: sendAmount,
      amount: amount,
      data: data,
      ttcFieldVersion: _ttcFieldVersion,
      sequence: nextSequence(),
    );
    await sendData(request.toBytes());
    if (operation == tnsLobOpRead) {
      _lobReadOps++;
    }
    final sourceLocatorLength = sourceLocator?.length ?? 0;
    final payload = await _receiveDataWithTimeout(
      timeout,
      operation: 'LOB operation',
      // LOB responses carry LOB_DATA / RETURN_PARAMETER shapes the EXECUTE
      // completion probe cannot walk — substitute the LOB-aware probe.
      completionProbe: (accumulated) => lobOpStreamIsComplete(
        accumulated,
        operation: operation,
        sourceLocatorLength: sourceLocatorLength,
        sendAmount: sendAmount,
        ttcFieldVersion: _ttcFieldVersion,
        endOfRequestSupport: _supportsEndOfRequest,
      ),
    );
    final response = decodeLobOpResponse(
      payload,
      operation: operation,
      sourceLocatorLength: sourceLocatorLength,
      sendAmount: sendAmount,
      ttcFieldVersion: _ttcFieldVersion,
      endOfRequestSupport: _supportsEndOfRequest,
    );
    if (!response.isSuccess) {
      throw OracleException(
        errorCode: response.errorCode ?? oraProtocolError,
        message: response.errorMessage ?? 'LOB operation failed',
      );
    }
    return response;
  }

  /// Converts LOB-destined bind values into temporary-LOB locators before
  /// the execute is encoded.
  ///
  /// Three conversions, all node-oracledb parity (connection.js `_bind`):
  /// * any CLOB-typed [BindVariable] holding a `String` — the declared
  ///   `OracleDbType.clob` path; the empty string binds as SQL NULL,
  ///   consistent with Oracle's `'' IS NULL` semantics;
  /// * any BLOB-typed [BindVariable] holding a `Uint8List` — the declared
  ///   `OracleDbType.blob` path; the empty byte list travels through an
  ///   internal empty temporary BLOB (no WRITE), preserving the BLOB
  ///   empty-vs-NULL distinction;
  /// * plain PL/SQL IN strings whose UTF-8 size exceeds the 32767-byte
  ///   VARCHAR bind limit. (SQL DML keeps oversized strings VARCHAR-typed
  ///   and relies on the deferred long-data write ordering instead.)
  ///
  /// Returns the original list unchanged when no bind needs conversion.
  Future<List<Object?>> _prepareLobBinds(
    List<Object?> binds, {
    required bool isPlSql,
    Duration? timeout,
  }) async {
    List<Object?>? converted;
    for (var i = 0; i < binds.length; i++) {
      final raw = binds[i];
      BindVariable? replacement;
      if (raw is BindVariable &&
          raw.oraType == oraTypeClob &&
          raw.value is String) {
        final value = raw.value as String;
        // NCLOB (isNChar) creates an NCHAR-charset temp LOB so the value is
        // stored as UTF-16BE; plain CLOB stays UTF-8 (ttcCsfrmImplicit).
        final csfrm = raw.isNChar ? ttcCsfrmNChar : ttcCsfrmImplicit;
        replacement = BindVariable(
          value: value.isEmpty
              ? null
              : await _createTempClob(value, timeout, csfrm: csfrm),
          oraType: oraTypeClob,
          maxSize: raw.maxSize,
          dir: raw.dir,
          isNChar: raw.isNChar,
        );
      } else if (raw is BindVariable &&
          raw.oraType == oraTypeBlob &&
          raw.value is Uint8List) {
        replacement = BindVariable(
          value: await _createTempBlob(raw.value as Uint8List, timeout),
          oraType: oraTypeBlob,
          maxSize: raw.maxSize,
          dir: raw.dir,
        );
      } else if (isPlSql) {
        final String? value = raw is String
            ? raw
            : (raw is BindVariable &&
                      raw.dir == BindDir.input &&
                      raw.oraType == oraTypeVarchar &&
                      raw.value is String
                  ? raw.value as String
                  : null);
        if (value != null &&
            utf8.encode(value).length > ttcMaxVarcharBindBytes) {
          replacement = BindVariable(
            value: await _createTempClob(value, timeout),
            oraType: oraTypeClob,
            dir: BindDir.input,
          );
        } else {
          // Plain PL/SQL IN byte values beyond the 32767-byte RAW bind
          // limit travel as temporary BLOBs — node-oracledb retypes PL/SQL
          // RAW binds with maxSize > 32767 to DB_TYPE_BLOB the same way
          // (connection.js `_bind`). SQL DML keeps oversized Uint8List
          // values RAW-typed and relies on the deferred long-data write
          // ordering instead.
          final Uint8List? bytes = raw is Uint8List
              ? raw
              : (raw is BindVariable &&
                        raw.dir == BindDir.input &&
                        raw.oraType == oraTypeRaw &&
                        raw.value is Uint8List
                    ? raw.value as Uint8List
                    : null);
          if (bytes != null && bytes.length > ttcMaxRawBindBytes) {
            replacement = BindVariable(
              value: await _createTempBlob(bytes, timeout),
              oraType: oraTypeBlob,
              dir: BindDir.input,
            );
          }
        }
      }
      if (replacement != null) {
        converted ??= List<Object?>.of(binds);
        converted[i] = replacement;
      }
    }
    return converted ?? binds;
  }

  /// Converts LOB-destined per-iteration values in executeMany [bulkRows]
  /// into temporary-LOB locators, mirroring [_prepareLobBinds] for the
  /// scalar bind list.
  ///
  /// [binds] are the executeMany slot templates ([BindVariable]s whose
  /// values are null); [bulkRows] carry the actual per-iteration values. For
  /// every CLOB-typed slot, each row's `String` becomes a temporary CLOB
  /// (empty string → SQL NULL, the CLOB convention; NCLOB slots create
  /// NCHAR-form temp LOBs); for every BLOB-typed slot, each row's `Uint8List`
  /// becomes a temporary BLOB (empty bytes → empty BLOB, preserving the
  /// empty-vs-NULL distinction). Rows are copied, never mutated in place.
  /// Returns [bulkRows] unchanged when no slot is LOB-typed.
  Future<List<List<Object?>>?> _prepareBulkRowLobs(
    List<Object?> binds,
    List<List<Object?>>? bulkRows,
    Duration? timeout,
  ) async {
    if (bulkRows == null) return null;
    List<int>? lobSlots;
    for (var i = 0; i < binds.length; i++) {
      final b = binds[i];
      if (b is BindVariable &&
          (b.oraType == oraTypeClob || b.oraType == oraTypeBlob)) {
        (lobSlots ??= <int>[]).add(i);
      }
    }
    if (lobSlots == null) return bulkRows;
    final newRows = <List<Object?>>[];
    for (final row in bulkRows) {
      final newRow = List<Object?>.of(row);
      for (final i in lobSlots) {
        final bind = binds[i] as BindVariable;
        final value = newRow[i];
        if (bind.oraType == oraTypeClob && value is String) {
          newRow[i] = value.isEmpty
              ? null
              : await _createTempClob(
                  value,
                  timeout,
                  csfrm: bind.isNChar ? ttcCsfrmNChar : ttcCsfrmImplicit,
                );
        } else if (bind.oraType == oraTypeBlob && value is Uint8List) {
          newRow[i] = await _createTempBlob(value, timeout);
        }
      }
      newRows.add(newRow);
    }
    return newRows;
  }

  /// Creates a temporary CLOB on the server and writes [value] into it.
  ///
  /// Mirrors node-oracledb `lob.js create()` + `write()`: CREATE_TEMP carries
  /// the charset form in the source offset, the Oracle type in the dest
  /// offset, and the session duration in the dest length; the WRITE then
  /// ships the UTF-8 bytes at 1-based offset 1. The locator is queued for the
  /// free-temp piggyback on the NEXT execute even if the write fails, so a
  /// failed bind cannot leak the server-side temp LOB past the next RPC.
  Future<LobLocator> _createTempClob(
    String value,
    Duration? timeout, {
    int csfrm = ttcCsfrmImplicit,
  }) async {
    // The charset form rides the CREATE_TEMP source offset: ttcCsfrmImplicit
    // makes a CLOB (UTF-8 storage), ttcCsfrmNChar makes an NCLOB (UTF-16BE
    // storage). The WRITE below encodes the value per the same [csfrm].
    final created = await sendLobOp(
      operation: tnsLobOpCreateTemp,
      sourceLocator: Uint8List(tnsLobLocatorBufferSize),
      sourceOffset: csfrm,
      destOffset: oraTypeClob,
      destLength: tnsDurationSession,
      timeout: timeout,
    );
    final locator = created.updatedLocator;
    if (locator == null) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message: 'Temporary CLOB creation returned no locator',
      );
    }
    try {
      // The write encoding follows node-oracledb lobOp.js getCsfrm(): an NCLOB
      // (declared NCHAR form) takes UTF-16BE outright, and a plain CLOB takes
      // UTF-16BE only when the server marked its locator variable-length
      // charset; everything else is UTF-8. The server does not reliably set the
      // flag bit on a freshly created NCLOB locator, so the known NCHAR form is
      // the authoritative signal here.
      final probe = LobLocator(
        locator: locator,
        oracleType: oraTypeClob,
        length: 0,
        chunkSize: 0,
        isNChar: csfrm == ttcCsfrmNChar,
      );
      final data = (probe.isNChar || probe.usesVarLengthCharset)
          ? encodeUtf16Be(value)
          : Uint8List.fromList(utf8.encode(value));
      final written = await sendLobOp(
        operation: tnsLobOpWrite,
        sourceLocator: locator,
        sourceOffset: 1, // LOB offsets are 1-based
        data: data,
        timeout: timeout,
      );
      // The server may update the locator state on write; keep a single
      // buffer whose contents track the latest server echo (node-oracledb
      // copies the returned bytes into the same `_locator` buffer).
      final updated = written.updatedLocator;
      if (updated != null && updated.length == locator.length) {
        locator.setRange(0, locator.length, updated);
      }
    } finally {
      // Same two-line accounting as queueTempLobToFree (single writer of the
      // free list + its UB4 total size).
      queueTempLobToFree(locator);
    }
    return LobLocator(
      locator: locator,
      oracleType: oraTypeClob,
      length: value.length,
      chunkSize: 0,
      isNChar: csfrm == ttcCsfrmNChar,
    );
  }

  /// Creates a temporary BLOB on the server and writes [value] into it.
  ///
  /// Mirrors node-oracledb `lob.js create()` + `write()` for
  /// `DB_TYPE_BLOB`: CREATE_TEMP carries the charset form (0 for BLOB — no
  /// character set) in the source offset, the Oracle type in the dest
  /// offset, and the session duration in the dest length; the WRITE then
  /// ships the raw bytes unchanged at 1-based offset 1 (lobOp.js passes
  /// BLOB data through with no transcoding). An empty [value] skips the
  /// WRITE entirely, leaving an empty temporary BLOB — node-oracledb binds
  /// empty buffers as NULL, but this driver preserves the BLOB
  /// empty-vs-NULL distinction (validated by integration tests on 23ai and
  /// 21c). The locator is queued for the free-temp piggyback on the NEXT
  /// execute even if the write fails, so a failed bind cannot leak the
  /// server-side temp LOB past the next RPC.
  Future<LobLocator> _createTempBlob(Uint8List value, Duration? timeout) async {
    final created = await sendLobOp(
      operation: tnsLobOpCreateTemp,
      sourceLocator: Uint8List(tnsLobLocatorBufferSize),
      sourceOffset: 0, // BLOB has no charset form (node-oracledb dbType._csfrm)
      destOffset: oraTypeBlob,
      destLength: tnsDurationSession,
      timeout: timeout,
    );
    final locator = created.updatedLocator;
    if (locator == null) {
      throw const OracleException(
        errorCode: oraProtocolError,
        message: 'Temporary BLOB creation returned no locator',
      );
    }
    try {
      if (value.isNotEmpty) {
        final written = await sendLobOp(
          operation: tnsLobOpWrite,
          sourceLocator: locator,
          sourceOffset: 1, // LOB offsets are 1-based (bytes for BLOB)
          data: value,
          timeout: timeout,
        );
        final updated = written.updatedLocator;
        if (updated != null && updated.length == locator.length) {
          locator.setRange(0, locator.length, updated);
        }
      }
    } finally {
      // Same two-line accounting as queueTempLobToFree (single writer of the
      // free list + its UB4 total size).
      queueTempLobToFree(locator);
    }
    return LobLocator(
      locator: locator,
      oracleType: oraTypeBlob,
      length: value.length,
      chunkSize: 0,
    );
  }

  /// Resolves the declared `maxSize` for the LOB OUT-bind value at
  /// [valueIndex] from the decoder-side bind metadata.
  ///
  /// [outBindIndices] maps each OUT value position to its original bind
  /// slot, so the value's metadata lives at
  /// `bindMetadata[outBindIndices[valueIndex]]`. A misalignment between the
  /// two — an indices list shorter than the OUT values, or an index outside
  /// the declared metadata — means the decoded response no longer matches
  /// what was sent: fail loud rather than silently skipping the maxSize
  /// guard. Returns null only when no bind metadata was supplied at all
  /// (no guard is possible) or when the resolved bind declares no maxSize.
  @visibleForTesting
  static int? resolveOutBindMaxSize({
    required int valueIndex,
    required List<int> outBindIndices,
    required List<BindMetadata>? bindMetadata,
  }) {
    if (bindMetadata == null) return null;
    if (valueIndex >= outBindIndices.length) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'OUT bind index misalignment: OUT value $valueIndex has no '
            'entry in outBindIndices (${outBindIndices.length} entries) — '
            'cannot apply the OUT-bind maxSize guard',
      );
    }
    final bindIdx = outBindIndices[valueIndex];
    if (bindIdx < 0 || bindIdx >= bindMetadata.length) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'OUT bind index misalignment: outBindIndices[$valueIndex] '
            'is $bindIdx but only ${bindMetadata.length} bind metadata '
            'entries were declared — cannot apply the OUT-bind maxSize guard',
      );
    }
    return bindMetadata[bindIdx].maxSize;
  }

  /// Fail-loud guard for a completed BLOB range read: the locator's prefetch
  /// metadata reports the exact byte length, so a mismatch means the value
  /// cannot be returned whole — never truncate or pad.
  ///
  /// Since Story 12.3 the read behind this guard is a **chunked continuation
  /// loop** ([readLobRange]), so size alone no longer explains a short result:
  /// a value larger than one round trip is read across as many READs as it
  /// takes. A mismatch here therefore means the LOB really delivered fewer
  /// bytes than its locator advertised — most often a locator whose cached
  /// prefetch length went stale (the LOB shrank in another session between the
  /// fetch and the read), or a corrupt stream.
  @visibleForTesting
  static void verifyBlobReadLength(int received, int locatorLength) {
    if (received == locatorLength) return;
    throw OracleException(
      errorCode: oraProtocolError,
      message:
          'BLOB read returned $received bytes but the locator reports '
          '$locatorLength${received < locatorLength ? ' — the LOB delivered '
                    'fewer bytes than its locator advertises (the value may '
                    'have shrunk since it was fetched)' : ''}',
    );
  }

  /// Copies the server's echoed (post-op) locator bytes back into [source] in
  /// place, guarded on an equal length.
  ///
  /// node-oracledb's `lobOp.processReturnParameter` copies the returned locator
  /// into `sourceLobImpl._locator` after EVERY LOB op, so a follow-on op
  /// references post-op state rather than stale bytes. Single implementation
  /// shared by [readLobRange], `createTemporaryLob` and the connection's
  /// read/write seams. A differently-sized echo is ignored (never truncates or
  /// grows the live locator).
  @internal
  static void copyBackLocator(Uint8List source, Uint8List? updated) {
    if (updated != null && updated.length == source.length) {
      source.setRange(0, source.length, updated);
    }
  }

  /// Reads [amount] units starting at 1-based [offset] from the LOB [locator]
  /// references, issuing **as many** `tnsLobOpRead` round trips as it takes,
  /// and returns the concatenated payload bytes plus the total units the server
  /// reported delivering.
  ///
  /// This is the driver's single LOB read-continuation loop (Story 12.3 AC1):
  /// `_readClobAsString`, `_readBlobAsBytes` and the connection's `runLobRead`
  /// seam (behind `OracleLob.read()`) all route through it, so the "keep reading
  /// at the advanced offset" logic exists in exactly one place.
  ///
  /// * **Units, not bytes.** [offset] and [amount] are in the LOB's native
  ///   units — characters (UCS-2 code units) for CLOB/NCLOB, bytes for BLOB —
  ///   while the returned buffer is always BYTES. Per-piece progress is taken
  ///   from the server's own SB8 reply (`LobOpResponse.amount`, decoded for
  ///   every `sendAmount: true` READ), never inferred from byte counts: a
  ///   CLOB has no fixed bytes-per-unit ratio.
  /// * **Single-READ fast path.** With [pieceUnits] null the first READ requests
  ///   the whole [amount], so a value that fits one round trip (measured: every
  ///   size up to 32 MB on 23ai and 8 MB on 21c) costs exactly **one**
  ///   `tnsLobOpRead` — byte-for-byte the pre-12.3 behavior. The loop only
  ///   engages if a server actually short-reads.
  /// * **Assemble bytes, decode once.** Pieces are concatenated as bytes and
  ///   handed back undecoded, because a piece boundary can split a UTF-8
  ///   sequence or a UTF-16 surrogate pair — which a per-piece decode cannot
  ///   reassemble but a single decode over the assembled buffer always can.
  /// * **Bounded and fail-loud.** A piece the server reports as **zero units**
  ///   while units are still outstanding cannot make progress, so it throws
  ///   [OracleException] naming the offset/amount rather than spinning. The one
  ///   exception is a first piece that delivers nothing at all — no reported
  ///   units AND no payload bytes: that returns an empty result so the caller's
  ///   own "read returned no data" guard produces its established message. A
  ///   piece reporting MORE units than that piece REQUESTED is likewise a
  ///   protocol fault.
  /// * **The two halves of a reply are cross-checked.** The unit count comes from
  ///   `RETURN_PARAMETER` and the payload from separate `LOB_DATA` messages, so
  ///   an internally inconsistent reply is possible in principle: a piece that
  ///   ships bytes while reporting 0 units fails loud naming the inconsistency,
  ///   rather than being mistaken for "the LOB delivered nothing" and silently
  ///   discarding the prefix.
  /// * **Missing SB8 amount.** If a READ reply omits the amount (never observed
  ///   for a `sendAmount: true` READ on either tested server version), the piece
  ///   is treated as having satisfied what THAT PIECE requested. With no piece
  ///   cap set — every production caller — a piece requests the whole
  ///   outstanding tail, so the read degrades to exactly the pre-12.3
  ///   single-round-trip behavior; with a cap in play the degrade is per piece
  ///   and the loop simply continues. Either way the caller's strict truncation
  ///   guard still catches a short payload. (Falling back to the whole
  ///   outstanding tail under a cap would itself exceed the piece's request and
  ///   trip the overshoot check below.)
  ///
  /// The server's echoed post-op locator is copied back after every piece
  /// ([copyBackLocator]), exactly as a single READ did.
  @internal
  Future<LobRangeRead> readLobRange({
    required Uint8List locator,
    required int offset,
    required int amount,
    int? pieceUnits,
    Duration? timeout = const Duration(minutes: 2),
  }) async {
    if (amount <= 0) return LobRangeRead(bytes: Uint8List(0), unitsRead: 0);
    // An explicit argument wins; otherwise the test-only cap applies (null in
    // production, which keeps the single-READ fast path byte-for-byte
    // unchanged). See [debugLobReadPieceUnits].
    final effectivePieceUnits = pieceUnits ?? _debugLobReadPieceUnits;
    final pieces = <Uint8List>[];
    var unitsRead = 0;
    var totalBytes = 0;
    while (unitsRead < amount) {
      final outstanding = amount - unitsRead;
      final request =
          effectivePieceUnits != null && effectivePieceUnits < outstanding
          ? effectivePieceUnits
          : outstanding;
      final response = await sendLobOp(
        operation: tnsLobOpRead,
        sourceLocator: locator,
        sourceOffset: offset + unitsRead,
        sendAmount: true,
        amount: request,
        timeout: timeout,
      );
      copyBackLocator(locator, response.updatedLocator);
      final data = response.data;
      if (data != null && data.isNotEmpty) {
        pieces.add(data);
        totalBytes += data.length;
      }
      // Progress in UNITS comes from the server's SB8 reply. A reply without one
      // is treated as having satisfied THIS PIECE's request (see the dartdoc),
      // which with no cap in play (`request == outstanding`, every production
      // caller) reduces this loop to the pre-12.3 single READ. Falling back to
      // `outstanding` instead would exceed `request` whenever a cap IS in play
      // and so trip the overshoot guard below — turning the documented degrade
      // into a hard error on exactly the seam that makes this loop testable.
      final delivered = response.amount ?? request;
      if (delivered <= 0) {
        if (unitsRead == 0 && totalBytes == 0) {
          // Nothing at all was delivered: hand back the empty result so the
          // caller's own "read returned no data" guard reports it.
          break;
        }
        // `amount` (RETURN_PARAMETER) and `data` (separate LOB_DATA messages)
        // are decoded from UNRELATED wire messages, so a reply can ship bytes
        // while reporting zero units. Without this cross-check the first such
        // piece took the break above and handed back an EMPTY result, silently
        // discarding the prefix and mis-diagnosing the fault as "read returned
        // no data".
        throw OracleException(
          errorCode: oraProtocolError,
          message: totalBytes > 0 && unitsRead == 0
              ? 'LOB read reply is internally inconsistent: the server '
                    'delivered $totalBytes payload bytes at offset $offset but '
                    'reported 0 units read (requested $request of $amount)'
              : 'LOB read made no progress: the server delivered 0 units at '
                    'offset ${offset + unitsRead} with ${amount - unitsRead} of '
                    '$amount units still outstanding (read started at offset '
                    '$offset)',
        );
      }
      // Compared against what THIS piece actually requested, not against the
      // whole outstanding tail: with a piece cap in play (`pieceUnits`, or the
      // test-only `debugLobReadPieceUnits`) `request < outstanding`, and the
      // looser comparison accepted an over-reporting server — which then
      // corrupts the next piece's `sourceOffset`. Identical in production, where
      // `pieceUnits` is null on every caller and `request == outstanding`.
      if (delivered > request) {
        throw OracleException(
          errorCode: oraProtocolError,
          message:
              'LOB read overshot: the server reported $delivered units at '
              'offset ${offset + unitsRead} but only $request were requested '
              '($outstanding of $amount outstanding)',
        );
      }
      unitsRead += delivered;
    }
    return LobRangeRead(
      bytes: _concatPieces(pieces, totalBytes),
      unitsRead: unitsRead,
    );
  }

  /// Concatenates [pieces] into one buffer, avoiding a copy in the (dominant)
  /// single-piece case.
  static Uint8List _concatPieces(List<Uint8List> pieces, int totalBytes) {
    if (pieces.isEmpty) return Uint8List(0);
    if (pieces.length == 1) return pieces.single;
    final out = Uint8List(totalBytes);
    var at = 0;
    for (final piece in pieces) {
      out.setRange(at, at + piece.length, piece);
      at += piece.length;
    }
    return out;
  }

  /// Replaces every [LobLocator] in a successful response's rows and OUT
  /// binds with its materialized value — `String` for CLOB, `Uint8List` for
  /// BLOB.
  ///
  /// Always runs AFTER the round trip that produced [response] has completed —
  /// never inside [sendExecute]. Every call site is in the connection layer or
  /// `ResultSetCursor` (the eager execute pass, the eager implicit-results pass,
  /// `_openResultSetGuarded`'s first batch, and a streaming cursor's per-batch
  /// FETCH), reached through the public [materializeLobs] seam. So all LOB reads
  /// still complete before the response escapes to the caller, and a failed LOB
  /// read still fails the whole operation rather than returning a half-populated
  /// result — but the bracket that holds the connection is the caller's, and on
  /// the streaming path the enclosing round trip is a FETCH, not an execute.
  Future<ExecuteResponse> _materializeLobValues(
    ExecuteResponse response, {
    List<BindMetadata>? bindMetadata,
    bool dmlReturning = false,
    Duration? timeout,
    Object Function(LobLocator locator)? wrapLob,
  }) async {
    if (!response.isSuccess) return response;
    final hasRowLob = response.rows.any(
      (row) => row.any((v) => v is LobLocator),
    );
    final hasOutLob = response.outBindValues.any((v) => v is LobLocator);
    // A DML RETURNING outBindRows cell is itself a list of returned values
    // (one per return bind), so its locators live one level deeper than the
    // PL/SQL executeMany shape (a scalar value per OUT bind). Detect and
    // materialize accordingly.
    final hasBatchOutLob = dmlReturning
        ? response.outBindRows.any(
            (row) => row.any(
              (cell) => cell is List && cell.any((v) => v is LobLocator),
            ),
          )
        : response.outBindRows.any((row) => row.any((v) => v is LobLocator));
    if (!hasRowLob && !hasOutLob && !hasBatchOutLob) return response;

    // Oracle's duplicate-column optimization can alias one LobLocator
    // instance into several rows; resolve each distinct locator once. On the
    // fetchLobs path this dedup means one locator yields exactly one shared
    // OracleLob handle no matter how many rows alias it.
    final materialized = <LobLocator, Object>{};
    Future<Object> readLocator(LobLocator locator) async {
      final existing = materialized[locator];
      if (existing != null) return existing;
      final Object value;
      if (wrapLob != null) {
        // fetchLobs: true — the handle owns the locator and frees it itself on
        // close() via OracleConnection.releaseLob. Queueing here too would
        // double-free (see queueTempLobToFree's ownership invariant).
        value = wrapLob(locator);
      } else {
        // Story 12.4 AC4 — the MATERIALIZE path's temporary-locator free.
        //
        // Materializing reads the locator's content into a String/Uint8List and
        // then DISCARDS the locator, so nothing else can ever free it. For a
        // locator the server allocated as a session-duration TEMPORARY LOB that
        // is a real resource leak: measured live on Oracle 23ai and 21c, three
        // consecutive `OracleBind.inOut(value: <String>, type: clob)` PL/SQL
        // calls under `fetchLobs: false` grew this session's V$TEMPORARY_LOBS
        // count 0 -> 1 -> 2 -> 3, exactly one per call, until session end.
        //
        // The decision is CONTENT-driven, never shape- or version-driven: the
        // locator's own TEMP flag bit (LobLocator.isTemporary, flag byte 4 bit
        // 0x01) is the only input. Every shape measured non-temporary — a plain
        // table row locator, `SELECT TO_CLOB(...)`, a `FOR UPDATE` locator, and a
        // PL/SQL CLOB OUT bind the body fills from a TO_CLOB LITERAL — therefore
        // keeps queueing nothing and is byte-for-byte unaffected. ("A PL/SQL LOB
        // OUT bind" is NOT one answer: an OUT locator the body assigns from a
        // TEMPORARY input LOB, `p_out := p_in`, IS flagged and IS queued.) Only
        // the free-temp queue ACCOUNTING changes; the materialized value the
        // caller receives is untouched.
        //
        // At most once per locator per response: this closure runs behind the
        // `materialized` dedup map above, so an aliased locator (Oracle's
        // duplicate-column optimization) is materialized — and hence queued —
        // exactly once, preserving queueTempLobToFree's at-most-once contract.
        //
        // No `OracleLob` is PRODUCED on this path (wrapLob is null), but one can
        // still be BOUND across the same statement: README documents
        // `OracleBind.inOut(value: lob, type: clob)` for a `createTemporary*`
        // handle, and created-temporary handles are exempt from the in-flight
        // slot rule, so such a handle can be open and can queue its own locator
        // on close(). What holds the at-most-once contract there is not the
        // absence of a handle but a MEASURED locator distinctness: Oracle
        // REPLACES the LOB behind an `IN OUT` bind, so the materialized OUT
        // locator is a DIFFERENT temporary LOB from the one the caller's handle
        // owns, and `p_out := p_in` deep-copies. Pinned live on 23ai and 21c by
        // `test/integration/lob_temporary_integration_test.dart` (the IN OUT
        // temp-handle case asserting pending 1 -> 2 as two DISTINCT entries,
        // then proving the carrier statement and the session survive both
        // frees). Empirical, not structural — a story that changes IN OUT
        // handling must re-measure it rather than trust this paragraph.
        //
        // The queued free rides the NEXT sendExecute's FREE_TEMP piggyback, and a
        // locator can never be freed by the very round trip that produced it.
        // The invariant is ORDERING, not call nesting: this method always runs
        // AFTER the round trip that produced the response has completed (it is
        // called from the connection layer / ResultSetCursor, NOT from inside
        // sendExecute), and that round trip's piggyback was built and sent before
        // the response came back. So whatever is queued here can only ride a
        // LATER message.
        //
        // FETCH-path deferral, worth knowing: on a streaming result set the
        // enclosing round trip is a per-batch FETCH, not an execute — and the
        // queue drains only on sendExecute. An open fetched handle blocks
        // execute() anyway, so a free queued while materializing a continuation
        // batch waits for the first UNRELATED execute after the result set
        // closes. Correct (the server-side temp LOB simply lives a little
        // longer), but it means debugPendingTempLobCount can stay non-zero for
        // the whole life of a streaming result set.
        //
        // EXCEPTION-SAFE by `try/finally`, not by ordering: the read below can
        // throw (the strict truncation guard, a malformed UTF-8/UTF-16
        // FormatException, a no-progress/overshoot fault in `readLobRange`'s
        // piece loop). Queueing only after a SUCCESSFUL read would gate the free
        // on "the read worked" and re-open exactly the leak this AC closed —
        // every read-failure path would leak the temp LOB until session end. The
        // `finally` gates it on "the read was attempted" instead, matching
        // `_createTempClob`/`_createTempBlob` (`finally`) and
        // `createTemporaryLob` (`catch`/rethrow). Queueing is not freeing: it
        // only records the locator for the next execute's piggyback, so doing it
        // for a locator whose read failed is correct — the server-side temp LOB
        // exists either way.
        //
        // ORDERING (Story 12.3 interaction, recorded here because nothing else
        // records it): `_readClobAsString`/`_readBlobAsBytes` now go through
        // `readLobRange`, which calls `copyBackLocator(locator,
        // response.updatedLocator)` after every piece. So both the
        // `locator.isTemporary` DECISION and the BYTES queued are the server's
        // post-READ echo of the locator, not the bytes the row delivered — the
        // `finally` does not change that (a partial read may already have copied
        // back). That is deliberate and matches node-oracledb, which frees its
        // own copy-back-updated `_locator`; the echo of a temporary LOB stays
        // temporary and keeps the same identity, and the dangerous direction
        // would be a persistent locator whose echo flipped flag-4 bit 0 on,
        // which is unobserved on both fixtures. See `queueTempLobToFree`'s
        // dedupe-backstop note for the companion in-place-mutation caveat.
        try {
          value = locator.oracleType == oraTypeBlob
              ? await _readBlobAsBytes(locator, timeout)
              : await _readClobAsString(locator, timeout);
        } finally {
          if (locator.isTemporary) queueTempLobToFree(locator.locator);
        }
      }
      materialized[locator] = value;
      return value;
    }

    var rows = response.rows;
    if (hasRowLob) {
      final newRows = <List<Object?>>[];
      for (final row in response.rows) {
        final newRow = List<Object?>.of(row);
        for (var i = 0; i < newRow.length; i++) {
          final value = newRow[i];
          if (value is LobLocator) {
            newRow[i] = await readLocator(value);
          }
        }
        newRows.add(newRow);
      }
      rows = newRows;
    }

    var outBindValues = response.outBindValues;
    if (hasOutLob) {
      final newOut = List<Object?>.of(outBindValues);
      for (var i = 0; i < newOut.length; i++) {
        final value = newOut[i];
        if (value is! LobLocator) continue;
        // OracleBind(type: clob/blob) requires maxSize; enforce it
        // client-side before reading — the wire bind is locator-sized, so
        // the server cannot apply the usual OUT-buffer bound (node-oracledb
        // raises ERR_INSUFFICIENT_BUFFER_FOR_BINDS from its outConverter
        // the same way). Units follow the LOB type: characters for CLOB,
        // bytes for BLOB.
        final maxSize = resolveOutBindMaxSize(
          valueIndex: i,
          outBindIndices: response.outBindIndices,
          bindMetadata: bindMetadata,
        );
        // The maxSize guard bounds the materialized return buffer; a fetchLobs
        // handle materializes nothing (the caller reads bounded pieces), so it
        // does not apply when wrapping.
        if (wrapLob == null && maxSize != null && value.length > maxSize) {
          final isBlob = value.oracleType == oraTypeBlob;
          throw OracleException(
            errorCode: oraBindTypeError,
            message:
                '${isBlob ? 'BLOB' : 'CLOB'} OUT bind returned '
                '${value.length} ${isBlob ? 'bytes' : 'characters'} but '
                'OracleBind maxSize is $maxSize — increase maxSize to at '
                'least the largest value the block can return',
          );
        }
        newOut[i] = await readLocator(value);
      }
      outBindValues = newOut;
    }

    var outBindRows = response.outBindRows;
    if (hasBatchOutLob) {
      // Enforce the declared maxSize per returned LOB value, then materialize
      // it, exactly like the single-execute OUT path above. Position j of each
      // row maps to bindMetadata[outBindIndices[j]], so the guard resolution is
      // shared across all executeMany shapes.
      OracleException tooLarge(LobLocator value, int maxSize) {
        final isBlob = value.oracleType == oraTypeBlob;
        return OracleException(
          errorCode: oraBindTypeError,
          message:
              '${isBlob ? 'BLOB' : 'CLOB'} OUT bind returned '
              '${value.length} ${isBlob ? 'bytes' : 'characters'} in an '
              'executeMany iteration but OracleBindDef maxSize is $maxSize — '
              'increase maxSize to at least the largest value the block can '
              'return',
        );
      }

      final newRows = <List<Object?>>[];
      for (final row in response.outBindRows) {
        final newRow = List<Object?>.of(row);
        for (var j = 0; j < newRow.length; j++) {
          final maxSize = resolveOutBindMaxSize(
            valueIndex: j,
            outBindIndices: response.outBindIndices,
            bindMetadata: bindMetadata,
          );
          final cell = newRow[j];
          if (dmlReturning) {
            // DML RETURNING: cell is the list of returned values for return
            // bind j in this iteration (possibly several database rows, or an
            // empty list for a zero-row match). Materialize each locator.
            if (cell is! List) continue;
            final newCell = List<Object?>.of(cell);
            for (var k = 0; k < newCell.length; k++) {
              final value = newCell[k];
              if (value is! LobLocator) continue;
              if (wrapLob == null &&
                  maxSize != null &&
                  value.length > maxSize) {
                throw tooLarge(value, maxSize);
              }
              newCell[k] = await readLocator(value);
            }
            newRow[j] = newCell;
          } else {
            // PL/SQL executeMany: cell is a scalar OUT value.
            if (cell is! LobLocator) continue;
            if (wrapLob == null && maxSize != null && cell.length > maxSize) {
              throw tooLarge(cell, maxSize);
            }
            newRow[j] = await readLocator(cell);
          }
        }
        newRows.add(newRow);
      }
      outBindRows = newRows;
    }

    return ExecuteResponse(
      isSuccess: true,
      cursorId: response.cursorId,
      columnMetadata: response.columnMetadata,
      rows: rows,
      outBindValues: outBindValues,
      outBindIndices: response.outBindIndices,
      outBindRows: outBindRows,
      // PL/SQL with both an OUT LOB bind and implicit results reaches here;
      // preserve the decoded implicit cursor descriptors through the rebuild.
      implicitResults: response.implicitResults,
      rowsAffected: response.rowsAffected,
      moreRowsToFetch: response.moreRowsToFetch,
      // Preserve Story 11.3 array-DML row-level reporting through the rebuild.
      // A DML RETURNING executeMany (Story 11.4) with LOB return binds and
      // `dmlRowCounts: true` routes through this exact path, so these must not
      // be silently dropped.
      batchErrors: response.batchErrors,
      dmlRowCounts: response.dmlRowCounts,
    );
  }

  /// Reads a CLOB locator's full value as a Dart String.
  ///
  /// Mirrors node-oracledb `lob.js` `getData()` → `read(1, this._length)`: the
  /// entire LOB length requested at 1-based offset 1. The server streams the
  /// content back as one or more `LOB_DATA` messages inside a single response,
  /// which [decodeLobOpResponse] concatenates into one byte buffer — and since
  /// Story 12.3 the request itself continues across further READs at the
  /// advanced offset ([readLobRange]) if one round trip cannot deliver the whole
  /// range, so there is no size at which this path gives up. Every measured
  /// value (up to 32 MB on 23ai, 8 MB on 21c) still arrives in exactly one READ.
  ///
  /// Requesting the whole length — rather than looping with a per-chunk
  /// character offset and decoding each chunk — keeps multibyte and
  /// supplementary-plane (surrogate pair) text correct: a chunk boundary can
  /// split a UTF-8 sequence or a surrogate pair, which a per-piece decode cannot
  /// reassemble but a single decode over the fully assembled bytes always can.
  /// [readLobRange] therefore concatenates pieces as BYTES and this method
  /// decodes exactly once. It also avoids reconstructing a character offset from
  /// a decoded String's length, which counts UTF-16 code units and desynced from
  /// Oracle's character offsets on astral text.
  Future<String> _readClobAsString(
    LobLocator locator,
    Duration? timeout,
  ) async {
    if (locator.length == 0) return ''; // EMPTY_CLOB()
    // A locator's data travels as UTF-16BE instead of the negotiated UTF-8
    // when it is national-charset. node-oracledb `lob.js getCsfrm()` decides
    // this two ways: an NCLOB's declared NCHAR form is national outright, and a
    // plain CLOB is national only if its locator carries the variable-length
    // charset flag (Oracle sets that bit on PL/SQL-created and temporary CLOBs,
    // whose data is stored as UCS-2). Server-created NCLOB locators do NOT
    // always set the flag bit, so the declared NCHAR form must be honored too.
    final isUtf16 = locator.isNChar || locator.usesVarLengthCharset;
    final read = await readLobRange(
      locator: locator.locator,
      offset: 1, // 1-based: read from the start of the LOB
      amount: locator.length, // the entire LOB length
      timeout: timeout,
    );
    final bytes = read.bytes;
    if (bytes.isEmpty) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'CLOB read returned no data '
            '(expected ${locator.length} chars)',
      );
    }
    final String text;
    try {
      // Strict decode over the fully assembled buffer: malformed bytes mean
      // stream corruption — fail loud instead of substituting replacement
      // characters.
      text = isUtf16 ? decodeUtf16Be(bytes) : utf8.decode(bytes);
    } on FormatException catch (e) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'CLOB read returned malformed '
            '${isUtf16 ? 'UTF-16' : 'UTF-8'} data',
        cause: e,
      );
    }
    // Truncation guard. Oracle reports CLOB length in UCS-2 code
    // units (CLOBs are stored AL16UTF16), which equals Dart's UTF-16
    // `String.length` — so a short read is a real truncation, not a
    // code-point-vs-code-unit mismatch.
    if (text.length != locator.length) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'CLOB read length mismatch: locator reports '
            '${locator.length} chars but ${text.length} were received',
      );
    }
    return text;
  }

  /// Reads a BLOB locator's full value as a Dart `Uint8List`.
  ///
  /// Mirrors node-oracledb `lob.js` `getData()` → `read(1, this._length)`: the
  /// entire LOB byte length requested at 1-based offset 1. The server streams
  /// the content back as one or more `LOB_DATA` messages inside a single
  /// response, which [decodeLobOpResponse] concatenates into one byte buffer —
  /// and since Story 12.3 the request continues across further READs at the
  /// advanced offset ([readLobRange]) if one round trip cannot deliver the whole
  /// range, so there is no size at which this path gives up. Every measured
  /// value (up to 32 MB on 23ai, 8 MB on 21c) still arrives in exactly one READ.
  /// BLOB `LOB_DATA` bytes pass through unchanged — no character set conversion
  /// of any kind (node-oracledb lobOp.js processMessage keeps BLOB data as a raw
  /// Buffer).
  Future<Uint8List> _readBlobAsBytes(
    LobLocator locator,
    Duration? timeout,
  ) async {
    if (locator.length == 0) {
      return Uint8List(0); // EMPTY_BLOB() — no LOB_DATA round trip needed
    }
    final read = await readLobRange(
      locator: locator.locator,
      offset: 1, // 1-based: read from the start of the LOB (bytes)
      amount: locator.length, // the entire LOB byte length
      timeout: timeout,
    );
    final bytes = read.bytes;
    if (bytes.isEmpty) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'BLOB read returned no data '
            '(expected ${locator.length} bytes)',
      );
    }
    verifyBlobReadLength(bytes.length, locator.length);
    return bytes;
  }

  /// Sends a TTC COMMIT message and waits for the server's acknowledgement.
  ///
  /// [timeout] bounds how long to wait for Oracle's commit acknowledgement.
  /// Throws [OracleException] if the commit fails, times out, or the connection is broken.
  Future<void> sendCommit({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final buf = WriteBuffer();
    buf.writeUint8(ttcMsgTypeFunction);
    buf.writeUint8(ttcFuncCommit);
    buf.writeUint8(nextSequence() & 0xFF);
    if (_ttcFieldVersion >= ttcCcapFieldVersion23_1Ext1) {
      buf.writeUB8(0);
    }
    await sendData(buf.toBytes());
    final payload = await _receiveDataWithTimeout(timeout, operation: 'Commit');
    final response = decodeExecuteResponse(
      payload,
      isQuery: false,
      ttcFieldVersion: _ttcFieldVersion,
      endOfRequestSupport: _supportsEndOfRequest,
    );
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
  Future<void> sendRollback({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final buf = WriteBuffer();
    buf.writeUint8(ttcMsgTypeFunction);
    buf.writeUint8(ttcFuncRollback);
    buf.writeUint8(nextSequence() & 0xFF);
    if (_ttcFieldVersion >= ttcCcapFieldVersion23_1Ext1) {
      buf.writeUB8(0);
    }
    await sendData(buf.toBytes());
    final payload = await _receiveDataWithTimeout(
      timeout,
      operation: 'Rollback',
    );
    final response = decodeExecuteResponse(
      payload,
      isQuery: false,
      ttcFieldVersion: _ttcFieldVersion,
      endOfRequestSupport: _supportsEndOfRequest,
    );
    if (!response.isSuccess) {
      throw OracleException(
        errorCode: response.errorCode ?? oraProtocolError,
        message: response.errorMessage ?? 'Rollback failed',
      );
    }
  }

  /// Sends a `TNS_MSG_TYPE_FLUSH_OUT_BINDS` request and drains its response.
  ///
  /// The DML `RETURNING ... INTO` error path ends its response with a
  /// FLUSH_OUT_BINDS marker; the server then expects a matching one-byte
  /// FLUSH_OUT_BINDS request to reset the accumulated OUT-bind state before it
  /// will process the next RPC (node-oracledb `protocol.js flushOutBindMessage`,
  /// gated on `message.flushOutBinds` in `_processCallStatus`). Skipping it
  /// leaves the wire desynchronized — the next execute/commit/rollback draws
  /// ORA-03137. The response carries no client-visible data (the original DML
  /// error is surfaced separately), so it is decoded only to consume the bytes.
  Future<ExecuteResponse> _flushOutBinds(
    Duration? timeout, {
    bool dmlRowCounts = false,
  }) async {
    final buf = WriteBuffer()..writeUint8(ttcMsgTypeFlushOutBinds);
    await sendData(buf.toBytes());
    final payload = await _receiveDataWithTimeout(
      timeout,
      operation: 'FlushOutBinds',
      dmlRowCounts: dmlRowCounts,
    );
    return decodeExecuteResponse(
      payload,
      isQuery: false,
      ttcFieldVersion: _ttcFieldVersion,
      endOfRequestSupport: _supportsEndOfRequest,
      dmlRowCounts: dmlRowCounts,
    );
  }

  /// Sends a DEFINE call for an open query cursor whose result shape
  /// contains a CLOB column and returns its decoded response.
  ///
  /// The call establishes column defines with the LOB prefetch cont-flag
  /// AND re-executes the cursor: its response carries the first row batch
  /// (up to [prefetchRows] rows) in the prefetch shape, so the caller must
  /// treat it as the authoritative first batch. Mirrors node-oracledb
  /// `connection._handleDefines`.
  Future<ExecuteResponse> _sendLobDefines(
    String sql,
    int cursorId,
    List<ColumnMetadata> columns,
    int prefetchRows,
    Duration? timeout,
  ) async {
    final request = ExecuteRequest(
      sql: sql,
      isQuery: true,
      cursorId: cursorId,
      numIters: prefetchRows,
      defineColumns: columns,
      ttcFieldVersion: _ttcFieldVersion,
      sequence: nextSequence(),
    );
    await sendData(request.toBytes());
    final payload = await _receiveDataWithTimeout(
      timeout,
      operation: 'Define',
      expectedColumns: columns,
    );
    final response = decodeExecuteResponse(
      payload,
      isQuery: true,
      ttcFieldVersion: _ttcFieldVersion,
      endOfRequestSupport: _supportsEndOfRequest,
      expectedColumns: columns,
      supportsNationalCharset: supportsNationalCharset,
      nationalCharset: nationalCharset,
    );
    if (!response.isSuccess) {
      throw OracleException(
        errorCode: response.errorCode ?? oraProtocolError,
        message: response.errorMessage ?? 'LOB define call failed',
      );
    }
    return response;
  }

  Future<ExecuteResponse> _sendFetch(
    int cursorId,
    int numRows,
    Duration? timeout, {
    List<ColumnMetadata>? expectedColumns,
    bool preserveTimestampTimeZone = false,
    List<Object?>? previousRoundLastRow,
  }) async {
    final fetch = FetchRequest(
      cursorId: cursorId,
      numRows: numRows,
      ttcFieldVersion: _ttcFieldVersion,
      sequence: nextSequence(),
    );
    await sendData(fetch.toBytes());
    final payload = await _receiveDataWithTimeout(
      timeout,
      expectedColumns: expectedColumns,
    );
    return decodeExecuteResponse(
      payload,
      isQuery: true,
      ttcFieldVersion: _ttcFieldVersion,
      endOfRequestSupport: _supportsEndOfRequest,
      expectedColumns: expectedColumns,
      preserveTimestampTimeZone: preserveTimestampTimeZone,
      supportsNationalCharset: supportsNationalCharset,
      nationalCharset: nationalCharset,
      previousRoundLastRow: previousRoundLastRow,
    );
  }

  Future<Uint8List> _receiveDataWithTimeout(
    Duration? timeout, {
    String operation = 'Query',
    List<ColumnMetadata>? expectedColumns,
    List<BindMetadata>? bindMetadata,
    bool Function(Uint8List accumulated)? completionProbe,
    bool plSqlExecuteMany = false,
    bool dmlReturning = false,
    bool dmlRowCounts = false,
    List<int>? presetOutBindIndices,
  }) async {
    _ensureUsable();
    final future = _receiveAllTtcData(
      expectedColumns: expectedColumns,
      bindMetadata: bindMetadata,
      completionProbe: completionProbe,
      plSqlExecuteMany: plSqlExecuteMany,
      dmlReturning: dmlReturning,
      dmlRowCounts: dmlRowCounts,
      presetOutBindIndices: presetOutBindIndices,
    );
    if (timeout == null) return future;
    return future.timeout(
      timeout,
      onTimeout: () {
        // `Future.timeout` abandons the returned future but does NOT cancel the
        // underlying socket read: the server's (late) response may still arrive
        // and would otherwise be misread as the reply to the next RPC. Poison
        // the transport and destroy the socket so that can never happen. The
        // message carries the operation name and elapsed wait; the
        // poisoned state makes every subsequent send/receive fail fast.
        _poison();
        throw OracleException(
          errorCode: oraConnectTimeout,
          message:
              '$operation timed out after ${timeout.inMilliseconds}ms; '
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
  ///     scan accumulated bytes after each packet using [ttcStreamIsComplete]
  ///     and keep reading more packets if the response is incomplete. This
  ///     matches node-oracledb thin (`packet.js waitForPackets`), which only
  ///     batches packets for `endOfRequestSupport == true`.
  Future<Uint8List> _receiveAllTtcData({
    List<ColumnMetadata>? expectedColumns,
    List<BindMetadata>? bindMetadata,
    bool Function(Uint8List accumulated)? completionProbe,
    bool plSqlExecuteMany = false,
    bool dmlReturning = false,
    bool dmlRowCounts = false,
    List<int>? presetOutBindIndices,
  }) async {
    // The completion probe decides whether the accumulated TTC bytes form a
    // complete response. EXECUTE-shaped responses (the default) use
    // [ttcStreamIsComplete]; LOB operations substitute [lobOpStreamIsComplete]
    // because their LOB_DATA / RETURN_PARAMETER shapes are not walkable by
    // the EXECUTE decoder. The probe needs [bindMetadata] for byte-accurate
    // OUT-bind consumption: a CLOB OUT bind ships a locator
    // shape, not a generic length-prefixed value, so the metadata-less
    // fallback would misalign the stream on pre-23.4 servers (where this
    // probe — not TNS data flags — detects end-of-response).
    //
    // A probe may also THROW (OracleException, oraProtocolError) when the
    // accumulated bytes are malformed on their face — waiting for more
    // packets can never repair that. A malformed stream means framing
    // desync: any later read on this socket would decode garbage, so poison
    // the transport before propagating (same rationale as the receive-packet cap and
    // the mid-query REFUSE below). The connection must not be reused.
    bool isComplete(Uint8List accumulated) {
      try {
        return completionProbe != null
            ? completionProbe(accumulated)
            : ttcStreamIsComplete(
                accumulated,
                ttcFieldVersion: _ttcFieldVersion,
                endOfRequestSupport: _supportsEndOfRequest,
                expectedColumns: expectedColumns,
                bindMetadata: bindMetadata,
                plSqlExecuteMany: plSqlExecuteMany,
                dmlReturning: dmlReturning,
                dmlRowCounts: dmlRowCounts,
                presetOutBindIndices: presetOutBindIndices,
              );
      } on OracleException catch (e) {
        _poison();
        throw OracleException(
          errorCode: e.errorCode,
          message:
              '${e.message}. Transport poisoned — close this connection '
              'and open a new one.',
          cause: e,
        );
      } catch (e) {
        // Any other throw escaping a probe is equally a framing-desync
        // hazard (the probe contract is return-bool-or-OracleException);
        // poison so the guarantee is self-contained, then propagate as-is.
        _poison();
        rethrow;
      }
    }

    final chunks = <Uint8List>[];
    var packetsRead = 0;
    while (true) {
      // Bound the loop so a server response that never satisfies the
      // completion probe cannot spin forever. Poison the transport before
      // throwing — a partially-read, non-terminating stream is a framing hazard
      // and the connection must not be reused.
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
      var packet = await receive();
      while (packet.type == tnsPacketMarker) {
        // Marker payload: [markerType(1B), pad(1B), dataType(1B)]
        // dataType: 1=BREAK(NIQBMARK), 2=RESET(NIQRMARK), 3=INTERRUPT(NIQIMARK)
        // When Oracle sends a BREAK marker it means "I have an error; acknowledge
        // with a RESET marker before I send the DATA response."
        //
        // Count MARKER packets against the cap (review patch): a server that
        // floods MARKER packets would otherwise bypass the receive-loop guard entirely.
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
        // refuse reason carried in the packet instead. Auth-time REFUSE is
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
        // could terminate a multi-packet response early. Follow-up guard:
        // only treat a trailing 0x1D as terminal once the accumulated TTC stream
        // actually parses to a complete response; otherwise keep reading.
        //
        // Cost note: like the pre-23.4 probe below, this sub-path
        // re-concatenates and re-walks the full accumulation once per packet
        // when a flags=0x0000 error response spans multiple packets — O(N x
        // bytes). The trailing-0x1D check short-circuits the expensive probe so
        // the re-walk only runs on packets that *look* terminal, and error
        // responses on 23ai are small (a single ORA-xxxxx message, almost
        // always one packet), so N is effectively 1. The same bound that covers
        // the pre-23.4 probe is exercised for this branch by the benchmark in
        // test/src/transport/ttc_stream_benchmark_test.dart. The long-term fix
        // (a stateful/lazy parser) is the shared follow-up tracked below.
        // A DML RETURNING error response instead ends with the FLUSH_OUT_BINDS
        // marker (0x13); treat it the same way — a trailing marker that only
        // terminates once the accumulated stream parses to a complete response.
        if (ttcData.isNotEmpty &&
            (ttcData.last == ttcMsgTypeEndOfRequest ||
                ttcData.last == ttcMsgTypeFlushOutBinds) &&
            isComplete(_concatChunks(chunks))) {
          break;
        }
      } else {
        // Pre-23.4 (Oracle 21c / 19c): no TNS-level boundary. Scan the
        // accumulated TTC bytes for STATUS / END_OF_REQUEST. If the response
        // is complete, stop; otherwise wait for the next packet.
        //
        // Cost note: this probe re-walks the full accumulated buffer once
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
        if (isComplete(_concatChunks(chunks))) {
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
  /// packet, surfacing the server's actual refuse reason.
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
      message:
          'Server refused the request mid-session '
          '(REFUSE userReason=0x${userReason.toRadixString(16)}, '
          'systemReason=0x${systemReason.toRadixString(16)}): $detail',
    );
  }

  /// Sends a TTC PING message to verify connection health.
  ///
  /// Throws [OracleException] if ping fails or times out.
  Future<void> sendPing({Duration timeout = const Duration(seconds: 5)}) async {
    _log.fine('Sending ping...');

    // Build a proper TTC FUNCTION message (node-oracledb writeFunctionHeader
    // parity: messageType FUNCTION + function code + sequence + 23.1 token UB8),
    // exactly like sendCommit/sendRollback. The legacy PingMessage emitted only
    // the bare function-code byte `[0x93]` with no FUNCTION framing or sequence —
    // the server then replied with a non-standard packet that the old single
    // `receive()` swallowed without validation, leaving stale TTC bytes on the
    // socket that the next RPC misframed (the ORA-12170 hang in deferred item D).
    final buf = WriteBuffer();
    buf.writeUint8(ttcMsgTypeFunction);
    buf.writeUint8(ttcPing);
    buf.writeUint8(nextSequence() & 0xFF);
    if (_ttcFieldVersion >= ttcCcapFieldVersion23_1Ext1) {
      buf.writeUB8(0);
    }
    await sendData(buf.toBytes());

    // Drain the FULL TTC ping reply through the same completion-probe path every
    // other RPC uses (see sendCommit/sendRollback) and surface any server error.
    // `_receiveDataWithTimeout` poisons the transport on timeout, so a ping that
    // never replies still fails fast and cannot corrupt a later RPC.
    final response = await _receiveDataWithTimeout(timeout, operation: 'Ping');
    final decoded = decodeExecuteResponse(
      response,
      isQuery: false,
      ttcFieldVersion: _ttcFieldVersion,
      endOfRequestSupport: _supportsEndOfRequest,
    );
    if (!decoded.isSuccess) {
      throw OracleException(
        errorCode: decoded.errorCode ?? oraProtocolError,
        message: decoded.errorMessage ?? 'Ping failed',
      );
    }
    _log.fine('Ping response drained (${response.length} bytes)');
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
      // Fail fast if the transport was poisoned by a prior timeout on
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
          _log.info(
            'Negotiated version=${acceptInfo.version}, '
            'sdu=${acceptInfo.sdu}, largeSdu=$_useLargeSdu, '
            'endOfRequest=$_supportsEndOfRequest, '
            'supportsFastAuth=$_supportsFastAuth',
          );

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
            'Server requested resend (attempt $resendCount/$_maxResendRetries)',
          );
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
    _log.info(
      'Protocol negotiation complete: '
      'serverVersion=${protocolResponse.serverVersion}',
    );

    // Store server major version for subsequent flag decisions.
    _serverMajorVersion =
        _extractMajorVersion(protocolResponse.serverBanner) ?? 23;
    _log.fine(
      'Server major version: $_serverMajorVersion '
      '(banner: ${protocolResponse.serverBanner})',
    );

    // Adjust ttcFieldVersion based on server compile caps
    _adjustFieldVersion(protocolResponse.compileCaps);

    // Step 2: Send data types negotiation (required before auth). The
    // server's advertised compile-cap vector has already been folded into the
    // client state above via _adjustFieldVersion (node-oracledb parity:
    // protocol.js processProtocolInfo -> adjustForServerCompileCaps mutates the
    // shared caps object BEFORE dataType.js encode runs), so the DataTypes
    // message needs no further reference to the protocol response.
    await _sendDataTypesNegotiation();

    return protocolResponse;
  }

  /// Sends a standalone AUTH_PHASE_ONE message and returns the raw TTC
  /// response data. Used by the classical (pre-23) authentication path, after
  /// [sendProtocolNegotiation] has completed.
  Future<Uint8List> sendAuthPhaseOne(
    AuthPhaseOneRequest request, {
    Duration? timeout,
  }) async {
    final bytes = request.toBytes();
    await sendData(bytes, dataFlags: 0x0000);
    final future = receiveData();
    if (timeout == null) return future;
    // Mirror the timeout-poisoning contract of _receiveDataWithTimeout: on
    // timeout the in-flight socket read is not cancelled, so destroy the socket
    // to guarantee the orphaned response cannot be misread as a later reply.
    return future.timeout(
      timeout,
      onTimeout: () {
        _poison();
        throw OracleException(
          errorCode: oraConnectTimeout,
          message:
              'AUTH_PHASE_ONE timed out after ${timeout.inMilliseconds}ms; transport poisoned',
        );
      },
    );
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
    _log.info(
      'Protocol negotiation complete: '
      'serverVersion=${protocolResponse.serverVersion}',
    );

    // Store server major version now that the response is available.
    _serverMajorVersion =
        _extractMajorVersion(protocolResponse.serverBanner) ?? 23;
    _log.fine(
      'Server major version: $_serverMajorVersion '
      '(banner: ${protocolResponse.serverBanner})',
    );

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
      'DEBUG: protocolEndPos=$protocolEndPos, total responseData=${responseData.length} bytes',
    );

    // Parse DataTypes response from remaining bytes
    int dataTypesEndPos = protocolEndPos;
    if (protocolEndPos < responseData.length) {
      final dataTypesData = Uint8List.sublistView(responseData, protocolEndPos);
      _log.fine(
        'DEBUG: dataTypesData starts at byte $protocolEndPos, first byte: ${dataTypesData[0]}',
      );
      DataTypesResponse.decode(dataTypesData);
      _log.info('Data types negotiation complete');

      // Track DataTypes end position by parsing its structure
      final dtBuffer = ReadBuffer(dataTypesData);
      dtBuffer.readUint8(); // type

      // Skip charset fields (4 bytes) + encoding flags (1 byte)
      if (dtBuffer.remaining >= 5) {
        dtBuffer.skip(
          5,
        ); // charset (2 bytes) + nCharset (2 bytes) + flags (1 byte)
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
            'DEBUG: Found AUTH parameter message at byte $currentPos (absolute: $dataTypesEndPos)',
          );
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
        'DEBUG: dataTypesEndPos=$dataTypesEndPos, dtBuffer.position=${dtBuffer.position}',
      );
    }

    // Buffer the AUTH response (remaining bytes) for next receiveData() call
    if (dataTypesEndPos < responseData.length) {
      _bufferedAuthResponse = Uint8List.sublistView(
        responseData,
        dataTypesEndPos,
      );
      _log.fine(
        'Buffered AUTH response: ${_bufferedAuthResponse!.length} bytes, starts with byte: ${_bufferedAuthResponse![0]}',
      );
      _log.fine(
        'First 32 bytes of AUTH response: ${_bufferedAuthResponse!.sublist(0, _bufferedAuthResponse!.length > 32 ? 32 : _bufferedAuthResponse!.length).map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}',
      );
    }

    // Auth response will be handled by auth module via receiveData()
    return protocolResponse;
  }

  /// Legacy method - deprecated in favor of sendFastAuth.
  @Deprecated('Use sendFastAuth for Oracle 23ai compatibility')
  Future<ProtocolResponse> sendBatchedProtocolAndAuth(
    Uint8List authPhaseOneBytes,
  ) async {
    throw UnsupportedError(
      'Manual batching is deprecated. Use sendFastAuth instead.',
    );
  }

  /// Builds the data types negotiation TTC message without sending it.
  /// Adjusts the TTC field version based on server compile capabilities.
  void _adjustFieldVersion(Uint8List? serverCompileCaps) {
    if (serverCompileCaps != null &&
        serverCompileCaps.length > _ccapFieldVersion) {
      final serverFieldVersion = serverCompileCaps[_ccapFieldVersion];
      if (serverFieldVersion < _ttcFieldVersion) {
        _ttcFieldVersion = serverFieldVersion;
        _log.fine(
          'Adjusted ttcFieldVersion to $serverFieldVersion '
          '(server limit)',
        );
      } else {
        _log.fine(
          'ttcFieldVersion remains $_ttcFieldVersion '
          '(server supports $serverFieldVersion)',
        );
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
    _log.info(
      'Protocol negotiation complete (minimal): '
      'serverVersion=${protocolResponse.serverVersion}',
    );

    return protocolResponse;
  }

  /// Sends the data types negotiation message.
  ///
  /// Takes no protocol-response argument by design. The DataTypes capabilities
  /// the client sends are a FIXED client vector ([_buildCompileCapabilities] /
  /// [_buildRuntimeCapabilities]); they are NOT gated on the server's
  /// advertised compile-cap vector at this site. This matches node-oracledb's
  /// thin client exactly: `dataType.js` `DataTypeMessage.encode` writes
  /// `buf.caps.compileCaps`/`runtimeCaps` verbatim, and the only server-vector
  /// adjustment (ttcFieldVersion clamp) happens earlier in the Protocol-message
  /// handler (`protocol.js` `adjustForServerCompileCaps`). The Dart equivalent
  /// of that clamp ([_adjustFieldVersion]) runs in [sendProtocolNegotiation]
  /// BEFORE this call, so the caps built here already reflect any server limit.
  Future<void> _sendDataTypesNegotiation() async {
    _log.info('Starting data types negotiation');

    // Build client capabilities
    final compileCaps = _buildCompileCapabilities();
    final runtimeCaps = _buildRuntimeCapabilities();

    await sendData(encodeDataTypesMessage(compileCaps, runtimeCaps));

    // Receive data types response
    final respData = await receiveData();
    _log.fine('Received data types response: ${respData.length} bytes');

    parseDataTypesResponse(respData);

    _log.info('Data types negotiation complete');
  }

  /// Parses the classical-path DataTypes negotiation RESPONSE body.
  ///
  /// The classical path issues its DataTypes request as a standalone round
  /// trip (see [_sendDataTypesNegotiation]), so [receiveData] hands this method
  /// a buffer that contains EXACTLY one DataTypes response and nothing else:
  ///
  ///   `[ message-type byte (2) ][ data-type mapping loop ... ][ 0x0000 ]`
  ///
  /// CRITICAL — the RESPONSE is NOT shaped like the REQUEST. The request that
  /// [encodeDataTypesMessage] builds carries a 5-byte charset/flags preamble
  /// (primary charset + national charset + encoding flags) and the two
  /// length-prefixed caps blocks BEFORE the mapping loop. The server's response
  /// carries NONE of that — it is the message-type byte followed immediately by
  /// the mapping loop. This mirrors node-oracledb's reference thin client
  /// exactly: `dataType.js` `DataTypeMessage.processMessage` (the single handler
  /// used by BOTH the FAST_AUTH and classical negotiations — see
  /// `fastAuth.js` `processMessage` dispatching `TNS_MSG_TYPE_DATA_TYPES` to it)
  /// reads only `readUInt16BE()` pairs until a 0 terminator AFTER the dispatcher
  /// has consumed the one-byte message type in `base.js` `process()`. There is
  /// no preamble or caps skip on the response side in the reference client, so
  /// adding one here would consume real mapping-loop bytes and desync the
  /// stream. Extracted from [_sendDataTypesNegotiation] so this node-oracledb
  /// parity invariant is pinned by a unit test and cannot silently regress.
  @visibleForTesting
  static void parseDataTypesResponse(Uint8List respData) {
    final respBuffer = ReadBuffer(respData);
    final msgType = respBuffer.readUint8();
    // Literal 2 (TNS_MSG_TYPE_DATA_TYPES): the named constant is exported by
    // two imported libraries here, so it is ambiguous unqualified — the encode
    // path uses the literal for the same reason.
    if (msgType != 2) {
      _log.warning('Unexpected data types response type: $msgType');
    }

    // Read and skip data type mappings until the 0x0000 terminator. No 5-byte
    // preamble and no caps blocks precede this loop (node-oracledb parity).
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
  }

  /// Encodes the classical-path DataTypes negotiation message body.
  ///
  /// Layout (matching node-oracledb `dataType.js` encode()):
  ///   - message type byte (`TNS_MSG_TYPE_DATA_TYPES` = 2)
  ///   - primary client charset, little-endian uint16 ([ttcCharsetUtf8])
  ///   - national charset slot, little-endian uint16 (also [ttcCharsetUtf8] —
  ///     national types are marked by the per-column csfrm byte, not this slot)
  ///   - encoding flags byte (MULTI_BYTE | CONV_LENGTH)
  ///   - length-prefixed compile caps, then length-prefixed runtime caps
  ///   - data type mappings (each 4×uint16BE), then a uint16BE terminator
  ///
  /// Extracted from [_sendDataTypesNegotiation] so the exact byte layout can be
  /// unit-tested without a live socket. The primary client character set is
  /// always [ttcCharsetUtf8] (AL32UTF8/UTF-8); the server converts to/from its
  /// database charset and no client-side codec is selected.
  @visibleForTesting
  Uint8List encodeDataTypesMessage(
    Uint8List compileCaps,
    Uint8List runtimeCaps,
  ) {
    final buffer = WriteBuffer();

    // Message type (TNS_MSG_TYPE_DATA_TYPES; named constant is ambiguous in
    // this library, so the literal matches the rest of the negotiation code).
    buffer.writeUint8(2);

    // Both charset slots are UTF-8 (node-oracledb dataType.js parity). The
    // national charset slot stays UTF-8: NCHAR/NVARCHAR2/NCLOB are marked by
    // the per-column csfrm byte (ttcCsfrmNChar), and their values travel
    // UTF-16BE — writing AL16UTF16 (2000) here would break negotiation.
    buffer.writeUint16LE(ttcCharsetUtf8); // primary client charset
    buffer.writeUint16LE(ttcCharsetUtf8); // national charset slot

    // Encoding flags
    buffer.writeUint8(0x01 | 0x02); // MULTI_BYTE | CONV_LENGTH

    // Compile caps (length-prefixed). The length prefix is a single byte, so a
    // cap vector longer than 255 bytes would silently truncate the prefix and
    // corrupt the DataTypes message on the wire (the server would read fewer
    // caps than were written and then misparse the runtime-caps block and the
    // data-type mappings). Fail loud instead. _buildCompileCapabilities()
    // currently produces 53 bytes, so this only fires on a future cap
    // expansion past the single-byte limit.
    _checkCapLengthFitsPrefix(compileCaps.length, 'compile');
    buffer.writeUint8(compileCaps.length);
    buffer.writeBytes(compileCaps);

    // Runtime caps (length-prefixed) — same single-byte prefix constraint.
    _checkCapLengthFitsPrefix(runtimeCaps.length, 'runtime');
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

    return buffer.toBytes();
  }

  /// Maximum value a single-byte (uint8) capability length prefix can hold.
  static const int _capLengthPrefixMax = 0xFF;

  /// Guards the single-byte length prefix that precedes each capability block
  /// in the DataTypes message. Oracle encodes the compile-/runtime-cap lengths
  /// as one byte each; a vector longer than 255 bytes would wrap the prefix and
  /// silently truncate the block, desyncing the rest of the message. Throw a
  /// clear protocol error rather than emit a corrupt handshake.
  static void _checkCapLengthFitsPrefix(int length, String which) {
    if (length > _capLengthPrefixMax) {
      throw OracleException(
        errorCode: oraProtocolError,
        message:
            'DataTypes $which capabilities are $length bytes but the wire '
            'length prefix is a single byte (max $_capLengthPrefixMax) — '
            'encoding it would truncate the prefix and corrupt the handshake. '
            'A cap-vector expansion past $_capLengthPrefixMax bytes requires a '
            'wider length prefix on both client and server.',
      );
    }
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

  /// Test seam exposing the real production compile-cap vector (the same bytes
  /// [encodeDataTypesMessage] sends on the wire) so the encoder can be unit
  /// tested with production-length caps, not synthetic short vectors.
  @visibleForTesting
  Uint8List debugBuildCompileCapabilities() => _buildCompileCapabilities();

  /// Test seam exposing the real production runtime-cap vector. See
  /// [debugBuildCompileCapabilities].
  @visibleForTesting
  Uint8List debugBuildRuntimeCapabilities() => _buildRuntimeCapabilities();

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

    // Field version (index 7) - the NEGOTIATED field version, not a literal.
    // Defaults to TNS_CCAP_FIELD_VERSION_MAX (24) but is clamped DOWN by
    // [_adjustFieldVersion] when the server advertises a lower value. Emitting
    // the clamped [_ttcFieldVersion] keeps the byte the client sends in sync
    // with what was negotiated, matching node-oracledb's capabilities.js
    // (`_init`: compileCaps[TNS_CCAP_FIELD_VERSION] = this.ttcFieldVersion, and
    // `adjustForServerCompileCaps` re-writes the same slot to the clamped value).
    caps[_ccapFieldVersion] = _ttcFieldVersion;

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
  /// DATA-flags contract (the default is intentionally version-gated, not
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

    // The negotiated SDU bounds the whole TNS packet: 8-byte header + 2-byte
    // data flags + payload. A TTC message larger than one packet's capacity
    // (e.g. a >32K CLOB-bound execute) is fragmented across
    // multiple DATA packets — node-oracledb's WritePacket sends a packet per
    // SDU with data flags 0x0000 and puts the request flags (END_OF_RPC on
    // 23ai) only on the final packet (packet.js `_sendPacket`).
    final capacity = _sdu - 10;
    var offset = 0;
    while (true) {
      final remaining = ttcData.length - offset;
      final chunkLen = remaining > capacity ? capacity : remaining;
      final isLast = offset + chunkLen >= ttcData.length;
      final flags = isLast ? dataFlags : 0x0000;
      final payload = Uint8List(2 + chunkLen);
      payload[0] = (flags >> 8) & 0xFF; // Data flags high byte (BE)
      payload[1] = flags & 0xFF; // Data flags low byte (BE)
      if (chunkLen > 0) {
        payload.setRange(2, payload.length, ttcData, offset);
      }
      await send(TnsPacket(type: tnsPacketData, payload: payload));
      offset += chunkLen;
      if (isLast) break;
    }
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
        'Received MARKER packet (${response.payload.length} bytes), reading next packet',
      );
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

/// Result of one [Transport.readLobRange] range read: the assembled payload
/// **bytes** plus the total **units** the server reported delivering.
///
/// The two counts are deliberately distinct (Story 12.3): a BLOB's units are
/// bytes, an NCLOB / variable-length-charset CLOB's units are half its byte
/// count (UTF-16BE), and a UTF-8-form CLOB has no fixed ratio at all — so a
/// caller that needs to reason about progress or truncation must use
/// [unitsRead], never `bytes.length`.
@internal
class LobRangeRead {
  /// Creates a range-read result.
  const LobRangeRead({required this.bytes, required this.unitsRead});

  /// The concatenated LOB_DATA payload bytes, undecoded (CLOB/NCLOB text is
  /// decoded ONCE by the caller over this whole buffer).
  final Uint8List bytes;

  /// Total units the server reported delivering across every piece — characters
  /// (UCS-2 code units) for CLOB/NCLOB, bytes for BLOB.
  final int unitsRead;
}
