#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

HOLD_SECONDS=3
CYCLES=1
INTERACTIVE=0
RESTORE=1
DEBUG=1

usage() {
  cat <<'EOF'
Usage: test-status-border.sh [options]

Cycle through Moss terminal border states to verify the status border UI.

Options:
  -d, --delay <seconds>   Seconds to wait after each status change (default: 3)
  -c, --cycles <count>    Number of pending -> none cycles (default: 1)
  -i, --interactive       Wait for Enter after each step instead of sleeping
      --debug             Print extra diagnostics (default: on)
      --no-debug          Print only essential progress logs
      --no-restore        Leave the terminal in its final status
  -h, --help              Show this help

Examples:
  ./scripts/test-status-border.sh
  ./scripts/test-status-border.sh --delay 1.5 --cycles 2
  ./scripts/test-status-border.sh --interactive
EOF
}

note() {
  printf '[moss-border-test] %s\n' "$*"
}

debug() {
  if (( DEBUG )); then
    printf '[moss-border-test][debug] %s\n' "$*" >&2
  fi
}

fail() {
  printf '[moss-border-test] %s\n' "$*" >&2
  exit 1
}

validate_args() {
  if ! [[ "${HOLD_SECONDS}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    fail "Delay must be a non-negative number, got: ${HOLD_SECONDS}"
  fi

  if ! [[ "${CYCLES}" =~ ^[1-9][0-9]*$ ]]; then
    fail "Cycles must be a positive integer, got: ${CYCLES}"
  fi
}

while (($# > 0)); do
  case "$1" in
    -d|--delay)
      [[ $# -ge 2 ]] || fail "Missing value for $1"
      HOLD_SECONDS="$2"
      shift 2
      ;;
    -c|--cycles)
      [[ $# -ge 2 ]] || fail "Missing value for $1"
      CYCLES="$2"
      shift 2
      ;;
    -i|--interactive)
      INTERACTIVE=1
      shift
      ;;
    --debug)
      DEBUG=1
      shift
      ;;
    --no-debug)
      DEBUG=0
      shift
      ;;
    --no-restore)
      RESTORE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

validate_args

[[ -n "${MOSS_SOCKET_PATH:-}" ]] || fail "MOSS_SOCKET_PATH is not set. Run this inside a Moss terminal."
[[ -n "${MOSS_SURFACE_ID:-}" ]] || fail "MOSS_SURFACE_ID is not set. Run this inside a Moss terminal."

declare -a MOSS_BIN

if [[ -n "${MOSS_CLI:-}" ]]; then
  MOSS_BIN=("${MOSS_CLI}")
elif [[ -x "${REPO_ROOT}/.build/debug/moss" ]]; then
  MOSS_BIN=("${REPO_ROOT}/.build/debug/moss")
elif command -v moss >/dev/null 2>&1; then
  MOSS_BIN=("$(command -v moss)")
else
  fail "Could not find the moss CLI. Build it with: swift build --target MossCLI"
fi

run_moss_status() {
  local output
  local rc

  debug "Running: ${MOSS_BIN[*]} status $*"

  if output="$("${MOSS_BIN[@]}" status "$@" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi

  debug "Exit code: ${rc}"
  if [[ -n "${output}" ]]; then
    while IFS= read -r line; do
      debug "CLI output: ${line}"
    done <<< "${output}"
  fi

  if [[ -n "${output}" ]]; then
    printf '%s\n' "${output}"
  fi
  return "${rc}"
}

moss_status() {
  run_moss_status "$@"
}

describe_status() {
  case "$1" in
    pending)
      printf '%s' 'static orange border'
      ;;
    none)
      printf '%s' 'no special border'
      ;;
    *)
      printf '%s' 'unknown'
      ;;
  esac
}

wait_between_steps() {
  if (( INTERACTIVE )); then
    read -r -p "[moss-border-test] Press Enter to continue..." _
  else
    sleep "${HOLD_SECONDS}"
  fi
}

ORIGINAL_STATUS="$(moss_status get 2>/dev/null || true)"
case "${ORIGINAL_STATUS}" in
  pending|none)
    ;;
  *)
    ORIGINAL_STATUS="none"
    ;;
esac

LAST_STATUS="${ORIGINAL_STATUS}"

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM

  if (( RESTORE )) && [[ -n "${MOSS_SOCKET_PATH:-}" ]] && [[ -n "${MOSS_SURFACE_ID:-}" ]]; then
    if [[ "${LAST_STATUS}" != "${ORIGINAL_STATUS}" ]]; then
      note "Restoring original status: ${ORIGINAL_STATUS}"
      run_moss_status set "${ORIGINAL_STATUS}" >/dev/null 2>&1 || true
    fi
  fi

  exit "${exit_code}"
}

trap cleanup EXIT INT TERM

set_status_and_wait() {
  local status="$1"
  local current_status
  note "Setting status to '${status}' ($(describe_status "${status}"))"
  moss_status set "${status}"
  LAST_STATUS="${status}"
  current_status="$(moss_status get 2>/dev/null || true)"
  note "CLI reports current status: ${current_status:-<empty>}"
  wait_between_steps
}

note "Using CLI: ${MOSS_BIN[*]}"
note "Original status: ${ORIGINAL_STATUS}"
debug "Repository root: ${REPO_ROOT}"
debug "PWD: $(pwd)"
debug "MOSS_SOCKET_PATH=${MOSS_SOCKET_PATH}"
debug "MOSS_SURFACE_ID=${MOSS_SURFACE_ID}"
if [[ -S "${MOSS_SOCKET_PATH}" ]]; then
  debug "Socket exists and is a Unix socket."
else
  debug "Socket path is missing or is not a Unix socket."
fi

if (( INTERACTIVE )); then
  note "Interactive mode enabled. Press Enter after each border change."
else
  note "Auto mode enabled. Waiting ${HOLD_SECONDS}s after each border change."
fi

for ((cycle = 1; cycle <= CYCLES; cycle++)); do
  note "Cycle ${cycle}/${CYCLES}"
  set_status_and_wait pending
  set_status_and_wait none
done

note "Border status test finished."
