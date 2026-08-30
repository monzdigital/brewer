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

        // 14. Installer helpers
        check("installer: sanitizes names", AppUpdateInstaller.sanitized("A/B:C") == "A-B-C")

        return failures
    }
}
