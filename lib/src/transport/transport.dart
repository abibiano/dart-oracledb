import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../errors.dart';
import 'packet.dart';
import 'socket.dart';

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

  /// Whether the transport is currently connected.
  bool get isConnected => _socket.isConnected;

  /// Connects to an Oracle database at the specified host and port.
  ///
  /// Throws [OracleException] if the connection fails.
  Future<void> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    _log.info('Connecting transport to $host:$port');
    await _socket.connect(host, port, timeout: timeout);
    _log.info('Transport connected');
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
    final bytes = encodePacket(packet);
    _log.fine(
        'Sending TNS packet: type=${packet.type}, length=${packet.length}');
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
    _log.fine('Waiting for TNS packet...');

    // Read header first (8 bytes)
    final header = await _socket.read(tnsHeaderSize);
    _log.fine('Received header: ${header.length} bytes');

    // Extract total packet length from header
    final packetLength = readPacketLength(header);
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

    final packet = decodePacket(fullPacket);
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

  /// Sends a TNS CONNECT packet and waits for an ACCEPT response.
  ///
  /// Returns the ACCEPT packet on success.
  /// Throws [OracleException] on connection refusal or protocol error.
  Future<TnsPacket> sendConnectReceiveAccept(Uint8List connectData) async {
    // Send CONNECT packet
    final connectPacket = TnsPacket(
      type: tnsPacketConnect,
      payload: connectData,
    );
    await send(connectPacket);

    var resendCount = 0;

    while (true) {
      // Wait for response
      final response = await receive();

      switch (response.type) {
        case tnsPacketAccept:
          _log.info('Connection accepted');
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
          _log.fine('Server requested resend (attempt $resendCount/$_maxResendRetries)');
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
}
