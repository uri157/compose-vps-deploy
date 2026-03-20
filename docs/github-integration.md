# GitHub Integration (App Repos + Infra Repo)

This toolkit uses two workflow layers:

- **App repositories** build/push images and dispatch infra deploy
- **Infra repository** receives tags and runs remote deploy over SSH

## Infra Repository Setup

Use templates:

- `workflows/github/deploy.yml`
- `workflows/github/ci.yml`

### Infra Repo Secrets

- `VPS_SSH_KEY`
- `VPS_HOST`
- `VPS_PORT`
- `VPS_USER`
- `REGISTRY_USERNAME`
- `REGISTRY_PASSWORD`
- `DB_ENV_B64` (optional)
- `API_ENV_B64` (optional)
- `FRONT_ENV_B64` (optional)
- `TUNNEL_TOKEN` (optional)

### Infra Repo Variables

- `REMOTE_REPO_PATH`
- `REMOTE_CONFIG_PATH` (optional, default `config/project.env`)

## Backend/App Repository Setup

Use template:

- `workflows/github/backend-build-dispatch.yml`

### Backend Repo Variables

- `IMAGE_REGISTRY` (optional, default `ghcr.io`)
- `IMAGE_NAMESPACE` (optional)
- `API_IMAGE_NAME`
- `MIGRATOR_IMAGE_NAME` (optional when no migrator image is built)
- `API_DOCKERFILE` (optional, default `./Dockerfile`)
- `MIGRATOR_DOCKERFILE` (optional)
- `INFRA_OWNER`
- `INFRA_REPO`
- `INFRA_WORKFLOW`
- `INFRA_REF`

### Backend Repo Secrets

- `REGISTRY_USERNAME`
- `REGISTRY_PASSWORD`
- `INFRA_DISPATCH_TOKEN`

## Frontend Repository Setup

Use template:

- `workflows/github/frontend-build-dispatch.yml`

### Frontend Repo Variables

- `IMAGE_REGISTRY` (optional, default `ghcr.io`)
- `IMAGE_NAMESPACE` (optional)
- `FRONT_IMAGE_NAME`
- `FRONT_DOCKERFILE` (optional, default `./Dockerfile`)
- `INFRA_OWNER`
- `INFRA_REPO`
- `INFRA_WORKFLOW`
- `INFRA_REF`

### Frontend Repo Secrets

- `REGISTRY_USERNAME`
- `REGISTRY_PASSWORD`
- `INFRA_DISPATCH_TOKEN`

## Dispatch Contract

The app workflows dispatch these inputs to infra deploy workflow:

- `api_tag`
- `migrator_tag` (only when a migrator image is built)
- `front_tag`

Infra deploy workflow maps them to environment variables consumed by `scripts/deploy.sh`.
Empty tag inputs are ignored, so existing configured tags remain unchanged.
