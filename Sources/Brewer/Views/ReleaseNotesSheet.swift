import SwiftUI
import WebKit

/// Shows what changed in a new version before updating (Latest/MacUpdater-style):
/// renders the appcast's embedded HTML notes, or loads the release-notes URL.
struct ReleaseNotesSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let update: SparkleUpdate

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: AppIconCache.shared.icon(forPath: update.appPath))
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(update.appName) - what's new")
                        .font(.headline)
                    HStack(spacing: 4) {
                        Text(update.currentVersion).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(update.latestVersion).fontWeight(.semibold).foregroundStyle(.blue)
                        if let bytes = update.enclosureBytes {
                            Text("· \(Format.bytes(bytes)) download")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            NotesWebView(update: update)

            Divider()
            HStack {
                if let notes = update.releaseNotesURL {
                    Link("Open in browser", destination: notes)
                        .font(.caption)
                }
                Spacer()
                if update.managedByCask == nil, update.downloadURL != nil {
                    Button {
                        dismiss()
                        Task { await app.installer.performUpdate(update) }
                    } label: {
                        Label("Update Now", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(10)
        }
        .frame(width: 640, height: 540)
    }
}

private struct NotesWebView: NSViewRepresentable {
    let update: SparkleUpdate

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        load(into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    private func load(into webView: WKWebView) {
        if let html = update.notesHTML, html.count > 40 {
            let wrapped = """
            <html><head><meta charset="utf-8">
            <style>
            :root { color-scheme: light dark; }
            body { font: 13px -apple-system, sans-serif; padding: 14px; }
            a { color: #4a9eff; }
            </style></head><body>\(html)</body></html>
            """
            webView.loadHTMLString(wrapped, baseURL: update.releaseNotesURL)
        } else if let url = update.releaseNotesURL {
            webView.load(URLRequest(url: url))
        } else {
            webView.loadHTMLString(
                "<html><body style=\"font:13px -apple-system;color:gray;padding:16px\">No release notes provided by the developer.</body></html>",
                baseURL: nil
            )
        }
    }
}

// MARK: - Backups sheet (restore previous versions)

struct BackupsSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Update Backups", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            if app.installer.backups.isEmpty {
                ContentUnavailableView(
                    "No backups yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Before Brewer updates an app directly, it keeps a copy of the old version here so you can roll back.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(app.installer.backups) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(entry.appName) \(entry.version)")
                                .fontWeight(.medium)
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") {
                            Task { message = await app.installer.restore(entry) }
                        }
                        .controlSize(.small)
                        Button(role: .destructive) {
                            Task { await app.installer.deleteBackup(entry) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red.opacity(0.8))
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }

            if let message {
                Divider()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(width: 520, height: 420)
        .task { await app.installer.loadBackups() }
    }
}
