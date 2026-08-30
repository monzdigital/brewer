import Foundation
import Observation

/// Root object that wires every store together and owns global UI state.
@MainActor
@Observable
final class AppState {

    let console: TaskConsole
    let packages: PackageStore
    let meta: MetaStore
    let history: HistoryStore
    let services: ServicesStore
    let taps: TapsStore
    let brewfile: BrewfileModel
    let health: HealthStore
    let duplicates: DuplicatesStore
    let discover: DiscoverStore
    let adopt: AdoptStore
    let appUpdates: AppUpdatesStore
    let arch: ArchitectureStore
    let mas: MasStore
    let scheduler: UpdateScheduler
    let inventory: AppsInventoryStore
    let uninstaller: UninstallerStore
    let installer: AppUpdateInstaller

    var selection: SidebarItem? = .installed
    var didBootstrap = false

    var brewIsAvailable: Bool { BrewEnvironment.current.exists }

    init() {
        Prefs.registerDefaults()

        let customPath = UserDefaults.standard.string(forKey: Prefs.customBrewPath) ?? ""
        BrewEnvironment.current = BrewEnvironment.detect(customPath: customPath.isEmpty ? nil : customPath)

        let console = TaskConsole()
        self.console = console
        let packages = PackageStore(console: console)
        self.packages = packages
        self.meta = MetaStore()
        let history = HistoryStore()
        self.history = history
        self.services = ServicesStore(console: console)
        self.taps = TapsStore(console: console)
        self.brewfile = BrewfileModel(console: console)
        self.health = HealthStore(console: console)
        self.duplicates = DuplicatesStore(console: console)
        self.discover = DiscoverStore()
        self.adopt = AdoptStore(console: console, packages: packages)
        self.appUpdates = AppUpdatesStore()
        self.arch = ArchitectureStore()
        self.mas = MasStore(console: console)
        self.scheduler = UpdateScheduler(packages: packages)
        self.inventory = AppsInventoryStore()
        self.uninstaller = UninstallerStore(console: console, packages: packages)
        self.installer = AppUpdateInstaller()

        console.onFinished = { [weak history] operation in
            history?.record(operation)
            // WailBrew-style completion notifications for meaningful operations.
            if UserDefaults.standard.bool(forKey: Prefs.notifyOnOperations),
               operation.duration > 4 {
                switch operation.state {
                case .succeeded:
                    NotificationManager.post(
                        title: "Completed: \(operation.title)",
                        body: "Finished in \(Format.duration(operation.duration))."
                    )
                case .failed(let code):
                    NotificationManager.post(
                        title: "Failed: \(operation.title)",
                        body: "Exited with code \(code) — see the console for details."
                    )
                default:
                    break
                }
            }
        }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        NotificationManager.requestAuthorizationIfNeeded()
        uninstaller.startTrashWatcherIfEnabled()
        await packages.refresh()
        scheduler.start()
        scheduler.onScheduledCheck = { [weak self] in
            guard let self else { return }
            await self.appUpdates.scan(casks: self.packages.casks)
        }
        Task { [weak self] in
            await self?.installer.loadBackups()
        }

        if UserDefaults.standard.bool(forKey: Prefs.checkOnLaunch) {
            Task { [weak self] in
                await self?.scheduler.check(scheduled: false)
            }
        }

        // Kick off the Sparkle scan a moment later so launch stays snappy.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            await self.appUpdates.scan(casks: self.packages.casks)
        }
        Task { [weak self] in
            await self?.mas.refresh()
        }
    }

    // MARK: Scope resolution

    func packages(in scope: BrowserScope) -> [BrewPackage] {
        switch scope {
        case .all:
            return packages.allPackages
        case .formulae:
            return packages.formulae
        case .casks:
            return packages.casks
        case .updates:
            return packages.outdatedPackages.filter { !meta.isSnoozed($0.id, latestVersion: $0.latestVersion) }
        case .favorites:
            return packages.allPackages.filter { meta.isFavorite($0.id) }
        case .pinned:
            return packages.allPackages.filter { $0.isPinned }
        case .snoozed:
            return packages.allPackages.filter { meta.snoozedIDs.contains($0.id) }
        case .tag(let tag):
            let ids = meta.packageIDs(withTag: tag)
            return packages.allPackages.filter { ids.contains($0.id) }
        case .collection(let id):
            guard let collection = meta.collection(id: id) else { return [] }
            let ids = Set(collection.packageIDs)
            return packages.allPackages.filter { ids.contains($0.id) }
        }
    }

    /// Count of updates not snoozed — used for sidebar and menu bar badges.
    var visibleUpdateCount: Int {
        packages(in: .updates).count
    }
}
