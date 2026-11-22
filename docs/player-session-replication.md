# Player and Session database replication

Player and Server Moderation Session each use one PostgreSQL 17 primary and two
asynchronous standbys. Both clusters use
`janetag/pad-postgres-replication:17-lab5.1` with separate networks, credentials,
and volumes. The apps use `DB_HOSTS` to find the primary, and Analytics uses a
three-host connection string with `target_session_attrs=primary`.

## Before cutover

Use the same CPR project and local `.env` as the existing deployment. Confirm
the app versions are set to `0.5.0`. Keep both original Analytics DSNs and set
`ANALYTICS_PLAYER_HA_DSN` and `ANALYTICS_SESSION_HA_DSN` using the existing
restricted reader credentials. Set a separate replication password for each
cluster as shown in [the environment example](../.env.example).

Check that each original database is running and its container's configured
`POSTGRES_USER` matches an existing database login. The stored database role
and password should match the app credentials in CPR. Provision the Analytics
readers and run the warehouse migrations before verification. Have Discovery
and Session's Message Broker ready before activating the apps.

Run the commands in Bash from the CPR root. In Git Bash on Windows, set
`export MSYS_NO_PATHCONV=1` so Docker receives the container paths as written.

## Move existing data

Complete one cutover at a time during a maintenance window. Backup pauses
the selected app and the Analytics scheduler. The old database volume is
retained. The backup directory contains data and role password hashes, so keep
it private.

```bash
bash scripts/replication-cutover.sh player backup
bash scripts/replication-cutover.sh player restore "$PLAYER_BACKUP"
bash scripts/replication-cutover.sh player verify
bash scripts/replication-cutover.sh player activate
```

Set `PLAYER_BACKUP` to the path printed by `backup`. Run each command only
after the previous one succeeds. Run the same sequence with `session` and the
Session backup path. Restore compares the restored public-table data with the
backup. Verify checks both standbys and runs the selected Analytics source
against the new cluster. Activate starts the selected app on the new cluster
and refreshes the scheduler using the recorded cutovers.

If you need to revert **before activation**, run
`bash scripts/replication-cutover.sh player rollback-before-activation` or
the equivalent for `session`. After activation, plan a reverse migration if
needed because the old volume no longer receives new writes.

Use `bash scripts/replication-cutover.sh resume-analytics` to recreate the
scheduler with the recorded source connections after cutover.

## Promote and rejoin

```bash
bash scripts/database-replication.sh player status
bash scripts/database-replication.sh player failover
```

Use `session` for the Session cluster. The command fences the old primary
before promoting an eligible standby. New app and Analytics connections can
find the promoted primary. Asynchronous replication can lose changes that
never reached an available standby. If the script reports a pending promotion,
inspect the nodes and use the operator's `complete` command after resolving
the error.

Rejoin each of the two non-primary nodes. For example, if `db-2` was promoted:

```bash
bash scripts/database-replication.sh player rejoin db-1 --rebuild
bash scripts/database-replication.sh player rejoin db-3 --rebuild
bash scripts/replication-cutover.sh player verify
```

Rejoin preserves the previous data directory and takes a fresh copy from the
current primary. The final verification checks both standbys and confirms
Analytics can read from the promoted primary.

## Rehearsal evidence

- Player and Session `0.5.0` each read and wrote data after a promotion without
  an app restart. Both standbys rejoined, and each targeted Analytics job
  extracted two rows from its promoted primary.
- The Session rehearsal restored a session created before backup. Player's
  initial cutover rehearsal used an empty database. Player accounts were
  created afterward to verify reads and writes through failover.
- A separate test delivered a pending Session outbox event to Player after
  promotion, using the CPR Broker built locally and a Session restart to
  refresh its gRPC connection.
- The disposable rehearsal used one app replica at a time and one-shot
  Analytics jobs. Full-stack scheduling and Daniela's live cutover were not
  exercised in this rehearsal.
