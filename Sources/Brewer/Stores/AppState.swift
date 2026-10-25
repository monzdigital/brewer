import Foundation
import Observation

/// Root object that wires every store together and owns global UI state.
@MainActor
@Observable
final class AppState {

    /// For the app delegate to reach the console at quit time.
    static weak var shared: AppState?

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
        let meta = MetaStore()
        self.meta = meta
        let history = HistoryStore()
        self.history = history
        self.services = ServicesStore(console: console)
        let taps = TapsStore(console: console)
        self.taps = taps
        self.brewfile = BrewfileModel(console: console)
        self.health = HealthStore(console: console)
        self.duplicates = DuplicatesStore(console: console)
        self.discover = DiscoverStore()
        self.adopt = AdoptStore(console: console, packages: packages)
        let appUpdates = AppUpdatesStore()
        self.appUpdates = appUpdates
        self.arch = ArchitectureStore()
        self.mas = MasStore(console: console)
        self.scheduler = UpdateScheduler(packages: packages)
        self.inventory = AppsInventoryStore()
        self.uninstaller = UninstallerStore(console: console, packages: packages)
        let installer = AppUpdateInstaller()
        self.installer = installer

        AppState.shared = self

        console.onFinished = { [weak history] operation in
            history?.record(operation)
            // WailBrew-style completion notifications for meaningful operations.
            if UserDefaults.standard.bool(forKey: Prefs.notifyOnOperations),
               operation.duration > 4 {
                switch operation.state {
                case .succeeded:
                    NotificationManager.post(
                        title: "Completed: \(operation.title)",
                        body: "Finished in \(Format.duration(operation.duration)).",
                        page: .console
                    )
                case .failed(let code):
                    NotificationManager.post(
                        title: "Failed: \(operation.title)",
                        body: "Exited with code \(code) - see the console for details.",
                        page: .console
                    )
                default:
                    break
                }
            }
        }
        packages.onRefreshed = { [weak meta, weak packages, weak taps] in
            if let meta, let packages, !packages.allPackages.isEmpty {
                meta.pruneStaleSnoozes(packages: packages.allPackages)
            }
            // Installs and removals change which packages wait for trust.
            Task { await taps?.refreshTrust() }
        }
        // Trusted packages only show up in `brew info --installed` afterwards.
        taps.onTrustChanged = { [weak packages] in
            await packages?.refresh()
        }
        installer.onInstalled = { [weak appUpdates] path in
            await appUpdates?.refreshApp(atPath: path)
        }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        NotificationManager.requestAuthorizationIfNeeded()
        uninstaller.startWatcherIfEnabled()
        await packages.refresh()
        scheduler.visibleUpdates = { [weak self] in
            self?.packages(in: .updates) ?? []
        }
        scheduler.onScheduledCheck = { [weak self] in
            guard let self else { return }
            await self.appUpdates.scan(casks: self.packages.casks)
        }
        scheduler.start()
        Task { [weak self] in
            // Applies the backup policy (one copy per version, N per app), which
            // also clears duplicates left by older releases.
            await self?.installer.settleBackups()
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

    /// Everything the user quits with: pending metadata writes and any brew
    /// process that would otherwise be orphaned holding Homebrew's lock.
    func prepareForTermination() {
        meta.flushPendingSave()
        console.terminateCurrent()
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
            return packages.outdatedPackages.filter { meta.isSnoozed($0.id, latestVersion: $0.latestVersion) }
        case .tag(let tag):
            let ids = meta.packageIDs(withTag: tag)
            return packages.allPackages.filter { ids.contains($0.id) }
        case .collection(let id):
            guard let collection = meta.collection(id: id) else { return [] }
            let ids = Set(collection.packageIDs)
            return packages.allPackages.filter { ids.contains($0.id) }
        }
    }

    /// Count of updates not snoozed - used for sidebar and menu bar badges.
    var visibleUpdateCount: Int {
        packages(in: .updates).count
    }

    /// Homebrew support-tier warning for this Mac (Intel, Rosetta or Sonoma
    /// under Homebrew 7), or nil when everything is fully supported.
    var platformNotice: PlatformSupport.Notice? {
        guard let version = packages.brewVersion else { return nil }
        let environment = BrewEnvironment.current
        return PlatformSupport.notice(
            brewMajor: BrewClient.majorVersion(ofBrewVersionLine: version),
            macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            appleSilicon: environment.isAppleSiliconMachine,
            rosettaBrew: environment.isRosettaBrew
        )
    }

    /// Updates currently hidden by a snooze.
    var snoozedUpdateCount: Int {
        packages(in: .snoozed).count
    }

    /// "Upgrade All" as the user sees it: everything outdated except snoozed packages.
    func upgradeAllVisible() async {
        let snoozed = Set(packages(in: .snoozed).map(\.id))
        await packages.upgradeAll(excluding: snoozed)
    }
}
