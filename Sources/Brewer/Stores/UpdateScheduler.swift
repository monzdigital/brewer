import Foundation
import Observation

/// Periodically runs `brew update`, refreshes the outdated list, notifies the user,
/// and (optionally) upgrades automatically — with battery-aware behavior.
@MainActor
@Observable
final class UpdateScheduler {

    var lastCheck: Date?
    var isChecking = false

    /// Extra work to run after each scheduled check (e.g. rescanning Sparkle feeds).
    var onScheduledCheck: (() async -> Void)?

    private unowned let packages: PackageStore
    private var loopTask: Task<Void, Never>?
    private var previousOutdatedCount: Int?

    init(packages: PackageStore) {
        self.packages = packages
    }

    var intervalHours: Int {
        UserDefaults.standard.integer(forKey: Prefs.checkIntervalHours)
    }

    var nextCheck: Date? {
        guard intervalHours > 0 else { return nil }
        let reference = lastCheck ?? Date()
        return reference.addingTimeInterval(Double(intervalHours) * 3600)
    }

    func start() {
        stop()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                // Wake up every 10 minutes and see whether a check is due.
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                guard let self else { return }
                let hours = self.intervalHours
                guard hours > 0 else { continue }
                let due: Bool
                if let last = self.lastCheck {
                    due = Date().timeIntervalSince(last) >= Double(hours) * 3600
                } else {
                    due = true
                }
                if due {
                    await self.check(scheduled: true)
                }
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Runs a full check: update Homebrew data, refresh, notify, maybe auto-upgrade.
    func check(scheduled: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        // Even if update fails (offline), still refresh from local data afterwards.
        _ = await Shell.runBrew(["update"])
        await packages.refresh()
        lastCheck = Date()

        let defaults = UserDefaults.standard
        let count = packages.outdatedCount

        if defaults.bool(forKey: Prefs.notifyOnUpdates), count > 0, count != previousOutdatedCount {
            NotificationManager.post(
                title: "Updates available",
                body: count == 1
                    ? "1 package can be upgraded."
                    : "\(count) packages can be upgraded."
            )
        }
        previousOutdatedCount = count

        if scheduled {
            await onScheduledCheck?()
        }

        if scheduled, defaults.bool(forKey: Prefs.autoUpgrade), count > 0 {
            if defaults.bool(forKey: Prefs.batteryAware) {
                let onAC = await PowerInfo.isOnACPower()
                guard onAC, !PowerInfo.isLowPowerMode else { return }
            }
            await packages.upgradeAll()
            if defaults.bool(forKey: Prefs.notifyOnUpdates) {
                NotificationManager.post(
                    title: "Upgrade finished",
                    body: "Brewer upgraded \(count) package\(count == 1 ? "" : "s") in the background."
                )
            }
        }
    }
}
