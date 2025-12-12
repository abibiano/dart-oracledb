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
    ├── protocol/              # Wire protocol (matches node-oracledb structure)
    │   ├── buffer.dart        # BaseBuffer, GrowableBuffer
    │   ├── packet.dart        # ReadPacket, WritePacket
    │   ├── protocol.dart      # Protocol class
    │   ├── capabilities.dart  # Capabilities negotiation
    │   ├── constants.dart     # Protocol constants
    │   ├── utils.dart         # Utility functions
    │   ├── encrypt_decrypt.dart # AES encryption
    │   ├── tns_packet.dart    # TNS packet encoding/decoding
    │   └── messages/          # TTC message types
    │       ├── base.dart      # Base Message class
    │       ├── with_data.dart # MessageWithData (row handling)
    │       ├── auth.dart      # Authentication
    │       ├── fast_auth.dart # Fast Auth (Oracle 23+)
    │       ├── execute.dart   # SQL execution
    │       ├── fetch.dart     # Row fetching
    │       └── ...
    └── crypto/                # Authentication crypto
        ├── auth.dart          # O5/O7/O8 LOGON protocols
        ├── verifier.dart
        └── session_key.dart

reference/                     # Git submodule for protocol reference
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

## Reference Implementation

When implementing protocol features, consult **node-oracledb** (`reference/node-oracledb/lib/thin/`):

- `protocol/constants.js` - Protocol constants (~870 lines, 400+ constants)
- `protocol/capabilities.js` - Capabilities negotiation
- `protocol/packet.js` - ReadPacket/WritePacket buffer classes
- `protocol/protocol.js` - Main protocol class
- `protocol/utils.js` - Utility functions (encodeRowID, obfuscation)
- `protocol/encryptDecrypt.js` - AES encryption for authentication
- `protocol/messages/` - All message classes:
  - `base.js` - Base Message class
  - `withData.js` - MessageWithData (row handling)
  - `auth.js` - Authentication (OSESSKEY/OAUTH)
  - `fastAuth.js` - Fast Auth (Oracle 23+)
  - `protocol.js` - Protocol negotiation
  - `dataType.js` - Data type negotiation
  - `execute.js`, `fetch.js` - SQL execution
  - `commit.js`, `rollback.js`, `ping.js`, `logOff.js` - Basic operations
  - `lobOp.js` - LOB operations
- `impl/datahandlers/buffer.js` - BaseBuffer with all read/write methods

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
