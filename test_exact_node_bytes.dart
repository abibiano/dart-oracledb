/// Test sending EXACT bytes from node-oracledb capture
import 'dart:typed_data';
import 'package:oracledb/src/transport/transport.dart';

void main() async {
  final transport = Transport();
  await transport.connect('localhost', 1521);

  // Perform TNS CONNECT/ACCEPT
  final connectData = Uint8List.fromList([
    // TNS connect packet body - simplified
  ]);
  await transport.sendConnectReceiveAccept(connectData);

  // Perform protocol negotiation
  await transport.sendProtocolNegotiation();

  // Now send EXACT AUTH_PHASE_ONE bytes from node-oracledb capture
  // Data flags (00 00) + message bytes
  final exactNodeBytes = Uint8List.fromList([
    // From node capture at 0xa46: 00 00 03 76 01 01 01 06 02 01 01 01 01 05 00...
    0x03, 0x76, 0x01, // Message type, function code, sequence
    0x01, 0x01, 0x06, // Username present, UB4(6)
    0x02, 0x01, 0x01, // UB4(257) auth mode
    0x01, // Unknown flag
    0x01, 0x05, // UB4(5) key-value pairs
    0x00, // Unknown
    0x01, // Unknown
    0x01, 0x06, // UB4(6) username length
    ...utf8.encode('system'), // Username
    // AUTH_TERMINAL
    0x01, 0x0d, // UB4(13) key length
    0x0d, ...utf8.encode('AUTH_TERMINAL'),
    0x01, 0x07, // UB4(7) value length
    0x07, ...utf8.encode('unknown'),
    0x00, 0x00, 0x00, 0x00, // flags
    // ... rest of key-value pairs
  ]);

  print('Sending exact node-oracledb AUTH_PHASE_ONE bytes...');
  try {
    await transport.sendData(exactNodeBytes);
    final response = await transport.receiveData();
    print('SUCCESS! Received ${response.length} bytes');
  } catch (e) {
    print('FAILED: $e');
  }

  await transport.disconnect();
}
