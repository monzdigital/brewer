import Foundation
import AppKit
import Observation
import UniformTypeIdentifiers

// MARK: - ServicesStore

@MainActor
@Observable
final class ServicesStore {

    var items: [ServiceItem] = []
    var isLoading = false
    var errorMessage: String?

    private let client = BrewClient()
    private unowned let console: TaskConsole

    init(console: TaskConsole) {
        self.console = console
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let raw = try await client.servicesList()
            items = raw.map { json in
                ServiceItem(
                    name: json.name,
                    status: ServiceStatus(raw: json.status),
                    user: json.user,
                    plistPath: json.file,
                    exitCode: json.exit_code,
                    pid: json.pid
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func start(_ name: String) async {
        await console.runBrew(title: "Start service \(name)", arguments: ["services", "start", name], subjects: ["service:\(name)"])
        await refresh()
    }

    func stop(_ name: String) async {
        await console.runBrew(title: "Stop service \(name)", arguments: ["services", "stop", name], subjects: ["service:\(name)"])
        await refresh()
    }

    func restart(_ name: String) async {
        await console.runBrew(title: "Restart service \(name)", arguments: ["services", "restart", name], subjects: ["service:\(name)"])
        await refresh()
    }
}

// MARK: - TapsStore

@MainActor
@Observable
final class TapsStore {

    var taps: [TapItem] = []
    var infoCache: [String: TapInfoJSON] = [:]
    var isLoading = false
    /// Homebrew 6+ refuses to load third-party taps until they are trusted.
    var supportsTrust = false
    /// Whole taps Homebrew trusts (tap-info's flag on Homebrew 7+).
    var trustedTaps: Set<String> = []
    /// Whole taps plus single formulae, casks and commands trusted on their own.
    var trustEntries = TrustEntries()
    /// Installed formulae and casks from third-party taps, from install receipts.
    var thirdPartyInstalled: [TapInstalledItem] = []

    /// Runs after a trust change so the package lists pick up what Homebrew
    /// loads now.
    var onTrustChanged: (() async -> Void)?

    private let client = BrewClient()
    private unowned let console: TaskConsole
    private var loadingInfo: Set<String> = []
    private var trustSupportChecked = false

    init(console: TaskConsole) {
        self.console = console
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        // `brew tap` lists only taps the user added (the built-in core/cask
        // catalogs are not removable, so they stay out of this list).
        let names = await client.tapNames()
        taps = names.map { TapItem(name: $0) }
        await refreshTrust()
        await refreshDetails()
    }

    /// Trust entries and the installed third-party items, without listing
    /// taps. Cheap enough to run after every package refresh, so packages
    /// Homebrew hides are noticed on every screen, not only on Taps.
    func refreshTrust() async {
        if !trustSupportChecked {
            supportsTrust = await client.supportsTapTrust()
            trustSupportChecked = true
        }
        guard supportsTrust else {
            trustEntries = TrustEntries()
            thirdPartyInstalled = []
            return
        }
        let entries = await client.trustEntries()
        let environment = BrewEnvironment.current
        let installed = await Task.detached(priority: .utility) {
            BrewClient.thirdPartyInstalledItems(cellar: environment.cellarPath, caskroom: environment.caskroomPath,
                                                tapsDirectory: environment.tapsPath)
        }.value
        trustEntries = entries
        thirdPartyInstalled = installed
    }

    /// One `brew tap-info --installed` call for counts, remotes and (on
    /// Homebrew 7+) the official whole-tap trust flag; the trust list is the
    /// fallback for versions without that flag.
    private func refreshDetails() async {
        let infos = await client.installedTapsInfo() ?? []
        for info in infos { infoCache[info.name] = info }
        trustedTaps = Self.trustedNames(fromTapInfo: infos) ?? trustEntries.taps
    }

    /// nil when the payload carries no `trusted` flag (Homebrew 6).
    nonisolated static func trustedNames(fromTapInfo infos: [TapInfoJSON]) -> Set<String>? {
        guard infos.contains(where: { $0.trusted != nil }) else { return nil }
        return Set(infos.filter { $0.trusted == true }.map { $0.name.lowercased() })
    }

    func isWholeTapTrusted(_ name: String) -> Bool {
        let key = name.lowercased()
        return trustedTaps.contains(key) || trustEntries.taps.contains(key)
    }

    func trustState(of tap: TapItem) -> TapTrustState {
        Self.trustState(tap: tap.name, isOfficial: tap.isOfficial, supportsTrust: supportsTrust,
                        wholeTapTrusted: isWholeTapTrusted(tap.name), entries: trustEntries,
                        installed: thirdPartyInstalled)
    }

    nonisolated static func trustState(tap: String, isOfficial: Bool, supportsTrust: Bool, wholeTapTrusted: Bool,
                                       entries: TrustEntries, installed: [TapInstalledItem]) -> TapTrustState {
        guard supportsTrust, !isOfficial else { return .notRequired }
        let key = tap.lowercased()
        if wholeTapTrusted || entries.taps.contains(key) { return .wholeTap }
        let fromTap = installed.filter { $0.tap == key }
        let pending = fromTap.filter { !entries.trusts($0) }
        if !pending.isEmpty { return .installedUntrusted(pending) }
        if !fromTap.isEmpty { return .installedTrusted(fromTap) }
        return .untrusted(partly: entries.hasItemEntries(forTap: key))
    }

    /// Installed packages Homebrew ignores because neither they nor their tap
    /// are trusted. `brew info --installed` leaves them out of every list.
    var untrustedInstalledItems: [TapInstalledItem] {
        guard supportsTrust else { return [] }
        return Self.untrustedItems(in: thirdPartyInstalled, trustedTaps: trustedTaps, entries: trustEntries)
    }

    nonisolated static func untrustedItems(in installed: [TapInstalledItem], trustedTaps: Set<String>,
                                           entries: TrustEntries) -> [TapInstalledItem] {
        installed.filter { !trustedTaps.contains($0.tap) && !entries.trusts($0) }
    }

    /// `brew trust` takes one kind per call, so formulae and casks go
    /// separately, each with its full `user/repo/name`.
    nonisolated static func trustCommands(for items: [TapInstalledItem]) -> [[String]] {
        let formulae = items.filter { $0.kind == .formula }.map(\.fullName).sorted()
        let casks = items.filter { $0.kind == .cask }.map(\.fullName).sorted()
        var commands: [[String]] = []
        if !formulae.isEmpty { commands.append(["trust", "--formula"] + formulae) }
        if !casks.isEmpty { commands.append(["trust", "--cask"] + casks) }
        return commands
    }

    /// Trusts only the installed packages of `tap` that still need it, which
    /// is what Homebrew recommends over trusting a whole tap.
    func trustInstalledItems(of tap: TapItem) async {
        guard case .installedUntrusted(let pending) = trustState(of: tap) else { return }
        for arguments in Self.trustCommands(for: pending) {
            let names = arguments.dropFirst(2).map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            let isCask = arguments[1] == "--cask"
            let noun = names.count == 1 ? (isCask ? "cask" : "formula") : (isCask ? "casks" : "formulae")
            await console.runBrew(
                title: "Trust \(noun) \(names.joined(separator: ", "))",
                arguments: arguments,
                presentConsole: false,
                subjects: ["tap:\(tap.name)"]
            )
        }
        await afterTrustChange()
    }

    /// Trusts every current and future formula, cask and command of a tap.
    func trust(_ name: String) async {
        await console.runBrew(
            title: "Trust tap \(name)",
            arguments: ["trust", "--tap", name],
            presentConsole: false,
            subjects: ["tap:\(name)"]
        )
        await afterTrustChange()
    }

    private func afterTrustChange() async {
        await refreshTrust()
        await refreshDetails()
        await onTrustChanged?()
    }

    func loadInfoIfNeeded(for name: String) {
        guard infoCache[name] == nil, !loadingInfo.contains(name) else { return }
        loadingInfo.insert(name)
        Task { [weak self] in
            let info = await self?.client.tapInfo(name)
            await MainActor.run {
                if let info { self?.infoCache[name] = info }
                self?.loadingInfo.remove(name)
            }
        }
    }

    /// Adds a tap; with `trust` it is also marked trusted, which is what the
    /// interactive `brew tap` prompt would have asked in a terminal.
    func addTap(_ name: String, trust: Bool = true) async -> Bool {
        let cleaned = name.trimmingCharacters(in: .whitespaces)
        guard cleaned.split(separator: "/").count == 2 else { return false }
        let ok = await console.runBrew(title: "Add tap \(cleaned)", arguments: ["tap", cleaned])
        if ok && trust && supportsTrust {
            await self.trust(cleaned)
        }
        await refresh()
        return ok
    }

    func removeTap(_ name: String) async {
        await console.runBrew(title: "Remove tap \(name)", arguments: ["untap", name])
        await refresh()
    }

    func isTapped(_ name: String) -> Bool {
        taps.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

// MARK: - BrewfileModel

@MainActor
@Observable
final class BrewfileModel {

    var previewText: String = ""
    var statusMessage: String?
    var isWorking = false

    private let client = BrewClient()
    private unowned let console: TaskConsole

    init(console: TaskConsole) {
        self.console = console
    }

    func generatePreview() async {
        isWorking = true
        statusMessage = nil
        defer { isWorking = false }
        if let text = await client.bundleDumpPreview() {
            previewText = text
            let count = Self.entryCount(in: text)
            statusMessage = "Preview generated from your current setup (\(count) entr\(count == 1 ? "y" : "ies"))."
        } else {
            statusMessage = "Could not generate a Brewfile preview."
        }
    }

    /// Real Brewfile entries: `brew bundle dump` also writes description
    /// comments, which are not entries.
    nonisolated static func entryCount(in brewfile: String) -> Int {
        brewfile.split(separator: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }.count
    }

    func exportBrewfile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Brewfile"
        panel.canCreateDirectories = true
        panel.title = "Export Brewfile"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await console.runBrew(
                title: "Export Brewfile",
                arguments: ["bundle", "dump", "--force", "--file", url.path]
            )
            statusMessage = "Exported to \(url.path)"
        }
    }

    func importBrewfile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Import Brewfile"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await console.runBrew(
                title: "Install from Brewfile",
                arguments: ["bundle", "install", "--file", url.path]
            )
            statusMessage = "Ran brew bundle install with \(url.lastPathComponent)."
        }
    }

    func check() async {
        isWorking = true
        defer { isWorking = false }
        statusMessage = await client.bundleCheck(file: nil)
    }
}
