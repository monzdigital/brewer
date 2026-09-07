import SwiftUI
import UserNotifications

/// Entry point. `--selftest` runs the data-layer checks and exits;
/// otherwise the normal SwiftUI app starts.
@main
enum BrewerEntry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTestRunner.run()
        }
        BrewerApp.main()
    }
}

struct BrewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("Brewer", id: "main") {
            RootView()
                .environment(appState)
                .frame(minWidth: 980, minHeight: 620)
                .task {
                    await appState.bootstrap()
                    TourShots.runIfRequested(app: appState)
                }
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Packages") {
                    Task { await appState.packages.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Check for Updates") {
                    Task { await appState.scheduler.check(scheduled: false) }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Button("Toggle Console") {
                    appState.console.isPresented.toggle()
                }
                .keyboardShortcut("l", modifiers: .command)
            }
        }
        Settings {
            SettingsView()
                .environment(appState)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(appState)
        } label: {
            MenuBarLabel()
                .environment(appState)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if NotificationManager.isAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
        MainActor.assumeIsolated {
            DockIcon.apply(hidden: UserDefaults.standard.bool(forKey: Prefs.hideDockIcon))
        }
    }

    /// An app dropped onto the Dock icon (or opened with Brewer) goes straight
    /// into the Uninstaller review - the AppCleaner workflow.
    func application(_ application: NSApplication, open urls: [URL]) {
        let apps = urls.filter { $0.pathExtension == "app" }
        guard let first = apps.first else { return }
        MainActor.assumeIsolated {
            guard let state = AppState.shared else { return }
            state.selection = .uninstaller
            NotificationCenter.default.post(name: .brewerOpenMainWindow, object: nil)
            Task { await state.uninstaller.beginReview(appURL: first) }
        }
    }

    // Flush pending metadata and don't leave orphaned brew processes running
    // (they hold Homebrew's lock).
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared?.prepareForTermination()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Pick the main window, not the menu bar extra's or the Settings panel.
            let main = sender.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
                ?? sender.windows.first { $0.canBecomeMain }
            main?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    // Show notifications even while the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Clicking a notification opens the page it is about.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo[NotificationManager.pageKey] as? String
        let page = raw.flatMap(NotificationManager.Page.init(rawValue:))
        MainActor.assumeIsolated {
            if let item = page?.sidebarItem {
                AppState.shared?.selection = item
            } else if page == .console {
                AppState.shared?.console.isPresented = true
            }
            NotificationCenter.default.post(name: .brewerOpenMainWindow, object: nil)
        }
        completionHandler()
    }
}

// MARK: - Menu bar

private struct MenuBarLabel: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Keep the structure constant (always Image + Text). NOTE: never pass
        // `isInserted:` to MenuBarExtra - on macOS 26 an isInserted binding sends
        // the scene graph into a permanent 100% CPU rebuild loop
        // (AppGraph.graphDidChange -> makeMainMenu -> invalidate -> repeat).
        let count = app.visibleUpdateCount
        Image(systemName: count > 0 ? "mug.fill" : "mug")
        Text(verbatim: count > 0 ? String(count) : "")
            // The label is the one view that always exists, so it services
            // "open the main window" requests from AppKit callbacks.
            .onReceive(NotificationCenter.default.publisher(for: .brewerOpenMainWindow)) { _ in
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
    }
}

private struct MenuBarContent: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let updates = app.packages(in: .updates)

        if updates.isEmpty {
            Text("Everything is up to date")
        } else {
            Text("\(updates.count) update\(updates.count == 1 ? "" : "s") available")
            Divider()
            ForEach(updates.prefix(12)) { package in
                Button("\(package.displayName)  \(package.versionSummary)") {
                    openMainWindow(selecting: .updates)
                }
            }
            if updates.count > 12 {
                Text("…and \(updates.count - 12) more")
            }
            Divider()
            Button("Upgrade All") {
                Task { await app.upgradeAllVisible() }
            }
        }

        Divider()
        Button(app.scheduler.isChecking ? "Checking…" : "Check Now") {
            Task { await app.scheduler.check(scheduled: false) }
        }
        .disabled(app.scheduler.isChecking)

        Button("Open Brewer") {
            openMainWindow(selecting: nil)
        }

        SettingsLink {
            Text("Settings…")
        }

        Divider()
        Button("Quit Brewer") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func openMainWindow(selecting item: SidebarItem?) {
        if let item { app.selection = item }
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
