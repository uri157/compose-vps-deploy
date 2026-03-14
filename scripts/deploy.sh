#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

CONFIG_PATH_ARG=""
CLEANUP_OVERRIDE=""

usage() {
  cat <<'HELP'
Usage:
  bash scripts/deploy.sh [--config <path>] [--dry-run] [--no-cleanup]

Stages:
  1) preflight checks
  2) env materialization / update
  3) registry login
  4) image pull
  5) migration run
  6) compose up/recreate
  7) health checks
  8) cleanup/report
HELP
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      [ $# -ge 2 ] || die "--config requires a value"
      CONFIG_PATH_ARG="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-cleanup)
      CLEANUP_OVERRIDE="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

load_config "$CONFIG_PATH_ARG"

# Defaults (can be overridden in config or env)
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-180}"
HEALTH_POLL_SECONDS="${HEALTH_POLL_SECONDS:-5}"
DEPLOY_ENV_FILE="${DEPLOY_ENV_FILE:-${DEPLOY_PATH}/env/.env.deploy}"
APP_ENV_FILE="${APP_ENV_FILE:-${DEPLOY_PATH}/env/.env.app}"
CLOUDFLARED_ENV_FILE="${CLOUDFLARED_ENV_FILE:-${DEPLOY_PATH}/env/.env.cloudflared}"
CLEANUP_ENABLED="${CLEANUP_ENABLED:-true}"
EXTRA_PULL_IMAGES="${EXTRA_PULL_IMAGES:-}"

if [ -n "$CLEANUP_OVERRIDE" ]; then
  CLEANUP_ENABLED="$CLEANUP_OVERRIDE"
fi

stage_preflight() {
  require_cmd docker
  require_cmd awk
  require_cmd sed
  require_cmd grep
  require_cmd base64

  require_var SSH_HOST
  require_var SSH_USER
  require_var SSH_PORT
  require_var DEPLOY_PATH

  require_var COMPOSE_FILE

  require_var REGISTRY_HOST
  require_var REGISTRY_USERNAME
  require_var REGISTRY_PASSWORD

  require_var API_IMAGE
  require_var MIGRATOR_IMAGE
  require_var FRONT_IMAGE
  require_var API_TAG
  require_var MIGRATOR_TAG
  require_var FRONT_TAG

  require_var MIGRATOR_SERVICE
  require_var HEALTH_SERVICES

  [ -d "$DEPLOY_PATH" ] || die "DEPLOY_PATH does not exist: $DEPLOY_PATH"
  [ -f "$COMPOSE_FILE" ] || die "COMPOSE_FILE not found: $COMPOSE_FILE"

  if [ "$DRY_RUN" != "1" ]; then
    docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"
    docker compose version >/dev/null 2>&1 || die "docker compose v2 is required"
  fi
}

stage_env_materialization() {
  upsert_env_var "$DEPLOY_ENV_FILE" "API_TAG" "$API_TAG"
  upsert_env_var "$DEPLOY_ENV_FILE" "MIGRATOR_TAG" "$MIGRATOR_TAG"
  upsert_env_var "$DEPLOY_ENV_FILE" "FRONT_TAG" "$FRONT_TAG"

  if [ -n "${APP_ENV_B64:-}" ]; then
    log "INFO" "Decoding APP_ENV_B64 -> ${APP_ENV_FILE}"
    decode_b64_to_file "$APP_ENV_B64" "$APP_ENV_FILE"
  fi

  if [ -n "${EXTRA_ENV_B64:-}" ] && [ -n "${EXTRA_ENV_FILE:-}" ]; then
    log "INFO" "Decoding EXTRA_ENV_B64 -> ${EXTRA_ENV_FILE}"
    decode_b64_to_file "$EXTRA_ENV_B64" "$EXTRA_ENV_FILE"
  fi

  if [ -n "${TUNNEL_TOKEN:-}" ]; then
    log "INFO" "Writing cloudflared token env file"
    write_file_content "$CLOUDFLARED_ENV_FILE" "TUNNEL_TOKEN=${TUNNEL_TOKEN}\n"
  fi
}

stage_registry_login() {
  if [ "$DRY_RUN" = "1" ]; then
    print_cmd docker login "$REGISTRY_HOST" -u "$REGISTRY_USERNAME" --password-stdin
    return 0
  fi

  printf '%s' "$REGISTRY_PASSWORD" | docker login "$REGISTRY_HOST" -u "$REGISTRY_USERNAME" --password-stdin
}

stage_image_pull() {
  local image
  local images=(
    "${API_IMAGE}:${API_TAG}"
    "${MIGRATOR_IMAGE}:${MIGRATOR_TAG}"
    "${FRONT_IMAGE}:${FRONT_TAG}"
  )

  while IFS= read -r image; do
    [ -n "$image" ] || continue
    images+=("$image")
  done < <(split_csv "$EXTRA_PULL_IMAGES")

  for image in "${images[@]}"; do
    run_cmd docker pull "$image"
  done
}

stage_migration() {
  if [ -z "$MIGRATOR_SERVICE" ]; then
    log "INFO" "MIGRATOR_SERVICE empty -> skipping migration stage"
    return 0
  fi

  compose_stdin_null run --rm -T "$MIGRATOR_SERVICE"
}

stage_compose_up() {
  compose up -d --remove-orphans --pull always --force-recreate
}

stage_health_checks() {
  verify_services "$HEALTH_SERVICES" "$HEALTH_TIMEOUT_SECONDS" "$HEALTH_POLL_SECONDS"
}

stage_cleanup_report() {
  if is_true "$CLEANUP_ENABLED"; then
    run_cmd docker container prune -f
    run_cmd docker image prune -f
    run_cmd docker builder prune -f
    run_cmd docker network prune -f
  fi

  compose ps -a
}

run_stage "01-preflight" stage_preflight
run_stage "02-env-materialization" stage_env_materialization
run_stage "03-registry-login" stage_registry_login
run_stage "04-image-pull" stage_image_pull
run_stage "05-migration" stage_migration
run_stage "06-compose-up" stage_compose_up
run_stage "07-health-checks" stage_health_checks
run_stage "08-cleanup-report" stage_cleanup_report

log "INFO" "Deploy finished successfully"
