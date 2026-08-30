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

    // MARK: Maintenance

    func doctor() async -> ShellResult {
        await Shell.runBrew(["doctor"])
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

    func multiVersionFormulae() async -> [(name: String, versions: [String])] {
        let result = await Shell.runBrew(["list", "--formula", "--versions"])
        guard result.succeeded else { return [] }
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
