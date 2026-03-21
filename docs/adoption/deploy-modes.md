# Deploy Modes With Compose Overrides

Use one base compose file and small override files to support both deployment modes without duplicating the full stack.

## Recommended structure

1. Base: `docker-compose.prod.yml`
- Shared services and networks.
- No host-published ports.

2. Single-host override: `docker-compose.single-host.yml`
- Adds host port bindings (for example `80:8080` on nginx).

3. Multi-project/edge override: `docker-compose.edge-cloudflared.yml`
- Adds edge connector service (for example cloudflared).
- Keeps app services private (no host ports).

## Engine configuration

`compose-vps-deploy` always loads `COMPOSE_FILE` first, then appends files from `COMPOSE_EXTRA_FILES` in CSV order.

Example single-host:

```env
COMPOSE_FILE=/opt/myapp/docker-compose.prod.yml
COMPOSE_EXTRA_FILES=/opt/myapp/docker-compose.single-host.yml
```

Example multi-project with edge tunnel:

```env
COMPOSE_FILE=/opt/myapp/docker-compose.prod.yml
COMPOSE_EXTRA_FILES=/opt/myapp/docker-compose.edge-cloudflared.yml
```

## Operational notes

- Keep healthchecks in base services so checks are mode-independent.
- Keep stateful volumes in base compose so persistence does not depend on mode.
- Use mode-specific config files (for example `config/project.single.env` and `config/project.multi.env`) when teams need to switch frequently.
