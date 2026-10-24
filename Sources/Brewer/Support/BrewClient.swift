import Foundation

enum BrewError: LocalizedError {
    case brewNotFound
    case commandFailed(command: String, output: String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .brewNotFound:
            return "Homebrew was not found. Install it from https://brew.sh or set a custom path in Settings."
        case .commandFailed(let command, let output):
            return "`\(command)` failed: \(output.prefix(500))"
        case .decodeFailed(let detail):
            return "Could not read Homebrew's response: \(detail)"
        }
    }
}

/// Read-only, typed access to Homebrew. Mutating commands go through TaskConsole instead
/// so the user always sees live output.
struct BrewClient: Sendable {

    private var env: BrewEnvironment { BrewEnvironment.current }

    // MARK: Installed packages

    func installedSnapshot() async throws -> InfoV2Response {
        guard env.exists else { throw BrewError.brewNotFound }
        let result = await Shell.runBrew(["info", "--json=v2", "--installed"])
        guard result.succeeded else {
            throw BrewError.commandFailed(command: "brew info --json=v2 --installed", output: result.stderr)
        }
        return try decodeInfo(result.stdout)
    }

    func infoJSON(formulae: [String] = [], casks: [String] = []) async -> InfoV2Response {
        var combined = InfoV2Response(formulae: [], casks: [])
        if !formulae.isEmpty {
            let result = await Shell.runBrew(["info", "--json=v2", "--formula"] + formulae)
            if result.succeeded, let response = try? decodeInfo(result.stdout) {
                combined.formulae = response.formulae
            }
        }
        if !casks.isEmpty {
            let result = await Shell.runBrew(["info", "--json=v2", "--cask"] + casks)
            if result.succeeded, let response = try? decodeInfo(result.stdout) {
                combined.casks = response.casks
            }
        }
        return combined
    }

    private func decodeInfo(_ json: String) throws -> InfoV2Response {
        guard let data = json.data(using: .utf8) else { throw BrewError.decodeFailed("empty output") }
        do {
            return try JSONDecoder().decode(InfoV2Response.self, from: data)
        } catch {
            throw BrewError.decodeFailed(String(describing: error))
        }
    }

    /// Casks that are outdated once self-updating apps are included
    /// (`--greedy-auto-updates`). Empty when the command fails.
    func outdatedCasksGreedy() async -> [OutdatedEntryJSON] {
        let result = await Shell.runBrew(["outdated", "--cask", "--greedy-auto-updates", "--json=v2"])
        guard result.succeeded, let data = result.stdout.data(using: .utf8),
              let response = try? JSONDecoder().decode(OutdatedResponse.self, from: data) else { return [] }
        return response.casks ?? []
    }

    // MARK: Search

    func search(query: String) async -> (formulae: [String], casks: [String]) {
        async let formulaResult = Shell.runBrew(["search", "--formula", "--quiet", query])
        async let caskResult = Shell.runBrew(["search", "--cask", "--quiet", query])
        let (fRes, cRes) = await (formulaResult, caskResult)

        func names(from result: ShellResult) -> [String] {
            guard result.succeeded else { return [] }
            return result.stdout
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("==>") }
        }
        return (names(from: fRes), names(from: cRes))
    }

    // MARK: Services

    func servicesList() async throws -> [ServiceJSON] {
        let result = await Shell.runBrew(["services", "list", "--json"])
        guard result.succeeded, let data = result.stdout.data(using: .utf8) else {
            throw BrewError.commandFailed(command: "brew services list", output: result.stderr)
        }
        do {
            return try JSONDecoder().decode([ServiceJSON].self, from: data)
        } catch {
            throw BrewError.decodeFailed(String(describing: error))
        }
    }

    // MARK: Taps

    func tapNames() async -> [String] {
        let result = await Shell.runBrew(["tap"])
        guard result.succeeded else { return [] }
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    func tapInfo(_ name: String) async -> TapInfoJSON? {
        let result = await Shell.runBrew(["tap-info", "--json", name])
        guard result.succeeded, let data = result.stdout.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode([TapInfoJSON].self, from: data))?.first
    }

    /// Every installed tap in one call (Homebrew 7 collects these concurrently);
    /// includes the `trusted` flag on Homebrew 7+.
    func installedTapsInfo() async -> [TapInfoJSON]? {
        let result = await Shell.runBrew(["tap-info", "--installed", "--json=v1"])
        guard result.succeeded, let data = result.stdout.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([TapInfoJSON].self, from: data)
    }

    /// "Homebrew 7.0.10" -> 7; 0 when brew can't be queried.
    func brewMajorVersion() async -> Int {
        guard let version = await brewVersion() else { return 0 }
        return Self.majorVersion(ofBrewVersionLine: version)
    }

    /// Homebrew 6 only loads formulae/casks from third-party taps the user has
    /// explicitly trusted (`brew trust --tap`).
    func supportsTapTrust() async -> Bool {
        guard let version = await brewVersion() else { return false }
        return Self.majorVersion(ofBrewVersionLine: version) >= 6
    }

    nonisolated static func majorVersion(ofBrewVersionLine line: String) -> Int {
        // "Homebrew 6.0.1" or "Homebrew 6.0.1-12-gabcdef"
        let token = line.split(separator: " ").last.map(String.init) ?? ""
        return Int(token.split(whereSeparator: { $0 == "." || $0 == "-" }).first ?? "") ?? 0
    }

    /// Taps listed in Homebrew's trust store (~/.homebrew/trust.json, or
    /// $XDG_CONFIG_HOME/homebrew/trust.json).
    nonisolated static func trustedTapNames() -> Set<String> {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["XDG_CONFIG_HOME"].map { $0 + "/homebrew" } ?? (NSHomeDirectory() + "/.homebrew")
        guard let data = FileManager.default.contents(atPath: directory + "/trust.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let taps = json["trustedtaps"] as? [String] else { return [] }
        return Set(taps.map { $0.lowercased() })
    }

    // MARK: Maintenance

    func doctor() async -> ShellResult {
        await Shell.runBrew(["doctor"])
    }

    /// Structured doctor findings (Homebrew 7+). nil when unsupported or
    /// unreadable, so callers fall back to the text output. doctor exits 1
    /// whenever it has findings, so the payload decides, not the exit code.
    func doctorReport() async -> DoctorReportJSON? {
        let result = await Shell.runBrew(["doctor", "--json"])
        guard let data = result.stdout.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(DoctorReportJSON.self, from: data)
    }

    /// `brew vulns --json` (Homebrew 7+): checks installed formulae against
    /// OSV.dev. It exits 1 when it finds anything, so the payload decides.
    func vulnerabilityReport() async -> (report: VulnsReportJSON?, error: String?) {
        let result = await Shell.runBrew(["vulns", "--json"])
        if let data = result.stdout.data(using: .utf8), !data.isEmpty,
           let report = try? JSONDecoder().decode(VulnsReportJSON.self, from: data) {
            return (report, nil)
        }
        let firstError = result.stderr.split(separator: "\n").first { $0.hasPrefix("Error") }.map(String.init)
        return (nil, firstError ?? "brew vulns failed (exit \(result.exitCode)).")
    }

    func cleanupDryRun() async -> CleanupReport {
        let result = await Shell.runBrew(["cleanup", "--dry-run", "--prune=all"])
        var items: [CleanupItem] = []
        var approximate: Int64?
        for rawLine in result.combined.split(separator: "\n") {
            let line = String(rawLine)
            if line.hasPrefix("Would remove: ") {
                let payload = String(line.dropFirst("Would remove: ".count))
                var path = payload
                var bytes: Int64?
                if let open = payload.lastIndex(of: "("), let close = payload.lastIndex(of: ")"), open < close {
                    path = String(payload[..<open]).trimmingCharacters(in: .whitespaces)
                    let sizeText = String(payload[payload.index(after: open)..<close])
                    bytes = Self.parseByteString(sizeText)
                }
                items.append(CleanupItem(path: path, bytes: bytes))
            } else if line.contains("would free approximately") {
                if let range = line.range(of: "approximately ") {
                    let tail = line[range.upperBound...]
                    let sizeText = tail.split(separator: " ").prefix(1).joined()
                    approximate = Self.parseByteString(String(sizeText))
                }
            }
        }
        if approximate == nil {
            let known = items.compactMap(\.bytes)
            if !known.isEmpty { approximate = known.reduce(0, +) }
        }
        return CleanupReport(items: items, approximateBytes: approximate, raw: result.combined)
    }

    static func parseByteString(_ text: String) -> Int64? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).uppercased()
        let units: [(String, Double)] = [
            ("TB", 1_000_000_000_000), ("GB", 1_000_000_000), ("MB", 1_000_000),
            ("KB", 1_000), ("B", 1)
        ]
        for (suffix, multiplier) in units where cleaned.hasSuffix(suffix) {
            let numberText = cleaned.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            if let value = Double(numberText.replacingOccurrences(of: ",", with: ".")) {
                return Int64(value * multiplier)
            }
        }
        return nil
    }

    func autoremoveDryRun() async -> [String] {
        let result = await Shell.runBrew(["autoremove", "--dry-run"])
        var names: [String] = []
        var collecting = false
        for rawLine in result.combined.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("==>") {
                collecting = line.contains("autoremove") || line.contains("unneeded")
                continue
            }
            if collecting && !line.isEmpty && !line.contains(" ") {
                names.append(line)
            }
        }
        return names
    }

    /// Returns nil when the command itself failed (e.g. Xcode license not accepted),
    /// so callers can keep their previous data instead of showing a false "all clean".
    func multiVersionFormulae() async -> [(name: String, versions: [String])]? {
        let result = await Shell.runBrew(["list", "--formula", "--versions"])
        guard result.succeeded else { return nil }
        return result.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count > 2 else { return nil }
            return (name: parts[0], versions: Array(parts.dropFirst()))
        }
    }

    // MARK: Dependencies

    func depsTreeText(for name: String, cask: Bool) async -> String {
        var args = ["deps", "--tree"]
        if cask { args.append("--cask") }
        args.append(name)
        let result = await Shell.runBrew(args)
        return result.succeeded ? result.stdout : result.combined
    }

    func dependents(of name: String) async -> [String] {
        let result = await Shell.runBrew(["uses", "--installed", name])
        guard result.succeeded else { return [] }
        return result.stdout.split(whereSeparator: { $0 == "\n" || $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }

    // MARK: Misc

    func brewVersion() async -> String? {
        let result = await Shell.runBrew(["--version"])
        guard result.succeeded else { return nil }
        return result.stdout.split(separator: "\n").first.map(String.init)
    }

    func cachePath() async -> String {
        let result = await Shell.runBrew(["--cache"])
        if result.succeeded, !result.stdout.isEmpty {
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return NSHomeDirectory() + "/Library/Caches/Homebrew"
    }

    func bundleDumpPreview() async -> String? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("brewer-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let result = await Shell.runBrew(["bundle", "dump", "--force", "--file", tempURL.path])
        guard result.succeeded else { return nil }
        return try? String(contentsOf: tempURL, encoding: .utf8)
    }

    func bundleCheck(file: String?) async -> String {
        var args = ["bundle", "check", "--verbose"]
        if let file { args += ["--file", file] }
        let result = await Shell.runBrew(args)
        return result.combined.isEmpty ? "brew bundle check produced no output." : result.combined
    }
}
