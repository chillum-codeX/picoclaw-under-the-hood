PicoClaw Slim Build Progress
============================

Date: 2026-02-19

Summary
- Cloned upstream https://github.com/sipeed/picoclaw into /workspace/project/external (initial exploration) and into entrypoint workflow for reproducible builds.
- Implemented telegram-only modular build using Go build tags:
  - Added //go:build !telegram to all non-telegram channels and the default channels manager.
  - Added a telegram-specific channels manager and a telegram-specific main.
  - Added helpers for config path loading under telegram tag.
- Built slim binary with CGO disabled and aggressive linker flags (-s -w -trimpath).
- Performed memory profiling of `status` command with GNU time under tight runtime constraints.

Artifacts
- Binary: /workspace/project/picoclaw-telegram
- Build size (ls -lh): ~8.9 MB
- Memory profile (GNU time -v):
  - Maximum resident set size (kbytes): 1860 (~1.86 MB) for `status` command
  - Elapsed time: ~0.21s

How to reproduce
- Run: bash /workspace/project/entrypoint.sh
  - Ensures Go 1.22.x, clones repo, applies telegram-only patch, builds, and profiles.

Notes
- This slim build intentionally excludes agent/provider logic to minimize memory. Gateway+Telegram can be started via `gateway` command in the slim main, but actual runtime RSS will be higher than `status`.
- Next steps: attempt TinyGo build for further code-size/runtime reduction, add build tags for other single-channel variants, and refine buffers/JSON parsing for lower steady-state memory during gateway operation.

