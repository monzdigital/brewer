import Foundation

/// Headless verification of the data layer against the real Homebrew installation.
/// Run with: ./Brewer --selftest  (or: swift run Brewer --selftest)
enum SelfTestRunner {

    static func run() -> Never {
        setbuf(stdout, nil) // stream output even when piped
        print("Brewer self-test - brew at \(BrewEnvironment.current.brewPath)")
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failures: [String] = []

        Task.detached {
            failures = await performChecks()
            semaphore.signal()
        }
        semaphore.wait()

        if failures.isEmpty {
            print("\nAll self-tests passed ✅")
            exit(0)
        } else {
            print("\n\(failures.count) self-test failure(s) ❌")
            for failure in failures { print("  - \(failure)") }
            exit(1)
        }
    }

    private static func performChecks() async -> [String] {
        var failures: [String] = []
        let client = BrewClient()

        func check(_ name: String, _ condition: Bool, detail: String = "") {
            if condition {
                print("PASS  \(name)\(detail.isEmpty ? "" : " - \(detail)")")
            } else {
                print("FAIL  \(name)\(detail.isEmpty ? "" : " - \(detail)")")
                failures.append(name)
            }
        }

        // 1. Environment
        check("brew executable exists", BrewEnvironment.current.exists,
              detail: BrewEnvironment.current.brewPath)

        // 2. Installed snapshot decode
        do {
            let snapshot = try await client.installedSnapshot()
            check("installed snapshot decodes", true,
                  detail: "\(snapshot.formulae.count) formulae, \(snapshot.casks.count) casks")
            let formulaPackages = snapshot.formulae.compactMap { PackageStore.package(from: $0) }
            check("formula mapping", !formulaPackages.isEmpty && formulaPackages.allSatisfy { $0.installedVersion != nil },
                  detail: "\(formulaPackages.count) mapped")
            let caskPackages = snapshot.casks.map { PackageStore.package(from: $0) }
            check("cask mapping", caskPackages.count == snapshot.casks.count,
                  detail: "\(caskPackages.filter { $0.appPath != nil }.count) with app path")
            let outdated = (formulaPackages + caskPackages).filter(\.isOutdated)
            print("      outdated according to snapshot: \(outdated.count)")
        } catch {
            check("installed snapshot decodes", false, detail: error.localizedDescription)
        }

        // 3. Services decode
        do {
            let services = try await client.servicesList()
            check("services list decodes", true, detail: "\(services.count) services")
        } catch {
            check("services list decodes", false, detail: error.localizedDescription)
        }

        // 4. Search
        let (formulaResults, caskResults) = await client.search(query: "jq")
        check("search finds jq", formulaResults.contains("jq"),
              detail: "\(formulaResults.count) formulae, \(caskResults.count) casks")

        // 5. Cleanup dry-run parser
        let cleanup = await client.cleanupDryRun()
        check("cleanup dry-run parses", true,
              detail: "\(cleanup.items.count) items, ~\(cleanup.approximateBytes.map(Format.bytes) ?? "?") reclaimable")

        // 6. Autoremove parser
        let orphans = await client.autoremoveDryRun()
        check("autoremove dry-run parses", true, detail: "\(orphans.count) orphans: \(orphans.joined(separator: ", "))")

        // 7. Version comparison
        check("version compare 1.2.10 > 1.2.9", VersionCompare.isNewer("1.2.10", than: "1.2.9"))
        check("version compare 1.10 > 1.9", VersionCompare.isNewer("1.10", than: "1.9"))
        check("version compare equal", !VersionCompare.isNewer("2.0", than: "2.0"))
        check("version compare 2026.2.0 > 3.1", VersionCompare.isNewer("2026.2.0", than: "3.1"))

        // 8. Deps tree parse
        let treeText = await client.depsTreeText(for: "jq", cask: false)
        let nodes = DepsTreeParser.parse(treeText)
        check("deps tree parses", !nodes.isEmpty, detail: "\(nodes.count) root node(s)")

        // 9. Mach-O inspector on a known universal binary
        let archs = MachOInspector.architectures(ofExecutable: URL(fileURLWithPath: "/bin/ls"))
        check("Mach-O inspector reads /bin/ls", archs.contains("arm64"),
              detail: archs.sorted().joined(separator: "+"))

        // 10. App scanner
        let apps = AppScanner.scanApplications()
        check("app scanner finds apps", !apps.isEmpty,
              detail: "\(apps.count) apps, \(apps.filter { $0.sparkleFeedURL != nil }.count) with Sparkle feed, \(apps.filter(\.hasMASReceipt).count) from App Store")

        // 11. Taps
        let taps = await client.tapNames()
        check("tap list", true, detail: taps.joined(separator: ", "))

        // 12. mas parsers (only if mas output format is available)
        let masLine = "497799835 Xcode (16.0)"
        let parsed = MasStore.parseList(masLine)
        check("mas list parser", parsed.first?.name == "Xcode" && parsed.first?.version == "16.0")

        // 13. Leftover scanner safety rules
        check("leftover: protects Apple apps",
              LeftoverScanner.isProtected(bundleID: "com.apple.Safari", appURL: nil))
        check("leftover: protects /System apps",
              LeftoverScanner.isProtected(bundleID: "com.foo.x", appURL: URL(fileURLWithPath: "/System/Applications/Mail.app")))
        check("leftover: bundle-id prefix matches",
              LeftoverScanner.match(itemName: "com.foo.myapp.plist", bundleID: "com.foo.myapp", appName: "MyApp", allowNameMatch: false) == .bundleID)
        check("leftover: group container matches",
              LeftoverScanner.match(itemName: "group.com.foo.myapp", bundleID: "com.foo.myapp", appName: "MyApp", allowNameMatch: false) == .bundleID)
        check("leftover: exact name matches only where allowed",
              LeftoverScanner.match(itemName: "MyApp", bundleID: nil, appName: "MyApp", allowNameMatch: true) == .nameMatch
              && LeftoverScanner.match(itemName: "MyApp Extras", bundleID: nil, appName: "MyApp", allowNameMatch: true) == nil)
        check("leftover: short names are ignored",
              LeftoverScanner.match(itemName: "Arc", bundleID: nil, appName: "Arc", allowNameMatch: true) == nil)
        check("leftover: sibling bundle ids never match",
              LeftoverScanner.match(itemName: "com.foo.barbaz.plist", bundleID: "com.foo.bar", appName: "Bar", allowNameMatch: false) == nil
              && LeftoverScanner.match(itemName: "ABCDE12345.com.foo.bar", bundleID: "com.foo.bar", appName: "Bar", allowNameMatch: false) == .bundleID)

        // 14. Installer helpers
        check("installer: sanitizes names", AppUpdateInstaller.sanitized("A/B:C") == "A-B-C")
        check("installer: backups prune by timestamp, not version text",
              AppUpdateInstaller.sortedNewestFirst(["1.9_20260801-120000", "1.10_20260901-090000", "2.0_20260701-000000"])
              == ["1.10_20260901-090000", "1.9_20260801-120000", "2.0_20260701-000000"])
        check("installer: rejects a malformed EdDSA signature",
              SparkleSignature.verify(fileAt: URL(fileURLWithPath: "/bin/ls"), signatureBase64: "AAAA", publicKeyBase64: "BBBB") != .notApplicable
              && SparkleSignature.verify(fileAt: URL(fileURLWithPath: "/bin/ls"), signatureBase64: nil, publicKeyBase64: "BBBB") == .notApplicable)

        // 16. Sparkle comparison follows build numbers when both sides have them
        check("sparkle: build number decides",
              SparkleUpdate.isUpdate(currentVersion: "2.0", latestVersion: "2.0", currentBuild: "200", latestBuild: "201")
              && !SparkleUpdate.isUpdate(currentVersion: "1.9", latestVersion: "2.0", currentBuild: "300", latestBuild: "200")
              && SparkleUpdate.isUpdate(currentVersion: "1.9", latestVersion: "2.0", currentBuild: nil, latestBuild: "200"))
        let appcast = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:version>300</sparkle:version><sparkle:shortVersionString>3.0</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/3.zip" sparkle:edSignature="sig3" length="10"/></item>
        <item><sparkle:version>250</sparkle:version><sparkle:shortVersionString>2.5</sparkle:shortVersionString>
          <enclosure url="https://example.com/2.zip" sparkle:os="windows"/></item>
        <item><sparkle:version>240</sparkle:version><sparkle:shortVersionString>2.4</sparkle:shortVersionString>
          <enclosure url="https://example.com/24.zip" sparkle:edSignature="sig24"/></item>
        <item><sparkle:version>230</sparkle:version><sparkle:channel>beta</sparkle:channel>
          <enclosure url="https://example.com/23.zip"/></item>
        </channel></rss>
        """
        let parsedAppcast = AppcastParser().parse(data: Data(appcast.utf8))
        check("sparkle: appcast skips beta, Windows and too-new-macOS items",
              parsedAppcast?.version == "2.4" && parsedAppcast?.buildVersion == "240" && parsedAppcast?.edSignature == "sig24",
              detail: parsedAppcast.map { "\($0.version) build \($0.buildVersion ?? "-")" } ?? "nil")

        // 17. brew outdated JSON (greedy cask merge)
        let outdatedJSON = """
        {"formulae":[],"casks":[{"name":"stats","installed_versions":["2.8.24"],"current_version":"3.0.15","pinned":false,"pinned_version":null}]}
        """
        var mergeCasks = [BrewPackage(kind: .cask, name: "stats", displayName: "Stats")]
        mergeCasks[0].installedVersion = "2.8.24"
        if let decoded = try? JSONDecoder().decode(OutdatedResponse.self, from: Data(outdatedJSON.utf8)) {
            PackageStore.mergeGreedyOutdated(decoded.casks ?? [], into: &mergeCasks)
        }
        check("greedy outdated merge marks the cask",
              mergeCasks[0].isOutdated && mergeCasks[0].latestVersion == "3.0.15")

        // 18. Snooze pruning (pure rule - the main thread is blocked here, so no MainActor hops)
        var stats = BrewPackage(kind: .cask, name: "stats", displayName: "Stats")
        stats.installedVersion = "3.0.15"
        var old = BrewPackage(kind: .cask, name: "old", displayName: "Old")
        old.installedVersion = "1.0"
        old.latestVersion = "1.1"
        old.isOutdated = true
        var kept = BrewPackage(kind: .formula, name: "kept", displayName: "kept")
        kept.installedVersion = "1.0"
        kept.latestVersion = "1.1"
        kept.isOutdated = true
        let stale = MetaStore.staleSnoozeIDs([
            "cask:stats": SnoozeInfo(until: nil, version: "3.0.15"),                       // already installed
            "cask:old": SnoozeInfo(until: Date(timeIntervalSinceNow: -60), version: nil),   // timer expired
            "formula:kept": SnoozeInfo(until: Date(timeIntervalSinceNow: 3600), version: nil) // still active
        ], packages: [stats, old, kept]).sorted()
        check("snooze pruning drops installed and expired snoozes only",
              stale == ["cask:old", "cask:stats"], detail: stale.joined(separator: ", "))

        // 15. sudo askpass helper
        let askpass = AskPass.ensureInstalled()
        check("askpass helper installs", askpass != nil
              && FileManager.default.isExecutableFile(atPath: askpass ?? ""),
              detail: askpass ?? "-")

        return failures
    }
}
