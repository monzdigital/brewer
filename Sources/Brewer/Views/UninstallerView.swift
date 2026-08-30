import SwiftUI
import UniformTypeIdentifiers

/// AppCleaner-style deep uninstaller: drop an app (or pick one), review every
/// leftover file it would leave behind, and move it all to the Trash together.
struct UninstallerView: View {
    @Environment(AppState.self) private var app
    @State private var dropTargeted = false
    @State private var confirming = false

    var body: some View {
        Group {
            if app.uninstaller.review != nil {
                reviewPane
            } else {
                landingPane
            }
        }
        .navigationTitle("Uninstaller")
    }

    // MARK: Landing (drop zone)

    private var landingPane: some View {
        ScrollView {
            VStack(spacing: 16) {
                dropZone
                    .padding(.top, 24)

                if let message = app.uninstaller.resultMessage {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 560, alignment: .leading)
                        .cardStyle(tint: .green)
                }

                smartDeleteCard
                    .frame(maxWidth: 560)

                if !app.uninstaller.recentlyTrashed.isEmpty {
                    recentlyTrashedCard
                        .frame(maxWidth: 560)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "trash.slash")
                .font(.system(size: 42))
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
            Text("Drop an app here to uninstall it completely")
                .font(.title3.weight(.semibold))
            Text("Brewer finds caches, preferences, support files, logs and containers the app leaves behind - and moves everything to the Trash together. Homebrew casks are removed with brew.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button {
                chooseApp()
            } label: {
                Label("Choose App…", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(36)
        .frame(maxWidth: 560)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [7])
                )
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(dropTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
                )
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var smartDeleteCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.title3)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 3) {
                Text("SmartDelete").font(.callout.weight(.semibold))
                Text("Watch the Trash in the background: when you delete an app the normal way, Brewer offers to clean up its leftovers too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { app.uninstaller.smartDeleteEnabled },
                set: { app.uninstaller.setSmartDelete($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .cardStyle()
    }

    private var recentlyTrashedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recently moved to Trash")
                .font(.callout.weight(.semibold))
            ForEach(app.uninstaller.recentlyTrashed) { trashedApp in
                HStack(spacing: 8) {
                    Image(nsImage: AppIconCache.shared.icon(forPath: trashedApp.url.path))
                        .resizable().frame(width: 22, height: 22)
                    Text(trashedApp.name).font(.callout)
                    Spacer()
                    Button("Clean Leftovers") {
                        Task { await app.uninstaller.beginReview(appURL: trashedApp.url) }
                    }
                    .controlSize(.small)
                }
            }
        }
        .cardStyle(tint: .purple)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await app.uninstaller.beginReview(appURL: url) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension == "app" else { return }
            Task { @MainActor in
                await app.uninstaller.beginReview(appURL: url)
            }
        }
        return true
    }

    // MARK: Review

    @ViewBuilder
    private var reviewPane: some View {
        if let review = app.uninstaller.review {
            VStack(spacing: 0) {
                reviewHeader(review)
                Divider()
                if app.uninstaller.isProtectedTarget {
                    Spacer()
                    ContentUnavailableView {
                        Label("Protected app", systemImage: "lock.shield")
                    } description: {
                        Text("System apps and Apple software can't be removed - deleting them could break macOS.")
                    } actions: {
                        Button("Back") { app.uninstaller.cancelReview() }
                    }
                    Spacer()
                } else if app.uninstaller.isScanning {
                    Spacer()
                    ProgressView("Scanning for leftover files…")
                    Spacer()
                } else {
                    leftoverList(review)
                    Divider()
                    reviewFooter(review)
                }
            }
        }
    }

    private func reviewHeader(_ review: UninstallerStore.Review) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIconCache.shared.icon(forPath: review.app.url.path))
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(review.app.name).font(.title3.weight(.semibold))
                    if let token = review.caskToken {
                        TinyBadge(text: "Homebrew: \(token)", color: .green)
                    }
                    if review.isRunning {
                        TinyBadge(text: "running - will be quit", color: .orange)
                    }
                    if !review.appStillOnDisk || review.app.url.path.contains("/.Trash/") {
                        TinyBadge(text: "already in Trash", color: .secondary)
                    }
                }
                Text(review.app.url.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Cancel") { app.uninstaller.cancelReview() }
        }
        .padding(12)
    }

    private func leftoverList(_ review: UninstallerStore.Review) -> some View {
        List {
            if review.caskToken == nil && review.appStillOnDisk && !review.app.url.path.contains("/.Trash/") {
                Section {
                    Toggle(isOn: Binding(
                        get: { app.uninstaller.includeAppItself },
                        set: { app.uninstaller.includeAppItself = $0 }
                    )) {
                        HStack {
                            Text("The app itself")
                            Spacer()
                            Text(review.app.url.path)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            if app.uninstaller.leftovers.isEmpty {
                Section {
                    Label("No leftover files found - this app is tidy.", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                }
            } else {
                let grouped = Dictionary(grouping: app.uninstaller.leftovers, by: \.kind)
                ForEach(grouped.keys.sorted(), id: \.self) { kind in
                    Section(kind) {
                        ForEach(grouped[kind] ?? []) { item in
                            LeftoverRow(item: item)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func reviewFooter(_ review: UninstallerStore.Review) -> some View {
        HStack(spacing: 12) {
            let count = app.uninstaller.checkedIDs.count
            Text("\(count) item\(count == 1 ? "" : "s") selected · \(Format.bytes(app.uninstaller.selectedBytes))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Select All") {
                app.uninstaller.checkedIDs = Set(app.uninstaller.leftovers.map(\.id))
            }
            .controlSize(.small)
            Button("Select None") {
                app.uninstaller.checkedIDs = []
            }
            .controlSize(.small)
            Spacer()
            Button(role: .destructive) {
                confirming = true
            } label: {
                Label(
                    review.caskToken != nil ? "Uninstall via Homebrew & Clean" : "Move to Trash",
                    systemImage: "trash"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(12)
        .confirmationDialog(
            "Remove \(review.app.name) and \(app.uninstaller.checkedIDs.count) leftover item(s)?",
            isPresented: $confirming
        ) {
            Button("Remove", role: .destructive) {
                Task { await app.uninstaller.performRemoval() }
            }
        } message: {
            Text("Everything is moved to the Trash, so you can still recover files afterwards.")
        }
    }
}

private struct LeftoverRow: View {
    @Environment(AppState.self) private var app
    let item: LeftoverItem

    var body: some View {
        Toggle(isOn: Binding(
            get: { app.uninstaller.checkedIDs.contains(item.id) },
            set: { checked in
                if checked { app.uninstaller.checkedIDs.insert(item.id) }
                else { app.uninstaller.checkedIDs.remove(item.id) }
            }
        )) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(item.displayName).font(.callout)
                        if item.confidence == .nameMatch {
                            TinyBadge(text: "name match - review", color: .yellow)
                        }
                        if item.isSystemDomain {
                            TinyBadge(text: "system - may need admin", color: .orange)
                        }
                    }
                    Text(item.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let size = item.sizeBytes {
                    Text(Format.bytes(size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}
