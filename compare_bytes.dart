import 'dart:io';
import 'dart:typed_data';

void main() async {
  // Read node's FAST_AUTH packet
  final nodeBytes = await File('node_fast_auth.bin').readAsBytes();
  print('Node packet: ${nodeBytes.length} bytes');

  // We need to capture our dart packet - let's modify the test to save it
  print('\nFirst 100 bytes (node):');
  printHex(nodeBytes.sublist(0, 100));
}

void printHex(Uint8List bytes) {
  for (int i = 0; i < bytes.length; i += 16) {
    final chunk = bytes.sublist(i, (i + 16) < bytes.length ? i + 16 : bytes.length);
    final offset = i.toRadixString(16).padLeft(4, '0');
    final hex = chunk.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    print('$offset: $hex');
  }
}
