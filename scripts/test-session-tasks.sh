#!/bin/bash
# Test session + task flow without Claude Code.
# Usage: ./scripts/test-session-tasks.sh [surface_id]
#
# Requires Moss.app running. Auto-discovers socket and surface ID.

set -euo pipefail

# --- Find socket (match running Moss PID) ---
if [[ -n "${MOSS_SOCKET_PATH:-}" ]]; then
  SOCK="$MOSS_SOCKET_PATH"
else
  TMPDIR_REAL=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "/tmp/")
  MOSS_PID=$(pgrep -x Moss 2>/dev/null | head -1)
  if [[ -z "$MOSS_PID" ]]; then
    echo "ERROR: Moss is not running."
    exit 1
  fi
  SOCK="${TMPDIR_REAL}moss-${MOSS_PID}.sock"
fi
if [[ ! -S "$SOCK" ]]; then
  echo "ERROR: Socket not found at $SOCK"
  exit 1
fi
echo "Socket: $SOCK"

# --- Find surface_id ---
if [[ -n "${1:-}" ]]; then
  SURFACE="$1"
elif [[ -n "${MOSS_SURFACE_ID:-}" ]]; then
  SURFACE="$MOSS_SURFACE_ID"
else
  CANVAS="$HOME/Library/Application Support/Moss/canvas-state.json"
  if [[ ! -f "$CANVAS" ]]; then
    echo "ERROR: Canvas state not found at $CANVAS"
    exit 1
  fi
  SURFACE=$(/usr/bin/python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['items'][0]['id'])" "$CANVAS")
  if [[ -z "$SURFACE" ]]; then
    echo "ERROR: No sessions found in canvas state."
    exit 1
  fi
fi
echo "Surface: $SURFACE"
echo ""

# --- Helper: send IPC via python3 unix socket ---
send() {
  local cmd="$1"
  local val="$2"
  /usr/bin/python3 - "$SOCK" "$SURFACE" "$cmd" "$val" <<'PYEOF'
import socket, sys, json
sock_path, surface_id, command, val = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
value = None if val == "null" else val
payload = json.dumps({"surface_id": surface_id, "command": command, "value": value}) + "\n"
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
s.sendall(payload.encode())
s.settimeout(5)
data = b""
while b"\n" not in data:
    chunk = s.recv(4096)
    if not chunk: break
    data += chunk
s.close()
print(data.decode().strip())
PYEOF
}

# === Test Sequence ===

SESSION_ID="test-session-$(date +%s)"

echo "=== 1. Start Claude session (session_id=$SESSION_ID) ==="
send "session_start" "$SESSION_ID"
sleep 0.5

echo ""
echo "=== 2. Create 3 tasks ==="
send "task_created" "{\"id\":\"t1\",\"subject\":\"Refactor auth module\",\"session_id\":\"$SESSION_ID\"}"
sleep 0.3
send "task_created" "{\"id\":\"t2\",\"subject\":\"Add unit tests\",\"session_id\":\"$SESSION_ID\"}"
sleep 0.3
send "task_created" "{\"id\":\"t3\",\"subject\":\"Update docs\",\"session_id\":\"$SESSION_ID\"}"
sleep 1

echo ""
echo "=== 3. Complete tasks one by one ==="
send "task_completed" "{\"id\":\"t1\",\"session_id\":\"$SESSION_ID\"}"
sleep 1
send "task_completed" "{\"id\":\"t2\",\"session_id\":\"$SESSION_ID\"}"
sleep 1

echo ""
echo "=== 4. Stale task from wrong session (should be rejected) ==="
send "task_created" "{\"id\":\"stale\",\"subject\":\"Ghost task\",\"session_id\":\"old-session-999\"}"
sleep 0.5

echo ""
echo "=== 5. Complete last task (all done → tasks clear) ==="
send "task_completed" "{\"id\":\"t3\",\"session_id\":\"$SESSION_ID\"}"
sleep 1

echo ""
echo "=== 6. New session (tasks should reset) ==="
NEW_SESSION="test-session-$(date +%s)-v2"
send "session_start" "$NEW_SESSION"
sleep 0.5
send "task_created" "{\"id\":\"t4\",\"subject\":\"Fresh task in new session\",\"session_id\":\"$NEW_SESSION\"}"
sleep 1

echo ""
echo "=== 7. Reset tasks ==="
send "task_reset" "null"
sleep 0.5

echo ""
echo "Done. Check the Moss UI to verify task indicators appeared and cleared correctly."
