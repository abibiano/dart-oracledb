/// LOB (Large Object) handling for CLOB, BLOB, and NCLOB types.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';

/// Base class for LOB (Large Object) types.
///
/// LOBs in Oracle can store up to 128TB of data and require
/// special handling for reading and writing.
sealed class Lob {
  Lob({
    required this.locator,
    this.chunkSize = 8192,
  });

  /// Server-side LOB locator
  final Uint8List locator;

  /// Optimal chunk size for read/write operations
  final int chunkSize;

  /// Whether the LOB locator is valid
  bool _isValid = true;

  /// Cached size (populated on first access)
  int? _cachedSize;

  /// Whether the LOB is valid
  bool get isValid => _isValid;

  /// Get the LOB size.
  ///
  /// For CLOB/NCLOB, returns the number of characters.
  /// For BLOB, returns the number of bytes.
  Future<int> getSize() async {
    if (!_isValid) {
      throw LobError.invalidLocator();
    }
    // Implementation in Protocol layer
    return _cachedSize ?? 0;
  }

  /// Read data from the LOB.
  ///
  /// Parameters:
  /// - [offset]: Starting position (0-based)
  /// - [amount]: Number of bytes/characters to read
  Future<Uint8List> read({int offset = 0, int? amount});

  /// Read the entire LOB as bytes.
  Future<Uint8List> readAll() async {
    final size = await getSize();
    return read(offset: 0, amount: size);
  }

  /// Stream the LOB data.
  Stream<Uint8List> stream({int offset = 0, int? chunkSize}) async* {
    final size = await getSize();
    final chunk = chunkSize ?? this.chunkSize;
    var pos = offset;

    while (pos < size) {
      final remaining = size - pos;
      final readSize = remaining < chunk ? remaining : chunk;
      final data = await read(offset: pos, amount: readSize);
      yield data;
      pos += readSize;
    }
  }

  /// Write data to the LOB.
  ///
  /// Parameters:
  /// - [data]: Data to write
  /// - [offset]: Starting position (0-based)
  Future<void> write(Uint8List data, {int offset = 0});

  /// Append data to the end of the LOB.
  Future<void> append(Uint8List data) async {
    final size = await getSize();
    await write(data, offset: size);
  }

  /// Truncate the LOB to the specified length.
  Future<void> truncate(int newLength);

  /// Free the LOB locator.
  ///
  /// After calling this method, the LOB cannot be used.
  Future<void> free() async {
    if (!_isValid) return;
    // Send free locator to server
    _isValid = false;
    _cachedSize = null;
  }

  /// Set cached size (called by Protocol).
  void setCachedSize(int size) {
    _cachedSize = size;
  }

  /// Invalidate the locator (called by Protocol).
  void invalidate() {
    _isValid = false;
    _cachedSize = null;
  }
}

/// Character Large Object (CLOB).
///
/// Stores character data using the database character set.
final class Clob extends Lob {
  Clob({
    required super.locator,
    super.chunkSize,
    this.encoding = utf8,
  });

  /// Character encoding
  final Encoding encoding;

  @override
  Future<Uint8List> read({int offset = 0, int? amount}) async {
    if (!isValid) {
      throw LobError.invalidLocator();
    }
    // Implementation in Protocol layer
    return Uint8List(0);
  }

  @override
  Future<void> write(Uint8List data, {int offset = 0}) async {
    if (!isValid) {
      throw LobError.invalidLocator();
    }
    // Implementation in Protocol layer
  }

  @override
  Future<void> truncate(int newLength) async {
    if (!isValid) {
      throw LobError.invalidLocator();
    }
    // Implementation in Protocol layer
  }

  /// Read the CLOB as a string.
  Future<String> readAsString({int offset = 0, int? length}) async {
    final data = await read(offset: offset, amount: length);
    return encoding.decode(data);
  }

  /// Read the entire CLOB as a string.
  Future<String> readAllAsString() async {
    final data = await readAll();
    return encoding.decode(data);
  }

  /// Write a string to the CLOB.
  Future<void> writeString(String text, {int offset = 0}) async {
    final data = Uint8List.fromList(encoding.encode(text));
    await write(data, offset: offset);
  }

  /// Append a string to the CLOB.
  Future<void> appendString(String text) async {
    final data = Uint8List.fromList(encoding.encode(text));
    await append(data);
  }

  /// Stream the CLOB as strings.
  Stream<String> streamAsString({int offset = 0, int? chunkSize}) async* {
    await for (final chunk in stream(offset: offset, chunkSize: chunkSize)) {
      yield encoding.decode(chunk);
    }
  }
}

/// Binary Large Object (BLOB).
///
/// Stores binary data.
final class Blob extends Lob {
  Blob({
    required super.locator,
    super.chunkSize,
  });

  @override
  Future<Uint8List> read({int offset = 0, int? amount}) async {
    if (!isValid) {
      throw LobError.invalidLocator();
    }
    // Implementation in Protocol layer
    return Uint8List(0);
  }

  @override
  Future<void> write(Uint8List data, {int offset = 0}) async {
    if (!isValid) {
      throw LobError.invalidLocator();
    }
    // Implementation in Protocol layer
  }

  @override
  Future<void> truncate(int newLength) async {
    if (!isValid) {
      throw LobError.invalidLocator();
    }
    // Implementation in Protocol layer
  }
}

/// National Character Large Object (NCLOB).
///
/// Stores character data using the national character set (UTF-16).
final class NClob extends Lob {
  NClob({
    required super.locator,
    super.chunkSize,
  });

  @override
  Future<Uint8List> read({int offset = 0, int? amount}) async {
    if (!isValid) {
      throw LobError.invalidLocator();
    }
    // Implementation in Protocol layer
    return Uint8List(0);
  }

  @override
  Future<void> write(Uint8List data, {int offset = 0}) async {
    if (!isValid) {
      throw LobError.invalidLocator();
    }
    // Implementation in Protocol layer
  }

  @override
  Future<void> truncate(int newLength) async {
    if (!isValid) {
      throw LobError.invalidLocator();
    }
    // Implementation in Protocol layer
  }

  /// Read the NCLOB as a string.
  Future<String> readAsString({int offset = 0, int? length}) async {
    final data = await read(offset: offset, amount: length);
    // Decode as UTF-16
    final buffer = data.buffer.asUint16List();
    return String.fromCharCodes(buffer);
  }

  /// Read the entire NCLOB as a string.
  Future<String> readAllAsString() async {
    final data = await readAll();
    final buffer = data.buffer.asUint16List();
    return String.fromCharCodes(buffer);
  }
}

/// Temporary LOB for creating LOBs in memory before inserting.
class TemporaryLob {
  TemporaryLob.clob() : _type = _LobType.clob;
  TemporaryLob.blob() : _type = _LobType.blob;
  TemporaryLob.nclob() : _type = _LobType.nclob;

  // ignore: unused_field
  final _LobType _type;
  Lob? _lob;

  /// Get the underlying LOB (created on server).
  Lob? get lob => _lob;

  /// Create the temporary LOB on the server.
  Future<Lob> create() async {
    // Implementation in Protocol layer
    // Returns a Clob, Blob, or NClob based on _type
    throw UnimplementedError('Temporary LOB creation not yet implemented');
  }

  /// Free the temporary LOB.
  Future<void> free() async {
    await _lob?.free();
    _lob = null;
  }
}

enum _LobType { clob, blob, nclob }
