import Foundation
import AppKit

/// Some child processes need administrator rights: `mas` upgrades App Store
/// apps that are owned by root, and some casks run `sudo` while installing or
/// adopting. Without a terminal, sudo cannot prompt - so we provide a
/// SUDO_ASKPASS helper that shows a native macOS password dialog instead. The
/// password goes straight from the dialog to sudo; the Brewer app never sees
/// or stores it.
///
/// The dialog names the operation it is for (read from a small context file
/// Brewer writes when an operation starts), comes to the front, and leaves a
/// marker file while it waits, so Brewer can say "waiting for your password"
/// and bring a dialog that got buried behind other windows back up.
enum AskPass {

    private static let script = """
    #!/bin/sh
    # SUDO_ASKPASS helper for Brewer. Shows the native macOS password dialog and
    # prints the entered password to stdout for sudo. Cancel makes osascript exit
    # non-zero, which makes sudo abort.
    support="$HOME/Library/Application Support/Brewer"
    operation=$(head -c 200 "$support/askpass-context.txt" 2>/dev/null)
    : > "$support/askpass.waiting"
    trap 'rm -f "$support/askpass.waiting"' EXIT
    /usr/bin/osascript \\
      -e 'on run argv' \\
      -e 'set operationName to item 1 of argv' \\
      -e 'if operationName is "" then set operationName to "the current operation"' \\
      -e 'activate' \\
      -e 'set prompt to "Brewer needs your Mac login password to finish:" & return & operationName & return & return & "The password goes from this dialog straight to sudo - the Brewer app never sees or stores it."' \\
      -e 'set answer to display dialog prompt with title "Administrator Password" default answer "" with hidden answer with icon caution buttons {"Cancel", "OK"} default button "OK"' \\
      -e 'return text returned of answer' \\
      -e 'end run' \\
      "$operation"
    """

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Brewer", isDirectory: true)
    }

    nonisolated static var scriptPath: String {
        supportDirectory.appendingPathComponent("askpass.sh").path
    }

    /// Present while the password dialog is on screen.
    nonisolated static var waitingMarkerPath: String {
        supportDirectory.appendingPathComponent("askpass.waiting").path
    }

    nonisolated static var contextPath: String {
        supportDirectory.appendingPathComponent("askpass-context.txt").path
    }

    /// Writes the helper (idempotent) and returns its path, or nil on failure.
    nonisolated static func ensureInstalled() -> String? {
        let path = scriptPath
        let fileManager = FileManager.default
        if let existing = try? String(contentsOfFile: path, encoding: .utf8), existing == script {
            return path
        }
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            return path
        } catch {
            return nil
        }
    }

    /// Names the operation a password dialog would be for.
    nonisolated static func setContext(_ operationTitle: String) {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let line = operationTitle.replacingOccurrences(of: "\n", with: " ")
        try? line.write(toFile: contextPath, atomically: true, encoding: .utf8)
    }

    nonisolated static var isWaitingForPassword: Bool {
        FileManager.default.fileExists(atPath: waitingMarkerPath)
    }

    /// A marker left by a helper that was killed mid-dialog must not claim a
    /// password is still wanted.
    nonisolated static func clearStaleMarker() {
        try? FileManager.default.removeItem(atPath: waitingMarkerPath)
    }

    /// Brings a password dialog that ended up behind other windows to the front.
    @MainActor
    static func bringDialogToFront() {
        for app in NSWorkspace.shared.runningApplications where app.executableURL?.lastPathComponent == "osascript" {
            app.activate()
        }
    }
}
