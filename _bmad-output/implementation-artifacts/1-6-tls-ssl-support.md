# Story 1.6: TLS/SSL Support

Status: done

## Story

As a **developer using dart-oracledb**,
I want **TLS/SSL encrypted connections**,
So that **I can securely connect to production Oracle databases** (FR3, NFR6).

## Acceptance Criteria

1. **AC1:** Given an Oracle database configured for TLS, when connecting with TLS enabled, then the connection is encrypted using TLS/SSL
2. **AC2:** Given TLS is enabled, then certificate validation occurs by default (verifiable via Dart SecureSocket behavior)
3. **AC3:** Given a TLS configuration, when certificate validation is explicitly disabled (`verifyCertificate: false`), then self-signed certificates are accepted
4. **AC4:** Given TLS is required but server doesn't support it, when connection is attempted, then a clear `OracleException` is thrown indicating TLS negotiation failed
5. **AC5:** Given the existing OracleConnection API, when adding TLS support, then it is backward compatible (TLS disabled by default)

## Tasks / Subtasks

- [x] **Task 1: Create TLS Support in OracleSocket** (AC: 1, 2, 3, 4)
  - [x] 1.1: Add `upgradeToTls()` method to `lib/src/transport/socket.dart`
  - [x] 1.2: Use `SecureSocket.secure()` to upgrade existing TCP socket to TLS
  - [x] 1.3: Accept `SecurityContext` parameter for custom certificate handling
  - [x] 1.4: Accept `onBadCertificate` callback for self-signed certs
  - [x] 1.5: Rewire `_socket` and `_subscription` after TLS upgrade
  - [x] 1.6: Handle TLS handshake errors with appropriate OracleException

- [x] **Task 2: Create TLS Configuration Class** (AC: 1, 2, 3, 5)
  - [x] 2.1: Create `lib/src/transport/tls.dart` with `TlsConfig` class
  - [x] 2.2: Add `enabled` property (default: false for backward compatibility)
  - [x] 2.3: Add `verifyCertificate` property (default: true)
  - [x] 2.4: Add optional `securityContext` property for custom CA certs
  - [x] 2.5: Add factory `TlsConfig.enabled()` for quick TLS enable

- [x] **Task 3: Integrate TLS into Transport Layer** (AC: 1, 4)
  - [x] 3.1: Add `tlsConfig` parameter to `Transport.connect()`
  - [x] 3.2: After TCP connect, if TLS enabled, call `socket.upgradeToTls()`
  - [x] 3.3: Pass TlsConfig settings to upgrade method
  - [x] 3.4: Ensure TLS upgrade happens BEFORE TNS handshake

- [x] **Task 4: Update OracleConnection API** (AC: 1, 5)
  - [x] 4.1: Add `tls` parameter to `OracleConnection.connect()` (type: `TlsConfig?`)
  - [x] 4.2: Pass TlsConfig to Transport.connect()
  - [x] 4.3: Update TNS connect string to include TLS protocol indicator if enabled
  - [x] 4.4: Maintain backward compatibility (null = no TLS)

- [x] **Task 5: Add TLS Error Codes** (AC: 4)
  - [x] 5.1: Add `oraTlsHandshakeFailed` constant (28860) to errors.dart
  - [x] 5.2: Add `oraTlsCertificateError` constant (28862) to errors.dart
  - [x] 5.3: Map TLS-specific exceptions to appropriate error codes

- [x] **Task 6: Update Public Exports** (AC: all)
  - [x] 6.1: Export `TlsConfig` from `lib/dart_oracledb.dart`
  - [x] 6.2: Export TLS error codes from `lib/dart_oracledb.dart`

- [x] **Task 7: Write Unit Tests** (AC: all)
  - [x] 7.1: Create `test/src/transport/tls_test.dart`
  - [x] 7.2: Test TlsConfig defaults (enabled: false, verifyCertificate: true)
  - [x] 7.3: Test TlsConfig.enabled() factory
  - [x] 7.4: Test OracleSocket.upgradeToTls() with mock (connection state changes)
  - [x] 7.5: Test TLS error mapping to OracleException

- [x] **Task 8: Integration Tests** (AC: 1, 4)
  - [x] 8.1: Create `test/integration/tls_integration_test.dart`
  - [x] 8.2: Test TLS connection to Oracle 23ai (requires TLS-enabled Oracle)
  - [x] 8.3: Test TLS failure when connecting to non-TLS port
  - [x] 8.4: Test certificate validation error handling
  - [x] 8.5: Skip tests if RUN_INTEGRATION_TESTS not set or no TLS Oracle available

- [x] **Task 9: Finalize and Validate** (AC: all)
  - [x] 9.1: Run `dart analyze` with zero warnings
  - [x] 9.2: Run `dart format --set-exit-if-changed .`
  - [x] 9.3: Verify all existing tests still pass with `dart test`
  - [x] 9.4: Update README with TLS usage example

## Dev Notes

### TLS Implementation Design

Oracle databases support TLS connections on a separate port or via in-band upgrade. The dart-oracledb driver will implement TLS by upgrading the TCP socket BEFORE the TNS protocol handshake begins.

**TLS Upgrade Flow:**
```
1. TCP Connect (Socket.connect)
2. TLS Upgrade (SecureSocket.secure)  <-- NEW
3. TNS CONNECT/ACCEPT handshake
4. Oracle Authentication
5. Connection ready
```

### TlsConfig Class Design

```dart
// lib/src/transport/tls.dart
import 'dart:io';

/// Configuration for TLS/SSL connections to Oracle databases.
///
/// TLS is disabled by default for backward compatibility. Enable TLS
/// for production connections to encrypt data in transit.
///
/// Example usage:
/// ```dart
/// // Enable TLS with certificate validation (recommended for production)
/// final connection = await OracleConnection.connect(
///   'db.example.com:2484/ORCL',  // TLS port typically 2484
///   user: 'system',
///   password: 'password',
///   tls: TlsConfig.enabled(),
/// );
///
/// // Disable certificate validation for self-signed certs (dev only)
/// final devConnection = await OracleConnection.connect(
///   'localhost:2484/ORCL',
///   user: 'system',
///   password: 'password',
///   tls: TlsConfig(enabled: true, verifyCertificate: false),
/// );
/// ```
class TlsConfig {
  /// Creates a TLS configuration.
  ///
  /// By default, TLS is disabled and certificate verification is enabled.
  const TlsConfig({
    this.enabled = false,
    this.verifyCertificate = true,
    this.securityContext,
  });

  /// Creates a TLS configuration with TLS enabled.
  ///
  /// Certificate verification is enabled by default.
  factory TlsConfig.enabled({
    bool verifyCertificate = true,
    SecurityContext? securityContext,
  }) {
    return TlsConfig(
      enabled: true,
      verifyCertificate: verifyCertificate,
      securityContext: securityContext,
    );
  }

  /// Whether TLS is enabled for the connection.
  final bool enabled;

  /// Whether to verify the server's TLS certificate.
  ///
  /// Set to `false` only for development with self-signed certificates.
  /// NEVER disable in production - this defeats the purpose of TLS.
  final bool verifyCertificate;

  /// Custom security context for certificate verification.
  ///
  /// Use this to specify custom CA certificates for enterprise PKI.
  final SecurityContext? securityContext;
}
```

### OracleSocket TLS Upgrade Method

```dart
// Add to lib/src/transport/socket.dart

/// Upgrades the current TCP connection to TLS.
///
/// This must be called BEFORE any TNS protocol communication.
/// The upgrade replaces the underlying socket with a SecureSocket.
///
/// Throws [OracleException] if TLS handshake fails.
Future<void> upgradeToTls({
  required String host,
  bool verifyCertificate = true,
  SecurityContext? securityContext,
}) async {
  if (!isConnected) {
    throw const OracleException(
      errorCode: oraProtocolError,
      message: 'Cannot upgrade to TLS: socket is not connected',
    );
  }

  _log.fine('Upgrading connection to TLS');

  try {
    // Cancel existing subscription before upgrade
    await _subscription?.cancel();
    _subscription = null;

    // Upgrade to TLS
    final secureSocket = await SecureSocket.secure(
      _socket!,
      host: host,
      context: securityContext,
      onBadCertificate: verifyCertificate
          ? null
          : (X509Certificate cert) {
              _log.warning('Accepting unverified certificate: ${cert.subject}');
              return true;
            },
    );

    // Replace socket with secure socket
    _socket = secureSocket;
    _log.info('TLS upgrade successful');

    // Re-establish data listener on secure socket
    _subscription = _socket!.listen(
      (Uint8List data) {
        _log.fine('Received ${data.length} bytes (TLS)');
        _pendingData.addAll(data);
        if (_dataAvailable != null && !_dataAvailable!.isCompleted) {
          _dataAvailable!.complete();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _log.warning('TLS socket error', error, stackTrace);
        _handleError(error);
      },
      onDone: () {
        _log.fine('TLS socket closed by remote');
        _cleanup();
      },
    );
  } on HandshakeException catch (e) {
    _log.warning('TLS handshake failed: $e');
    throw OracleException(
      errorCode: oraTlsHandshakeFailed,
      message: 'TLS handshake failed: ${e.message}',
      cause: e,
    );
  } on CertificateException catch (e) {
    _log.warning('TLS certificate error: $e');
    throw OracleException(
      errorCode: oraTlsCertificateError,
      message: 'TLS certificate verification failed: ${e.message}',
      cause: e,
    );
  } catch (e) {
    _log.severe('Unexpected TLS error', e);
    throw OracleException(
      errorCode: oraTlsHandshakeFailed,
      message: 'Failed to establish TLS connection: $e',
      cause: e,
    );
  }
}
```

### Architecture Compliance (MANDATORY)

**Source:** [docs/architecture.md](../architecture.md)

**Target Files (create/modify these):**
- `lib/src/transport/tls.dart` - NEW: TlsConfig class
- `lib/src/transport/socket.dart` - MODIFY: Add upgradeToTls() method
- `lib/src/transport/transport.dart` - MODIFY: Add tlsConfig parameter
- `lib/src/connection.dart` - MODIFY: Add tls parameter to connect()
- `lib/src/errors.dart` - MODIFY: Add TLS error codes
- `test/src/transport/tls_test.dart` - NEW: TLS unit tests
- `test/integration/tls_integration_test.dart` - NEW: TLS integration tests

**Existing Files (REUSE - understand their patterns):**
- `lib/src/transport/socket.dart` - OracleSocket class (study for upgrade pattern)
- `lib/src/transport/transport.dart` - Transport class (study for parameter passing)
- `lib/src/connection.dart` - OracleConnection class (study for API pattern)
- `lib/src/errors.dart` - Error codes and OracleException

### Error Handling Patterns (CRITICAL)

**TLS Error Code Mapping:**

| Scenario | Error Code | Constant |
|----------|------------|----------|
| TLS handshake failure | 28860 | `oraTlsHandshakeFailed` |
| Certificate verification failure | 28862 | `oraTlsCertificateError` |

**Add to errors.dart:**
```dart
/// TLS/SSL error codes
const int oraTlsHandshakeFailed = 28860; // ORA-28860: Fatal SSL error
const int oraTlsCertificateError = 28862; // ORA-28862: SSL cert verify failed
```

**Error Wrapping Pattern (from Story 1.5):**
```dart
try {
  await SecureSocket.secure(socket, host: host);
} catch (e) {
  if (e is OracleException) rethrow;
  if (e is HandshakeException) {
    throw OracleException(
      errorCode: oraTlsHandshakeFailed,
      message: 'TLS handshake failed: ${e.message}',
      cause: e,
    );
  }
  throw OracleException(
    errorCode: oraTlsHandshakeFailed,
    message: 'TLS connection failed',
    cause: e,
  );
}
```

### File Structure Requirements

**Directory Structure (must follow):**
```
lib/src/
├── connection.dart              # MODIFY - Add tls parameter
├── errors.dart                  # MODIFY - Add TLS error codes
└── transport/
    ├── tls.dart                 # NEW - TlsConfig class
    ├── socket.dart              # MODIFY - Add upgradeToTls()
    └── transport.dart           # MODIFY - Add tlsConfig parameter
```

**Test Structure (mirrors lib/src/):**
```
test/
├── src/
│   └── transport/
│       └── tls_test.dart        # NEW - TLS unit tests
└── integration/
    └── tls_integration_test.dart # NEW - TLS integration tests
```

### Testing Requirements

**Unit Tests Required:**
1. TlsConfig default values (enabled: false, verifyCertificate: true)
2. TlsConfig.enabled() factory creates correct config
3. TlsConfig with custom SecurityContext
4. OracleSocket.upgradeToTls() state changes
5. TLS error mapping to OracleException

**Unit Test Pattern:**
```dart
// test/src/transport/tls_test.dart
import 'package:test/test.dart';
import 'package:dart_oracledb/dart_oracledb.dart';

void main() {
  group('TlsConfig', () {
    test('default values', () {
      final config = TlsConfig();
      expect(config.enabled, isFalse);
      expect(config.verifyCertificate, isTrue);
      expect(config.securityContext, isNull);
    });

    test('enabled() factory creates enabled config', () {
      final config = TlsConfig.enabled();
      expect(config.enabled, isTrue);
      expect(config.verifyCertificate, isTrue);
    });

    test('enabled() with verifyCertificate false', () {
      final config = TlsConfig.enabled(verifyCertificate: false);
      expect(config.enabled, isTrue);
      expect(config.verifyCertificate, isFalse);
    });
  });
}
```

**Integration Test Pattern:**
```dart
// test/integration/tls_integration_test.dart
@Tags(['integration'])
import 'dart:io';
import 'package:test/test.dart';
import 'package:dart_oracledb/dart_oracledb.dart';

void main() {
  final hasOracle = Platform.environment.containsKey('RUN_INTEGRATION_TESTS');
  final hasTlsOracle = Platform.environment.containsKey('ORACLE_TLS_PORT');

  group('TLS connection', skip: !hasOracle || !hasTlsOracle, () {
    test('connects with TLS enabled', () async {
      final tlsPort = int.parse(Platform.environment['ORACLE_TLS_PORT'] ?? '2484');
      final connection = await OracleConnection.connect(
        'localhost:$tlsPort/FREEPDB1',
        user: 'system',
        password: 'testpassword',
        tls: TlsConfig.enabled(),
      );

      expect(connection.isConnected, isTrue);
      await connection.close();
    });

    test('fails TLS on non-TLS port', () async {
      await expectLater(
        OracleConnection.connect(
          'localhost:1521/FREEPDB1',  // Non-TLS port
          user: 'system',
          password: 'testpassword',
          tls: TlsConfig.enabled(),
        ),
        throwsA(isA<OracleException>()
            .having((e) => e.errorCode, 'errorCode', oraTlsHandshakeFailed)),
      );
    });
  });

  group('TLS without Oracle', skip: hasOracle, () {
    test('TLS error handling with mock server', () async {
      // Test TLS error handling without requiring Oracle
    });
  });
}
```

### Previous Story Intelligence

**From Story 1.5 (Connection API & Error Handling):**
- `OracleConnection.connect()` orchestrates: parseEZConnect() -> Transport.connect() -> TNS handshake -> AuthFlow
- Error wrapping pattern: check `if (e is OracleException) rethrow` before wrapping
- Password is NEVER logged or included in error messages
- Integration tests use `@Tags(['integration'])` and skip when env var not set
- All files pass `dart analyze` with zero warnings

**From Story 1.5 Completion Notes:**
- Full Oracle integration tests fail due to pre-existing TNS protocol layer issue (socket closes during handshake)
- This may affect TLS integration testing as well

**From OracleSocket implementation:**
- Socket uses `_subscription` for data listening
- `_pendingData` buffer holds incoming bytes
- `_dataAvailable` completer signals when data arrives
- `_cleanup()` resets all state on disconnect

### Git Intelligence

**Recent commits:**
```
b17a3ee feat: Implement Oracle authentication protocol with SHA512 and PBKDF2 verifiers
3669cfa Implement TTC Packet Structure and Protocol Tests
9a6dcbc Add comprehensive tests for Oracle database connection and protocol handling
```

**Patterns from previous stories:**
- All files pass `dart analyze` with zero warnings
- All files pass `dart format`
- Tests mirror lib/src/ structure exactly
- Logging uses `package:logging` with Logger per class
- Error codes defined as `const int` in errors.dart

### Dart SecureSocket API Reference

**Key SecureSocket methods:**
```dart
// Upgrade existing socket to TLS
static Future<SecureSocket> secure(
  Socket socket, {
  String? host,
  SecurityContext? context,
  bool Function(X509Certificate)? onBadCertificate,
  List<String>? supportedProtocols,
})

// Create new TLS connection directly
static Future<SecureSocket> connect(
  dynamic host,
  int port, {
  SecurityContext? context,
  bool Function(X509Certificate)? onBadCertificate,
  List<String>? supportedProtocols,
  Duration? timeout,
})
```

**TLS Exceptions in Dart:**
- `HandshakeException` - TLS handshake failed
- `CertificateException` - Certificate validation failed
- `TlsException` - General TLS error

### Oracle TLS Configuration Notes

**Oracle 23ai TLS Ports:**
- Default non-TLS: 1521
- Default TLS: 2484 (configurable)

**TNS Descriptor with TLS:**
```
(DESCRIPTION=
  (ADDRESS=(PROTOCOL=TCPS)(HOST=host)(PORT=2484))
  (CONNECT_DATA=(SERVICE_NAME=FREEPDB1)))
```

Note: PROTOCOL=TCPS indicates TLS. However, since we upgrade after TCP connect, we may still use TCP in the descriptor and rely on in-band upgrade.

### Anti-Patterns to Avoid

1. **DO NOT** modify socket listeners without canceling existing subscription first
2. **DO NOT** disable certificate verification in production examples
3. **DO NOT** log sensitive connection strings with credentials
4. **DO NOT** catch and swallow TLS exceptions without proper error code mapping
5. **DO NOT** forget to re-establish listeners after socket upgrade
6. **DO NOT** change the API signature in a breaking way (tls parameter must be optional)

### Project Structure Notes

- Alignment with architecture: `lib/src/transport/tls.dart` as specified in architecture.md
- Export via `lib/dart_oracledb.dart` - single public export file
- Tests in `test/src/transport/tls_test.dart` mirroring lib structure

### References

- [Architecture: Project Structure](../architecture.md#complete-project-directory-structure) - tls.dart location
- [Architecture: Error Handling](../architecture.md#error-handling-patterns) - Error wrapping pattern
- [Architecture: Resource Management](../architecture.md#resource-management-patterns) - Socket handling
- [PRD: FR3 TLS/SSL Support](../prd.md) - TLS requirement
- [PRD: NFR6 Security](../prd.md) - TLS encryption for production
- [Epic 1: Story 1.6 Requirements](../epics.md#story-16-tlsssl-support)
- [Story 1.5: Connection API & Error Handling](./1-5-connection-api-error-handling.md) - API pattern
- [Dart SecureSocket docs](https://api.dart.dev/stable/dart-io/SecureSocket-class.html)

## Dev Agent Record

### Context Reference

Story created by SM agent using ultimate context engine analysis. YOLO mode enabled.

### Agent Model Used

Claude Opus 4.5 (claude-opus-4-5-20251101)

### Debug Log References

N/A

### Completion Notes List

- Implemented TlsConfig class with enabled/verifyCertificate/securityContext properties
- Added upgradeToTls() method to OracleSocket with proper error handling and cleanup
- Integrated TLS into Transport.connect() with tlsConfig parameter
- Updated OracleConnection.connect() with optional tls parameter (backward compatible)
- Added TLS error codes: oraTlsHandshakeFailed (28860), oraTlsCertificateError (28862)
- All exports added to lib/dart_oracledb.dart
- TLS unit tests: 7 tests in tls_test.dart, 5 tests in socket_tls_test.dart
- TLS integration tests: 8 tests (skipped when no Oracle/TLS available)
- README updated with TLS usage examples
- Code review fix: Added socket cleanup in TLS error paths (close_sinks warning)

### Change Log

- 2025-12-15: Story drafted by SM agent with comprehensive context analysis
- 2025-12-15: Story implementation complete
- 2025-12-15: Code review fix - Added socket cleanup in TLS error paths to resolve dart analyze warning

### File List

**Files Created:**
- `lib/src/transport/tls.dart` - TlsConfig class
- `test/src/transport/tls_test.dart` - TlsConfig unit tests (7 tests)
- `test/src/transport/socket_tls_test.dart` - OracleSocket TLS unit tests (5 tests)
- `test/integration/tls_integration_test.dart` - Integration tests (8 tests)

**Files Modified:**
- `lib/src/transport/socket.dart` - Add upgradeToTls() method with proper cleanup
- `lib/src/transport/transport.dart` - Add tlsConfig parameter to connect()
- `lib/src/connection.dart` - Add tls parameter to connect(), TLS protocol in TNS string
- `lib/src/errors.dart` - Add TLS error codes (oraTlsHandshakeFailed, oraTlsCertificateError)
- `lib/dart_oracledb.dart` - Export TlsConfig and TLS error codes
- `lib/src/crypto/auth.dart` - Minor formatting (line wrap)
- `README.md` - Add TLS/SSL usage documentation section
