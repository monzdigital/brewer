import Foundation
import AppKit
import Observation

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

    let client = BrewClient()
    private unowned let console: TaskConsole
    private var sizeTasks: Set<String> = []

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

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let snapshot = try await client.installedSnapshot()
            formulae = snapshot.formulae
                .compactMap { Self.package(from: $0) }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            casks = snapshot.casks
                .map { Self.package(from: $0) }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            lastRefreshed = Date()
        } catch {
            loadError = error.localizedDescription
        }

        if brewVersion == nil {
            brewVersion = await client.brewVersion()
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
            for base in ["/Applications", NSHomeDirectory() + "/Applications"] {
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
        await console.runBrew(title: "Install \(name)", arguments: args)
        await refresh()
    }

    func install(_ package: BrewPackage) async {
        await install(name: package.name, kind: package.kind)
    }

    func uninstall(_ packages: [BrewPackage], zap: Bool = false) async {
        let formulaNames = packages.filter { $0.kind == .formula }.map(\.name)
        let caskNames = packages.filter { $0.kind == .cask }.map(\.name)
        if !formulaNames.isEmpty {
            await console.runBrew(
                title: "Uninstall \(formulaNames.joined(separator: ", "))",
                arguments: ["uninstall"] + formulaNames
            )
        }
        if !caskNames.isEmpty {
            var args = ["uninstall", "--cask"]
            if zap { args.append("--zap") }
            await console.runBrew(
                title: "Uninstall \(caskNames.joined(separator: ", "))",
                arguments: args + caskNames
            )
        }
        await refresh()
    }

    func upgrade(_ packages: [BrewPackage]) async {
        guard !packages.isEmpty else { return }
        let caskPackages = packages.filter { $0.kind == .cask }
        await closeRunningAppsIfEnabled(for: caskPackages)

        let formulaNames = packages.filter { $0.kind == .formula }.map(\.name)
        let caskNames = caskPackages.map(\.name)
        if !formulaNames.isEmpty {
            await console.runBrew(
                title: "Upgrade \(formulaNames.count == 1 ? formulaNames[0] : "\(formulaNames.count) formulae")",
                arguments: ["upgrade"] + formulaNames
            )
        }
        if !caskNames.isEmpty {
            await console.runBrew(
                title: "Upgrade \(caskNames.count == 1 ? caskNames[0] : "\(caskNames.count) casks")",
                arguments: ["upgrade", "--cask"] + caskNames
            )
        }
        await refresh()
    }

    func upgradeAll() async {
        await closeRunningAppsIfEnabled(for: outdatedPackages.filter { $0.kind == .cask })
        var args = ["upgrade"]
        if UserDefaults.standard.bool(forKey: Prefs.greedyCasks) { args.append("--greedy") }
        await console.runBrew(title: "Upgrade all packages", arguments: args)
        await refresh()
    }

    func setPinned(_ package: BrewPackage, pinned: Bool) async {
        guard package.kind == .formula else { return }
        await console.runBrew(
            title: pinned ? "Pin \(package.name)" : "Unpin \(package.name)",
            arguments: [pinned ? "pin" : "unpin", package.name],
            presentConsole: false
        )
        await refresh()
    }

    func updateHomebrewData(presentConsole: Bool = true) async {
        await console.runBrew(title: "Update Homebrew data", arguments: ["update"], presentConsole: presentConsole)
        await refresh()
    }

    // MARK: Running app handling

    private func closeRunningAppsIfEnabled(for caskPackages: [BrewPackage]) async {
        guard UserDefaults.standard.bool(forKey: Prefs.closeAppsBeforeUpgrade), !caskPackages.isEmpty else { return }
        let appPaths = Set(caskPackages.compactMap(\.appPath))
        guard !appPaths.isEmpty else { return }

        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard let path = app.bundleURL?.path else { return false }
            return appPaths.contains(path)
        }
        guard !running.isEmpty else { return }

        for app in running {
            app.terminate()
        }
        // Wait up to 8 seconds for a clean exit.
        for _ in 0..<16 {
            if running.allSatisfy({ $0.isTerminated }) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
