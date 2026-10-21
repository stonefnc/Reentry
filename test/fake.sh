#!/usr/bin/env bash
# Tests backup, verify and their failure paths against a fake docker command (test/fake-docker).
# This proves the script logic. It does not prove real dumps and restores, see test/e2e.sh for that.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export PATH="$ROOT/test/fake-docker:$PATH" FAKE_LOG="$tmp/docker.log"
fail=0

check() { # check <description> <command...>
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then echo "ok   $what"; else echo "FAIL $what"; fail=1; fi
}
fresh() { export REENTRY_BACKUP_DIR="$tmp/$1"; rm -rf "$REENTRY_BACKUP_DIR"; : > "$FAKE_LOG"; }
run() { "$ROOT/reentry" "$@" >"$tmp/out" 2>&1; rc=$?; }
has() { grep -q -- "$1" "$tmp/out"; }
files() { ls "$REENTRY_BACKUP_DIR" | grep -c "$1"; }

fresh a
run backup
check "backup exits 0" [ "$rc" = 0 ]
check "two dumps written" [ "$(files '\.sql\.gz$')" = 2 ]
check "each dump has a sidecar and a counts manifest" [ "$(files '\.sha256$')$(files '\.counts$')" = 22 ]
check "no .partial left behind" [ "$(files partial)" = 0 ]

run verify
check "verify passes" [ "$rc" = 0 ]
check "verify reports PASS for both engines" [ "$(grep -c PASS "$tmp/out")" = 2 ]
check "throwaway containers are removed on success" [ "$(grep -c '^rm .*reentry-verify-' "$FAKE_LOG")" = 2 ]

FAKE_DRIFT=1 run verify
check "writes after the backup do not fail verify (manifest used)" [ "$rc" = 0 ]

FAKE_DROP_ROW=1 run verify
check "a restored table missing a row fails verify" [ "$rc" = 1 ]
check "the mismatch is named" has "row counts differ"

printf x >> "$REENTRY_BACKUP_DIR/$(ls "$REENTRY_BACKUP_DIR" | grep '^mysql.*\.sql\.gz$')"
run verify
check "a corrupted backup fails verify on the checksum" [ "$rc" = 1 ]
check "the checksum failure is named" has "SHA-256 mismatch"

FAKE_DOWN=reentry-mysql run verify
check "a missing container exits 3" [ "$rc" = 3 ]

fresh b
FAKE_FAIL_DUMP=1 run backup
check "a failing dump exits 1" [ "$rc" = 1 ]
check "no files are left after failed dumps" [ "$(ls -A "$REENTRY_BACKUP_DIR" | grep -vc '^\.reentry\.lock$')" = 0 ]

fresh c
FAKE_TRUNCATE=1 run backup
check "a cut-off dump is rejected" [ "$rc" = 1 ]
check "the cut-off dump is named" has "looks incomplete"
check "a rejected dump leaves no backup" [ "$(files '\.sql\.gz$')" = 0 ]

fresh d
FAKE_DOWN=reentry-mysql run backup
check "one engine down still backs up the other" [ "$(files '^postgres.*\.sql\.gz$')" = 1 ]
check "and the run exits 3" [ "$rc" = 3 ]

fresh e
check "list exits 1 on an empty folder" bash -c "! '$ROOT/reentry' list"

exit "$fail"
