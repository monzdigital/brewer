import SwiftUI

// MARK: - Taps

struct TapsView: View {
    @Environment(AppState.self) private var app
    @State private var addingTap = false
    @State private var newTapName = ""
    @State private var tapToRemove: TapItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Taps").font(.title3.weight(.semibold))
                    Text("Third-party repositories that extend Homebrew's catalog.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    addingTap = true
                } label: {
                    Label("Add Tap", systemImage: "plus")
                }
                Button {
                    Task { await app.taps.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(app.taps.isLoading)
            }
            .padding(12)
            Divider()

            if app.taps.isLoading && app.taps.taps.isEmpty {
                Spacer()
                ProgressView("Loading taps…")
                Spacer()
            } else if app.taps.taps.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No third-party taps",
                    systemImage: "archivebox",
                    description: Text("Homebrew's core catalogs are built in. Add taps to access extra packages.")
                )
                Spacer()
            } else {
                List(app.taps.taps) { tap in
                    TapRowView(tap: tap, onRemove: { tapToRemove = tap })
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Taps")
        .task {
            if app.taps.taps.isEmpty { await app.taps.refresh() }
        }
        .alert("Add Tap", isPresented: $addingTap) {
            TextField("user/repo", text: $newTapName)
            Button("Add") {
                let name = newTapName
                newTapName = ""
                Task { _ = await app.taps.addTap(name) }
            }
            Button("Cancel", role: .cancel) { newTapName = "" }
        } message: {
            Text("Enter the tap in user/repo form, e.g. supabase/tap")
        }
        .confirmationDialog(
            "Remove tap \(tapToRemove?.name ?? "")?",
            isPresented: Binding(get: { tapToRemove != nil }, set: { if !$0 { tapToRemove = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let tap = tapToRemove {
                    Task { await app.taps.removeTap(tap.name) }
                }
                tapToRemove = nil
            }
        } message: {
            Text("Packages installed from this tap will remain installed but can no longer be upgraded until the tap is re-added.")
        }
    }
}

private struct TapRowView: View {
    @Environment(AppState.self) private var app
    let tap: TapItem
    var onRemove: () -> Void

    private var info: TapInfoJSON? { app.taps.infoCache[tap.name] }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tap.isOfficial ? "checkmark.seal.fill" : "archivebox.fill")
                .foregroundStyle(tap.isOfficial ? .green : .purple)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tap.name).fontWeight(.medium)
                    if tap.isOfficial { TinyBadge(text: "official", color: .green) }
                }
                if let info {
                    Text("\(info.formula_names?.count ?? 0) formulae · \(info.cask_tokens?.count ?? 0) casks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Loading details…").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let remote = info?.remote, let url = URL(string: remote) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open repository")
            }
            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.8))
            .help("Remove tap")
        }
        .padding(.vertical, 3)
        .onAppear { app.taps.loadInfoIfNeeded(for: tap.name) }
        .contextMenu {
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tap.name, forType: .string)
            }
        }
    }
}

// MARK: - Services

struct ServicesView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Services").font(.title3.weight(.semibold))
                    Text("Start and stop background services (databases, daemons) without touching launchctl.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await app.services.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(app.services.isLoading)
            }
            .padding(12)
            Divider()

            if app.services.isLoading && app.services.items.isEmpty {
                Spacer()
                ProgressView("Loading services…")
                Spacer()
            } else if let error = app.services.errorMessage, app.services.items.isEmpty {
                Spacer()
                ContentUnavailableView("Couldn't load services", systemImage: "exclamationmark.triangle", description: Text(error))
                Spacer()
            } else if app.services.items.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No services",
                    systemImage: "gearshape.2",
                    description: Text("Formulae that provide background services will appear here.")
                )
                Spacer()
            } else {
                List(app.services.items) { service in
                    ServiceRowView(service: service)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Services")
        .task {
            if app.services.items.isEmpty { await app.services.refresh() }
        }
    }
}

private struct ServiceRowView: View {
    @Environment(AppState.self) private var app
    let service: ServiceItem

    private var statusColor: Color {
        switch service.status {
        case .started, .scheduled: return .green
        case .stopped: return .yellow
        case .error: return .red
        case .none, .unknown: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name).fontWeight(.medium)
                HStack(spacing: 6) {
                    Text(service.status.label)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                    if let user = service.user {
                        Text("· \(user)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let exitCode = service.exitCode, exitCode != 0 {
                        Text("· exit \(exitCode)").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Spacer()
            if let plist = service.plistPath {
                Text(plist)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            HStack(spacing: 6) {
                if service.isRunning {
                    Button {
                        Task { await app.services.stop(service.name) }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    Button {
                        Task { await app.services.restart(service.name) }
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                } else {
                    Button {
                        Task { await app.services.start(service.name) }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                }
            }
            .controlSize(.small)
            .labelStyle(.titleOnly)
            .disabled(app.console.isBusy)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Brewfile

struct BrewfileView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var brewfile = app.brewfile
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Brewfile").font(.title3.weight(.semibold))
                    Text("Move your setup between Macs: export everything you have, or install from an existing Brewfile.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button {
                        Task { await app.brewfile.generatePreview() }
                    } label: {
                        Label("Generate Preview", systemImage: "doc.text.magnifyingglass")
                    }
                    Button {
                        app.brewfile.exportBrewfile()
                    } label: {
                        Label("Export…", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        app.brewfile.importBrewfile()
                    } label: {
                        Label("Import & Install…", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        Task { await app.brewfile.check() }
                    } label: {
                        Label("Check", systemImage: "checklist")
                    }
                    if app.brewfile.isWorking {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }

                if let status = app.brewfile.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }

                if app.brewfile.previewText.isEmpty {
                    ContentUnavailableView(
                        "No preview yet",
                        systemImage: "doc.text",
                        description: Text("Generate a preview to see the Brewfile for your current setup — taps, formulae, casks and App Store apps.")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    OutputTextView(text: app.brewfile.previewText, highlightWarnings: false)
                }
            }
            .padding(14)
        }
        .navigationTitle("Brewfile")
    }
}
