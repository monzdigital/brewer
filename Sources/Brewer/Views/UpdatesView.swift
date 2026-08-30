import SwiftUI

/// Outdated Homebrew packages: bulk upgrade, per-package upgrade, snoozing.
struct UpdatesView: View {
    @Environment(AppState.self) private var app
    @State private var selection = Set<String>()
    @State private var confirmingUninstall = false

    private var updates: [BrewPackage] {
        app.packages(in: .updates)
    }

    private var selectedPackages: [BrewPackage] {
        app.packages.packages(ids: selection)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                listColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                detailColumn
                    .frame(width: 380)
                    .frame(maxHeight: .infinity)
            }
        }
        .navigationTitle("Updates")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await app.scheduler.check(scheduled: false) }
                } label: {
                    Label("Check Now", systemImage: "arrow.clockwise")
                }
                .disabled(app.scheduler.isChecking)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(updates.isEmpty ? "Everything is up to date" : "\(updates.count) update\(updates.count == 1 ? "" : "s") available")
                    .font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    if app.scheduler.isChecking {
                        ProgressView().controlSize(.mini)
                        Text("Checking for updates…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let last = app.scheduler.lastCheck ?? app.packages.lastRefreshed {
                        Text("Last checked \(Format.relative(last))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let next = app.scheduler.nextCheck {
                        Text("· next check \(Format.relative(next))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            Button {
                Task { await app.packages.updateHomebrewData() }
            } label: {
                Label("brew update", systemImage: "arrow.down.to.line")
            }
            .help("Refresh Homebrew's package data")
            Button {
                Task { await app.packages.upgradeAll() }
            } label: {
                Label("Upgrade All", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .disabled(updates.isEmpty || app.console.isBusy)
        }
        .padding(12)
    }

    @ViewBuilder
    private var listColumn: some View {
        if updates.isEmpty {
            VStack {
                Spacer()
                ContentUnavailableView(
                    "Everything is up to date",
                    systemImage: "checkmark.seal",
                    description: Text(app.meta.snoozedIDs.isEmpty
                        ? "All installed packages are at their latest version."
                        : "Some updates may be snoozed — check the Snoozed section.")
                )
                Spacer()
            }
        } else {
            List(selection: $selection) {
                ForEach(updates) { package in
                    UpdateRow(package: package)
                        .tag(package.id)
                        .contextMenu {
                            PackageContextMenu(package: package)
                        }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if selection.count == 1, let id = selection.first, let package = app.packages.package(id: id) {
            PackageDetailView(package: package)
        } else if selection.count > 1 {
            MultiSelectionPane(packages: selectedPackages, onUninstall: {})
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "arrow.triangle.2.circlepath",
                description: Text("Select an update to review what changed before upgrading.")
            )
        }
    }
}

private struct UpdateRow: View {
    @Environment(AppState.self) private var app
    let package: BrewPackage

    var body: some View {
        HStack(spacing: 10) {
            PackageIconView(package: package, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.displayName).fontWeight(.medium)
                    KindChip(kind: package.kind)
                    if package.isPinned {
                        TinyBadge(text: "pinned — will be skipped", color: .orange)
                    }
                }
                HStack(spacing: 4) {
                    Text(package.installedVersion ?? "?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(package.latestVersion ?? "?")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
            Spacer()
            Button {
                Task { await app.packages.upgrade([package]) }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .help("Upgrade \(package.name)")
            .disabled(app.console.isBusy)
        }
        .padding(.vertical, 3)
    }
}
