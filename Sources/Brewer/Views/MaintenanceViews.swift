import SwiftUI

// MARK: - Health dashboard

struct HealthView: View {
    @Environment(AppState.self) private var app

    private var issueCount: Int { app.health.doctorWarnings.count }
    private var score: Int {
        app.health.healthScore(outdatedCount: app.packages.outdatedCount, issueCount: issueCount)
    }

    private var statusLabel: (String, Color) {
        if app.packages.outdatedCount == 0 && issueCount == 0 { return ("Good", .green) }
        if app.packages.outdatedCount > 30 || issueCount > 3 { return ("Warning", .orange) }
        return ("Fair", .yellow)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("System Health").font(.title.bold())
                        HStack(spacing: 6) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(statusLabel.1)
                            Text(statusLabel.0)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(statusLabel.1)
                            if let updated = app.health.lastRefreshed {
                                Text("· Updated \(Format.relative(updated))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    ZStack {
                        Circle()
                            .stroke(statusLabel.1.opacity(0.2), lineWidth: 7)
                        Circle()
                            .trim(from: 0, to: CGFloat(score) / 100)
                            .stroke(statusLabel.1, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(score)")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                    }
                    .frame(width: 64, height: 64)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    StatTile(
                        value: "\(app.packages.outdatedCount)",
                        title: "Outdated",
                        subtitle: "packages need updates",
                        symbol: "arrow.triangle.2.circlepath",
                        color: app.packages.outdatedCount > 0 ? .orange : .green
                    ) { app.selection = .updates }

                    StatTile(
                        value: "\(app.packages.deprecatedOrDisabled.count)",
                        title: "Deprecated",
                        subtitle: "deprecated or disabled packages",
                        symbol: "shield.lefthalf.filled",
                        color: app.packages.deprecatedOrDisabled.isEmpty ? .green : .red
                    ) { app.selection = .diagnostics }

                    StatTile(
                        value: "\(app.health.orphans?.count ?? 0)",
                        title: "Orphaned",
                        subtitle: "unused dependencies",
                        symbol: "cube.transparent",
                        color: (app.health.orphans?.isEmpty ?? true) ? .green : .yellow
                    ) { app.selection = .diagnostics }

                    StatTile(
                        value: app.health.cacheBytes.map(Format.bytes) ?? "…",
                        title: "Cache",
                        subtitle: "can be cleaned",
                        symbol: "internaldrive",
                        color: .purple
                    ) { app.selection = .cleanup }

                    StatTile(
                        value: app.health.doctorLastRun == nil ? "-" : "\(issueCount)",
                        title: "Issues",
                        subtitle: app.health.doctorLastRun == nil ? "run brew doctor" : "from brew doctor",
                        symbol: "stethoscope",
                        color: issueCount > 0 ? .yellow : .green
                    ) { app.selection = .diagnostics }

                    StatTile(
                        value: "\(score)%",
                        title: "Score",
                        subtitle: "health rating",
                        symbol: "chart.bar.fill",
                        color: statusLabel.1,
                        action: nil
                    )
                }

                Text("Quick Actions")
                    .font(.headline)
                HStack(spacing: 10) {
                    Button {
                        Task { await app.packages.upgradeAll() }
                    } label: {
                        Label("Update All", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(app.packages.outdatedCount == 0)

                    Button {
                        Task { await app.health.clearCache(scrub: false) }
                    } label: {
                        Label("Clear Cache", systemImage: "trash")
                    }

                    Button {
                        app.selection = .diagnostics
                        Task { await app.health.runDoctor() }
                    } label: {
                        Label("Run Doctor", systemImage: "stethoscope")
                    }
                    .disabled(app.health.doctorRunning)

                    if app.health.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(18)
        }
        .navigationTitle("Health")
        .task {
            if app.health.lastRefreshed == nil {
                await app.health.refreshMetrics()
            }
        }
        .toolbar {
            Button {
                Task { await app.health.refreshMetrics() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(app.health.isRefreshing)
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PaneHeader(title: "Diagnostics", subtitle: "Check system health, spot risky packages, and read brew doctor without the wall of text.")

                securityCard
                orphansCard
                doctorCard
            }
            .padding(18)
        }
        .navigationTitle("Diagnostics")
        .task {
            if app.health.lastRefreshed == nil {
                await app.health.refreshMetrics()
            }
        }
    }

    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Package Risk Scan", systemImage: "shield.lefthalf.filled")
                    .font(.headline)
                Spacer()
                Text("checks for deprecated & disabled packages")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            let risky = app.packages.deprecatedOrDisabled
            if risky.isEmpty {
                Label("No deprecated or disabled packages found", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(risky) { package in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(package.isDisabled ? .red : .yellow)
                            Text(package.name).fontWeight(.medium)
                            KindChip(kind: package.kind)
                            TinyBadge(text: package.isDisabled ? "disabled" : "deprecated",
                                      color: package.isDisabled ? .red : .yellow)
                        }
                        if let reason = package.deprecationReason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 22)
                        }
                    }
                    .padding(.vertical, 3)
                }
                Text("Deprecated packages stop receiving updates (including security fixes). Find replacements when possible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var orphansCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Orphaned Packages", systemImage: "cube.transparent")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await app.health.refreshMetrics() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(app.health.isRefreshing)
            }
            Text("Packages installed as dependencies that are no longer needed by anything.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let orphans = app.health.orphans {
                if orphans.isEmpty {
                    Label("No orphaned packages", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    FlowLayout(spacing: 5) {
                        ForEach(orphans, id: \.self) { name in
                            TinyBadge(text: name, color: .yellow)
                        }
                    }
                    Button {
                        Task { await app.health.removeOrphans() }
                    } label: {
                        Label("Remove All (\(orphans.count))", systemImage: "trash")
                    }
                }
            } else if app.health.isRefreshing {
                ProgressView().controlSize(.small)
            }
        }
        .cardStyle()
    }

    private var doctorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Brew Doctor", systemImage: "stethoscope")
                    .font(.headline)
                Spacer()
                if let run = app.health.doctorLastRun {
                    Text("Last run \(Format.relative(run))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    Task { await app.health.runDoctor() }
                } label: {
                    if app.health.doctorRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Running…")
                        }
                    } else {
                        Label("Run Doctor", systemImage: "play.fill")
                    }
                }
                .disabled(app.health.doctorRunning)
            }
            Text("Check your Homebrew installation for potential issues.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let output = app.health.doctorRaw {
                if !app.health.doctorWarnings.isEmpty {
                    Text("\(app.health.doctorWarnings.count) issue\(app.health.doctorWarnings.count == 1 ? "" : "s") found")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.yellow)
                }
                OutputTextView(text: output)
                    .frame(minHeight: 160, maxHeight: 380)
            }
        }
        .cardStyle()
    }
}

// MARK: - Cleanup

struct CleanupView: View {
    @Environment(AppState.self) private var app
    @State private var scrub = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                PaneHeader(title: "Cleanup", subtitle: "See how much space Homebrew uses and clear files you no longer need.")

                HStack(spacing: 12) {
                    StatTile(
                        value: app.health.cacheBytes.map(Format.bytes) ?? "…",
                        title: "Download cache",
                        subtitle: app.health.cachePath.isEmpty ? "" : app.health.cachePath,
                        symbol: "internaldrive",
                        color: .purple,
                        action: nil
                    )
                    StatTile(
                        value: app.health.cleanupReport?.approximateBytes.map(Format.bytes) ?? "…",
                        title: "Reclaimable",
                        subtitle: "\(app.health.cleanupReport?.items.count ?? 0) old files & versions",
                        symbol: "arrow.3.trianglepath",
                        color: .orange,
                        action: nil
                    )
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await app.health.refreshMetrics() }
                    } label: {
                        Label("Analyze", systemImage: "magnifyingglass")
                    }
                    .disabled(app.health.isRefreshing)

                    Button {
                        Task { await app.health.clearCache(scrub: scrub) }
                    } label: {
                        Label("Clean Up Now", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)

                    Toggle("Scrub cache (also delete latest downloads)", isOn: $scrub)
                        .toggleStyle(.checkbox)
                        .font(.caption)

                    if app.health.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
            }
            .padding(18)
            Divider()

            if let report = app.health.cleanupReport, !report.items.isEmpty {
                List(report.items) { item in
                    HStack {
                        Image(systemName: "doc.zipper")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.fileName).font(.callout)
                            Text(item.path)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if let bytes = item.bytes {
                            Text(Format.bytes(bytes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                Spacer()
                ContentUnavailableView(
                    app.health.cleanupReport == nil ? "Not analyzed yet" : "Nothing to clean",
                    systemImage: "sparkles",
                    description: Text(app.health.cleanupReport == nil
                        ? "Run Analyze to preview what brew cleanup would remove."
                        : "Homebrew has no stale files right now.")
                )
                Spacer()
            }
        }
        .navigationTitle("Cleanup")
        .task {
            if app.health.lastRefreshed == nil {
                await app.health.refreshMetrics()
            }
        }
    }
}

// MARK: - Duplicates

struct DuplicatesView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicates").font(.title3.weight(.semibold))
                    Text("Multiple installed versions of the same formula, and apps managed twice.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await app.duplicates.refresh(casks: app.packages.casks, masApps: app.mas.installed) }
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(app.duplicates.isLoading)
            }
            .padding(12)
            Divider()

            if let error = app.duplicates.errorMessage {
                Spacer()
                ContentUnavailableView("Couldn't scan", systemImage: "exclamationmark.triangle",
                    description: Text(error))
                Spacer()
            } else if app.duplicates.isLoading {
                Spacer()
                ProgressView("Scanning…")
                Spacer()
            } else if app.duplicates.lastScan == nil {
                Spacer()
                ContentUnavailableView("Not scanned yet", systemImage: "square.on.square",
                    description: Text("Scan to find duplicate installs."))
                Spacer()
            } else if app.duplicates.multiVersionKegs.isEmpty && app.duplicates.overlaps.isEmpty {
                Spacer()
                ContentUnavailableView("No duplicates found", systemImage: "checkmark.seal",
                    description: Text("Each package has exactly one installed version."))
                Spacer()
            } else {
                List {
                    if !app.duplicates.multiVersionKegs.isEmpty {
                        Section("Multiple versions installed (\(app.duplicates.multiVersionKegs.count))") {
                            ForEach(app.duplicates.multiVersionKegs) { keg in
                                HStack {
                                    Image(systemName: "shippingbox")
                                        .foregroundStyle(.green)
                                    Text(keg.name).fontWeight(.medium)
                                    FlowLayout(spacing: 4) {
                                        ForEach(keg.versions, id: \.self) { version in
                                            TinyBadge(text: version, color: .secondary)
                                        }
                                    }
                                    Spacer()
                                    Button("Clean Old") {
                                        Task { await app.duplicates.cleanOldVersions(of: keg.name) }
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    if !app.duplicates.overlaps.isEmpty {
                        Section("Managed twice (\(app.duplicates.overlaps.count))") {
                            ForEach(app.duplicates.overlaps) { overlap in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(overlap.name).fontWeight(.medium)
                                    Text(overlap.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Duplicates")
        .task {
            if app.duplicates.lastScan == nil && !app.duplicates.isLoading {
                await app.duplicates.refresh(casks: app.packages.casks, masApps: app.mas.installed)
            }
        }
    }
}

// MARK: - History

struct HistoryView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History").font(.title3.weight(.semibold))
                    Text("Every command Brewer ran on your behalf.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    app.history.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(app.history.entries.isEmpty)
            }
            .padding(12)
            Divider()

            if app.history.entries.isEmpty {
                Spacer()
                ContentUnavailableView("No history yet", systemImage: "clock",
                    description: Text("Install, upgrade and maintenance operations will be recorded here."))
                Spacer()
            } else {
                Table(app.history.entries) {
                    TableColumn("Status") { entry in
                        Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(entry.succeeded ? .green : .red)
                    }
                    .width(44)
                    TableColumn("Date") { entry in
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    }
                    .width(150)
                    TableColumn("Action") { entry in
                        Text(entry.title)
                    }
                    TableColumn("Command") { entry in
                        Text(entry.command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    TableColumn("Duration") { entry in
                        Text(Format.duration(entry.durationSeconds))
                            .foregroundStyle(.secondary)
                    }
                    .width(70)
                }
            }
        }
        .navigationTitle("History")
    }
}
