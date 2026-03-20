# Configuration Contract

The deploy engine expects one env file (default: `config/project.env`).

## Required Keys

- SSH target: `SSH_HOST`, `SSH_USER`, `SSH_PORT`, `DEPLOY_PATH`
- Compose: `COMPOSE_FILE`
- Images/tags: `API_IMAGE`, `API_TAG`

## Optional Keys

- Registry auth: `REGISTRY_HOST`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD`
  - If `REGISTRY_USERNAME`/`REGISTRY_PASSWORD` are provided, `REGISTRY_HOST` is required.
  - If both credentials are empty, registry login stage is skipped.
- Optional image/tag pairs: `MIGRATOR_IMAGE` + `MIGRATOR_TAG`, `FRONT_IMAGE` + `FRONT_TAG`
  - Image/tag must be set together as a pair.
- `COMPOSE_PROJECT_NAME`
- `COMPOSE_EXTRA_FILES` (CSV, appended as additional `docker compose -f` files in order)
- `COMPOSE_ENV_FILES` (CSV)
- `DEPLOY_ENV_FILE`, `APP_ENV_FILE`, `APP_ENV_B64`
- `EXTRA_ENV_B64`, `EXTRA_ENV_FILE`
- `CLOUDFLARED_ENV_FILE`, `TUNNEL_TOKEN`
- `EXTRA_PULL_IMAGES` (CSV)
- `MIGRATION_MODE` (`none|service|command`)
- `MIGRATOR_SERVICE` (required when `MIGRATION_MODE=service`)
- `MIGRATION_COMMAND` (required when `MIGRATION_MODE=command`)
- `HEALTH_SERVICES` (empty skips health stage)
- `HEALTH_TIMEOUT_SECONDS`, `HEALTH_POLL_SECONDS`
- `PRE_DEPLOY_HOOK`, `POST_DEPLOY_HOOK`
- `CLEANUP_ENABLED`

## Dispatch Mapping

When using the GitHub templates, dispatched inputs map to config/runtime as follows:

- `api_tag` -> `API_TAG`
- `migrator_tag` -> `MIGRATOR_TAG`
- `front_tag` -> `FRONT_TAG`

If a dispatched tag is empty, the current value from `config/project.env` is preserved.

Secrets can also be injected as base64 payloads:

- `APP_ENV_B64`
- `EXTRA_ENV_B64`
