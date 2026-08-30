import Foundation
import AppKit
import Observation

// MARK: - AppsInventoryStore (MacUpdater-style full system scan)

/// Every app on the Mac - however it was installed - with source detection
/// (Homebrew cask / App Store / Sparkle self-updater / manual), size and
/// architecture.
@MainActor
@Observable
final class AppsInventoryStore {

    var apps: [InventoryApp] = []
    var isScanning = false
    var lastScan: Date?

    private var sizeTasksRunning = false

    var totalBytes: Int64 {
        apps.compactMap(\.sizeBytes).reduce(0, +)
    }

    func count(for source: AppSource) -> Int {
        apps.filter { $0.source == source }.count
    }

    func scan(casks: [BrewPackage]) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let caskByPath: [String: String] = Dictionary(
            uniqueKeysWithValues: casks.compactMap { cask in
                cask.appPath.map { ($0, cask.name) }
            }
        )

        let scanned = await Task.detached(priority: .utility) { () -> [(ScannedApp, Set<String>)] in
            AppScanner.scanApplications().map { app in
                let archs = app.executableURL.map { MachOInspector.architectures(ofExecutable: $0) } ?? []
                return (app, archs)
            }
        }.value

        apps = scanned.map { (app, archs) in
            let source: AppSource
            let token = caskByPath[app.url.path]
            if token != nil {
                source = .homebrew
            } else if app.hasMASReceipt {
                source = .appStore
            } else if app.sparkleFeedURL != nil {
                source = .sparkle
            } else {
                source = .manual
            }
            return InventoryApp(app: app, source: source, caskToken: token, archs: archs)
        }
        lastScan = Date()
        computeSizes()
    }

    private func computeSizes() {
        guard !sizeTasksRunning else { return }
        sizeTasksRunning = true
        let paths = apps.map(\.app.url.path)
        Task { [weak self] in
            for chunk in paths.chunked(into: 4) {
                var sizes: [(String, Int64?)] = []
                await withTaskGroup(of: (String, Int64?).self) { group in
                    for path in chunk {
                        group.addTask { (path, await DiskUsage.size(ofPath: path)) }
                    }
                    for await entry in group { sizes.append(entry) }
                }
                await MainActor.run {
                    guard let self else { return }
                    for (path, size) in sizes {
                        if let index = self.apps.firstIndex(where: { $0.app.url.path == path }) {
                            self.apps[index].sizeBytes = size
                        }
                    }
                }
            }
            await MainActor.run { self?.sizeTasksRunning = false }
        }
    }
}

// MARK: - UninstallerStore (AppCleaner-style deep uninstall + SmartDelete)

@MainActor
@Observable
final class UninstallerStore {

    struct Review {
        var app: ScannedApp
        var caskToken: String?
        var isRunning: Bool
        var appStillOnDisk: Bool
    }

    var review: Review?
    var leftovers: [LeftoverItem] = []
    var checkedIDs: Set<String> = []
    var isScanning = false
    var isProtectedTarget = false
    var includeAppItself = true
    var resultMessage: String?

    // SmartDelete
    var recentlyTrashed: [ScannedApp] = []
    private var trashWatcher: DispatchSourceFileSystemObject?
    private var knownTrashApps: Set<String> = []

    private unowned let console: TaskConsole
    private unowned let packages: PackageStore

    init(console: TaskConsole, packages: PackageStore) {
        self.console = console
        self.packages = packages
    }

    var selectedBytes: Int64 {
        leftovers.filter { checkedIDs.contains($0.id) }.compactMap(\.sizeBytes).reduce(0, +)
    }

    // MARK: Review flow

    func beginReview(appURL: URL) async {
        resultMessage = nil
        guard appURL.pathExtension == "app", let scanned = AppScanner.scanApp(at: appURL) else {
            resultMessage = "That doesn't look like an app bundle."
            return
        }
        isProtectedTarget = LeftoverScanner.isProtected(bundleID: scanned.bundleID, appURL: appURL)
        let caskToken = packages.casks.first { $0.appPath == appURL.path }?.name
        let isRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == appURL.path }
        let onDisk = FileManager.default.fileExists(atPath: appURL.path)
        review = Review(app: scanned, caskToken: caskToken, isRunning: isRunning, appStillOnDisk: onDisk)
        includeAppItself = onDisk && !appURL.path.contains("/.Trash/")
        leftovers = []
        checkedIDs = []
        guard !isProtectedTarget else { return }

        isScanning = true
        let bundleID = scanned.bundleID
        let name = scanned.name
        let items = await Task.detached(priority: .userInitiated) {
            await LeftoverScanner.scan(bundleID: bundleID, appName: name)
        }.value
        leftovers = items
        // Pre-check only high-confidence, user-domain items.
        checkedIDs = Set(items.filter { $0.confidence == .bundleID && !$0.isSystemDomain }.map(\.id))
        isScanning = false
    }

    func cancelReview() {
        review = nil
        leftovers = []
        checkedIDs = []
        resultMessage = nil
    }

    // MARK: Removal

    func performRemoval() async {
        guard let review, !isProtectedTarget else { return }
        var notes: [String] = []

        // 1. Quit the app if it's running.
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == review.app.url.path }
        if !running.isEmpty {
            for app in running { app.terminate() }
            for _ in 0..<10 where !running.allSatisfy({ $0.isTerminated }) {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        // 2. Remove the app itself - through Homebrew when it owns the cask.
        if let token = review.caskToken {
            let ok = await console.runBrew(
                title: "Uninstall \(token)",
                arguments: ["uninstall", "--cask", token]
            )
            notes.append(ok ? "Removed via Homebrew (\(token))." : "brew uninstall \(token) failed - see the console.")
            await packages.refresh()
        } else if includeAppItself && review.appStillOnDisk {
            let result = LeftoverScanner.moveToTrash(paths: [review.app.url.path])
            if result.trashed.isEmpty {
                notes.append("Could not move the app to the Trash: \(result.failed.first?.reason ?? "unknown error")")
            } else {
                notes.append("App moved to the Trash.")
            }
        }

        // 3. Trash the selected leftovers.
        let selected = leftovers.filter { checkedIDs.contains($0.id) }
        if !selected.isEmpty {
            let bytes = selectedBytes
            let result = LeftoverScanner.moveToTrash(paths: selected.map(\.path))
            notes.append("\(result.trashed.count) leftover item\(result.trashed.count == 1 ? "" : "s") trashed (\(Format.bytes(bytes))).")
            for failure in result.failed.prefix(3) {
                notes.append("Kept (no permission): \(failure.path)")
            }
        }

        resultMessage = notes.joined(separator: " ")
        if UserDefaults.standard.bool(forKey: Prefs.notifyOnOperations) {
            NotificationManager.post(title: "\(review.app.name) removed", body: resultMessage ?? "")
        }
        self.review = nil
        leftovers = []
        checkedIDs = []
    }

    // MARK: SmartDelete (Trash watcher)

    var smartDeleteEnabled: Bool {
        UserDefaults.standard.bool(forKey: Prefs.smartDelete)
    }

    func setSmartDelete(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Prefs.smartDelete)
        if enabled { startTrashWatcher() } else { stopTrashWatcher() }
    }

    func startTrashWatcherIfEnabled() {
        if smartDeleteEnabled { startTrashWatcher() }
    }

    private var trashPath: String { NSHomeDirectory() + "/.Trash" }

    private func startTrashWatcher() {
        guard trashWatcher == nil else { return }
        knownTrashApps = Set((try? FileManager.default.contentsOfDirectory(atPath: trashPath))?
            .filter { $0.hasSuffix(".app") } ?? [])
        let descriptor = open(trashPath, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.trashDidChange()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        trashWatcher = source
    }

    private func stopTrashWatcher() {
        trashWatcher?.cancel()
        trashWatcher = nil
    }

    private func trashDidChange() {
        let current = Set((try? FileManager.default.contentsOfDirectory(atPath: trashPath))?
            .filter { $0.hasSuffix(".app") } ?? [])
        let added = current.subtracting(knownTrashApps)
        knownTrashApps = current
        for name in added {
            let url = URL(fileURLWithPath: trashPath + "/" + name)
            guard let scanned = AppScanner.scanApp(at: url),
                  !LeftoverScanner.isProtected(bundleID: scanned.bundleID, appURL: url) else { continue }
            if !recentlyTrashed.contains(where: { $0.id == scanned.id }) {
                recentlyTrashed.insert(scanned, at: 0)
                if recentlyTrashed.count > 10 { recentlyTrashed.removeLast() }
            }
            NotificationManager.post(
                title: "\(scanned.name) moved to Trash",
                body: "Brewer can also remove its leftover files - open the Uninstaller."
            )
        }
    }
}
