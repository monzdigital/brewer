import SwiftUI

/// MacUpdater-style full system scan: every app on the Mac with its install
/// source (Homebrew / App Store / Sparkle / manual), size and architecture.
struct AppsInventoryView: View {
    @Environment(AppState.self) private var app
    @State private var sourceFilter: AppSource?
    @State private var searchText = ""

    private var filtered: [InventoryApp] {
        var result = app.inventory.apps
        if let sourceFilter {
            result = result.filter { $0.source == sourceFilter }
        }
        if !searchText.isEmpty {
            let needle = searchText.lowercased()
            result = result.filter { $0.app.name.lowercased().contains(needle) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if app.inventory.isScanning && app.inventory.apps.isEmpty {
                Spacer()
                ProgressView("Scanning applications…")
                Spacer()
            } else if app.inventory.apps.isEmpty {
                Spacer()
                ContentUnavailableView("No apps found", systemImage: "square.grid.3x3")
                Spacer()
            } else {
                List(filtered) { item in
                    InventoryRow(item: item)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Apps")
        .task {
            if app.inventory.lastScan == nil && !app.inventory.isScanning {
                await app.inventory.scan(casks: app.packages.casks)
            }
        }
    }

    private var summary: String {
        let inventory = app.inventory
        var parts = ["\(inventory.apps.count) apps", "\(Format.bytes(inventory.totalBytes)) total"]
        for source in AppSource.allCases {
            let count = inventory.count(for: source)
            if count > 0 { parts.append("\(count) \(source == .manual ? "manual" : source.rawValue)") }
        }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("All Applications").font(.title3.weight(.semibold))
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Search apps", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
            Picker("Source", selection: $sourceFilter) {
                Text("All Sources").tag(Optional<AppSource>.none)
                ForEach(AppSource.allCases, id: \.self) { source in
                    Text(source.rawValue).tag(Optional(source))
                }
            }
            .labelsHidden()
            .frame(width: 130)
            Button {
                Task { await app.inventory.scan(casks: app.packages.casks) }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(app.inventory.isScanning)
        }
        .padding(12)
    }
}

extension AppSource {
    var badgeColor: Color {
        switch self {
        case .homebrew: return .green
        case .appStore: return .blue
        case .setapp: return .purple
        case .sparkle: return .teal
        case .manual: return .secondary
        }
    }
}

private struct InventoryRow: View {
    @Environment(AppState.self) private var app
    let item: InventoryApp

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIconCache.shared.icon(forPath: item.app.url.path))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.app.name).fontWeight(.medium)
                    TinyBadge(text: item.source.rawValue, color: item.source.badgeColor)
                    if let token = item.caskToken {
                        TinyBadge(text: token, color: .green)
                    }
                    if item.isIntelOnly {
                        TinyBadge(text: "Intel", color: .orange)
                    }
                }
                Text(item.app.shortVersion ?? "-")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.sizeBytes.map(Format.bytes) ?? "…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
            Menu {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.app.url])
                }
                Button("Open") {
                    NSWorkspace.shared.openApplication(at: item.app.url, configuration: NSWorkspace.OpenConfiguration())
                }
                Divider()
                Button("Uninstall Completely…", role: .destructive) {
                    app.selection = .uninstaller
                    Task { await app.uninstaller.beginReview(appURL: item.app.url) }
                }
                .disabled(LeftoverScanner.isProtected(bundleID: item.app.bundleID, appURL: item.app.url))
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.app.url.path, forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }
}
