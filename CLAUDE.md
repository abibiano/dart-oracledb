# Claude Code Guide

This file provides guidance for Claude Code when working on this project.

## Project Overview

**oracledb** is a pure Dart Oracle Database driver implementing thin-mode TNS/TTC wire protocol. No Oracle Client libraries required.

## Architecture

Four-layer architecture (bottom to top):

```text
┌─────────────────────────────────────┐
│            API Layer                │  ← connection.dart, pool.dart, cursor.dart
├─────────────────────────────────────┤
│          Message Layer              │  ← messages/*.dart (auth, execute, fetch, etc.)
├─────────────────────────────────────┤
│         Protocol Layer              │  ← protocol/*.dart (TNS packets, TTC buffers)
├─────────────────────────────────────┤
│         Transport Layer             │  ← transport/*.dart (socket, TLS)
└─────────────────────────────────────┘
```

## Directory Structure

```text
lib/
├── oracledb.dart              # Public API exports
└── src/
    ├── constants.dart         # Protocol constants, enums
    ├── errors.dart            # Exception hierarchy (sealed classes)
    ├── types.dart             # Oracle data types (NUMBER, DATE, TIMESTAMP)
    ├── connection.dart        # OracleConnection class
    ├── pool.dart              # ConnectionPool
    ├── cursor.dart            # Query cursor handling
    ├── lob.dart               # LOB (CLOB/BLOB) support
    ├── db_object.dart         # Database object types
    ├── transport/             # Network layer
    │   ├── transport.dart
    │   ├── socket.dart
    │   └── tls.dart
    ├── protocol/              # Wire protocol
    │   ├── protocol.dart
    │   ├── tns_packet.dart    # TNS packet encoding/decoding
    │   ├── ttc_buffer.dart    # TTC data buffer
    │   └── capabilities.dart
    ├── messages/              # TTC message types
    │   ├── message.dart       # Base message class
    │   ├── auth_message.dart
    │   ├── execute_message.dart
    │   ├── fetch_message.dart
    │   └── ...
    └── crypto/                # Authentication crypto
        ├── auth.dart          # O5/O7/O8 LOGON protocols
        ├── verifier.dart
        └── session_key.dart

reference/                     # Git submodules for protocol reference
├── python-oracledb/           # Oracle's Python driver (src/oracledb/impl/thin/)
└── node-oracledb/             # Oracle's Node.js driver (lib/thin/)
```

## Key Concepts

### Oracle Wire Protocol

- **TNS (Transparent Network Substrate)**: Connection layer packets (Connect, Accept, Data, Refuse, etc.)
- **TTC (Two-Task Common)**: Data protocol over TNS Data packets
- **CLR encoding**: Chunked Long Raw - variable-length data with length bytes

### Oracle NUMBER Format

Oracle NUMBER uses base-100 encoding with sign byte:

- Byte 0: Exponent + sign (`0x80` = zero, `>0x80` = positive, `<0x80` = negative)
- Bytes 1-20: Base-100 digits (value + 1 for positive, 101 - value for negative)

### Oracle DATE Format

7-byte format: `[century, year, month, day, hour+1, minute+1, second+1]`

- Century/year use offset of 100 (e.g., 2024 = bytes [120, 124])

### Authentication Protocols

- **O5LOGON**: SHA1-based (Oracle 11g)
- **O7LOGON/O8LOGON**: PBKDF2-SHA512 (Oracle 12c+)

## Dart Conventions

- **SDK**: Dart 3.0+ (uses records, patterns, sealed classes)
- **Linting**: `package:lints/recommended.yaml` with strict mode
- **Formatting**: `dart format` (line length 80)

### Style Guidelines

- Use sealed classes for exception hierarchies
- Use records for multiple return values: `(Type1, Type2) method()`
- Use pattern matching with `switch` expressions
- Prefer `final` for local variables
- Use `Uint8List` for binary data (not `List<int>`)

## Commands

```bash
# Get dependencies
dart pub get

# Run tests
dart test

# Run specific test
dart test test/oracledb_test.dart

# Analyze code
dart analyze

# Format code
dart format .

# Generate documentation
dart doc
```

## Testing

Unit tests are in `test/`. Integration tests require an Oracle Database instance.

```bash
# Start Oracle Free for testing (Docker)
docker run -d -p 1521:1521 -e ORACLE_PASSWORD=testpassword gvenzl/oracle-free:slim-faststart
```

Supported Oracle versions:

- Oracle Free (23ai)
- Oracle XE (21c, 18c)
- Oracle Database (11g+)

## Reference Implementations

When implementing protocol features, consult:

1. **Python**: `reference/python-oracledb/src/oracledb/impl/thin/`
   - `protocol.pyx` - Main protocol handling
   - `messages.pyx` - TTC message implementations
   - `crypto.pyx` - Authentication crypto

2. **Node.js**: `reference/node-oracledb/lib/thin/`
   - `protocol/` - Protocol implementation
   - `messages/` - Message handlers

## Common Tasks

### Adding a new TTC message type

1. Add constant to `lib/src/constants.dart` (TtcMessageType enum)
2. Create message class in `lib/src/messages/`
3. Add encode/decode methods following existing patterns
4. Register in message factory (`message.dart`)

### Adding a new Oracle data type

1. Add type constant to `OracleType` enum in `constants.dart`
2. Implement type class in `types.dart` with `toBytes()`/`fromBytes()`
3. Add conversion in TTC buffer read/write methods

### Implementing a new API method

1. Add method signature to `OracleConnection` in `connection.dart`
2. Create appropriate TTC messages
3. Handle response parsing
4. Add tests

## Error Handling

Use the sealed exception hierarchy:

```dart
sealed class OracleException implements Exception { }

class OracleError extends OracleException { }      // ORA-xxxxx errors
class ConnectionError extends OracleException { }  // Network/connection issues
class ProtocolError extends OracleException { }    // Wire protocol errors
class AuthenticationError extends OracleException { } // Login failures
class DataTypeError extends OracleException { }    // Type conversion errors
```

## Dependencies

- `pointycastle`: Cryptographic operations (AES, SHA, PBKDF2)
- `decimal`: Precise decimal arithmetic for NUMBER type
- `collection`: Collection utilities
- `logging`: Structured logging
- `typed_data`: Efficient byte buffer operations
