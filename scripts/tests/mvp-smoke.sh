#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKEBIN="$TMP_DIR/fakebin"
NODOCKERBIN="$TMP_DIR/nodockerbin"
mkdir -p "$FAKEBIN" "$NODOCKERBIN" "$TMP_DIR/deploy"

cat > "$FAKEBIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

echo "$*" >> "${FAKE_DOCKER_LOG:?}"

if [ "${1:-}" = "info" ]; then
  exit 0
fi

if [ "${1:-}" = "login" ]; then
  exit 0
fi

if [ "${1:-}" = "pull" ]; then
  exit 0
fi

if [ "${1:-}" = "container" ] || [ "${1:-}" = "image" ] || [ "${1:-}" = "builder" ] || [ "${1:-}" = "network" ]; then
  exit 0
fi

if [ "${1:-}" = "inspect" ]; then
  tmpl="${3:-}"
  cid="${4:-}"
  if [[ "$tmpl" == *"State.Health"* ]]; then
    case "$cid" in
      cid_badsvc) echo "unhealthy" ;;
      *) echo "healthy" ;;
    esac
    exit 0
  fi
  if [[ "$tmpl" == *"State.Status"* ]]; then
    echo "running"
    exit 0
  fi
fi

if [ "${1:-}" = "compose" ]; then
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -p|--project-name|--project-directory|--env-file|-f)
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done

  sub="${1:-}"
  shift || true

  case "$sub" in
    version)
      exit 0
      ;;
    ps)
      if [ "${1:-}" = "-q" ]; then
        svc="${2:-}"
        echo "cid_${svc}"
      fi
      exit 0
      ;;
    logs)
      exit 0
      ;;
    run)
      if [ "${FAKE_MIGRATOR_FAIL:-0}" = "1" ]; then
        exit 17
      fi
      exit 0
      ;;
    up)
      exit 0
      ;;
    *)
      exit 0
      ;;
  esac
fi

exit 0
FAKE_DOCKER

cat > "$FAKEBIN/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -euo pipefail
exit 0
FAKE_SSH

chmod +x "$FAKEBIN/docker" "$FAKEBIN/ssh"

# Minimal bins for missing-docker scenario
ln -s /usr/bin/bash "$NODOCKERBIN/bash"
ln -s /usr/bin/dirname "$NODOCKERBIN/dirname"
ln -s /usr/bin/date "$NODOCKERBIN/date"
ln -s /usr/bin/ssh "$NODOCKERBIN/ssh"

cat > "$TMP_DIR/config.env" <<EOF_CONFIG
SSH_HOST=example.com
SSH_USER=deploy
SSH_PORT=22
DEPLOY_PATH=$TMP_DIR/deploy
COMPOSE_FILE=$TMP_DIR/deploy/docker-compose.prod.yml
REGISTRY_HOST=ghcr.io
REGISTRY_USERNAME=u
REGISTRY_PASSWORD=p
API_IMAGE=ghcr.io/acme/api
MIGRATOR_IMAGE=ghcr.io/acme/migrator
FRONT_IMAGE=ghcr.io/acme/front
API_TAG=latest
MIGRATOR_TAG=latest
FRONT_TAG=latest
MIGRATOR_SERVICE=migrator
HEALTH_SERVICES=postgres,api,front,nginx
HEALTH_TIMEOUT_SECONDS=5
HEALTH_POLL_SECONDS=1
DEPLOY_ENV_FILE=$TMP_DIR/deploy/.env.deploy
APP_ENV_FILE=$TMP_DIR/deploy/.env.app
CLEANUP_ENABLED=false
EOF_CONFIG

touch "$TMP_DIR/deploy/docker-compose.prod.yml"

FAKE_DOCKER_LOG="$TMP_DIR/docker.log"
export FAKE_DOCKER_LOG

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if ! grep -q "$needle" <<<"$haystack"; then
    echo "ASSERTION FAILED: expected to find '$needle'" >&2
    return 1
  fi
}

echo "[test] doctor fails when docker command is unavailable"
set +e
OUT_DOCTOR_FAIL=$(env -i PATH="$NODOCKERBIN" HOME="$TMP_DIR" /usr/bin/bash "$ROOT_DIR/scripts/doctor.sh" --config "$TMP_DIR/config.env" 2>&1)
RC_DOCTOR_FAIL=$?
set -e
[ $RC_DOCTOR_FAIL -ne 0 ] || { echo "doctor should fail without docker" >&2; exit 1; }
assert_contains "$OUT_DOCTOR_FAIL" "Missing required command: docker"

echo "[test] deploy --dry-run prints ordered stages"
OUT_DRY=$(PATH="$FAKEBIN:/usr/bin:/bin" "$ROOT_DIR/scripts/deploy.sh" --config "$TMP_DIR/config.env" --dry-run 2>&1)
assert_contains "$OUT_DRY" "[01-preflight] start"
assert_contains "$OUT_DRY" "[08-cleanup-report] done"

echo "[test] deploy fails when migrator fails"
set +e
OUT_MIG_FAIL=$(FAKE_MIGRATOR_FAIL=1 PATH="$FAKEBIN:/usr/bin:/bin" "$ROOT_DIR/scripts/deploy.sh" --config "$TMP_DIR/config.env" 2>&1)
RC_MIG_FAIL=$?
set -e
[ $RC_MIG_FAIL -ne 0 ] || { echo "deploy should fail when migrator fails" >&2; exit 1; }
assert_contains "$OUT_MIG_FAIL" "[05-migration] failed"

echo "[test] verify fails for unhealthy service"
set +e
OUT_VERIFY_FAIL=$(PATH="$FAKEBIN:/usr/bin:/bin" "$ROOT_DIR/scripts/verify.sh" --config "$TMP_DIR/config.env" --services badsvc --timeout 1 --interval 1 2>&1)
RC_VERIFY_FAIL=$?
set -e
[ $RC_VERIFY_FAIL -ne 0 ] || { echo "verify should fail for unhealthy service" >&2; exit 1; }
assert_contains "$OUT_VERIFY_FAIL" "Service unhealthy: badsvc"

echo "All MVP smoke tests passed"
