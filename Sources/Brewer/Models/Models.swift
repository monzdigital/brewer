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

    var id: String { Self.makeID(kind: kind, name: name) }

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
        return latestVersion ?? "—"
    }
}

// MARK: - Sidebar / scopes

enum SidebarItem: Hashable {
    case discover, collections, search
    case installed, formulae, casks, updates, appUpdates, appleSilicon, adoptApps
    case appStore
    case favorites, tags, pinned, snoozed
    case taps, services, brewfile
    case health, duplicates, diagnostics, cleanup, history
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

// MARK: - History

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var title: String
    var command: String
    var succeeded: Bool
    var durationSeconds: Double
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
    let executableURL: URL?
    let sparkleFeedURL: URL?
    let hasMASReceipt: Bool
}

struct SparkleUpdate: Identifiable, Hashable {
    var id: String { appPath }
    let appName: String
    let appPath: String
    let currentVersion: String
    let latestVersion: String
    let downloadURL: URL?
    let releaseNotesURL: URL?
    let managedByCask: String?

    var hasUpdate: Bool {
        VersionCompare.isNewer(latestVersion, than: currentVersion)
    }
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
