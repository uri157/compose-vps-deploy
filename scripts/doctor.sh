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
}

check_paths() {
  [ -d "$DEPLOY_PATH" ] || die "DEPLOY_PATH does not exist: $DEPLOY_PATH"
  [ -f "$COMPOSE_FILE" ] || die "COMPOSE_FILE not found: $COMPOSE_FILE"
}

run_stage "01-commands" check_commands
run_stage "02-config" check_config
run_stage "03-paths" check_paths

log "INFO" "Doctor checks passed"
