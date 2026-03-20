# Architecture (MVP)

## Model

- **Engine**: bash CLI scripts under `scripts/`
- **Adapter**: GitHub Actions workflow template under `workflows/github/`
- **Contract**: single env file (`config/project.env`)

## Execution

The GitHub adapter SSHes into the VPS and invokes:

- `scripts/deploy.sh --config ...`

`deploy.sh` performs the full pipeline with explicit stage boundaries and fail-fast behavior.
Migration is controlled through `MIGRATION_MODE=none|service|command`.
Pre/post host-side commands can be attached with `PRE_DEPLOY_HOOK` and `POST_DEPLOY_HOOK`.
Compose runtime supports one base file (`COMPOSE_FILE`) plus optional overrides (`COMPOSE_EXTRA_FILES` CSV).

## Safety

- strict shell mode (`set -euo pipefail`)
- required variable checks
- deterministic stage order
- service health verification before success (when `HEALTH_SERVICES` is configured)
- optional docker cleanup at end
