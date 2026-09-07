import Foundation

/// Scans /Applications and reads app bundle metadata. Shared by the Adopt Apps,
/// App Updates (Sparkle), Apps inventory and Apple Silicon features.
enum AppScanner {

    static var applicationRoots: [String] {
        ["/Applications", NSHomeDirectory() + "/Applications"]
    }

    /// Lists app bundles in the application folders. With `includeSubfolders`
    /// one level of plain folders is searched too (Setapp, Utilities, Adobe …),
    /// which is where a large share of manually installed apps live.
    static func scanApplications(includeSubfolders: Bool = true) -> [ScannedApp] {
        let fileManager = FileManager.default
        var appURLs: [URL] = []
        var seen: Set<String> = []

        func collect(in directory: URL, descend: Bool) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if entry.pathExtension == "app" {
                    if seen.insert(entry.path).inserted { appURLs.append(entry) }
                } else if descend, values?.isDirectory == true, values?.isSymbolicLink != true {
                    collect(in: entry, descend: false)
                }
            }
        }

        for base in applicationRoots {
            collect(in: URL(fileURLWithPath: base), descend: includeSubfolders)
        }

        return appURLs.compactMap { url in
            scanApp(at: url)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func scanApp(at url: URL) -> ScannedApp? {
        let infoPlistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        else {
            return nil
        }

        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let bundleID = plist["CFBundleIdentifier"] as? String
        let bundleVersion = plist["CFBundleVersion"] as? String
        let shortVersion = (plist["CFBundleShortVersionString"] as? String) ?? bundleVersion

        var executableURL: URL?
        if let executable = plist["CFBundleExecutable"] as? String {
            executableURL = url.appendingPathComponent("Contents/MacOS/\(executable)")
        }

        var feedURL: URL?
        if let feedString = plist["SUFeedURL"] as? String {
            feedURL = URL(string: feedString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let publicKey = (plist["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let receiptPath = url.appendingPathComponent("Contents/_MASReceipt/receipt").path
        let hasReceipt = FileManager.default.fileExists(atPath: receiptPath)

        return ScannedApp(
            url: url,
            name: name,
            bundleID: bundleID,
            shortVersion: shortVersion,
            bundleVersion: bundleVersion,
            executableURL: executableURL,
            sparkleFeedURL: feedURL,
            sparklePublicKey: publicKey,
            hasMASReceipt: hasReceipt
        )
    }

    // MARK: Sparkle appcast

    struct AppcastResult {
        /// Marketing version for display (falls back to the build number).
        let version: String
        /// sparkle:version - the build number, when the feed provides one.
        let buildVersion: String?
        let downloadURL: URL?
        let releaseNotesURL: URL?
        let notesHTML: String?
        let enclosureBytes: Int64?
        let edSignature: String?
        let minimumSystemVersion: String?
    }

    static func latestAppcastVersion(feedURL: URL) async -> AppcastResult? {
        guard let data = try? await HTTP.fetchData(feedURL, timeout: 12) else { return nil }
        let parser = AppcastParser()
        return parser.parse(data: data)
    }
}

/// Minimal Sparkle appcast (RSS) parser. Ignores beta channels, Windows
/// enclosures (WinSparkle feeds) and items that need a newer macOS than the one
/// running - offering those would break the app on install.
final class AppcastParser: NSObject, XMLParserDelegate {

    struct Item {
        var version: String?
        var shortVersion: String?
        var enclosureURL: String?
        var enclosureLength: Int64?
        var edSignature: String?
        var os: String?
        var minimumSystemVersion: String?
        var releaseNotesLink: String?
        var link: String?
        var channel: String?
        var descriptionHTML: String?

        var displayVersion: String? { shortVersion ?? version }
        /// The value Sparkle compares: build number first, marketing version otherwise.
        var comparableVersion: String? { version ?? shortVersion }
    }

    private var items: [Item] = []
    private var currentItem: Item?
    private var currentText = ""

    /// The running macOS version, injectable for tests.
    var systemVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    func parse(data: Data) -> AppScanner.AppcastResult? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return Self.best(of: items, systemVersion: systemVersion)
    }

    static func best(of items: [Item], systemVersion: String) -> AppScanner.AppcastResult? {
        let eligible = items.filter { item in
            guard let version = item.comparableVersion, !version.isEmpty else { return false }
            // Skip beta/alternate channels.
            guard item.channel == nil || item.channel?.isEmpty == true else { return false }
            if let os = item.os?.lowercased(), !os.isEmpty, os != "macos", os != "osx", os != "mac" {
                return false
            }
            if let minimum = item.minimumSystemVersion, !minimum.isEmpty,
               VersionCompare.isNewer(minimum, than: systemVersion) {
                return false
            }
            return true
        }
        guard var best = eligible.first else { return nil }
        for item in eligible.dropFirst() {
            if let a = item.comparableVersion, let b = best.comparableVersion,
               VersionCompare.isNewer(a, than: b) {
                best = item
            }
        }
        guard let display = best.displayVersion else { return nil }
        let notes = best.releaseNotesLink ?? best.link
        return AppScanner.AppcastResult(
            version: display,
            buildVersion: best.version,
            downloadURL: best.enclosureURL.flatMap(URL.init(string:)),
            releaseNotesURL: notes.flatMap(URL.init(string:)),
            notesHTML: best.descriptionHTML,
            enclosureBytes: best.enclosureLength,
            edSignature: best.edSignature,
            minimumSystemVersion: best.minimumSystemVersion
        )
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        currentText = ""
        switch elementName {
        case "item":
            currentItem = Item()
        case "enclosure":
            currentItem?.enclosureURL = attributes["url"]
            if let version = attributes["sparkle:version"] { currentItem?.version = version }
            if let short = attributes["sparkle:shortVersionString"] { currentItem?.shortVersion = short }
            if let length = attributes["length"].flatMap({ Int64($0) }) { currentItem?.enclosureLength = length }
            if let signature = attributes["sparkle:edSignature"] { currentItem?.edSignature = signature }
            if let os = attributes["sparkle:os"] { currentItem?.os = os }
            if let minimum = attributes["sparkle:minimumSystemVersion"] { currentItem?.minimumSystemVersion = minimum }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        currentText += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "sparkle:version":
            if currentItem?.version == nil { currentItem?.version = text }
        case "sparkle:shortVersionString":
            if currentItem?.shortVersion == nil { currentItem?.shortVersion = text }
        case "sparkle:minimumSystemVersion":
            if currentItem?.minimumSystemVersion == nil { currentItem?.minimumSystemVersion = text }
        case "sparkle:releaseNotesLink":
            currentItem?.releaseNotesLink = text
        case "sparkle:channel":
            currentItem?.channel = text
        case "description":
            if currentItem != nil, !text.isEmpty { currentItem?.descriptionHTML = text }
        case "link":
            if currentItem != nil, currentItem?.link == nil { currentItem?.link = text }
        case "item":
            if let item = currentItem { items.append(item) }
            currentItem = nil
        default:
            break
        }
        currentText = ""
    }
}
