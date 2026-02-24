#!/usr/bin/env bash
# live_gateway_test.sh — Build, start gateway, send 50 messages, capture RSS
set -euo pipefail

# Fix Go PATH (adjust if Go is installed elsewhere)
export PATH="$PATH:/usr/local/go/bin:/usr/local/bin"

TOKEN="${TELEGRAM_TOKEN:-}"
if [ -z "$TOKEN" ]; then
    echo "ERROR: Set TELEGRAM_TOKEN environment variable first."
    echo "  export TELEGRAM_TOKEN='your_bot_token_here'"
    exit 1
fi
PROJECT_DIR="/home/clad_5MB/workspace/project"
BUILD_DIR="$PROJECT_DIR/build/picoclaw"
BINARY="$PROJECT_DIR/picoclaw-telegram"
BURST=50

echo "=============================================="
echo " PicoClaw Live Gateway Test"
echo " Token: ${TOKEN:0:10}...redacted"
echo " Messages: $BURST"
echo "=============================================="
echo ""

# --- Step 1: Write config ---
echo "[1/6] Writing config with real token..."
mkdir -p ~/.picoclaw
cat > ~/.picoclaw/config.json << EOF
{"channels":{"telegram":{"enabled":true,"token":"$TOKEN"}},"gateway":{"host":"127.0.0.1","port":8080}}
EOF
echo "  Config written to ~/.picoclaw/config.json"

# --- Step 2: Build ---
echo "[2/6] Building telegram-slim binary..."
cd "$BUILD_DIR"
which go || { echo "ERROR: go not found. Run: export PATH=\$PATH:/usr/local/go/bin"; exit 1; }
CGO_ENABLED=0 GOMAXPROCS=1 go build \
    -buildvcs=false \
    -tags "telegram pprof smallbuf" \
    -trimpath \
    -ldflags "-s -w" \
    -o "$BINARY" \
    ./cmd/picoclaw
echo "  Binary: $(ls -lh "$BINARY" | awk '{print $5}') at $BINARY"

# --- Step 3: Get chat ID ---
echo "[3/6] Getting bot info and chat ID..."
BOT_INFO=$(curl -s "https://api.telegram.org/bot$TOKEN/getMe")
BOT_USERNAME=$(echo "$BOT_INFO" | grep -o '"username":"[^"]*"' | cut -d'"' -f4)
echo "  Bot: @$BOT_USERNAME"

UPDATES=$(curl -s "https://api.telegram.org/bot$TOKEN/getUpdates?limit=1&offset=-1")
CHAT_ID=$(echo "$UPDATES" | grep -o '"chat":{"id":[0-9-]*' | head -1 | grep -o '[0-9-]*$' || true)

if [ -z "$CHAT_ID" ]; then
    echo ""
    echo "  WARNING: No chat ID found. Please send any message to @$BOT_USERNAME first,"
    echo "  then re-run this script."
    exit 1
fi
echo "  Chat ID: $CHAT_ID"

# --- Step 4: Start gateway ---
echo "[4/6] Starting gateway (background)..."
cd "$PROJECT_DIR"
GOMEMLIMIT=5MiB GOGC=20 GOMAXPROCS=1 \
    /usr/bin/time -v "$BINARY" gateway \
    > gateway_stdout.log 2> gateway_time.log &
GW_PID=$!
echo "  Gateway PID: $GW_PID"

sleep 3

if ! kill -0 $GW_PID 2>/dev/null; then
    echo "  Gateway crashed on startup!"
    cat gateway_time.log
    exit 1
fi
echo "  Gateway is running."

# --- Step 5: Send messages ---
echo "[5/6] Sending $BURST messages via Telegram API..."
for i in $(seq 1 $BURST); do
    MSG="Test+message+${i}+of+${BURST}+PicoClaw+benchmark"
    curl -s -X POST \
        "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d "chat_id=$CHAT_ID" \
        -d "text=$MSG" \
        > /dev/null 2>&1 || true

    if (( i % 10 == 0 )); then
        echo "  Sent $i/$BURST..."
        sleep 1
    fi
done
echo "  All $BURST messages sent."

echo "  Waiting 10s for processing + GC..."
sleep 10

# Capture live RSS
if [ -f /proc/$GW_PID/status ]; then
    RSS_LIVE=$(grep VmRSS /proc/$GW_PID/status | awk '{print $2}')
    RSS_MB=$(echo "scale=2; $RSS_LIVE/1024" | bc)
    echo ""
    echo "  LIVE RSS (mid-run): $RSS_LIVE KB ($RSS_MB MB)"
fi

# --- Step 6: Stop and report ---
echo "[6/6] Stopping gateway..."
kill -INT $GW_PID 2>/dev/null || true
wait $GW_PID 2>/dev/null || true

echo ""
echo "=============================================="
echo " RESULTS"
echo "=============================================="
echo ""

if [ -f gateway_time.log ]; then
    MAX_RSS=$(grep "Maximum resident" gateway_time.log | awk '{print $NF}')
    echo "Maximum RSS:       $MAX_RSS KB ($(echo "scale=2; $MAX_RSS/1024" | bc) MB)"
    echo ""

    if [ "$MAX_RSS" -le 5120 ] 2>/dev/null; then
        echo "PASS: Peak RSS ${MAX_RSS} KB is UNDER 5 MB target (5120 KB)"
        echo "Headroom: $((5120 - MAX_RSS)) KB ($(echo "scale=2; (5120-$MAX_RSS)/1024" | bc) MB)"
    else
        echo "OVER: Peak RSS ${MAX_RSS} KB EXCEEDS 5 MB target by $((MAX_RSS - 5120)) KB"
    fi
    echo ""
    echo "Full timing output:"
    cat gateway_time.log
fi

echo ""
echo "Gateway log (last 20 lines):"
tail -20 gateway_stdout.log 2>/dev/null || echo "(empty)"
echo ""
echo "REMINDER: Revoke your bot token via @BotFather after testing!"
