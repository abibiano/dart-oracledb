/// Internal LOB locator value produced while decoding CLOB / BLOB column or
/// OUT-bind data (Stories 4.1 and 4.2).
///
/// A locator is a reference to LOB data stored on the server, shipped with
/// LOB-prefetch metadata (length and chunk size) because the driver
/// negotiates `TNS_CCAP_LOB_PREFETCH` in its compile capabilities.
///
/// On the DEFAULT path a locator never escapes the transport layer:
/// `Transport.materializeLobs` reads every locator into a Dart `String` (CLOB)
/// or `Uint8List` (BLOB) via TTC LOB READ operations before the response
/// reaches `OracleConnection`. On the opt-in `OracleExecuteOptions(fetchLobs:
/// true)` path (Story 12.1) a locator instead escapes wrapped in a public
/// `OracleLob` handle (the `wrapLob` callback threaded into `materializeLobs`);
/// the handle owns the locator and drives its own bounded LOB READ/WRITE round
/// trips. The locator bytes themselves are still never handed to callers.
///
/// Story 12.2 adds a third origin: a locator the DRIVER creates on the server
/// (`Transport.createTemporaryLob`, a session-duration temporary LOB) and hands
/// to the caller wrapped in an `OracleLob` from
/// `OracleConnection.createTemporaryClob/NClob/Blob()`. Such a locator is
/// constructed with `isTemporary: true` and escapes the transport as a
/// caller-OWNED handle: the caller decides when it dies, and the handle's
/// `close()` queues the locator bytes for the transport's existing
/// `FREE_TEMP | ARRAY` piggyback. The bytes are still never exposed publicly —
/// the only public reference is the opaque `OracleLob`.
library;

import 'dart:typed_data';

import 'constants.dart';

/// A decoded LOB locator plus the prefetch metadata needed to read its value.
class LobLocator {
  /// Creates a locator value.
  ///
  /// [isTemporary] forces [isTemporary] to `true` regardless of the locator's
  /// flag bytes: the driver sets it for a locator it just created itself via
  /// CREATE_TEMP (`Transport.createTemporaryLob`), where the temporary nature is
  /// known from the request, not inferred from the server's echo. Leave it at
  /// its default for a FETCHED locator so the TEMP flag bit decides.
  LobLocator({
    required this.locator,
    required this.oracleType,
    required this.length,
    required this.chunkSize,
    this.isNChar = false,
    bool isTemporary = false,
  }) : _createdTemporary = isTemporary;

  /// Raw locator bytes as sent by the server (typically 40 bytes). For
  /// temporary LOBs the server updates this buffer's contents on every LOB
  /// operation response.
  final Uint8List locator;

  /// The Oracle LOB type this locator references: [oraTypeClob] or
  /// [oraTypeBlob]. Determines the units of [length] / [chunkSize] and how
  /// LOB READ payloads are interpreted (character data vs raw bytes).
  final int oracleType;

  /// LOB length in the type's native units: UCS-2 code units for CLOB —
  /// Oracle's CLOB character counting, which matches Dart's `String.length`
  /// (UTF-16 code units) exactly — and **bytes** for BLOB.
  final int length;

  /// Server-side chunk size from the LOB-prefetch metadata, in the same
  /// units as [length]. `0` when unknown (e.g. internally created temporary
  /// LOBs). Retained as diagnostic metadata; the value is read in a single
  /// full-length LOB READ (node-oracledb `getData` parity), so this no
  /// longer sizes reads.
  final int chunkSize;

  /// Whether this locator references a national-charset LOB (an `NCLOB`,
  /// `csfrm == ttcCsfrmNChar`), known from the column or bind metadata rather
  /// than the locator bytes.
  ///
  /// node-oracledb `lob.js getCsfrm()` treats an NCLOB as national outright —
  /// its declared NCHAR character set form — and only falls back to the
  /// locator's [usesVarLengthCharset] flag for plain CLOBs. Server-created
  /// NCLOB locators do not reliably set that flag bit, so this declared form is
  /// the authoritative national signal; both together drive the UTF-16BE
  /// materialization path.
  final bool isNChar;

  /// Whether the locator flags report a variable-length character set.
  ///
  /// When set, the LOB's data travels as UTF-16BE on the wire instead of the
  /// negotiated UTF-8 — node-oracledb `lob.js getCsfrm()` treats such a
  /// locator as NCHAR-charset and `lobOp.js` converts with `swap16`. Oracle
  /// marks PL/SQL-created and temporary CLOBs this way (CLOB data is stored
  /// in UCS-2 internally), so plain CLOB support must honor it.
  bool get usesVarLengthCharset =>
      locator.length > tnsLobLocOffsetFlag3 &&
      (locator[tnsLobLocOffsetFlag3] & tnsLobLocFlagsVarLengthCharset) != 0;

  /// Set when the driver created this locator itself through CREATE_TEMP, so
  /// [isTemporary] is authoritative without inspecting the server's echoed
  /// flag bytes. Never set for a fetched locator.
  final bool _createdTemporary;

  /// Whether this locator references a **temporary** LOB — one occupying
  /// session temp-LOB space that must be explicitly freed (via the transport's
  /// `FREE_TEMP | ARRAY` piggyback) rather than a persistent, table-backed
  /// value the server reclaims on its own.
  ///
  /// True either because the driver created the LOB itself (the constructor's
  /// `isTemporary` flag — `Transport.createTemporaryLob`) or because a FETCHED
  /// locator's flag byte 4 carries [tnsLobLocFlagsTemp]. The flag read is
  /// bounds-guarded exactly like [usesVarLengthCharset]: a locator shorter than
  /// the flag offset simply reports `false`.
  ///
  /// **Deliberate node-oracledb divergence.** `thin/lob.js init()` marks a
  /// fetched locator temporary when EITHER
  /// `locator[FLAG_4] & TNS_LOB_LOC_FLAGS_TEMP === TNS_LOB_LOC_FLAGS_TEMP` OR
  /// `locator[FLAG_1] & TNS_LOB_LOC_FLAGS_ABSTRACT === TNS_LOB_LOC_FLAGS_ABSTRACT`.
  /// Only the FIRST clause is ported here. JavaScript's `===` binds tighter
  /// than `&`, so each clause actually evaluates as `byte & (X === X)` →
  /// `byte & 1`; the second clause therefore does not test ABSTRACT (0x40) at
  /// all — it tests bit 0x01 of flag byte 1, which is
  /// [tnsLobLocFlagsBlob], marking EVERY fetched BLOB "temporary". Porting
  /// node's effective behavior would queue every fetched BLOB locator for
  /// FREE_TEMP, and since that free rides an unrelated statement's piggyback it
  /// would corrupt innocent executes. Porting node's *intended* behavior
  /// (`& 0x40`) would capture value-based abstract JSON/VECTOR locators, which
  /// never reach `OracleLob` in this driver (native JSON has its own OSON decode
  /// path and never becomes a LOB handle). So only the TEMP bit — where node's
  /// effective behavior and the intended semantics agree — is honored.
  bool get isTemporary =>
      _createdTemporary ||
      (locator.length > tnsLobLocOffsetFlag4 &&
          (locator[tnsLobLocOffsetFlag4] & tnsLobLocFlagsTemp) != 0);

  @override
  String toString() => 'LobLocator(type: $oracleType, length: $length '
      '${oracleType == oraTypeBlob ? 'bytes' : 'chars'}, '
      'chunkSize: $chunkSize, temporary: $isTemporary, '
      'locator: ${locator.length} bytes)';
}

/// Encodes [value] as UTF-16BE bytes (2 bytes per UTF-16 code unit) for LOB
/// writes against a variable-length-charset locator. Equivalent to
/// node-oracledb's `Buffer.from(data, 'utf16le').swap16()`.
Uint8List encodeUtf16Be(String value) {
  final units = value.codeUnits;
  final bytes = Uint8List(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    bytes[i * 2] = (units[i] >> 8) & 0xFF;
    bytes[i * 2 + 1] = units[i] & 0xFF;
  }
  return bytes;
}

/// Decodes UTF-16BE LOB data bytes into a Dart String. Surrogate pairs pass
/// through as their two code units, matching Dart's native string encoding.
/// Throws [FormatException] on an odd byte count (a UTF-16 stream must be an
/// even number of bytes).
String decodeUtf16Be(Uint8List bytes) {
  if (bytes.length.isOdd) {
    throw FormatException(
        'UTF-16 LOB data has an odd byte count: ${bytes.length}');
  }
  final units = Uint16List(bytes.length ~/ 2);
  for (var i = 0; i < units.length; i++) {
    units[i] = (bytes[i * 2] << 8) | bytes[i * 2 + 1];
  }
  return String.fromCharCodes(units);
}
