# Reentry

Backups that prove they restore. Reentry takes logical dumps of a MySQL and a
PostgreSQL database, checksums them, and restores the latest one into a
throwaway container to check it against the source. Everything runs in Docker.

Status: scaffold only. Every item below is planned until it is marked built.

## Spec

| Piece | Status |
|---|---|
| `compose/`: one MySQL and one PostgreSQL instance, each seeded with a small fake sample database | written, not yet run (no Docker on the build machine) |
| `reentry backup`: compressed dumps with a SHA-256 checksum file, named by database and timestamp, written to `backups/` | written, not yet run |
| `reentry verify`: restore the latest backup into a throwaway container, compare row counts per table with the source, run a basic integrity query, exit non-zero on any mismatch | written, restore path not yet run |
| `reentry prune`: retention of 7 daily, 4 weekly and 6 monthly backups, configurable | planned |
| `reentry list`: show backups with size and checksum state | planned |
| Exit codes and one log line per step | planned |
| `docs/runbook.md`: generic ransomware recovery runbook | planned |
| `test/e2e.sh`: backup, corrupt a copy, confirm verify catches it | planned |

## Requirements

Bash, Docker and Docker Compose.

## Usage

```
cp .env.example .env     # then set the passwords
./reentry up             # start MySQL and PostgreSQL
./reentry backup         # dump both databases into backups/
./reentry verify         # restore the latest backups and check them
./reentry down           # stop and delete the data volumes
```

`verify` handles each engine in turn. For the latest backup it checks the
SHA-256 file and gzip integrity, starts a throwaway container with no
published ports, restores the dump into it, compares the row count of every
table with the live source, and runs integrity checks: no `order_items` row
without a parent order (written for the sample schema, change it for your own),
plus `mysqlcheck` on MySQL. It removes the throwaway container on exit and
exits 1 if either engine fails. The source is read live, so run `verify`
soon after `backup`: rows written in between show up as a count mismatch.
Set `REENTRY_BACKUP_DIR` to point it at a different backup folder.

The Compose file lives in `compose/`, so a bare `docker compose up` from the
repo root will not find it. `./reentry up` runs
`docker compose -f compose/docker-compose.yml --env-file .env up -d --wait`.
Use that command directly if you prefer.

Backups are written as `<engine>_<database>_<UTC timestamp>.sql.gz` with a
matching `.sha256` file. A dump is written to a `.partial` file and only
renamed once it is valid gzip, so a failed dump never looks like a backup.

Exit codes: 0 ok, 1 command failed, 2 usage error, 3 prerequisite missing
(no `.env`, no Docker, container not running).

## Data and secrets

All sample data is fake. Credentials live in a git-ignored `.env`. The
`backups/` folder is git-ignored and must never be committed.

## Done when

`docker compose up -d && ./reentry backup && ./reentry verify` succeeds, and
the corruption test fails verify as expected.

## Test status

Docker is not installed on the build machine, so no container, dump or
restore has been run. Run so far: `bash -n reentry`, the usage output, and
`verify` against a stub `docker` command, which confirmed the checksum
mismatch and no-backup-found paths exit 1. The restore, row count and
integrity steps are untested.
