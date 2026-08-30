import Foundation

/// AppCleaner-style leftover discovery: finds an app's side files in the
/// Library folders (caches, preferences, support files, logs, containers, …).
///
/// Safety model:
/// - Apple / system apps are refused entirely (`isProtected`).
/// - Bundle-identifier matches are high confidence; plain name matches must be
///   exact (not substring) and are surfaced as lower confidence.
/// - Removal always goes through the Trash (recoverable), never a hard delete.
enum LeftoverScanner {

    // MARK: Safety

    static func isProtected(bundleID: String?, appURL: URL?) -> Bool {
        if let bundleID, bundleID.hasPrefix("com.apple.") { return true }
        if let path = appURL?.path {
            if path.hasPrefix("/System") { return true }
            if path == "/Applications/Safari.app" { return true }
        }
        return false
    }

    // MARK: Scan locations

    struct Root {
        let path: String
        let kind: String
        let allowNameMatch: Bool
    }

    static func scanRoots() -> [Root] {
        let home = NSHomeDirectory()
        return [
            Root(path: home + "/Library/Application Support", kind: "Application Support", allowNameMatch: true),
            Root(path: home + "/Library/Caches", kind: "Caches", allowNameMatch: true),
            Root(path: home + "/Library/Preferences", kind: "Preferences", allowNameMatch: false),
            Root(path: home + "/Library/Logs", kind: "Logs", allowNameMatch: true),
            Root(path: home + "/Library/Containers", kind: "Containers", allowNameMatch: false),
            Root(path: home + "/Library/Group Containers", kind: "Group Containers", allowNameMatch: false),
            Root(path: home + "/Library/Saved Application State", kind: "Saved State", allowNameMatch: false),
            Root(path: home + "/Library/HTTPStorages", kind: "HTTP Storage", allowNameMatch: false),
            Root(path: home + "/Library/WebKit", kind: "WebKit Data", allowNameMatch: false),
            Root(path: home + "/Library/LaunchAgents", kind: "Launch Agents", allowNameMatch: false),
            Root(path: home + "/Library/Application Scripts", kind: "App Scripts", allowNameMatch: false),
            Root(path: home + "/Library/Cookies", kind: "Cookies", allowNameMatch: false),
            Root(path: "/Library/Application Support", kind: "Application Support (system)", allowNameMatch: false),
            Root(path: "/Library/Caches", kind: "Caches (system)", allowNameMatch: false),
            Root(path: "/Library/Preferences", kind: "Preferences (system)", allowNameMatch: false),
            Root(path: "/Library/LaunchAgents", kind: "Launch Agents (system)", allowNameMatch: false),
            Root(path: "/Library/LaunchDaemons", kind: "Launch Daemons (system)", allowNameMatch: false)
        ]
    }

    // MARK: Matching

    static func match(itemName: String, bundleID: String?, appName: String, allowNameMatch: Bool) -> LeftoverConfidence? {
        let lowerItem = itemName.lowercased()
        if let bundleID = bundleID?.lowercased(), bundleID.count >= 6 {
            if lowerItem == bundleID { return .bundleID }
            if lowerItem.hasPrefix(bundleID + ".") { return .bundleID }
            if lowerItem.contains(bundleID) { return .bundleID } // e.g. "group.com.foo.app", "TEAMID.com.foo.app"
        }
        guard allowNameMatch else { return nil }
        let lowerApp = appName.lowercased().trimmingCharacters(in: .whitespaces)
        guard lowerApp.count >= 4 else { return nil }
        if lowerItem == lowerApp { return .nameMatch }
        return nil
    }

    // MARK: Scanning

    static func scan(bundleID: String?, appName: String) async -> [LeftoverItem] {
        guard bundleID != nil || appName.count >= 4 else { return [] }
        let fileManager = FileManager.default
        var found: [LeftoverItem] = []

        for root in scanRoots() {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root.path) else { continue }
            for entry in entries {
                guard let confidence = match(
                    itemName: entry,
                    bundleID: bundleID,
                    appName: appName,
                    allowNameMatch: root.allowNameMatch
                ) else { continue }
                // Never offer to delete anything that belongs to Apple.
                guard !entry.lowercased().contains("com.apple.") else { continue }
                found.append(LeftoverItem(
                    path: root.path + "/" + entry,
                    kind: root.kind,
                    confidence: confidence
                ))
            }
        }

        // Compute sizes with limited concurrency.
        var sized: [LeftoverItem] = []
        for chunk in found.chunked(into: 6) {
            await withTaskGroup(of: LeftoverItem.self) { group in
                for item in chunk {
                    group.addTask {
                        var copy = item
                        copy.sizeBytes = await DiskUsage.size(ofPath: item.path)
                        return copy
                    }
                }
                for await item in group { sized.append(item) }
            }
        }

        return sized.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }

    // MARK: Removal (always via Trash)

    struct TrashResult {
        var trashed: [String] = []
        var failed: [(path: String, reason: String)] = []
    }

    static func moveToTrash(paths: [String]) -> TrashResult {
        var result = TrashResult()
        for path in paths {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                result.trashed.append(path)
            } catch {
                result.failed.append((path, error.localizedDescription))
            }
        }
        return result
    }
}
