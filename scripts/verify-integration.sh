#!/usr/bin/env bash
# Verify gate: run the integration suites against BOTH Oracle 23ai and 21c
# (CLAUDE.md: a one-database run is never sufficient). Fails fast, with start
# instructions, when either database is unreachable.
#
#   23ai: localhost:1521 / FREEPDB1  (Docker Desktop, docker context desktop-linux)
#   21c:  localhost:1522 / XEPDB1    (Colima x86_64 VM, docker context colima)

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

HOST="${ORACLE_HOST:-localhost}"

require_up() {
  local port="$1" name="$2" hint="$3"
  if ! nc -z "$HOST" "$port" 2>/dev/null; then
    printf 'verify-integration: Oracle %s is not reachable on %s:%s\n  start it: %s\n' \
      "$name" "$HOST" "$port" "$hint" >&2
    exit 1
  fi
}

require_up 1521 23ai 'docker context use desktop-linux && docker compose up -d'
require_up 1522 21c 'colima start --arch x86_64 --cpu 6 --memory 8 && docker context use colima && docker compose --profile oracle21c up -d oracle21c'

scripts/assert_oracle_version.sh oracle23ai 23.9. desktop-linux

printf 'running: integration tests on Oracle 23ai\n'
RUN_INTEGRATION_TESTS=true dart test test/integration/

printf 'running: integration tests on Oracle 21c\n'
RUN_INTEGRATION_TESTS=true ORACLE_PORT=1522 ORACLE_SERVICE=XEPDB1 dart test test/integration/
