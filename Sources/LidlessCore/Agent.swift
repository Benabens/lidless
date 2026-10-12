/// A coding agent whose sessions Lidless can follow.
public enum Agent: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case gemini

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        }
    }
}
