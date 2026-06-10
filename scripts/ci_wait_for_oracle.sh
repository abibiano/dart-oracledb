#!/usr/bin/env bash
# Bounded Oracle readiness probe shared by the CI integration jobs.
#
# Usage: ci_wait_for_oracle.sh IMAGE SERVICE LABEL [PORT]
#   IMAGE   — service-container image (used to derive the container id)
#   SERVICE — PDB service name to open a session on (FREEPDB1 / XEPDB1)
#   LABEL   — human-readable name for log lines ("Oracle" / "Oracle 21c")
#   PORT    — host listener port to probe (optional, default 1521)
#
# Even though GitHub `services:` waits for the container healthcheck before
# starting steps, this probe makes the failure mode (container vs. listener
# vs. PDB) explicit in the logs if Oracle never becomes ready. It requires a
# real DB session on the PDB via in-container sqlplus (Story 7.9 AC4) — a
# TCP-up listener with a still-mounting PDB (ORA-12514) is not "ready".
# Total budget (60 × ~10s ≈ 10 min worst case) stays under each job's
# timeout-minutes (AC5).
if [ "$#" -lt 3 ]; then
  echo "Usage: $0 IMAGE SERVICE LABEL [PORT]" >&2
  exit 2
fi

set -euo pipefail

image="$1"
service="$2"
label="$3"
port="${4:-1521}"

# `services:` containers get auto-generated names — derive the id from the
# image (Story 7.9 AC7). Re-derive inside the loop: the container may not be
# listed when the step starts, and a one-shot empty id would make the
# [ -n "$cid" ] session probe never succeed, silently looping to the full
# timeout even on a healthy DB.
attempts=60
cid=""
for i in $(seq 1 $attempts); do
  cid="$(docker ps --filter "ancestor=${image}" -q | head -n1)"
  # Connect-only probe: opening /dev/tcp performs the TCP connect, and `:`
  # returns immediately on success WITHOUT reading. A `cat`-style read would
  # block forever here — Oracle's TNS listener sends nothing until it receives
  # a connect packet — making a `timeout`-wrapped read report "not ready" on
  # every iteration even against a healthy listener. `timeout 5` still bounds a
  # connect that hangs (accepts but never completes the handshake).
  if timeout 5 bash -c ": < /dev/tcp/localhost/${port}" >/dev/null 2>&1; then
    # Listener is up — now require an actual session on the PDB.
    # Credential is the ephemeral CI-only password (see test-run env).
    if [ -n "$cid" ] && echo 'SELECT 1 FROM dual;' | docker exec -i "$cid" sqlplus -L -S "system/testpassword@//localhost:${port}/${service}" >/dev/null 2>&1; then
      echo "${label} ready: DB session on ${service} established (after ${i} attempts)"
      exit 0
    fi
    if [ -z "$cid" ]; then
      echo "Listener up but no container matched ancestor=${image} yet (attempt ${i}/${attempts})..."
    else
      echo "Listener up but ${service} not accepting sessions yet (attempt ${i}/${attempts})..."
    fi
  else
    echo "${label} not ready yet (attempt ${i}/${attempts})..."
  fi
  sleep 10
done
echo "::error::${label} did not become ready within timeout"
# Surface service-container startup logs (Story 7.9 AC7).
if [ -n "$cid" ]; then
  docker logs "$cid" 2>&1 | tail -n 200 || true
else
  echo "::error::No container matched ancestor=${image}; cannot show logs. All containers:"
  docker ps -a || true
fi
exit 1
