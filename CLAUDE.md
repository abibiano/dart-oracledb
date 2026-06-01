# Project instructions for AI agents

## Integration test databases (READ BEFORE running integration tests)

This project validates against **two** Oracle versions, and on Apple Silicon
each one runs in a **different** container runtime. Use the right one:

| Version | Runtime / docker context | Why | Host endpoint |
|---------|--------------------------|-----|---------------|
| **Oracle 23ai** (primary) | **Docker Desktop** — `docker context use desktop-linux` | Native ARM64 image, runs fast | `localhost:1521` / `FREEPDB1` |
| **Oracle 21c** (secondary, required for all changes) | **Colima x86_64 VM** — `docker context use colima` | No native ARM64 build exists for 21c; must be emulated | `localhost:1522` / `XEPDB1` |

**Rule of thumb: Docker Desktop for 23ai, Colima for pre-23ai (21c).** Never run
21c under Docker Desktop's built-in emulation — it crashes Oracle init.

### Bring up 23ai (native)
```bash
docker context use desktop-linux
docker compose up -d
```

### Bring up 21c (emulated)
```bash
# One-time: brew install colima qemu lima-additional-guestagents
colima start --arch x86_64 --cpu 6 --memory 8   # 2 CPU / 4 GB crashes init (ORA-04021)
docker context use colima
docker compose --profile oracle21c up -d oracle21c   # name the service! (see below)
```

### Gotchas an agent will hit
- **Always name the `oracle21c` service** in `up`. A bare
  `docker compose --profile oracle21c up -d` also starts the profile-less 23ai
  service *inside Colima* (emulated + two DBs starve the VM).
- `docker context` only switches which daemon the CLI talks to; it does **not**
  stop the other VM's containers. Both DBs can be up at once (different host
  ports), so tests can target 1521 and 1522 in the same run.
- Colima is **not** set to autostart. After a macOS reboot, run `colima start`
  before using 21c.
- 21c first-boot init takes a few minutes under emulation; wait for
  `health: healthy` (`docker compose ps`) before connecting.

### Run the suites
```bash
# 23ai
RUN_INTEGRATION_TESTS=true dart test test/integration/
# 21c
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/
```

> All new features and bug fixes must pass integration tests on **both** 23ai
> and 21c before being considered complete. Running only one is insufficient.

See `CONTRIBUTING.md` for the full developer walkthrough.
