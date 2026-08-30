# Brewer

A native Homebrew app for the Mac that turns `brew` commands into simple
point-and-click actions. Built in SwiftUI. Everything maps directly to real
brew commands, so your setup stays portable, familiar, and fully yours.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5](https://img.shields.io/badge/Swift-5.9-orange)

## Features

**Browse & install**
- Search formulae, casks and third-party taps from one search bar (full
  `user/repo/package` paths supported — missing taps can be added automatically)
- Inspect dependencies, license, caveats, disk usage and quarantine status before installing
- One-click install with live command output streamed into the console panel
- Curated Discover catalog with live install counts from formulae.brew.sh

**Manage what you have**
- Everything installed in one list; filter by formulae, casks, outdated, favorites, pinned
- Multi-select to upgrade, uninstall, pin or favorite in bulk
- Adopt apps already in /Applications (`brew install --cask --adopt`)
- Per-package notes, tags and collections; compact list mode

**Stay up to date**
- Scheduled update checks (6h/12h/daily/weekly) with notifications
- Optional automatic background upgrades — battery-aware (AC power / Low Power Mode)
- Menu bar icon with outdated count at a glance
- Running apps are closed cleanly before their cask is upgraded
- Snooze updates per package (for a duration or per version)
- App Updates: scans Sparkle feeds of installed apps and compares versions

**Services, taps & Brewfiles**
- Start / stop / restart `brew services` with one click
- Add and remove taps; tap details (formula/cask counts, repo link)
- Export, import and check Brewfiles (`brew bundle`)

**Keep Homebrew healthy**
- Health dashboard: outdated count, deprecated/disabled packages, orphans,
  cache size, doctor issues, health score
- `brew doctor` in a readable interface
- Cleanup preview (`--dry-run`) with per-file sizes, one-click cleanup
- Remove quarantine flags from cask apps
- Duplicate detection (multi-version kegs, Homebrew ⟷ App Store overlaps)

**Extras**
- Installation history · dependency tree visualization · Apple Silicon scan
  (finds Intel-only apps and Rosetta-installed brew) · `mas` CLI integration

## Requirements

- macOS 14 Sonoma or later
- [Homebrew](https://brew.sh) (auto-detected at `/opt/homebrew` or `/usr/local`;
  custom path configurable in Settings)
- To build: Xcode **or** just the Command Line Tools (Swift 5.9+)

## Build & run

```bash
make app        # build release and assemble dist/Brewer.app
make run        # build and open the app
make debug      # debug build
make icon       # regenerate packaging/AppIcon.icns
```

The result is `dist/Brewer.app` — copy it to /Applications if you like.
With Xcode installed you can also open `Package.swift` directly.

## Verify the data layer

The binary ships with a headless self-test that exercises JSON decoding,
output parsers and scanners against your real Homebrew installation:

```bash
.build/release/Brewer --selftest
```

## Architecture

```
Sources/Brewer/
├── Support/      brew detection, process runner (live output streaming),
│                 tolerant JSON models, read-only BrewClient, scanners, utilities
├── Models/       BrewPackage and friends
├── Stores/       @Observable state: packages, console, user metadata,
│                 services, taps, health, scans, scheduler
└── Views/        SwiftUI: sidebar navigation, package browser + detail,
                  discover, updates, maintenance, console, settings
```

Mutating commands run through a serialized console queue (Homebrew holds a
global lock), stream their output live, and are recorded to history.
Read-only queries (`brew info --json=v2`, `brew outdated`, …) run directly
with `HOMEBREW_NO_AUTO_UPDATE=1`.
