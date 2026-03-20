# Pattern: Stateful PostgreSQL Volume

## Goal
Run PostgreSQL/Timescale in compose with persistent data across container recreation.

## Baseline
- Mount named volume to PostgreSQL data directory.
- Add healthcheck with `pg_isready`.
- Make migrator depend on DB health.

## Suggested health chain
- `postgres` -> healthy
- `migrator` -> completed successfully
- `api` -> healthy
- `front` -> healthy
- `nginx` -> healthy

## Deploy config recommendations
- Include DB service in `HEALTH_SERVICES`.
- Use `MIGRATION_MODE=service` and `MIGRATOR_SERVICE=<name>`.
- Keep backups outside image lifecycle.

## Backup/restore
- Define backup cadence before production.
- Test restore procedure periodically.
- Treat destructive schema migrations as staged changes.
