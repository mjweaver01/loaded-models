# Loaded Models

See which local LLMs are loaded and how hard they're working, from your menu bar or desktop.

A small native macOS app in the spirit of [MenuMeters](https://github.com/yujitach/MenuMeters): live graphs, near-zero overhead, no Electron.

## Features

**Menu bar**
- Live GPU sparkline, the number of loaded models, and a `•` while any model is generating

**Popover** (click the menu bar item)
- Every loaded model with its params, quantization, format and context length
- Per model: real memory and CPU of its process, live tokens/sec while streaming, prompt-processing progress, and a sparkline of recent runs with average tok/s and time to first token
- Status: generating, reading prompt, or idle with when it was last used
- Live 2-minute charts: tokens/sec, GPU utilization, runtime CPU, GPU memory
- System memory bar showing how much the loaded models take
- Toggles for the desktop widget and launch at login

**Desktop widget**
- A blurred, rounded panel that sits on the wallpaper below your windows, on every Space
- Shows the loaded models, tokens/sec and GPU charts, and memory, updated every second
- Drag it anywhere (the position is remembered); right-click to hide it

## Requirements

- macOS 14 or later on Apple Silicon
- Swift 5.10+ (Xcode or the Command Line Tools) to build
- [LM Studio](https://lmstudio.ai) with its `lms` CLI at `~/.lmstudio/bin/lms` (LM Studio installs it)
- Optional: [Ollama](https://ollama.com)

## Install

```sh
./build.sh            # builds "build/Loaded Models.app"
./build.sh install    # copies it to /Applications and launches it
```

Install to `/Applications` before enabling **Launch at login**, so the login item points at that copy. Run `./build.sh install` again after making changes.

The app is ad-hoc signed and runs only on the Mac that built it. No Apple Developer account is needed.

## How it works

Everything is read locally; the app makes no network requests beyond `127.0.0.1`.

| Data | Source |
|---|---|
| Loaded models, status, queue | `lms ps --json`, gated by a cheap check of LM Studio's REST API (`:1234/api/v0/models`) so `lms` only runs while something is loaded |
| Ollama models | `GET :11434/api/ps` |
| Final tok/s, TTFT, token counts | `lms log stream --source model --stats` (one event per finished prediction) |
| Live tok/s, prompt progress | `lms log stream --source server` (one "Generated packet" line per streamed chunk, about one token each) |
| Which process belongs to which model | `lms log stream --source runtime` (logs carry the worker pid), with fallbacks: the `--model` argument of `llama-server`, or elimination |
| Per-model memory and CPU | `proc_pidinfo` on each model's process. LM Studio runs every model in its own process: `llmworker` for MLX, `llama-server` for GGUF |
| GPU utilization and memory | IOKit `IOAccelerator` → `PerformanceStatistics` (no root needed) |
| System memory | `host_statistics64`, matching Activity Monitor's "Memory Used" |

The app only talks to a runtime while its process is running, so it never starts LM Studio's daemon itself. It stops its `lms log stream` children when it quits, and on launch it removes any left behind by a crash.

Overhead is about 3% of one core while idle (roughly 0.2% of the whole CPU on an M5 Max) and about 80 MB of RAM.

## Limitations

- **Live tok/s only covers streaming API requests.** Non-streaming requests (and possibly LM Studio's own chat window) report their speed only when they finish; the chart then fills in that generation's time window.
- **GPU utilization is system-wide.** macOS doesn't split GPU use by process, so the per-model status shows which model is busy.
- **Ollama** shows loaded models and sizes only. Its API doesn't expose speed or activity.
- **The LM Studio server port** is assumed to be `1234`.
- **Not a WidgetKit widget.** Native widgets refresh every few minutes at best, which rules out live graphs, so the desktop widget is a desktop-level window instead.

## Debugging

Run the binary directly with `LOADED_MODELS_DEBUG=1` to print per-model stats every second:

```sh
LOADED_MODELS_DEBUG=1 "/Applications/Loaded Models.app/Contents/MacOS/LoadedModels"
# gpu=61% tok/s=208 chartTotal=799 qwen3.5-2b[2.23GB 58.6%cpu live=208 active]
```

## Project layout

```
Package.swift                  SwiftPM manifest (executable target, macOS 14)
build.sh                       Builds, signs and optionally installs the .app
Resources/Info.plist           Bundle info (LSUIElement: no Dock icon)
Sources/LoadedModels/
  LoadedModelsApp.swift        App entry, MenuBarExtra, menu bar label and sparkline
  Monitor.swift                1-second sampling loop and all state the UI reads
  SystemStats.swift            GPU (IOKit), per-process CPU and memory, system memory
  ModelSources.swift           Loaded models from LM Studio and Ollama
  LMStudioLogs.swift           Tails `lms log stream` and parses events
  PopoverView.swift            Popover UI and shared views (model rows, charts)
  DesktopWidget.swift          Desktop-level panel and its view
```
