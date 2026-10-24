import Foundation
import Observation

// MARK: - HealthStore

@MainActor
@Observable
final class HealthStore {

    // brew doctor: structured findings on Homebrew 7+, parsed text otherwise.
    var doctorRaw: String?
    var doctorWarnings: [String] = []
    var doctorFindings: [DoctorFinding] = []
    var doctorIsStructured = false
    var doctorRunning = false
    var doctorLastRun: Date?

    // brew vulns (Homebrew 7+). User-initiated: it sends installed formula
    // names and versions to OSV.dev.
    var vulnerablePackages: [VulnerablePackage] = []
    var vulnsRunning = false
    var vulnsLastRun: Date?
    var vulnsError: String?
    var vulnsScannedCount: Int?
    var vulnsComplete = true
    var vulnsUnscanned: [String: String] = [:]

    /// Homebrew's major version, detected on first use (0 = unknown).
    var brewMajor = 0

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

    var supportsStructuredDiagnostics: Bool { brewMajor >= 7 }

    /// Number of doctor issues, whichever output format produced them.
    var issueCount: Int { doctorIsStructured ? doctorFindings.count : doctorWarnings.count }

    func detectBrewMajorIfNeeded() async {
        if brewMajor == 0 { brewMajor = await client.brewMajorVersion() }
    }

    func runDoctor() async {
        guard !doctorRunning else { return }
        doctorRunning = true
        defer { doctorRunning = false }
        await detectBrewMajorIfNeeded()

        if supportsStructuredDiagnostics, let report = await client.doctorReport() {
            doctorFindings = Self.findings(from: report)
            doctorWarnings = doctorFindings.map(\.title)
            doctorIsStructured = true
            doctorRaw = nil
        } else {
            let result = await client.doctor()
            var text = result.combined
            if text.isEmpty {
                text = result.succeeded ? "Your system is ready to brew." : "brew doctor exited with code \(result.exitCode)."
            }
            doctorRaw = text
            doctorWarnings = Self.parseWarnings(from: text)
            doctorFindings = []
            doctorIsStructured = false
        }
        doctorLastRun = Date()
    }

    nonisolated static func findings(from report: DoctorReportJSON) -> [DoctorFinding] {
        report.findings.enumerated().compactMap { index, finding in
            let text = (finding.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let title = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? text
            let details = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let remediation = (finding.remediation?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return DoctorFinding(
                id: index,
                title: title,
                details: details.isEmpty ? nil : details,
                affects: finding.affects?.values ?? [],
                remediation: remediation.isEmpty ? nil : remediation,
                commands: (finding.remediation?.commands?.values ?? []).filter { !$0.isEmpty },
                links: (finding.links?.values ?? []).compactMap(URL.init(string:))
            )
        }
    }

    /// Arguments for a doctor remediation command Brewer may run for the user:
    /// only plain `brew …` invocations, never anything a shell would interpret.
    nonisolated static func brewArguments(forRemediation command: String) -> [String]? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("brew ") else { return nil }
        let shellSyntax = CharacterSet(charactersIn: ";|&$`<>()\\\"'*?{}[]~!#\n")
        guard trimmed.rangeOfCharacter(from: shellSyntax) == nil else { return nil }
        let parts = trimmed.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        return Array(parts.dropFirst())
    }

    func runRemediation(_ command: String) async {
        guard let arguments = Self.brewArguments(forRemediation: command) else { return }
        let title = command.count <= 48 ? "Doctor fix: \(command)" : "Doctor fix: \(command.prefix(45))…"
        await console.runBrew(title: title, arguments: arguments)
        await runDoctor()
    }

    // MARK: Vulnerabilities (brew vulns)

    var advisoryCount: Int {
        vulnerablePackages.reduce(0) { $0 + $1.advisories.count }
    }

    var seriousAdvisoryCount: Int {
        vulnerablePackages.reduce(0) { total, package in
            total + package.advisories.filter { $0.severity >= .high }.count
        }
    }

    func runVulnerabilityScan() async {
        guard !vulnsRunning else { return }
        await detectBrewMajorIfNeeded()
        guard supportsStructuredDiagnostics else { return }
        vulnsRunning = true
        defer { vulnsRunning = false }

        let (report, error) = await client.vulnerabilityReport()
        if let report {
            vulnerablePackages = Self.vulnerablePackages(from: report)
            vulnsScannedCount = report.checked
            vulnsComplete = report.complete ?? true
            vulnsUnscanned = report.unscanned_formulae ?? [:]
            vulnsError = nil
        } else {
            vulnsError = error
        }
        vulnsLastRun = Date()
    }

    nonisolated static func vulnerablePackages(from report: VulnsReportJSON) -> [VulnerablePackage] {
        report.findings.compactMap { finding -> VulnerablePackage? in
            let advisories = (finding.vulnerabilities ?? [])
                .map { vulnerability in
                    Advisory(
                        id: vulnerability.id,
                        severity: Advisory.Severity(raw: vulnerability.severity),
                        summary: vulnerability.summary ?? "",
                        hasUpstreamFix: !(vulnerability.fixed_versions ?? []).isEmpty
                    )
                }
                .sorted { $0.severity > $1.severity }
            guard !advisories.isEmpty else { return nil }
            return VulnerablePackage(
                formula: finding.formula,
                version: finding.version,
                advisories: advisories,
                patchedCount: finding.patched?.count ?? 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.highestSeverity != rhs.highestSeverity { return lhs.highestSeverity > rhs.highestSeverity }
            if lhs.advisories.count != rhs.advisories.count { return lhs.advisories.count > rhs.advisories.count }
            return lhs.formula < rhs.formula
        }
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
        // Known vulnerabilities from the last scan. Most are unrated and many
        // have no fix yet, so only high/critical ones weigh much, capped so an
        // up-to-date Mac is never scored as broken for upstream issues.
        let serious = Double(seriousAdvisoryCount)
        let other = Double(advisoryCount - seriousAdvisoryCount)
        score -= min(10.0, serious * 3.0 + other * 0.5)
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
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        if let kegs = await client.multiVersionFormulae() {
            multiVersionKegs = kegs.map { MultiVersionKeg(name: $0.name, versions: $0.versions) }
            errorMessage = nil
        } else {
            errorMessage = "brew could not list versions - see the console (a pending Xcode license can cause this)."
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
