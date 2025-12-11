/// Protocol state machine for TNS/TTC communication.
library;

import 'dart:async';
import 'dart:typed_data';

import '../constants.dart';
import '../cursor.dart';
import '../errors.dart';
import '../transport/transport.dart';
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
  Future<void> negotiate() async {
    if (!_connected) {
      throw const ProtocolError('Not connected');
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

  void _parseAccept(Uint8List data) {
    // Parse Accept packet to get negotiated parameters
    // This includes SDU size, TDU size, and protocol options
  }

  String _parseRefuse(Uint8List data) {
    // Parse Refuse packet to get error reason
    return 'Unknown error';
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
    _ttc.clear();
    _ttc.writeUint8(TtcMessageType.protocol.value);
    _ttc.writeBytes(Uint8List.fromList([6, 5, 4, 3, 2, 1, 0])); // Versions
    _ttc.writeString('dart-oracledb');
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
    // Determine auth protocol from response
    return (AuthProtocol.o8logon, <String, dynamic>{});
  }

  Future<void> _authenticateO5Logon(
    String user,
    String password,
    Map<String, dynamic> authData,
  ) async {
    // O5LOGON (SHA1-based) authentication
    // See crypto/auth.dart for implementation
  }

  Future<void> _authenticateO7O8Logon(
    String user,
    String password,
    Map<String, dynamic> authData,
    AuthProtocol authType,
  ) async {
    // O7/O8 LOGON (PBKDF2-SHA512) authentication
    // See crypto/auth.dart for implementation
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
    // Encode value based on type
    // Implementation uses CLR encoding for variable-length data
  }

  Future<ResultSet> _processExecuteResponse(FetchMode fetchMode) async {
    final columns = <ColumnMetadata>[];
    final rows = <List<dynamic>>[];
    const rowsAffected = 0;
    String? lastRowId;

    // Process response messages
    // Parse column definitions, row data, and status

    return ResultSet(
      columns: columns,
      rows: rows,
      rowsAffected: rowsAffected,
      lastRowId: lastRowId,
    );
  }

  int _parseRowsAffected(Uint8List data) {
    // Parse rows affected from response
    return 0;
  }

  Map<String, dynamic> _parsePlSqlResponse(
    Uint8List data,
    Map<String, dynamic>? params,
  ) {
    // Parse OUT parameter values from response
    return {};
  }

  void _checkStatus(Uint8List data) {
    // Check for error status
    if (data.isNotEmpty && data[0] == TtcMessageType.error.value) {
      // Parse error code and message
      throw const OracleError('Operation failed');
    }
  }
}
