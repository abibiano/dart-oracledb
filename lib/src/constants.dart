/// Protocol constants, type codes, and enumerations for Oracle Database driver.
library;

// =============================================================================
// TNS Packet Types (Section 14 TNS packet types from spec)
// =============================================================================

/// TNS packet type codes for network layer framing.
enum TnsPacketType {
  connect(0x01),
  accept(0x02),
  acknowledge(0x03),
  refuse(0x04),
  redirect(0x05),
  data(0x06),
  nullPacket(0x07),
  abort(0x09),
  resend(0x0B),
  marker(0x0C),
  attention(0x0D),
  control(0x0E),
  dataDescriptor(0x0F);

  const TnsPacketType(this.value);
  final int value;

  static TnsPacketType? fromValue(int value) {
    for (final type in values) {
      if (type.value == value) return type;
    }
    return null;
  }
}

// =============================================================================
// TTC Message Types (Two-Task Common)
// =============================================================================

/// TTC message type codes for protocol layer operations.
enum TtcMessageType {
  protocol(0x01), // TTIPRO - Protocol version negotiation
  dataTypes(0x02), // TTIDTY - Data type representation negotiation
  function(0x03), // TTIFUN - OPI function invocation
  error(0x04), // TTIOER - Oracle error response
  rowHeader(0x06), // TTIRXH - Row transfer header
  rowData(0x07), // TTIRXD - Row transfer data
  returnParam(0x08), // TTIRPA - Return parameter
  status(0x09), // TTISTA - Function status (OK)
  columnAccessor(0x0D), // TTIOAC - Oracle column accessor
  lobData(0x0E), // TTILOBD - LOB data transfer
  secureNetworkServices(0xDE); // TTISNS - Secure Network Services

  const TtcMessageType(this.value);
  final int value;

  static TtcMessageType? fromValue(int value) {
    for (final type in values) {
      if (type.value == value) return type;
    }
    return null;
  }
}

// =============================================================================
// OPI Function Codes (Oracle Programmatic Interface)
// =============================================================================

/// OPI function codes for database operations.
enum OpiFunction {
  logon(0x01), // OLOGON - Legacy logon
  openCursor(0x02), // OOPEN - Open cursor
  parse(0x03), // OPARSE - Parse SQL statement
  execute(0x04), // OEXEC - Execute statement
  fetch(0x05), // OFETCH - Fetch row
  closeCursor(0x08), // OCLOSE - Close cursor
  logoff(0x09), // OLOGOFF - Log off
  commit(0x0E), // OCOMMIT - Commit transaction
  rollback(0x0F), // OROLLBACK - Rollback transaction
  bundledCall(0x5E), // OALL8 - Bundled V8 call (parse+bind+exec+fetch)
  lobOps(0x60), // OLOBOPS - LOB operations
  auth(0x73), // OAUTH - Generic authentication
  sessionKey(0x76), // OSESSKEY - Get session key
  enhancedFetch(0x89), // OFETCH2 - Enhanced fetch
  ping(0x93); // OPING - Connection ping

  const OpiFunction(this.value);
  final int value;
}

/// OALL8 options bitmap for bundled operations.
abstract final class OAll8Options {
  static const int parse = 0x0001;
  static const int bind = 0x0008;
  static const int define = 0x0010;
  static const int execute = 0x0020;
  static const int fetch = 0x0040;
  static const int commit = 0x0100;
}

// =============================================================================
// Oracle Data Types
// =============================================================================

/// Oracle database column types.
enum OracleType {
  varchar2(1),
  number(2),
  integer(3),
  float(4),
  string(5),
  varnum(6),
  long(8),
  varchar(9),
  rowid(11),
  date(12),
  raw(23),
  longRaw(24),
  unsignedInt(68),
  char(96),
  nchar(96),
  binaryFloat(100),
  binaryDouble(101),
  cursor(102),
  rowIdDescriptor(104),
  urowid(208),
  clob(112),
  blob(113),
  nclob(112),
  bfile(114),
  json(119),
  timestamp(180),
  timestampTZ(181),
  intervalYM(182),
  intervalDS(183),
  timestampLTZ(231),
  plsqlBoolean(252),
  xmlType(109),
  vector(127);

  const OracleType(this.value);
  final int value;

  static OracleType? fromValue(int value) {
    for (final type in values) {
      if (type.value == value) return type;
    }
    return null;
  }
}

/// Fetch mode for cursor operations.
enum FetchMode {
  /// Return rows as `List<dynamic>`
  list,

  /// Return rows as `Map<String, dynamic>`
  map,

  /// Return rows as typed records (requires type annotation)
  record,
}

/// Bind variable direction for stored procedure parameters.
enum BindDirection {
  /// Input parameter
  input,

  /// Output parameter
  output,

  /// Input/Output parameter
  inputOutput,
}

// =============================================================================
// Protocol Constants
// =============================================================================

/// TNS protocol constants.
abstract final class TnsConstants {
  /// Default Oracle port
  static const int defaultPort = 1521;

  /// TNS header size in bytes
  static const int headerSize = 8;

  /// Default SDU (Session Data Unit) size
  static const int defaultSdu = 8192;

  /// Default TDU (Transport Data Unit) size
  static const int defaultTdu = 32767;

  /// Maximum packet size
  static const int maxPacketSize = 4086;

  /// Protocol version for thin mode (Oracle 8.1+)
  static const int protocolVersion = 6;

  /// TNS version for connect packet
  static const int tnsVersion = 0x0136; // v310
}

/// CLR (Chunked Long Raw) encoding constants.
abstract final class ClrConstants {
  /// Maximum length for single-byte length encoding
  static const int maxSingleByteLength = 64;

  /// Marker for chunked encoding
  static const int chunkedMarker = 0xFE;

  /// Null value marker
  static const int nullMarker = 0x00;

  /// Alternative null marker
  static const int altNullMarker = 0xFF;

  /// Chunk size for CLR encoding
  static const int chunkSize = 64;

  /// Terminator for chunked encoding
  static const int terminator = 0x00;
}

/// Authentication protocol versions.
enum AuthProtocol {
  /// O5LOGON - SHA1-based (Oracle 11g)
  o5logon,

  /// O7LOGON - PBKDF2-SHA512 (Oracle 12c+)
  o7logon,

  /// O8LOGON - Enhanced PBKDF2-SHA512 (Oracle 12c+)
  o8logon,
}
