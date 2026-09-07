import Foundation
import AppKit
import Observation

/// Collects the apps a queue preflight closed so they can be reopened afterwards.
actor ClosedApps {
    private(set) var paths: [String] = []
    func record(_ closed: [String]) { paths.append(contentsOf: closed) }
}

/// Source of truth for installed formulae and casks, plus all package actions.
@MainActor
@Observable
final class PackageStore {

    var formulae: [BrewPackage] = []
    var casks: [BrewPackage] = []
    var isLoading = false
    var lastRefreshed: Date?
    var loadError: String?
    var sizeCache: [String: Int64] = [:]
    var brewVersion: String?

    /// Runs after every completed refresh (AppState prunes stale snoozes here).
    var onRefreshed: (() -> Void)?

    let client = BrewClient()
    private unowned let console: TaskConsole
    private var sizeTasks: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false

    init(console: TaskConsole) {
        self.console = console
    }

    // MARK: Derived collections

    var allPackages: [BrewPackage] { formulae + casks }

    var outdatedPackages: [BrewPackage] {
        allPackages.filter { $0.isOutdated }
    }

    var outdatedCount: Int { outdatedPackages.count }

    var deprecatedOrDisabled: [BrewPackage] {
        allPackages.filter { $0.isDeprecated || $0.isDisabled }
    }

    func package(id: String) -> BrewPackage? {
        allPackages.first { $0.id == id }
    }

    func packages(ids: Set<String>) -> [BrewPackage] {
        allPackages.filter { ids.contains($0.id) }
    }

    // MARK: Refresh

    /// Refreshes from `brew info --installed`. Calls that arrive while a refresh
    /// is already running wait for it AND trigger one more pass, so a refresh
    /// requested after an install never returns data captured before it.
    func refresh() async {
        if let task = refreshTask {
            refreshAgain = true
            await task.value
            return
        }
        let task = Task { @MainActor [self] in
            repeat {
                self.refreshAgain = false
                await self.performRefresh()
            } while self.refreshAgain
            self.refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let snapshot = try await client.installedSnapshot()
            let newFormulae = snapshot.formulae
                .compactMap { Self.package(from: $0) }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            var newCasks = snapshot.casks
                .map { Self.package(from: $0) }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            if UserDefaults.standard.bool(forKey: Prefs.greedyCasks) {
                Self.mergeGreedyOutdated(await client.outdatedCasksGreedy(), into: &newCasks)
            }
            formulae = newFormulae
            casks = newCasks
            lastRefreshed = Date()
        } catch {
            loadError = error.localizedDescription
        }

        if brewVersion == nil {
            brewVersion = await client.brewVersion()
        }
        onRefreshed?()
    }

    /// `brew info` reports self-updating casks as current even when Homebrew's
    /// version moved on; with the greedy preference the Updates list must match
    /// what "Upgrade All" will actually upgrade.
    nonisolated static func mergeGreedyOutdated(_ entries: [OutdatedEntryJSON], into casks: inout [BrewPackage]) {
        for entry in entries {
            guard let index = casks.firstIndex(where: { $0.name == entry.name }) else { continue }
            casks[index].isOutdated = true
            if let current = entry.current_version, !current.isEmpty {
                casks[index].latestVersion = current
            }
        }
    }

    nonisolated static func package(from json: FormulaJSON) -> BrewPackage? {
        guard let entry = json.installed?.last, let installedVersion = entry.version else { return nil }
        var package = BrewPackage(
            kind: .formula,
            name: json.name,
            displayName: json.name,
            desc: json.desc,
            homepage: json.homepage,
            license: json.license,
            tap: json.tap
        )
        package.installedVersion = installedVersion
        package.latestVersion = json.versions?.stable
        package.isOutdated = json.outdated ?? false
        package.isPinned = json.pinned ?? false
        package.installedAsDependency = entry.installed_as_dependency ?? false
        package.installedOnRequest = entry.installed_on_request ?? !(entry.installed_as_dependency ?? false)
        package.isDeprecated = json.deprecated ?? false
        package.deprecationReason = json.deprecation_reason
        package.isDisabled = json.disabled ?? false
        package.caveats = json.caveats
        package.dependencies = json.dependencies ?? []
        package.buildDependencies = json.build_dependencies ?? []
        package.isKegOnly = json.keg_only ?? false
        package.kegOnlyReason = json.keg_only_reason?.displayText
        package.isLinked = json.linked_keg != nil
        return package
    }

    nonisolated static func package(from json: CaskJSON) -> BrewPackage {
        var package = BrewPackage(
            kind: .cask,
            name: json.token,
            displayName: json.name?.first ?? json.token,
            desc: json.desc,
            homepage: json.homepage,
            license: nil,
            tap: json.tap
        )
        package.installedVersion = json.installed?.value
        package.latestVersion = json.version
        package.isOutdated = json.outdated ?? false
        package.isDeprecated = json.deprecated ?? false
        package.deprecationReason = json.deprecation_reason
        package.isDisabled = json.disabled ?? false
        package.caveats = json.caveats
        package.autoUpdates = json.auto_updates ?? false
        if let epoch = json.installed_time {
            package.installedDate = Date(timeIntervalSince1970: epoch)
        }
        package.appPath = Self.resolveAppPath(for: json)
        return package
    }

    nonisolated static func resolveAppPath(for json: CaskJSON) -> String? {
        let fileManager = FileManager.default
        let appNames = json.appNames
        for appName in appNames {
            for base in AppScanner.applicationRoots {
                let candidate = base + "/" + appName
                if fileManager.fileExists(atPath: candidate) { return candidate }
            }
        }
        // Name-based guess for casks whose artifact list is empty.
        if let displayName = json.name?.first {
            let candidate = "/Applications/\(displayName).app"
            if fileManager.fileExists(atPath: candidate) { return candidate }
        }
        // Fall back to the Caskroom copy (the app may have been moved or removed
        // from /Applications but still exists inside the keg).
        let caskroomDir = BrewEnvironment.current.caskroomPath + "/" + json.token
        if let versions = try? fileManager.contentsOfDirectory(atPath: caskroomDir) {
            for version in versions.sorted(by: >) where !version.hasPrefix(".") {
                let versionDir = caskroomDir + "/" + version
                guard let entries = try? fileManager.contentsOfDirectory(atPath: versionDir) else { continue }
                if let match = appNames.first(where: { entries.contains($0) }) {
                    return versionDir + "/" + match
                }
                if let anyApp = entries.first(where: { $0.hasSuffix(".app") }) {
                    return versionDir + "/" + anyApp
                }
            }
        }
        return nil
    }

    // MARK: Sizes

    func computeSizeIfNeeded(for package: BrewPackage) {
        let id = package.id
        guard sizeCache[id] == nil, !sizeTasks.contains(id) else { return }
        sizeTasks.insert(id)
        let env = BrewEnvironment.current
        Task { [weak self] in
            var paths: [String] = []
            switch package.kind {
            case .formula:
                paths.append(env.cellarPath + "/" + package.name)
                paths.append(env.prefix + "/opt/" + package.name) // symlink dir, usually tiny
            case .cask:
                paths.append(env.caskroomPath + "/" + package.name)
                if let appPath = package.appPath { paths.append(appPath) }
            }
            let size = await DiskUsage.size(ofPaths: package.kind == .cask ? paths : [paths[0]])
            await MainActor.run {
                self?.sizeCache[id] = size ?? 0
                self?.sizeTasks.remove(id)
            }
        }
    }

    // MARK: Actions

    func install(name: String, kind: PackageKind) async {
        var args = ["install"]
        if kind == .cask { args.append("--cask") }
        args.append(name)
        await console.runBrew(
            title: "Install \(name)",
            arguments: args,
            subjects: [BrewPackage.makeID(kind: kind, name: name)]
        )
        await refresh()
    }

    func install(_ package: BrewPackage) async {
        await install(name: package.name, kind: package.kind)
    }

    func reinstall(_ package: BrewPackage) async {
        var args = ["reinstall"]
        if package.kind == .cask { args.append("--cask") }
        args.append(package.name)
        let appPaths = Self.appPathsForClosing(package.kind == .cask ? [package] : [])
        let closed = ClosedApps()
        await console.runBrew(
            title: "Reinstall \(package.name)",
            arguments: args,
            subjects: [package.id],
            preflight: { await closed.record(Self.closeRunningApps(atPaths: appPaths)) }
        )
        await Self.relaunchIfWanted(closed)
        await refresh()
    }

    func uninstall(_ packages: [BrewPackage], zap: Bool = false) async {
        let formulae = packages.filter { $0.kind == .formula }
        let casks = packages.filter { $0.kind == .cask }
        if !formulae.isEmpty {
            let names = formulae.map(\.name)
            await console.runBrew(
                title: "Uninstall \(names.joined(separator: ", "))",
                arguments: ["uninstall"] + names,
                subjects: formulae.map(\.id)
            )
        }
        if !casks.isEmpty {
            var args = ["uninstall", "--cask"]
            if zap { args.append("--zap") }
            await console.runBrew(
                title: "Uninstall \(casks.map(\.name).joined(separator: ", "))",
                arguments: args + casks.map(\.name),
                subjects: casks.map(\.id)
            )
        }
        await refresh()
    }

    func upgrade(_ packages: [BrewPackage]) async {
        guard !packages.isEmpty else { return }
        let caskPackages = packages.filter { $0.kind == .cask }
        let appPaths = Self.appPathsForClosing(caskPackages)

        let formulae = packages.filter { $0.kind == .formula }
        if !formulae.isEmpty {
            let names = formulae.map(\.name)
            await console.runBrew(
                title: "Upgrade \(names.count == 1 ? names[0] : "\(names.count) formulae")",
                arguments: ["upgrade"] + names,
                subjects: formulae.map(\.id)
            )
        }
        if !caskPackages.isEmpty {
            let names = caskPackages.map(\.name)
            let closed = ClosedApps()
            await console.runBrew(
                title: "Upgrade \(names.count == 1 ? names[0] : "\(names.count) casks")",
                arguments: ["upgrade", "--cask"] + names,
                subjects: caskPackages.map(\.id),
                preflight: { await closed.record(Self.closeRunningApps(atPaths: appPaths)) }
            )
            await Self.relaunchIfWanted(closed)
        }
        await refresh()
    }

    /// Upgrades everything outdated. Snoozed packages are passed in as
    /// exclusions: brew has no notion of a snooze, so when any exist the upgrade
    /// runs with an explicit package list instead of a bare `brew upgrade`.
    func upgradeAll(excluding excludedIDs: Set<String> = []) async {
        let outdated = outdatedPackages
        let targets = outdated.filter { !excludedIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        if targets.count < outdated.count {
            await upgrade(targets)
            return
        }

        let appPaths = Self.appPathsForClosing(targets.filter { $0.kind == .cask })
        var args = ["upgrade"]
        if UserDefaults.standard.bool(forKey: Prefs.greedyCasks) { args.append("--greedy-auto-updates") }
        let closed = ClosedApps()
        await console.runBrew(
            title: "Upgrade all packages",
            arguments: args,
            subjects: targets.map(\.id),
            preflight: { await closed.record(Self.closeRunningApps(atPaths: appPaths)) }
        )
        await Self.relaunchIfWanted(closed)
        await refresh()
    }

    func setPinned(_ package: BrewPackage, pinned: Bool) async {
        guard package.kind == .formula else { return }
        await console.runBrew(
            title: pinned ? "Pin \(package.name)" : "Unpin \(package.name)",
            arguments: [pinned ? "pin" : "unpin", package.name],
            presentConsole: false,
            subjects: [package.id]
        )
        await refresh()
    }

    func setLinked(_ package: BrewPackage, linked: Bool) async {
        guard package.kind == .formula else { return }
        await console.runBrew(
            title: linked ? "Link \(package.name)" : "Unlink \(package.name)",
            arguments: [linked ? "link" : "unlink", package.name],
            subjects: [package.id]
        )
        await refresh()
    }

    func updateHomebrewData(presentConsole: Bool = true) async {
        await console.runBrew(title: "Update Homebrew data", arguments: ["update"], presentConsole: presentConsole)
        await refresh()
    }

    // MARK: Running app handling

    nonisolated static func appPathsForClosing(_ caskPackages: [BrewPackage]) -> Set<String> {
        guard UserDefaults.standard.bool(forKey: Prefs.closeAppsBeforeUpgrade) else { return [] }
        return Set(caskPackages.compactMap(\.appPath))
    }

    /// Runs as a queue preflight: closes apps just before their upgrade executes,
    /// not while the operation is still waiting in line. Returns what it closed.
    nonisolated static func closeRunningApps(atPaths appPaths: Set<String>) async -> [String] {
        guard !appPaths.isEmpty else { return [] }
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.filter { app in
                guard let path = app.bundleURL?.path else { return false }
                return appPaths.contains(path)
            }
        }
        guard !running.isEmpty else { return [] }

        for app in running {
            _ = app.terminate()
        }
        // Wait up to 8 seconds for a clean exit.
        for _ in 0..<16 {
            if running.allSatisfy({ $0.isTerminated }) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return running.compactMap { $0.bundleURL?.path }
    }

    /// Reopens the apps a preflight closed (in the background, without stealing
    /// focus) once their upgrade has run - whether or not brew succeeded, the
    /// user had those apps open.
    nonisolated static func relaunchIfWanted(_ closed: ClosedApps) async {
        guard UserDefaults.standard.bool(forKey: Prefs.relaunchAppsAfterUpgrade) else { return }
        let paths = await closed.paths
        guard !paths.isEmpty else { return }
        await MainActor.run {
            for path in paths where FileManager.default.fileExists(atPath: path) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
            }
        }
    }
}
