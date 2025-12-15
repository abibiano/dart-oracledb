# Story 1.1: Project Initialization & Structure

Status: Ready for Review

## Story

As a **developer contributing to dart-oracledb**,
I want **a properly structured Dart package mirroring node-oracledb organization**,
So that **I have a maintainable foundation that enables easier upstream sync**.

## Acceptance Criteria

1. **AC1:** Project directory structure matches Architecture specification exactly
2. **AC2:** `lib/dart_oracledb.dart` exists as single public export file
3. **AC3:** `lib/src/` contains all required subdirectories: `transport/`, `protocol/`, `protocol/messages/`, `crypto/`
4. **AC4:** `test/src/` mirrors lib structure exactly
5. **AC5:** `pubspec.yaml` has Dart 3.0+ SDK constraint and all required dependencies
6. **AC6:** `analysis_options.yaml` is properly configured
7. **AC7:** `dart analyze` passes with zero warnings
8. **AC8:** Dependencies declared: `crypto`, `pointycastle`, `logging`

## Tasks / Subtasks

- [x] **Task 1: Restructure lib/src directories** (AC: 1, 3)
  - [x] 1.1: Rename `lib/src/sqlnet/` to `lib/src/transport/`
  - [x] 1.2: Create `lib/src/protocol/` directory
  - [x] 1.3: Create `lib/src/protocol/messages/` directory
  - [x] 1.4: Verify `lib/src/crypto/` exists (already present)

- [x] **Task 2: Create public API export file** (AC: 2)
  - [x] 2.1: Create `lib/dart_oracledb.dart` with placeholder exports

- [x] **Task 3: Create test directory structure** (AC: 4)
  - [x] 3.1: Create `test/src/` directory
  - [x] 3.2: Create `test/src/transport/` directory
  - [x] 3.3: Create `test/src/protocol/` directory
  - [x] 3.4: Create `test/src/protocol/messages/` directory
  - [x] 3.5: Create `test/src/crypto/` directory

- [x] **Task 4: Update pubspec.yaml** (AC: 5, 8)
  - [x] 4.1: Verify SDK constraint is `^3.0.0` (already correct)
  - [x] 4.2: Add `crypto: ^3.0.0` to dependencies
  - [x] 4.3: Add `pointycastle: ^3.9.0` to dependencies
  - [x] 4.4: Add `logging: ^1.3.0` to dependencies
  - [x] 4.5: Run `dart pub get` to fetch dependencies

- [x] **Task 5: Verify analysis configuration** (AC: 6, 7)
  - [x] 5.1: Review `analysis_options.yaml` for strict settings
  - [x] 5.2: Run `dart analyze` and ensure zero warnings
  - [x] 5.3: Run `dart format --set-exit-if-changed .` to verify formatting

## Dev Notes

### Current Project State (CRITICAL - READ FIRST)

The project has been partially initialized. Current state:

```
lib/
├── src/
│   ├── crypto/         # EXISTS (empty)
│   └── sqlnet/         # EXISTS - MUST RENAME TO transport/
```

**What needs to change:**
- `sqlnet/` → `transport/` (rename to match architecture)
- Add `protocol/` and `protocol/messages/` directories
- Create `lib/dart_oracledb.dart` export file

### Architecture Compliance (MANDATORY)

**Source:** [docs/architecture.md](../architecture.md)

**Required Directory Structure:**

```text
dart_oracledb/
├── lib/
│   ├── dart_oracledb.dart              # Public API exports only
│   └── src/
│       ├── connection.dart             # (future)
│       ├── pool.dart                   # (future)
│       ├── ...
│       ├── protocol/                   # TTC Protocol layer
│       │   ├── buffer.dart
│       │   ├── capabilities.dart
│       │   ├── constants.dart
│       │   ├── packet.dart
│       │   ├── protocol.dart
│       │   └── messages/
│       │       ├── base.dart
│       │       ├── auth_message.dart
│       │       ├── execute_message.dart
│       │       └── ...
│       │
│       ├── transport/                  # TNS Network layer (NOT sqlnet/)
│       │   ├── socket.dart
│       │   ├── tls.dart
│       │   ├── transport.dart
│       │   ├── packet.dart
│       │   └── connect_string.dart
│       │
│       └── crypto/                     # Authentication
│           ├── auth.dart
│           ├── session_key.dart
│           └── verifier.dart
│
├── test/
│   └── src/
│       ├── connection_test.dart
│       ├── protocol/
│       │   ├── buffer_test.dart
│       │   └── messages/
│       │       └── auth_message_test.dart
│       ├── transport/
│       │   └── socket_test.dart
│       └── crypto/
│           └── verifier_test.dart
```

### Library/Framework Requirements

**Dependencies to add to pubspec.yaml:**

```yaml
dependencies:
  crypto: ^3.0.0          # Cryptographic operations for authentication
  pointycastle: ^3.9.0    # Additional crypto (PBKDF2, etc.)
  logging: ^1.3.0         # Diagnostic logging

dev_dependencies:
  lints: ^6.0.0           # Already present
  test: ^1.28.0           # Already present
```

**Package name:** `oracledb` (already correct in pubspec.yaml)

### File Structure Requirements

**lib/dart_oracledb.dart content (placeholder for now):**

```dart
/// Pure Dart Oracle Database driver implementing thin-mode TNS/TTC wire protocol.
///
/// This library provides Oracle database connectivity for Dart applications
/// without requiring Oracle Client installation.
library;

// Public API exports will be added as implementation progresses
// export 'src/connection.dart' show OracleConnection;
// export 'src/pool.dart' show OraclePool;
// export 'src/result.dart' show OracleResult, OracleRow;
// export 'src/errors.dart' show OracleException;
```

### Testing Requirements

**For this story, only structural verification is needed:**

1. `dart analyze` must pass with zero warnings
2. `dart format --set-exit-if-changed .` must pass
3. `dart pub get` must complete successfully
4. Directory structure must match architecture specification

**No unit tests required for this story** - it's purely structural setup.

### Project Structure Notes

**Alignment with unified project structure:**
- Package name: `oracledb` matches pub.dev convention
- Directory follows standard Dart package layout
- Mirrors node-oracledb thin driver organization for maintainability

**Detected conflicts or variances:**
- Current `sqlnet/` directory name conflicts with architecture spec (`transport/`)
- Must rename to maintain fidelity with documented architecture

### References

- [Architecture: Project Directory Structure](../architecture.md#complete-project-directory-structure)
- [Architecture: Structural Mapping](../architecture.md#structural-mapping)
- [Architecture: Implementation Patterns](../architecture.md#implementation-patterns--consistency-rules)
- [PRD: Installation & Distribution](../prd.md#installation--distribution)
- [PRD: Dependencies](../prd.md#installation--distribution)

## Dev Agent Record

### Context Reference

Story created by SM agent using ultimate context engine analysis.

### Agent Model Used

Claude Opus 4.5

### Debug Log References

N/A - structural story

### Completion Notes List

- All 5 tasks and 17 subtasks completed successfully
- Directory structure now matches architecture specification exactly
- `lib/src/sqlnet/` renamed to `lib/src/transport/` per architecture doc
- Created `lib/src/protocol/` and `lib/src/protocol/messages/` directories
- Public API export file `lib/dart_oracledb.dart` created with placeholder exports
- Test directory structure mirrors lib structure with .gitkeep files for git tracking
- Dependencies added: `crypto: ^3.0.0`, `pointycastle: ^3.9.0`, `logging: ^1.3.0`
- `dart analyze` passes with zero warnings
- `dart format --set-exit-if-changed .` passes
- No unit tests required per story spec (structural setup only)

### Change Log

- 2025-12-15: Story implementation completed - all tasks done, all ACs satisfied

### File List

**Files created:**
- `lib/dart_oracledb.dart`
- `test/src/.gitkeep`
- `test/src/transport/.gitkeep`
- `test/src/protocol/.gitkeep`
- `test/src/protocol/messages/.gitkeep`
- `test/src/crypto/.gitkeep`

**Directories created:**
- `lib/src/protocol/`
- `lib/src/protocol/messages/`
- `test/src/`
- `test/src/transport/`
- `test/src/protocol/`
- `test/src/protocol/messages/`
- `test/src/crypto/`

**Directories renamed:**
- `lib/src/sqlnet/` → `lib/src/transport/`

**Files modified:**
- `pubspec.yaml` (added crypto, pointycastle, logging dependencies)
- `pubspec.lock` (auto-generated from dart pub get)
