/// Protocol state machine for TNS/TTC communication.
library;

import 'dart:async';
import 'dart:typed_data';

import 'dart:convert';

import '../constants.dart';
import '../crypto/auth.dart';
import '../cursor.dart';
import '../errors.dart';
import '../messages/auth_message.dart';
import '../messages/message.dart';
import '../transport/transport.dart';
import '../types.dart';
import 'capabilities.dart';
import 'tns_packet.dart';
import 'ttc_buffer.dart';

/// Protocol layer for Oracle TNS/TTC communication.
///
/// Handles connection establishment, protocol negotiation,
/// authentication, and message exchange.
class Protocol {
  Protocol(this._transport);

  final Transport _transport;

  /// TNS packet handler
  late final TnsPacketHandler _tns = TnsPacketHandler(_transport);

  /// TTC buffer for message encoding/decoding
  late final TtcBuffer _ttc = TtcBuffer();

  /// Client capabilities
  final ClientCapabilities clientCaps = ClientCapabilities();

  /// Server capabilities (populated during negotiation)
  ServerCapabilities? serverCaps;

  /// Session ID (assigned after authentication)
  // ignore: unused_field
  int? _sessionId;

  /// Protocol version negotiated (used during message processing)
  // ignore: unused_field
  int _protocolVersion = TnsConstants.protocolVersion;

  /// Whether connected
  bool _connected = false;

  /// Whether authenticated
  bool _authenticated = false;

  /// Whether connected and authenticated
  bool get isReady => _connected && _authenticated;

  /// Whether server supports Fast Auth (for debugging)
  bool get supportsFastAuth => _supportsFastAuth;

  /// Whether server supports end of response marker (for debugging)
  bool get supportsEndOfResponse => _supportsEndOfResponse;

  /// Send TNS Connect and receive Accept.
  Future<void> connect({
    String? serviceName,
    String? sid,
  }) async {
    // Build connect string
    final connectData = _buildConnectString(
      serviceName: serviceName,
      sid: sid,
    );

    // Send Connect packet
    await _tns.sendConnect(
      version: TnsConstants.tnsVersion,
      connectData: connectData,
    );

    // Receive response (Accept, Refuse, or Redirect)
    final response = await _tns.receivePacket();

    switch (response.type) {
      case TnsPacketType.accept:
        _connected = true;
        _parseAccept(response.data);

      case TnsPacketType.refuse:
        final reason = _parseRefuse(response.data);
        throw ConnectionError('Connection refused: $reason');

      case TnsPacketType.redirect:
        // TODO: Handle redirect to different host
        throw const ProtocolError('Redirect not yet implemented');

      default:
        throw ProtocolError.unexpectedResponse(
          'Accept/Refuse/Redirect',
          response.type.name,
        );
    }
  }

  /// Perform TTC protocol negotiation (TTIPRO and TTIDTY).
  ///
  /// Note: For servers supporting Fast Auth, use [negotiateAndAuthenticate] instead.
  Future<void> negotiate() async {
    if (!_connected) {
      throw const ProtocolError('Not connected');
    }

    if (_supportsFastAuth) {
      // Fast Auth servers require combined negotiate+authenticate
      throw const ProtocolError(
          'Server supports Fast Auth - use negotiateAndAuthenticate()');
    }

    // Send protocol negotiation (TTIPRO)
    await _sendProtocolNegotiation();

    // Receive protocol response
    final protoResponse = await _receiveDataMessage();
    _parseProtocolResponse(protoResponse);

    // Send data type negotiation (TTIDTY)
    await _sendDataTypeNegotiation();

    // Receive data type response
    final dtResponse = await _receiveDataMessage();
    _parseDataTypeResponse(dtResponse);
  }

  /// Combined negotiate and authenticate for Fast Auth servers.
  ///
  /// Oracle 23+ servers support Fast Auth which bundles protocol negotiation,
  /// data type negotiation, and authentication into a single message.
  Future<void> negotiateAndAuthenticate({
    required String user,
    required String password,
  }) async {
    if (!_connected) {
      throw const ProtocolError('Not connected');
    }

    if (_supportsFastAuth) {
      await _fastAuth(user: user, password: password);
    } else {
      // Fall back to traditional multi-step approach
      await negotiate();
      await authenticate(user: user, password: password);
    }
  }

  /// Authenticate with username and password.
  Future<void> authenticate({
    required String user,
    required String password,
  }) async {
    if (!_connected) {
      throw const ProtocolError('Not connected');
    }

    // Send OSESSKEY to get session key and auth parameters
    final (authType, authData) = await _requestSessionKey(user);

    // Perform authentication based on auth type
    switch (authType) {
      case AuthProtocol.o5logon:
        await _authenticateO5Logon(user, password, authData);
      case AuthProtocol.o7logon:
      case AuthProtocol.o8logon:
        await _authenticateO7O8Logon(user, password, authData, authType);
    }

    _authenticated = true;
  }

  /// Fast Auth - combined protocol, data types, and auth in one message.
  Future<void> _fastAuth({
    required String user,
    required String password,
  }) async {
    // Build Fast Auth message per python-oracledb/node-oracledb reference
    _ttc.clear();

    // Fast Auth header
    const tnsMsgTypeFastAuth = 0x22; // 34
    const tnsServerConvertsChars = 0x01;
    const tnsCcapFieldVersion191Ext1 = 13;
    _ttc.writeUint8(tnsMsgTypeFastAuth);
    _ttc.writeUint8(1); // Fast auth version
    _ttc.writeUint8(tnsServerConvertsChars); // Flag 1
    _ttc.writeUint8(0); // Flag 2

    // Embedded Protocol message
    _ttc.writeUint8(TtcMessageType.protocol.value); // 0x01
    _ttc.writeUint8(6); // Protocol version (8.1+)
    _ttc.writeUint8(0); // Array terminator
    _ttc.writeBytes(Uint8List.fromList(utf8.encode('dart-oracledb')));
    _ttc.writeUint8(0); // NULL terminator

    // Charset placeholders (unused by server but required)
    // Per node-oracledb fastAuth.js lines 53-57
    _ttc.writeUint16(0); // Server charset (big-endian)
    _ttc.writeUint8(0); // Server charset flag
    _ttc.writeUint16(0); // Server ncharset (big-endian)
    _ttc.writeUint8(tnsCcapFieldVersion191Ext1); // TTC field version

    // Embedded Data Types message
    _writeDataTypesMessage();

    // Embedded Auth message (session key request)
    _writeAuthMessage(user);

    final msgBytes = _ttc.toBytes();
    // Debug: print message hex dump
    print('Fast Auth message (${msgBytes.length} bytes):');
    print(msgBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' '));

    await _sendDataMessage(msgBytes);

    // Process Fast Auth response (contains protocol, data types, and auth responses)
    await _processFastAuthResponse(user, password);

    _authenticated = true;
  }

  /// Write Data Types message content to buffer.
  void _writeDataTypesMessage() {
    const tnsMsgTypeDataTypes = 0x02;
    const tnsCharsetUtf8 = 873;
    const tnsEncodingMultiByte = 0x01;
    const tnsEncodingConvLength = 0x02;

    _ttc.writeUint8(tnsMsgTypeDataTypes);

    // Character set info (little-endian per reference)
    _ttc.writeUint16LE(tnsCharsetUtf8);
    _ttc.writeUint16LE(tnsCharsetUtf8);

    // Encoding flags
    _ttc.writeUint8(tnsEncodingMultiByte | tnsEncodingConvLength);

    // Compile capabilities with length prefix
    final compileCaps = _buildCompileCapabilities();
    _ttc.writeUint8(compileCaps.length);
    _ttc.writeBytes(compileCaps);

    // Runtime capabilities with length prefix
    final runtimeCaps = _buildRuntimeCapabilities();
    _ttc.writeUint8(runtimeCaps.length);
    _ttc.writeBytes(runtimeCaps);

    // Data type definitions - full list per node-oracledb/python-oracledb
    // Each entry: [dataType, convDataType, representation, 0]
    for (final entry in _dataTypes) {
      _ttc.writeUint16(entry[0]);
      _ttc.writeUint16(entry[1]);
      _ttc.writeUint16(entry[2]);
      _ttc.writeUint16(0);
    }
    _ttc.writeUint16(0); // Terminator
  }

  /// Data types list per node-oracledb/python-oracledb reference.
  /// Format: [dataType, convDataType, representation]
  /// representation: 1 = UNIVERSAL, 10 = ORACLE
  static const _dataTypes = <List<int>>[
    // Core data types
    [1, 1, 1], // VARCHAR
    [2, 2, 10], // NUMBER
    [8, 8, 1], // LONG
    [12, 12, 10], // DATE
    [23, 23, 1], // RAW
    [24, 24, 1], // LONG RAW
    [25, 25, 1], // UB2
    [26, 26, 1], // UB4
    [27, 27, 10], // SB1
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
    [117, 117, 1], // CWD
    [120, 120, 1], // OAC122
    // Extended types
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
    [380, 380, 1], // UD12
    [381, 381, 1], // AL8
    [382, 382, 1], // LFOP
    [383, 383, 1], // FCRT
    [384, 384, 1], // DNY
    [385, 385, 1], // OPR
    [386, 386, 1], // PLS
    [387, 387, 1], // XID
    [388, 388, 1], // TXN
    [389, 389, 1], // DCB
    [390, 390, 1], // CCA
    [391, 391, 1], // WRN
    [393, 393, 1], // TLH
    [394, 394, 1], // TOH
    [395, 395, 1], // FOI
    [396, 396, 1], // SID2
    [397, 397, 1], // TCH
    [398, 398, 1], // PII
    [399, 399, 1], // PFI
    [400, 400, 1], // PPU
    [401, 401, 1], // PTE
    [404, 404, 1], // RXH8
    [405, 405, 1], // N12
    [406, 406, 1], // AUTH
    [407, 407, 1], // KVAL
    [413, 413, 1], // FGI
    [414, 414, 1], // DSY
    [415, 415, 1], // DSYR8
    [416, 416, 1], // DSYH8
    [417, 417, 1], // DSYL
    [418, 418, 1], // DSYT8
    [419, 419, 1], // DSYV8
    [420, 420, 1], // DSYP
    [421, 421, 1], // DSYF
    [422, 422, 1], // DSYK
    [423, 423, 1], // DSYY
    [424, 424, 1], // DSYQ
    [425, 425, 1], // DSYC
    [426, 426, 1], // DSYA
    [427, 427, 1], // OT8
    [429, 429, 1], // DSYTY
    [430, 430, 1], // AQE
    [431, 431, 1], // KV
    [432, 432, 1], // AQD
    [433, 433, 1], // AQ8
    [449, 449, 1], // RFS
    [450, 450, 1], // RXH10
    [454, 454, 1], // KPN
    [455, 455, 1], // KPDNR
    [456, 456, 1], // DSYD
    [457, 457, 1], // DSYS
    [458, 458, 1], // DSYR
    [459, 459, 1], // DSYH
    [460, 460, 1], // DSYT
    [461, 461, 1], // DSYV
    [462, 462, 1], // AQM
    [463, 463, 1], // OER11
    [466, 466, 1], // AQL
    [467, 467, 1], // OTC
    [468, 468, 1], // KFNO
    [469, 469, 1], // KFNP
    [470, 470, 1], // KGT8
    [471, 471, 1], // RASB4
    [472, 472, 1], // RAUB2
    [473, 473, 1], // RAUB1
    [474, 474, 1], // RATXT
    [475, 475, 1], // RSSB4
    [476, 476, 1], // RSUB2
    [477, 477, 1], // RSUB1
    [478, 478, 1], // RSTXT
    [479, 479, 1], // RIDL
    [480, 480, 1], // GLRDD
    [481, 481, 1], // GLRDG
    [482, 482, 1], // GLRDC
    [483, 483, 1], // OKO
    [484, 484, 1], // DPP
    [485, 485, 1], // DPLS
    [486, 486, 1], // DPMOP
    [490, 490, 1], // STAT
    [491, 491, 1], // RFX
    [492, 492, 1], // FAL
    [493, 493, 1], // CKV
    [494, 494, 1], // DRCX
    [495, 495, 1], // KGH
    [496, 496, 1], // AQO
    [498, 498, 1], // OKGT
    [499, 499, 1], // KPFC
    [500, 500, 1], // FE2
    [501, 501, 1], // SPFP
    [502, 502, 1], // DPULS
    [509, 509, 1], // AQA
    [510, 510, 1], // KPBF
    [513, 513, 1], // TSM
    [514, 514, 1], // MSS
    [516, 516, 1], // KPC
    [517, 517, 1], // CRS
    [518, 518, 1], // KKS
    [519, 519, 1], // KSP
    [520, 520, 1], // KSPTOP
    [521, 521, 1], // KSPVAL
    [522, 522, 1], // PSS
    [523, 523, 1], // NLS
    [524, 524, 1], // ALS
    [525, 525, 1], // KSDEVTVAL
    [526, 526, 1], // KSDEVTTOP
    [527, 527, 1], // KPSPP
    [528, 528, 1], // KOL
    [529, 529, 1], // LST
    [530, 530, 1], // ACX
    [531, 531, 1], // SCS
    [532, 532, 1], // RXH
    [533, 533, 1], // KPDNS
    [534, 534, 1], // KPDCN
    [535, 535, 1], // KPNNS
    [536, 536, 1], // KPNCN
    [537, 537, 1], // KPS
    [538, 538, 1], // APINF
    [539, 539, 1], // TEN
    [540, 540, 1], // XSSCS
    [541, 541, 1], // XSSSO
    [542, 542, 1], // XSSAO
    [543, 543, 1], // KSRPC
    [560, 560, 1], // KVL
    [565, 565, 1], // XSSDEF
    [572, 572, 1], // PDQCINV
    [573, 573, 1], // PDQIDC
    [574, 574, 1], // KPDQCSTA
    [575, 575, 1], // KPRS
    [576, 576, 1], // KPDQIDC
    [578, 578, 1], // RTSTRM
    [563, 563, 1], // SESSGET
    [564, 564, 1], // SESSREL
    [579, 579, 1], // SESSRET
    [580, 580, 1], // SCN6
    [581, 581, 1], // KECPA
    [582, 582, 1], // KECPP
    [583, 583, 1], // SXA
    [584, 584, 1], // KVARR
    [585, 585, 1], // KPNGN
    // Converted types
    [3, 2, 10], // BINARY_INTEGER -> NUMBER
    [4, 2, 10], // FLOAT -> NUMBER
    [5, 1, 1], // STR -> VARCHAR
    [6, 2, 10], // VNU -> NUMBER
    [7, 2, 10], // PDN -> NUMBER
    [9, 1, 1], // VCS -> VARCHAR
    [15, 1, 1], // VBI -> VARCHAR
    [39, 39, 1], // OAC9
    [68, 2, 10], // UIN -> NUMBER
    [91, 2, 10], // SLS -> NUMBER
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
    [198, 198, 1], // DJSON
    [146, 146, 1], // CLV
    [152, 2, 10], // DTR -> NUMBER
    [153, 2, 10], // DUN -> NUMBER
    [154, 2, 10], // DOP -> NUMBER
    [155, 1, 1], // VST -> VARCHAR
    [156, 12, 10], // ODT -> DATE
    [172, 2, 10], // DOL -> NUMBER
    [178, 178, 1], // TIME
    [179, 179, 1], // TIME_TZ
    [180, 180, 1], // TIMESTAMP
    [181, 181, 1], // TIMESTAMP_TZ
    [182, 182, 1], // INTERVAL_YM
    [183, 183, 1], // INTERVAL_DS
    [184, 12, 10], // EDATE -> DATE
    [185, 185, 1], // ETIME
    [186, 186, 1], // ETTZ
    [187, 187, 1], // ESTAMP
    [188, 188, 1], // ESTZ
    [189, 189, 1], // EIYM
    [190, 190, 1], // EIDS
    [195, 112, 1], // DCLOB -> CLOB
    [196, 113, 1], // DBLOB -> BLOB
    [197, 114, 1], // DBFILE -> BFILE
    [208, 208, 1], // UROWID
    [231, 231, 1], // TIMESTAMP_LTZ
    [232, 231, 1], // ESITZ -> TIMESTAMP_LTZ
    [233, 233, 1], // UB8
    [241, 109, 1], // PNTY -> INT_NAMED
    [252, 252, 1], // BOOLEAN
    [590, 590, 1], // XSNSOP
    [591, 591, 1], // XSATTR
    [592, 592, 1], // XSNS
    [613, 613, 1], // UB1ARRAY
    [614, 614, 1], // SESSSTATE
    [615, 615, 1], // AC_REPLAY
    [616, 616, 1], // AC_CONT
    [611, 611, 1], // IMPLRES
    [612, 612, 1], // OER19
    [593, 593, 1], // TXT
    [594, 594, 1], // XSSESSNS
    [595, 595, 1], // XSATTOP
    [596, 596, 1], // XSCREOP
    [597, 597, 1], // XSDETOP
    [598, 598, 1], // XSDESOP
    [599, 599, 1], // XSSETSP
    [600, 600, 1], // XSSIDP
    [601, 601, 1], // XSPRIN
    [602, 602, 1], // XSKVL
    [603, 603, 1], // XSSSDEF2
    [604, 604, 1], // XSNSOP2
    [605, 605, 1], // XSNS2
    [622, 622, 1], // KPDNREQ
    [623, 623, 1], // KPDNRNF
    [624, 624, 1], // KPNGNC
    [625, 625, 1], // KPNRI
    [626, 626, 1], // AQENQ
    [627, 627, 1], // AQDEQ
    [628, 628, 1], // AQJMS
    [629, 629, 1], // KPDNRPAY
    [630, 630, 1], // KPDNRACK
    [631, 631, 1], // KPDNRMP
    [632, 632, 1], // KPDNRDQ
    [637, 637, 1], // SCN
    [638, 638, 1], // SCN8
    [636, 636, 1], // CHUNKINFO
    [639, 639, 1], // UD21
    [663, 663, 1], // UDS
    [640, 640, 1], // TNP
    [652, 652, 1], // OER
    [646, 646, 1], // OAC
    [647, 647, 1], // SESSSIGN
    [127, 127, 1], // VECTOR
  ];

  /// Build compile capabilities byte array.
  Uint8List _buildCompileCapabilities() {
    // Simplified compile caps per python-oracledb
    const tnsCcapMax = 53;
    const tnsCcapSqlVersion = 0;
    const tnsCcapLogonTypes = 4;
    const tnsCcapFieldVersion = 7;
    const tnsCcapSqlVersionMax = 6;
    const tnsCcapFieldVersionMax = 24;
    const tnsCcapO5logon = 8;
    const tnsCcapO5logonNp = 2;
    const tnsCcapO7logon = 32;
    const tnsCcapO8logonLongId = 64;
    const tnsCcapO9logonLongPw = 0x80;

    final caps = Uint8List(tnsCcapMax);
    caps[tnsCcapSqlVersion] = tnsCcapSqlVersionMax;
    caps[tnsCcapLogonTypes] = tnsCcapO5logon |
        tnsCcapO5logonNp |
        tnsCcapO7logon |
        tnsCcapO8logonLongId |
        tnsCcapO9logonLongPw;
    caps[tnsCcapFieldVersion] = tnsCcapFieldVersionMax;
    return caps;
  }

  /// Build runtime capabilities byte array.
  Uint8List _buildRuntimeCapabilities() {
    // Simplified runtime caps
    const tnsRcapMax = 11;
    const tnsRcapCompat = 0;
    const tnsRcapCompat81 = 2;

    final caps = Uint8List(tnsRcapMax);
    caps[tnsRcapCompat] = tnsRcapCompat81;
    return caps;
  }

  /// Write Auth message for session key request.
  void _writeAuthMessage(String user) {
    // This writes an OSESSKEY request embedded in Fast Auth
    _ttc.writeUint8(TtcMessageType.function.value); // 0x03
    _ttc.writeUint8(OpiFunction.sessionKey.value); // 0x76
    // User as length-prefixed string
    final userBytes = utf8.encode(user.toUpperCase());
    _ttc.writeUint8(userBytes.length);
    _ttc.writeBytes(Uint8List.fromList(userBytes));
  }

  /// Process Fast Auth response.
  Future<void> _processFastAuthResponse(String user, String password) async {
    // Fast Auth response contains multiple messages
    final response = await _receiveDataMessage();

    // Parse the response - it should contain protocol, data types, and auth info
    final buffer = TtcBuffer();
    buffer.load(response);

    // Process messages in response
    while (!buffer.atEnd) {
      final msgType = buffer.readUint8();

      switch (msgType) {
        case 0x01: // Protocol response
          _parseProtocolResponseFromBuffer(buffer);
        case 0x02: // Data types response
          _parseDataTypesResponseFromBuffer(buffer);
        case 0x08: // Return parameter (auth response)
          final authInfo = _parseAuthResponseFromBuffer(buffer);
          // Complete authentication with the returned session key
          await _completeAuthentication(user, password, authInfo);
        case 0x04: // Error
          final errorCode = buffer.readUint16();
          final errorMsg = buffer.readClrString() ?? 'Unknown error';
          throw AuthenticationError(errorMsg, errorCode);
        default:
          // Skip unknown message types
          break;
      }
    }
  }

  void _parseProtocolResponseFromBuffer(TtcBuffer buffer) {
    _protocolVersion = buffer.readUint8();
    // Skip remaining protocol data
    buffer.readUint8(); // Zero byte
    buffer.readClrString(); // Server banner
  }

  void _parseDataTypesResponseFromBuffer(TtcBuffer buffer) {
    // Skip data types response
    while (!buffer.atEnd) {
      final dataType = buffer.readUint16();
      if (dataType == 0) break;
      buffer.readUint16(); // Conv data type
      if (buffer.peek() != 0) {
        buffer.skip(4);
      }
    }
  }

  Map<String, dynamic> _parseAuthResponseFromBuffer(TtcBuffer buffer) {
    // Parse session key response
    // This is simplified - actual implementation needs more work
    return <String, dynamic>{};
  }

  Future<void> _completeAuthentication(
    String user,
    String password,
    Map<String, dynamic> authInfo,
  ) async {
    // Send follow-up auth message if needed
    // For now, just mark as authenticated
  }

  /// Request session key from server.
  Future<(AuthProtocol, Map<String, dynamic>)> _requestSessionKey(
    String user,
  ) async {
    // Build OSESSKEY message
    _ttc.clear();
    _ttc.writeUint8(TtcMessageType.function.value);
    _ttc.writeUint8(OpiFunction.sessionKey.value);
    _ttc.writeString(user.toUpperCase());

    await _sendDataMessage(_ttc.toBytes());

    // Parse response to determine auth protocol
    final response = await _receiveDataMessage();
    return _parseSessionKeyResponse(response);
  }

  /// Execute SQL statement.
  Future<ResultSet> execute({
    required String sql,
    Object? params,
    int fetchSize = 100,
    FetchMode fetchMode = FetchMode.list,
  }) async {
    if (!isReady) {
      throw const ProtocolError('Not connected or authenticated');
    }

    // Build OALL8 bundled call
    _ttc.clear();
    _ttc.writeUint8(TtcMessageType.function.value);
    _ttc.writeUint8(OpiFunction.bundledCall.value);

    // Options: PARSE | EXECUTE | FETCH
    const options =
        OAll8Options.parse | OAll8Options.execute | OAll8Options.fetch;
    _ttc.writeUint32(options);

    // Cursor ID (0 for new cursor)
    _ttc.writeUint32(0);

    // SQL text
    _ttc.writeClrString(sql);

    // Bind parameters
    _encodeBindParams(params);

    // Fetch size
    _ttc.writeUint32(fetchSize);

    await _sendDataMessage(_ttc.toBytes());

    // Process response
    final result = await _processExecuteResponse(fetchMode);
    return result;
  }

  /// Execute multiple statements in batch.
  Future<int> executeMany({
    required String sql,
    required List<Object> paramsList,
    int batchSize = 100,
  }) async {
    if (!isReady) {
      throw const ProtocolError('Not connected or authenticated');
    }

    var totalAffected = 0;

    // Process in batches
    for (var i = 0; i < paramsList.length; i += batchSize) {
      final end = (i + batchSize).clamp(0, paramsList.length);
      final batch = paramsList.sublist(i, end);

      // Build batch execute message
      _ttc.clear();
      _ttc.writeUint8(TtcMessageType.function.value);
      _ttc.writeUint8(OpiFunction.bundledCall.value);

      // Options: PARSE | BIND | EXECUTE
      const options =
          OAll8Options.parse | OAll8Options.bind | OAll8Options.execute;
      _ttc.writeUint32(options);

      // Cursor ID
      _ttc.writeUint32(0);

      // SQL text
      _ttc.writeClrString(sql);

      // Batch parameters
      _ttc.writeUint32(batch.length);
      for (final params in batch) {
        _encodeBindParams(params);
      }

      await _sendDataMessage(_ttc.toBytes());

      // Get affected count
      final response = await _receiveDataMessage();
      totalAffected += _parseRowsAffected(response);
    }

    return totalAffected;
  }

  /// Execute PL/SQL block.
  Future<Map<String, dynamic>> executePlSql({
    required String plsql,
    Map<String, dynamic>? params,
  }) async {
    if (!isReady) {
      throw const ProtocolError('Not connected or authenticated');
    }

    // Build OALL8 for PL/SQL
    _ttc.clear();
    _ttc.writeUint8(TtcMessageType.function.value);
    _ttc.writeUint8(OpiFunction.bundledCall.value);

    // Options: PARSE | BIND | EXECUTE
    const options =
        OAll8Options.parse | OAll8Options.bind | OAll8Options.execute;
    _ttc.writeUint32(options);

    // Cursor ID
    _ttc.writeUint32(0);

    // PL/SQL text
    _ttc.writeClrString(plsql);

    // Bind parameters with IN/OUT directions
    if (params != null) {
      _encodePlSqlParams(params);
    }

    await _sendDataMessage(_ttc.toBytes());

    // Process response and extract OUT values
    final response = await _receiveDataMessage();
    return _parsePlSqlResponse(response, params);
  }

  /// Commit current transaction.
  Future<void> commit() async {
    if (!isReady) {
      throw const ProtocolError('Not connected or authenticated');
    }

    _ttc.clear();
    _ttc.writeUint8(TtcMessageType.function.value);
    _ttc.writeUint8(OpiFunction.commit.value);

    await _sendDataMessage(_ttc.toBytes());

    final response = await _receiveDataMessage();
    _checkStatus(response);
  }

  /// Rollback current transaction.
  Future<void> rollback() async {
    if (!isReady) {
      throw const ProtocolError('Not connected or authenticated');
    }

    _ttc.clear();
    _ttc.writeUint8(TtcMessageType.function.value);
    _ttc.writeUint8(OpiFunction.rollback.value);

    await _sendDataMessage(_ttc.toBytes());

    final response = await _receiveDataMessage();
    _checkStatus(response);
  }

  /// Ping the database.
  Future<void> ping() async {
    if (!isReady) {
      throw const ProtocolError('Not connected or authenticated');
    }

    _ttc.clear();
    _ttc.writeUint8(TtcMessageType.function.value);
    _ttc.writeUint8(OpiFunction.ping.value);

    await _sendDataMessage(_ttc.toBytes());

    final response = await _receiveDataMessage();
    _checkStatus(response);
  }

  /// Log off from database.
  Future<void> logoff() async {
    if (!_connected) return;

    try {
      _ttc.clear();
      _ttc.writeUint8(TtcMessageType.function.value);
      _ttc.writeUint8(OpiFunction.logoff.value);

      await _sendDataMessage(_ttc.toBytes());
      await _receiveDataMessage();
    } catch (_) {
      // Ignore logoff errors
    }

    _connected = false;
    _authenticated = false;
  }

  // =========================================================================
  // Private helper methods
  // =========================================================================

  String _buildConnectString({String? serviceName, String? sid}) {
    final buffer = StringBuffer()
      ..write('(DESCRIPTION=')
      ..write('(ADDRESS=(PROTOCOL=TCP)')
      ..write('(HOST=${_transport.remoteAddress.host})')
      ..write('(PORT=${_transport.remotePort}))')
      ..write('(CONNECT_DATA=');

    if (serviceName != null) {
      buffer.write('(SERVICE_NAME=$serviceName)');
    } else if (sid != null) {
      buffer.write('(SID=$sid)');
    }

    buffer
      ..write('(CID=(PROGRAM=dart-oracledb)')
      ..write('(HOST=${_transport.localAddress.host})')
      ..write('(USER=dart))))');

    return buffer.toString();
  }

  /// Whether server supports Fast Auth (Oracle 23+)
  bool _supportsFastAuth = false;

  /// Whether server supports end of response marker
  bool _supportsEndOfResponse = false;

  void _parseAccept(Uint8List data) {
    // Parse Accept packet per python-oracledb reference (connect.pyx):
    // - Bytes 0-1: Protocol version (big-endian)
    // - Bytes 2-3: Protocol options (big-endian)
    // - Bytes 4-13: Skip 10 bytes
    // - Byte 14: flags1
    // - Bytes 15-23: Skip 9 bytes
    // - Bytes 24-27: SDU (big-endian)
    // - If protocol >= 318:
    //   - Bytes 28-32: Skip 5 bytes
    //   - Bytes 33-36: flags2 (big-endian) - contains FAST_AUTH flag

    if (data.length < 28) return;

    final view = ByteData.sublistView(data);
    final protocolVersion = view.getUint16(0, Endian.big);
    // final protocolOptions = view.getUint16(2, Endian.big);
    // flags1 at byte 14

    // SDU at bytes 24-27
    final sdu = view.getUint32(24, Endian.big);
    if (sdu > 0) {
      _tns.sdu = sdu;
      _tns.tdu = sdu;
    }

    // Check for Fast Auth support (protocol >= 318)
    const tnsVersionMinOobCheck = 318;
    const tnsVersionMinEndOfResponse = 319;
    const tnsAcceptFlagFastAuth = 0x10000000;
    const tnsAcceptFlagEndOfResponse = 0x02000000;

    if (protocolVersion >= tnsVersionMinOobCheck && data.length >= 37) {
      // flags2 at bytes 33-36 (after skipping 5 bytes from byte 28)
      final flags2 = view.getUint32(33, Endian.big);
      _supportsFastAuth = (flags2 & tnsAcceptFlagFastAuth) != 0;
      _supportsEndOfResponse = (flags2 & tnsAcceptFlagEndOfResponse) != 0;
    }

    if (protocolVersion >= tnsVersionMinEndOfResponse) {
      _supportsEndOfResponse = true;
    }
  }

  String _parseRefuse(Uint8List data) {
    // Parse Refuse packet to get error reason
    // Refuse packet format:
    // - Byte 0: User reason
    // - Byte 1: System reason
    // - Bytes 2-3: Data length
    // - Remaining: Error message

    if (data.isEmpty) {
      return 'Connection refused (no details)';
    }

    final userReason = data[0];
    final systemReason = data.length > 1 ? data[1] : 0;

    // Try to extract error message
    if (data.length > 4) {
      final msgLength = (data[2] << 8) | data[3];
      if (data.length >= 4 + msgLength) {
        final msgBytes = data.sublist(4, 4 + msgLength);
        final message = utf8.decode(msgBytes, allowMalformed: true);
        return message.isNotEmpty
            ? message
            : 'User reason: $userReason, System reason: $systemReason';
      }
    }

    // Map common refuse reasons
    switch (userReason) {
      case 1:
        return 'Service not available';
      case 2:
        return 'Invalid service name';
      case 3:
        return 'Invalid SID';
      case 4:
        return 'No listener';
      case 9:
        return 'Service name not found (ORA-12514)';
      case 12:
        return 'TNS: listener does not know of service (ORA-12514)';
      default:
        return 'User reason: $userReason, System reason: $systemReason';
    }
  }

  Future<void> _sendDataMessage(Uint8List data) async {
    await _tns.sendData(data);
  }

  Future<Uint8List> _receiveDataMessage() async {
    final packet = await _tns.receivePacket();
    if (packet.type != TnsPacketType.data) {
      throw ProtocolError.unexpectedResponse('Data', packet.type.name);
    }
    return packet.data;
  }

  Future<void> _sendProtocolNegotiation() async {
    // Protocol message format (per python-oracledb reference):
    // - Message type (TNS_MSG_TYPE_PROTOCOL = 0x01)
    // - Protocol version (6 for Oracle 8.1+)
    // - Array terminator (0)
    // - Driver name as raw UTF-8 bytes
    // - NULL terminator (0)
    _ttc.clear();
    _ttc.writeUint8(TtcMessageType.protocol.value); // 0x01
    _ttc.writeUint8(6); // Protocol version (8.1 and higher)
    _ttc.writeUint8(0); // Array terminator
    _ttc.writeBytes(Uint8List.fromList(utf8.encode('dart-oracledb')));
    _ttc.writeUint8(0); // NULL terminator
    await _sendDataMessage(_ttc.toBytes());
  }

  void _parseProtocolResponse(Uint8List data) {
    // Parse TTIPRO response
    if (data.isNotEmpty && data[0] == TtcMessageType.protocol.value) {
      _protocolVersion = data[1];
    }
  }

  Future<void> _sendDataTypeNegotiation() async {
    _ttc.clear();
    _ttc.writeUint8(TtcMessageType.dataTypes.value);
    // Write data type mappings
    await _sendDataMessage(_ttc.toBytes());
  }

  void _parseDataTypeResponse(Uint8List data) {
    // Parse TTIDTY response
    // Store character set information
  }

  (AuthProtocol, Map<String, dynamic>) _parseSessionKeyResponse(
      Uint8List data) {
    // Parse AUTH_SESSKEY response using SessionKeyResponse decoder
    final buffer = TtcBuffer();
    buffer.load(data);

    // Skip message type byte if present
    if (!buffer.atEnd && buffer.peek() == TtcMessageType.function.value) {
      buffer.skip(1);
    }

    final response = SessionKeyResponse.decode(buffer);

    return (
      response.authProtocol,
      <String, dynamic>{
        'sessionKey': response.sessionKey,
        'salt': response.salt,
        'iterations': response.iterations,
        'speedyKey': response.speedyKey,
      }
    );
  }

  Future<void> _authenticateO5Logon(
    String user,
    String password,
    Map<String, dynamic> authData,
  ) async {
    final authenticator = OracleAuthenticator();

    final sessionKey = authData['sessionKey'] as Uint8List;
    final salt = authData['salt'] as Uint8List;

    // Generate auth and session tokens using SHA1-based authentication
    final (authToken, sessionToken) = authenticator.authenticateO5Logon(
      password: password,
      encryptedSessionKey: sessionKey,
      salt: salt,
    );

    // Send authentication request
    final authRequest = AuthRequest(
      username: user,
      authToken: authToken,
      sessionToken: sessionToken,
    );

    await _sendDataMessage(authRequest.encode());

    // Process authentication response
    final response = await _receiveDataMessage();
    final buffer = TtcBuffer();
    buffer.load(response);

    final authResponse = AuthResponse.decode(buffer);

    if (!authResponse.success) {
      throw AuthenticationError(
        authResponse.errorMessage ?? 'Authentication failed',
        authResponse.errorCode,
      );
    }

    _sessionId = authResponse.sessionId;
  }

  Future<void> _authenticateO7O8Logon(
    String user,
    String password,
    Map<String, dynamic> authData,
    AuthProtocol authType,
  ) async {
    final authenticator = OracleAuthenticator();

    final salt = authData['salt'] as Uint8List;
    final iterations = authData['iterations'] as int? ?? 4096;
    final speedyKey = authData['speedyKey'] as Uint8List?;

    // Generate auth and session tokens using PBKDF2-SHA512 authentication
    final (authToken, sessionToken) = authenticator.authenticateO7O8Logon(
      password: password,
      salt: salt,
      iterations: iterations,
      speedyKey: speedyKey,
      protocol: authType,
    );

    // Send authentication request
    final authRequest = AuthRequest(
      username: user,
      authToken: authToken,
      sessionToken: sessionToken,
    );

    await _sendDataMessage(authRequest.encode());

    // Process authentication response
    final response = await _receiveDataMessage();
    final buffer = TtcBuffer();
    buffer.load(response);

    final authResponse = AuthResponse.decode(buffer);

    if (!authResponse.success) {
      throw AuthenticationError(
        authResponse.errorMessage ?? 'Authentication failed',
        authResponse.errorCode,
      );
    }

    _sessionId = authResponse.sessionId;
  }

  void _encodeBindParams(Object? params) {
    if (params == null) {
      _ttc.writeUint32(0); // No parameters
      return;
    }

    if (params is List) {
      _ttc.writeUint32(params.length);
      for (final param in params) {
        _encodeValue(param);
      }
    } else if (params is Map<String, dynamic>) {
      _ttc.writeUint32(params.length);
      for (final entry in params.entries) {
        _ttc.writeString(entry.key);
        _encodeValue(entry.value);
      }
    }
  }

  void _encodePlSqlParams(Map<String, dynamic> params) {
    _ttc.writeUint32(params.length);
    for (final entry in params.entries) {
      _ttc.writeString(entry.key);
      final value = entry.value;
      if (value is ({
        OracleType type,
        BindDirection direction,
        dynamic value
      })) {
        _ttc.writeUint8(value.direction.index);
        _ttc.writeUint8(value.type.value);
        _encodeValue(value.value);
      } else {
        _ttc.writeUint8(BindDirection.input.index);
        _encodeValue(value);
      }
    }
  }

  void _encodeValue(dynamic value) {
    if (value == null) {
      _ttc.writeNull();
      return;
    }

    switch (value) {
      case int v:
        // Encode as Oracle NUMBER
        final oraNum = OracleNumber.fromInt(v);
        _ttc.writeClr(oraNum.toBytes());

      case double v:
        // Encode as Oracle NUMBER
        final oraNum = OracleNumber.fromDouble(v);
        _ttc.writeClr(oraNum.toBytes());

      case String v:
        // Encode as VARCHAR2 using CLR encoding
        _ttc.writeClr(Uint8List.fromList(utf8.encode(v)));

      case DateTime v:
        // Encode as Oracle DATE (7 bytes)
        final oraDate = OracleDate(v);
        _ttc.writeClr(oraDate.toBytes());

      case bool v:
        // PL/SQL BOOLEAN: 1 for true, 0 for false
        _ttc.writeClr(Uint8List.fromList([v ? 1 : 0]));

      case Uint8List v:
        // RAW data - pass through as CLR
        _ttc.writeClr(v);

      case List<int> v:
        // Convert to Uint8List for RAW
        _ttc.writeClr(Uint8List.fromList(v));

      case OracleNumber v:
        _ttc.writeClr(v.toBytes());

      case OracleDate v:
        _ttc.writeClr(v.toBytes());

      case OracleTimestampTZ v:
        _ttc.writeClr(v.toBytes());

      case OracleTimestamp v:
        _ttc.writeClr(v.toBytes());

      case OracleRowId v:
        _ttc.writeClr(v.toBytes());

      case OracleInterval v:
        // Encode INTERVAL - simplified for YEAR TO MONTH
        final bytes = Uint8List(5);
        final totalMonths = v.totalMonths;
        bytes[0] = ((totalMonths >> 24) & 0xFF) ^ 0x80; // Sign bit
        bytes[1] = (totalMonths >> 16) & 0xFF;
        bytes[2] = (totalMonths >> 8) & 0xFF;
        bytes[3] = totalMonths & 0xFF;
        bytes[4] = 0x3C; // 60 for months offset
        _ttc.writeClr(bytes);

      case Map<String, dynamic> v:
        // JSON object - encode as string
        final jsonStr = _encodeJson(v);
        _ttc.writeClr(Uint8List.fromList(utf8.encode(jsonStr)));

      case List<dynamic> v:
        // JSON array - encode as string
        final jsonStr = _encodeJson(v);
        _ttc.writeClr(Uint8List.fromList(utf8.encode(jsonStr)));

      default:
        // Try toString() as fallback
        final str = value.toString();
        _ttc.writeClr(Uint8List.fromList(utf8.encode(str)));
    }
  }

  String _encodeJson(Object? value) {
    // Simple JSON encoder - could use dart:convert for complex cases
    if (value == null) {
      return 'null';
    } else if (value is Map) {
      final pairs = value.entries
          .map((e) => '"${e.key}":${_encodeJson(e.value as Object?)}')
          .join(',');
      return '{$pairs}';
    } else if (value is List) {
      final items = value.map((e) => _encodeJson(e as Object?)).join(',');
      return '[$items]';
    } else if (value is String) {
      return '"${value.replaceAll('"', '\\"')}"';
    } else {
      return value.toString();
    }
  }

  Future<ResultSet> _processExecuteResponse(FetchMode fetchMode) async {
    final columns = <ColumnMetadata>[];
    final rows = <List<dynamic>>[];
    var rowsAffected = 0;
    String? lastRowId;

    // Process response messages until we get status or error
    var done = false;
    while (!done) {
      final response = await _receiveDataMessage();
      final message = Message.decode(response);

      switch (message) {
        case ErrorMessage msg:
          throw OracleError(msg.errorMessage, msg.errorCode);

        case StatusMessage msg:
          rowsAffected = msg.rowsAffected;
          lastRowId = msg.lastRowId;
          done = true;

        case RowHeaderMessage msg:
          // Convert column definitions to metadata
          columns.clear();
          for (final col in msg.columns) {
            columns.add(ColumnMetadata(
              name: col.name,
              type: OracleType.fromValue(col.typeCode) ?? OracleType.varchar2,
              size: col.size,
              precision: col.precision,
              scale: col.scale,
              nullable: col.nullable,
            ));
          }

        case RowDataMessage msg:
          // Decode row values based on column types
          final row = <dynamic>[];
          for (var i = 0; i < msg.values.length && i < columns.length; i++) {
            final bytes = msg.values[i];
            final colType = columns[i].type;
            row.add(_decodeValue(bytes, colType));
          }
          rows.add(row);

          if (msg.isLastRow) {
            done = true;
          }

        case RawMessage _:
          // Unknown message type - continue processing
          break;
      }
    }

    return ResultSet(
      columns: columns,
      rows: rows,
      rowsAffected: rowsAffected,
      lastRowId: lastRowId,
    );
  }

  /// Decode a value from Oracle wire format to Dart type.
  dynamic _decodeValue(Uint8List? bytes, OracleType type) {
    if (bytes == null || bytes.isEmpty) {
      return null;
    }

    switch (type) {
      case OracleType.number:
      case OracleType.integer:
      case OracleType.float:
      case OracleType.varnum:
        final oraNum = OracleNumber.fromBytes(bytes);
        // Return as int if it's a whole number, otherwise as double
        final dec = oraNum.toDecimal();
        if (dec.scale == 0) {
          return oraNum.toInt();
        }
        return oraNum.toDouble();

      case OracleType.binaryFloat:
        // IEEE 754 single-precision float
        final bd = ByteData.sublistView(bytes);
        return bd.getFloat32(0, Endian.big);

      case OracleType.binaryDouble:
        // IEEE 754 double-precision float
        final bd = ByteData.sublistView(bytes);
        return bd.getFloat64(0, Endian.big);

      case OracleType.varchar2:
      case OracleType.varchar:
      case OracleType.char:
      case OracleType.nchar:
      case OracleType.string:
      case OracleType.long:
        return utf8.decode(bytes);

      case OracleType.date:
        return OracleDate.fromBytes(bytes).dateTime;

      case OracleType.timestamp:
        return OracleTimestamp.fromBytes(bytes).dateTime;

      case OracleType.timestampTZ:
      case OracleType.timestampLTZ:
        final ts = OracleTimestampTZ.fromBytes(bytes);
        return ts.dateTime;

      case OracleType.raw:
      case OracleType.longRaw:
      case OracleType.blob:
        return bytes;

      case OracleType.clob:
      case OracleType.nclob:
        return utf8.decode(bytes);

      case OracleType.rowid:
      case OracleType.urowid:
      case OracleType.rowIdDescriptor:
        return OracleRowId.fromBytes(bytes).value;

      case OracleType.json:
        return utf8.decode(bytes);

      case OracleType.plsqlBoolean:
        return bytes.isNotEmpty && bytes[0] != 0;

      case OracleType.intervalYM:
        // INTERVAL YEAR TO MONTH: 5 bytes
        if (bytes.length >= 5) {
          final years = ((bytes[0] ^ 0x80) << 24) |
              (bytes[1] << 16) |
              (bytes[2] << 8) |
              bytes[3];
          final months = bytes[4] - 60;
          return OracleInterval(years: years, months: months);
        }
        return null;

      case OracleType.intervalDS:
        // INTERVAL DAY TO SECOND: 11 bytes
        if (bytes.length >= 11) {
          final days = ((bytes[0] ^ 0x80) << 24) |
              (bytes[1] << 16) |
              (bytes[2] << 8) |
              bytes[3];
          final hours = bytes[4] - 60;
          final minutes = bytes[5] - 60;
          final seconds = bytes[6] - 60;
          final nanos = ((bytes[7] ^ 0x80) << 24) |
              (bytes[8] << 16) |
              (bytes[9] << 8) |
              bytes[10];
          return OracleInterval(
            days: days,
            hours: hours,
            minutes: minutes,
            seconds: seconds,
            nanoseconds: nanos,
          );
        }
        return null;

      case OracleType.cursor:
        // REF CURSOR - return as-is for now
        return bytes;

      case OracleType.bfile:
      case OracleType.xmlType:
      case OracleType.vector:
      case OracleType.unsignedInt:
        // Return raw bytes for unsupported types
        return bytes;
    }
  }

  int _parseRowsAffected(Uint8List data) {
    final message = Message.decode(data);

    switch (message) {
      case ErrorMessage msg:
        throw OracleError(msg.errorMessage, msg.errorCode);

      case StatusMessage msg:
        return msg.rowsAffected;

      default:
        return 0;
    }
  }

  Map<String, dynamic> _parsePlSqlResponse(
    Uint8List data,
    Map<String, dynamic>? params,
  ) {
    final result = <String, dynamic>{};
    final message = Message.decode(data);

    switch (message) {
      case ErrorMessage msg:
        throw OracleError(msg.errorMessage, msg.errorCode);

      case StatusMessage _:
        // No OUT parameters, return empty result
        break;

      case RawMessage msg:
        // Parse OUT parameters from raw response
        // The response contains parameter values in order
        if (params != null) {
          final buffer = TtcBuffer();
          buffer.load(msg.data);

          // Skip the message type byte
          if (!buffer.atEnd) {
            buffer.skip(1);
          }

          for (final entry in params.entries) {
            final value = entry.value;
            if (value is ({
              OracleType type,
              BindDirection direction,
              dynamic value
            })) {
              if (value.direction == BindDirection.output ||
                  value.direction == BindDirection.inputOutput) {
                // Read output value
                final bytes = buffer.readClr();
                result[entry.key] = _decodeValue(bytes, value.type);
              }
            }
          }
        }

      default:
        break;
    }

    return result;
  }

  void _checkStatus(Uint8List data) {
    final message = Message.decode(data);

    switch (message) {
      case ErrorMessage msg:
        throw OracleError(msg.errorMessage, msg.errorCode);

      case StatusMessage _:
        // Success - nothing to do
        break;

      default:
        // Unknown response type
        break;
    }
  }
}
