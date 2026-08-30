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
    @AppStorage(Prefs.menuBarEnabled) private var menuBarEnabled = true

    var body: some Scene {
        WindowGroup("Brewer", id: "main") {
            RootView()
                .environment(appState)
                .frame(minWidth: 980, minHeight: 620)
                .task { await appState.bootstrap() }
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

                Button("Show Console") {
                    appState.console.isPresented = true
                }
                .keyboardShortcut("l", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }

        MenuBarExtra(isInserted: $menuBarEnabled) {
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
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
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
}

// MARK: - Menu bar

private struct MenuBarLabel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let count = app.visibleUpdateCount
        if count > 0 {
            Image(systemName: "mug.fill")
            Text("\(count)")
        } else {
            Image(systemName: "mug")
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
                Task { await app.packages.upgradeAll() }
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
