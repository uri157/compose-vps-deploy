#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

CONFIG_PATH_ARG=""
SERVICES_OVERRIDE=""
TIMEOUT_OVERRIDE=""
INTERVAL_OVERRIDE=""

usage() {
  cat <<'HELP'
Usage:
  bash scripts/verify.sh [--config <path>] [--services csv] [--timeout seconds] [--interval seconds] [--dry-run]

Verifies service health/running state for configured compose services.
HELP
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      [ $# -ge 2 ] || die "--config requires a value"
      CONFIG_PATH_ARG="$2"
      shift 2
      ;;
    --services)
      [ $# -ge 2 ] || die "--services requires csv"
      SERVICES_OVERRIDE="$2"
      shift 2
      ;;
    --timeout)
      [ $# -ge 2 ] || die "--timeout requires seconds"
      TIMEOUT_OVERRIDE="$2"
      shift 2
      ;;
    --interval)
      [ $# -ge 2 ] || die "--interval requires seconds"
      INTERVAL_OVERRIDE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
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

require_cmd docker
require_var COMPOSE_FILE

services="${SERVICES_OVERRIDE:-${HEALTH_SERVICES:-}}"
timeout="${TIMEOUT_OVERRIDE:-${HEALTH_TIMEOUT_SECONDS:-180}}"
interval="${INTERVAL_OVERRIDE:-${HEALTH_POLL_SECONDS:-5}}"

[ -n "$services" ] || die "No services configured (HEALTH_SERVICES or --services)"

verify_stage() {
  verify_services "$services" "$timeout" "$interval"
}

run_stage "verify-health" verify_stage

log "INFO" "Verification passed"
