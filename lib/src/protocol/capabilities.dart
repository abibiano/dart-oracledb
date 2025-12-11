/// Client and server capability negotiation.
library;

/// Client capabilities for protocol negotiation.
class ClientCapabilities {
  ClientCapabilities();

  /// Protocol version
  int protocolVersion = 6;

  /// Character set (UTF-8)
  int charsetId = 873; // AL32UTF8

  /// National character set (UTF-16)
  int ncharsetId = 2000; // AL16UTF16

  /// Supported TTC versions
  List<int> ttcVersions = [6, 5, 4, 3, 2, 1, 0];

  /// Client program name
  String programName = 'dart-oracledb';

  /// Client machine name
  String machineName = 'dart';

  /// Client process ID
  int processId = 0;

  /// Support for LOB operations
  bool supportsLob = true;

  /// Support for scrollable cursors
  bool supportsScrollable = false;

  /// Support for batch operations
  bool supportsBatch = true;

  /// Support for two-phase commit
  bool supportsTwoPhase = true;

  /// Support for Oracle Objects
  bool supportsObjects = true;

  /// Support for JSON type
  bool supportsJson = true;

  /// Support for VECTOR type (23ai)
  bool supportsVector = true;

  /// Encode capabilities for protocol negotiation
  List<int> encode() {
    // Capabilities are encoded as bit flags
    var flags = 0;
    if (supportsLob) flags |= 0x0001;
    if (supportsScrollable) flags |= 0x0002;
    if (supportsBatch) flags |= 0x0004;
    if (supportsTwoPhase) flags |= 0x0008;
    if (supportsObjects) flags |= 0x0010;
    if (supportsJson) flags |= 0x0020;
    if (supportsVector) flags |= 0x0040;

    return [
      (flags >> 24) & 0xFF,
      (flags >> 16) & 0xFF,
      (flags >> 8) & 0xFF,
      flags & 0xFF,
    ];
  }
}

/// Server capabilities received during negotiation.
class ServerCapabilities {
  ServerCapabilities();

  /// Server protocol version
  int protocolVersion = 0;

  /// Server character set
  int charsetId = 0;

  /// Server national character set
  int ncharsetId = 0;

  /// Server database version
  String databaseVersion = '';

  /// Server banner
  String serverBanner = '';

  /// Maximum number of cursors
  int maxCursors = 0;

  /// Maximum SDU size
  int maxSdu = 0;

  /// Maximum TDU size
  int maxTdu = 0;

  /// Server byte order (true = big-endian)
  bool bigEndian = true;

  /// Support for LOB operations
  bool supportsLob = false;

  /// Support for batch operations
  bool supportsBatch = false;

  /// Support for two-phase commit
  bool supportsTwoPhase = false;

  /// Support for Oracle Objects
  bool supportsObjects = false;

  /// Support for JSON type
  bool supportsJson = false;

  /// Support for VECTOR type
  bool supportsVector = false;

  /// Decode capabilities from protocol negotiation response
  void decode(List<int> data) {
    if (data.length < 4) return;

    final flags = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];

    supportsLob = (flags & 0x0001) != 0;
    supportsBatch = (flags & 0x0004) != 0;
    supportsTwoPhase = (flags & 0x0008) != 0;
    supportsObjects = (flags & 0x0010) != 0;
    supportsJson = (flags & 0x0020) != 0;
    supportsVector = (flags & 0x0040) != 0;
  }

  @override
  String toString() => 'ServerCapabilities(version: $databaseVersion, '
      'charset: $charsetId, lob: $supportsLob, json: $supportsJson)';
}
