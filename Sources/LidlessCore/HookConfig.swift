import Foundation

/// Which native hook events Lidless registers for an agent, and what each one means.
public struct AgentHookSpec: Sendable {
    public struct Binding: Equatable, Sendable {
        /// The event name in the agent's own configuration.
        public var nativeEvent: String
        public var event: HookEvent
        /// In the agent's own unit; `nil` leaves the agent's default.
        public var timeout: Int?
    }

    public var agent: Agent
    public var bindings: [Binding]
    /// Shown by agents that list hooks by name.
    public var hookName: String?

    // Claude Code, Codex and Gemini CLI share one configuration shape:
    //   { "hooks": { "<Event>": [ { "matcher": …, "hooks": [ { "type": "command", … } ] } ] } }
    public static func spec(for agent: Agent) -> AgentHookSpec {
        switch agent {
        case .claude:
            // Timeouts are in seconds. SessionEnd gets none: Claude Code stretches the exit budget
            // of *all* SessionEnd hooks to the longest timeout it finds.
            AgentHookSpec(agent: agent, bindings: [
                Binding(nativeEvent: "SessionStart", event: .start, timeout: 5),
                Binding(nativeEvent: "UserPromptSubmit", event: .prompt, timeout: 5),
                Binding(nativeEvent: "PreToolUse", event: .activity, timeout: 5),
                Binding(nativeEvent: "PostToolUse", event: .activity, timeout: 5),
                Binding(nativeEvent: "Stop", event: .stop, timeout: 5),
                Binding(nativeEvent: "SessionEnd", event: .end, timeout: nil),
            ], hookName: nil)
        case .codex:
            // Seconds. Newer releases add SessionEnd and Interrupt, but an unknown event name is a
            // risk on the ones that do not; a dead process ends the session just as well.
            AgentHookSpec(agent: agent, bindings: [
                Binding(nativeEvent: "SessionStart", event: .start, timeout: 5),
                Binding(nativeEvent: "UserPromptSubmit", event: .prompt, timeout: 5),
                Binding(nativeEvent: "PreToolUse", event: .activity, timeout: 5),
                Binding(nativeEvent: "PostToolUse", event: .activity, timeout: 5),
                Binding(nativeEvent: "Stop", event: .stop, timeout: 5),
            ], hookName: nil)
        case .gemini:
            // Milliseconds.
            AgentHookSpec(agent: agent, bindings: [
                Binding(nativeEvent: "SessionStart", event: .start, timeout: 5000),
                Binding(nativeEvent: "BeforeAgent", event: .prompt, timeout: 5000),
                Binding(nativeEvent: "BeforeTool", event: .activity, timeout: 5000),
                Binding(nativeEvent: "AfterTool", event: .activity, timeout: 5000),
                Binding(nativeEvent: "AfterAgent", event: .stop, timeout: 5000),
                Binding(nativeEvent: "SessionEnd", event: .end, timeout: 5000),
            ], hookName: "lidless")
        }
    }
}

public enum HookConfigError: Error, Equatable, CustomStringConvertible {
    /// The file is not strict JSON (comments, trailing commas, syntax errors…).
    case unparseable(String)
    /// Valid JSON, but not laid out the way hook configurations are.
    case unexpectedShape(String)

    public var description: String {
        switch self {
        case let .unparseable(detail): "The file is not valid JSON (\(detail))."
        case let .unexpectedShape(detail): "The file has an unexpected structure: \(detail)."
        }
    }
}

/// Adds Lidless's hooks to an agent's configuration text, and takes them out again.
/// Existing hooks are never replaced, reordered or removed.
public enum HookConfig {
    public enum State: Equatable, Sendable {
        case notInstalled
        /// Lidless entries exist but are not the ones this version would write.
        case outdated
        case installed
        case unreadable
    }

    static let executableName = "lidless-hook"

    /// The configuration with Lidless's hooks added, replacing any earlier Lidless entries.
    /// `text` is `nil` or blank when the file does not exist yet.
    public static func installing(_ spec: AgentHookSpec, hookPath: String, into text: String?) throws -> String {
        var document = try parse(text) ?? JSONDocument(root: .object(JSONObject()))
        var root = try rootObject(of: document)
        var hooks = try stripping(hooksSection(of: root)).hooks

        for binding in spec.bindings {
            guard case let .array(groups) = hooks[binding.nativeEvent] ?? .array([]) else {
                throw HookConfigError.unexpectedShape("\"hooks.\(binding.nativeEvent)\" is not an array")
            }
            let handler = handler(for: binding, spec: spec, hookPath: hookPath)
            let group = JSONValue.object(JSONObject(["hooks": .array([handler])]))
            hooks[binding.nativeEvent] = .array(groups + [group])
        }

        root["hooks"] = .object(hooks)
        document.root = .object(root)
        return document.text
    }

    /// The configuration without any Lidless hook. Returns the text untouched when there is
    /// nothing to remove, and `nil` when nothing but Lidless was in the file.
    public static func uninstalling(from text: String) throws -> String? {
        guard var document = try parse(text) else { return text }
        var root = try rootObject(of: document)
        let (hooks, removedAny) = try stripping(hooksSection(of: root))
        guard removedAny else { return text }

        root["hooks"] = hooks.isEmpty ? nil : .object(hooks)
        guard !root.isEmpty else { return nil }
        document.root = .object(root)
        return document.text
    }

    /// `false` for a file Lidless cannot read: it has nothing of ours that we could remove.
    public static func containsLidlessHooks(in text: String) -> Bool {
        do {
            return try uninstalling(from: text) != text
        } catch {
            return false
        }
    }

    public static func state(of spec: AgentHookSpec, hookPath: String, in text: String?) -> State {
        let current: JSONDocument?
        do {
            current = try parse(text)
            guard let current, let text else { return .notInstalled }
            let expected = try JSONDocument(text: installing(spec, hookPath: hookPath, into: text))
            if expected.root == current.root { return .installed }
            return try stripping(hooksSection(of: rootObject(of: current))).removedAny ? .outdated : .notInstalled
        } catch {
            return .unreadable
        }
    }

    // MARK: - Pieces

    private static func parse(_ text: String?) throws -> JSONDocument? {
        guard let text, !text.allSatisfy(\.isWhitespace) else { return nil }
        do {
            return try JSONDocument(text: text)
        } catch let error as JSONParseError {
            throw HookConfigError.unparseable(error.description)
        }
    }

    private static func rootObject(of document: JSONDocument) throws -> JSONObject {
        guard case let .object(root) = document.root else {
            throw HookConfigError.unexpectedShape("the top level is not an object")
        }
        return root
    }

    private static func hooksSection(of root: JSONObject) throws -> JSONObject {
        switch root["hooks"] {
        case nil: return JSONObject()
        case let .object(hooks)?: return hooks
        default: throw HookConfigError.unexpectedShape("\"hooks\" is not an object")
        }
    }

    /// `hooks` minus every Lidless handler. Groups and events are dropped only when removing
    /// Lidless left them empty; whatever the user wrote stays, in its place.
    private static func stripping(_ hooks: JSONObject) throws -> (hooks: JSONObject, removedAny: Bool) {
        var result = hooks
        var removedAny = false

        for member in hooks.members {
            guard case let .array(groups) = member.value else {
                throw HookConfigError.unexpectedShape("\"hooks.\(member.key)\" is not an array")
            }
            var keptGroups: [JSONValue] = []
            var touched = false
            for group in groups {
                guard case var .object(fields) = group else {
                    throw HookConfigError.unexpectedShape("\"hooks.\(member.key)\" contains something that is not an object")
                }
                guard let handlersValue = fields["hooks"] else {
                    keptGroups.append(group)
                    continue
                }
                guard case let .array(handlers) = handlersValue else {
                    throw HookConfigError.unexpectedShape("a \"hooks\" list under \"\(member.key)\" is not an array")
                }
                let kept = handlers.filter { !isLidless($0) }
                if kept.count == handlers.count {
                    keptGroups.append(group)
                    continue
                }
                touched = true
                if !kept.isEmpty {
                    fields["hooks"] = .array(kept)
                    keptGroups.append(.object(fields))
                }
            }
            if touched {
                removedAny = true
                result[member.key] = keptGroups.isEmpty ? nil : .array(keptGroups)
            }
        }
        return (result, removedAny)
    }

    private static func isLidless(_ handler: JSONValue) -> Bool {
        guard case let .object(fields) = handler, case let .string(command)? = fields["command"] else {
            return false
        }
        return isLidlessCommand(command)
    }

    /// Whether `command` has exactly the shape `handler(for:)` writes: a quoted path to the
    /// executable, an agent, an event. A hook of the user's that merely mentions Lidless is theirs.
    static func isLidlessCommand(_ command: String) -> Bool {
        let words = command.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count >= 3,
              Agent(rawValue: String(words[words.count - 2])) != nil,
              HookEvent(rawValue: String(words[words.count - 1])) != nil
        else { return false }
        let path = words.dropLast(2).joined(separator: " ")
        return path.hasPrefix("'") && path.hasSuffix("/\(executableName)'")
    }

    private static func handler(for binding: AgentHookSpec.Binding, spec: AgentHookSpec, hookPath: String) -> JSONValue {
        var fields = JSONObject()
        if let name = spec.hookName { fields["name"] = .string(name) }
        fields["type"] = .string("command")
        // Agents hand the command to a shell, and the path contains a space.
        fields["command"] = .string("\(hookPath.shellQuoted) \(spec.agent.rawValue) \(binding.event.rawValue)")
        if let timeout = binding.timeout { fields["timeout"] = .number(String(timeout)) }
        return .object(fields)
    }
}
