import 'dart:typed_data';
import 'package:oracledb/src/protocol/messages/fast_auth_message.dart';
import 'package:oracledb/src/protocol/buffer.dart';

void main() {
  // Build capabilities (simplified)
  final compileCaps = Uint8List.fromList([
    0x29, 0x90, 0x03, 0x07, 0x03, 0x00, 0x01, 0x00,
    0xcf, 0x00, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x00, 0x0c, 0x20, 0x00, 0xb8, 0x00,
    0x08, 0x24, 0x00, 0x05, 0x00, 0x28, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x07, 0x02,
    0x00
  ]);

  final runtimeCaps = Uint8List.fromList([
    0x00, 0x00, 0x00, 0x05, 0x00, 0x01, 0x00, 0x01,
    0x00, 0x01, 0x00
  ]);

  final dataTypes = [
    [1, 0, 0],   // VARCHAR2
    [2, 10, 0],  // NUMBER
    [8, 8, 0],   // LONG
   // ... truncated for brevity
  ];

  final fastAuth = FastAuthRequest(
    username: 'system',
    clientNonce: Uint8List(16),
    compileCaps: compileCaps,
    runtimeCaps: runtimeCaps,
    dataTypes: dataTypes,
    ttcFieldVersion: 24,
    sequence: 1,
  );

  final bytes = fastAuth.toBytes();
  print('Dart FAST_AUTH: ${bytes.length} bytes');
  print('First 50 bytes:');
  print(bytes.sublist(0, 50).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' '));
}
