import Foundation
import AppKit
import Observation

/// MacUpdater-style direct app updates for Sparkle-distributed apps:
/// downloads the new version, verifies it (EdDSA signature and/or code
/// signing identity), backs up the current one, extracts the archive
/// (zip / dmg / tar), swaps the bundle with rollback, and can restore backups.
@MainActor
@Observable
final class AppUpdateInstaller {

    enum Phase: Equatable {
        case idle
        case downloading(Double?)   // 0...1 or nil when unknown
        case verifying
        case backingUp
        case extracting
        case installing
        case finished(String)       // completion note
        case failed(String)

        var isActive: Bool {
            switch self {
            case .downloading, .verifying, .backingUp, .extracting, .installing: return true
            default: return false
            }
        }
    }

    var phases: [String: Phase] = [:]
    var backups: [BackupEntry] = []

    /// Called after a bundle was replaced successfully (path of the app).
    var onInstalled: ((String) async -> Void)?

    nonisolated static var backupsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Brewer/Backups", isDirectory: true)
    }

    nonisolated private static var stagingRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Brewer/Staging", isDirectory: true)
    }

    func phase(for appPath: String) -> Phase {
        phases[appPath] ?? .idle
    }

    // MARK: - Update

    func performUpdate(_ update: SparkleUpdate) async {
        let key = update.appPath
        guard phases[key]?.isActive != true else { return }
        guard let downloadURL = update.downloadURL else {
            phases[key] = .failed("The update feed doesn't provide a direct download.")
            return
        }

        let staging = Self.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            phases[key] = .downloading(nil)
            let archive = try await Self.download(downloadURL, into: staging) { [weak self] progress in
                Task { @MainActor [weak self] in
                    if case .downloading = self?.phases[key] ?? .idle {
                        self?.phases[key] = .downloading(progress)
                    }
                }
            }

            // Installer packages need the system Installer app - hand off.
            if Self.isInstallerPackage(archive) {
                try Self.handOffPackage(archive)
                phases[key] = .finished("Installer package opened - complete the update there.")
                return
            }

            // 1. Sparkle's own integrity check, when the app publishes a key.
            phases[key] = .verifying
            let signature = update.edSignature
            let publicKey = update.publicKey
            let outcome = await Task.detached(priority: .userInitiated) {
                SparkleSignature.verify(fileAt: archive, signatureBase64: signature, publicKeyBase64: publicKey)
            }.value
            if case .invalid(let reason) = outcome {
                throw InstallerError.step(reason)
            }

            if UserDefaults.standard.bool(forKey: Prefs.backupBeforeUpdate) {
                phases[key] = .backingUp
                try await Self.backup(appPath: key, appName: update.appName, version: update.currentVersion)
                await loadBackups()
                Self.pruneBackups(keep: max(1, UserDefaults.standard.integer(forKey: Prefs.keepBackupsPerApp)))
            }

            phases[key] = .extracting
            let payload = try await Self.extract(archive, workDir: staging)
            let newApp: URL
            switch payload {
            case .package(let pkg):
                try Self.handOffPackage(pkg)
                phases[key] = .finished("Installer package opened - complete the update there.")
                return
            case .app(let url):
                newApp = url
            }

            // 2. Same developer as the version being replaced (Sparkle's code-signing rule).
            phases[key] = .verifying
            try await Self.verifyCodeSigning(newApp: newApp, replacing: key, signatureVerified: outcome == .valid)

            phases[key] = .installing
            try await Self.install(newAppAt: newApp, replacing: key)

            phases[key] = .finished("Updated to \(update.latestVersion).")
            if UserDefaults.standard.bool(forKey: Prefs.notifyOnOperations) {
                NotificationManager.post(
                    title: "\(update.appName) updated",
                    body: "\(update.currentVersion) → \(update.latestVersion)",
                    page: .appUpdates
                )
            }
            await onInstalled?(key)
        } catch {
            phases[key] = .failed(error.localizedDescription)
            if UserDefaults.standard.bool(forKey: Prefs.notifyOnOperations) {
                NotificationManager.post(
                    title: "Update failed: \(update.appName)",
                    body: error.localizedDescription,
                    page: .appUpdates
                )
            }
        }
    }

    nonisolated static func isInstallerPackage(_ url: URL) -> Bool {
        ["pkg", "mpkg"].contains(url.pathExtension.lowercased())
    }

    /// Moves a .pkg out of the throwaway staging folder and opens it in Installer.
    nonisolated static func handOffPackage(_ pkg: URL) throws {
        let keep = stagingRoot.appendingPathComponent(pkg.lastPathComponent)
        try? FileManager.default.removeItem(at: keep)
        try FileManager.default.moveItem(at: pkg, to: keep)
        Task { @MainActor in NSWorkspace.shared.open(keep) }
    }

    // MARK: - Download with progress

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let destinationDir: URL
        let onProgress: (Double?) -> Void
        var continuation: CheckedContinuation<URL, Error>?

        init(destinationDir: URL, onProgress: @escaping (Double?) -> Void) {
            self.destinationDir = destinationDir
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 {
                onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            } else {
                onProgress(nil)
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // A 404 page saved as "Update.zip" must not reach the extractor.
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                continuation?.resume(throwing: InstallerError.step("Download failed (HTTP \(http.statusCode))."))
                continuation = nil
                return
            }
            let suggested = downloadTask.response?.suggestedFilename
                ?? downloadTask.originalRequest?.url?.lastPathComponent
                ?? "update.download"
            let destination = destinationDir.appendingPathComponent(suggested)
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                continuation?.resume(returning: destination)
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                continuation?.resume(throwing: error)
                continuation = nil
            }
        }
    }

    nonisolated static func download(
        _ url: URL,
        into directory: URL,
        onProgress: @escaping (Double?) -> Void
    ) async throws -> URL {
        let delegate = DownloadDelegate(destinationDir: directory, onProgress: onProgress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            var request = URLRequest(url: url)
            request.setValue("Brewer/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    // MARK: - Verification

    /// Refuses the swap when the new bundle fails `codesign --verify`, or when the
    /// developer identity changed (signed app replaced by a differently signed or
    /// unsigned one). A valid EdDSA signature already vouches for unsigned apps.
    nonisolated static func verifyCodeSigning(newApp: URL, replacing appPath: String, signatureVerified: Bool) async throws {
        let oldTeam = await CodeSigning.teamIdentifier(ofApp: appPath)
        let newTeam = await CodeSigning.teamIdentifier(ofApp: newApp.path)

        if newTeam != nil {
            let check = await CodeSigning.verify(appAt: newApp.path)
            guard check.ok else {
                throw InstallerError.step("The downloaded app failed code-signature verification: \(check.detail.prefix(160))")
            }
        }
        if let oldTeam {
            guard let newTeam else {
                if signatureVerified { return }
                throw InstallerError.step("The current version is signed by team \(oldTeam) but the update is unsigned - refusing to install it.")
            }
            guard newTeam == oldTeam else {
                throw InstallerError.step("The update is signed by a different developer (\(newTeam) instead of \(oldTeam)) - refusing to install it.")
            }
        }
    }

    // MARK: - Backup

    nonisolated static func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    nonisolated static func backup(appPath: String, appName: String, version: String) async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dir = backupsRoot
            .appendingPathComponent(sanitized(appName), isDirectory: true)
            .appendingPathComponent("\(sanitized(version))_\(formatter.string(from: Date()))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "\(appPath)".write(to: dir.appendingPathComponent("origin.txt"), atomically: true, encoding: .utf8)
        let target = dir.appendingPathComponent(URL(fileURLWithPath: appPath).lastPathComponent)
        let result = await Shell.run("/usr/bin/ditto", [appPath, target.path])
        guard result.succeeded else {
            throw InstallerError.step("Backup failed: \(result.stderr.prefix(200))")
        }
    }

    enum InstallerError: LocalizedError {
        case step(String)
        var errorDescription: String? {
            if case .step(let message) = self { return message }
            return nil
        }
    }

    // MARK: - Extraction

    enum Payload {
        case app(URL)
        case package(URL)
    }

    nonisolated static func extract(_ archive: URL, workDir: URL) async throws -> Payload {
        let name = archive.lastPathComponent.lowercased()
        let extractDir = workDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        if name.hasSuffix(".app") {
            return .app(archive)
        }
        if name.hasSuffix(".zip") {
            let result = await Shell.run("/usr/bin/ditto", ["-xk", archive.path, extractDir.path])
            guard result.succeeded else { throw InstallerError.step("Could not unzip the update: \(result.stderr.prefix(200))") }
            return try findPayload(in: extractDir)
        }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") || name.hasSuffix(".tar.bz2")
            || name.hasSuffix(".tbz") || name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") || name.hasSuffix(".tar") {
            let result = await Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", extractDir.path])
            guard result.succeeded else { throw InstallerError.step("Could not extract the archive: \(result.stderr.prefix(200))") }
            return try findPayload(in: extractDir)
        }
        if name.hasSuffix(".dmg") {
            let mountPoint = workDir.appendingPathComponent("mount", isDirectory: true)
            let attach = await Shell.run("/usr/bin/hdiutil", [
                "attach", archive.path, "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mountPoint.path
            ])
            guard attach.succeeded else {
                throw InstallerError.step("Could not open the disk image (it may require accepting a license - open it manually).")
            }
            defer {
                Task.detached { _ = await Shell.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }
            }
            let payload = try findPayload(in: mountPoint)
            switch payload {
            case .app(let appInDMG):
                let copied = extractDir.appendingPathComponent(appInDMG.lastPathComponent)
                let copy = await Shell.run("/usr/bin/ditto", [appInDMG.path, copied.path])
                guard copy.succeeded else { throw InstallerError.step("Could not copy the app out of the disk image.") }
                return .app(copied)
            case .package(let pkgInDMG):
                let copied = extractDir.appendingPathComponent(pkgInDMG.lastPathComponent)
                let copy = await Shell.run("/usr/bin/ditto", [pkgInDMG.path, copied.path])
                guard copy.succeeded else { throw InstallerError.step("Could not copy the installer out of the disk image.") }
                return .package(copied)
            }
        }
        throw InstallerError.step("Unsupported update format (\(archive.pathExtension)). Download it manually instead.")
    }

    /// Breadth-first, max 3 levels: the first .app wins, otherwise the first installer package.
    nonisolated static func findPayload(in directory: URL) throws -> Payload {
        let fileManager = FileManager.default
        var queue: [(URL, Int)] = [(directory, 0)]
        var package: URL?
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            guard let entries = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries where entry.pathExtension == "app" {
                return .app(entry)
            }
            if package == nil, let pkg = entries.first(where: { isInstallerPackage($0) }) {
                package = pkg
            }
            if depth < 3 {
                for entry in entries where !isInstallerPackage(entry) {
                    let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDirectory { queue.append((entry, depth + 1)) }
                }
            }
        }
        if let package { return .package(package) }
        throw InstallerError.step("No .app bundle found inside the downloaded update.")
    }

    // MARK: - Install

    nonisolated static func install(newAppAt newApp: URL, replacing appPath: String) async throws {
        // Quit the running app cleanly first.
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == appPath }
        }
        for app in running { _ = app.terminate() }
        for _ in 0..<16 where !running.allSatisfy({ $0.isTerminated }) {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let destination = URL(fileURLWithPath: appPath)
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: destination, resultingItemURL: &trashed)
        } catch {
            throw InstallerError.step("Could not move the old version to the Trash: \(error.localizedDescription)")
        }
        let copy = await Shell.run("/usr/bin/ditto", [newApp.path, destination.path])
        guard copy.succeeded else {
            // Put the old version back so the user is never left without the app.
            try? FileManager.default.removeItem(at: destination)
            if let trashed = trashed as URL? {
                try? FileManager.default.moveItem(at: trashed, to: destination)
            }
            throw InstallerError.step("Could not install the new version (the old one was restored): \(copy.stderr.prefix(200))")
        }
    }

    // MARK: - Backups list / restore

    func loadBackups() async {
        let root = Self.backupsRoot
        let entries = await Task.detached(priority: .utility) { () -> [BackupEntry] in
            let fileManager = FileManager.default
            guard let appDirs = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
            var result: [BackupEntry] = []
            for appDir in appDirs where !appDir.hasPrefix(".") {
                let appDirURL = root.appendingPathComponent(appDir)
                guard let versionDirs = try? fileManager.contentsOfDirectory(atPath: appDirURL.path) else { continue }
                for versionDir in versionDirs where !versionDir.hasPrefix(".") {
                    let dirURL = appDirURL.appendingPathComponent(versionDir)
                    guard let contents = try? fileManager.contentsOfDirectory(atPath: dirURL.path),
                          let appBundle = contents.first(where: { $0.hasSuffix(".app") }) else { continue }
                    let origin = try? String(
                        contentsOf: dirURL.appendingPathComponent("origin.txt"), encoding: .utf8
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    let attrs = try? fileManager.attributesOfItem(atPath: dirURL.path)
                    let date = (attrs?[.creationDate] as? Date) ?? Date.distantPast
                    let version = Self.versionPart(ofBackupName: versionDir)
                    result.append(BackupEntry(
                        appName: appDir,
                        version: version,
                        date: date,
                        path: dirURL.path,
                        appBundlePath: dirURL.appendingPathComponent(appBundle).path,
                        originalPath: origin
                    ))
                }
            }
            return result.sorted { $0.date > $1.date }
        }.value
        backups = entries
    }

    func restore(_ entry: BackupEntry) async -> String {
        guard let origin = entry.originalPath else {
            return "This backup doesn't record where the app came from."
        }
        let destination = URL(fileURLWithPath: origin)
        if FileManager.default.fileExists(atPath: origin) {
            let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == origin }
            for app in running { app.terminate() }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            do {
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            } catch {
                return "Could not move the current version aside: \(error.localizedDescription)"
            }
        }
        let copy = await Shell.run("/usr/bin/ditto", [entry.appBundlePath, destination.path])
        if copy.succeeded { await onInstalled?(origin) }
        return copy.succeeded
            ? "Restored \(entry.appName) \(entry.version)."
            : "Restore failed: \(copy.stderr.prefix(200))"
    }

    func deleteBackup(_ entry: BackupEntry) async {
        try? FileManager.default.removeItem(atPath: entry.path)
        await loadBackups()
    }

    // Backup folders are named "<version>_<yyyyMMdd-HHmmss>"; ordering must use
    // the timestamp, not the version text ("1.10" sorts before "1.9" as a string).

    nonisolated static func versionPart(ofBackupName name: String) -> String {
        guard let underscore = name.lastIndex(of: "_") else { return name }
        return String(name[..<underscore])
    }

    nonisolated static func timestampPart(ofBackupName name: String) -> String {
        guard let underscore = name.lastIndex(of: "_") else { return "" }
        return String(name[name.index(after: underscore)...])
    }

    nonisolated static func sortedNewestFirst(_ backupNames: [String]) -> [String] {
        backupNames.sorted { timestampPart(ofBackupName: $0) > timestampPart(ofBackupName: $1) }
    }

    nonisolated static func pruneBackups(keep: Int) {
        let fileManager = FileManager.default
        guard let appDirs = try? fileManager.contentsOfDirectory(atPath: backupsRoot.path) else { return }
        for appDir in appDirs where !appDir.hasPrefix(".") {
            let appDirURL = backupsRoot.appendingPathComponent(appDir)
            guard let names = try? fileManager.contentsOfDirectory(atPath: appDirURL.path) else { continue }
            let ordered = sortedNewestFirst(names.filter { !$0.hasPrefix(".") })
            for oldest in ordered.dropFirst(keep) {
                try? fileManager.removeItem(at: appDirURL.appendingPathComponent(oldest))
            }
        }
    }
}
