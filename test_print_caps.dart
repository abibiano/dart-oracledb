/// Print the compile and runtime capabilities that dart-oracledb sends
import 'dart:typed_data';
import 'package:oracledb/src/protocol/buffer.dart';

void main() {
  print('=== DART-ORACLEDB CAPABILITIES ===\n');

  // Build capabilities (copied from Transport class)
  final compileCaps = _buildCompileCapabilities();
  final runtimeCaps = _buildRuntimeCapabilities();

  print('Compile caps length: ${compileCaps.length} bytes');
  print('Compile capabilities (hex): ${_toHexString(compileCaps)}');
  print('\nCompile capabilities (indexed - non-zero only):');
  for (var i = 0; i < compileCaps.length; i++) {
    if (compileCaps[i] != 0) {
      print('  [${i.toString().padLeft(2)}] = 0x${compileCaps[i].toRadixString(16).padLeft(2, '0')} (${compileCaps[i].toString().padLeft(3)})');
    }
  }

  print('\nRuntime caps length: ${runtimeCaps.length} bytes');
  print('Runtime capabilities (hex): ${_toHexString(runtimeCaps)}');
  print('\nRuntime capabilities (indexed - non-zero only):');
  for (var i = 0; i < runtimeCaps.length; i++) {
    if (runtimeCaps[i] != 0) {
      print('  [${i.toString().padLeft(2)}] = 0x${runtimeCaps[i].toRadixString(16).padLeft(2, '0')} (${runtimeCaps[i].toString().padLeft(3)})');
    }
  }

  // Build full data types message to compare
  print('\n=== FULL DATA TYPES MESSAGE (first 150 bytes) ===\n');
  final buffer = WriteBuffer();

  // Message type
  buffer.writeUint8(2); // TNS_MSG_TYPE_DATA_TYPES

  // Character set (UTF-8 = 873)
  buffer.writeUint16LE(873);
  buffer.writeUint16LE(873);

  // Encoding flags
  buffer.writeUint8(0x01 | 0x20); // MULTI_BYTE | CONV_LENGTH

  // Compile caps (length-prefixed)
  buffer.writeUint8(compileCaps.length);
  buffer.writeBytes(compileCaps);

  // Runtime caps (length-prefixed)
  buffer.writeUint8(runtimeCaps.length);
  buffer.writeBytes(runtimeCaps);

  final bytes = buffer.toBytes();
  final displayBytes = bytes.length > 150 ? bytes.sublist(0, 150) : bytes;

  for (var i = 0; i < displayBytes.length; i += 16) {
    final chunk = displayBytes.sublist(i, (i + 16 > displayBytes.length) ? displayBytes.length : i + 16);
    final hexStr = chunk.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ').padRight(48);
    final asciiStr = chunk.map((b) => (b >= 32 && b < 127) ? String.fromCharCode(b) : '.').join('');
    print('${i.toRadixString(16).padLeft(4, '0')}: $hexStr $asciiStr');
  }
}

String _toHexString(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
}

// Constants (from transport.dart)
const int _ccapMax = 48;
const int _ccapSqlVersion = 0;
const int _ccapLogonTypes = 4;
const int _ccapCtbFeatureBackport = 5;
const int _ccapFieldVersion = 7;
const int _ccapServerDefineConv = 8;
const int _ccapDequeueWithSelector = 9;
const int _ccapTtc1 = 15;
const int _ccapOci1 = 16;
const int _ccapTdsVersion = 17;
const int _ccapRpcVersion = 18;
const int _ccapRpcSig = 19;
const int _ccapDbfVersion = 21;
const int _ccapLob = 23;
const int _ccapTtc2 = 26;
const int _ccapUb2Dty = 27;
const int _ccapOci2 = 31;

const int _rcapMax = 9;
const int _rcapCompat = 0;
const int _rcapTtc = 6;

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

  // TTC2 flags (index 26)
  caps[_ccapTtc2] = 0x04;

  // UB2 DTY (index 27)
  caps[_ccapUb2Dty] = 1;

  // OCI2 flags (index 31) - DRCP
  caps[_ccapOci2] = 0x10;

  return caps;
}

Uint8List _buildRuntimeCapabilities() {
  final caps = Uint8List(_rcapMax);

  // Compat (index 0)
  caps[_rcapCompat] = 2; // TNS_RCAP_COMPAT_81

  // TTC flags (index 6) - ZERO_COPY | 32K
  caps[_rcapTtc] = 0x01 | 0x04; // = 0x05

  return caps;
}
