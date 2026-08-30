import Foundation

/// Some child processes need administrator rights: `mas` upgrades App Store
/// apps that are owned by root, and a few pkg-based casks run `sudo installer`.
/// Without a terminal, sudo cannot prompt - so we provide a SUDO_ASKPASS
/// helper that shows the native macOS password dialog instead. The password
/// goes straight from the dialog to sudo; Brewer never sees or stores it.
enum AskPass {

    private static let script = """
    #!/bin/sh
    # SUDO_ASKPASS helper for Brewer. Shows the native macOS admin-password
    # prompt and prints the entered password to stdout for sudo.
    # Cancelling makes osascript exit non-zero, which makes sudo abort.
    exec /usr/bin/osascript \
      -e 'set d to display dialog "Brewer needs administrator privileges for the current operation." with title "Brewer" default answer "" with hidden answer with icon caution buttons {"Cancel", "Allow"} default button "Allow"' \
      -e 'text returned of d'
    """

    nonisolated static var scriptPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Brewer/askpass.sh").path
    }

    /// Writes the helper (idempotent) and returns its path, or nil on failure.
    nonisolated static func ensureInstalled() -> String? {
        let path = scriptPath
        let fileManager = FileManager.default
        if let existing = try? String(contentsOfFile: path, encoding: .utf8), existing == script {
            return path
        }
        do {
            try fileManager.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            return path
        } catch {
            return nil
        }
    }
}
