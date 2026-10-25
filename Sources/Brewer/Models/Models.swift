import Foundation

// MARK: - Packages

enum PackageKind: String, Codable, Hashable {
    case formula
    case cask

    var label: String { self == .formula ? "Formula" : "Cask" }
}

struct BrewPackage: Identifiable, Hashable {
    let kind: PackageKind
    let name: String            // formula name or cask token
    var displayName: String
    var desc: String?
    var homepage: String?
    var license: String?
    var tap: String?
    var installedVersion: String?
    var latestVersion: String?
    var isOutdated: Bool = false
    var isPinned: Bool = false
    var installedAsDependency: Bool = false
    var installedOnRequest: Bool = true
    var isDeprecated: Bool = false
    var deprecationReason: String?
    var isDisabled: Bool = false
    var caveats: String?
    var dependencies: [String] = []
    var buildDependencies: [String] = []
    var autoUpdates: Bool = false
    var appPath: String?
    var installedDate: Date?
    var isKegOnly: Bool = false
    var kegOnlyReason: String?
    /// Formulae only: whether the keg is linked into the prefix (`linked_keg`).
    var isLinked: Bool = true

    var id: String { Self.makeID(kind: kind, name: name) }

    /// An installed, non-keg-only formula that isn't linked - its binaries are
    /// not on PATH, which is almost always unintended.
    var isUnexpectedlyUnlinked: Bool {
        kind == .formula && isInstalled && !isLinked && !isKegOnly
    }

    static func makeID(kind: PackageKind, name: String) -> String {
        "\(kind.rawValue):\(name)"
    }

    var isInstalled: Bool { installedVersion != nil }

    var isFromThirdPartyTap: Bool {
        guard let tap else { return false }
        return !tap.hasPrefix("homebrew/")
    }

    var versionSummary: String {
        if let installed = installedVersion {
            if isOutdated, let latest = latestVersion, latest != installed {
                return "\(installed) → \(latest)"
            }
            return installed
        }
        return latestVersion ?? "-"
    }
}

// MARK: - Sidebar / scopes

enum SidebarItem: Hashable {
    case discover, collections, search
    case installed, formulae, casks, updates, appUpdates, apps, appleSilicon, adoptApps
    case appStore
    case favorites, tags, pinned, snoozed
    case taps, services, brewfile
    case health, duplicates, diagnostics, cleanup, uninstaller, history
}

enum BrowserScope: Hashable {
    case all
    case formulae
    case casks
    case updates
    case favorites
    case pinned
    case snoozed
    case tag(String)
    case collection(UUID)
}

// MARK: - Services

enum ServiceStatus: String {
    case started, stopped, none, error, scheduled, unknown

    init(raw: String?) {
        self = ServiceStatus(rawValue: raw ?? "unknown") ?? .unknown
    }

    var label: String {
        switch self {
        case .none: return "Not running"
        case .unknown: return "Unknown"
        default: return rawValue.capitalized
        }
    }
}

struct ServiceItem: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let status: ServiceStatus
    let user: String?
    let plistPath: String?
    let exitCode: Int?
    let pid: Int?

    var isRunning: Bool { status == .started || status == .scheduled }
}

// MARK: - Taps

struct TapItem: Identifiable, Hashable {
    var id: String { name }
    let name: String
    var isOfficial: Bool { name.hasPrefix("homebrew/") }
}

/// A formula or cask installed from a third-party tap, read from its install
/// receipt. `brew info --installed` leaves out everything from taps Homebrew
/// does not trust, so the receipts are the only complete list.
struct TapInstalledItem: Identifiable, Hashable, Sendable {
    let kind: PackageKind
    /// Lowercased `user/repo`, the way Homebrew stores trust entries.
    let tap: String
    /// Formula name or cask token, lowercased.
    let name: String

    init(kind: PackageKind, tap: String, name: String) {
        self.kind = kind
        self.tap = tap.lowercased()
        self.name = name.lowercased()
    }

    /// The name `brew trust --formula` / `--cask` expects.
    var fullName: String { "\(tap)/\(name)" }
    var id: String { "\(kind.rawValue):\(fullName)" }
    /// "meetily-backend", or "meetily (cask)" so a formula and a cask with the
    /// same name stay distinguishable in short lists.
    var listLabel: String { kind == .cask ? "\(name) (cask)" : name }
}

/// What Homebrew trusts beyond its official taps (`brew trust --json=v1`).
/// Homebrew stores every entry lowercased, and so does this.
struct TrustEntries: Equatable, Sendable {
    var taps: Set<String>
    var formulae: Set<String>
    var casks: Set<String>
    var commands: Set<String>

    init(taps: [String] = [], formulae: [String] = [], casks: [String] = [], commands: [String] = []) {
        self.taps = Set(taps.map { $0.lowercased() })
        self.formulae = Set(formulae.map { $0.lowercased() })
        self.casks = Set(casks.map { $0.lowercased() })
        self.commands = Set(commands.map { $0.lowercased() })
    }

    /// Whether Homebrew may load the item: its tap or the item itself is trusted.
    func trusts(_ item: TapInstalledItem) -> Bool {
        if taps.contains(item.tap) { return true }
        return (item.kind == .formula ? formulae : casks).contains(item.fullName)
    }

    /// Whether any single formula, cask or command of `tap` is trusted.
    func hasItemEntries(forTap tap: String) -> Bool {
        let prefix = tap.lowercased() + "/"
        return [formulae, casks, commands].contains { entries in
            entries.contains { $0.hasPrefix(prefix) }
        }
    }
}

/// How far Homebrew trusts a tap, as the Taps page presents it.
enum TapTrustState: Equatable {
    /// An official tap, or a Homebrew release without tap trust.
    case notRequired
    /// The whole tap is trusted.
    case wholeTap
    /// Installed packages that still need trust; Homebrew ignores them until then.
    case installedUntrusted([TapInstalledItem])
    /// Every installed package is trusted on its own; the tap itself is not.
    case installedTrusted([TapInstalledItem])
    /// Nothing is installed from the tap and the tap is not trusted.
    /// `partly`: some of its formulae, casks or commands are trusted.
    case untrusted(partly: Bool)

    /// Whether trusting the whole tap would still change anything.
    var allowsWholeTapTrust: Bool {
        switch self {
        case .installedUntrusted, .installedTrusted, .untrusted: return true
        case .notRequired, .wholeTap: return false
        }
    }
}

// MARK: - History

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var title: String
    var command: String
    var succeeded: Bool
    var durationSeconds: Double
    /// Last lines of output, kept for failed or cancelled operations so they can
    /// still be diagnosed after the console was cleared or the app quit.
    var output: [String]?
}

// MARK: - Diagnostics (Homebrew 7 structured doctor and vulnerability scan)

struct DoctorFinding: Identifiable, Hashable {
    let id: Int
    let title: String
    let details: String?
    let affects: [String]
    let remediation: String?
    let commands: [String]
    let links: [URL]
}

struct Advisory: Identifiable, Hashable {
    enum Severity: Int, Comparable, Hashable {
        case unknown = 0, low, medium, high, critical

        init(raw: String?) {
            switch raw?.uppercased() {
            case "CRITICAL": self = .critical
            case "HIGH": self = .high
            case "MEDIUM", "MODERATE": self = .medium
            case "LOW": self = .low
            default: self = .unknown
            }
        }

        var label: String {
            switch self {
            case .critical: return "Critical"
            case .high: return "High"
            case .medium: return "Medium"
            case .low: return "Low"
            case .unknown: return "Unrated"
            }
        }

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let severity: Severity
    let summary: String
    let hasUpstreamFix: Bool

    var url: URL? {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            .flatMap { URL(string: "https://osv.dev/vulnerability/\($0)") }
    }
}

struct VulnerablePackage: Identifiable, Hashable {
    var id: String { formula }
    let formula: String
    let version: String?
    let advisories: [Advisory]
    /// Advisories Homebrew has already fixed with a backported patch.
    let patchedCount: Int

    var highestSeverity: Advisory.Severity {
        advisories.map(\.severity).max() ?? .unknown
    }
}

// MARK: - User metadata

struct PackageCollection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var packageIDs: [String] = []
}

struct SnoozeInfo: Codable, Hashable {
    var until: Date?
    var version: String?
}

// MARK: - Cleanup

struct CleanupItem: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let bytes: Int64?

    var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct CleanupReport {
    var items: [CleanupItem]
    var approximateBytes: Int64?
    var raw: String
}

// MARK: - Scanned applications

struct ScannedApp: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bundleID: String?
    let shortVersion: String?
    /// CFBundleVersion - the build number Sparkle actually compares.
    let bundleVersion: String?
    let executableURL: URL?
    let sparkleFeedURL: URL?
    /// SUPublicEDKey (base64 Ed25519 key) when the app verifies its own updates.
    let sparklePublicKey: String?
    let hasMASReceipt: Bool

    /// Apple's own software (never adopt, never uninstall).
    var isAppleApp: Bool { bundleID?.hasPrefix("com.apple.") ?? false }

    /// Setapp editions keep the vendor's regular update feed in their
    /// Info.plist, but Setapp updates them itself - replacing one with the
    /// vendor's build would swap in an unlicensed or trial edition.
    var isSetappApp: Bool {
        (bundleID?.lowercased().hasSuffix("-setapp") ?? false) || url.path.contains("/Applications/Setapp/")
    }

    /// True for apps sitting directly in /Applications or ~/Applications
    /// (the only locations `brew install --adopt` can take over).
    var isTopLevel: Bool {
        let parent = url.deletingLastPathComponent().path
        return parent == "/Applications" || parent == NSHomeDirectory() + "/Applications"
    }
}

struct SparkleUpdate: Identifiable, Hashable {
    var id: String { appPath }
    let appName: String
    let appPath: String
    let currentVersion: String
    let latestVersion: String
    let downloadURL: URL?
    let releaseNotesURL: URL?
    var notesHTML: String?
    var enclosureBytes: Int64?
    var managedByCask: String?
    var currentBuild: String?
    var latestBuild: String?
    var edSignature: String?
    var publicKey: String?

    /// Sparkle's own rule: when both sides carry a build number (CFBundleVersion /
    /// sparkle:version) that decides; the marketing version is only a fallback.
    var hasUpdate: Bool {
        Self.isUpdate(currentVersion: currentVersion, latestVersion: latestVersion,
                      currentBuild: currentBuild, latestBuild: latestBuild)
    }

    /// A rebuild of the same marketing version ("4.0.10" build 4165 -> 4166)
    /// would otherwise read as "4.0.10 -> 4.0.10", so the build is shown then.
    private var showsBuilds: Bool {
        guard let currentBuild, let latestBuild, currentBuild != latestBuild else { return false }
        return VersionCompare.compare(currentVersion, latestVersion) == .orderedSame
    }

    var currentVersionDisplay: String {
        showsBuilds ? "\(currentVersion) (\(currentBuild ?? ""))" : currentVersion
    }

    var latestVersionDisplay: String {
        showsBuilds ? "\(latestVersion) (\(latestBuild ?? ""))" : latestVersion
    }

    static func isUpdate(currentVersion: String, latestVersion: String,
                         currentBuild: String?, latestBuild: String?) -> Bool {
        if let latestBuild, let currentBuild, !latestBuild.isEmpty, !currentBuild.isEmpty {
            return VersionCompare.isNewer(latestBuild, than: currentBuild)
        }
        return VersionCompare.isNewer(latestVersion, than: currentVersion)
    }
}

// MARK: - Full app inventory (MacUpdater-style)

enum AppSource: String, CaseIterable, Hashable {
    case homebrew = "Homebrew"
    case appStore = "App Store"
    case setapp = "Setapp"
    case sparkle = "Sparkle"
    case manual = "Manual"

    /// Install source for an app that no Homebrew cask owns.
    static func detect(for app: ScannedApp) -> AppSource {
        if app.hasMASReceipt { return .appStore }
        if app.isSetappApp { return .setapp }
        if app.sparkleFeedURL != nil { return .sparkle }
        return .manual
    }
}

struct InventoryApp: Identifiable, Hashable {
    var id: String { app.id }
    let app: ScannedApp
    let source: AppSource
    let caskToken: String?
    var archs: Set<String> = []
    var sizeBytes: Int64?

    var isIntelOnly: Bool { archs.contains("x86_64") && !archs.contains("arm64") }
}

// MARK: - Deep uninstall (AppCleaner-style)

enum LeftoverConfidence: Hashable {
    case bundleID   // matched the app's bundle identifier - safe to remove
    case nameMatch  // matched only by app name - review before removing
}

struct LeftoverItem: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let kind: String
    let confidence: LeftoverConfidence
    var sizeBytes: Int64?

    var isSystemDomain: Bool { path.hasPrefix("/Library") }
    var displayName: String { URL(fileURLWithPath: path).lastPathComponent }
}

// MARK: - App update backups (MacUpdater-style)

struct BackupEntry: Identifiable, Hashable {
    var id: String { path }
    let appName: String
    let version: String
    let date: Date
    let path: String        // directory containing the backed-up .app
    let appBundlePath: String
    let originalPath: String?
    var sizeBytes: Int64?
}

enum AdoptState: Hashable {
    case idle
    case searching
    case adoptable(token: String)
    case appStore
    case noMatch
}

struct AdoptRow: Identifiable, Hashable {
    var id: String { app.id }
    let app: ScannedApp
    var candidates: [String] = []
    var state: AdoptState = .idle
}

enum ArchClass: String {
    case universal = "Universal"
    case armOnly = "Apple Silicon"
    case intelOnly = "Intel only"
    case unknown = "Unknown"
}

struct ArchInfo: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let archs: Set<String>
    let cls: ArchClass
}

// MARK: - Mac App Store

struct MasApp: Identifiable, Hashable {
    var id: String { adamID }
    let adamID: String
    let name: String
    let version: String
    var newVersion: String?
}
