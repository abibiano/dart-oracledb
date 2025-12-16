import 'dart:typed_data';
import 'lib/src/protocol/messages/auth_message.dart';

void main() {
  final msg = AuthPhaseOneRequest(
    username: 'SYSTEM',
    clientNonce: Uint8List(16),
  );
  final bytes = msg.toBytes(use23aiFormat: true);
  print('Full AUTH_PHASE_ONE: ${bytes.length} bytes');
  print('Hex: ${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
}
