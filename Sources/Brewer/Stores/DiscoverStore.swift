import Foundation
import Observation

struct DiscoverItem: Identifiable, Hashable {
    var id: String { "\(kind.rawValue):\(token)" }
    let token: String
    let kind: PackageKind
    let fallbackDesc: String
}

struct DiscoverCategory: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let symbol: String
    let items: [DiscoverItem]
}

/// Curated catalog plus live details (description, latest version, install counts)
/// fetched from formulae.brew.sh.
@MainActor
@Observable
final class DiscoverStore {

    struct ApiDetail {
        var desc: String?
        var version: String?
        var installs365d: Int?
        var homepage: String?
    }

    let categories: [DiscoverCategory] = DiscoverStore.catalog
    var details: [String: ApiDetail] = [:]
    private var loading: Set<String> = []

    var allCategory: DiscoverCategory {
        DiscoverCategory(
            name: "All Categories",
            symbol: "square.grid.2x2",
            items: categories.flatMap(\.items)
        )
    }

    func loadDetailsIfNeeded(for item: DiscoverItem) {
        let key = item.id
        guard details[key] == nil, !loading.contains(key) else { return }
        loading.insert(key)
        Task { [weak self] in
            let path = item.kind == .cask ? "cask" : "formula"
            var detail = ApiDetail()
            if let url = URL(string: "https://formulae.brew.sh/api/\(path)/\(item.token).json"),
               let data = try? await HTTP.fetchData(url, timeout: 12),
               let decoded = try? JSONDecoder().decode(ApiPackageJSON.self, from: data) {
                detail.desc = decoded.desc
                detail.version = decoded.latestVersion
                detail.installs365d = decoded.installs365d
                detail.homepage = decoded.homepage
            }
            await MainActor.run {
                self?.details[key] = detail
                self?.loading.remove(key)
            }
        }
    }

    // MARK: Catalog

    private static let catalog: [DiscoverCategory] = [
        DiscoverCategory(name: "Development", symbol: "hammer", items: [
            DiscoverItem(token: "visual-studio-code", kind: .cask, fallbackDesc: "Open-source code editor"),
            DiscoverItem(token: "iterm2", kind: .cask, fallbackDesc: "Terminal emulator as alternative to Apple's Terminal app"),
            DiscoverItem(token: "fork", kind: .cask, fallbackDesc: "GUI client for Git"),
            DiscoverItem(token: "postman", kind: .cask, fallbackDesc: "Collaboration platform for API development"),
            DiscoverItem(token: "tableplus", kind: .cask, fallbackDesc: "Native GUI tool for relational databases"),
            DiscoverItem(token: "orbstack", kind: .cask, fallbackDesc: "Fast, light Docker containers and Linux machines"),
            DiscoverItem(token: "gh", kind: .formula, fallbackDesc: "GitHub command-line tool"),
            DiscoverItem(token: "git", kind: .formula, fallbackDesc: "Distributed revision control system")
        ]),
        DiscoverCategory(name: "Cloud & DevOps", symbol: "cloud", items: [
            DiscoverItem(token: "awscli", kind: .formula, fallbackDesc: "Official Amazon AWS command-line interface"),
            DiscoverItem(token: "kubernetes-cli", kind: .formula, fallbackDesc: "Kubernetes command-line interface"),
            DiscoverItem(token: "helm", kind: .formula, fallbackDesc: "Kubernetes package manager"),
            DiscoverItem(token: "opentofu", kind: .formula, fallbackDesc: "Drop-in replacement for Terraform"),
            DiscoverItem(token: "colima", kind: .formula, fallbackDesc: "Container runtimes on macOS with minimal setup"),
            DiscoverItem(token: "docker", kind: .formula, fallbackDesc: "Pack, ship and run applications as containers")
        ]),
        DiscoverCategory(name: "Utilities", symbol: "wrench.and.screwdriver", items: [
            DiscoverItem(token: "raycast", kind: .cask, fallbackDesc: "Control your tools with a few keystrokes"),
            DiscoverItem(token: "rectangle", kind: .cask, fallbackDesc: "Move and resize windows using keyboard shortcuts or snap areas"),
            DiscoverItem(token: "appcleaner", kind: .cask, fallbackDesc: "Application uninstaller"),
            DiscoverItem(token: "keka", kind: .cask, fallbackDesc: "File archiver"),
            DiscoverItem(token: "stats", kind: .cask, fallbackDesc: "System monitor for the menu bar"),
            DiscoverItem(token: "alt-tab", kind: .cask, fallbackDesc: "Windows-style alt-tab window switcher"),
            DiscoverItem(token: "shottr", kind: .cask, fallbackDesc: "Screenshot measurement and annotation tool")
        ]),
        DiscoverCategory(name: "Databases", symbol: "cylinder.split.1x2", items: [
            DiscoverItem(token: "dbeaver-community", kind: .cask, fallbackDesc: "Universal database tool and SQL client"),
            DiscoverItem(token: "mongodb-compass", kind: .cask, fallbackDesc: "Interactive tool for analyzing MongoDB data"),
            DiscoverItem(token: "sequel-ace", kind: .cask, fallbackDesc: "MySQL/MariaDB database management platform"),
            DiscoverItem(token: "db-browser-for-sqlite", kind: .cask, fallbackDesc: "Browser for SQLite databases"),
            DiscoverItem(token: "postgresql@17", kind: .formula, fallbackDesc: "Object-relational database system"),
            DiscoverItem(token: "redis", kind: .formula, fallbackDesc: "Persistent key-value database")
        ]),
        DiscoverCategory(name: "Productivity", symbol: "doc.text", items: [
            DiscoverItem(token: "libreoffice", kind: .cask, fallbackDesc: "Free cross-platform office suite, fresh version"),
            DiscoverItem(token: "notion", kind: .cask, fallbackDesc: "App to write, plan, collaborate, and get organised"),
            DiscoverItem(token: "obsidian", kind: .cask, fallbackDesc: "Knowledge base that works on top of a local folder of plain text Markdown files"),
            DiscoverItem(token: "karabiner-elements", kind: .cask, fallbackDesc: "Keyboard customiser"),
            DiscoverItem(token: "anki", kind: .cask, fallbackDesc: "Memory training application"),
            DiscoverItem(token: "todoist-app", kind: .cask, fallbackDesc: "To-do list and task manager")
        ]),
        DiscoverCategory(name: "Media & Graphics", symbol: "photo.on.rectangle", items: [
            DiscoverItem(token: "vlc", kind: .cask, fallbackDesc: "Multimedia player"),
            DiscoverItem(token: "iina", kind: .cask, fallbackDesc: "Free and open-source media player"),
            DiscoverItem(token: "handbrake-app", kind: .cask, fallbackDesc: "Open-source video transcoder"),
            DiscoverItem(token: "gimp", kind: .cask, fallbackDesc: "Free and open-source image editor"),
            DiscoverItem(token: "inkscape", kind: .cask, fallbackDesc: "Professional vector graphics editor"),
            DiscoverItem(token: "blender", kind: .cask, fallbackDesc: "3D creation suite"),
            DiscoverItem(token: "obs", kind: .cask, fallbackDesc: "Open-source software for live streaming and screen recording")
        ]),
        DiscoverCategory(name: "Communication", symbol: "bubble.left.and.bubble.right", items: [
            DiscoverItem(token: "slack", kind: .cask, fallbackDesc: "Team communication and collaboration software"),
            DiscoverItem(token: "discord", kind: .cask, fallbackDesc: "Voice and text chat software"),
            DiscoverItem(token: "zoom", kind: .cask, fallbackDesc: "Video communication and virtual meeting platform"),
            DiscoverItem(token: "telegram", kind: .cask, fallbackDesc: "Messaging app with a focus on speed and security"),
            DiscoverItem(token: "signal", kind: .cask, fallbackDesc: "Instant messaging application focusing on security")
        ]),
        DiscoverCategory(name: "Browsers", symbol: "globe", items: [
            DiscoverItem(token: "google-chrome", kind: .cask, fallbackDesc: "Web browser from Google"),
            DiscoverItem(token: "firefox", kind: .cask, fallbackDesc: "Web browser from Mozilla"),
            DiscoverItem(token: "brave-browser", kind: .cask, fallbackDesc: "Web browser focusing on privacy"),
            DiscoverItem(token: "microsoft-edge", kind: .cask, fallbackDesc: "Web browser from Microsoft"),
            DiscoverItem(token: "arc", kind: .cask, fallbackDesc: "Chromium-based browser")
        ]),
        DiscoverCategory(name: "Security", symbol: "lock.shield", items: [
            DiscoverItem(token: "1password", kind: .cask, fallbackDesc: "Password manager that keeps all passwords secure"),
            DiscoverItem(token: "bitwarden", kind: .cask, fallbackDesc: "Desktop password and login vault"),
            DiscoverItem(token: "veracrypt", kind: .cask, fallbackDesc: "Disk encryption software"),
            DiscoverItem(token: "gpg-suite", kind: .cask, fallbackDesc: "Tools to protect your emails and files"),
            DiscoverItem(token: "little-snitch", kind: .cask, fallbackDesc: "Host-based application firewall")
        ]),
        DiscoverCategory(name: "Terminal & Shell", symbol: "terminal", items: [
            DiscoverItem(token: "wget", kind: .formula, fallbackDesc: "Internet file retriever"),
            DiscoverItem(token: "jq", kind: .formula, fallbackDesc: "Lightweight and flexible command-line JSON processor"),
            DiscoverItem(token: "ripgrep", kind: .formula, fallbackDesc: "Search tool like grep and The Silver Searcher"),
            DiscoverItem(token: "fzf", kind: .formula, fallbackDesc: "Command-line fuzzy finder"),
            DiscoverItem(token: "tmux", kind: .formula, fallbackDesc: "Terminal multiplexer"),
            DiscoverItem(token: "htop", kind: .formula, fallbackDesc: "Improved top (interactive process viewer)"),
            DiscoverItem(token: "eza", kind: .formula, fallbackDesc: "Modern, maintained replacement for ls"),
            DiscoverItem(token: "bat", kind: .formula, fallbackDesc: "Clone of cat with syntax highlighting and Git integration")
        ])
    ]
}
