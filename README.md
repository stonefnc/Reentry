# Reentry

Backups that prove they restore. Reentry takes logical dumps of a MySQL and a
PostgreSQL database, checksums them, and restores the latest one into a
throwaway container to check it against the source. Everything runs in Docker.

Status: scaffold only. Every item below is planned until it is marked built.

## Spec

| Piece | Status |
|---|---|
| `compose/`: one MySQL and one PostgreSQL instance, each seeded with a small fake sample database | written, not yet run (no Docker on the build machine) |
| `reentry backup`: compressed dumps with a SHA-256 checksum file, named by database and timestamp, written to `backups/` | planned |
| `reentry verify`: restore the latest backup into a throwaway container, compare row counts per table with the source, run a basic integrity query, exit non-zero on any mismatch | planned |
| `reentry prune`: retention of 7 daily, 4 weekly and 6 monthly backups, configurable | planned |
| `reentry list`: show backups with size and checksum state | planned |
| Exit codes and one log line per step | planned |
| `docs/runbook.md`: generic ransomware recovery runbook | planned |
| `test/e2e.sh`: backup, corrupt a copy, confirm verify catches it | planned |

## Requirements

Bash, Docker and Docker Compose.

## Data and secrets

All sample data is fake. Credentials live in a git-ignored `.env`. The
`backups/` folder is git-ignored and must never be committed.

## Done when

`docker compose up -d && ./reentry backup && ./reentry verify` succeeds, and
the corruption test fails verify as expected.

## Test status

Nothing has been run yet.
