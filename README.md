# Brewer

A native Homebrew app for the Mac that turns `brew` commands into simple
point-and-click actions. Built in SwiftUI. Everything maps directly to real
brew commands, so your setup stays portable, familiar, and fully yours.

**🌐 Website: [monzdigital.github.io/brewer](https://monzdigital.github.io/brewer/) ·
⬇️ [Download the latest release](https://github.com/monzdigital/brewer/releases/latest/download/Brewer-1.0.0.zip)**

```bash
brew install --cask monzdigital/tap/brewer
```

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5](https://img.shields.io/badge/Swift-5.9-orange) ![Free](https://img.shields.io/badge/price-free-brightgreen)

> Early build, not yet notarized - on first launch right-click the app → Open,
> or allow it under System Settings → Privacy & Security.

## Features

**Browse & install**
- Search formulae, casks and third-party taps from one search bar (full
  `user/repo/package` paths supported - missing taps can be added automatically)
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
- Optional automatic background upgrades - battery-aware (AC power / Low Power Mode)
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

**All apps, not just Homebrew** *(MacUpdater / Latest-style)*
- Apps inventory: every app on the Mac with install source (Homebrew /
  App Store / Sparkle / manual), size and architecture
- Direct Sparkle updates: download → back up the old version → extract
  (zip/dmg/tar) → install, with release-notes preview and rollback from backups
- Background checks notify you when app updates appear

**Complete uninstaller** *(AppCleaner-style)*
- Drag & drop any app to remove it together with its caches, preferences,
  support files, logs and containers (everything goes to the Trash - recoverable)
- Homebrew casks are uninstalled through brew, leftovers cleaned after
- SmartDelete: optionally watch the Trash and offer leftover cleanup when you
  delete an app the normal way
- Safety first: Apple/system apps are protected; name-only matches require review

**Extras**
- Installation history · dependency tree visualization · Apple Silicon scan
  (finds Intel-only apps and Rosetta-installed brew) · `mas` CLI integration
  · notifications when long operations finish · bottom-docked live console

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

The result is `dist/Brewer.app` - copy it to /Applications if you like.
With Xcode installed you can also open `Package.swift` directly.

For signed, notarized, universal (arm64+x86_64) builds for distribution, see
[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) and `scripts/release.sh`.
(Heads-up: this app class cannot ship on the Mac App Store - the App Sandbox
forbids running brew and managing other apps; Developer ID + notarization is
the supported path, same as Cork/Cakebrew/AppCleaner.)

## Website

The landing page is authored in `site/` (template + build script) and built
into `docs/index.html`, which GitHub Pages serves at
[monzdigital.github.io/brewer](https://monzdigital.github.io/brewer/). The
download button points at the latest GitHub release asset.

To refresh the screenshots after UI changes and rebuild the page:

```bash
./dist/Brewer.app/Contents/MacOS/Brewer --tour-shots /tmp/shots   # captures every page
python3 site/build-site.py /tmp/shots
```

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
