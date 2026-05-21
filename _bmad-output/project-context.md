---
project_name: 'dart_oracledb'
user_name: 'Alex'
date: '2025-12-15'
sections_completed: ['technology_stack', 'dart_language_rules', 'protocol_rules', 'testing_error_handling', 'critical_rules']
existing_patterns_found: 8
status: 'complete'
---

# Project Context for AI Agents

_This file contains critical rules and patterns that AI agents must follow when implementing code in this project. Focus on unobvious details that agents might otherwise miss._

---

## Technology Stack & Versions

| Technology | Version | Notes |
|------------|---------|-------|
| Dart SDK | ^3.0.0 | Pure Dart, no FFI |
| package:crypto | latest | SHA-512 hashing |
| pointycastle | latest | PBKDF2 key derivation |
| package:logging | latest | Diagnostic output |
| package:test | ^1.28.0 | Integration testing |
| package:lints | ^6.0.0 | Strict analysis |

**Target Databases:**
- **Oracle 23ai** (primary) — Docker: `container-registry.oracle.com/database/free`, service `FREEPDB1` on port 1521. Uses the FAST_AUTH protocol.
- **Oracle pre-23 (12c+)** (supported via fallback) — Docker: `gvenzl/oracle-xe:21`, service `XEPDB1` on port 1522 (CI: 1521 inside container). Uses the classical AUTH_PHASE_ONE/AUTH_PHASE_TWO sequence.

**Auth path is server-driven**, not version-driven: `Transport.supportsFastAuth` is set from the `TNS_ACCEPT_FLAG_FAST_AUTH` bit in the TNS ACCEPT packet. `AuthFlow.authenticate` branches on that flag. Do not parse version strings to choose the auth path; do not assume FAST_AUTH is universally available.

**Platforms:** Desktop only (macOS, Windows, Linux) - no web/mobile due to dart:io Socket requirement

## Dart Language Rules

### Analyzer Strictness (MUST PASS)

- `strict-casts: true` - No implicit dynamic casts
- `strict-inference: true` - No inferred dynamic types
- `strict-raw-types: true` - No raw generic types
- All code must pass `dart analyze` with **zero warnings**

### Style Requirements

- `prefer_single_quotes` - Use `'string'` not `"string"`
- `prefer_const_constructors` - Use `const` where possible
- `prefer_final_locals` - Use `final` for non-reassigned variables
- `avoid_print` - Use `package:logging` instead

### Async Patterns

- Always `await` Futures immediately when produced
- Use `unawaited()` if intentionally not awaiting
- Close all `Stream` subscriptions (`cancel_subscriptions` rule)
- Close all `Sink` objects (`close_sinks` rule)

### Import Conventions

- Use relative imports within `lib/src/`
- Use `package:dart_oracledb/` only in tests and examples
- Order: dart:, package:, relative imports

## Protocol Implementation Rules

### Buffer Byte Order (CRITICAL)

Oracle TNS/TTC uses **mixed endianness**. ALWAYS use explicit endianness methods:

```dart
// CORRECT - Endianness explicit in method name
final value = buffer.readUint16BE();  // Big-endian
buffer.writeUint32LE(value);          // Little-endian

// WRONG - Never use ambiguous methods
final value = buffer.readUint16();    // Which endian?
```

**Required methods:** `readUint16BE()`, `writeUint32BE()`, `*LE()` variants

### Oracle Data Type Encoding

- **NUMBER**: Encoded in base-100, NOT binary. Special handling required.
- **DATE**: 7-byte format (century, year, month, day, hour, min, sec)
- **VARCHAR2**: Length-prefixed, Oracle character set encoding
- **NULL**: Represented as length byte = 0 or 0xFF depending on context

### TNS Packet Structure

- Length field is big-endian, includes header size
- Always validate packet type before processing
- Checksum may be zero for modern Oracle versions

### Authentication Flow

Two logical phases must complete (AUTH_PHASE_ONE → AUTH_PHASE_TWO), but the *transport-layer* sequence depends on `transport.supportsFastAuth`:

- **FAST_AUTH path (23ai, supportsFastAuth=true):** single round-trip — `transport.sendFastAuth()` bundles Protocol + DataTypes + AUTH_PHASE_ONE. AUTH_PHASE_TWO sent separately with `dataFlags: 0x0800`.
- **Classical path (pre-23, supportsFastAuth=false):** four messages — `sendProtocolNegotiation()` (Protocol + DataTypes), then `sendAuthPhaseOne()` with `dataFlags: 0x0000`, then AUTH_PHASE_TWO with `dataFlags: 0x0000`.

The branch lives in `lib/src/crypto/auth.dart` `AuthFlow.authenticate`. Never call `sendFastAuth` unconditionally — always gate on `transport.supportsFastAuth`.

**Security:** Never store or log passwords — only derived keys.

## Testing Rules

### Integration-First Approach

- All tests run against **a real Oracle server** in Docker — no mocking of database connections.
- Test file structure mirrors `lib/src/` exactly. Test files use `_test.dart` suffix.
- Integration tests use `test/integration/test_helper.dart` to read connection params from env (`ORACLE_HOST`, `ORACLE_PORT`, `ORACLE_SERVICE`, `ORACLE_USER`, `ORACLE_PASSWORD`) so the same suite runs against either Oracle version. Never hardcode `FREEPDB1`, `XEPDB1`, port numbers, or credentials in test files.

### Test Environments

| Profile | Image | Service | Host port | Auth path exercised |
|---------|-------|---------|-----------|--------------------|
| Default (23ai) | `container-registry.oracle.com/database/free` | `FREEPDB1` | 1521 | FAST_AUTH |
| `oracle21c` profile (`docker-compose --profile oracle21c up -d`) | `gvenzl/oracle-xe:21` | `XEPDB1` | 1522 | Classical AUTH_PHASE_ONE/TWO |

CI runs both via the `integration` and `integration-21c` jobs. Auth-flow-specific tests (e.g. `classical_auth_integration_test.dart`) auto-skip on the wrong server using a `Transport.supportsFastAuth` probe.

## Error Handling Rules

### OracleException Pattern

Always preserve error context with `cause` parameter:

```dart
// CORRECT - Preserve original error
throw OracleException(
  errorCode: 12170,
  message: 'TNS connection lost',
  cause: originalError,  // REQUIRED
);

// WRONG - Lost debugging context
throw OracleException(errorCode: 12170, message: 'TNS connection lost');
```

### Resource Cleanup

ALL resources must have:

1. Explicit `close()` method
2. Auto-close wrapper (e.g., `withConnection()`)

```dart
// Always use try-finally for explicit cleanup
final conn = await OracleConnection.connect(...);
try {
  await conn.execute('SELECT ...');
} finally {
  await conn.close();  // ALWAYS close
}
```

## Critical Don't-Miss Rules

### Anti-Patterns to Avoid

**Protocol Buffer Mistakes:**
```dart
// WRONG - Ambiguous byte order
buffer.writeUint16(length);

// CORRECT - Always explicit
buffer.writeUint16BE(length);  // TNS headers are BE
```

**Connection Lifecycle:**
```dart
// WRONG - Connection leak
final conn = await OracleConnection.connect(...);
await conn.execute('SELECT ...');
// Missing close!

// CORRECT - Always ensure cleanup
final conn = await OracleConnection.connect(...);
try {
  await conn.execute('SELECT ...');
} finally {
  await conn.close();
}
```

### Edge Cases Agents Must Handle

- **Empty Result Sets** - `execute()` returns empty list, not null
- **NULL Values** - Oracle NULL vs empty string are distinct
- **Large Numbers** - Oracle NUMBER can exceed Dart `int` range
- **CLOB/BLOB** - Require streaming, not direct fetch
- **Connection Timeout** - TNS timeout vs socket timeout are separate

### Security Rules

- **Never log passwords** - Only derived session keys
- **Never store credentials in code** - Use environment variables
- **Validate all SQL** - Prefer bind parameters over string interpolation
- **Close connections on error** - Prevent connection pool exhaustion

### Performance Gotchas

- **Statement caching** - Reuse prepared statements
- **Fetch size** - Large result sets need pagination
- **Pool sizing** - Match to connection count, not request count
- **Async discipline** - Never block on Future in protocol code
