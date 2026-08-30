import SwiftUI

/// Searches Homebrew formulae, casks and third-party taps from one search bar.
/// Fully qualified tap paths (user/repo/name) are supported, and missing taps
/// can be added automatically.
struct SearchView: View {
    @Environment(AppState.self) private var app

    @State private var query = ""
    @State private var isSearching = false
    @State private var results: [BrewPackage] = []
    @State private var selection: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchedOnce = false

    private var tapQualified: (tap: String, name: String)? {
        let parts = query.split(separator: "/").map(String.init)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return ("\(parts[0])/\(parts[1])", parts[2])
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                searchBar
                Divider()
                resultsList
            }
            .frame(minWidth: 400, idealWidth: 560, maxWidth: .infinity)

            detailColumn
                .frame(minWidth: 320, idealWidth: 400, maxWidth: 520)
        }
        .navigationTitle("Search")
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search formulae, casks, or user/repo/package…", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { startSearch() }
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                        searchedOnce = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            if let qualified = tapQualified, !app.taps.isTapped(qualified.tap) {
                HStack(spacing: 8) {
                    Label("Tap \(qualified.tap) is not added yet.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Add Tap & Install") {
                        Task {
                            if await app.taps.addTap(qualified.tap) {
                                await app.packages.install(name: query, kind: .formula)
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            guard newValue.count >= 2 else { return }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                startSearch()
            }
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        if results.isEmpty {
            if isSearching {
                VStack { Spacer(); ProgressView("Searching…"); Spacer() }
            } else if searchedOnce {
                ContentUnavailableView.search(text: query)
            } else {
                ContentUnavailableView(
                    "Search Homebrew",
                    systemImage: "magnifyingglass",
                    description: Text("Search across formulae, casks and your third-party taps.\nTip: paste a full tap path like `owner/tap/package`.")
                )
            }
        } else {
            List(selection: $selection) {
                let formulaResults = results.filter { $0.kind == .formula }
                let caskResults = results.filter { $0.kind == .cask }
                if !formulaResults.isEmpty {
                    Section("Formulae (\(formulaResults.count))") {
                        ForEach(formulaResults) { package in
                            SearchResultRow(package: package)
                                .tag(package.id)
                        }
                    }
                }
                if !caskResults.isEmpty {
                    Section("Casks (\(caskResults.count))") {
                        ForEach(caskResults) { package in
                            SearchResultRow(package: package)
                                .tag(package.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let id = selection, let package = results.first(where: { $0.id == id }) {
            PackageDetailView(package: app.packages.package(id: id) ?? package)
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "shippingbox",
                description: Text("Select a result to inspect dependencies, license, caveats and disk usage before installing.")
            )
        }
    }

    // MARK: Search execution

    private func startSearch() {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { return }
        isSearching = true
        Task {
            let client = app.packages.client
            let (formulaNames, caskNames) = await client.search(query: term)
            let info = await client.infoJSON(
                formulae: Array(formulaNames.prefix(25)),
                casks: Array(caskNames.prefix(25))
            )
            var found: [BrewPackage] = []
            found += info.formulae.map { Self.searchPackage(from: $0, store: app.packages) }
            found += info.casks.map { Self.searchCaskPackage(from: $0, store: app.packages) }

            // Names that brew search returned but info didn't resolve (e.g. from an
            // un-tapped third-party tap) still get a minimal entry.
            let resolved = Set(found.map(\.name))
            for name in formulaNames.prefix(25) where !resolved.contains(name) {
                found.append(BrewPackage(kind: .formula, name: name, displayName: name))
            }
            for name in caskNames.prefix(25) where !resolved.contains(name) {
                found.append(BrewPackage(kind: .cask, name: name, displayName: name))
            }

            results = found
            isSearching = false
            searchedOnce = true
            if selection == nil { selection = found.first?.id }
        }
    }

    static func searchPackage(from json: FormulaJSON, store: PackageStore) -> BrewPackage {
        if let installed = PackageStore.package(from: json) { return installed }
        var package = BrewPackage(
            kind: .formula,
            name: json.name,
            displayName: json.name,
            desc: json.desc,
            homepage: json.homepage,
            license: json.license,
            tap: json.tap
        )
        package.latestVersion = json.versions?.stable
        package.isDeprecated = json.deprecated ?? false
        package.deprecationReason = json.deprecation_reason
        package.isDisabled = json.disabled ?? false
        package.caveats = json.caveats
        package.dependencies = json.dependencies ?? []
        return package
    }

    static func searchCaskPackage(from json: CaskJSON, store: PackageStore) -> BrewPackage {
        PackageStore.package(from: json)
    }
}

private struct SearchResultRow: View {
    @Environment(AppState.self) private var app
    let package: BrewPackage

    var body: some View {
        HStack(spacing: 10) {
            PackageIconView(package: package, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.displayName).fontWeight(.medium)
                    if package.displayName != package.name {
                        Text(package.name).font(.caption).foregroundStyle(.tertiary)
                    }
                    if package.isFromThirdPartyTap {
                        TinyBadge(text: package.tap ?? "tap", color: .purple)
                    }
                }
                if let desc = package.desc {
                    Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if package.isInstalled {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Install") {
                    Task { await app.packages.install(package) }
                }
                .controlSize(.small)
                .disabled(app.console.isBusy)
            }
        }
        .padding(.vertical, 2)
    }
}
