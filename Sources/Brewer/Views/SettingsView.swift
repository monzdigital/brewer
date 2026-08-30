import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
            HomebrewSettings()
                .tabItem { Label("Homebrew", systemImage: "mug") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppState.self) private var app
    @AppStorage(Prefs.autoOpenConsole) private var autoOpenConsole = true
    @AppStorage(Prefs.compactRows) private var compactRows = false
    @AppStorage(Prefs.notifyOnOperations) private var notifyOnOperations = true

    var body: some View {
        Form {
            Text("The menu bar icon shows how many packages are outdated at a glance.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Toggle("Open console automatically when a command runs", isOn: $autoOpenConsole)
            Toggle("Use compact package lists", isOn: $compactRows)
            Toggle("Notify when operations finish", isOn: $notifyOnOperations)

            Divider().padding(.vertical, 4)

            Toggle("SmartDelete - watch the Trash for deleted apps", isOn: Binding(
                get: { app.uninstaller.smartDeleteEnabled },
                set: { app.uninstaller.setSmartDelete($0) }
            ))
            Text("When you trash an app the normal way, Brewer offers to clean up its leftover files too.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

// MARK: - Updates

private struct UpdateSettings: View {
    @Environment(AppState.self) private var app
    @AppStorage(Prefs.checkIntervalHours) private var intervalHours = 24
    @AppStorage(Prefs.checkOnLaunch) private var checkOnLaunch = true
    @AppStorage(Prefs.notifyOnUpdates) private var notifyOnUpdates = true
    @AppStorage(Prefs.autoUpgrade) private var autoUpgrade = false
    @AppStorage(Prefs.batteryAware) private var batteryAware = true
    @AppStorage(Prefs.closeAppsBeforeUpgrade) private var closeApps = true
    @AppStorage(Prefs.greedyCasks) private var greedyCasks = false
    @AppStorage(Prefs.backupBeforeUpdate) private var backupBeforeUpdate = true

    var body: some View {
        Form {
            Picker("Check for updates", selection: $intervalHours) {
                Text("Manually").tag(0)
                Text("Every 6 hours").tag(6)
                Text("Every 12 hours").tag(12)
                Text("Daily").tag(24)
                Text("Weekly").tag(168)
            }
            Toggle("Check on launch", isOn: $checkOnLaunch)
            Toggle("Notify when updates are available", isOn: $notifyOnUpdates)

            Divider().padding(.vertical, 4)

            Toggle("Upgrade automatically in the background", isOn: $autoUpgrade)
            Toggle("Only when on AC power (battery-aware)", isOn: $batteryAware)
                .disabled(!autoUpgrade)
                .padding(.leading, 18)

            Divider().padding(.vertical, 4)

            Toggle("Close running apps cleanly before upgrading them", isOn: $closeApps)
            Toggle("Back up apps before direct updates (App Updates)", isOn: $backupBeforeUpdate)
            Toggle("Include self-updating casks (--greedy)", isOn: $greedyCasks)
            Text("Greedy upgrades also update casks that normally update themselves (marked “auto-updates”).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            HStack {
                if let last = app.scheduler.lastCheck {
                    Text("Last check: \(Format.relative(last))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check Now") {
                    Task { await app.scheduler.check(scheduled: false) }
                }
                .disabled(app.scheduler.isChecking)
            }
        }
        .padding(20)
    }
}

// MARK: - Homebrew

private struct HomebrewSettings: View {
    @Environment(AppState.self) private var app
    @AppStorage(Prefs.customBrewPath) private var customBrewPath = ""

    var body: some View {
        Form {
            LabeledContent("Detected brew") {
                Text(BrewEnvironment.current.brewPath)
                    .textSelection(.enabled)
            }
            LabeledContent("Prefix") {
                Text(BrewEnvironment.current.prefix)
                    .textSelection(.enabled)
            }
            if let version = app.packages.brewVersion {
                LabeledContent("Version") {
                    Text(version)
                }
            }
            LabeledContent("Architecture") {
                Text(BrewEnvironment.current.isAppleSiliconMachine
                     ? (BrewEnvironment.current.isRosettaBrew ? "Apple Silicon (brew under Rosetta!)" : "Apple Silicon (native)")
                     : "Intel")
            }

            Divider().padding(.vertical, 4)

            TextField("Custom brew path", text: $customBrewPath, prompt: Text("/opt/homebrew/bin/brew"))
            HStack {
                Text("Leave empty to auto-detect. Applied immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply") {
                    BrewEnvironment.current = BrewEnvironment.detect(
                        customPath: customBrewPath.isEmpty ? nil : customBrewPath
                    )
                    Task { await app.packages.refresh() }
                }
            }
        }
        .padding(20)
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "mug.fill")
                .font(.system(size: 42))
                .foregroundStyle(Color.accentColor)
            Text("Brewer")
                .font(.title2.bold())
            Text("A native Homebrew app for the Mac.\nEverything maps directly to real brew commands, so your setup stays portable, familiar, and fully yours.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Link("Homebrew documentation", destination: URL(string: "https://docs.brew.sh")!)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }
}
