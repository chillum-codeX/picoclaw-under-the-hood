# Linux Execution Guide: PicoClaw 5 MB Memory Proof

> Step-by-step commands to build, benchmark, and validate the 5 MB RSS target on Linux.

---

## Prerequisites

```bash
# Install Go (if not present)
wget -qO- https://dl.google.com/go/go1.26.0.linux-amd64.tar.gz | sudo tar -C /usr/local -xzf -
export PATH=$PATH:/usr/local/go/bin
go version

# Install GNU time (for RSS measurement)
sudo apt-get install -y time
```

---

## 1. Clone & Build

```bash
cd /path/to/clad_5MB/workspace/project/build/picoclaw

# Download dependencies
go mod tidy

# Build telegram-slim binary (stripped, static, telegram-only)
CGO_ENABLED=0 GOMAXPROCS=1 go build \
    -buildvcs=false \
    -tags "telegram pprof smallbuf" \
    -trimpath \
    -ldflags "-s -w -X main.version=v0.1-telegram-slim" \
    -o ../../picoclaw-telegram \
    ./cmd/picoclaw

# Build memory benchmark binary
CGO_ENABLED=0 go build \
    -buildvcs=false \
    -tags "smallbuf" \
    -trimpath \
    -ldflags "-s -w" \
    -o ../../membench \
    ./cmd/membench

# Verify binaries
ls -lh ../../picoclaw-telegram ../../membench
file ../../picoclaw-telegram
```

**Expected output:**
```
-rwxr-xr-x 1 user user 8.9M ...  picoclaw-telegram
-rwxr-xr-x 1 user user 2.7M ...  membench
picoclaw-telegram: ELF 64-bit LSB executable, x86-64, statically linked, stripped
```

---

## 2. Create Config

```bash
mkdir -p ~/.picoclaw

cat > ~/.picoclaw/config.json << 'EOF'
{
  "channels": {
    "telegram": {
      "enabled": true,
      "token": "123456789:ABCdefGHIjklmnOPQRstUVWxyz0123456"
    }
  },
  "gateway": {
    "host": "127.0.0.1",
    "port": 8080
  }
}
EOF
```

---

## 3. Quick Status Check (RSS Baseline)

```bash
cd /path/to/clad_5MB/workspace/project

# Measure status command RSS via GNU time
/usr/bin/time -v ./picoclaw-telegram status 2>&1 | grep -E "Maximum resident|Elapsed"
```

**Expected output (~1.8 MB):**
```
Maximum resident set size (kbytes): 1860
Elapsed (wall clock) time: 0:00.21
```

---

## 4. Run Memory Benchmark

### 4.1 With GOMEMLIMIT (aggressive GC)

```bash
cd /path/to/clad_5MB/workspace/project

GOMEMLIMIT=5MiB GOGC=20 BURST=100 ./membench 2>&1 | tee bench_results_linux.txt
```

### 4.2 Without GOMEMLIMIT (default)

```bash
BURST=100 ./membench 2>&1 | tee bench_results_linux_default.txt
```

### 4.3 Higher burst (stress test)

```bash
GOMEMLIMIT=5MiB GOGC=20 BURST=500 ./membench 2>&1 | tee bench_results_linux_500.txt
```

**Key lines to look for:**
```
[mem 1-baseline          ] RSS= XXXX KB (X.XX MB)   ← Should be ~1.5-2.5 MB
[mem 4-after-burst       ] RSS= XXXX KB (X.XX MB)   ← Should be ~2.5-3.5 MB
[mem 5-steady-state      ] RSS= XXXX KB (X.XX MB)   ← Should be ~2.5-3.0 MB

✅ PASS: RSS XXXX KB (X.XX MB) is UNDER 5 MB target (5120 KB)
```

---

## 5. Simulate Mode (Full Telegram Channel, No Network)

```bash
cd /path/to/clad_5MB/workspace/project

# Run simulate (requires valid-format token in config)
GOMEMLIMIT=5MiB GOGC=20 BURST=100 SIMULATE=1 \
    /usr/bin/time -v ./picoclaw-telegram simulate \
    2>&1 | tee simulate_results_linux.txt

# Extract key metrics
grep -E "Maximum resident set size|RSS=|HeapAlloc|Simulation complete" simulate_results_linux.txt
```

---

## 6. Live Gateway Test (Requires Real Telegram Token)

```bash
# Set your real bot token
export TELEGRAM_TOKEN="your_real_bot_token_here"

# Update config with real token
cat > ~/.picoclaw/config.json << EOF
{
  "channels": {
    "telegram": {
      "enabled": true,
      "token": "$TELEGRAM_TOKEN"
    }
  },
  "gateway": {
    "host": "127.0.0.1",
    "port": 8080
  }
}
EOF

# Start gateway with memory limits, measure RSS
GOMEMLIMIT=5MiB GOGC=20 GOMAXPROCS=1 \
    /usr/bin/time -v ./picoclaw-telegram gateway \
    2> live_time.txt &
GATEWAY_PID=$!

echo "Gateway started (PID: $GATEWAY_PID)"
echo "Send ~100 messages to your Telegram bot now."
echo "When done, press Enter to stop the gateway."
read -r

# Stop gateway
kill -INT $GATEWAY_PID
wait $GATEWAY_PID 2>/dev/null

# Show results
echo "=== LIVE TEST RESULTS ==="
grep -E "Maximum resident|Elapsed|Exit" live_time.txt
```

---

## 7. Heap Profile Analysis

```bash
# If pprof is enabled (built with -tags pprof), capture heap during gateway run:
PPROF=1 PPROF_PORT=6060 GOMEMLIMIT=5MiB GOGC=20 \
    ./picoclaw-telegram gateway &

# Wait for gateway to stabilize, then send messages, then capture:
curl -s http://127.0.0.1:6060/debug/pprof/heap -o heap_live.pb.gz

# Analyze top allocators
go tool pprof -top ./picoclaw-telegram heap_live.pb.gz

# Interactive analysis
go tool pprof -http=:8888 ./picoclaw-telegram heap_live.pb.gz
```

---

## 8. Helper Script (All-in-One)

```bash
#!/usr/bin/env bash
# run_all_benchmarks.sh — Run all PicoClaw memory benchmarks
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

echo "========================================="
echo " PicoClaw 5 MB Feasibility — Linux Tests"
echo "========================================="
echo ""

# --- Binary info ---
echo "=== BINARY INFO ==="
ls -lh picoclaw-telegram membench 2>/dev/null || echo "Binaries not found — run build first"
echo ""

# --- Status RSS ---
echo "=== STATUS COMMAND RSS ==="
/usr/bin/time -v ./picoclaw-telegram status 2>&1 | grep -E "Maximum resident|picoclaw"
echo ""

# --- Membench: GOMEMLIMIT ---
echo "=== MEMBENCH: GOMEMLIMIT=5MiB GOGC=20 BURST=100 ==="
GOMEMLIMIT=5MiB GOGC=20 BURST=100 ./membench 2>&1
echo ""

# --- Membench: Default ---
echo "=== MEMBENCH: Default GC, BURST=100 ==="
BURST=100 ./membench 2>&1
echo ""

# --- Membench: High burst ---
echo "=== MEMBENCH: GOMEMLIMIT=5MiB GOGC=20 BURST=500 ==="
GOMEMLIMIT=5MiB GOGC=20 BURST=500 ./membench 2>&1
echo ""

# --- Simulate (if token works) ---
echo "=== SIMULATE: 100-msg burst ==="
GOMEMLIMIT=5MiB GOGC=20 BURST=100 SIMULATE=1 \
    /usr/bin/time -v ./picoclaw-telegram simulate 2>&1 \
    | grep -E "Maximum resident|RSS=|Simulation complete" || echo "(Simulate skipped — token validation)"
echo ""

echo "All benchmarks complete."
```

Make it executable:
```bash
chmod +x run_all_benchmarks.sh
./run_all_benchmarks.sh 2>&1 | tee full_benchmark_report.txt
```

---

## 9. Expected Results Summary

| Test | Expected RSS (Linux) | 5 MB Target |
|------|---------------------|-------------|
| `status` command | ~1.8 MB | ✅ Well under |
| `membench` baseline | ~1.5–2.5 MB | ✅ Under |
| `membench` after 100-msg burst | ~2.5–3.5 MB | ✅ Under |
| `membench` steady state | ~2.5–3.0 MB | ✅ Under |
| `simulate` (100 msgs) | ~2.5–4.0 MB | ✅ Under |
| `gateway` idle | ~3.0–4.0 MB | ✅ Under |
| `gateway` under load (100 msgs) | ~3.5–4.5 MB | ✅ Under |

---

## 10. Troubleshooting

| Problem | Solution |
|---------|----------|
| `permission denied` running binary | `chmod +x ./picoclaw-telegram ./membench` |
| `invalid token format` | Token must be `<digits>:<35-char-alphanumeric>` format |
| `/usr/bin/time: not found` | `sudo apt install time` (it's the GNU time, not bash builtin) |
| Config not found | Ensure `~/.picoclaw/config.json` exists and is valid JSON (no BOM) |
| `go: command not found` | `export PATH=$PATH:/usr/local/go/bin` or install Go |
| RSS higher than expected | Check for other processes; ensure `GOMEMLIMIT` and `GOGC` are set |
| pprof endpoint not responding | Ensure built with `-tags pprof` and `PPROF=1` is set |
