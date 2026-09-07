import Foundation
import AppKit
import CryptoKit
import UserNotifications

// MARK: - Preferences

enum Prefs {
    static let menuBarEnabled = "pref.menuBarEnabled"
    static let autoOpenConsole = "pref.autoOpenConsole"
    static let compactRows = "pref.compactRows"
    static let checkIntervalHours = "pref.checkIntervalHours"
    static let checkOnLaunch = "pref.checkOnLaunch"
    static let notifyOnUpdates = "pref.notifyOnUpdates"
    static let autoUpgrade = "pref.autoUpgrade"
    static let batteryAware = "pref.batteryAware"
    static let closeAppsBeforeUpgrade = "pref.closeAppsBeforeUpgrade"
    static let greedyCasks = "pref.greedyCasks"
    static let customBrewPath = "pref.customBrewPath"
    static let notifyOnOperations = "pref.notifyOnOperations"
    static let smartDelete = "pref.smartDelete"
    static let backupBeforeUpdate = "pref.backupBeforeUpdate"
    static let keepBackupsPerApp = "pref.keepBackupsPerApp"
    static let relaunchAppsAfterUpgrade = "pref.relaunchAppsAfterUpgrade"
    static let hideDockIcon = "pref.hideDockIcon"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            menuBarEnabled: true,
            autoOpenConsole: true,
            compactRows: false,
            checkIntervalHours: 24,
            checkOnLaunch: true,
            notifyOnUpdates: true,
            autoUpgrade: false,
            batteryAware: true,
            closeAppsBeforeUpgrade: true,
            greedyCasks: false,
            customBrewPath: "",
            notifyOnOperations: true,
            smartDelete: false,
            backupBeforeUpdate: true,
            keepBackupsPerApp: 2,
            relaunchAppsAfterUpgrade: true,
            hideDockIcon: false
        ])
    }
}

// MARK: - Dock presence (menu bar only mode)

@MainActor
enum DockIcon {
    static func apply(hidden: Bool) {
        let policy: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if !hidden { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - Cross-scene requests

extension Notification.Name {
    /// Asks whichever scene is alive (the menu bar label always is) to open the
    /// main window - AppKit callbacks can't reach SwiftUI's openWindow directly.
    static let brewerOpenMainWindow = Notification.Name("brewer.openMainWindow")
}

// MARK: - App info

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

// MARK: - Formatting

enum Format {
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }

    static func installsPerYear(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let number = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        return "\(number) installs/year"
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(minutes)m \(secs)s"
    }
}

// MARK: - Version comparison

enum VersionCompare {
    /// Loose version comparison that copes with values like "1.2.3", "2026.2.0", "1.2.3,45" and "v1.10-beta".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let partsA = components(of: a)
        let partsB = components(of: b)
        let count = max(partsA.count, partsB.count)
        for index in 0..<count {
            let pa = index < partsA.count ? partsA[index] : .number(0)
            let pb = index < partsB.count ? partsB[index] : .number(0)
            switch (pa, pb) {
            case (.number(let x), .number(let y)):
                if x != y { return x < y ? .orderedAscending : .orderedDescending }
            case (.text(let x), .text(let y)):
                if x != y { return x < y ? .orderedAscending : .orderedDescending }
            case (.number, .text):
                return .orderedDescending // 1.2.0 > 1.2.beta
            case (.text, .number):
                return .orderedAscending
            }
        }
        return .orderedSame
    }

    private enum Part { case number(Int), text(String) }

    private static func components(of version: String) -> [Part] {
        var cleaned = version.lowercased()
        if cleaned.hasPrefix("v") { cleaned.removeFirst() }
        let separators = CharacterSet(charactersIn: ".-_+, ")
        return cleaned.components(separatedBy: separators)
            .filter { !$0.isEmpty }
            .map { piece in
                if let number = Int(piece) { return .number(number) }
                // Split "12abc" style pieces on the numeric prefix.
                let digits = piece.prefix { $0.isNumber }
                if !digits.isEmpty, let number = Int(digits) { return .number(number) }
                return .text(piece)
            }
    }
}

// MARK: - Disk usage

enum DiskUsage {
    /// Size of a file system path in bytes (via `du -sk`, fast for big trees).
    static func size(ofPath path: String) async -> Int64? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let result = await Shell.run("/usr/bin/du", ["-sk", path])
        guard result.succeeded,
              let first = result.stdout.split(separator: "\t").first,
              let kilobytes = Int64(first.trimmingCharacters(in: .whitespaces)) else { return nil }
        return kilobytes * 1024
    }

    static func size(ofPaths paths: [String]) async -> Int64? {
        var total: Int64 = 0
        var found = false
        for path in paths {
            if let size = await size(ofPath: path) {
                total += size
                found = true
            }
        }
        return found ? total : nil
    }
}

// MARK: - Power

enum PowerInfo {
    static func isOnACPower() async -> Bool {
        let result = await Shell.run("/usr/bin/pmset", ["-g", "batt"])
        guard result.succeeded else { return true }
        return result.stdout.contains("AC Power")
    }

    static var isLowPowerMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

// MARK: - Quarantine

enum Quarantine {
    static func isQuarantined(appPath: String) async -> Bool {
        let result = await Shell.run("/usr/bin/xattr", ["-p", "com.apple.quarantine", appPath])
        return result.succeeded && !result.stdout.isEmpty
    }

    static func remove(appPath: String) async -> ShellResult {
        await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appPath])
    }
}

// MARK: - Code signing

/// Wraps `codesign` so a downloaded update can be checked the way Sparkle does:
/// the new bundle must verify, and it must come from the same Team ID as the
/// version it replaces.
enum CodeSigning {
    static func teamIdentifier(ofApp path: String) async -> String? {
        let result = await Shell.run("/usr/bin/codesign", ["-dv", "--verbose=2", path])
        for rawLine in result.combined.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value == "not set" || value.isEmpty ? nil : value
        }
        return nil
    }

    static func verify(appAt path: String) async -> (ok: Bool, detail: String) {
        let result = await Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", path])
        return (result.succeeded, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Sparkle EdDSA signatures

enum SparkleSignature {
    enum Outcome: Equatable { case valid, invalid(String), notApplicable }

    /// Verifies a Sparkle `sparkle:edSignature` (Ed25519 over the whole archive)
    /// against the app's `SUPublicEDKey`. Both are base64.
    static func verify(fileAt url: URL, signatureBase64: String?, publicKeyBase64: String?) -> Outcome {
        guard let signatureBase64, let publicKeyBase64,
              !signatureBase64.isEmpty, !publicKeyBase64.isEmpty else { return .notApplicable }
        guard let signature = Data(base64Encoded: signatureBase64), signature.count == 64,
              let keyData = Data(base64Encoded: publicKeyBase64), keyData.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return .invalid("The update's signature or the app's public key is malformed.") }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .invalid("The downloaded file could not be read for verification.")
        }
        return publicKey.isValidSignature(signature, for: data)
            ? .valid
            : .invalid("EdDSA signature mismatch - the download may be corrupted or tampered with.")
    }
}

// MARK: - Mach-O architecture inspection

enum MachOInspector {
    /// Returns the CPU architectures contained in a binary ("arm64", "x86_64", …).
    static func architectures(ofExecutable url: URL) -> Set<String> {
        guard let fileHandle = try? FileHandle(forReadingFrom: url),
              let data = try? fileHandle.read(upToCount: 4096),
              data.count >= 8 else { return [] }
        defer { try? fileHandle.close() }

        func byte(_ index: Int) -> UInt8 { data[data.startIndex + index] }
        func bigEndian32(_ offset: Int) -> UInt32 {
            guard data.count >= offset + 4 else { return 0 }
            return (UInt32(byte(offset)) << 24) | (UInt32(byte(offset + 1)) << 16)
                | (UInt32(byte(offset + 2)) << 8) | UInt32(byte(offset + 3))
        }
        func littleEndian32(_ offset: Int) -> UInt32 {
            guard data.count >= offset + 4 else { return 0 }
            return (UInt32(byte(offset + 3)) << 24) | (UInt32(byte(offset + 2)) << 16)
                | (UInt32(byte(offset + 1)) << 8) | UInt32(byte(offset))
        }
        func name(forCPUType cpuType: UInt32) -> String? {
            switch cpuType {
            case 0x0100000C: return "arm64"
            case 0x01000007: return "x86_64"
            case 0x0000000C: return "arm"
            case 0x00000007: return "i386"
            default: return nil
            }
        }

        var archs: Set<String> = []
        let b0 = byte(0), b1 = byte(1), b2 = byte(2), b3 = byte(3)

        if b0 == 0xCA, b1 == 0xFE, b2 == 0xBA, (b3 == 0xBE || b3 == 0xBF) {
            // FAT binary (fields big-endian). 0xBF variant has 32-byte entries.
            let entrySize = b3 == 0xBE ? 20 : 32
            let count = Int(bigEndian32(4))
            for index in 0..<min(count, 16) {
                let offset = 8 + index * entrySize
                if let arch = name(forCPUType: bigEndian32(offset)) { archs.insert(arch) }
            }
        } else if b0 == 0xCF || b0 == 0xCE, b1 == 0xFA, b2 == 0xED, b3 == 0xFE {
            // Thin Mach-O, little-endian on disk.
            if let arch = name(forCPUType: littleEndian32(4)) { archs.insert(arch) }
        }
        return archs
    }
}

// MARK: - Dependency tree parsing

struct DepTreeNode: Identifiable {
    let id = UUID()
    let name: String
    var children: [DepTreeNode]?
}

enum DepsTreeParser {
    /// Parses `brew deps --tree` output (├──/└──/│ glyphs, 4-column indentation)
    /// with recursive descent over indexed lines.
    static func parse(_ text: String) -> [DepTreeNode] {
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }

        struct Line { let depth: Int; let name: String }
        let parsed: [Line] = lines.compactMap { line in
            var name = line
            var depth = 0
            // Count leading glyph groups of 4 characters ("│   ", "    ", "├── ", "└── ").
            while name.count >= 4 {
                let prefix = String(name.prefix(4))
                let isGlyph = prefix.hasPrefix("├──") || prefix.hasPrefix("└──")
                    || prefix.hasPrefix("│") || prefix == "    "
                guard isGlyph else { break }
                depth += 1
                name = String(name.dropFirst(4))
            }
            let cleaned = name.trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { return nil }
            return Line(depth: depth, name: cleaned)
        }

        var index = 0
        func buildNodes(depth: Int) -> [DepTreeNode] {
            var result: [DepTreeNode] = []
            while index < parsed.count {
                let line = parsed[index]
                if line.depth < depth { break }
                if line.depth == depth {
                    index += 1
                    let children = buildNodes(depth: depth + 1)
                    result.append(DepTreeNode(name: line.name, children: children.isEmpty ? nil : children))
                } else {
                    break
                }
            }
            return result
        }

        return buildNodes(depth: 0)
    }
}

// MARK: - Notifications

enum NotificationManager {
    /// UNUserNotificationCenter crashes when the process is not a proper app bundle
    /// (e.g. when running the bare SwiftPM binary), so guard every call.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func requestAuthorizationIfNeeded() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    /// Which sidebar page a notification click should open.
    enum Page: String {
        case updates, appUpdates, uninstaller, appStore, console

        var sidebarItem: SidebarItem? {
            switch self {
            case .updates: return .updates
            case .appUpdates: return .appUpdates
            case .uninstaller: return .uninstaller
            case .appStore: return .appStore
            case .console: return nil
            }
        }
    }

    static let pageKey = "brewer.page"

    static func post(title: String, body: String, page: Page? = nil) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let page { content.userInfo = [pageKey: page.rawValue] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - HTTP helper

enum HTTP {
    static func fetchData(_ url: URL, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Brewer/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - App icon cache

@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private var cache: [String: NSImage] = [:]

    func icon(forPath path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 64, height: 64)
        cache[path] = image
        return image
    }
}
