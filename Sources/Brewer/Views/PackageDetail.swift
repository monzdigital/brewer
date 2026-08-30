import SwiftUI

/// Full detail pane for a single package: info grid, caveats, dependencies,
/// notes, tags, collections, quarantine handling and actions.
struct PackageDetailView: View {
    @Environment(AppState.self) private var app
    let package: BrewPackage

    @State private var isQuarantined: Bool?
    @State private var showingDepsTree = false
    @State private var dependents: [String]?
    @State private var loadingDependents = false
    @State private var newTagText = ""
    @State private var newCollectionName = ""
    @State private var askingNewCollection = false

    /// Prefer live data from the store (it changes after upgrades/uninstalls).
    private var live: BrewPackage {
        app.packages.package(id: package.id) ?? package
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actionRow
                if live.isDeprecated || live.isDisabled {
                    deprecationBanner
                }
                infoSection
                if let desc = live.desc {
                    section("Description") {
                        Text(desc).font(.callout)
                    }
                }
                if let caveats = live.caveats, !caveats.isEmpty {
                    caveatsSection(caveats)
                }
                if !live.dependencies.isEmpty || live.kind == .formula {
                    dependenciesSection
                }
                notesSection
                tagsSection
                collectionsSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: live.id + (live.appPath ?? "")) {
            isQuarantined = nil
            dependents = nil
            if let appPath = live.appPath {
                isQuarantined = await Quarantine.isQuarantined(appPath: appPath)
            }
        }
        .sheet(isPresented: $showingDepsTree) {
            DepsTreeSheet(package: live)
        }
        .alert("New Collection", isPresented: $askingNewCollection) {
            TextField("Name", text: $newCollectionName)
            Button("Create") {
                let name = newCollectionName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let collection = app.meta.addCollection(named: name)
                app.meta.toggleMembership(packageID: live.id, collectionID: collection.id)
                newCollectionName = ""
            }
            Button("Cancel", role: .cancel) { newCollectionName = "" }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            PackageIconView(package: live, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(live.displayName)
                    .font(.title2.bold())
                HStack(spacing: 6) {
                    if live.displayName != live.name {
                        Text(live.name).font(.caption).foregroundStyle(.secondary)
                    }
                    KindChip(kind: live.kind)
                    if live.isPinned { TinyBadge(text: "Pinned", color: .orange) }
                }
            }
            Spacer()
            Button {
                app.meta.toggleFavorite(live.id)
            } label: {
                Image(systemName: app.meta.isFavorite(live.id) ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(app.meta.isFavorite(live.id) ? .pink : .secondary)
            }
            .buttonStyle(.plain)
            .help("Favorite")
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            if !live.isInstalled {
                Button {
                    Task { await app.packages.install(live) }
                } label: {
                    Label("Install", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
            } else if live.isOutdated {
                Button {
                    Task { await app.packages.upgrade([live]) }
                } label: {
                    Label("Upgrade", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
            }

            if live.isInstalled {
                Menu {
                    Button("Uninstall", role: .destructive) {
                        Task { await app.packages.uninstall([live]) }
                    }
                    if live.kind == .cask {
                        Button("Uninstall (Zap - remove all data)", role: .destructive) {
                            Task { await app.packages.uninstall([live], zap: true) }
                        }
                    }
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
                .fixedSize()

                if live.kind == .formula {
                    Button {
                        Task { await app.packages.setPinned(live, pinned: !live.isPinned) }
                    } label: {
                        Label(live.isPinned ? "Unpin" : "Pin", systemImage: live.isPinned ? "pin.slash" : "pin")
                    }
                    .help("Pinned formulae are skipped by brew upgrade")
                }
            }

            Spacer()

            if app.console.isBusy {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var deprecationBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(live.isDisabled ? "This package is disabled" : "This package is deprecated",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
            if let reason = live.deprecationReason {
                Text(reason).font(.caption)
            }
            Text("Consider finding a replacement.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(tint: .yellow)
    }

    // MARK: Info grid

    private var infoSection: some View {
        section("Information") {
            VStack(alignment: .leading, spacing: 8) {
                if let installed = live.installedVersion {
                    InfoRow(label: "Installed Version", value: installed)
                }
                if let latest = live.latestVersion {
                    InfoRow(label: "Latest Version", value: latest, valueColor: live.isOutdated ? .blue : nil)
                }
                if let homepage = live.homepage {
                    InfoRow(label: "Homepage", value: homepage, link: URL(string: homepage))
                }
                InfoRow(label: "Type", value: live.kind == .formula ? "Formula (CLI)" : "Cask (GUI App)")
                if let tap = live.tap {
                    InfoRow(label: "Tap", value: tap)
                }
                if let license = live.license {
                    InfoRow(label: "License", value: license)
                }
                if live.kind == .cask {
                    InfoRow(label: "Auto-updates itself", value: live.autoUpdates ? "Yes" : "No")
                }
                if let date = live.installedDate {
                    InfoRow(label: "Installed", value: date.formatted(date: .abbreviated, time: .omitted))
                }
                if live.isInstalled {
                    sizeRow
                }
                if let appPath = live.appPath {
                    InfoRow(label: "App", value: appPath)
                    quarantineRow(appPath: appPath)
                }
                if live.installedAsDependency && !live.installedOnRequest {
                    InfoRow(label: "Installed as", value: "Dependency of another package")
                }
            }
        }
    }

    private var sizeRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Size")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            if let size = app.packages.sizeCache[live.id] {
                Text(size > 0 ? Format.bytes(size) : "-")
                    .font(.callout)
            } else {
                Text("Calculating…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .onAppear { app.packages.computeSizeIfNeeded(for: live) }
            }
        }
    }

    private func quarantineRow(appPath: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Quarantine Status")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            switch isQuarantined {
            case .none:
                Text("Checking…").font(.callout).foregroundStyle(.tertiary)
            case .some(false):
                Label("Not quarantined", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
            case .some(true):
                HStack(spacing: 8) {
                    Label("Quarantined", systemImage: "exclamationmark.shield")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("Remove") {
                        Task {
                            _ = await Quarantine.remove(appPath: appPath)
                            isQuarantined = await Quarantine.isQuarantined(appPath: appPath)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func caveatsSection(_ caveats: String) -> some View {
        section("Caveats") {
            Text(caveats)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle(tint: .yellow)
        }
    }

    // MARK: Dependencies

    private var dependenciesSection: some View {
        section("Dependencies") {
            VStack(alignment: .leading, spacing: 8) {
                if live.dependencies.isEmpty {
                    Text("No runtime dependencies.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 5) {
                        ForEach(live.dependencies, id: \.self) { dep in
                            let installed = app.packages.package(id: BrewPackage.makeID(kind: .formula, name: dep)) != nil
                            TinyBadge(text: dep, color: installed ? .green : .secondary)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button("Dependency Tree…") { showingDepsTree = true }
                        .controlSize(.small)
                    if live.kind == .formula {
                        Button(loadingDependents ? "Loading…" : "Show Dependents") {
                            loadingDependents = true
                            Task {
                                dependents = await app.packages.client.dependents(of: live.name)
                                loadingDependents = false
                            }
                        }
                        .controlSize(.small)
                        .disabled(loadingDependents)
                    }
                }
                if let dependents {
                    if dependents.isEmpty {
                        Text("No installed packages depend on this.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 5) {
                            ForEach(dependents, id: \.self) { name in
                                TinyBadge(text: name, color: .blue)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Notes / tags / collections

    private var notesSection: some View {
        section("Notes") {
            TextEditor(text: Binding(
                get: { app.meta.note(for: live.id) },
                set: { app.meta.setNote($0, for: live.id) }
            ))
            .font(.callout)
            .frame(height: 64)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var tagsSection: some View {
        section("Tags") {
            VStack(alignment: .leading, spacing: 8) {
                let tags = app.meta.tags(for: live.id)
                if !tags.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(tags, id: \.self) { tag in
                            HStack(spacing: 3) {
                                Text(tag).font(.caption)
                                Button {
                                    app.meta.removeTag(tag, from: live.id)
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 8))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                }
                TextField("Add tag…", text: $newTagText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 160)
                    .onSubmit {
                        app.meta.addTag(newTagText, to: live.id)
                        newTagText = ""
                    }
            }
        }
    }

    private var collectionsSection: some View {
        section("Collections") {
            HStack {
                Menu {
                    ForEach(app.meta.collections) { collection in
                        Button {
                            app.meta.toggleMembership(packageID: live.id, collectionID: collection.id)
                        } label: {
                            if collection.packageIDs.contains(live.id) {
                                Label(collection.name, systemImage: "checkmark")
                            } else {
                                Text(collection.name)
                            }
                        }
                    }
                    Divider()
                    Button("New Collection…") { askingNewCollection = true }
                } label: {
                    let memberships = app.meta.collections.filter { $0.packageIDs.contains(live.id) }
                    if memberships.isEmpty {
                        Label("Add to Collection", systemImage: "rectangle.stack.badge.plus")
                    } else {
                        Label(memberships.map(\.name).joined(separator: ", "), systemImage: "rectangle.stack")
                    }
                }
                .fixedSize()
            }
        }
    }

    // MARK: Helpers

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }
}

// MARK: - Info row

struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color?
    var link: URL?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            if let link {
                Link(value, destination: link)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(value)
                    .font(.callout)
                    .foregroundStyle(valueColor ?? .primary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }
}

// MARK: - Dependency tree sheet

struct DepsTreeSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let package: BrewPackage

    @State private var nodes: [DepTreeNode]?
    @State private var rawText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Dependency tree for \(package.name)", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()

            Group {
                if let nodes {
                    if nodes.isEmpty {
                        ContentUnavailableView("No dependencies", systemImage: "checkmark.circle",
                            description: Text(rawText.isEmpty ? "" : rawText).font(.caption))
                    } else {
                        List(nodes, children: \.children) { node in
                            Label(node.name, systemImage: "cube")
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                } else {
                    ProgressView("Resolving dependencies…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 460, height: 480)
        .task {
            let text = await app.packages.client.depsTreeText(for: package.name, cask: package.kind == .cask)
            rawText = text
            nodes = DepsTreeParser.parse(text)
        }
    }
}
