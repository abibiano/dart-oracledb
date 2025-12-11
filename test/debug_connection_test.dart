/// Debug test to trace connection issue.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:oracledb/src/transport/transport.dart';
import 'package:oracledb/src/protocol/protocol.dart';
import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  test('debug - using Transport class', () async {
    final config = testConfig;
    print('Connecting via Transport to ${config.host}:${config.port}');

    final transport = await Transport.connect(
      host: config.host,
      port: config.port,
    );
    print('Transport connected!');
    print('Remote: ${transport.remoteAddress}:${transport.remotePort}');

    // Create protocol and try to connect
    final protocol = Protocol(transport);
    print('Protocol created, sending connect...');

    try {
      await protocol.connect(serviceName: config.serviceName);
      print('Protocol connect succeeded!');
      print('Supports Fast Auth: ${protocol.supportsFastAuth}');
      print('Supports End of Response: ${protocol.supportsEndOfResponse}');

      print('Starting negotiate and authenticate...');
      await protocol.negotiateAndAuthenticate(
        user: config.user,
        password: config.password,
      );
      print('Authentication succeeded!');
    } catch (e, st) {
      print('Protocol failed: $e');
      print('Stack: $st');
    }

    await transport.close();
  });

  test('debug - raw packet capture', () async {
    final config = testConfig;
    print('Connecting to ${config.host}:${config.port}');

    final socket = await Socket.connect(config.host, config.port);
    print('Connected! Local: ${socket.address}:${socket.port}');

    // Listen for responses
    final responses = <List<int>>[];
    socket.listen(
      (data) {
        print('Received ${data.length} bytes: ${_hexDump(data)}');
        responses.add(data);
      },
      onDone: () => print('Socket closed by server'),
      onError: (e) => print('Socket error: $e'),
    );

    // Build connect packet exactly as we do
    const sdu = 8192;
    final connectData =
        '(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${config.host})(PORT=${config.port}))(CONNECT_DATA=(SERVICE_NAME=${config.serviceName})(CID=(PROGRAM=dart-oracledb)(HOST=localhost)(USER=dart))))';
    final connectDataBytes = Uint8List.fromList(connectData.codeUnits);

    const connectHeaderSize = 74;
    final totalSize = connectHeaderSize + connectDataBytes.length;

    final buffer = ByteData(totalSize);
    var offset = 0;

    // TNS Header (8 bytes)
    buffer.setUint16(offset, totalSize, Endian.big);
    offset += 2;
    buffer.setUint16(offset, 0, Endian.big);
    offset += 2;
    buffer.setUint8(offset, 0x01); // Connect type
    offset += 1;
    buffer.setUint8(offset, 0);
    offset += 1;
    buffer.setUint16(offset, 0, Endian.big);
    offset += 2;

    // Connect specific fields
    buffer.setUint16(offset, 319, Endian.big);
    offset += 2; // Version
    buffer.setUint16(offset, 300, Endian.big);
    offset += 2; // Version Compatible

    buffer.setUint16(offset, 0x0001, Endian.big);
    offset += 2; // Service Options

    buffer.setUint16(offset, sdu, Endian.big);
    offset += 2; // SDU
    buffer.setUint16(offset, sdu, Endian.big);
    offset += 2; // TDU

    buffer.setUint16(offset, 0x8F01, Endian.big);
    offset += 2; // NT Protocol

    buffer.setUint16(offset, 0, Endian.big);
    offset += 2; // Line Turnaround
    buffer.setUint16(offset, 1, Endian.big);
    offset += 2; // Value of 1

    buffer.setUint16(offset, connectDataBytes.length, Endian.big);
    offset += 2; // Connect Data Length
    buffer.setUint16(offset, connectHeaderSize, Endian.big);
    offset += 2; // Connect Data Offset = 74

    buffer.setUint32(offset, 0, Endian.big);
    offset += 4; // Max Receivable Connect Data

    const nsiFlags = 0x0A;
    buffer.setUint8(offset, nsiFlags);
    offset += 1;
    buffer.setUint8(offset, nsiFlags);
    offset += 1;

    // Obsolete fields (24 bytes)
    for (var i = 0; i < 24; i++) {
      buffer.setUint8(offset + i, 0);
    }
    offset += 24;

    // Large SDU and TDU
    buffer.setUint32(offset, sdu, Endian.big);
    offset += 4;
    buffer.setUint32(offset, sdu, Endian.big);
    offset += 4;

    // Connect Flags
    buffer.setUint32(offset, 0, Endian.big);
    offset += 4;
    buffer.setUint32(offset, 0, Endian.big);
    offset += 4;

    // Connect Data
    final data = buffer.buffer.asUint8List();
    data.setRange(offset, offset + connectDataBytes.length, connectDataBytes);

    print('Sending ${data.length} bytes:');
    print('Header: ${_hexDump(data.sublist(0, 8))}');
    print('Connect fields: ${_hexDump(data.sublist(8, 74))}');
    print('Connect data: ${String.fromCharCodes(data.sublist(74))}');

    socket.add(data);
    await socket.flush();
    print('Packet sent, waiting for response...');

    // Wait for response
    await Future.delayed(const Duration(seconds: 5));

    print('Received ${responses.length} responses');
    for (var i = 0; i < responses.length; i++) {
      final resp = responses[i];
      if (resp.length >= 8) {
        final type = resp[4];
        print('Response $i: type=0x${type.toRadixString(16)} (${_typeName(type)})');
        if (type == 0x04) {
          // Refuse - parse the reason
          if (resp.length > 12) {
            final dataLen = (resp[10] << 8) | resp[11];
            if (resp.length >= 12 + dataLen) {
              final reason = String.fromCharCodes(resp.sublist(12, 12 + dataLen));
              print('Refuse reason: $reason');
            }
          }
        }
      }
    }

    await socket.close();
  });
}

String _hexDump(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
}

String _typeName(int type) {
  const types = {
    0x01: 'CONNECT',
    0x02: 'ACCEPT',
    0x04: 'REFUSE',
    0x05: 'REDIRECT',
    0x06: 'DATA',
  };
  return types[type] ?? 'UNKNOWN';
}
