# Ransomware recovery runbook

A generic runbook for recovering a MySQL or PostgreSQL database after a
ransomware attack. It is written to be followed in order, under pressure.
Read the rules, then work through the steps. Do not skip ahead.

The commands use the sample setup from this repo (`./reentry`, `backups/`).
Replace the names with your own. Where Reentry has no command for a step, the
plain database commands are given.

## Rules

1. Do not pay or contact the attacker from this runbook. That is a decision
   for the incident owner, with legal advice.
2. Do not restore onto the infected host. Restore onto a clean one.
3. Do not reconnect anything to the network until step 7.
4. Write down what you do as you do it (step 8). Memory fails under stress.
5. One person leads. Everyone else does what the lead asks.

## Before you start: fill in this table

| Item | Value |
|---|---|
| Incident lead | |
| Time the attack was noticed | |
| Systems known to be affected | |
| Where the backups are stored | |
| Who can approve returning to service | |

## 1. Isolate

Goal: stop the spread. Do this first and do it fast.

- [ ] Disconnect affected hosts from the network. Pull the cable or disable the
      switch port or cloud network interface. Do not shut the hosts down yet,
      because memory can hold evidence.
- [ ] Disable the accounts and API keys that may be exposed. Include database
      users, backup users and cloud credentials.
- [ ] Check the backup storage. If it is reachable from an affected host,
      disconnect it too. Attackers go after backups.
- [ ] Tell the people who need to know: the incident owner, and whoever handles
      legal, privacy and customer communication.

## 2. Preserve evidence

Goal: keep what you need to understand the attack, without touching it more
than necessary.

- [ ] Note the ransom message, file names and file extensions you see. Take
      photos or screenshots.
- [ ] If you can, take disk or memory images of affected hosts before wiping.
- [ ] Keep logs from the firewall, the hosts and the database. Copy them to a
      safe location that is not reachable from the affected network.

## 3. Identify the last known good backup

Goal: pick the newest backup that is both clean and complete.

1. Decide the earliest time the attacker could have been present. If you do
   not know, assume earlier than you think and choose an older backup.
2. List the backups from a clean machine that has read-only access to the
   backup storage:

   ```
   ./reentry list
   ```

3. Ignore any backup newer than the earliest possible compromise time. A
   backup taken after the attacker arrived may hold tampered data.
4. Ignore any backup that shows `CHECKSUM-MISMATCH` or `no-checksum`.
5. Pick the newest backup that is left. Write down its file name and its
   SHA-256 value.

If there is no usable backup, stop and tell the incident lead. Recovery then
becomes a different, longer process.

## 4. Prepare a clean host

Goal: a place to restore that the attacker has never touched.

- [ ] Build a new host from a trusted image. Do not reuse the old one.
- [ ] Install the same major version of the database as the backup came from.
- [ ] Set new passwords for every account. Do not reuse old ones.
- [ ] Keep the new host off the production network for now.
- [ ] Copy the chosen backup and its `.sha256` file to the new host.

## 5. Restore

Check the file first. Run this in the folder that holds the backup:

```
sha256sum -c mysql_shop_20260101T000000Z.sql.gz.sha256
```

It must print `OK`. If it does not, stop and pick a different backup.

Create the empty database, then load the dump.

MySQL:

```
mysql -uroot -p -e "CREATE DATABASE shop"
gzip -dc mysql_shop_20260101T000000Z.sql.gz | mysql -uroot -p shop
```

PostgreSQL:

```
createdb -U postgres shop
gzip -dc postgres_shop_20260101T000000Z.sql.gz | psql -U postgres -d shop -v ON_ERROR_STOP=1
```

Any error during the load means the restore is not trustworthy. Stop and
investigate before going on.

## 6. Validate

Goal: prove the restored data is whole before anyone relies on it.

- [ ] Compare row counts per table with the last numbers you trust. If you ran
      `./reentry verify` before the attack, its log lines hold the counts.
- [ ] Run an integrity check. For example, look for child rows with no parent
      row, and on MySQL run `mysqlcheck --check`.
- [ ] Ask a business owner to spot check known records.
- [ ] Note how much data is lost. It is everything written after the backup
      was taken. Tell the incident lead the exact time.

If a check fails, go back to step 3 and choose an older backup.

## 7. Return to service

Goal: bring the system back without letting the attacker back in.

- [ ] Confirm the way in has been found and closed, or that you have a plan to
      watch for it. Restoring without fixing the cause invites a second attack.
- [ ] Rotate every credential the application and the database use.
- [ ] Apply outstanding security updates to the new host.
- [ ] Get approval from the person named in the table above.
- [ ] Connect the new host to the network. Point the application at it.
- [ ] Watch logs and traffic closely for several days.
- [ ] Start taking backups again, and run `./reentry verify` on the first one.

## 8. Record what happened

Do this while it is fresh. Within a few days, hold a short review with the
people involved. The record should state:

- The timeline: first sign, detection, isolation, restore, return to service.
- Which backup was used and why, and how much data was lost.
- How the attacker got in, if known.
- What worked and what did not.
- What will change: for example off-host copies of backups, shorter time to
  detection, access changes.

Keep the record somewhere the affected systems cannot reach.

## Limits of the tooling in this repo

Reentry writes backups to a local folder, and nothing in the repo copies them
elsewhere yet (planned). A ransomware attack on the host that holds `backups/`
can encrypt the backups as well. Keep a copy somewhere the database host
cannot write to or delete from, and run `./reentry verify` often.
