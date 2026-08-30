import SwiftUI

/// Reusable installed-package browser: filterable list on the left, detail pane on the right,
/// with multi-select bulk actions. Used by Installed, Formulae, Casks, Favorites, Pinned,
/// Snoozed, Tags and Collections screens.
struct PackageBrowserView: View {
    let title: String
    let scope: BrowserScope

    @Environment(AppState.self) private var app
    @State private var selection = Set<String>()
    @State private var filterText = ""
    @State private var kindFilter: KindFilter = .all
    @State private var confirmingUninstall = false
    @AppStorage(Prefs.compactRows) private var compactRows = false

    enum KindFilter: String, CaseIterable {
        case all = "All"
        case formulae = "Formulae"
        case casks = "Casks"
        case outdated = "Outdated"
    }

    private var showsKindFilter: Bool {
        switch scope {
        case .formulae, .casks, .updates: return false
        default: return true
        }
    }

    private var basePackages: [BrewPackage] {
        app.packages(in: scope)
    }

    private var filteredPackages: [BrewPackage] {
        var result = basePackages
        switch kindFilter {
        case .all: break
        case .formulae: result = result.filter { $0.kind == .formula }
        case .casks: result = result.filter { $0.kind == .cask }
        case .outdated: result = result.filter { $0.isOutdated }
        }
        if !filterText.isEmpty {
            let needle = filterText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(needle)
                    || $0.displayName.lowercased().contains(needle)
                    || ($0.desc?.lowercased().contains(needle) ?? false)
            }
        }
        return result
    }

    private var selectedPackages: [BrewPackage] {
        app.packages.packages(ids: selection)
    }

    var body: some View {
        HSplitView {
            listColumn
                .frame(minWidth: 400, idealWidth: 560, maxWidth: .infinity)
            detailColumn
                .frame(minWidth: 320, idealWidth: 400, maxWidth: 520)
        }
        .navigationTitle(title)
        .navigationSubtitle("\(filteredPackages.count) packages")
        .toolbar { toolbarContent }
        .confirmationDialog(
            "Uninstall \(selectedPackages.count) package\(selectedPackages.count == 1 ? "" : "s")?",
            isPresented: $confirmingUninstall
        ) {
            Button("Uninstall", role: .destructive) {
                let packages = selectedPackages
                selection = []
                Task { await app.packages.uninstall(packages) }
            }
        } message: {
            Text(selectedPackages.map(\.displayName).joined(separator: ", "))
        }
    }

    // MARK: Columns

    private var listColumn: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if app.packages.isLoading && basePackages.isEmpty {
                Spacer()
                ProgressView("Loading packages…")
                Spacer()
            } else if let error = app.packages.loadError, basePackages.isEmpty {
                ContentUnavailableView("Couldn't load packages", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if filteredPackages.isEmpty {
                emptyState
            } else {
                packageList
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            if showsKindFilter {
                Picker("", selection: $kindFilter) {
                    ForEach(KindFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            TextField("Filter", text: $filterText)
                .textFieldStyle(.roundedBorder)
        }
        .padding(8)
    }

    private var packageList: some View {
        List(selection: $selection) {
            ForEach(filteredPackages) { package in
                PackageRowView(package: package, compact: compactRows)
                    .tag(package.id)
                    .contextMenu { PackageContextMenu(package: package) }
            }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            switch scope {
            case .favorites:
                ContentUnavailableView("No favorites yet", systemImage: "heart",
                    description: Text("Mark packages with the heart button to collect them here."))
            case .pinned:
                ContentUnavailableView("Nothing pinned", systemImage: "pin",
                    description: Text("Pin formulae to keep them at their current version during upgrades."))
            case .snoozed:
                ContentUnavailableView("Nothing snoozed", systemImage: "moon.zzz",
                    description: Text("Snooze updates from the Updates screen to hide them temporarily."))
            case .updates:
                ContentUnavailableView("Everything is up to date", systemImage: "checkmark.circle")
            default:
                ContentUnavailableView.search
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if selection.count == 1, let id = selection.first,
           let package = app.packages.package(id: id) {
            PackageDetailView(package: package)
        } else if selection.count > 1 {
            MultiSelectionPane(
                packages: selectedPackages,
                onUninstall: { confirmingUninstall = true }
            )
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "shippingbox",
                description: Text("Select a package to see its details.")
            )
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if selection.count > 1 {
                bulkMenu
            }
            Toggle(isOn: $compactRows) {
                Label("Compact List", systemImage: "rectangle.compress.vertical")
            }
            .help("Toggle compact rows")
            Button {
                Task { await app.packages.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh package list (⌘R)")
            .disabled(app.packages.isLoading)
        }
    }

    private var bulkMenu: some View {
        Menu {
            let packages = selectedPackages
            Button("Upgrade Selected") {
                Task { await app.packages.upgrade(packages.filter(\.isOutdated)) }
            }
            .disabled(!packages.contains(where: \.isOutdated))

            Button("Uninstall Selected…", role: .destructive) {
                confirmingUninstall = true
            }

            Divider()

            Button("Pin Selected") {
                Task {
                    for package in packages where package.kind == .formula && !package.isPinned {
                        await app.packages.setPinned(package, pinned: true)
                    }
                }
            }
            Button("Unpin Selected") {
                Task {
                    for package in packages where package.kind == .formula && package.isPinned {
                        await app.packages.setPinned(package, pinned: false)
                    }
                }
            }

            Divider()

            Button("Add to Favorites") {
                for package in packages where !app.meta.isFavorite(package.id) {
                    app.meta.toggleFavorite(package.id)
                }
            }
            Button("Remove from Favorites") {
                for package in packages where app.meta.isFavorite(package.id) {
                    app.meta.toggleFavorite(package.id)
                }
            }
        } label: {
            Label("Actions (\(selection.count))", systemImage: "ellipsis.circle")
        }
    }
}

// MARK: - Row

struct PackageRowView: View {
    @Environment(AppState.self) private var app
    let package: BrewPackage
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            PackageIconView(package: package, size: compact ? 20 : 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(package.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if package.displayName != package.name {
                        Text(package.name)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if package.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if app.meta.isFavorite(package.id) {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                    }
                    if package.installedAsDependency && !package.installedOnRequest {
                        TinyBadge(text: "dep")
                    }
                    if package.isDeprecated || package.isDisabled {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    if package.isFromThirdPartyTap {
                        TinyBadge(text: "tap", color: .purple)
                    }
                }
                if !compact, let desc = package.desc {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if package.isOutdated, let latest = package.latestVersion {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(package.installedVersion ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(latest)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            } else {
                Text(package.installedVersion ?? package.latestVersion ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, compact ? 1 : 3)
    }
}

// MARK: - Context menu

struct PackageContextMenu: View {
    @Environment(AppState.self) private var app
    let package: BrewPackage

    var body: some View {
        if package.isOutdated {
            Button("Upgrade") {
                Task { await app.packages.upgrade([package]) }
            }
        }
        if package.isInstalled {
            Button("Uninstall") {
                Task { await app.packages.uninstall([package]) }
            }
            if package.kind == .cask {
                Button("Uninstall (Zap)") {
                    Task { await app.packages.uninstall([package], zap: true) }
                }
            }
        } else {
            Button("Install") {
                Task { await app.packages.install(package) }
            }
        }

        Divider()

        Button(app.meta.isFavorite(package.id) ? "Remove from Favorites" : "Add to Favorites") {
            app.meta.toggleFavorite(package.id)
        }
        if package.kind == .formula {
            Button(package.isPinned ? "Unpin" : "Pin") {
                Task { await app.packages.setPinned(package, pinned: !package.isPinned) }
            }
        }

        if !app.meta.collections.isEmpty {
            Menu("Collections") {
                ForEach(app.meta.collections) { collection in
                    Button {
                        app.meta.toggleMembership(packageID: package.id, collectionID: collection.id)
                    } label: {
                        if collection.packageIDs.contains(package.id) {
                            Label(collection.name, systemImage: "checkmark")
                        } else {
                            Text(collection.name)
                        }
                    }
                }
            }
        }

        Divider()

        if let homepage = package.homepage, let url = URL(string: homepage) {
            Link("Open Homepage", destination: url)
        }
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(package.name, forType: .string)
        }
    }
}

// MARK: - Multi selection pane

struct MultiSelectionPane: View {
    @Environment(AppState.self) private var app
    let packages: [BrewPackage]
    var onUninstall: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("\(packages.count) packages selected")
                .font(.title3.weight(.semibold))

            let outdated = packages.filter(\.isOutdated)
            VStack(spacing: 8) {
                Button {
                    Task { await app.packages.upgrade(outdated) }
                } label: {
                    Label("Upgrade \(outdated.count)", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .disabled(outdated.isEmpty)

                Button(role: .destructive) {
                    onUninstall()
                } label: {
                    Label("Uninstall…", systemImage: "trash")
                        .frame(maxWidth: 180)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
