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
  2) pre-deploy hook (optional)
  3) env materialization / update
  4) registry login
  5) image pull
  6) migration run
  7) compose up/recreate
  8) health checks
  9) cleanup/report
  10) post-deploy hook (optional)
HELP
}

is_set() {
  [ -n "${1:-}" ]
}

validate_image_tag_pair() {
  local image_var="$1"
  local tag_var="$2"
  local image_value="${!image_var:-}"
  local tag_value="${!tag_var:-}"

  if is_set "$image_value" && ! is_set "$tag_value"; then
    die "$image_var is set but $tag_var is empty"
  fi
  if ! is_set "$image_value" && is_set "$tag_value"; then
    die "$tag_var is set but $image_var is empty"
  fi
}

has_registry_auth() {
  is_set "${REGISTRY_USERNAME:-}" && is_set "${REGISTRY_PASSWORD:-}"
}

apply_override_if_set() {
  local name="$1"
  local value="$2"
  if is_set "$value"; then
    printf -v "$name" '%s' "$value"
  fi
}

validate_migration_mode() {
  case "${MIGRATION_MODE}" in
    none|service|command)
      ;;
    *)
      die "Invalid MIGRATION_MODE='${MIGRATION_MODE}' (expected: none|service|command)"
      ;;
  esac

  case "${MIGRATION_MODE}" in
    service)
      if ! is_set "${MIGRATOR_SERVICE:-}"; then
        die "MIGRATION_MODE=service requires MIGRATOR_SERVICE"
      fi
      ;;
    command)
      if ! is_set "${MIGRATION_COMMAND:-}"; then
        die "MIGRATION_MODE=command requires MIGRATION_COMMAND"
      fi
      ;;
  esac
}

validate_compose_files() {
  local compose_file

  [ -f "$COMPOSE_FILE" ] || die "COMPOSE_FILE not found: $COMPOSE_FILE"

  while IFS= read -r compose_file; do
    [ -n "$compose_file" ] || continue
    [ -f "$compose_file" ] || die "COMPOSE_EXTRA_FILES entry not found: $compose_file"
  done < <(split_csv "${COMPOSE_EXTRA_FILES:-}")
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

# Preserve process-level overrides injected by CI before sourcing config.
API_TAG_OVERRIDE="${API_TAG:-}"
MIGRATOR_TAG_OVERRIDE="${MIGRATOR_TAG:-}"
FRONT_TAG_OVERRIDE="${FRONT_TAG:-}"
REGISTRY_HOST_OVERRIDE="${REGISTRY_HOST:-}"
REGISTRY_USERNAME_OVERRIDE="${REGISTRY_USERNAME:-}"
REGISTRY_PASSWORD_OVERRIDE="${REGISTRY_PASSWORD:-}"
APP_ENV_B64_OVERRIDE="${APP_ENV_B64:-}"
EXTRA_ENV_B64_OVERRIDE="${EXTRA_ENV_B64:-}"
TUNNEL_TOKEN_OVERRIDE="${TUNNEL_TOKEN:-}"
EXTRA_PULL_IMAGES_OVERRIDE="${EXTRA_PULL_IMAGES:-}"

load_config "$CONFIG_PATH_ARG"

# Defaults (can be overridden in config or env)
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-180}"
HEALTH_POLL_SECONDS="${HEALTH_POLL_SECONDS:-5}"
DEPLOY_ENV_FILE="${DEPLOY_ENV_FILE:-${DEPLOY_PATH}/env/.env.deploy}"
APP_ENV_FILE="${APP_ENV_FILE:-${DEPLOY_PATH}/env/.env.app}"
CLOUDFLARED_ENV_FILE="${CLOUDFLARED_ENV_FILE:-${DEPLOY_PATH}/env/.env.cloudflared}"
CLEANUP_ENABLED="${CLEANUP_ENABLED:-true}"
EXTRA_PULL_IMAGES="${EXTRA_PULL_IMAGES:-}"
MIGRATION_MODE="${MIGRATION_MODE:-}"
MIGRATION_COMMAND="${MIGRATION_COMMAND:-}"
PRE_DEPLOY_HOOK="${PRE_DEPLOY_HOOK:-}"
POST_DEPLOY_HOOK="${POST_DEPLOY_HOOK:-}"

apply_override_if_set "API_TAG" "$API_TAG_OVERRIDE"
apply_override_if_set "MIGRATOR_TAG" "$MIGRATOR_TAG_OVERRIDE"
apply_override_if_set "FRONT_TAG" "$FRONT_TAG_OVERRIDE"
apply_override_if_set "REGISTRY_HOST" "$REGISTRY_HOST_OVERRIDE"
apply_override_if_set "REGISTRY_USERNAME" "$REGISTRY_USERNAME_OVERRIDE"
apply_override_if_set "REGISTRY_PASSWORD" "$REGISTRY_PASSWORD_OVERRIDE"
apply_override_if_set "APP_ENV_B64" "$APP_ENV_B64_OVERRIDE"
apply_override_if_set "EXTRA_ENV_B64" "$EXTRA_ENV_B64_OVERRIDE"
apply_override_if_set "TUNNEL_TOKEN" "$TUNNEL_TOKEN_OVERRIDE"
apply_override_if_set "EXTRA_PULL_IMAGES" "$EXTRA_PULL_IMAGES_OVERRIDE"

if [ -z "$MIGRATION_MODE" ]; then
  if is_set "${MIGRATOR_SERVICE:-}"; then
    MIGRATION_MODE="service"
  else
    MIGRATION_MODE="none"
  fi
fi

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

  require_var API_IMAGE
  require_var API_TAG
  validate_image_tag_pair "MIGRATOR_IMAGE" "MIGRATOR_TAG"
  validate_image_tag_pair "FRONT_IMAGE" "FRONT_TAG"

  if is_set "${REGISTRY_USERNAME:-}" && ! is_set "${REGISTRY_PASSWORD:-}"; then
    die "REGISTRY_USERNAME is set but REGISTRY_PASSWORD is empty"
  fi
  if ! is_set "${REGISTRY_USERNAME:-}" && is_set "${REGISTRY_PASSWORD:-}"; then
    die "REGISTRY_PASSWORD is set but REGISTRY_USERNAME is empty"
  fi
  if has_registry_auth; then
    require_var REGISTRY_HOST
  fi
  validate_migration_mode

  [ -d "$DEPLOY_PATH" ] || die "DEPLOY_PATH does not exist: $DEPLOY_PATH"
  validate_compose_files

  if [ "$DRY_RUN" != "1" ]; then
    docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"
    docker compose version >/dev/null 2>&1 || die "docker compose v2 is required"
  fi
}

stage_env_materialization() {
  upsert_env_var "$DEPLOY_ENV_FILE" "API_TAG" "$API_TAG"

  if is_set "${MIGRATOR_TAG:-}"; then
    upsert_env_var "$DEPLOY_ENV_FILE" "MIGRATOR_TAG" "$MIGRATOR_TAG"
  fi
  if is_set "${FRONT_TAG:-}"; then
    upsert_env_var "$DEPLOY_ENV_FILE" "FRONT_TAG" "$FRONT_TAG"
  fi

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

stage_pre_deploy_hook() {
  if [ -z "$PRE_DEPLOY_HOOK" ]; then
    log "INFO" "PRE_DEPLOY_HOOK empty -> skipping pre-deploy hook stage"
    return 0
  fi
  run_cmd bash -lc "$PRE_DEPLOY_HOOK"
}

stage_registry_login() {
  if ! has_registry_auth; then
    log "INFO" "Registry credentials not configured -> skipping registry login stage"
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    print_cmd docker login "$REGISTRY_HOST" -u "$REGISTRY_USERNAME" --password-stdin
    return 0
  fi

  printf '%s' "$REGISTRY_PASSWORD" | docker login "$REGISTRY_HOST" -u "$REGISTRY_USERNAME" --password-stdin
}

stage_image_pull() {
  local image
  local images=("${API_IMAGE}:${API_TAG}")

  if is_set "${MIGRATOR_IMAGE:-}" && is_set "${MIGRATOR_TAG:-}"; then
    images+=("${MIGRATOR_IMAGE}:${MIGRATOR_TAG}")
  else
    log "INFO" "MIGRATOR_IMAGE/MIGRATOR_TAG not configured -> skipping migrator image pull"
  fi

  if is_set "${FRONT_IMAGE:-}" && is_set "${FRONT_TAG:-}"; then
    images+=("${FRONT_IMAGE}:${FRONT_TAG}")
  else
    log "INFO" "FRONT_IMAGE/FRONT_TAG not configured -> skipping front image pull"
  fi

  while IFS= read -r image; do
    [ -n "$image" ] || continue
    images+=("$image")
  done < <(split_csv "$EXTRA_PULL_IMAGES")

  for image in "${images[@]}"; do
    run_cmd docker pull "$image"
  done
}

stage_migration() {
  case "$MIGRATION_MODE" in
    none)
      log "INFO" "MIGRATION_MODE=none -> skipping migration stage"
      return 0
      ;;
    service)
      compose_stdin_null run --rm -T "$MIGRATOR_SERVICE"
      ;;
    command)
      run_cmd bash -lc "$MIGRATION_COMMAND"
      ;;
  esac
}

stage_compose_up() {
  compose up -d --remove-orphans --pull always --force-recreate
}

stage_health_checks() {
  if [ -z "${HEALTH_SERVICES:-}" ]; then
    log "INFO" "HEALTH_SERVICES empty -> skipping health checks stage"
    return 0
  fi
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

stage_post_deploy_hook() {
  if [ -z "$POST_DEPLOY_HOOK" ]; then
    log "INFO" "POST_DEPLOY_HOOK empty -> skipping post-deploy hook stage"
    return 0
  fi
  run_cmd bash -lc "$POST_DEPLOY_HOOK"
}

run_stage "01-preflight" stage_preflight
run_stage "02-pre-deploy-hook" stage_pre_deploy_hook
run_stage "03-env-materialization" stage_env_materialization
run_stage "04-registry-login" stage_registry_login
run_stage "05-image-pull" stage_image_pull
run_stage "06-migration" stage_migration
run_stage "07-compose-up" stage_compose_up
run_stage "08-health-checks" stage_health_checks
run_stage "09-cleanup-report" stage_cleanup_report
run_stage "10-post-deploy-hook" stage_post_deploy_hook

log "INFO" "Deploy finished successfully"
