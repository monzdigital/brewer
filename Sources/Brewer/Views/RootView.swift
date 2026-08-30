import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var console = app.console
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detailView(for: app.selection ?? .installed)
                .overlay(alignment: .bottomTrailing) {
                    RunningOperationPill()
                }
        }
        .sheet(isPresented: $console.isPresented) {
            ConsolePanel()
                .environment(app)
        }
        .navigationTitle("Brewer")
    }

    @ViewBuilder
    private func detailView(for item: SidebarItem) -> some View {
        if !app.brewIsAvailable {
            BrewMissingView()
        } else {
            switch item {
            case .discover:
                DiscoverView()
            case .collections:
                CollectionsView()
            case .search:
                SearchView()
            case .installed:
                PackageBrowserView(title: "Installed", scope: .all)
            case .formulae:
                PackageBrowserView(title: "Formulae", scope: .formulae)
            case .casks:
                PackageBrowserView(title: "Casks", scope: .casks)
            case .updates:
                UpdatesView()
            case .appUpdates:
                AppUpdatesView()
            case .appleSilicon:
                AppleSiliconView()
            case .adoptApps:
                AdoptAppsView()
            case .appStore:
                MasView()
            case .favorites:
                PackageBrowserView(title: "Favorites", scope: .favorites)
            case .tags:
                TagsView()
            case .pinned:
                PackageBrowserView(title: "Pinned", scope: .pinned)
            case .snoozed:
                PackageBrowserView(title: "Snoozed", scope: .snoozed)
            case .taps:
                TapsView()
            case .services:
                ServicesView()
            case .brewfile:
                BrewfileView()
            case .health:
                HealthView()
            case .duplicates:
                DuplicatesView()
            case .diagnostics:
                DiagnosticsView()
            case .cleanup:
                CleanupView()
            case .history:
                HistoryView()
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            Group {
                Label("Discover", systemImage: "sparkles")
                    .tag(SidebarItem.discover)
                Label("Collections", systemImage: "rectangle.stack")
                    .tag(SidebarItem.collections)
                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
            }

            Section("Main") {
                Label("Installed", systemImage: "checkmark.circle")
                    .badge(app.packages.allPackages.count)
                    .tag(SidebarItem.installed)
                Label("Formulae", systemImage: "shippingbox")
                    .badge(app.packages.formulae.count)
                    .tag(SidebarItem.formulae)
                Label("Casks", systemImage: "macwindow")
                    .badge(app.packages.casks.count)
                    .tag(SidebarItem.casks)
                Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                    .badge(app.visibleUpdateCount)
                    .tag(SidebarItem.updates)
                Label("App Updates", systemImage: "arrow.down.app")
                    .badge(app.appUpdates.availableUpdates.count)
                    .tag(SidebarItem.appUpdates)
                Label("Apple Silicon", systemImage: "cpu")
                    .tag(SidebarItem.appleSilicon)
                Label("Adopt Apps", systemImage: "plus.app")
                    .tag(SidebarItem.adoptApps)
            }

            Section("App Store") {
                Label("App Store", systemImage: "bag")
                    .badge(app.mas.outdated.count)
                    .tag(SidebarItem.appStore)
            }

            Section("Organization") {
                Label("Favorites", systemImage: "heart")
                    .badge(app.meta.favorites.count)
                    .tag(SidebarItem.favorites)
                Label("Tags", systemImage: "tag")
                    .tag(SidebarItem.tags)
                Label("Pinned", systemImage: "pin")
                    .tag(SidebarItem.pinned)
                Label("Snoozed", systemImage: "moon.zzz")
                    .badge(app.meta.snoozedIDs.count)
                    .tag(SidebarItem.snoozed)
            }

            Section("Management") {
                Label("Taps", systemImage: "archivebox")
                    .tag(SidebarItem.taps)
                Label("Services", systemImage: "gearshape.2")
                    .tag(SidebarItem.services)
                Label("Brewfile", systemImage: "doc.text")
                    .tag(SidebarItem.brewfile)
            }

            Section("Maintenance") {
                Label("Health", systemImage: "stethoscope")
                    .tag(SidebarItem.health)
                Label("Duplicates", systemImage: "square.on.square")
                    .tag(SidebarItem.duplicates)
                Label("Diagnostics", systemImage: "waveform.path.ecg")
                    .tag(SidebarItem.diagnostics)
                Label("Cleanup", systemImage: "trash")
                    .tag(SidebarItem.cleanup)
                Label("History", systemImage: "clock")
                    .tag(SidebarItem.history)
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Missing Homebrew

struct BrewMissingView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Homebrew Not Found", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Brewer could not find the `brew` executable at \(BrewEnvironment.current.brewPath).\nInstall Homebrew from brew.sh, or point Brewer at your installation in Settings → Homebrew.")
        } actions: {
            Link("Open brew.sh", destination: URL(string: "https://brew.sh")!)
                .buttonStyle(.borderedProminent)
        }
    }
}
