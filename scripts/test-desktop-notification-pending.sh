#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
WATCH_LOG="/tmp/moss-desktop-notification-test.log"

TITLE="Moss Test"
BODY="Desktop notification should switch this terminal to pending."
POST_SECONDS=2
DEBUG=1

usage() {
  cat <<'EOF'
Usage: test-desktop-notification-pending.sh [options]

Trigger Ghostty's desktop-notification path with OSC 777 and verify that Moss
switches the current terminal to pending.

Options:
  -t, --title <text>       Notification title
  -b, --body <text>        Notification body
  -p, --post <seconds>     Seconds to keep polling after emitting OSC 777 (default: 2)
      --debug              Print extra diagnostics (default: on)
      --no-debug           Print only essential logs
  -h, --help               Show this help

Examples:
  ./scripts/test-desktop-notification-pending.sh
  ./scripts/test-desktop-notification-pending.sh --title "Claude Code" --body "Needs your attention"
EOF
}

note() {
  printf '[moss-desktop-notify-test] %s\n' "$*"
}

debug() {
  if (( DEBUG )); then
    printf '[moss-desktop-notify-test][debug] %s\n' "$*" >&2
  fi
}

fail() {
  printf '[moss-desktop-notify-test] %s\n' "$*" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    -t|--title)
      [[ $# -ge 2 ]] || fail "Missing value for $1"
      TITLE="$2"
      shift 2
      ;;
    -b|--body)
      [[ $# -ge 2 ]] || fail "Missing value for $1"
      BODY="$2"
      shift 2
      ;;
    -p|--post)
      [[ $# -ge 2 ]] || fail "Missing value for $1"
      POST_SECONDS="$2"
      shift 2
      ;;
    --debug)
      DEBUG=1
      shift
      ;;
    --no-debug)
      DEBUG=0
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

[[ -n "${MOSS_SOCKET_PATH:-}" ]] || fail "MOSS_SOCKET_PATH is not set. Run this inside a Moss terminal."
[[ -n "${MOSS_SURFACE_ID:-}" ]] || fail "MOSS_SURFACE_ID is not set. Run this inside a Moss terminal."

declare -a MOSS_BIN

if [[ -n "${MOSS_CLI_PATH:-}" && -x "${MOSS_CLI_PATH}" ]]; then
  MOSS_BIN=("${MOSS_CLI_PATH}")
elif [[ -x "${REPO_ROOT}/.build/debug/moss" ]]; then
  MOSS_BIN=("${REPO_ROOT}/.build/debug/moss")
elif command -v moss >/dev/null 2>&1; then
  MOSS_BIN=("$(command -v moss)")
else
  fail "Could not find the moss CLI. Build it with: swift build --target MossCLI"
fi

if ! [[ "${POST_SECONDS}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  fail "Post wait must be a positive number, got: ${POST_SECONDS}"
fi

run_moss_status() {
  local output
  local rc

  if output="$("${MOSS_BIN[@]}" status "$@" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi

  debug "moss status $* -> exit=${rc} output=${output:-<empty>}"

  if [[ -n "${output}" ]]; then
    printf '%s\n' "${output}"
  fi
  return "${rc}"
}

note "Using CLI: ${MOSS_BIN[*]}"
note "Notification title: ${TITLE}"
note "Notification body: ${BODY}"
debug "Repository root: ${REPO_ROOT}"
debug "PWD: $(pwd)"
debug "MOSS_SOCKET_PATH=${MOSS_SOCKET_PATH}"
debug "MOSS_SURFACE_ID=${MOSS_SURFACE_ID}"

printf '' > "${WATCH_LOG}"

STOP_FILE="$(mktemp "${TMPDIR:-/tmp}/moss-desktop-notify-stop.XXXXXX")"
rm -f "${STOP_FILE}"

watch_statuses() {
  local last=""
  local current=""
  while [[ ! -f "${STOP_FILE}" ]]; do
    current="$(run_moss_status get 2>/dev/null || true)"
    current="${current:-<empty>}"
    if [[ "${current}" != "${last}" ]]; then
      printf '[%s] status=%s\n' "$(date +%H:%M:%S)" "${current}" >> "${WATCH_LOG}"
      last="${current}"
    fi
    sleep 0.2
  done
}

WATCH_PID=""
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ -n "${WATCH_PID}" ]]; then
    : > "${STOP_FILE}"
    wait "${WATCH_PID}" 2>/dev/null || true
  fi
  rm -f "${STOP_FILE}"
  exit "${rc}"
}
trap cleanup EXIT INT TERM

watch_statuses &
WATCH_PID=$!

initial_status="$(run_moss_status get 2>/dev/null || true)"
initial_status="${initial_status:-<empty>}"
note "Initial status: ${initial_status}"

printf '\033]777;notify;%s;%s\a' "${TITLE}" "${BODY}"
note "OSC 777 desktop notification emitted. Waiting ${POST_SECONDS}s."
sleep "${POST_SECONDS}"

final_status="$(run_moss_status get 2>/dev/null || true)"
final_status="${final_status:-<empty>}"
note "Final status: ${final_status}"

note "Status transitions recorded in ${WATCH_LOG}:"
sed 's/^/[moss-desktop-notify-test][watch] /' "${WATCH_LOG}"

if [[ "${final_status}" == "pending" ]]; then
  note "Result: pending observed as expected."
  exit 0
fi

fail "Expected final status pending after desktop notification, got: ${final_status}"
