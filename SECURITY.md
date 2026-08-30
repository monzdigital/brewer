# Security Policy

## Supported versions

Only the latest release on the
[releases page](https://github.com/monzdigital/brewer/releases) receives
security fixes.

## Reporting a vulnerability

Please do NOT open a public issue for security problems.

Use GitHub's private vulnerability reporting instead:
**Security tab → "Report a vulnerability"** on this repository
(https://github.com/monzdigital/brewer/security/advisories/new).

You can expect an initial response within a few days. Please include steps to
reproduce and the app/macOS/Homebrew versions involved.

## Scope notes

Brewer intentionally runs without the App Sandbox (it must execute `brew`,
manage app bundles, and scan Library folders). Reports about that design
itself are out of scope; reports about Brewer doing more than the user asked,
executing untrusted input, or mishandling downloaded artifacts are very much
in scope.
