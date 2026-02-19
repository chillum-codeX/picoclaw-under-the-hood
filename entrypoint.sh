#!/usr/bin/env bash
set -euo pipefail

# Entrypoint: build and run the telegram-only slim PicoClaw, generate local metrics,
# and print instructions for the external live load test.
# This script is reproducible in identical sandbox environments.

# 1) Ensure Go toolchain and GNU time
if ! /usr/local/go/bin/go version >/dev/null 2>&1; then
  echo "Installing Go 1.22.5..."
  cd /tmp
  wget -O go1.22.5.linux-amd64.tar.gz https://dl.google.com/go/go1.22.5.linux-amd64.tar.gz
  rm -rf /usr/local/go && tar -C /usr/local -xzf go1.22.5.linux-amd64.tar.gz
fi
export PATH=/usr/local/go/bin:$PATH
if ! command -v time >/dev/null 2>&1; then
  apt-get update && apt-get install -y time
fi

# 2) Build telegram-only slim binary with profiling hooks
cd /workspace/project/build/picoclaw
/usr/local/go/bin/go mod tidy || true
CGO_ENABLED=0 GOMAXPROCS=1 /usr/local/go/bin/go build \
  -buildvcs=false -tags "telegram pprof smallbuf" -trimpath \
  -ldflags "-s -w -X main.version=v0.1-telegram-slim" \
  -o /workspace/project/picoclaw-telegram ./cmd/picoclaw
ls -lh /workspace/project/picoclaw-telegram || true

# 3) Local simulate run (no network I/O) to capture memory metrics and heap profile
/usr/bin/time -v env GOMEMLIMIT=5MiB GOGC=20 BURST=100 \
  /workspace/project/picoclaw-telegram simulate \
  1>/workspace/project/simulate_out.txt \
  2>/workspace/project/simulate_time.txt || true

# Show key metrics from GNU time
echo "--- simulate_time.txt (key metrics) ---"
grep -E "Maximum resident set size|User time|System time|Elapsed|Exit status" -n /workspace/project/simulate_time.txt || true

# Show internal runtime metrics if available
if [ -f /workspace/project/simulate_metrics.txt ]; then
  echo "--- simulate_metrics.txt ---"
  sed -n "1,40p" /workspace/project/simulate_metrics.txt || true
fi

# Heap profile analysis (if generated)
if [ -f /workspace/project/heap_sim.pb.gz ]; then
  /usr/bin/file /workspace/project/heap_sim.pb.gz || true
  /usr/bin/du -h /workspace/project/heap_sim.pb.gz || true
  /usr/local/go/bin/go tool pprof -top /workspace/project/picoclaw-telegram /workspace/project/heap_sim.pb.gz \
    1>/workspace/project/pprof_top.txt 2>&1 || true
  echo "--- pprof_top.txt (top allocators) ---"
  sed -n "1,120p" /workspace/project/pprof_top.txt || true
else
  echo "No heap profile found (simulate may have skipped heap write)."
fi

# 4) Print external live load test instructions
cat << 'EOF'

Next: External live load test (exec-enabled machine required)
- Prereqs: executable filesystem (no noexec on working dir), GNU time installed, valid Telegram bot token.
- Steps:
  1) Copy binary to your host and make executable:
     cp /workspace/project/picoclaw-telegram ./picoclaw-telegram && chmod +x ./picoclaw-telegram
  2) Ensure minimal config at ~/.picoclaw/config.json or set TELEGRAM_TOKEN env.
  3) Run helper:
     chmod +x /workspace/project/run_live_test.sh
     GOMEMLIMIT=5MiB GOGC=20 BURST=100 PPROF=1 ./run_live_test.sh
  4) When prompted, send ~100 messages to your Telegram bot.
  5) Collect artifacts:
     - live_time.txt (GNU time output)
     - If pprof enabled: curl -s http://127.0.0.1:6060/debug/pprof/heap -o heap.pb.gz
  6) Share artifacts so we can profile and apply targeted optimizations to reach <5MB steady-state RSS.

Optimization roadmap after artifacts:
- Replace metadata map[string]string with a compact struct.
- Introduce sync.Pool for reusable buffers/builders in handlers.
- Build with -tags smallbuf (already enabled) to reduce bus channel capacity.
- Switch heavy JSON paths to streaming / zero-allocation parsers.
- Evaluate a minimal long-poll loop to reduce handler overhead.
EOF

# 5) Done
echo "Entrypoint completed: built slim binary, ran simulate, and printed external test instructions."
