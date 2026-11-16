You are on call for a three-node PostgreSQL-backed transaction service. Your shell starts on `node0`; you may SSH as `root` to `node1` and `node2`.

## Current operational picture

- `node0` runs the transaction API.
- `node1` runs PgBouncer and is supposed to be the only database endpoint used by the API.
- `node2` runs PostgreSQL.
- Basic health checks and a single manual transaction can succeed.
- During sustained traffic, clients see intermittent transaction failures and slow requests.
- The incident began after a maintenance window that changed pooler behavior.

## Business impact

The service is accepting some traffic, but the current deployment is not safe for normal load. A quick restart or one-off live edit may appear to help, then the problem returns after service restart or reload.

## What resolved means

- New transactions succeed reliably under concurrent load.
- The application still routes through PgBouncer, not directly to PostgreSQL.
- PgBouncer settings are safe in the persistent configuration.
- Restarting PgBouncer and the app does not reintroduce the incident.
- Bootstrap data already in PostgreSQL is retained.

## Change posture

Prefer a targeted in-place repair. Do not wipe and recreate PostgreSQL data, bypass PgBouncer, or add background babysitter loops that merely hide the issue.
