# Contributing to dart-oracledb

Thank you for your interest in contributing! This document explains how to set up the development environment, run tests, and submit changes.

## Development Setup

**Requirements:**
- Dart SDK >= 3.3.0
- Docker (for integration tests)
- Git

```bash
git clone https://github.com/abibiano/dart-oracledb.git
cd dart-oracledb
dart pub get
```

## Running Tests

### Unit tests (no database required)

```bash
dart test test/src/
```

Expected output: ~490 tests passing.

### Integration tests

Integration tests require Oracle Database instances running in Docker.

**Start the databases:**

```bash
# Oracle 23ai (primary target)
docker compose up -d

# Oracle 21c (secondary target — required for all new features)
# On Apple Silicon, run inside a Colima x86_64 VM (see below); always name
# the service to avoid accidentally spinning up 23ai inside Colima too.
docker compose --profile oracle21c up -d oracle21c
```

**Apple Silicon (M-series Macs):** Oracle has no native ARM64 build for 21c, so
the `gvenzl/oracle-xe:21` image runs under x86_64 emulation. Docker Desktop's
built-in emulation is unreliable for Oracle (init crashes), so run 21c inside a
dedicated Colima x86_64 VM:

```bash
brew install colima qemu lima-additional-guestagents
colima start --arch x86_64 --cpu 6 --memory 8   # 2 CPU / 4 GB crashes init (ORA-04021)
docker context use colima                        # 21c lives in this VM
docker compose --profile oracle21c up -d oracle21c
```

- **Name the service** (`... up -d oracle21c`). A bare `--profile oracle21c up -d`
  also starts the profile-less 23ai service inside Colima (emulated, wasteful).
- **23ai stays on Docker Desktop** (native ARM64 image). Switch back with
  `docker context use desktop-linux` and `docker compose up -d`.
- Both DBs can run at once — they're separate VMs publishing different host
  ports (23ai → `localhost:1521`, 21c → `localhost:1522`), so tests reach both.
- `docker context` only changes which daemon the `docker` CLI targets; it does
  not stop the other VM's containers.

Wait up to 5 minutes for the databases to initialize. You can check readiness with:

```bash
docker compose ps
```

When the status shows `healthy`, run the tests:

```bash
# Run against Oracle 23ai
RUN_INTEGRATION_TESTS=true dart test test/integration/

# Run against Oracle 21c
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/
```

> **Important:** All new features and bug fixes must pass integration tests on **both** Oracle 23ai and Oracle 21c before being considered complete. Running only one version is not sufficient.

### Static analysis

```bash
dart analyze
```

All code must produce zero warnings.

## Code Style

- Use single quotes for strings
- Use `const` constructors where possible
- Use `final` for non-reassigned variables
- Never use `print()` — use `package:logging` instead
- When working with the internal `Buffer` class, always use explicit-endianness methods (`readUint16BE`, `writeUint32LE`, etc.) — Oracle's TNS/TTC protocol uses mixed endianness

## Project Architecture

```
lib/
  src/
    connection.dart       # OracleConnection class and factory methods
    result.dart           # OracleResult, OracleRow
    errors.dart           # OracleException and error codes
    crypto/               # Authentication crypto (PBKDF2, HMAC-SHA512)
    protocol/             # TTC message encoding/decoding
    transport/            # TCP socket and packet framing
test/
  src/                    # Unit tests (mirror lib/src/ structure)
  integration/            # Integration tests (require live database)
    test_helper.dart      # Connection params from env vars
```

Connection parameters in integration tests always come from environment variables via `test_helper.dart`. The helper defines default values (e.g. `FREEPDB1`, port `1521`) — `test_helper.dart` is the one permitted place for those defaults. Never hardcode them directly in individual test files.

## Adding Protocol Features

The implementation follows Oracle's thin-client protocol as described in [node-oracledb](https://github.com/oracle/node-oracledb). The `reference/` directory contains the node-oracledb source as a git submodule:

```bash
git submodule update --init --recursive
```

When implementing new protocol features:

1. Use the node-oracledb source in `reference/node-oracledb/lib/thin/` as the reference implementation.
2. Write unit tests for message encoding/decoding.
3. Write integration tests that verify behavior against a real Oracle instance.
4. Validate against both Oracle 23ai and Oracle 21c.

## Submitting a Pull Request

1. Fork the repository and create a feature branch.
2. Make your changes and ensure all tests pass on both Oracle versions.
3. Run `dart analyze` — zero warnings required.
4. Run `dart format .` — consistent formatting is required.
5. Submit a pull request with a clear description of what changed and why.

## Reporting Issues

Please use the [issue tracker](https://github.com/abibiano/dart-oracledb/issues). Include:
- Oracle version
- Dart SDK version
- Minimal reproduction case
- Observed vs. expected behavior
