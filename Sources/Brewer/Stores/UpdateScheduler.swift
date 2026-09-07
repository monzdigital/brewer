import Foundation
import Observation

/// Periodically runs `brew update`, refreshes the outdated list, notifies the user,
/// and (optionally) upgrades automatically - with battery-aware behavior.
@MainActor
@Observable
final class UpdateScheduler {

    var lastCheck: Date?
    var isChecking = false

    /// Extra work to run after each scheduled check (e.g. rescanning Sparkle feeds).
    var onScheduledCheck: (() async -> Void)?

    /// The outdated packages the user actually wants to hear about (snoozed ones
    /// excluded). Falls back to everything outdated when not wired up.
    var visibleUpdates: (() -> [BrewPackage])?

    private unowned let packages: PackageStore
    private var loopTask: Task<Void, Never>?
    private var previousOutdatedCount: Int?
    private var loopStartedAt: Date?

    init(packages: PackageStore) {
        self.packages = packages
    }

    var intervalHours: Int {
        UserDefaults.standard.integer(forKey: Prefs.checkIntervalHours)
    }

    var nextCheck: Date? {
        guard intervalHours > 0 else { return nil }
        let reference = lastCheck ?? loopStartedAt ?? Date()
        return reference.addingTimeInterval(Double(intervalHours) * 3600)
    }

    func start() {
        stop()
        loopStartedAt = Date()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                // Wake up every 10 minutes and see whether a check is due.
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                guard let self else { return }
                let hours = self.intervalHours
                guard hours > 0 else { continue }
                // With "check on launch" off, the launch itself is the reference
                // point - otherwise the first wake-up would always be "due".
                let reference = self.lastCheck ?? self.loopStartedAt ?? Date()
                if Date().timeIntervalSince(reference) >= Double(hours) * 3600 {
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

        // Goes through the console queue so it can never race a running brew
        // command for Homebrew's lock; the panel stays closed for background
        // checks. Even if update fails (offline) the refresh still runs.
        await packages.updateHomebrewData(presentConsole: false)
        lastCheck = Date()

        let defaults = UserDefaults.standard
        let updates = visibleUpdates?() ?? packages.outdatedPackages
        let count = updates.count

        if defaults.bool(forKey: Prefs.notifyOnUpdates), count > 0, count != previousOutdatedCount {
            NotificationManager.post(
                title: "Updates available",
                body: count == 1
                    ? "1 package can be upgraded."
                    : "\(count) packages can be upgraded.",
                page: .updates
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
            let snoozed = Set(packages.outdatedPackages.map(\.id)).subtracting(updates.map(\.id))
            await packages.upgradeAll(excluding: snoozed)
            if defaults.bool(forKey: Prefs.notifyOnUpdates) {
                NotificationManager.post(
                    title: "Upgrade finished",
                    body: "Brewer upgraded \(count) package\(count == 1 ? "" : "s") in the background.",
                    page: .console
                )
            }
        }
    }
}
