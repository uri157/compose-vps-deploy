#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

CONFIG_PATH_ARG=""
CONFIG_PATH_TMP=""
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

cleanup_tmp_config() {
  if [ -n "${CONFIG_PATH_TMP:-}" ] && [ -f "$CONFIG_PATH_TMP" ]; then
    rm -f "$CONFIG_PATH_TMP"
  fi
}

payload_looks_like_env_file() {
  local payload="${1:-}"
  local line trimmed
  local has_assignment=0

  [ -n "$payload" ] || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    trimmed="$(trim "$line")"

    [ -z "$trimmed" ] && continue
    case "$trimmed" in
      \#*) continue ;;
    esac

    if [[ "$trimmed" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      has_assignment=1
      continue
    fi

    return 1
  done <<< "$payload"

  [ "$has_assignment" = "1" ]
}

materialize_env_payload_to_file() {
  local payload="${1:-}"
  local target_file="${2:-}"
  local payload_name="${3:-payload}"
  local force_write="${4:-0}"
  local parent

  if [ -z "$payload" ]; then
    return 0
  fi
  if [ -z "$target_file" ]; then
    die "${payload_name} target file is empty"
  fi

  if [ "$DRY_RUN" = "1" ] && [ "$force_write" != "1" ]; then
    if payload_looks_like_env_file "$payload"; then
      print_cmd sh -c "printf '%s' '<plain env payload>' > '$target_file'"
    else
      print_cmd sh -c "base64 -d > '$target_file'"
    fi
    return 0
  fi

  parent="$(dirname "$target_file")"
  mkdir -p "$parent"

  if payload_looks_like_env_file "$payload"; then
    printf '%s' "$payload" > "$target_file"
  else
    require_cmd base64
    if ! printf '%s' "$payload" | base64 -d > "$target_file"; then
      die "Failed to materialize ${payload_name} into ${target_file}. Expected plain env text or valid base64 payload."
    fi
  fi

  sed -i 's/\r$//' "$target_file" || true
}

materialize_config_override_if_set() {
  local payload="${1:-}"
  local target_path

  if [ -z "$payload" ]; then
    return 0
  fi

  target_path="${CONFIG_PATH_ARG:-$DEFAULT_CONFIG_PATH}"

  if [ "$DRY_RUN" = "1" ]; then
    CONFIG_PATH_TMP="$(mktemp)"
    materialize_env_payload_to_file "$payload" "$CONFIG_PATH_TMP" "PROJECT_ENV_B64" "1"
    CONFIG_PATH_ARG="$CONFIG_PATH_TMP"
    log "INFO" "[dry-run] materialized PROJECT_ENV_B64 into temp config: ${CONFIG_PATH_TMP}"
    return 0
  fi

  log "INFO" "Materializing PROJECT_ENV_B64 -> ${target_path}"
  materialize_env_payload_to_file "$payload" "$target_path" "PROJECT_ENV_B64" "1"
  CONFIG_PATH_ARG="$target_path"
}

decode_env_payload_if_set() {
  local payload="${1:-}"
  local payload_name="${2:-}"
  local target_file="${3:-}"
  local label="${4:-}"

  if [ -z "$payload" ]; then
    return 0
  fi
  if [ -z "$target_file" ]; then
    die "${payload_name} is set but ${label} is empty"
  fi

  log "INFO" "Materializing ${payload_name} -> ${target_file}"
  materialize_env_payload_to_file "$payload" "$target_file" "$payload_name" "0"
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

trap cleanup_tmp_config EXIT

# Preserve process-level overrides injected by CI before sourcing config.
PROJECT_ENV_B64_OVERRIDE="${PROJECT_ENV_B64:-}"
API_TAG_OVERRIDE="${API_TAG:-}"
MIGRATOR_TAG_OVERRIDE="${MIGRATOR_TAG:-}"
FRONT_TAG_OVERRIDE="${FRONT_TAG:-}"
REGISTRY_HOST_OVERRIDE="${REGISTRY_HOST:-}"
REGISTRY_USERNAME_OVERRIDE="${REGISTRY_USERNAME:-}"
REGISTRY_PASSWORD_OVERRIDE="${REGISTRY_PASSWORD:-}"
DB_ENV_B64_OVERRIDE="${DB_ENV_B64:-}"
API_ENV_B64_OVERRIDE="${API_ENV_B64:-}"
FRONT_ENV_B64_OVERRIDE="${FRONT_ENV_B64:-}"
TUNNEL_TOKEN_OVERRIDE="${TUNNEL_TOKEN:-}"
EXTRA_PULL_IMAGES_OVERRIDE="${EXTRA_PULL_IMAGES:-}"

materialize_config_override_if_set "$PROJECT_ENV_B64_OVERRIDE"
load_config "$CONFIG_PATH_ARG"

# Defaults (can be overridden in config or env)
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-180}"
HEALTH_POLL_SECONDS="${HEALTH_POLL_SECONDS:-5}"
DEPLOY_ENV_FILE="${DEPLOY_ENV_FILE:-${DEPLOY_PATH}/env/.env.deploy}"
DB_ENV_FILE="${DB_ENV_FILE:-${DEPLOY_PATH}/env/.env.db}"
API_ENV_FILE="${API_ENV_FILE:-${DEPLOY_PATH}/env/.env.api}"
FRONT_ENV_FILE="${FRONT_ENV_FILE:-${DEPLOY_PATH}/env/.env.front}"
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
apply_override_if_set "DB_ENV_B64" "$DB_ENV_B64_OVERRIDE"
apply_override_if_set "API_ENV_B64" "$API_ENV_B64_OVERRIDE"
apply_override_if_set "FRONT_ENV_B64" "$FRONT_ENV_B64_OVERRIDE"
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

  decode_env_payload_if_set "${DB_ENV_B64:-}" "DB_ENV_B64" "${DB_ENV_FILE:-}" "DB_ENV_FILE"
  decode_env_payload_if_set "${API_ENV_B64:-}" "API_ENV_B64" "${API_ENV_FILE:-}" "API_ENV_FILE"
  decode_env_payload_if_set "${FRONT_ENV_B64:-}" "FRONT_ENV_B64" "${FRONT_ENV_FILE:-}" "FRONT_ENV_FILE"

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
