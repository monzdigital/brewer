import Foundation

/// Describes where Homebrew lives on this machine.
struct BrewEnvironment: Sendable {
    let brewPath: String
    let prefix: String
    let isAppleSiliconMachine: Bool

    var binDir: String { prefix + "/bin" }
    var cellarPath: String { prefix + "/Cellar" }
    var caskroomPath: String { prefix + "/Caskroom" }
    var isRosettaBrew: Bool { isAppleSiliconMachine && prefix == "/usr/local" }
    var exists: Bool { FileManager.default.isExecutableFile(atPath: brewPath) }

    /// The active environment. Set once at startup (and again if the user overrides the path).
    nonisolated(unsafe) static var current: BrewEnvironment = .detect()

    static func detect(customPath: String? = nil) -> BrewEnvironment {
        let appleSilicon = Self.machineIsAppleSilicon()
        var candidates: [String] = []
        if let customPath, !customPath.isEmpty { candidates.append(customPath) }
        candidates.append(contentsOf: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", "/home/linuxbrew/.linuxbrew/bin/brew"])

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let prefix = Self.prefixFor(brewPath: path)
            return BrewEnvironment(brewPath: path, prefix: prefix, isAppleSiliconMachine: appleSilicon)
        }
        // Fall back to the default location even if missing so the UI can explain the problem.
        return BrewEnvironment(
            brewPath: appleSilicon ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew",
            prefix: appleSilicon ? "/opt/homebrew" : "/usr/local",
            isAppleSiliconMachine: appleSilicon
        )
    }

    private static func prefixFor(brewPath: String) -> String {
        // …/bin/brew → prefix is two levels up.
        URL(fileURLWithPath: brewPath).deletingLastPathComponent().deletingLastPathComponent().path
    }

    private static func machineIsAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 {
            return value == 1
        }
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}
