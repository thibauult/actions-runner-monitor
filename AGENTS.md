# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## What this is

A macOS 14+ menu bar app (SwiftUI `MenuBarExtra`) that shows the state of self-hosted GitHub Actions runners installed as launchd services. No Xcode project and no Swift package: `build.sh` calls `swiftc` directly on `Sources/*.swift`. There are no tests and no linter.

## Commands

```bash
./build.sh            # universal (arm64 + x86_64) app into build/
./build.sh --install  # also copy to ~/Applications and (re)start it (handles the launchd agent)
./build.sh --zip      # also package build/ActionsRunnerMonitor.zip (what CI releases)

BIN="build/Actions Runner Monitor.app/Contents/MacOS/ActionsRunnerMonitor"
"$BIN" --dump              # print discovered runners + parsed jobs, no UI (CI runs this as its only check)
"$BIN" --dump path/to.log  # run the log parser on a single file
"$BIN" --install-agent     # / --uninstall-agent: toggle the KeepAlive launchd agent
```

`--dump` is the way to verify discovery/parsing changes. CI (`.github/workflows/build.yml`) builds on `macos-15` and publishes a GitHub release on `v*` tags.

## Architecture

`Entry.main` (`App.swift`) handles CLI flags (`--dump`, `--write-icon`, `--install-agent`/`--uninstall-agent`) before launching the SwiftUI app, so headless modes never open UI. `build.sh` uses `--write-icon` to render the app icon from the same code that draws the menu bar GitHub mark (`GitHubMark.swift`).

Data flow, all derived from files the runner itself wrote (nothing is configured):

1. **Discovery** (`Runner.swift`): each `actions.runner.*.plist` in `~/Library/LaunchAgents` is a runner. `StandardOutPath` is the log; `WorkingDirectory` holds `.runner` (name, org/repo URL, agent id).
2. **State** (`Monitor.swift`): `RunnerProbe` runs `launchctl list` to see whether the service is up; a `Runner.Worker` child process means busy. `Monitor` (`@MainActor`, `ObservableObject`) polls in a loop at `Defaults.refreshInterval`, off the main thread. All subprocesses have timeouts. Failed probes keep the last state, and identical snapshots are not republished (republishing re-lays out the status item and can swallow clicks).
3. **Jobs** (`LogParser.swift`): parses only the last 512 KB of the listener log (`Running job:` / `Job … completed with result:` lines), and only when the log changed.
4. **Job → GitHub link** (`JobLinks.swift`): the listener log has no repo/run info, so `JobLinkResolver` matches jobs to `_diag/Worker_<utc>.log` files and reads repo, run id and check run id from the job message. Results are cached per file.
5. **UI** (`Views.swift`): the panel, settings, and menu bar label (overall state: offline > busy > idle).
6. **Self-management**: `SelfAgent.swift` writes and loads the app's own launchd agent (start at login + KeepAlive); `Startup.shouldRun` makes the launchd-started copy close a manually started one. `Notifier.swift` handles job-start notifications.

Settings live in `UserDefaults.standard` (domain `io.github.thibauult.actions-runner-monitor`), defined in `Defaults.swift`: `refreshInterval`, `historyLimit`, `hiddenRunners`, `notifyOnJobStart`. They can be changed with `defaults write` (defaults: 3 s refresh, 10 jobs of history, notifications on; refresh and history are clamped to a minimum of 1).

The bundle id in `Info.plist` doubles as the launchd label for the self agent, and `build.sh` reads it from there.
