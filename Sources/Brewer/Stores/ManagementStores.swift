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
        await console.runBrew(title: "Start service \(name)", arguments: ["services", "start", name])
        await refresh()
    }

    func stop(_ name: String) async {
        await console.runBrew(title: "Stop service \(name)", arguments: ["services", "stop", name])
        await refresh()
    }

    func restart(_ name: String) async {
        await console.runBrew(title: "Restart service \(name)", arguments: ["services", "restart", name])
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

    private let client = BrewClient()
    private unowned let console: TaskConsole
    private var loadingInfo: Set<String> = []

    init(console: TaskConsole) {
        self.console = console
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let names = await client.tapNames()
        taps = names.map { TapItem(name: $0) }
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

    func addTap(_ name: String) async -> Bool {
        let cleaned = name.trimmingCharacters(in: .whitespaces)
        guard cleaned.split(separator: "/").count == 2 else { return false }
        let ok = await console.runBrew(title: "Add tap \(cleaned)", arguments: ["tap", cleaned])
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
            statusMessage = "Preview generated from your current setup (\(text.split(separator: "\n").count) entries)."
        } else {
            statusMessage = "Could not generate a Brewfile preview."
        }
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
