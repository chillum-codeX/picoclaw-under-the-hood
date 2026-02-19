#!/usr/bin/env bash
set -euo pipefail

# PicoClaw telegram-only ultra-slim build and memory profile
# This script clones upstream PicoClaw, applies a minimal telegram-only build using Go build tags,
# builds with aggressive linker flags, and profiles memory usage of the 'status' command.
# It avoids heavy agent/provider logic and excludes non-telegram channels for minimal footprint.

WORKDIR="/workspace/project"
BUILD_DIR="$WORKDIR/build"
REPO_URL="https://github.com/sipeed/picoclaw.git"
REPO_DIR="$BUILD_DIR/picoclaw"

mkdir -p "$BUILD_DIR"

echo "[1/7] Ensure Go toolchain (1.22.x) is available"
if ! /usr/local/go/bin/go version >/dev/null 2>&1; then
  echo "Installing Go 1.22.5..."
  cd /tmp
  wget -O go1.22.5.linux-amd64.tar.gz https://dl.google.com/go/go1.22.5.linux-amd64.tar.gz
  rm -rf /usr/local/go && tar -C /usr/local -xzf go1.22.5.linux-amd64.tar.gz
fi
export PATH="/usr/local/go/bin:$PATH"

if ! command -v time >/dev/null 2>&1; then
  echo "Installing GNU time for memory profiling..."
  apt-get update && apt-get install -y time
fi

echo "[2/7] Clone PicoClaw upstream"
rm -rf "$REPO_DIR"
git clone "$REPO_URL" "$REPO_DIR"

# Some environments may have older default Go; patch go.mod to a supported version
echo "[3/7] Patch go.mod go directive to 1.22"
sed -i 's/^go .*/go 1.22/' "$REPO_DIR/go.mod"

echo "[4/7] Apply telegram-only build: exclude default main and non-telegram channels"
# Exclude default main when building with -tags telegram
if ! head -n 1 "$REPO_DIR/cmd/picoclaw/main.go" | grep -q "//go:build"; then
  sed -i '1i //go:build !telegram\n' "$REPO_DIR/cmd/picoclaw/main.go"
fi

# Add build constraints to non-telegram channels to strip them under -tags telegram
non_tg_channels=(
  dingtalk.go discord.go feishu_32.go feishu_64.go line.go maixcam.go onebot.go qq.go slack.go whatsapp.go manager.go
)
for f in "${non_tg_channels[@]}"; do
  file="$REPO_DIR/pkg/channels/$f"
  if [ -f "$file" ]; then
    if ! head -n 1 "$file" | grep -q "//go:build"; then
      sed -i '1i //go:build !telegram\n' "$file"
    fi
  fi
done

echo "[5/7] Add minimal telegram-only files (main, helpers, manager)"
cat > "$REPO_DIR/cmd/picoclaw/main_telegram.go" <<'EOF'
//go:build telegram

package main

import (
    "context"
    "fmt"
    "net/http"
    "os"
    "os/signal"
    "runtime"

    "github.com/sipeed/picoclaw/pkg/bus"
    "github.com/sipeed/picoclaw/pkg/channels"
    "github.com/sipeed/picoclaw/pkg/health"
    "github.com/sipeed/picoclaw/pkg/logger"
)

var (
    version   = "dev"
    gitCommit string
    buildTime string
    goVersion string
)

const logo = "🦞"

func formatVersion() string {
    v := version
    if gitCommit != "" {
        v += fmt.Sprintf(" (git: %s)", gitCommit)
    }
    return v
}

func formatBuildInfo() (build string, goVer string) {
    if buildTime != "" {
        build = buildTime
    }
    goVer = goVersion
    if goVer == "" {
        goVer = runtime.Version()
    }
    return
}

func printHelp() {
    fmt.Printf("%s picoclaw (telegram-slim) v%s\n\n", logo, version)
    fmt.Println("Usage: picoclaw <command>")
    fmt.Println()
    fmt.Println("Commands:")
    fmt.Println("  status      Show status (config, workspace)")
    fmt.Println("  gateway     Start minimal gateway with Telegram channel")
    fmt.Println("  version     Show build information")
}

func main() {
    if len(os.Args) < 2 {
        printHelp()
        os.Exit(1)
    }
    switch os.Args[1] {
    case "status":
        statusCmd()
    case "version":
        printVersion()
    case "gateway":
        gatewayCmd()
    default:
        printHelp()
    }
}

func printVersion() {
    fmt.Printf("%s picoclaw %s\n", logo, formatVersion())
    build, goVer := formatBuildInfo()
    if build != "" {
        fmt.Printf("  Build: %s\n", build)
    }
    if goVer != "" {
        fmt.Printf("  Go: %s\n", goVer)
    }
}

func statusCmd() {
    cfg, err := loadConfig()
    if err != nil {
        fmt.Printf("Error loading config: %v\n", err)
        return
    }
    configPath := getConfigPath()
    fmt.Printf("%s picoclaw Status\n", logo)
    fmt.Printf("Version: %s\n", formatVersion())
    build, _ := formatBuildInfo()
    if build != "" {
        fmt.Printf("Build: %s\n", build)
    }
    fmt.Println()
    if _, err := os.Stat(configPath); err == nil {
        fmt.Println("Config:", configPath, "✓")
    } else {
        fmt.Println("Config:", configPath, "✗")
    }
    workspace := cfg.WorkspacePath()
    if _, err := os.Stat(workspace); err == nil {
        fmt.Println("Workspace:", workspace, "✓")
    } else {
        fmt.Println("Workspace:", workspace, "✗")
    }
}

func gatewayCmd() {
    cfg, err := loadConfig()
    if err != nil {
        fmt.Printf("Error loading config: %v\n", err)
        os.Exit(1)
    }
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()

    // Bus and channels (telegram only via build tags)
    msgBus := bus.NewMessageBus()
    channelManager, err := channels.NewManager(cfg, msgBus)
    if err != nil {
        fmt.Printf("Error initializing channels: %v\n", err)
        os.Exit(1)
    }

    // Health server
    healthServer := health.NewServer(cfg.Gateway.Host, cfg.Gateway.Port)
    go func() {
        if err := healthServer.Start(); err != nil && err != http.ErrServerClosed {
            logger.ErrorCF("health", "Health server error", map[string]interface{}{"error": err.Error()})
        }
    }()
    fmt.Printf("✓ Health endpoints: http://%s:%d/health and /ready\n", cfg.Gateway.Host, cfg.Gateway.Port)

    if err := channelManager.StartAll(ctx); err != nil {
        fmt.Printf("Error starting channels: %v\n", err)
    }

    sigChan := make(chan os.Signal, 1)
    signal.Notify(sigChan, os.Interrupt)
    <-sigChan

    fmt.Println("\nShutting down...")
    healthServer.Stop(context.Background())
    channelManager.StopAll(ctx)
    fmt.Println("✓ Gateway stopped")
}
EOF

cat > "$REPO_DIR/cmd/picoclaw/helpers_telegram.go" <<'EOF'
//go:build telegram

package main

import (
    "fmt"
    "os"
    "path/filepath"

    "github.com/sipeed/picoclaw/pkg/config"
)

func getConfigPath() string {
    home, err := os.UserHomeDir()
    if err != nil {
        fmt.Println("Error getting home directory:", err)
        return ".picoclaw/config.json"
    }
    return filepath.Join(home, ".picoclaw", "config.json")
}

func loadConfig() (*config.Config, error) {
    return config.LoadConfig(getConfigPath())
}
EOF

cat > "$REPO_DIR/pkg/channels/manager_telegram.go" <<'EOF'
//go:build telegram

package channels

import (
    "context"
    "sync"

    "github.com/sipeed/picoclaw/pkg/bus"
    "github.com/sipeed/picoclaw/pkg/config"
    "github.com/sipeed/picoclaw/pkg/constants"
    "github.com/sipeed/picoclaw/pkg/logger"
)

type Manager struct {
    channels     map[string]Channel
    bus          *bus.MessageBus
    config       *config.Config
    dispatchTask *asyncTask
    mu           sync.RWMutex
}

type asyncTask struct {
    cancel context.CancelFunc
}

func NewManager(cfg *config.Config, messageBus *bus.MessageBus) (*Manager, error) {
    m := &Manager{
        channels: make(map[string]Channel),
        bus:      messageBus,
        config:   cfg,
    }
    if err := m.initChannels(); err != nil {
        return nil, err
    }
    return m, nil
}

func (m *Manager) initChannels() error {
    logger.InfoC("channels", "Initializing minimal channel manager (telegram)")
    if m.config.Channels.Telegram.Enabled && m.config.Channels.Telegram.Token != "" {
        logger.DebugC("channels", "Attempting to initialize Telegram channel")
        telegram, err := NewTelegramChannel(m.config, m.bus)
        if err != nil {
            logger.ErrorCF("channels", "Failed to initialize Telegram channel", map[string]interface{}{
                "error": err.Error(),
            })
        } else {
            m.channels["telegram"] = telegram
            logger.InfoC("channels", "Telegram channel enabled successfully")
        }
    }
    logger.InfoCF("channels", "Channel initialization completed", map[string]interface{}{
        "enabled_channels": len(m.channels),
    })
    return nil
}

func (m *Manager) StartAll(ctx context.Context) error {
    m.mu.Lock()
    defer m.mu.Unlock()
    if len(m.channels) == 0 {
        logger.WarnC("channels", "No channels enabled")
        return nil
    }
    logger.InfoC("channels", "Starting all channels")
    dispatchCtx, cancel := context.WithCancel(ctx)
    m.dispatchTask = &asyncTask{cancel: cancel}
    go m.dispatchOutbound(dispatchCtx)
    for name, channel := range m.channels {
        logger.InfoCF("channels", "Starting channel", map[string]interface{}{
            "channel": name,
        })
        if err := channel.Start(ctx); err != nil {
            logger.ErrorCF("channels", "Failed to start channel", map[string]interface{}{
                "channel": name,
                "error":   err.Error(),
            })
        }
    }
    logger.InfoC("channels", "All channels started")
    return nil
}

func (m *Manager) StopAll(ctx context.Context) error {
    m.mu.Lock()
    defer m.mu.Unlock()
    if m.dispatchTask != nil && m.dispatchTask.cancel != nil {
        m.dispatchTask.cancel()
        m.dispatchTask = nil
    }
    for name, channel := range m.channels {
        logger.InfoCF("channels", "Stopping channel", map[string]interface{}{
            "channel": name,
        })
        if err := channel.Stop(ctx); err != nil {
            logger.ErrorCF("channels", "Failed to stop channel", map[string]interface{}{
                "channel": name,
                "error":   err.Error(),
            })
        }
    }
    logger.InfoC("channels", "All channels stopped")
    return nil
}

func (m *Manager) dispatchOutbound(ctx context.Context) {
    logger.InfoC("channels", "Outbound dispatcher started")
    for {
        select {
        case <-ctx.Done():
            logger.InfoC("channels", "Outbound dispatcher stopped")
            return
        default:
            msg, ok := m.bus.SubscribeOutbound(ctx)
            if !ok {
                continue
            }
            if constants.IsInternalChannel(msg.Channel) {
                continue
            }
            m.mu.RLock()
            channel, exists := m.channels[msg.Channel]
            m.mu.RUnlock()
            if !exists {
                logger.WarnCF("channels", "Unknown channel for outbound message", map[string]interface{}{
                    "channel": msg.Channel,
                })
                continue
            }
            if err := channel.Send(ctx, msg); err != nil {
                logger.ErrorCF("channels", "Error sending message to channel", map[string]interface{}{
                    "channel": msg.Channel,
                    "error":   err.Error(),
                })
            }
        }
    }
}
EOF

# Minimal embed directory to satisfy //go:embed in default main when building non-telegram, not used here but keep safe
mkdir -p "$REPO_DIR/cmd/picoclaw/workspace/templates"
printf "{}\n" > "$REPO_DIR/cmd/picoclaw/workspace/templates/config.json"

echo "[6/7] Build telegram-only binary with aggressive linker flags"
cd "$REPO_DIR"
/usr/local/go/bin/go mod tidy || true
CGO_ENABLED=0 GOMAXPROCS=1 /usr/local/go/bin/go build -buildvcs=false -tags telegram -trimpath \
  -ldflags "-s -w -X main.version=v0.1-telegram-min" \
  -o "$WORKDIR/picoclaw-telegram" ./cmd/picoclaw
chmod +x "$WORKDIR/picoclaw-telegram"
ls -lh "$WORKDIR/picoclaw-telegram"

echo "[7/7] Memory profiling (status command) with tight limits"
/usr/bin/time -v env GOMEMLIMIT=4MiB GOGC=20 "$WORKDIR/picoclaw-telegram" status || true

echo "\nDone. Binary at $WORKDIR/picoclaw-telegram"
