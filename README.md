PicoClaw Telegram-Slim Build: Live Test and Optimization Guide

Overview
- This project provides a telegram-only, ultra-slim build of PicoClaw using Go build tags and aggressive linker flags, targeting a steady-state RSS under 5MB on low-cost hardware.
- The sandbox filesystem mounts block binary execution (noexec), so run the live test externally (container/VM/host with exec-enabled filesystems).

Build (inside sandbox or your host)
- Ensure Go >= 1.22 is installed and PATH includes /usr/local/go/bin
- Build telegram-only with pprof:
  CGO_ENABLED=0 GOMAXPROCS=1 go build -buildvcs=false -tags "telegram pprof" -trimpath \
    -ldflags "-s -w -X main.version=v0.1-telegram-slim" -o ./picoclaw-telegram ./cmd/picoclaw

Commands
- status:   ./picoclaw-telegram status
- version:  ./picoclaw-telegram version
- gateway:  ./picoclaw-telegram gateway
- simulate: ./picoclaw-telegram simulate

Simulate (no network I/O)
- The simulate command publishes a burst of synthetic messages with SIMULATE=1, reports internal memory metrics (RSS via /proc/self/status, heap stats), and writes a heap profile to /workspace/project/heap_sim.pb.gz (when run in an exec-enabled environment).
- Example:
  GOMEMLIMIT=5MiB GOGC=20 BURST=100 ./picoclaw-telegram simulate

Live Load Test (exec-enabled environment required)
- Use the helper script:
  ./run_live_test.sh
- It will:
  1) Ensure minimal config at ~/.picoclaw/config.json
  2) Start the gateway with memory limits (GOMEMLIMIT=5MiB, GOGC=20)
  3) Prompt you to send ~BURST messages to the Telegram bot
  4) Capture RSS via GNU time and optional pprof heap sampling
- Environment:
  TELEGRAM_TOKEN=your_bot_token
  OPENAI_API_KEY=optional (for agents)
  GOMEMLIMIT=5MiB GOGC=20 BURST=100

Memory Optimization Tips
- Runtime limits: export GOMEMLIMIT=5MiB, GOGC=20, GOMAXPROCS=1
- Reduce channel buffer capacity: build with -tags smallbuf (sets bus channelCap=16)
  CGO_ENABLED=0 go build -tags "telegram pprof smallbuf" ...
- JSON and buffers: prefer streaming decoding and reuse byte buffers with sync.Pool
- Minimize allocations in telegram handlers (replace map[string]string with a small struct)
- Consider a minimal Telegram client or stripped-down telego usage to reduce handler overhead
- Explore TinyGo for CLI-only components if compatible

Roadmap (tracked in TODO)
- ENV-FIX: Run live test in an exec-enabled environment using run_live_test.sh
- OPT-METADATA: Replace metadata map with a compact struct
- OPT-POOL: Introduce sync.Pool for buffers/builders
- OPT-TELEGO-MIN: Minimal long-polling loop without heavy handler allocations
- OPT-BUILD-SMALLBUF: Measure impact of reduced bus buffers
- OPT-RUNTIME: Standardize GOMEMLIMIT/GOGC/GOMAXPROCS in service scripts

Artifacts
- Binary (built in sandbox): /workspace/project/picoclaw-telegram
- Scripts: /workspace/project/entrypoint.sh, /workspace/project/run_live_test.sh
- Progress: /workspace/project/progress.md
