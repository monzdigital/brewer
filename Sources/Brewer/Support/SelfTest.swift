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

        // 19. Homebrew 7 structured doctor output
        let doctorSample = """
        {"tier": 1, "findings": [
          {"text": "You have unlinked kegs in your Cellar.\\nLeaving kegs unlinked can lead to build-trouble.", "tier": 1,
           "affects": ["openssl@4"], "links": [], "remediation": {"commands": ["brew link openssl@4"], "text": "Run brew link on these:\\n  openssl@4"}},
          {"text": "The following taps are not trusted:\\n  a/b", "tier": 1, "affects": [], "links": ["https://docs.brew.sh/Tap-Trust"],
           "remediation": {"commands": [], "text": ""}}
        ]}
        """
        let doctorFindings = (try? JSONDecoder().decode(DoctorReportJSON.self, from: Data(doctorSample.utf8)))
            .map { HealthStore.findings(from: $0) } ?? []
        check("doctor --json findings parse",
              doctorFindings.count == 2
              && doctorFindings[0].title == "You have unlinked kegs in your Cellar."
              && doctorFindings[0].details == "Leaving kegs unlinked can lead to build-trouble."
              && doctorFindings[0].affects == ["openssl@4"]
              && doctorFindings[0].commands == ["brew link openssl@4"]
              && doctorFindings[1].remediation == nil && doctorFindings[1].links.count == 1,
              detail: doctorFindings.map(\.title).joined(separator: " | "))
        check("doctor --json without findings is rejected (text fallback)",
              (try? JSONDecoder().decode(DoctorReportJSON.self, from: Data(#"{"error": "x"}"#.utf8))) == nil)
        check("doctor fixes: only plain brew commands may run",
              HealthStore.brewArguments(forRemediation: "brew link openssl@4") == ["link", "openssl@4"]
              && HealthStore.brewArguments(forRemediation: "rm -rf /") == nil
              && HealthStore.brewArguments(forRemediation: "brew install x; rm -rf ~") == nil
              && HealthStore.brewArguments(forRemediation: "brew $(id)") == nil
              && HealthStore.brewArguments(forRemediation: "brew") == nil)

        // 20. Homebrew 7 vulnerability scan output
        let vulnsSample = """
        {"checked": 3, "complete": true, "findings": [
          {"formula": "boost", "version": "1.92.0", "vulnerabilities": [
             {"id": "OSV-2024-112", "severity": "LOW", "summary": "a", "aliases": [], "fixed_versions": []},
             {"id": "OSV-2024-914", "severity": "MEDIUM", "summary": "b", "aliases": [], "fixed_versions": ["abc"]}], "patched": []},
          {"formula": "openjpeg", "version": "2.5.4", "vulnerabilities": [
             {"id": "CVE-1", "severity": "HIGH", "summary": "c", "aliases": [], "fixed_versions": []}],
           "patched": [{"id": "CVE-0", "severity": "UNKNOWN", "summary": "d", "aliases": [], "fixed_versions": []}]},
          {"formula": "clean", "version": "1", "vulnerabilities": [], "patched": []}],
         "unscanned_formulae": {"sshpass": "untrusted_tap"}}
        """
        let vulnsReport = try? JSONDecoder().decode(VulnsReportJSON.self, from: Data(vulnsSample.utf8))
        let vulnerable = vulnsReport.map { HealthStore.vulnerablePackages(from: $0) } ?? []
        check("brew vulns --json parses and ranks by severity",
              vulnerable.map(\.formula) == ["openjpeg", "boost"]
              && vulnerable.first?.highestSeverity == .high
              && vulnerable.first?.patchedCount == 1
              && vulnerable.last?.advisories.map(\.severity) == [.medium, .low]
              && vulnerable.last?.advisories.first?.hasUpstreamFix == true
              && vulnsReport?.unscanned_formulae?["sshpass"] == "untrusted_tap",
              detail: vulnerable.map { "\($0.formula):\($0.highestSeverity.label)" }.joined(separator: ", "))

        // 21. Tap trust from tap-info (Homebrew 7) with a file fallback for Homebrew 6
        let tapInfoSample = #"[{"name": "a/b", "trusted": false}, {"name": "C/D", "trusted": true}]"#
        let tapInfos = (try? JSONDecoder().decode([TapInfoJSON].self, from: Data(tapInfoSample.utf8))) ?? []
        let legacyInfos = (try? JSONDecoder().decode([TapInfoJSON].self, from: Data(#"[{"name": "a/b"}]"#.utf8))) ?? []
        check("tap trust comes from tap-info when present",
              TapsStore.trustedNames(fromTapInfo: tapInfos) == ["c/d"]
              && TapsStore.trustedNames(fromTapInfo: legacyInfos) == nil)

        // 22. Brewfile entries exclude the description comments brew bundle dump writes
        check("Brewfile entry count skips comments",
              BrewfileModel.entryCount(in: "# desc\ntap \"a/b\"\nbrew \"jq\"\n\n  # another\ncask \"x\"\n") == 3)

        // 23. Backups: one copy per version, then the newest N
        let backupNames = ["0.109.4_20260830-140931", "0.108_20260801-000000", "0.109.4_20260830-145558", "0.107_20260701-000000"]
        check("backups: duplicates of a kept version are removed",
              AppUpdateInstaller.backupsToRemove(backupNames, keep: 2).sorted()
              == ["0.107_20260701-000000", "0.109.4_20260830-140931"])

        // 24. Homebrew 7 support tiers
        check("platform notice: Sonoma, Intel and Rosetta are Tier 3 on Homebrew 7",
              PlatformSupport.notice(brewMajor: 7, macOSMajor: 14, appleSilicon: true, rosettaBrew: false)?.kind == .sonoma
              && PlatformSupport.notice(brewMajor: 7, macOSMajor: 27, appleSilicon: false, rosettaBrew: false)?.kind == .intel
              && PlatformSupport.notice(brewMajor: 7, macOSMajor: 27, appleSilicon: true, rosettaBrew: true)?.kind == .rosetta
              && PlatformSupport.notice(brewMajor: 7, macOSMajor: 27, appleSilicon: true, rosettaBrew: false) == nil
              && PlatformSupport.notice(brewMajor: 6, macOSMajor: 14, appleSilicon: false, rosettaBrew: false) == nil)

        // 25. History keeps output only for the newest failed operations
        var historySample = (0..<4).map { index in
            HistoryEntry(date: Date(), title: "op \(index)", command: "brew x", succeeded: false,
                         durationSeconds: 1, output: ["line \(index)"])
        }
        HistoryStore.trimStoredOutputs(&historySample, keep: 2)
        check("history trims stored output to the newest failures",
              historySample.map { $0.output != nil } == [true, true, false, false])

        // 26. SmartDelete: removals are detected by bundle ID, moves and renames are not
        func scannedApp(_ path: String, _ bundleID: String?) -> ScannedApp {
            ScannedApp(url: URL(fileURLWithPath: path), name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                       bundleID: bundleID, shortVersion: "1", bundleVersion: "1", executableURL: nil,
                       sparkleFeedURL: nil, sparklePublicKey: nil, hasMASReceipt: false)
        }
        let before = UninstallerStore.snapshot(of: [
            scannedApp("/Applications/Gone.app", "com.example.gone"),
            scannedApp("/Applications/Moved.app", "com.example.moved"),
            scannedApp("/Applications/Stay.app", "com.example.stay")
        ])
        let after = UninstallerStore.snapshot(of: [
            scannedApp("/Applications/Utilities/Moved.app", "com.example.moved"),
            scannedApp("/Applications/Stay.app", "com.example.stay")
        ])
        check("SmartDelete: only truly removed apps are reported",
              UninstallerStore.removedApps(previous: before, current: after).map(\.name) == ["Gone"])

        // Setapp and App Store editions are never updated from a vendor feed.
        func feedApp(_ path: String, _ bundleID: String, receipt: Bool = false) -> ScannedApp {
            ScannedApp(url: URL(fileURLWithPath: path), name: "X", bundleID: bundleID, shortVersion: "1", bundleVersion: "1",
                       executableURL: nil, sparkleFeedURL: URL(string: "https://example.com/appcast.xml"),
                       sparklePublicKey: nil, hasMASReceipt: receipt)
        }
        let setappByID = feedApp("/Applications/TablePlus.app", "com.tinyapp.TablePlus-setapp")
        let setappByPath = feedApp("/Applications/Setapp/Permute.app", "com.charliemonroe.Permute")
        let storeApp = feedApp("/Applications/Store.app", "com.example.store", receipt: true)
        let plainApp = feedApp("/Applications/Plain.app", "com.example.plain")
        check("App Updates skip Setapp and App Store editions",
              !AppUpdatesStore.isDirectUpdateCandidate(setappByID)
              && !AppUpdatesStore.isDirectUpdateCandidate(setappByPath)
              && !AppUpdatesStore.isDirectUpdateCandidate(storeApp)
              && AppUpdatesStore.isDirectUpdateCandidate(plainApp)
              && AppSource.detect(for: setappByPath) == .setapp
              && AppSource.detect(for: plainApp) == .sparkle)
        let liveSetapp = apps.filter(\.isSetappApp)
        check("live scan: Setapp apps are never direct-update candidates",
              liveSetapp.allSatisfy { !AppUpdatesStore.isDirectUpdateCandidate($0) },
              detail: "\(liveSetapp.count) Setapp app(s) found")
        let roots = ["/Applications"]
        check("SmartDelete: folder-level changes only",
              FolderWatcher.isRelevantChange("/Applications/", roots: roots)
              && FolderWatcher.isRelevantChange("/Applications/Setapp", roots: roots)
              && !FolderWatcher.isRelevantChange("/Applications/Foo.app", roots: roots)
              && !FolderWatcher.isRelevantChange("/Applications/Foo.app/Contents/Resources", roots: roots)
              && !FolderWatcher.isRelevantChange("/Users/me/Documents", roots: roots)
              && FolderWatcher.isRelevantChange(FolderWatcher.rescanMarker, roots: roots))

        // 27. SmartDelete: the FSEvents watcher really fires (temporary folder)
        let watchFolder = FileManager.default.temporaryDirectory.appendingPathComponent("brewer-watch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: watchFolder, withIntermediateDirectories: true)
        let watchRoot = FolderWatcher.canonicalPath(watchFolder.path)
        let fired = DispatchSemaphore(value: 0)
        let watcher = FolderWatcher(paths: [watchRoot], latency: 0.2) { changed in
            if changed.contains(where: { FolderWatcher.isRelevantChange($0, roots: [watchRoot]) }) { fired.signal() }
        }
        try? FileManager.default.createDirectory(atPath: watchRoot + "/Dummy.app/Contents", withIntermediateDirectories: true)
        let sawAdd = fired.wait(timeout: .now() + 6) == .success
        try? FileManager.default.removeItem(atPath: watchRoot + "/Dummy.app")
        let sawRemove = fired.wait(timeout: .now() + 6) == .success
        watcher?.stop()
        try? FileManager.default.removeItem(at: watchFolder)
        check("SmartDelete: FSEvents reports an app being added and removed",
              watcher != nil && sawAdd && sawRemove, detail: "added=\(sawAdd) removed=\(sawRemove)")

        // 27b. Shell must never lose a process termination. With waitUntilExit()
        // this hung after a few dozen short processes; a watchdog turns a hang
        // into a failure instead of a stuck self-test.
        let shellWatchdog = DispatchWorkItem {
            print("FAIL  shell: short processes all complete - hung (lost process termination)")
            exit(1)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: shellWatchdog)
        var shellRunsOK = 0
        for _ in 0..<150 {
            let result = await Shell.run("/bin/sh", ["-c", "echo out; echo err >&2"])
            if result.exitCode == 0 && result.stdout == "out" && result.stderr == "err" { shellRunsOK += 1 }
        }
        shellWatchdog.cancel()
        check("shell: short processes all complete", shellRunsOK == 150, detail: "\(shellRunsOK)/150")

        // 28. Live Homebrew 7 payloads on this machine
        if await client.brewMajorVersion() >= 7 {
            let liveDoctor = await client.doctorReport()
            check("live brew doctor --json decodes", liveDoctor != nil,
                  detail: liveDoctor.map { "\($0.findings.count) finding(s)" } ?? "nil")
            let liveTaps = await client.installedTapsInfo()
            check("live tap-info --installed carries the trust flag",
                  liveTaps.map { TapsStore.trustedNames(fromTapInfo: $0) != nil } ?? false,
                  detail: liveTaps.map { "\($0.count) taps" } ?? "nil")
        } else {
            print("      skipped live Homebrew 7 checks (older Homebrew)")
        }

        // 15. sudo askpass helper
        let askpass = AskPass.ensureInstalled()
        check("askpass helper installs", askpass != nil
              && FileManager.default.isExecutableFile(atPath: askpass ?? ""),
              detail: askpass ?? "-")

        return failures
    }
}
