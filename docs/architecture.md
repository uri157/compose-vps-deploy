# Architecture (MVP)

## Model

- **Engine**: bash CLI scripts under `scripts/`
- **Adapter**: GitHub Actions workflow template under `workflows/github/`
- **Contract**: single env file (`config/project.env`)

## Execution

The GitHub adapter SSHes into the VPS and invokes:

- `scripts/deploy.sh --config ...`

`deploy.sh` performs the full pipeline with explicit stage boundaries and fail-fast behavior.

## Safety

- strict shell mode (`set -euo pipefail`)
- required variable checks
- deterministic stage order
- service health verification before success
- optional docker cleanup at end
