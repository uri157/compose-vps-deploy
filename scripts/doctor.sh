#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

CONFIG_PATH_ARG=""

usage() {
  cat <<'HELP'
Usage:
  bash scripts/doctor.sh [--config <path>]

Checks:
  - required commands (docker, docker compose, ssh)
  - required configuration keys
  - basic path validation for deploy + compose files
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

resolve_migration_mode() {
  local migration_mode="${MIGRATION_MODE:-}"
  if [ -z "$migration_mode" ]; then
    if is_set "${MIGRATOR_SERVICE:-}"; then
      migration_mode="service"
    else
      migration_mode="none"
    fi
  fi
  printf '%s' "$migration_mode"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      [ $# -ge 2 ] || die "--config requires a value"
      CONFIG_PATH_ARG="$2"
      shift 2
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

check_commands() {
  require_cmd bash
  require_cmd docker
  require_cmd ssh
  docker compose version >/dev/null 2>&1 || die "docker compose v2 is required"
}

check_config() {
  local migration_mode

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
  if is_set "${REGISTRY_USERNAME:-}" && is_set "${REGISTRY_PASSWORD:-}"; then
    require_var REGISTRY_HOST
  fi

  migration_mode="$(resolve_migration_mode)"
  case "$migration_mode" in
    none|service|command)
      ;;
    *)
      die "Invalid MIGRATION_MODE='${migration_mode}' (expected: none|service|command)"
      ;;
  esac

  if [ "$migration_mode" = "service" ] && ! is_set "${MIGRATOR_SERVICE:-}"; then
    die "MIGRATION_MODE=service requires MIGRATOR_SERVICE"
  fi
  if [ "$migration_mode" = "command" ] && ! is_set "${MIGRATION_COMMAND:-}"; then
    die "MIGRATION_MODE=command requires MIGRATION_COMMAND"
  fi
}

check_paths() {
  [ -d "$DEPLOY_PATH" ] || die "DEPLOY_PATH does not exist: $DEPLOY_PATH"
  [ -f "$COMPOSE_FILE" ] || die "COMPOSE_FILE not found: $COMPOSE_FILE"
}

run_stage "01-commands" check_commands
run_stage "02-config" check_config
run_stage "03-paths" check_paths

log "INFO" "Doctor checks passed"
