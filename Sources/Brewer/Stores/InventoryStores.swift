import Foundation
import AppKit
import Observation
import os

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
            casks.compactMap { cask in cask.appPath.map { ($0, cask.name) } },
            uniquingKeysWith: { first, _ in first }
        )

        let scanned = await Task.detached(priority: .utility) { () -> [(ScannedApp, Set<String>)] in
            AppScanner.scanApplications().map { app in
                let archs = app.executableURL.map { MachOInspector.architectures(ofExecutable: $0) } ?? []
                return (app, archs)
            }
        }.value

        apps = scanned.map { (app, archs) in
            let token = caskByPath[app.url.path]
            let source: AppSource = token != nil ? .homebrew : AppSource.detect(for: app)
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

    // SmartDelete: watches the Applications folders (no Full Disk Access needed,
    // unlike ~/.Trash) and offers leftover cleanup for apps that disappear.
    var recentlyRemoved: [ScannedApp] = []
    private var appsWatcher: FolderWatcher?
    private var appSnapshot: [String: ScannedApp] = [:]
    private var snapshotReady = false
    private var settleTask: Task<Void, Never>?
    /// Set when a change happened while a brew command ran: cask upgrades,
    /// reinstalls and uninstalls remove apps on purpose.
    private var changedDuringBrewOperation = false
    /// App paths Brewer's own uninstaller just removed - no second offer.
    private var removedByBrewer: Set<String> = []
    private let logger = Logger(subsystem: "com.monz.brewer", category: "SmartDelete")

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
        guard appURL.pathExtension == "app" else {
            resultMessage = "That doesn't look like an app bundle."
            return
        }
        guard let scanned = AppScanner.scanApp(at: appURL) else {
            resultMessage = appURL.path.contains("/.Trash/")
                ? "macOS doesn't let Brewer read apps inside the Trash. Turn on SmartDelete and pick the app from \"Recently removed apps\", or drop apps here before deleting them."
                : "Brewer couldn't read that app bundle."
            return
        }
        await beginReview(app: scanned)
    }

    /// Reviews an app from a scan - it may already be gone from disk (SmartDelete),
    /// in which case only its leftovers are offered.
    func beginReview(app scanned: ScannedApp) async {
        resultMessage = nil
        let appURL = scanned.url
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
        removedByBrewer.insert(review.app.url.path)
        recentlyRemoved.removeAll { $0.id == review.app.id }
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
            NotificationManager.post(title: "\(review.app.name) removed", body: resultMessage ?? "", page: .uninstaller)
        }
        self.review = nil
        leftovers = []
        checkedIDs = []
    }

    // MARK: SmartDelete (Applications watcher)

    var smartDeleteEnabled: Bool {
        UserDefaults.standard.bool(forKey: Prefs.smartDelete)
    }

    var isWatchingApplications: Bool { appsWatcher != nil }

    func setSmartDelete(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Prefs.smartDelete)
        if enabled { startApplicationsWatcher() } else { stopApplicationsWatcher() }
    }

    func startWatcherIfEnabled() {
        if smartDeleteEnabled { startApplicationsWatcher() }
    }

    private func startApplicationsWatcher() {
        guard appsWatcher == nil else { return }
        let roots = AppScanner.applicationRoots
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map(FolderWatcher.canonicalPath)
        appsWatcher = FolderWatcher(paths: roots) { [weak self] changed in
            guard changed.contains(where: { FolderWatcher.isRelevantChange($0, roots: roots) }) else { return }
            Task { @MainActor [weak self] in self?.applicationsChanged() }
        }
        if appsWatcher == nil {
            logger.error("SmartDelete could not start watching \(roots.joined(separator: ", "), privacy: .public)")
            return
        }
        Task { [weak self] in
            let apps = await Task.detached(priority: .utility) { AppScanner.scanApplications() }.value
            guard let self, self.appsWatcher != nil else { return }
            self.appSnapshot = Self.snapshot(of: apps)
            self.snapshotReady = true
            self.logger.notice("SmartDelete is watching \(apps.count) apps")
        }
    }

    private func stopApplicationsWatcher() {
        appsWatcher?.stop()
        appsWatcher = nil
        settleTask?.cancel()
        settleTask = nil
        snapshotReady = false
        appSnapshot = [:]
    }

    /// Waits until the folders have been quiet for a moment and no brew command
    /// is running, then compares against the last snapshot.
    private func applicationsChanged() {
        if console.isBusy { changedDuringBrewOperation = true }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            while self.console.isBusy {
                self.changedDuringBrewOperation = true
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
            }
            await self.compareWithSnapshot()
        }
    }

    private func compareWithSnapshot() async {
        let apps = await Task.detached(priority: .utility) { AppScanner.scanApplications() }.value
        let current = Self.snapshot(of: apps)
        let previous = appSnapshot
        appSnapshot = current
        let wasBrewOperation = changedDuringBrewOperation
        changedDuringBrewOperation = false
        guard snapshotReady else { return }

        for app in Self.removedApps(previous: previous, current: current) {
            if removedByBrewer.remove(app.url.path) != nil { continue }
            if wasBrewOperation {
                logger.notice("SmartDelete ignored \(app.name, privacy: .public): removed while a brew command ran")
                continue
            }
            guard !LeftoverScanner.isProtected(bundleID: app.bundleID, appURL: app.url) else { continue }
            logger.notice("SmartDelete detected removal of \(app.name, privacy: .public) (\(app.bundleID ?? "no bundle id", privacy: .public))")
            recentlyRemoved.removeAll { $0.id == app.id }
            recentlyRemoved.insert(app, at: 0)
            if recentlyRemoved.count > 10 { recentlyRemoved.removeLast() }
            NotificationManager.post(
                title: "\(app.name) was removed",
                body: "Brewer can also clean up the files it left behind - click to review them.",
                page: .uninstaller
            )
        }
    }

    nonisolated static func snapshot(of apps: [ScannedApp]) -> [String: ScannedApp] {
        Dictionary(apps.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Apps that were present before and are gone now - unless an app with the
    /// same bundle ID still exists (moved to another folder, or replaced by an
    /// update that renamed the bundle).
    nonisolated static func removedApps(previous: [String: ScannedApp], current: [String: ScannedApp]) -> [ScannedApp] {
        let currentBundleIDs = Set(current.values.compactMap(\.bundleID))
        return previous.values
            .filter { app in
                guard current[app.url.path] == nil else { return false }
                if let bundleID = app.bundleID, currentBundleIDs.contains(bundleID) { return false }
                return true
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
