import SwiftUI

// MARK: - Health dashboard

struct HealthView: View {
    @Environment(AppState.self) private var app

    private var issueCount: Int { app.health.issueCount }

    private var advisoryTileColor: Color {
        if app.health.vulnsLastRun == nil { return .secondary }
        if app.health.seriousAdvisoryCount > 0 { return .red }
        return app.health.advisoryCount > 0 ? .orange : .green
    }
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

                if let notice = app.platformNotice {
                    PlatformNoticeCard(notice: notice)
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

                    if app.health.supportsStructuredDiagnostics {
                        StatTile(
                            value: app.health.vulnsLastRun == nil ? "-" : "\(app.health.advisoryCount)",
                            title: "Advisories",
                            subtitle: app.health.vulnsLastRun == nil
                                ? "run a security scan"
                                : "\(app.health.seriousAdvisoryCount) high or critical",
                            symbol: "exclamationmark.shield",
                            color: advisoryTileColor
                        ) { app.selection = .diagnostics }
                    }

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
                        Task { await app.upgradeAllVisible() }
                    } label: {
                        Label("Update All", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(app.visibleUpdateCount == 0)

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
            await app.health.detectBrewMajorIfNeeded()
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

                if let notice = app.platformNotice {
                    PlatformNoticeCard(notice: notice)
                }
                securityCard
                if app.health.supportsStructuredDiagnostics {
                    advisoriesCard
                }
                orphansCard
                doctorCard
            }
            .padding(18)
        }
        .navigationTitle("Diagnostics")
        .task {
            await app.health.detectBrewMajorIfNeeded()
            if app.health.lastRefreshed == nil {
                await app.health.refreshMetrics()
            }
        }
    }

    // MARK: Security advisories (brew vulns)

    private var advisoriesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Security Advisories", systemImage: "exclamationmark.shield")
                    .font(.headline)
                Spacer()
                if let last = app.health.vulnsLastRun {
                    Text("Scanned \(Format.relative(last))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    Task { await app.health.runVulnerabilityScan() }
                } label: {
                    if app.health.vulnsRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Scanning…")
                        }
                    } else {
                        Label(app.health.vulnsLastRun == nil ? "Scan" : "Scan Again", systemImage: "magnifyingglass")
                    }
                }
                .disabled(app.health.vulnsRunning)
            }
            Text("Checks installed formulae for known vulnerabilities with brew vulns. Formula names and versions are sent to OSV.dev; issues Homebrew already patched are not counted.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = app.health.vulnsError {
                Label(error, systemImage: "xmark.octagon")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if app.health.vulnsLastRun != nil {
                if app.health.vulnerablePackages.isEmpty {
                    Label("No known vulnerabilities in \(app.health.vulnsScannedCount.map(String.init) ?? "the") scanned formulae", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("\(app.health.advisoryCount) advisor\(app.health.advisoryCount == 1 ? "y" : "ies") in \(app.health.vulnerablePackages.count) formula\(app.health.vulnerablePackages.count == 1 ? "" : "e")")
                        .font(.callout.weight(.semibold))
                    ForEach(app.health.vulnerablePackages) { package in
                        VulnerablePackageRow(package: package)
                    }
                }
                if !app.health.vulnsUnscanned.isEmpty {
                    Text("Not scanned: \(app.health.vulnsUnscanned.keys.sorted().joined(separator: ", ")) - their taps are not trusted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .cardStyle()
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

            if app.health.doctorIsStructured {
                if app.health.doctorFindings.isEmpty {
                    Label("Your system is ready to brew.", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("\(app.health.doctorFindings.count) issue\(app.health.doctorFindings.count == 1 ? "" : "s") found")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.yellow)
                    ForEach(app.health.doctorFindings) { finding in
                        DoctorFindingRow(finding: finding)
                    }
                }
            } else if let output = app.health.doctorRaw {
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

// MARK: - Diagnostics building blocks

/// Homebrew support-tier warning (Intel, Rosetta or Sonoma under Homebrew 7).
struct PlatformNoticeCard: View {
    let notice: PlatformSupport.Notice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(notice.title, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
            Text(notice.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(tint: .orange)
    }
}

private struct DoctorFindingRow: View {
    @Environment(AppState.self) private var app
    let finding: DoctorFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(finding.title, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .labelStyle(DoctorTitleLabelStyle())
            if let details = finding.details {
                Text(details)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            if !finding.affects.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(finding.affects, id: \.self) { name in
                        TinyBadge(text: name, color: .yellow)
                    }
                }
            }
            if let remediation = finding.remediation, remediation != finding.details {
                Text(remediation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            ForEach(finding.commands, id: \.self) { command in
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy command")
                    if HealthStore.brewArguments(forRemediation: command) != nil {
                        Button("Run") {
                            Task { await app.health.runRemediation(command) }
                        }
                        .controlSize(.small)
                        .help("Run it in the console, then re-check")
                    }
                }
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            ForEach(finding.links, id: \.self) { url in
                Link("Learn more", destination: url)
                    .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Keeps the warning icon yellow while the title text stays primary.
private struct DoctorTitleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundStyle(.yellow)
            configuration.title
        }
    }
}

private struct VulnerablePackageRow: View {
    @Environment(AppState.self) private var app
    let package: VulnerablePackage
    @State private var expanded = false

    private var installed: BrewPackage? {
        app.packages.package(id: BrewPackage.makeID(kind: .formula, name: package.formula))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(package.advisories) { advisory in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SeverityBadge(severity: advisory.severity)
                        VStack(alignment: .leading, spacing: 1) {
                            if let url = advisory.url {
                                Link(advisory.id, destination: url)
                                    .font(.caption.weight(.medium))
                            } else {
                                Text(advisory.id).font(.caption.weight(.medium))
                            }
                            Text(advisory.summary.isEmpty ? "No summary published." : advisory.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Text(advisory.hasUpstreamFix ? "fixed upstream" : "no fix yet")
                            .font(.caption2)
                            .foregroundStyle(advisory.hasUpstreamFix ? .green : .secondary)
                    }
                }
                if package.patchedCount > 0 {
                    Text("Homebrew already patched \(package.patchedCount) other advisor\(package.patchedCount == 1 ? "y" : "ies") for this formula.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                SeverityBadge(severity: package.highestSeverity)
                Text(package.formula).fontWeight(.medium)
                if let version = package.version {
                    Text(version).font(.caption).foregroundStyle(.secondary)
                }
                TinyBadge(text: "\(package.advisories.count) advisor\(package.advisories.count == 1 ? "y" : "ies")", color: .secondary)
                Spacer()
                if let installed, installed.isOutdated {
                    if app.console.isPending(subject: installed.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Upgrade to \(installed.latestVersion ?? "latest")") {
                            Task { await app.packages.upgrade([installed]) }
                        }
                        .controlSize(.small)
                        .help("A newer version may contain the fix")
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SeverityBadge: View {
    let severity: Advisory.Severity

    private var color: Color {
        switch severity {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .blue
        case .unknown: return .secondary
        }
    }

    var body: some View {
        TinyBadge(text: severity.label, color: color)
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
    @State private var selection = Set<HistoryEntry.ID>()
    @State private var outputEntry: HistoryEntry?

    private func entry(_ id: HistoryEntry.ID?) -> HistoryEntry? {
        guard let id else { return nil }
        return app.history.entries.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History").font(.title3.weight(.semibold))
                    Text("Every command Brewer ran on your behalf. Double-click a failed one to read its output.")
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
                Table(app.history.entries, selection: $selection) {
                    TableColumn("Status") { entry in
                        HStack(spacing: 4) {
                            Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(entry.succeeded ? .green : .red)
                            if entry.output != nil {
                                Image(systemName: "doc.plaintext")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help("Output saved - double-click to read it")
                            }
                        }
                    }
                    .width(52)
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
                .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
                    if let entry = entry(ids.first) {
                        if entry.output != nil {
                            Button("Show Output") { outputEntry = entry }
                        }
                        Button("Copy Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.command, forType: .string)
                        }
                    }
                } primaryAction: { ids in
                    if let entry = entry(ids.first), entry.output != nil {
                        outputEntry = entry
                    }
                }
            }
        }
        .navigationTitle("History")
        .sheet(item: $outputEntry) { entry in
            HistoryOutputSheet(entry: entry)
        }
    }
}

private struct HistoryOutputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: HistoryEntry

    private var text: String { (entry.output ?? []).joined(separator: "\n") }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(entry.title, systemImage: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(entry.succeeded ? Color.primary : Color.red)
                    Text("$ \(entry.command)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text("\(entry.date.formatted(date: .abbreviated, time: .standard)) · \(Format.duration(entry.durationSeconds))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            OutputTextView(text: text.isEmpty ? "(no output was produced)" : text)
                .padding(10)
        }
        .frame(width: 720, height: 480)
    }
}
