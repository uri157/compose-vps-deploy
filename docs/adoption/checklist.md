# Adoption Checklist

Use this checklist when adapting an existing project to `compose-vps-deploy`.

## 1) Repository split and ownership
- Define which repositories own: API image, frontend image, migrator image, infrastructure deploy.
- Ensure one infra repository owns production compose files.

## 2) Container contract
- API image has a stable health endpoint and deterministic startup command.
- Frontend image exposes a stable HTTP port.
- Migrator image is idempotent and safe to run on every deploy.

## 3) Compose contract
- `docker-compose.prod.yml` includes healthchecks for core services.
- Runtime env files are externalized under `env/`.
- Stateful services mount persistent volumes.

## 4) Deploy config (`config/project.env`)
- Set SSH target and compose file paths.
- Set image coordinates and default tags.
- Select migration strategy with `MIGRATION_MODE`.
- Configure `HEALTH_SERVICES` to include only critical services.

## 5) GitHub Actions wiring
- App repositories: build/push image and dispatch infra workflow.
- Infra repository: SSH to VPS and execute deploy engine.
- Validate required secrets/variables before first deploy.

## 6) First deploy flow
- Execute dry run first.
- Execute real deploy with immutable tags.
- Validate post-deploy health and logs.

## 7) Operations
- Define rollback runbook by tag rollback.
- Define backup/restore strategy for stateful data.
- Review periodic maintenance hooks (optional pre/post deploy hooks).
