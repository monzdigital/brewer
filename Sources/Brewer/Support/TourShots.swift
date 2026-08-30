import AppKit
import SwiftUI

/// Hidden utility: `Brewer --tour-shots <outputDir>` walks through every page,
/// waits for its data, and captures the window to PNGs (used to regenerate
/// website/docs screenshots). Captures use `cacheDisplay` on our own window,
/// which needs no screen-recording permission.
@MainActor
enum TourShots {

    static var requestedOutputDir: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--tour-shots"),
              CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }

    /// True while running in screenshot mode (sidebar renders opaque, since
    /// translucent materials don't survive offscreen capture).
    static var isActive: Bool { requestedOutputDir != nil }

    static func runIfRequested(app: AppState) {
        if CommandLine.arguments.contains("--settings-shot"), let dir = requestedOutputDir {
            runSettingsShot(dir: dir)
            return
        }
        guard let dir = requestedOutputDir else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        Task { @MainActor in
            NSApp.appearance = NSAppearance(named: .darkAqua)

            // Wait for the package data to arrive.
            for _ in 0..<180 {
                if !app.packages.allPackages.isEmpty && !app.packages.isLoading { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            if let window = NSApp.windows.first(where: { $0.contentView != nil }) {
                window.setFrame(NSRect(x: 120, y: 120, width: 1280, height: 800), display: true)
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            @MainActor
            func shoot(_ item: SidebarItem?, _ name: String, wait seconds: Double) async {
                if let item { app.selection = item }
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                capture(name: name, dir: dir)
            }

            await shoot(.installed, "01-installed", wait: 2.5)
            await shoot(.updates, "02-updates", wait: 2)
            await shoot(.discover, "03-discover", wait: 5)
            await shoot(.apps, "04-apps", wait: 7)
            await shoot(.appUpdates, "05-appupdates", wait: 3)
            await shoot(.uninstaller, "06-uninstaller", wait: 1.5)

            // Health needs its metrics loaded.
            app.selection = .health
            await app.health.refreshMetrics()
            await shoot(nil, "07-health", wait: 1)

            // Diagnostics with real doctor results on the page.
            await app.health.runDoctor()
            await shoot(.diagnostics, "08-diagnostics", wait: 1.5)

            await shoot(.services, "09-services", wait: 3)
            await shoot(.appleSilicon, "10-applesilicon", wait: 4)
            await shoot(.adoptApps, "11-adoptapps", wait: 9)
            await shoot(.appStore, "12-appstore", wait: 4)
            await shoot(.duplicates, "13-duplicates", wait: 5)
            await shoot(.cleanup, "14-cleanup", wait: 2)
            await shoot(.taps, "15-taps", wait: 3)

            app.selection = .brewfile
            await app.brewfile.generatePreview()
            await shoot(nil, "16-brewfile", wait: 1)

            await shoot(.history, "17-history", wait: 1.5)
            await shoot(.favorites, "18-favorites", wait: 1.5)
            await shoot(.collections, "19-collections", wait: 1.5)
            await shoot(.search, "20-search", wait: 1)

            // Live console shot: run brew doctor through the console panel.
            app.selection = .diagnostics
            Task { await app.console.runBrew(title: "Run brew doctor", arguments: ["doctor"]) }
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            capture(name: "21-console", dir: dir)

            // Let the doctor finish before quitting so no orphan remains.
            for _ in 0..<60 {
                if !app.console.isBusy { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            capture(name: "22-console-done", dir: dir)

            print("tour-shots complete")
            exit(0)
        }
    }

    /// Opens the Settings window WITHOUT activating the app (so the user's
    /// focus is never stolen), captures each tab, then exits.
    private static func runSettingsShot(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            NSApp.appearance = NSAppearance(named: .darkAqua)
            // SettingsAutoOpener (in RootView) calls openSettings() ~1s after launch.
            let tabTitles = ["General", "Updates", "Homebrew", "About", "Settings", "Brewer Settings"]
            var found: NSWindow?
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let window = NSApp.windows.first(where: { tabTitles.contains($0.title) }) {
                    found = window
                    break
                }
            }
            guard let settingsWindow = found else {
                print("settings window not found — titles: \(NSApp.windows.map(\.title))")
                exit(1)
            }
            settingsWindow.orderFrontRegardless()

            // Walk the toolbar-style tabs.
            let toolbar = settingsWindow.toolbar
            let items = toolbar?.items ?? []
            if items.isEmpty {
                try? await Task.sleep(nanoseconds: 800_000_000)
                captureWindow(settingsWindow, name: "30-settings", dir: dir)
            } else {
                for (index, item) in items.enumerated() {
                    if let action = item.action {
                        _ = item.target.map { NSApp.sendAction(action, to: $0, from: item) }
                            ?? NSApp.sendAction(action, to: nil, from: item)
                    }
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    captureWindow(settingsWindow, name: String(format: "3%d-settings-%@", index, item.label.lowercased()), dir: dir)
                }
            }
            print("settings-shot complete")
            exit(0)
        }
    }

    private static func captureWindow(_ window: NSWindow, name: String, dir: String) {
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        if let cgImage = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ), cgImage.width > 1 {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
            }
        }
    }

    private static func capture(name: String, dir: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")

        // Preferred: the composited window buffer (renders materials correctly).
        // Capturing our OWN window needs no screen-recording permission.
        if let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ), cgImage.width > 1 {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                return
            }
        }

        // Fallback: offscreen render (translucent materials appear flat).
        guard let frameView = window.contentView?.superview ?? window.contentView,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }
}
