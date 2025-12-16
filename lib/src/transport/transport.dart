import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../errors.dart';
import '../protocol/buffer.dart';
import '../protocol/messages/execute_message.dart';
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

  /// Whether the server supports end-of-request markers.
  /// Set after parsing ACCEPT packet flag2 field.
  bool _supportsEndOfRequest = false;

  /// TTC field version - adjusted after protocol negotiation.
  /// Used to determine whether token numbers should be written.
  /// TNS_CCAP_FIELD_VERSION_23_1_EXT_1 = 18 is threshold for token numbers.
  int _ttcFieldVersion = 24; // TNS_CCAP_FIELD_VERSION_MAX

  /// Returns true if auth messages should include token numbers.
  /// Token numbers are written when ttcFieldVersion >= 18.
  bool get shouldWriteTokenNumber => _ttcFieldVersion >= 18;

  /// Whether the transport is currently connected.
  bool get isConnected => _socket.isConnected;

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
  Future<ExecuteResponse> sendExecute(
    String sql, {
    List<dynamic>? bindValues,
    List<String>? bindNames,
    Duration? timeout = const Duration(minutes: 2),
  }) async {
    _log.fine('Sending execute request...');

    final request = ExecuteRequest(
      sql: sql,
      bindValues: bindValues,
      bindNames: bindNames,
    );
    final requestData = request.toBytes();

    final packet = TnsPacket(type: tnsPacketData, payload: requestData);
    await send(packet);

    // Receive response with optional timeout
    final Future<TnsPacket> receiveFuture = receive();
    final response = timeout != null
        ? await receiveFuture.timeout(
            timeout,
            onTimeout: () => throw OracleException(
              errorCode: oraConnectTimeout,
              message: 'Query timeout after ${timeout.inSeconds}s',
            ),
          )
        : await receiveFuture;

    if (response.type != tnsPacketData) {
      throw OracleException(
        errorCode: oraProtocolError,
        message: 'Unexpected response type: ${response.type}',
      );
    }

    return ExecuteResponse.decode(response.payload);
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

    // Wait for response with timeout
    // Note: onTimeout callback throws OracleException directly, no need
    // to catch TimeoutException separately
    final response = await receive().timeout(
      timeout,
      onTimeout: () => throw OracleException(
        errorCode: oraConnectTimeout,
        message:
            'Ping timeout after ${timeout.inSeconds}s - connection may be broken',
      ),
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
          _log.info('Negotiated version=${acceptInfo.version}, '
              'sdu=${acceptInfo.sdu}, largeSdu=$_useLargeSdu, '
              'endOfRequest=$_supportsEndOfRequest');

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

    // Step 1: Send protocol request
    final request = ProtocolRequest();
    final requestData = request.toBytes();
    await sendData(requestData);

    // Receive protocol response
    final ttcData = await receiveData();
    final protocolResponse = ProtocolResponse.decode(ttcData);
    _log.info('Protocol negotiation complete: '
        'serverVersion=${protocolResponse.serverVersion}');

    // Adjust ttcFieldVersion based on server compile caps
    _adjustFieldVersion(protocolResponse.compileCaps);

    // Step 2: Send data types negotiation (required before auth)
    await _sendDataTypesNegotiation(protocolResponse);

    return protocolResponse;
  }

  /// Sends protocol negotiation, data types negotiation, and AUTH_PHASE_ONE
  /// in a single batched TNS DATA packet (Oracle 23ai requirement).
  ///
  /// This is required for Oracle 23ai which expects these three messages
  /// to be sent together in one packet, not as separate packets.
  Future<ProtocolResponse> sendBatchedProtocolAndAuth(
      Uint8List authPhaseOneBytes) async {
    _log.info('Starting batched protocol negotiation with AUTH_PHASE_ONE');

    // Build protocol negotiation TTC message
    final protocolRequest = ProtocolRequest();
    final protocolBytes = protocolRequest.toBytes();
    _log.fine('Protocol message: ${protocolBytes.length} bytes');

    // Build data types negotiation TTC message
    final dataTypesBytes = _buildDataTypesMessage();
    _log.fine('Data types message: ${dataTypesBytes.length} bytes');
    _log.fine('AUTH_PHASE_ONE message: ${authPhaseOneBytes.length} bytes');

    // Concatenate all three TTC messages
    final batchedTtc = Uint8List(protocolBytes.length +
        dataTypesBytes.length +
        authPhaseOneBytes.length);
    var offset = 0;
    batchedTtc.setRange(offset, offset + protocolBytes.length, protocolBytes);
    offset += protocolBytes.length;
    batchedTtc.setRange(offset, offset + dataTypesBytes.length, dataTypesBytes);
    offset += dataTypesBytes.length;
    batchedTtc.setRange(
        offset, offset + authPhaseOneBytes.length, authPhaseOneBytes);

    _log.info('Sending batched handshake: ${batchedTtc.length} bytes total');

    // DEBUG: Save TTC batch to file for comparison with node-oracledb
    try {
      await _saveTtcBatchForDebug(batchedTtc);
    } catch (e) {
      _log.warning('Failed to save debug TTC batch: $e');
    }

    // Send batched message in single TNS DATA packet
    await sendData(batchedTtc);

    // Receive protocol response
    final protocolResponseData = await receiveData();
    final protocolResponse = ProtocolResponse.decode(protocolResponseData);
    _log.info('Protocol negotiation complete: '
        'serverVersion=${protocolResponse.serverVersion}');

    // Adjust ttcFieldVersion based on server compile caps
    _adjustFieldVersion(protocolResponse.compileCaps);

    // Receive data types response
    final dataTypesResponseData = await receiveData();
    _log.fine(
        'Received data types response: ${dataTypesResponseData.length} bytes');
    _log.info('Data types negotiation complete');

    // Auth response will be handled by auth module
    return protocolResponse;
  }

  /// Builds the data types negotiation TTC message without sending it.
  Uint8List _buildDataTypesMessage() {
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
    for (final dt in _dataTypes) {
      _writeDataTypeMapping(buffer, dt[0], dt[1], dt[2]);
    }

    // Terminator + padding (node-oracledb has extra padding)
    buffer.writeUint16BE(0); // Terminator (2 bytes)
    buffer.writeUint16BE(0x007f); // Padding (2 bytes)
    buffer.writeUint16BE(0x007f); // Padding (2 bytes)
    buffer.writeUint16BE(0x0001); // Padding (2 bytes)
    buffer.writeUint16BE(0); // Padding (2 bytes)
    buffer.writeUint16BE(0); // Additional padding (2 bytes) to match node

    return buffer.toBytes();
  }

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
    await sendData(requestData);

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
    [1, 1, 1], // VARCHAR
    [2, 2, 10], // NUMBER (ORACLE rep)
    [8, 8, 1], // LONG
    [12, 12, 10], // DATE (ORACLE rep)
    [23, 23, 1], // RAW
    [24, 24, 1], // LONG_RAW
    [25, 25, 1], // UB2
    [26, 26, 1], // UB4
    [27, 27, 10], // SB1 (ORACLE rep)
    [28, 28, 1], // SB2
    [29, 29, 1], // SB4
    [30, 30, 1], // SWORD
    [31, 31, 1], // UWORD
    [32, 32, 1], // PTRB
    [33, 33, 1], // PTRW
    [10, 10, 1], // TIDDEF
    [11, 11, 1], // ROWID
    [40, 40, 1], // AMS
    [41, 41, 1], // BRN
    [42, 42, 1], // CWD
    [290, 290, 1], // OER8
    [291, 291, 1], // FUN
    [292, 292, 1], // AUA
    [293, 293, 1], // RXH7
    [294, 294, 1], // NA6
    [298, 298, 1], // BRP
    [299, 299, 1], // BRV
    [300, 300, 1], // KVA
    [301, 301, 1], // CLS
    [302, 302, 1], // CUI
    [303, 303, 1], // DFN
    [304, 304, 1], // DQR
    [305, 305, 1], // DSC
    [306, 306, 1], // EXE
    [307, 307, 1], // FCH
    [308, 308, 1], // GBV
    [309, 309, 1], // GEM
    [310, 310, 1], // GIV
    [311, 311, 1], // OKG
    [312, 312, 1], // HMI
    [313, 313, 1], // INO
    [315, 315, 1], // LNF
    [316, 316, 1], // ONT
    [317, 317, 1], // OPE
    [318, 318, 1], // OSQ
    [319, 319, 1], // SFE
    [320, 320, 1], // SPF
    [321, 321, 1], // VSN
    [322, 322, 1], // UD7
    [323, 323, 1], // DSA
    [327, 327, 1], // PIN
    [328, 328, 1], // PFN
    [329, 329, 1], // PPT
    [331, 331, 1], // STO
    [333, 333, 1], // ARC
    [334, 334, 1], // MRS
    [335, 335, 1], // MRT
    [336, 336, 1], // MRG
    [337, 337, 1], // MRR
    [338, 338, 1], // MRC
    [339, 339, 1], // VER
    [340, 340, 1], // LON2
    [341, 341, 1], // INO2
    [342, 342, 1], // ALL
    [343, 343, 1], // UDB
    [344, 344, 1], // AQI
    [345, 345, 1], // ULB
    [346, 346, 1], // ULD
    [348, 348, 1], // SID
    [349, 349, 1], // NA7
    [354, 354, 1], // AL7
    [355, 355, 1], // K2RPC
    [359, 359, 1], // XDP
    [363, 363, 1], // OKO8
    [3, 2, 10], // BINARY_INTEGER -> NUMBER (ORACLE rep)
    [4, 2, 10], // FLOAT -> NUMBER (ORACLE rep)
    [5, 1, 1], // STR -> VARCHAR
    [6, 2, 10], // VNU -> NUMBER (ORACLE rep)
    [7, 2, 10], // PDN -> NUMBER (ORACLE rep)
    [9, 1, 1], // VCS -> VARCHAR
    [15, 1, 1], // VBI -> VARCHAR
    [39, 39, 1], // OAC9
    [68, 2, 10], // UIN -> NUMBER (ORACLE rep)
    [91, 2, 10], // SLS -> NUMBER (ORACLE rep)
    [94, 1, 1], // LVC -> VARCHAR
    [95, 23, 1], // LVB -> RAW
    [96, 96, 1], // CHAR
    [97, 96, 1], // AVC -> CHAR
    [100, 100, 1], // BINARY_FLOAT
    [101, 101, 1], // BINARY_DOUBLE
    [102, 102, 1], // CURSOR
    [104, 11, 1], // RDD -> ROWID
    [106, 106, 1], // OSL
    [108, 109, 1], // EXT_NAMED -> INT_NAMED
    [109, 109, 1], // INT_NAMED
    [110, 111, 1], // EXT_REF -> INT_REF
    [111, 111, 1], // INT_REF
    [112, 112, 1], // CLOB
    [113, 113, 1], // BLOB
    [114, 114, 1], // BFILE
    [115, 115, 1], // CFILE
    [116, 102, 1], // RSET -> CURSOR
    [119, 119, 1], // JSON
    [120, 120, 1], // DJSON
    [245, 245, 1], // CLV
    [156, 2, 10], // DTR -> NUMBER (ORACLE rep)
    [162, 2, 10], // DUN -> NUMBER (ORACLE rep)
    [163, 2, 10], // DOP -> NUMBER (ORACLE rep)
    [155, 1, 1], // VST -> VARCHAR
    [156, 12, 10], // ODT -> DATE (ORACLE rep)
    [167, 2, 10], // DOL -> NUMBER (ORACLE rep)
    [178, 178, 1], // TIME
    [179, 179, 1], // TIME_TZ
    [180, 180, 1], // TIMESTAMP
    [181, 181, 1], // TIMESTAMP_TZ
    [182, 182, 1], // INTERVAL_YM
    [183, 183, 1], // INTERVAL_DS
    [184, 12, 10], // EDATE -> DATE (ORACLE rep)
    [185, 185, 1], // ETIME
    [186, 186, 1], // ETTZ
    [187, 187, 1], // ESTAMP
    [188, 188, 1], // ESTZ
    [189, 189, 1], // EIYM
    [190, 190, 1], // EIDS
    [208, 112, 1], // DCLOB -> CLOB
    [209, 113, 1], // DBLOB -> BLOB
    [210, 114, 1], // DBFILE -> BFILE
    [104 + 256, 104 + 256, 1], // UROWID (360)
    [231, 231, 1], // TIMESTAMP_LTZ
    [232, 231, 1], // ESITZ -> TIMESTAMP_LTZ
    [266, 266, 1], // UB8
    [241, 109, 1], // PNTY -> INT_NAMED
    [252, 252, 1], // BOOLEAN
    // Auth and session types (critical for authentication)
    [406, 406, 1], // AUTH
    [165, 165, 1], // KVAL
    [289 + 256, 289 + 256, 1], // OAC122 (545)
    [364, 364, 1], // UD12
    [365, 365, 1], // AL8
    [366, 366, 1], // LFOP
    [367, 367, 1], // FCRT
    [368, 368, 1], // DNY
    [369, 369, 1], // OPR
    [370, 370, 1], // PLS
    [371, 371, 1], // XID
    [372, 372, 1], // TXN
    [373, 373, 1], // DCB
    [374, 374, 1], // CCA
    [375, 375, 1], // WRN
    [376, 376, 1], // TLH
    [377, 377, 1], // TOH
    [378, 378, 1], // FOI
    [379, 379, 1], // SID2
    [380, 380, 1], // TCH
    [381, 381, 1], // PII
    [382, 382, 1], // PFI
    [383, 383, 1], // PPU
    [384, 384, 1], // PTE
    [385, 385, 1], // RXH8
    [386, 386, 1], // N12
    [407, 407, 1], // FGI
    [408, 408, 1], // DSY
    [409, 409, 1], // DSYR8
    [410, 410, 1], // DSYH8
    [411, 411, 1], // DSYL
    [412, 412, 1], // DSYT8
    [413, 413, 1], // DSYV8
    [414, 414, 1], // DSYP
    [415, 415, 1], // DSYF
    [416, 416, 1], // DSYK
    [417, 417, 1], // DSYY
    [418, 418, 1], // DSYQ
    [419, 419, 1], // DSYC
    [420, 420, 1], // DSYA
    [421, 421, 1], // OT8
    [422, 422, 1], // DSYTY
    [423, 423, 1], // AQE
    [424, 424, 1], // KV
    [425, 425, 1], // AQD
    [426, 426, 1], // AQ8
    [427, 427, 1], // RFS
    [428, 428, 1], // RXH10
    [429, 429, 1], // KPN
    [430, 430, 1], // KPDNR
    [431, 431, 1], // DSYD
    [432, 432, 1], // DSYS
    [433, 433, 1], // DSYR
    [434, 434, 1], // DSYH
    [435, 435, 1], // DSYT
    [436, 436, 1], // DSYV
    [437, 437, 1], // AQM
    [438, 438, 1], // OER11
    [439, 439, 1], // AQL
    [440, 440, 1], // OTC
    [441, 441, 1], // KFNO
    [442, 442, 1], // KFNP
    [443, 443, 1], // KGT8
    [444, 444, 1], // RASB4
    [445, 445, 1], // RAUB2
    [446, 446, 1], // RAUB1
    [447, 447, 1], // RATXT
    [448, 448, 1], // RSSB4
    [449, 449, 1], // RSUB2
    [450, 450, 1], // RSUB1
    [451, 451, 1], // RSTXT
    [452, 452, 1], // RIDL
    [453, 453, 1], // GLRDD
    [454, 454, 1], // GLRDG
    [455, 455, 1], // GLRDC
    [456, 456, 1], // OKO
    [457, 457, 1], // DPP
    [458, 458, 1], // DPLS
    [459, 459, 1], // DPMOP
    [460, 460, 1], // STAT
    [461, 461, 1], // RFX
    [462, 462, 1], // FAL
    [463, 463, 1], // CKV
    [464, 464, 1], // DRCX
    [465, 465, 1], // KGH
    [466, 466, 1], // AQO
    [467, 467, 1], // OKGT
    [468, 468, 1], // KPFC
    [469, 469, 1], // FE2
    [470, 470, 1], // SPFP
    [471, 471, 1], // DPULS
    [472, 472, 1], // AQA
    [473, 473, 1], // KPBF
    [474, 474, 1], // TSM
    [475, 475, 1], // MSS
    [476, 476, 1], // KPC
    [477, 477, 1], // CRS
    [478, 478, 1], // KKS
    [479, 479, 1], // KSP
    [480, 480, 1], // KSPTOP
    [481, 481, 1], // KSPVAL
    [482, 482, 1], // PSS
    [483, 483, 1], // NLS
    [484, 484, 1], // ALS
    [485, 485, 1], // KSDEVTVAL
    [486, 486, 1], // KSDEVTTOP
    [487, 487, 1], // KPSPP
    [488, 488, 1], // KOL
    [489, 489, 1], // LST
    [490, 490, 1], // ACX
    [491, 491, 1], // SCS
    [492, 492, 1], // RXH
    [493, 493, 1], // KPDNS
    [494, 494, 1], // KPDCN
    [495, 495, 1], // KPNNS
    [496, 496, 1], // KPNCN
    [497, 497, 1], // KPS
    [498, 498, 1], // APINF
    [499, 499, 1], // TEN
    [500, 500, 1], // XSSCS
    [501, 501, 1], // XSSSO
    [502, 502, 1], // XSSAO
    [503, 503, 1], // KSRPC
    [504, 504, 1], // KVL
    [505, 505, 1], // XSSDEF
    [506, 506, 1], // PDQCINV
    [507, 507, 1], // PDQIDC
    [508, 508, 1], // KPDQCSTA
    [509, 509, 1], // KPRS
    [510, 510, 1], // KPDQIDC
    [511, 511, 1], // RTSTRM
    [512, 512, 1], // SESSGET
    [513, 513, 1], // SESSREL
    [514, 514, 1], // SESSRET
    [515, 515, 1], // SCN6
    [516, 516, 1], // KECPA
    [517, 517, 1], // KECPP
    [518, 518, 1], // SXA
    [519, 519, 1], // KVARR
    [520, 520, 1], // KPNGN
    [521, 521, 1], // XSNSOP
    [522, 522, 1], // XSATTR
    [523, 523, 1], // XSNS
    [524, 524, 1], // UB1ARRAY
    [525, 525, 1], // SESSSTATE
    [526, 526, 1], // AC_REPLAY
    [527, 527, 1], // AC_CONT
    [528, 528, 1], // IMPLRES
    [529, 529, 1], // OER19
    [530, 530, 1], // TXT
    [531, 531, 1], // XSSESSNS
    [532, 532, 1], // XSATTOP
    [533, 533, 1], // XSCREOP
    [534, 534, 1], // XSDETOP
    [535, 535, 1], // XSDESOP
    [536, 536, 1], // XSSETSP
    [537, 537, 1], // XSSIDP
    [538, 538, 1], // XSPRIN
    [539, 539, 1], // XSKVL
    [540, 540, 1], // XSSSDEF2
    [541, 541, 1], // XSNSOP2
    [542, 542, 1], // XSNS2
    [543, 543, 1], // KPDNREQ
    [544, 544, 1], // KPDNRNF
    [546, 546, 1], // KPNGNC
    [547, 547, 1], // KPNRI
    [548, 548, 1], // AQENQ
    [549, 549, 1], // AQDEQ
    [550, 550, 1], // AQJMS
    [551, 551, 1], // KPDNRPAY
    [552, 552, 1], // KPDNRACK
    [553, 553, 1], // KPDNRMP
    [554, 554, 1], // KPDNRDQ
    [555, 555, 1], // SCN
    [556, 556, 1], // SCN8
    [557, 557, 1], // CHUNKINFO
    [558, 558, 1], // UD21
    [559, 559, 1], // UDS
    [560, 560, 1], // TNP
    [561, 561, 1], // OER
    [562, 562, 1], // OAC
    [563, 563, 1], // SESSSIGN
    [564, 564, 1], // VECTOR
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

  /// Sends TTC data in a TNS DATA packet with proper data flags.
  ///
  /// TNS DATA packets have a 2-byte data flags field at the start of
  /// the payload, followed by the actual TTC message data.
  ///
  /// Note: Outgoing data flags are always 0. The END_OF_REQUEST/EOF flags
  /// are only used for checking incoming responses.
  Future<void> sendData(Uint8List ttcData, {int? dataFlags}) async {
    // Outgoing data flags are always 0 (node-oracledb startRequest defaults to 0)
    dataFlags ??= 0;

    // Build payload with 2-byte data flags prefix
    final payload = Uint8List(2 + ttcData.length);
    payload[0] = (dataFlags >> 8) & 0xFF; // Data flags high byte (BE)
    payload[1] = dataFlags & 0xFF; // Data flags low byte (BE)
    payload.setRange(2, payload.length, ttcData);

    final packet = TnsPacket(type: tnsPacketData, payload: payload);
    await send(packet);
  }

  /// Receives TTC data from a TNS DATA packet, stripping data flags.
  ///
  /// Returns the TTC message data with the 2-byte data flags prefix removed.
  Future<Uint8List> receiveData() async {
    final response = await receive();

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

  /// DEBUG: Saves TTC batch to file for byte-by-byte comparison with node-oracledb.
  Future<void> _saveTtcBatchForDebug(Uint8List ttcBatch) async {
    final file = File('dart_ttc_batch.bin');
    await file.writeAsBytes(ttcBatch);
    _log.info(
        'DEBUG: Saved TTC batch to ${file.path} (${ttcBatch.length} bytes)');

    // Also log first 100 bytes as hex for quick comparison
    final hexPreview = ttcBatch
        .sublist(0, ttcBatch.length < 100 ? ttcBatch.length : 100)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    _log.fine('First 100 bytes: $hexPreview');
  }
}
