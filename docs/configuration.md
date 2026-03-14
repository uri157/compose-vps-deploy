# Configuration Contract

The deploy engine expects one env file (default: `config/project.env`).

## Required Keys

- SSH target: `SSH_HOST`, `SSH_USER`, `SSH_PORT`, `DEPLOY_PATH`
- Compose: `COMPOSE_FILE`
- Registry: `REGISTRY_HOST`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD`
- Images/tags: `API_IMAGE`, `MIGRATOR_IMAGE`, `FRONT_IMAGE`, `API_TAG`, `MIGRATOR_TAG`, `FRONT_TAG`
- Runtime: `MIGRATOR_SERVICE`, `HEALTH_SERVICES`

## Optional Keys

- `COMPOSE_PROJECT_NAME`
- `COMPOSE_ENV_FILES` (CSV)
- `DEPLOY_ENV_FILE`, `APP_ENV_FILE`, `APP_ENV_B64`
- `EXTRA_ENV_B64`, `EXTRA_ENV_FILE`
- `CLOUDFLARED_ENV_FILE`, `TUNNEL_TOKEN`
- `EXTRA_PULL_IMAGES` (CSV)
- `HEALTH_TIMEOUT_SECONDS`, `HEALTH_POLL_SECONDS`
- `CLEANUP_ENABLED`

## Dispatch Mapping

When using the GitHub templates, dispatched inputs map to config/runtime as follows:

- `api_tag` -> `API_TAG`
- `migrator_tag` -> `MIGRATOR_TAG`
- `front_tag` -> `FRONT_TAG`

Secrets can also be injected as base64 payloads:

- `APP_ENV_B64`
- `EXTRA_ENV_B64`
