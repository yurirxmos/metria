import AppKit
import SwiftUI
import MetriaCore

/// UI metadata for each `ProviderKind`: the SF Symbol fallback, the bundled logo asset,
/// and the sidebar gauge's gradient. Add a case here alongside every new provider file.
extension ProviderKind {
    var symbol: String {
        switch self { case .claude: "sparkles"; case .codex: "hexagon"; case .openCodeGo: "globe.americas.fill"; case .cursor: "cursorarrow.rays"; case .antigravity: "sparkle" }
    }

    var reconnectCommand: String {
        switch self {
        case .claude: "claude auth login"
        case .codex: "codex login"
        case .openCodeGo: "opencode auth login"
        case .cursor: "open -a Cursor"
        case .antigravity: "agy login"
        }
    }

    var logoName: String? {
        switch self { case .claude: "claude-logo"; case .codex: "codex-logo"; case .openCodeGo: "opencode-logo"; case .cursor: "cursor-logo"; case .antigravity: "antigravity-logo" }
    }

    var logo: NSImage? {
        guard let logoName, let url = MetriaResources.bundle.url(forResource: logoName, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    var sidebarProgressGradient: LinearGradient {
        switch self {
        case .claude:
            LinearGradient(colors: [.orange, .orange], startPoint: .leading, endPoint: .trailing)
        case .codex:
            LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .openCodeGo:
            LinearGradient(colors: [.white, .white], startPoint: .leading, endPoint: .trailing)
        case .cursor:
            LinearGradient(colors: [.gray, .white], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .antigravity:
            LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
