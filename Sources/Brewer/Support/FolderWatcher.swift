import CoreServices
import Foundation

/// Watches folder trees with FSEvents and reports the changed directories on a
/// private queue. Used by SmartDelete on /Applications and ~/Applications, which
/// need no special permission (unlike ~/.Trash, which requires Full Disk Access).
final class FolderWatcher: @unchecked Sendable {

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.monz.brewer.folder-watcher")
    private let onChange: @Sendable ([String]) -> Void

    /// Returns nil when no stream could be started (e.g. none of the paths exist).
    init?(paths: [String], latency: TimeInterval = 1.0, onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }

        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray) as? [String] ?? []
            var reported = Array(changed.prefix(count))
            // A dropped or coalesced batch must be treated as "anything may have changed".
            let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
            if (0..<count).contains(where: { flags[$0] & rescanFlags != 0 }) {
                reported.append(FolderWatcher.rescanMarker)
            }
            watcher.onChange(reported)
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    /// Reported instead of a path when FSEvents asks for a full rescan.
    static let rescanMarker = "<rescan>"

    /// FSEvents reports real paths (/private/var, resolved symlinks), so roots
    /// must be compared in that form too.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    /// True when a changed directory can mean an app appeared or disappeared:
    /// an application folder itself, or a plain folder directly inside it (such
    /// as /Applications/Setapp) - not the inside of an app bundle.
    static func isRelevantChange(_ path: String, roots: [String]) -> Bool {
        if path == rescanMarker { return true }
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        for root in roots {
            if trimmed == root { return true }
            guard trimmed.hasPrefix(root + "/") else { continue }
            let rest = trimmed.dropFirst(root.count + 1)
            if !rest.contains("/") && !rest.hasSuffix(".app") { return true }
        }
        return false
    }
}
