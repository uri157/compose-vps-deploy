#!/usr/bin/env bash

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${LIB_DIR}/../.." && pwd)"
DEFAULT_CONFIG_PATH="${ROOT_DIR}/config/project.env"

DRY_RUN="${DRY_RUN:-0}"

log() {
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*"
}

die() {
  log "ERROR" "$*"
  exit 1
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

trim() {
  local s="${1:-}"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
}

require_var() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    die "Missing required variable: $name"
  fi
}

load_config() {
  local config_path="${1:-$DEFAULT_CONFIG_PATH}"
  [ -f "$config_path" ] || die "Config file not found: $config_path"

  set -a
  # shellcheck disable=SC1090
  . "$config_path"
  set +a

  CONFIG_PATH="$config_path"
}

print_cmd() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
}

run_cmd() {
  if [ "$DRY_RUN" = "1" ]; then
    print_cmd "$@"
    return 0
  fi
  "$@"
}

run_cmd_stdin_null() {
  if [ "$DRY_RUN" = "1" ]; then
    print_cmd "$@"
    echo '+ (stdin) </dev/null'
    return 0
  fi
  "$@" </dev/null
}

ensure_parent_dir() {
  local path="$1"
  local parent
  parent="$(dirname "$path")"
  if [ "$DRY_RUN" = "1" ]; then
    print_cmd mkdir -p "$parent"
    return 0
  fi
  mkdir -p "$parent"
}

write_file_content() {
  local path="$1"
  local content="$2"
  ensure_parent_dir "$path"

  if [ "$DRY_RUN" = "1" ]; then
    print_cmd sh -c "printf '%s' '<content>' > '$path'"
    return 0
  fi

  printf '%s' "$content" > "$path"
}

upsert_env_var() {
  local file="$1"
  local key="$2"
  local value="$3"

  ensure_parent_dir "$file"

  if [ "$DRY_RUN" = "1" ]; then
    print_cmd sh -c "upsert ${key} in ${file}"
    return 0
  fi

  [ -f "$file" ] || : > "$file"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

decode_b64_to_file() {
  local b64_value="$1"
  local target_file="$2"

  if [ -z "$b64_value" ]; then
    return 0
  fi

  ensure_parent_dir "$target_file"

  if [ "$DRY_RUN" = "1" ]; then
    print_cmd sh -c "base64 -d > '$target_file'"
    return 0
  fi

  if ! printf '%s' "$b64_value" | base64 -d > "$target_file"; then
    die "Failed to decode base64 payload into $target_file"
  fi

  sed -i 's/\r$//' "$target_file" || true
}

split_csv() {
  local raw="${1:-}"
  local item
  local out=()

  IFS=',' read -r -a _arr <<< "$raw"
  for item in "${_arr[@]}"; do
    item="$(trim "$item")"
    if [ -n "$item" ]; then
      out+=("$item")
    fi
  done

  printf '%s\n' "${out[@]}"
}

compose() {
  local args=()
  local env_file

  require_var COMPOSE_FILE

  if [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
    args+=( -p "$COMPOSE_PROJECT_NAME" )
  fi

  if [ -n "${COMPOSE_ENV_FILES:-}" ]; then
    while IFS= read -r env_file; do
      [ -n "$env_file" ] || continue
      args+=( --env-file "$env_file" )
    done < <(split_csv "$COMPOSE_ENV_FILES")
  fi

  args+=( -f "$COMPOSE_FILE" )

  if [ "$DRY_RUN" = "1" ]; then
    print_cmd docker compose "${args[@]}" "$@"
    return 0
  fi

  docker compose "${args[@]}" "$@"
}

compose_stdin_null() {
  if [ "$DRY_RUN" = "1" ]; then
    compose "$@"
    echo '+ (stdin) </dev/null'
    return 0
  fi
  compose "$@" </dev/null
}

dump_service_logs() {
  local service="$1"
  compose logs --tail 120 "$service" || true
}

wait_for_service_health() {
  local service="$1"
  local timeout="${2:-120}"
  local interval="${3:-5}"
  local start now cid health state

  start="$(date +%s)"
  while true; do
    cid="$(compose ps -q "$service" 2>/dev/null || true)"
    if [ -z "$cid" ]; then
      log "ERROR" "Missing container for service: $service"
      compose ps -a || true
      return 1
    fi

    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || true)"
    state="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || true)"

    case "$health" in
      healthy)
        log "INFO" "Service healthy: $service"
        return 0
        ;;
      unhealthy)
        log "ERROR" "Service unhealthy: $service"
        dump_service_logs "$service"
        return 1
        ;;
      none)
        if [ "$state" = "running" ]; then
          log "INFO" "Service running (no healthcheck): $service"
          return 0
        fi
        ;;
    esac

    now="$(date +%s)"
    if [ $((now - start)) -ge "$timeout" ]; then
      log "ERROR" "Timeout waiting for service: $service"
      dump_service_logs "$service"
      return 1
    fi

    sleep "$interval"
  done
}

verify_services() {
  local services_csv="$1"
  local timeout="${2:-120}"
  local interval="${3:-5}"
  local svc

  if [ "$DRY_RUN" = "1" ]; then
    while IFS= read -r svc; do
      [ -n "$svc" ] || continue
      log "INFO" "[dry-run] would verify service: $svc"
    done < <(split_csv "$services_csv")
    return 0
  fi

  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    wait_for_service_health "$svc" "$timeout" "$interval"
  done < <(split_csv "$services_csv")
}

run_stage() {
  local stage="$1"
  shift

  log "INFO" "[${stage}] start"
  if ! "$@"; then
    die "[${stage}] failed"
  fi
  log "INFO" "[${stage}] done"
}
