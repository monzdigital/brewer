import Foundation

/// Scans /Applications and reads app bundle metadata. Shared by the Adopt Apps,
/// App Updates (Sparkle) and Apple Silicon features.
enum AppScanner {

    static func scanApplications() -> [ScannedApp] {
        let fileManager = FileManager.default
        var appURLs: [URL] = []
        for base in ["/Applications", NSHomeDirectory() + "/Applications"] {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: base),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            appURLs.append(contentsOf: entries.filter { $0.pathExtension == "app" })
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
        let shortVersion = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String)

        var executableURL: URL?
        if let executable = plist["CFBundleExecutable"] as? String {
            executableURL = url.appendingPathComponent("Contents/MacOS/\(executable)")
        }

        var feedURL: URL?
        if let feedString = plist["SUFeedURL"] as? String {
            feedURL = URL(string: feedString.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let receiptPath = url.appendingPathComponent("Contents/_MASReceipt/receipt").path
        let hasReceipt = FileManager.default.fileExists(atPath: receiptPath)

        return ScannedApp(
            url: url,
            name: name,
            bundleID: bundleID,
            shortVersion: shortVersion,
            executableURL: executableURL,
            sparkleFeedURL: feedURL,
            hasMASReceipt: hasReceipt
        )
    }

    // MARK: Sparkle appcast

    struct AppcastResult {
        let version: String
        let downloadURL: URL?
        let releaseNotesURL: URL?
    }

    static func latestAppcastVersion(feedURL: URL) async -> AppcastResult? {
        guard let data = try? await HTTP.fetchData(feedURL, timeout: 12) else { return nil }
        let parser = AppcastParser()
        return parser.parse(data: data)
    }
}

/// Minimal Sparkle appcast (RSS) parser.
final class AppcastParser: NSObject, XMLParserDelegate {

    private struct Item {
        var version: String?
        var shortVersion: String?
        var enclosureURL: String?
        var releaseNotesLink: String?
        var link: String?
        var channel: String?

        var effectiveVersion: String? { shortVersion ?? version }
    }

    private var items: [Item] = []
    private var currentItem: Item?
    private var currentElement = ""
    private var currentText = ""

    func parse(data: Data) -> AppScanner.AppcastResult? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        let stableItems = items.filter { item in
            guard let version = item.effectiveVersion, !version.isEmpty else { return false }
            // Skip beta/alternate channels.
            return item.channel == nil || item.channel?.isEmpty == true
        }
        guard var best = stableItems.first else { return nil }
        for item in stableItems.dropFirst() {
            if let a = item.effectiveVersion, let b = best.effectiveVersion,
               VersionCompare.isNewer(a, than: b) {
                best = item
            }
        }
        guard let version = best.effectiveVersion else { return nil }
        let notes = best.releaseNotesLink ?? best.link
        return AppScanner.AppcastResult(
            version: version,
            downloadURL: best.enclosureURL.flatMap(URL.init(string:)),
            releaseNotesURL: notes.flatMap(URL.init(string:))
        )
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        switch elementName {
        case "item":
            currentItem = Item()
        case "enclosure":
            currentItem?.enclosureURL = attributes["url"]
            if let version = attributes["sparkle:version"] { currentItem?.version = version }
            if let short = attributes["sparkle:shortVersionString"] { currentItem?.shortVersion = short }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "sparkle:version":
            if currentItem?.version == nil { currentItem?.version = text }
        case "sparkle:shortVersionString":
            if currentItem?.shortVersion == nil { currentItem?.shortVersion = text }
        case "sparkle:releaseNotesLink":
            currentItem?.releaseNotesLink = text
        case "sparkle:channel":
            currentItem?.channel = text
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
