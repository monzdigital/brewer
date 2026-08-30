# Contributing to Brewer

Thanks for your interest! Brewer is a native SwiftUI app built with plain
SwiftPM - no Xcode project required.

## Building

```bash
make app        # release build -> dist/Brewer.app
make debug      # debug build
make run        # build and open
```

Requirements: macOS 14+, Swift 5.9+ (full Xcode or just the Command Line
Tools), and Homebrew installed for runtime testing.

## Before you open a PR

1. Build cleanly: `swift build` with no errors.
2. Run the data-layer self-test against your real Homebrew install - all
   checks must pass:

   ```bash
   .build/debug/Brewer --selftest
   ```

3. If you changed any UI, exercise the affected screens. You can regenerate
   reference screenshots of every page with:

   ```bash
   ./dist/Brewer.app/Contents/MacOS/Brewer --tour-shots /tmp/shots
   ```

## Guidelines

- Every user-visible action must map to a real `brew` command and stream its
  output through the console - no hidden magic.
- Mutating brew commands go through `TaskConsole` (serialized queue);
  read-only queries use `BrewClient`.
- Anything that deletes user data must go through the Trash, never a hard
  delete. Apple/system apps stay protected in the uninstaller.
- Style: match the surrounding code; use plain hyphens, never em dashes, in
  all strings and docs.
- Keep PRs focused - one feature or fix per PR, with a short description of
  how you tested it.

## Reporting bugs

Use the bug report issue template. Console output (the operation's log in the
app) and your `brew --version` make reports much easier to act on.
