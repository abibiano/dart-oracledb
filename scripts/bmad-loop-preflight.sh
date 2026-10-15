#!/usr/bin/env bash
# Preflight for an unattended bmad-loop run: check everything that silently
# wedges or fails it, and start what it needs. Run before `bmad-loop run`.
#
#   1. required tools on PATH
#   2. Codex hook trust (untrusted hooks silently never fire -> review sessions
#      sit at the "Hooks need review" prompt for the whole session timeout)
#   3. Oracle 23ai up and healthy  (Docker Desktop, native ARM64, :1521)
#   4. Oracle 21c up and healthy   (Colima x86_64 VM, emulated, :1522)
#   5. `bmad-loop validate`
#
# Uses `docker --context ...` per call, so the global docker context is never
# switched. See CLAUDE.md for why each database lives in a different runtime.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WAIT_23AI_S="${WAIT_23AI_S:-600}"
WAIT_21C_S="${WAIT_21C_S:-1200}"   # emulated first boot takes several minutes

step() { printf '\n:: %s\n' "$*"; }
die()  { printf 'bmad-loop-preflight: %s\n' "$*" >&2; exit 1; }

step "tools"
for t in git dart python3 tmux claude codex bmad-loop uv docker colima nc; do
  command -v "$t" >/dev/null 2>&1 || die "'$t' not found on PATH"
done
echo "ok"

step "codex hook trust"
python3 - <<'PY' || die "Codex hooks are not trusted. Run \`codex\` once in this repo, choose 'Hooks need review' -> 'Trust all and continue', exit, then re-run."
import json, os, re, sys, tomllib
from pathlib import Path

repo = Path.cwd()
hooks = repo / ".codex" / "hooks.json"
if not hooks.is_file():
    sys.exit("missing .codex/hooks.json - run `bmad-loop init --cli codex`")
home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
cfg = home / "config.toml"
state = {}
if cfg.is_file():
    state = tomllib.loads(cfg.read_text()).get("hooks", {}).get("state", {})
snake = lambda e: re.sub(r"(?<!^)(?=[A-Z])", "_", e).lower()
missing = []
for event, groups in json.loads(hooks.read_text()).get("hooks", {}).items():
    for gi, g in enumerate(groups):
        for hi, _ in enumerate(g.get("hooks", [])):
            key = f"{hooks}:{snake(event)}:{gi}:{hi}"
            if "trusted_hash" not in (state.get(key) or {}):
                missing.append(key)
if missing:
    print("untrusted in", cfg, *missing, sep="\n  ", file=sys.stderr)
    sys.exit(1)
print(f"ok: hooks trusted in {cfg}")
PY

wait_healthy() {  # <docker-context> <container-id> <label> <timeout-s>
  local ctx="$1" id="$2" label="$3" limit="$4" waited=0 status
  while :; do
    status="$(docker --context "$ctx" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || echo missing)"
    [ "$status" = healthy ] && { echo "ok: $label healthy"; return 0; }
    [ "$waited" -ge "$limit" ] && die "$label not healthy after ${limit}s (last status: $status)"
    printf '   %s: %s (%ss/%ss)\n' "$label" "$status" "$waited" "$limit"
    sleep 15; waited=$((waited + 15))
  done
}

step "Oracle 23ai (Docker Desktop, localhost:1521)"
docker --context desktop-linux info >/dev/null 2>&1 \
  || die "Docker Desktop is not running (docker context desktop-linux). Start it, then re-run."
# The 23.9-pinned container lives in compose project `dart-oracledb-23ai` (its data volume
# is dart-oracledb-23ai_oracle-data). Without -p, compose uses the directory name and
# collides with the fixed container_name.
docker --context desktop-linux compose -p dart-oracledb-23ai up -d oracle
wait_healthy desktop-linux oracle23ai "oracle23ai" "$WAIT_23AI_S"

step "Oracle 21c (Colima x86_64 VM, localhost:1522)"
if ! colima status >/dev/null 2>&1; then
  echo "starting colima (x86_64, 6 CPU / 8 GB; less crashes init with ORA-04021)"
  colima start --arch x86_64 --cpu 6 --memory 8
fi
# Name the service: a bare profile `up` would also start 23ai inside Colima.
docker --context colima compose --profile oracle21c up -d oracle21c
id21="$(docker --context colima compose --profile oracle21c ps -q oracle21c)"
[ -n "$id21" ] || die "oracle21c container not found after up"
wait_healthy colima "$id21" "oracle21c" "$WAIT_21C_S"

step "ports"
nc -z localhost 1521 || die "23ai healthy but localhost:1521 unreachable"
nc -z localhost 1522 || die "21c healthy but localhost:1522 unreachable"
echo "ok"

step "bmad-loop validate"
bmad-loop validate

printf '\n:: bmad-loop preflight OK - tools present, hooks trusted, 23ai + 21c up\n'
