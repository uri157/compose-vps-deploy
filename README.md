# compose-vps-deploy

A lightweight, deterministic deploy toolkit for Docker Compose workloads on a VPS.

Designed for small production stacks that need safer, repeatable deployments without adopting a full orchestration platform.

It provides a deterministic deploy engine with safety checks, migration execution, health validation, and cleanup, exposed through a simple CLI plus a thin GitHub Actions adapter.

## MVP Scope (v0.1)

- Single host, single environment (production)
- CLI engine:
  - `doctor` (preflight)
  - `deploy` (full pipeline)
  - `verify` (health verification)
- Config contract in one env file: `config/project.env`
- GitHub Actions template for remote deploy over SSH
- GitHub Actions templates for app repos (build/push/dispatch)

## Quick Start

1. Copy the config template:

```bash
cp config/project.env.example config/project.env
```

2. Edit required values in `config/project.env`.

3. Run preflight checks on target host:

```bash
bash scripts/doctor.sh --config config/project.env
```

4. Run deploy:

```bash
bash scripts/deploy.sh --config config/project.env
```

5. Verify services:

```bash
bash scripts/verify.sh --config config/project.env
```

## Deploy Stages

`deploy` runs these stages in order:

1. preflight checks
2. env materialization/update
3. registry login
4. image pull
5. migration run
6. compose up/recreate
7. health checks
8. cleanup/report

Dry-run mode:

```bash
bash scripts/deploy.sh --config config/project.env --dry-run
```

## Repository Layout

- `scripts/`: CLI engine (`doctor.sh`, `deploy.sh`, `verify.sh`)
- `scripts/lib/`: shared runtime helpers
- `config/`: configuration contract (`project.env.example`)
- `workflows/github/`: reusable GitHub Actions templates
- `examples/minimal-compose/`: generic sample stack and onboarding files
- `docs/`: architecture/config notes

## GitHub Actions Adapter

Use `workflows/github/deploy.yml` as template in your infrastructure repository.

It is intentionally thin: it only resolves inputs/secrets, opens SSH, and invokes the CLI engine remotely.

For app repositories, use:

- `workflows/github/backend-build-dispatch.yml`
- `workflows/github/frontend-build-dispatch.yml`

These templates build and push images, then dispatch infra deploy with image tags.

Full integration guide:

- `docs/github-integration.md`

## Quality Gates

- `shellcheck` for scripts
- `shfmt -d` for formatting checks
- smoke tests in `scripts/tests/mvp-smoke.sh`

## License

MIT
