import SwiftUI

// MARK: - App Updates (Sparkle feeds)

/// Apps that update themselves via Sparkle: compares each app's version against
/// its own appcast feed - useful for casks marked `auto_updates` whose Homebrew
/// version lags behind.
struct AppUpdatesView: View {
    @Environment(AppState.self) private var app
    @State private var showAll = false
    @State private var notesTarget: SparkleUpdate?
    @State private var showingBackups = false

    private var rows: [SparkleUpdate] {
        showAll ? app.appUpdates.results : app.appUpdates.availableUpdates
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("App Updates")
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Show All", isOn: $showAll)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button {
                    showingBackups = true
                } label: {
                    Label("Backups", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    Task { await app.appUpdates.scan(casks: app.packages.casks) }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(app.appUpdates.isScanning)
            }
            .padding(12)
            Divider()

            if app.appUpdates.isScanning && rows.isEmpty {
                Spacer()
                ProgressView("Checking Sparkle feeds…")
                Spacer()
            } else if rows.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No app updates",
                    systemImage: "checkmark.seal",
                    description: Text(app.appUpdates.lastScan == nil
                        ? "Run a scan to check apps that ship their own Sparkle updater."
                        : "All \(app.appUpdates.checkedCount) Sparkle-updated apps are current.")
                )
                Spacer()
            } else {
                List(rows) { update in
                    SparkleUpdateRow(update: update, onShowNotes: { notesTarget = update })
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("App Updates")
        .sheet(item: $notesTarget) { update in
            ReleaseNotesSheet(update: update)
                .environment(app)
        }
        .sheet(isPresented: $showingBackups) {
            BackupsSheet()
                .environment(app)
        }
        .task {
            if app.appUpdates.lastScan == nil && !app.appUpdates.isScanning {
                await app.appUpdates.scan(casks: app.packages.casks)
            }
        }
    }

    private var subtitle: String {
        if app.appUpdates.isScanning { return "Scanning appcast feeds…" }
        let count = app.appUpdates.availableUpdates.count
        if let last = app.appUpdates.lastScan {
            return "\(count) update\(count == 1 ? "" : "s") available · checked \(app.appUpdates.checkedCount) apps \(Format.relative(last))"
        }
        return "Checks apps that update themselves via Sparkle"
    }
}

private struct SparkleUpdateRow: View {
    @Environment(AppState.self) private var app
    let update: SparkleUpdate
    var onShowNotes: () -> Void

    private var phase: AppUpdateInstaller.Phase {
        app.installer.phase(for: update.appPath)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIconCache.shared.icon(forPath: update.appPath))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(update.appName).fontWeight(.medium)
                    if let token = update.managedByCask {
                        TinyBadge(text: token, color: .blue)
                    }
                }
                HStack(spacing: 4) {
                    Text(update.currentVersion)
                        .font(.caption)
                        .foregroundStyle(update.hasUpdate ? Color.secondary : Color.green)
                    if update.hasUpdate {
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(update.latestVersion)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                        if let bytes = update.enclosureBytes {
                            Text("· \(Format.bytes(bytes))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                phaseLine
            }
            Spacer()
            TinyBadge(text: "Sparkle", color: .teal)
            if update.hasUpdate {
                Button {
                    onShowNotes()
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("What's new in \(update.latestVersion)")

                trailingAction
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var phaseLine: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .downloading(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .controlSize(.small)
                    .frame(width: 120)
                Text(progress.map { "\(Int($0 * 100))%" } ?? "Downloading…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .backingUp:
            Text("Backing up current version…").font(.caption2).foregroundStyle(.secondary)
        case .extracting:
            Text("Extracting update…").font(.caption2).foregroundStyle(.secondary)
        case .installing:
            Text("Installing…").font(.caption2).foregroundStyle(.secondary)
        case .finished(let note):
            Label(note, systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "xmark.circle")
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var trailingAction: some View {
        if let token = update.managedByCask {
            Button("brew upgrade") {
                if let package = app.packages.package(id: BrewPackage.makeID(kind: .cask, name: token)) {
                    Task { await app.packages.upgrade([package]) }
                }
            }
            .controlSize(.small)
            .help("This app is managed by Homebrew - upgrade the cask")
        } else if phase.isActive {
            ProgressView().controlSize(.small)
        } else if update.downloadURL != nil {
            Button {
                Task { await app.installer.performUpdate(update) }
            } label: {
                Label("Update", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Download, back up the old version, and install automatically")
        } else {
            Button {
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: update.appPath),
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .help("Open the app to update via its built-in updater")
        }
    }
}

// MARK: - Adopt Apps

/// Apps already in /Applications that Homebrew doesn't manage yet:
/// `brew install --cask --adopt` takes them over so future updates run through brew.
struct AdoptAppsView: View {
    @Environment(AppState.self) private var app

    private var adoptableRows: [AdoptRow] {
        app.adopt.rows.filter {
            if case .appStore = $0.state { return false }
            return true
        }
    }

    private var appStoreRows: [AdoptRow] {
        app.adopt.rows.filter {
            if case .appStore = $0.state { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adopt Apps").font(.title3.weight(.semibold))
                    Text("Bring apps you installed manually under Homebrew's control (`brew install --cask --adopt`).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await app.adopt.scan() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(app.adopt.isScanning)
            }
            .padding(12)
            Divider()

            if app.adopt.isScanning && app.adopt.rows.isEmpty {
                Spacer()
                ProgressView("Scanning /Applications…")
                Spacer()
            } else if app.adopt.rows.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "Nothing to adopt",
                    systemImage: "checkmark.circle",
                    description: Text(app.adopt.lastScan == nil
                        ? "Run a scan to find apps Homebrew could manage."
                        : "Every app in /Applications is already managed by Homebrew or the App Store.")
                )
                Spacer()
            } else {
                List {
                    if !adoptableRows.isEmpty {
                        Section("Candidates (\(adoptableRows.count))") {
                            ForEach(adoptableRows) { row in
                                AdoptRowView(row: row)
                            }
                        }
                    }
                    if !appStoreRows.isEmpty {
                        Section("Managed by the App Store (\(appStoreRows.count))") {
                            ForEach(appStoreRows) { row in
                                HStack(spacing: 10) {
                                    Image(nsImage: AppIconCache.shared.icon(forPath: row.app.url.path))
                                        .resizable().frame(width: 26, height: 26)
                                    Text(row.app.name)
                                    Spacer()
                                    TinyBadge(text: "App Store", color: .blue)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Adopt Apps")
        .task {
            if app.adopt.lastScan == nil && !app.adopt.isScanning {
                await app.adopt.scan()
            }
        }
    }
}

private struct AdoptRowView: View {
    @Environment(AppState.self) private var app
    let row: AdoptRow

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIconCache.shared.icon(forPath: row.app.url.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.app.name).fontWeight(.medium)
                Text(row.app.shortVersion ?? "unknown version")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch row.state {
            case .idle:
                Text("Not checked").font(.caption).foregroundStyle(.tertiary)
            case .searching:
                ProgressView().controlSize(.small)
            case .adoptable(let token):
                if row.candidates.count > 1 {
                    Menu(token) {
                        ForEach(row.candidates, id: \.self) { candidate in
                            Button(candidate) {
                                Task { await app.adopt.adopt(rowID: row.id, token: candidate) }
                            }
                        }
                    }
                    .fixedSize()
                } else {
                    TinyBadge(text: token, color: .green)
                }
                Button("Adopt") {
                    Task { await app.adopt.adopt(rowID: row.id, token: token) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .noMatch:
                Text("No matching cask").font(.caption).foregroundStyle(.tertiary)
                Button("Search") {
                    Task { await app.adopt.searchCandidates(forRowWithID: row.id) }
                }
                .controlSize(.small)
            case .appStore:
                TinyBadge(text: "App Store", color: .blue)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Apple Silicon

struct AppleSiliconView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Silicon").font(.title3.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await app.arch.scan() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(app.arch.isScanning)
            }
            .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if BrewEnvironment.current.isRosettaBrew {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Homebrew is running under Rosetta", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout.weight(.semibold))
                            Text("Your brew prefix is /usr/local, the Intel location. Consider migrating to a native arm64 installation at /opt/homebrew for better performance.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle(tint: .orange)
                    }

                    if app.arch.isScanning {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Inspecting app binaries…").font(.callout).foregroundStyle(.secondary)
                        }
                    } else if app.arch.lastScan != nil {
                        HStack(spacing: 12) {
                            StatTile(value: "\(app.arch.intelOnly.count)", title: "Intel only",
                                     subtitle: "run via Rosetta 2", symbol: "tortoise", color: .orange, action: nil)
                            StatTile(value: "\(app.arch.universal.count)", title: "Universal",
                                     subtitle: "native on both", symbol: "circle.grid.2x2", color: .blue, action: nil)
                            StatTile(value: "\(app.arch.armOnly.count)", title: "Apple Silicon",
                                     subtitle: "arm64 native", symbol: "cpu", color: .green, action: nil)
                        }

                        if !app.arch.intelOnly.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Intel-only apps")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                ForEach(app.arch.intelOnly) { info in
                                    HStack(spacing: 10) {
                                        Image(nsImage: AppIconCache.shared.icon(forPath: info.path))
                                            .resizable().frame(width: 26, height: 26)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(info.name).font(.callout)
                                            Text(info.path).font(.caption2).foregroundStyle(.tertiary)
                                                .lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        TinyBadge(text: "x86_64", color: .orange)
                                    }
                                    .padding(.vertical, 2)
                                }
                                Text("Tip: many of these have native builds - reinstalling through Homebrew usually fetches the Apple Silicon version.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            }
                            .cardStyle()
                        } else {
                            Label("No Intel-only apps found - everything runs natively. 🎉", systemImage: "checkmark.seal")
                                .font(.callout)
                                .cardStyle(tint: .green)
                        }
                    } else {
                        ContentUnavailableView(
                            "Not scanned yet",
                            systemImage: "cpu",
                            description: Text("Scan /Applications to find apps still running under Rosetta 2.")
                        )
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Apple Silicon")
        .task {
            if app.arch.lastScan == nil && !app.arch.isScanning {
                await app.arch.scan()
            }
        }
    }

    private var subtitle: String {
        BrewEnvironment.current.isAppleSiliconMachine
            ? "This Mac runs on Apple Silicon - find apps still built for Intel."
            : "This Mac has an Intel processor."
    }
}

// MARK: - Mac App Store (mas)

struct MasView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if !app.mas.isAvailable {
                ContentUnavailableView {
                    Label("mas CLI not installed", systemImage: "bag")
                } description: {
                    Text("Brewer integrates with the `mas` command-line tool to list and upgrade Mac App Store apps.")
                } actions: {
                    Button("Install mas via Homebrew") {
                        Task { await app.mas.installMasCLI(packages: app.packages) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                masContent
            }
        }
        .navigationTitle("App Store")
        .task {
            await app.mas.refresh()
        }
    }

    private var masContent: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac App Store").font(.title3.weight(.semibold))
                    Text("\(app.mas.installed.count) apps installed · \(app.mas.outdated.count) outdated")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !app.mas.outdated.isEmpty {
                    Button {
                        Task { await app.mas.upgradeAll() }
                    } label: {
                        Label("Upgrade All", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    Task { await app.mas.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(app.mas.isLoading)
            }
            .padding(12)
            Divider()

            if app.mas.isLoading && app.mas.installed.isEmpty {
                Spacer()
                ProgressView("Loading App Store apps…")
                Spacer()
            } else {
                List {
                    if !app.mas.outdated.isEmpty {
                        Section("Updates (\(app.mas.outdated.count))") {
                            ForEach(app.mas.outdated) { masApp in
                                MasRow(masApp: masApp, showsUpgrade: true)
                            }
                        }
                    }
                    Section("Installed (\(app.mas.installed.count))") {
                        ForEach(app.mas.installed) { masApp in
                            MasRow(masApp: masApp, showsUpgrade: false)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct MasRow: View {
    @Environment(AppState.self) private var app
    let masApp: MasApp
    let showsUpgrade: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bag.fill")
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(masApp.name).fontWeight(.medium)
                HStack(spacing: 4) {
                    Text(masApp.version).font(.caption).foregroundStyle(.secondary)
                    if let newVersion = masApp.newVersion {
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(newVersion).font(.caption.weight(.semibold)).foregroundStyle(.blue)
                    }
                }
            }
            Spacer()
            Text(masApp.adamID)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if showsUpgrade {
                if app.console.isPending(subject: "mas:\(masApp.adamID)") {
                    ProgressView().controlSize(.small).help("Queued")
                } else {
                    Button("Upgrade") {
                        Task { await app.mas.upgrade(masApp) }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
