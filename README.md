# Brewer

A native Homebrew app for the Mac that turns `brew` commands into simple
point-and-click actions. Built in SwiftUI. Everything maps directly to real
brew commands, so your setup stays portable, familiar, and fully yours.

**🌐 Website: [monzdigital.github.io/brewer](https://monzdigital.github.io/brewer/) ·
⬇️ [Download the latest release](https://github.com/monzdigital/brewer/releases/latest)**

```bash
brew install --cask monzdigital/tap/brewer
```

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5](https://img.shields.io/badge/Swift-5.9-orange) ![Free](https://img.shields.io/badge/price-free-brightgreen) ![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)

> Early build, not yet notarized - macOS blocks the first launch, and the first
> launch after each update. Open System Settings → Privacy & Security, scroll
> down, and click "Open Anyway", or clear the quarantine flag in Terminal:
> `xattr -dr com.apple.quarantine /Applications/Brewer.app`
> (Homebrew 7 removed the old `--no-quarantine` install option.)

**Brewer and BrewUI.** Homebrew 7 ships BrewUI, an official app for browsing
and searching packages on macOS 26 and later. Brewer is built for everything
around the packages - App Store and Sparkle app updates, uninstalls with
leftovers, scheduled upgrades, health and security checks - and runs on
macOS 14 Sonoma and later.

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
- Reinstall, link/unlink (keg-only and unlinked formulae are flagged), reveal apps in Finder
- Adopt apps already in /Applications (`brew install --cask --adopt`)
- Per-package notes, tags and collections; compact list mode

**Stay up to date**
- Scheduled update checks (6h/12h/daily/weekly) with notifications that open the right page
- Optional automatic background upgrades - battery-aware (AC power / Low Power Mode)
- Menu bar icon with outdated count at a glance; optional menu-bar-only mode and launch at login
- Running apps are closed cleanly before their cask is upgraded and reopened afterwards
- Snooze updates per package (for a duration, per version, or indefinitely - the cask
  equivalent of `brew pin`); snoozed packages are never touched by "Upgrade All"
- Optional greedy mode lists and upgrades self-updating casks consistently (`--greedy-auto-updates`)
- App Updates: scans Sparkle feeds of installed apps and compares versions the way
  Sparkle does (build numbers), skipping betas and releases that need a newer macOS

**Services, taps & Brewfiles**
- Start / stop / restart `brew services` with one click
- Add and remove taps; tap details (formula/cask counts, repo link)
- Tap trust the way Homebrew recommends: trust just the packages you installed from a
  tap, or the whole tap after a confirmation (`brew trust`)
- Packages from untrusted taps don't silently vanish: Homebrew leaves them out of its
  package lists, so Brewer reads their install receipts and points you to Taps
- Export, import and check Brewfiles (`brew bundle`)

**Keep Homebrew healthy**
- Health dashboard: outdated count, deprecated/disabled packages, orphans,
  cache size, doctor issues, health score
- `brew doctor` in a readable interface - on Homebrew 7 as structured findings
  with affected packages and one-click fixes (`brew doctor --json`)
- Security advisories: scan installed formulae with `brew vulns` (OSV.dev),
  ranked by severity, with links, fix status and upgrade buttons
- Support-tier notices when Homebrew 7 treats your Mac as Tier 3 (Intel,
  Rosetta installs, macOS 14 Sonoma)
- Cleanup preview (`--dry-run`) with per-file sizes, one-click cleanup
- Remove quarantine flags from cask apps
- Duplicate detection (multi-version kegs, Homebrew ⟷ App Store overlaps)

**All apps, not just Homebrew** *(MacUpdater / Latest-style)*
- Apps inventory: every app on the Mac with install source (Homebrew /
  App Store / Sparkle / manual), size and architecture
- Direct Sparkle updates: download → verify (EdDSA signature and code-signing
  identity) → back up the old version → extract (zip/dmg/tar) → install, with
  release-notes preview, automatic rollback on failure and restore from backups
- Apps inside /Applications subfolders (Setapp, Utilities, vendor folders) are scanned too;
  Setapp and App Store editions are left to their own stores, so their licenses never break
- Background checks notify you when app updates appear

**Complete uninstaller** *(AppCleaner-style)*
- Drag & drop any app (or drop it on the Dock icon) to remove it together with its
  caches, preferences, support files, logs and containers (everything goes to the
  Trash - recoverable)
- Homebrew casks are uninstalled through brew, leftovers cleaned after
- SmartDelete: optionally watch your Applications folders and offer leftover
  cleanup when you delete an app the normal way (no Full Disk Access needed)
- Safety first: Apple/system apps are protected; name-only matches require review

**Extras**
- Installation history · dependency tree visualization · Apple Silicon scan
  (finds Intel-only apps and Rosetta-installed brew) · `mas` CLI integration
  · notifications when long operations finish · bottom-docked live console with
  a cancellable queue (Homebrew runs one command at a time) · failed operations
  keep their output in History

## Requirements

- macOS 14 Sonoma or later
- [Homebrew](https://brew.sh) (auto-detected at `/opt/homebrew` or `/usr/local`;
  custom path configurable in Settings)
- To build: Xcode (recommended), or the Command Line Tools with a macOS 26 SDK.
  With the macOS 27 SDK, SwiftUI's macros need Xcode's toolchain; `make app`
  picks a working toolchain automatically (see `scripts/toolchain.sh`)

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

## License

Brewer is free software released under the [GPL-3.0](LICENSE) license.
