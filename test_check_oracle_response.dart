/// Check if Oracle sends any response before closing
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:oracledb/src/transport/transport.dart';
import 'package:oracledb/src/transport/packet.dart' show buildConnectPacketBody;
import 'package:oracledb/src/protocol/buffer.dart';
import 'package:oracledb/src/protocol/constants.dart';
import 'dart:convert';

void main() async {
  const host = 'localhost';
  const port = 1521;
  const serviceName = 'FREEPDB1';
  const username = 'system';

  // Build connect data
  final tnsDescriptor = '(DESCRIPTION='
      '(ADDRESS=(PROTOCOL=TCP)(HOST=$host)(PORT=$port))'
      '(CONNECT_DATA=(SERVICE_NAME=$serviceName)))';
  final descriptorBytes = Uint8List.fromList(utf8.encode(tnsDescriptor));
  final connectData = buildConnectPacketBody(descriptorBytes);

  final transport = Transport();

  try {
    print('Connecting...');
    await transport.connect(host, port);

    print('Sending CONNECT...');
    await transport.sendConnectReceiveAccept(connectData);

    print('Protocol negotiation...');
    await transport.sendProtocolNegotiation();

    print('Sending AUTH_PHASE_ONE...');

    // Build minimal AUTH_PHASE_ONE
    final buffer = WriteBuffer();
    buffer.writeUint8(ttcMsgTypeFunction); // 3
    buffer.writeUint8(ttcAuthPhaseOne); // 0x76
    buffer.writeUint8(1); // sequence

    // Auth mode
    const authMode = ttcAuthModeLogon | ttcAuthModeWithPassword;
    final usernameBytes = Uint8List.fromList(utf8.encode(username));
    buffer.writeUint8(1); // username present
    buffer.writeUB4(usernameBytes.length);
    buffer.writeUB4(authMode);

    // 5 key-value pairs
    buffer.writeUint8(1);
    buffer.writeUB4(5);
    buffer.writeUint8(0);
    buffer.writeUint8(1);

    buffer.writeBytesWithLength(usernameBytes);
    buffer.writeKeyValue('AUTH_TERMINAL', 'unknown');
    buffer.writeKeyValue('AUTH_PROGRAM_NM', 'dart');
    buffer.writeKeyValue('AUTH_MACHINE', 'localhost');
    buffer.writeKeyValue('AUTH_PID', '12345');
    buffer.writeKeyValue('AUTH_SID', 'testuser');

    final authBytes = buffer.toBytes();
    print('AUTH_PHASE_ONE: ${authBytes.length} bytes');

    await transport.sendData(authBytes);
    print('AUTH_PHASE_ONE sent. Waiting for response...');

    // Try to receive with timeout to see if Oracle sends anything
    try {
      final response = await transport.receiveData().timeout(
        Duration(seconds: 2),
        onTimeout: () {
          print('TIMEOUT - No response from Oracle');
          return Uint8List(0);
        },
      );

      if (response.isNotEmpty) {
        print('Received ${response.length} bytes:');
        print('Hex: ${response.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');
      } else {
        print('Socket likely closed without sending data');
      }
    } catch (e) {
      print('Error receiving: $e');
    }

  } catch (e) {
    print('Error: $e');
  } finally {
    await transport.disconnect();
  }
}
