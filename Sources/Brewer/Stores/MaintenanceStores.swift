import Foundation
import Observation

// MARK: - HealthStore

@MainActor
@Observable
final class HealthStore {

    var doctorRaw: String?
    var doctorWarnings: [String] = []
    var doctorRunning = false
    var doctorLastRun: Date?

    var cachePath: String = ""
    var cacheBytes: Int64?
    var cleanupReport: CleanupReport?
    var orphans: [String]?
    var isRefreshing = false
    var lastRefreshed: Date?

    private let client = BrewClient()
    private unowned let console: TaskConsole

    init(console: TaskConsole) {
        self.console = console
    }

    // MARK: Metrics

    func refreshMetrics() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if cachePath.isEmpty {
            cachePath = await client.cachePath()
        }
        async let cacheSizeTask = DiskUsage.size(ofPath: cachePath)
        async let cleanupTask = client.cleanupDryRun()
        async let orphanTask = client.autoremoveDryRun()

        cacheBytes = await cacheSizeTask
        cleanupReport = await cleanupTask
        orphans = await orphanTask
        lastRefreshed = Date()
    }

    // MARK: Doctor

    func runDoctor() async {
        guard !doctorRunning else { return }
        doctorRunning = true
        defer { doctorRunning = false }
        let result = await client.doctor()
        var text = result.combined
        if text.isEmpty {
            text = result.succeeded ? "Your system is ready to brew." : "brew doctor exited with code \(result.exitCode)."
        }
        doctorRaw = text
        doctorWarnings = Self.parseWarnings(from: text)
        doctorLastRun = Date()
    }

    nonisolated static func parseWarnings(from output: String) -> [String] {
        var warnings: [String] = []
        var current: [String] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("Warning:") || line.hasPrefix("Error:") {
                if !current.isEmpty { warnings.append(current.joined(separator: "\n")) }
                current = [line]
            } else if !current.isEmpty {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    warnings.append(current.joined(separator: "\n"))
                    current = []
                } else {
                    current.append(line)
                }
            }
        }
        if !current.isEmpty { warnings.append(current.joined(separator: "\n")) }
        return warnings
    }

    // MARK: Actions

    func clearCache(scrub: Bool) async {
        var args = ["cleanup", "--prune=all"]
        if scrub { args.append("-s") }
        await console.runBrew(title: "Clean up Homebrew files", arguments: args)
        await refreshMetrics()
    }

    func removeOrphans() async {
        await console.runBrew(title: "Remove orphaned packages", arguments: ["autoremove"])
        await refreshMetrics()
    }

    // MARK: Score

    func healthScore(outdatedCount: Int, issueCount: Int) -> Int {
        var score = 100.0
        score -= min(50.0, Double(outdatedCount) * 1.2)
        score -= min(25.0, Double(issueCount) * 4.0)
        score -= min(15.0, Double(orphans?.count ?? 0) * 2.0)
        if let cacheBytes, cacheBytes > 2_000_000_000 { score -= 10 }
        return max(0, min(100, Int(score.rounded())))
    }
}

// MARK: - DuplicatesStore

@MainActor
@Observable
final class DuplicatesStore {

    struct MultiVersionKeg: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let versions: [String]
    }

    struct Overlap: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let detail: String
    }

    var multiVersionKegs: [MultiVersionKeg] = []
    var overlaps: [Overlap] = []
    var isLoading = false
    var lastScan: Date?
    var errorMessage: String?

    private let client = BrewClient()
    private unowned let console: TaskConsole

    init(console: TaskConsole) {
        self.console = console
    }

    func refresh(casks: [BrewPackage], masApps: [MasApp]) async {
        isLoading = true
        defer { isLoading = false }

        if let kegs = await client.multiVersionFormulae() {
            multiVersionKegs = kegs.map { MultiVersionKeg(name: $0.name, versions: $0.versions) }
            errorMessage = nil
        } else {
            errorMessage = "brew could not list versions — see the console (a pending Xcode license can cause this)."
        }

        // Apps managed both by Homebrew and the App Store are duplicate sources of truth.
        var found: [Overlap] = []
        let masNames = Set(masApps.map { $0.name.lowercased() })
        for cask in casks {
            let display = cask.displayName.lowercased()
            if masNames.contains(display) {
                found.append(Overlap(
                    name: cask.displayName,
                    detail: "Installed as Homebrew cask “\(cask.name)” and via the Mac App Store."
                ))
            }
        }
        overlaps = found
        lastScan = Date()
    }

    func cleanOldVersions(of name: String) async {
        await console.runBrew(title: "Clean old versions of \(name)", arguments: ["cleanup", name])
        if let kegs = await client.multiVersionFormulae() {
            multiVersionKegs = kegs.map { MultiVersionKeg(name: $0.name, versions: $0.versions) }
            errorMessage = nil
        }
    }
}
