import Foundation

// Tolerant Codable models for Homebrew's JSON output.
// Field shapes were verified against Homebrew 6.0 (`brew info --json=v2`).

// MARK: - Lenient helpers

/// Decodes a String from a String, Int, Double or Bool; anything else becomes nil.
struct LenientString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else if let bool = try? container.decode(Bool.self) {
            value = String(bool)
        } else {
            value = nil
        }
    }
}

/// Decodes `[String]` from a string, an array of strings, or an array of objects with a `version` key.
struct LenientStringArray: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            values = [string]
        } else if let array = try? container.decode([String].self) {
            values = array
        } else if let objects = try? container.decode([VersionObject].self) {
            values = objects.compactMap(\.version)
        } else {
            values = []
        }
    }

    private struct VersionObject: Decodable { let version: String? }
}

// MARK: - brew info --json=v2

struct InfoV2Response: Decodable {
    var formulae: [FormulaJSON]
    var casks: [CaskJSON]

    enum CodingKeys: String, CodingKey { case formulae, casks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formulae = (try? container.decode([SafeDecodable<FormulaJSON>].self, forKey: .formulae))?.compactMap(\.value) ?? []
        casks = (try? container.decode([SafeDecodable<CaskJSON>].self, forKey: .casks))?.compactMap(\.value) ?? []
    }

    init(formulae: [FormulaJSON], casks: [CaskJSON]) {
        self.formulae = formulae
        self.casks = casks
    }
}

/// Wraps an element so one malformed entry doesn't sink the whole array.
struct SafeDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

struct FormulaJSON: Decodable {
    var name: String
    var full_name: String?
    var tap: String?
    var desc: String?
    var license: String?
    var homepage: String?
    var versions: VersionsJSON?
    var installed: [InstalledEntryJSON]?
    var pinned: Bool?
    var outdated: Bool?
    var deprecated: Bool?
    var deprecation_reason: String?
    var disabled: Bool?
    var disable_date: String?
    var caveats: String?
    var dependencies: [String]?
    var build_dependencies: [String]?
    var aliases: [String]?
    var keg_only: Bool?
    var keg_only_reason: KegOnlyReasonJSON?
    var linked_keg: String?
}

/// `keg_only_reason` is an object today ({"reason":…, "explanation":…}) but was a
/// plain string in older Homebrew releases; either shape must not sink the formula.
struct KegOnlyReasonJSON: Decodable {
    var reason: String?
    var explanation: String?

    enum CodingKeys: String, CodingKey { case reason, explanation }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            reason = (try? container.decodeIfPresent(LenientString.self, forKey: .reason))?.value
            explanation = (try? container.decodeIfPresent(LenientString.self, forKey: .explanation))?.value
        } else if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            reason = text
        }
    }

    var displayText: String? {
        if let explanation, !explanation.isEmpty { return explanation }
        guard let reason, !reason.isEmpty else { return nil }
        // ":versioned_formula" -> "versioned formula"
        return reason.trimmingCharacters(in: CharacterSet(charactersIn: ":")).replacingOccurrences(of: "_", with: " ")
    }
}

struct VersionsJSON: Decodable {
    var stable: String?
    var head: String?
}

struct InstalledEntryJSON: Decodable {
    var version: String?
    var installed_as_dependency: Bool?
    var installed_on_request: Bool?
}

struct CaskJSON: Decodable {
    var token: String
    var full_token: String?
    var tap: String?
    var name: [String]?
    var desc: String?
    var homepage: String?
    var version: String?
    var installed: LenientString?
    var installed_time: Double?
    var bundle_version: String?
    var outdated: Bool?
    var deprecated: Bool?
    var deprecation_reason: String?
    var disabled: Bool?
    var caveats: String?
    var auto_updates: Bool?
    var artifacts: [CaskArtifactJSON]?

    /// Names of .app bundles this cask installs.
    var appNames: [String] {
        (artifacts ?? []).flatMap { artifact -> [String] in
            (artifact.app ?? []).compactMap { entry in
                guard let raw = entry.value else { return nil }
                return URL(fileURLWithPath: raw).lastPathComponent
            }
        }
    }
}

struct CaskArtifactJSON: Decodable {
    var app: [LenientString]?

    enum CodingKeys: String, CodingKey { case app }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        app = try? container?.decodeIfPresent([LenientString].self, forKey: .app)
    }
}

// MARK: - brew outdated --json=v2

struct OutdatedResponse: Decodable {
    var formulae: [OutdatedEntryJSON]?
    var casks: [OutdatedEntryJSON]?
}

struct OutdatedEntryJSON: Decodable {
    var name: String
    var installed_versions: LenientStringArray?
    var current_version: String?
    var pinned: Bool?
    var pinned_version: String?
}

// MARK: - brew services list --json

struct ServiceJSON: Decodable {
    var name: String
    var status: String?
    var user: String?
    var file: String?
    var exit_code: Int?
    var pid: Int?
}

// MARK: - brew tap-info --json

struct TapInfoJSON: Decodable {
    var name: String
    var user: String?
    var repo: String?
    var official: Bool?
    var installed: Bool?
    var formula_names: [String]?
    var cask_tokens: [String]?
    var path: String?
    var remote: String?
    /// Homebrew 7+: whether `brew trust` lets Homebrew load this tap.
    var trusted: Bool?
}

// MARK: - brew doctor --json (Homebrew 7+)

struct DoctorReportJSON: Decodable {
    var tier: Int?
    var findings: [DoctorFindingJSON]

    enum CodingKeys: String, CodingKey { case tier, findings }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tier = try? container.decodeIfPresent(Int.self, forKey: .tier)
        // `findings` is required: a payload without it is not a doctor report,
        // and the caller falls back to the text output instead of "no issues".
        findings = try container.decode([SafeDecodable<DoctorFindingJSON>].self, forKey: .findings).compactMap(\.value)
    }
}

struct DoctorFindingJSON: Decodable {
    var text: String?
    var tier: Int?
    var affects: LenientStringArray?
    var links: LenientStringArray?
    var remediation: DoctorRemediationJSON?
}

struct DoctorRemediationJSON: Decodable {
    var commands: LenientStringArray?
    var text: String?
}

// MARK: - brew vulns --json (Homebrew 7+)

struct VulnsReportJSON: Decodable {
    var checked: Int?
    var complete: Bool?
    var findings: [VulnFindingJSON]
    var skipped_formulae: [String]?
    var unscanned_formulae: [String: String]?

    enum CodingKeys: String, CodingKey { case checked, complete, findings, skipped_formulae, unscanned_formulae }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checked = try? container.decodeIfPresent(Int.self, forKey: .checked)
        complete = try? container.decodeIfPresent(Bool.self, forKey: .complete)
        findings = try container.decode([SafeDecodable<VulnFindingJSON>].self, forKey: .findings).compactMap(\.value)
        skipped_formulae = try? container.decodeIfPresent([String].self, forKey: .skipped_formulae)
        unscanned_formulae = try? container.decodeIfPresent([String: String].self, forKey: .unscanned_formulae)
    }
}

struct VulnFindingJSON: Decodable {
    var formula: String
    var version: String?
    var repo_url: String?
    var vulnerabilities: [VulnerabilityJSON]?
    /// Advisories Homebrew already fixed with a backported patch.
    var patched: [VulnerabilityJSON]?
}

struct VulnerabilityJSON: Decodable {
    var id: String
    var severity: String?
    var summary: String?
    var aliases: [String]?
    var fixed_versions: [String]?
}

// MARK: - formulae.brew.sh API

struct ApiPackageJSON: Decodable {
    var name: LenientString?
    var token: String?
    var desc: String?
    var homepage: String?
    var version: String?
    var versions: VersionsJSON?
    var analytics: ApiAnalyticsJSON?
    var deprecated: Bool?
    var deprecation_reason: String?
    var disabled: Bool?
    var disable_reason: String?

    var installs365d: Int? {
        analytics?.install?["365d"]?.values.first
    }

    var latestVersion: String? {
        version ?? versions?.stable
    }
}

struct ApiAnalyticsJSON: Decodable {
    var install: [String: [String: Int]]?
}
