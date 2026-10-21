#!/usr/bin/env bash
# End to end test. Needs Docker. Starts the sample databases if they are not running, takes a real
# backup, checks that verify passes, then damages copies of the backup two ways and checks that
# verify fails on each:
#   A. a corrupted dump, which the SHA-256 check must catch
#   B. a dump with a row removed and a matching, valid checksum, which only the restore and the
#      row count comparison can catch
# Backups go to a temporary folder, never to backups/. Set E2E_KEEP_UP=1 to leave Docker running.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
made_env=0 started=0
fail=0

cleanup() {
  [ "$started" = 0 ] || [ -n "${E2E_KEEP_UP:-}" ] || "$ROOT/reentry" down --yes >/dev/null 2>&1
  [ "$made_env" = 0 ] || rm -f "$ROOT/.env"
  rm -rf "$tmp"
}
trap cleanup EXIT

check() { # check <description> <command...>
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then echo "ok   $what"; else echo "FAIL $what"; fail=1; fi
}
run() { # run <backup dir> <reentry args...>: sets rc, output in $tmp/out
  local d=$1; shift
  REENTRY_BACKUP_DIR="$d" "$ROOT/reentry" "$@" >"$tmp/out" 2>&1; rc=$?
}
has() { grep -q -- "$1" "$tmp/out"; }

command -v docker >/dev/null 2>&1 || { echo "docker not found, this test needs Docker"; exit 3; }
if [ ! -f "$ROOT/.env" ]; then cp "$ROOT/.env.example" "$ROOT/.env"; made_env=1; fi

if [ "$(docker inspect -f '{{.State.Running}}' reentry-mysql 2>/dev/null)" != true ]; then
  started=1
  "$ROOT/reentry" up || { echo "FAIL could not start the sample databases"; exit 1; }
fi

good="$tmp/good"
run "$good" backup
check "backup succeeds" [ "$rc" = 0 ]
run "$good" verify
check "verify passes on an untouched backup" [ "$rc" = 0 ]
[ "$rc" = 0 ] || cat "$tmp/out"

# control: a plain copy must still pass, so a failure below is down to the damage and not the copy
cp -r "$good" "$tmp/control"
run "$tmp/control" verify
check "verify passes on an undamaged copy" [ "$rc" = 0 ]

# A. corrupted dump
cp -r "$good" "$tmp/a"
my="$(cd "$tmp/a" && ls mysql_*.sql.gz)"
printf 'garbage' >> "$tmp/a/$my"
run "$tmp/a" verify
check "A: corrupted dump makes verify exit non-zero" [ "$rc" != 0 ]
check "A: the failure is the checksum" has "SHA-256 mismatch"

# B. one row removed from the PostgreSQL dump, checksum files rewritten so they match
cp -r "$good" "$tmp/b"
pg="$(cd "$tmp/b" && ls postgres_*.sql.gz)"
gzip -dc "$tmp/b/$pg" | awk 'f==1{f=0;next} /^COPY public\.order_items /{f=1} {print}' | gzip -9 > "$tmp/b/$pg.new"
mv "$tmp/b/$pg.new" "$tmp/b/$pg"
(cd "$tmp/b" && sha256sum "$pg" "$pg.counts" > "$pg.sha256")
check "B: the damaged copy passes its own checksum" bash -c "cd '$tmp/b' && sha256sum -c --status '$pg.sha256'"
run "$tmp/b" verify
check "B: a missing row makes verify exit non-zero" [ "$rc" != 0 ]
check "B: the failure is the row count comparison" has "row counts differ"

exit "$fail"
