import Foundation
import Observation

// MARK: - AppUpdatesStore (Sparkle feeds)

@MainActor
@Observable
final class AppUpdatesStore {

    var results: [SparkleUpdate] = []
    var isScanning = false
    var lastScan: Date?
    var checkedCount = 0

    var availableUpdates: [SparkleUpdate] {
        results.filter(\.hasUpdate)
    }

    /// Scans apps that ship a Sparkle feed and compares their version against the appcast.
    func scan(casks: [BrewPackage]) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let caskByAppPath: [String: String] = Dictionary(
            uniqueKeysWithValues: casks.compactMap { cask in
                cask.appPath.map { ($0, cask.name) }
            }
        )

        let apps = await Task.detached(priority: .utility) {
            AppScanner.scanApplications()
        }.value

        let sparkleApps = apps.filter { $0.sparkleFeedURL != nil && $0.shortVersion != nil }
        checkedCount = sparkleApps.count
        var found: [SparkleUpdate] = []

        // Check feeds with limited concurrency.
        for chunk in sparkleApps.chunked(into: 6) {
            await withTaskGroup(of: SparkleUpdate?.self) { group in
                for app in chunk {
                    group.addTask {
                        guard let feed = app.sparkleFeedURL,
                              let current = app.shortVersion,
                              let latest = await AppScanner.latestAppcastVersion(feedURL: feed)
                        else { return nil }
                        return SparkleUpdate(
                            appName: app.name,
                            appPath: app.url.path,
                            currentVersion: current,
                            latestVersion: latest.version,
                            downloadURL: latest.downloadURL,
                            releaseNotesURL: latest.releaseNotesURL,
                            notesHTML: latest.notesHTML,
                            enclosureBytes: latest.enclosureBytes,
                            managedByCask: nil
                        )
                    }
                }
                for await update in group {
                    if let update { found.append(update) }
                }
            }
        }

        results = found
            .map { update in
                var copy = update
                copy.managedByCask = caskByAppPath[update.appPath]
                return copy
            }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        lastScan = Date()
    }
}

// MARK: - AdoptStore

@MainActor
@Observable
final class AdoptStore {

    var rows: [AdoptRow] = []
    var isScanning = false
    var lastScan: Date?

    private let client = BrewClient()
    private unowned let console: TaskConsole
    private unowned let packages: PackageStore

    init(console: TaskConsole, packages: PackageStore) {
        self.console = console
        self.packages = packages
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let managedPaths = Set(packages.casks.compactMap(\.appPath))
        let apps = await Task.detached(priority: .utility) {
            AppScanner.scanApplications()
        }.value

        var newRows: [AdoptRow] = []
        for app in apps {
            guard !managedPaths.contains(app.url.path) else { continue }
            var row = AdoptRow(app: app)
            if app.hasMASReceipt {
                row.state = .appStore
            }
            newRows.append(row)
        }
        rows = newRows
        lastScan = Date()

        // Verify token guesses against the Homebrew API, a few at a time.
        let candidates = rows.enumerated().filter { $0.element.state == .idle }
        for chunk in candidates.chunked(into: 6) {
            await withTaskGroup(of: (Int, AdoptState, [String]).self) { group in
                for (index, row) in chunk {
                    let guess = Self.guessToken(for: row.app.name)
                    group.addTask {
                        guard let url = URL(string: "https://formulae.brew.sh/api/cask/\(guess).json"),
                              (try? await HTTP.fetchData(url, timeout: 10)) != nil
                        else {
                            return (index, .noMatch, [])
                        }
                        return (index, .adoptable(token: guess), [guess])
                    }
                }
                for await (index, state, tokens) in group {
                    guard index < rows.count else { continue }
                    rows[index].state = state
                    rows[index].candidates = tokens
                }
            }
        }
    }

    nonisolated static func guessToken(for appName: String) -> String {
        appName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// Uses `brew search --cask` to fill in candidates when the direct guess failed.
    func searchCandidates(forRowWithID id: String) async {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].state = .searching
        let query = rows[index].app.name
        let (_, casks) = await client.search(query: query)
        guard let currentIndex = rows.firstIndex(where: { $0.id == id }) else { return }
        if let first = casks.first {
            rows[currentIndex].candidates = Array(casks.prefix(5))
            rows[currentIndex].state = .adoptable(token: first)
        } else {
            rows[currentIndex].candidates = []
            rows[currentIndex].state = .noMatch
        }
    }

    func adopt(rowID: String, token: String) async {
        await console.runBrew(
            title: "Adopt \(token)",
            arguments: ["install", "--cask", "--adopt", token]
        )
        await packages.refresh()
        await scan()
    }
}

// MARK: - ArchitectureStore

@MainActor
@Observable
final class ArchitectureStore {

    var results: [ArchInfo] = []
    var isScanning = false
    var lastScan: Date?

    var intelOnly: [ArchInfo] { results.filter { $0.cls == .intelOnly } }
    var universal: [ArchInfo] { results.filter { $0.cls == .universal } }
    var armOnly: [ArchInfo] { results.filter { $0.cls == .armOnly } }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let scanned = await Task.detached(priority: .utility) { () -> [ArchInfo] in
            let apps = AppScanner.scanApplications()
            return apps.compactMap { app in
                guard let executable = app.executableURL else { return nil }
                let archs = MachOInspector.architectures(ofExecutable: executable)
                let cls: ArchClass
                if archs.contains("arm64") && archs.contains("x86_64") {
                    cls = .universal
                } else if archs.contains("arm64") {
                    cls = .armOnly
                } else if archs.contains("x86_64") {
                    cls = .intelOnly
                } else {
                    cls = .unknown
                }
                return ArchInfo(name: app.name, path: app.url.path, archs: archs, cls: cls)
            }
        }.value

        results = scanned
        lastScan = Date()
    }
}

// MARK: - MasStore (Mac App Store CLI)

@MainActor
@Observable
final class MasStore {

    var isAvailable = false
    var installed: [MasApp] = []
    var outdated: [MasApp] = []
    var isLoading = false

    private unowned let console: TaskConsole

    init(console: TaskConsole) {
        self.console = console
    }

    var masPath: String? {
        let env = BrewEnvironment.current
        for candidate in [env.binDir + "/mas", "/usr/local/bin/mas"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    func refresh() async {
        guard let path = masPath else {
            isAvailable = false
            return
        }
        isAvailable = true
        isLoading = true
        defer { isLoading = false }

        async let listResult = Shell.run(path, ["list"])
        async let outdatedResult = Shell.run(path, ["outdated"])
        let (list, out) = await (listResult, outdatedResult)

        installed = Self.parseList(list.stdout)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        outdated = Self.parseOutdated(out.stdout)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Parses lines like `497799835  Xcode  (16.0)`.
    nonisolated static func parseList(_ text: String) -> [MasApp] {
        text.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard let idEnd = line.firstIndex(of: " ") else { return nil }
            let id = String(line[..<idEnd])
            guard Int(id) != nil else { return nil }
            var rest = String(line[idEnd...]).trimmingCharacters(in: .whitespaces)
            var version = ""
            if rest.hasSuffix(")"), let open = rest.lastIndex(of: "(") {
                version = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
                rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
            }
            return MasApp(adamID: id, name: rest, version: version)
        }
    }

    /// Parses lines like `497799835  Xcode  (15.4 -> 16.0)`.
    nonisolated static func parseOutdated(_ text: String) -> [MasApp] {
        parseList(text).map { app in
            var copy = app
            if app.version.contains("->") {
                let parts = app.version.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    copy = MasApp(adamID: app.adamID, name: app.name, version: parts[0], newVersion: parts[1])
                }
            }
            return copy
        }
    }

    func upgradeAll() async {
        guard let path = masPath else { return }
        await console.run(title: "Upgrade App Store apps", executablePath: path, arguments: ["upgrade"])
        await refresh()
    }

    func upgrade(_ app: MasApp) async {
        guard let path = masPath else { return }
        await console.run(title: "Upgrade \(app.name)", executablePath: path, arguments: ["upgrade", app.adamID])
        await refresh()
    }

    func installMasCLI(packages: PackageStore) async {
        await packages.install(name: "mas", kind: .formula)
        await refresh()
    }
}

// MARK: - Helpers

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
