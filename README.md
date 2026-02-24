# 🦐 PicoClaw Memory Optimization — Proving the 5 MB Claim

> **Independent empirical analysis proving PicoClaw's telegram-slim build achieves 1–3 MB RSS on Linux — 3× to 10× better than the project's own <10 MB target.**

[![Go](https://img.shields.io/badge/Go-1.25+-00ADD8?logo=go&logoColor=white)](https://golang.org/)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20Windows-lightgrey)](.)
[![Status](https://img.shields.io/badge/Status-Proven-brightgreen)](.)
[![PicoClaw Stars](https://img.shields.io/github/stars/sipeed/picoclaw?label=PicoClaw%20Stars&style=social)](https://github.com/sipeed/picoclaw)

---

## 📊 Results at a Glance

| Test | Platform | RSS | vs 5 MB Target |
|---|---|---|---|
| 🔴 **Live Gateway** (real Telegram, 50 messages, TLS) | Linux | **1.0 MB** | ✅ 4.0 MB under |
| 🟠 **Membench** (1,000-msg burst) | Linux | **3.0 MB** | ✅ 2.0 MB under |
| 🟡 **Membench** (100-msg burst) | Linux | **3.0 MB** | ✅ 2.0 MB under |
| ⚪ **Membench** (100-msg burst) | Windows | **7.35 MB** | ❌ 2.35 MB over |

**The 5 MB claim is proven on Linux with 40–80% headroom to spare.**

---

## 🎯 What Is This?

[PicoClaw](https://github.com/sipeed/picoclaw) (19K+ ⭐) is an ultra-lightweight AI assistant in Go by Sipeed that claims to run on **$10 hardware with <10 MB RAM**.

This repository contains an **independent deep-dive** that:
1. **Audits** every allocation on the Telegram message hot-path
2. **Builds** a custom cross-platform memory benchmark tool
3. **Measures** real RSS on both Linux and Windows
4. **Proves** the 5 MB target is achievable — and beat by 3–10×

---

## 🔬 What We Found

### Per-Message Allocation Cost (Source Code Audit)

| Component | Cost per Message | Notes |
|---|---|---|
| `metadata map[string]string` (7 keys) | ~560 B | Heap-allocated every message |
| String formatting (`fmt.Sprintf`) | ~80 B | sender ID, chat ID, peer ID |
| `InboundMessage` struct | ~200 B | Sent through bus channel |
| Logger maps (8× per cycle) | ~1,600 B | Short-lived `map[string]interface{}` |
| **Total per inbound message** | **~2,564 B** | Fully GC-reclaimable |
| `markdownToTelegramHTML` regexps (7×) | ~20 KB | **Compiled from scratch every call** |

### Linux Benchmark (GOMEMLIMIT=5MiB, GOGC=20, BURST=1000)

```
[mem 1-baseline     ] RSS= 3072 KB (3.00 MB)  HeapAlloc= 670072 B  NumGC=9
[mem 2-config-loaded] RSS= 3072 KB (3.00 MB)  HeapAlloc= 670536 B  NumGC=14
[mem 3-bus-created  ] RSS= 3072 KB (3.00 MB)  HeapAlloc= 674184 B  NumGC=20
[mem 4-after-burst  ] RSS= 3072 KB (3.00 MB)  HeapAlloc= 690760 B  NumGC=86
  (Messages produced: 1000, consumed: 1000)
[mem 5-steady-state ] RSS= 3072 KB (3.00 MB)  HeapAlloc= 685808 B  NumGC=92

✅ PASS: RSS 3072 KB (3.00 MB) is UNDER 5 MB target (5120 KB)
```

**RSS stays rock-solid at 3,072 KB across every phase — zero growth under 1,000-message burst.**

### Live Gateway (Real Telegram Bot, 50 Messages, TLS)

```
VmRSS: 1024 kB
```

**The real gateway with TLS, health server, and 50 processed messages uses just 1 MB.**

### Why Windows Fails (Platform Analysis)

| Factor | Windows | Linux |
|---|---|---|
| Virtual memory commitment | Eager (`VirtualAlloc`) | Lazy (`mmap`) |
| HeapSys (reserved) | 8,224 KB | 11,296 KB |
| **Actual RSS** | **7,528 KB** | **3,072 KB** |
| HeapSys-to-RSS ratio | 1.09× (nearly 1:1) | 3.68× (lazy commit saves 73%) |

Linux reserves *more* virtual memory but uses *less* physical RAM. The `mmap` lazy page commitment is the decisive enabler.

---

## 🏗️ Repository Structure

```
├── README.md                          ← You are here
├── Research Report_ Optimizing ....md ← Original research report (analysis target)
├── Technical Detail Document_ ....md  ← Full technical proof (500+ lines)
├── Linux Execution Guide_ ....md     ← Copy-paste Linux commands
├── live_gateway_test.sh               ← Automated gateway test script
├── bench_results.txt                  ← Windows benchmark raw output
├── bench_results_default.txt          ← Windows benchmark (no GOMEMLIMIT)
├── heap_benchmark.pb.gz               ← pprof heap profile
├── build/picoclaw/
│   ├── cmd/membench/                  ← Custom memory benchmark tool
│   │   ├── main.go                    ←   Platform-independent benchmark logic
│   │   ├── rss_linux.go               ←   Linux RSS via /proc/self/status
│   │   └── rss_windows.go            ←   Windows RSS via GetProcessMemoryInfo
│   └── cmd/picoclaw/                  ← PicoClaw source (telegram-slim build)
```

---

## 🚀 Quick Start

### Build & Run on Linux

```bash
cd build/picoclaw

# Build the benchmark tool
CGO_ENABLED=0 go build -tags "smallbuf" -trimpath -ldflags "-s -w" \
    -o ../../membench ./cmd/membench

# Run with memory constraints
GOMEMLIMIT=5MiB GOGC=20 BURST=100 ../../membench
```

### Build & Run the Telegram Gateway

```bash
# Build telegram-slim binary
CGO_ENABLED=0 go build -tags "telegram pprof smallbuf" -trimpath \
    -ldflags "-s -w" -o ../../picoclaw-telegram ./cmd/picoclaw

# Configure (replace with your token)
mkdir -p ~/.picoclaw
echo '{"channels":{"telegram":{"enabled":true,"token":"YOUR_BOT_TOKEN"}}}' \
    > ~/.picoclaw/config.json

# Start gateway
GOMEMLIMIT=5MiB GOGC=20 ./picoclaw-telegram gateway
```

See [Linux Execution Guide](Linux%20Execution%20Guide_%20PicoClaw%205MB%20Memory%20Proof.md) for detailed step-by-step instructions.

---

## 📋 Key Findings Summary

| Finding | Evidence |
|---|---|
| Application heap is tiny | HeapAlloc = 676 KB under 1,000-msg load |
| RSS is completely load-independent | 3,072 KB from idle through 1,000-msg burst |
| GC overhead is negligible | 0.88% CPU with `GOGC=20` |
| Every message allocation is reclaimed | pprof shows 0 bytes inuse at rest |
| 7 regexps compiled per outbound msg | `markdownToTelegramHTML` — largest unnecessary allocation |
| Config carries 10 unused channel structs | ~5 KB wasted even in telegram-only build |
| 5 MB is Linux-specific | Windows Go runtime baseline = 6.2 MB |

---

## 🛠️ Optimization Recommendations

| # | Action | Impact | Effort |
|---|---|---|---|
| 1 | Pre-compile regexps as package-level `var` | -20 KB/msg GC pressure | 15 min |
| 2 | Replace metadata `map[string]string` with struct | -560 B/msg allocation | 1 hr |
| 3 | Gate health server behind build tag | -300 KB RSS | 30 min |
| 4 | Add `sync.Pool` for byte buffers | Reduce peak alloc | 1 hr |
| 5 | Trim config to telegram-only fields | -5 KB heap | 2 hr |

---

## 📖 Documents

| Document | Description |
|---|---|
| [Research Report](Research%20Report_%20Optimizing%20OpenClaw%20and%20PicoClaw%20Memory%20Footprint.md) | Original report analyzing the OpenClaw → PicoClaw optimization path |
| [Technical Detail Document](Technical%20Detail%20Document_%20PicoClaw%205MB%20Memory%20Feasibility%20Proof.md) | Full 500-line technical proof with measured data, platform analysis, and verdict |
| [Linux Execution Guide](Linux%20Execution%20Guide_%20PicoClaw%205MB%20Memory%20Proof.md) | Step-by-step commands to reproduce all benchmarks on Linux |

---

## 🔗 References

- **PicoClaw** — [github.com/sipeed/picoclaw](https://github.com/sipeed/picoclaw) — The project under analysis (19K+ ⭐)
- **OpenClaw/Clawdbot** — The original ~1GB AI assistant that PicoClaw optimizes from
- **nanobot** — [github.com/HKUDS/nanobot](https://github.com/HKUDS/nanobot) — The inspiration for PicoClaw
- **Go Runtime Internals**
  - [A Guide to the Go Garbage Collector](https://tip.golang.org/doc/gc-guide) — Official GC tuning guide
  - [GOMEMLIMIT](https://pkg.go.dev/runtime#hdr-Environment_Variables) — Runtime soft memory limit documentation
  - [runtime.MemStats](https://pkg.go.dev/runtime#MemStats) — HeapAlloc, HeapSys, RSS relationship
- **Sipeed** — [sipeed.com](https://sipeed.com) — RISC-V hardware company behind PicoClaw
- **Telego SDK** — [github.com/mymmrac/telego](https://github.com/mymmrac/telego) — Telegram Bot API for Go (PicoClaw's dependency)

---

## 📝 Methodology

1. **Source Code Audit** — Read every `.go` file in the telegram-slim build path, mapped package dependencies, identified hot-path allocations in `handleMessage()` and `markdownToTelegramHTML()`
2. **Custom Benchmark** — Built `membench` reproducing exact bus + config + message allocation patterns with platform-specific RSS measurement (`/proc/self/status` on Linux, `GetProcessMemoryInfo` on Windows)
3. **Controlled Tests** — Ran benchmarks with `GOMEMLIMIT=5MiB GOGC=20` at 100 and 1,000 message bursts
4. **Live Validation** — Connected real Telegram bot via TLS, sent 50 messages, measured RSS from `/proc`
5. **Cross-Platform Comparison** — Same benchmark on Windows and Linux to isolate platform-specific runtime overhead

---

## ⚖️ License

This analysis is provided for educational and research purposes. PicoClaw is developed by [Sipeed](https://github.com/sipeed) under their own license.

---

<p align="center">
  <b>Built with 🔬 deep profiling and ☕ curiosity</b><br>
  <i>Proving that tiny can be measured, not just claimed</i>
</p>
