#!/usr/bin/env bash
set -euo pipefail

# Live load test runner for telegram-only slim PicoClaw build
# Prereqs (on the host/container you run this in):
# - Executable filesystem (no noexec on /tmp or working dir)
# - /usr/bin/time (GNU time) installed for RSS capture
# - Valid Telegram bot token in env TELEGRAM_TOKEN or in ~/.picoclaw/config.json
# - Binary built by entrypoint or available at $BIN (default: ./picoclaw-telegram)

BIN=${BIN:-"./picoclaw-telegram"}
BURST=${BURST:-"100"}
GOMEMLIMIT=${GOMEMLIMIT:-"5MiB"}
GOGC=${GOGC:-"20"}
PPROF=${PPROF:-""}
PPROF_PORT=${PPROF_PORT:-"6060"}

if [ ! -x "$BIN" ]; then
  echo "Binary not found or not executable: $BIN" >&2
  exit 1
fi

# Ensure config has Telegram enabled; if not, create a minimal config
CFG="$HOME/.picoclaw/config.json"
if [ ! -f "$CFG" ]; then
  mkdir -p "$(dirname "$CFG")"
  cat > "$CFG" <<EOF
{
  "agents": {"defaults": {"workspace": "$HOME/.picoclaw/workspace", "provider": "openai", "model": "gpt-4o-mini"}},
  "channels": {"telegram": {"enabled": true, "token": "${TELEGRAM_TOKEN:-}"}},
  "providers": {"openai": {"api_key": "${OPENAI_API_KEY:-}"}},
  "gateway": {"host": "127.0.0.1", "port": 18080},
  "heartbeat": {"enabled": false},
  "tools": {"browser": {"enabled": false}}
}
EOF
  echo "Wrote minimal config to $CFG"
fi

if ! grep -q '"enabled"\s*:\s*true' "$CFG"; then
  echo "Ensure Channels.Telegram.Enabled is true in $CFG" >&2
fi

# Launch gateway with tight memory limits; capture RSS
set +e
CMD_ENV=(GOMEMLIMIT="$GOMEMLIMIT" GOGC="$GOGC")
if [ -n "$PPROF" ]; then
  CMD_ENV+=(PPROF="1" PPROF_PORT="$PPROF_PORT")
fi

# Start gateway in background to warm up
"${CMD_ENV[@]}" "$BIN" gateway &
PID=$!
echo "Gateway PID: $PID"
# Allow warmup
sleep 3

# Capture baseline RSS from /proc
if [ -r "/proc/$PID/status" ]; then
  RSS=$(awk '/VmRSS:/ {print $2}' "/proc/$PID/status")
  echo "Baseline VmRSS(kB): $RSS"
fi

# Drive a quick load by sending BURST messages (manual step)
echo "Now send ~$BURST messages to your Telegram bot to simulate load. Press Enter when done."
read -r _ || true

# Measure with GNU time by launching a short-lived run (optional)
/usr/bin/time -v "${CMD_ENV[@]}" "$BIN" gateway </dev/null 1>/dev/null 2> live_time.txt &
T_PID=$!
sleep 5 || true
kill $T_PID >/dev/null 2>&1 || true

# Report results
if [ -f live_time.txt ]; then
  echo "--- GNU time (key metrics) ---"
  grep -E "Maximum resident set size|User time|System time|Elapsed|Exit status" -n live_time.txt || true
fi

# Collect pprof if enabled
if [ -n "$PPROF" ]; then
  echo "pprof heap endpoint: http://127.0.0.1:$PPROF_PORT/debug/pprof/heap"
  echo "You can curl and analyze: curl -s http://127.0.0.1:$PPROF_PORT/debug/pprof/heap -o heap.pb.gz"
fi

# Stop gateway
kill $PID >/dev/null 2>&1 || true
wait $PID 2>/dev/null || true

echo "Live load test completed. Inspect live_time.txt and any pprof captures."
