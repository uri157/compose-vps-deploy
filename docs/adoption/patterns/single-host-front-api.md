# Pattern: Single Host Front + API

## Topology
- One VPS host.
- Reverse proxy (`nginx`) as public entrypoint.
- Internal services: `front`, `api`, optional `migrator`, optional DB.

## Routing options
1. Path-based:
- `/` -> `front`
- `/api` and `/ws` -> `api`

2. Host-based:
- `app.example.com` -> `front`
- `api.example.com` -> `api`

## Minimal deploy contract
- `API_IMAGE` + `API_TAG`
- `FRONT_IMAGE` + `FRONT_TAG`
- `MIGRATION_MODE=none|service|command`
- `HEALTH_SERVICES=api,front,nginx`

## Notes
- Keep frontend/API URL strategy explicit (build-time vs runtime env).
- Keep websocket proxy headers (`Upgrade`, `Connection`) configured.
