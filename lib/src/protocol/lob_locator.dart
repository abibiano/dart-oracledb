/// Internal LOB locator value produced while decoding CLOB column or OUT-bind
/// data (Story 4.1).
///
/// A locator is a reference to LOB data stored on the server, shipped with
/// LOB-prefetch metadata (length and chunk size) because the driver
/// negotiates `TNS_CCAP_LOB_PREFETCH` in its compile capabilities. Instances
/// never escape the transport layer: `Transport.sendExecute` materializes
/// every locator into a Dart `String` (via TTC LOB READ operations) before
/// the response reaches `OracleConnection`.
library;

import 'dart:typed_data';

import 'constants.dart';

/// A decoded LOB locator plus the prefetch metadata needed to read its value.
class LobLocator {
  /// Creates a locator value.
  LobLocator({
    required this.locator,
    required this.lengthInChars,
    required this.chunkSize,
  });

  /// Raw locator bytes as sent by the server (typically 40 bytes). For
  /// temporary LOBs the server updates this buffer's contents on every LOB
  /// operation response.
  final Uint8List locator;

  /// LOB length in UCS-2 code units — Oracle's CLOB character counting,
  /// which matches Dart's `String.length` (UTF-16 code units) exactly.
  final int lengthInChars;

  /// Server-side chunk size in characters from the LOB-prefetch metadata.
  /// `0` when unknown (e.g. internally created temporary LOBs). Retained as
  /// diagnostic metadata; the value is read in a single full-length LOB READ
  /// (node-oracledb `getData` parity), so this no longer sizes reads.
  final int chunkSize;

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

  @override
  String toString() => 'LobLocator(length: $lengthInChars chars, '
      'chunkSize: $chunkSize, locator: ${locator.length} bytes)';
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
