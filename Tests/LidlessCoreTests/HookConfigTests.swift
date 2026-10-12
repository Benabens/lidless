import Foundation
import Testing
import LidlessCore

private let hookPath = "/Users/me/Library/Application Support/Lidless/bin/lidless-hook"

/// Shaped like a real, busy Claude Code settings file.
private let busyClaudeSettings = """
{
  "attribution": {
    "commit": "",
    "pr": ""
  },
  "model": "opus",
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/notify-start.sh"
          },
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/obs-send.sh UserPromptSubmit"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/notify-done.sh"
          },
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/obs-send.sh Stop"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/obs-send.sh PreToolUse",
            "timeout": 10
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/obs-send.sh Notification"
          }
        ]
      }
    ]
  },
  "theme": "dark"
}

"""

/// Every hook command in the file, per event, in order.
private func commands(in text: String) throws -> [String: [String]] {
    guard case let .object(root) = try JSONDocument(text: text).root,
          case let .object(hooks)? = root["hooks"]
    else { return [:] }
    var result: [String: [String]] = [:]
    for member in hooks.members {
        guard case let .array(groups) = member.value else { continue }
        for case let .object(group) in groups {
            guard case let .array(handlers)? = group["hooks"] else { continue }
            for case let .object(handler) in handlers {
                if case let .string(command)? = handler["command"] {
                    result[member.key, default: []].append(command)
                }
            }
        }
    }
    return result
}

@Suite("Merging Lidless into an agent's hook configuration")
struct HookConfigTests {
    let claude = AgentHookSpec.spec(for: .claude)

    @Test func addsItsHooksAfterTheExistingOnesAndTouchesNothingElse() throws {
        let installed = try HookConfig.installing(claude, hookPath: hookPath, into: busyClaudeSettings)
        let after = try commands(in: installed)

        #expect(after["UserPromptSubmit"] == [
            "bash ~/.claude/hooks/notify-start.sh",
            "bash ~/.claude/hooks/obs-send.sh UserPromptSubmit",
            "'\(hookPath)' claude prompt",
        ])
        #expect(after["Stop"] == [
            "bash ~/.claude/hooks/notify-done.sh",
            "bash ~/.claude/hooks/obs-send.sh Stop",
            "'\(hookPath)' claude stop",
        ])
        #expect(after["PreToolUse"] == [
            "bash ~/.claude/hooks/obs-send.sh PreToolUse",
            "'\(hookPath)' claude activity",
        ])
        #expect(after["PostToolUse"] == ["'\(hookPath)' claude activity"])
        #expect(after["SessionStart"] == ["'\(hookPath)' claude start"])
        #expect(after["SessionEnd"] == ["'\(hookPath)' claude end"])
        #expect(after["Notification"] == ["bash ~/.claude/hooks/obs-send.sh Notification"])
    }

    @Test func leavesTheRestOfTheFileExactlyAsItWas() throws {
        let installed = try HookConfig.installing(claude, hookPath: hookPath, into: busyClaudeSettings)

        // Everything outside the hooks section is untouched, in the same order.
        let beforeTheFirstHook = busyClaudeSettings.components(separatedBy: "\"UserPromptSubmit\"")[0]
        #expect(installed.hasPrefix(beforeTheFirstHook))
        #expect(installed.hasSuffix("  \"theme\": \"dark\"\n}\n"))
        // The user's matcher and timeout on their own hook survive.
        #expect(installed.contains("\"matcher\": \"Bash\""))
        #expect(installed.contains("\"timeout\": 10"))
    }

    @Test func uninstallingGivesBackTheOriginalFileByteForByte() throws {
        let installed = try HookConfig.installing(claude, hookPath: hookPath, into: busyClaudeSettings)
        #expect(installed != busyClaudeSettings)
        #expect(try HookConfig.uninstalling(from: installed) == busyClaudeSettings)
    }

    @Test func installingTwiceIsTheSameAsInstallingOnce() throws {
        let once = try HookConfig.installing(claude, hookPath: hookPath, into: busyClaudeSettings)
        let twice = try HookConfig.installing(claude, hookPath: hookPath, into: once)
        #expect(twice == once)
    }

    @Test func reinstallingFromANewLocationReplacesTheOldEntries() throws {
        let old = try HookConfig.installing(claude, hookPath: "/old/place/lidless-hook", into: busyClaudeSettings)
        let moved = try HookConfig.installing(claude, hookPath: hookPath, into: old)

        #expect(!moved.contains("/old/place"))
        #expect(moved == (try HookConfig.installing(claude, hookPath: hookPath, into: busyClaudeSettings)))
    }

    @Test func createsTheHooksSectionWhenTheFileHasNone() throws {
        let original = "{\n  \"model\": \"opus\"\n}\n"
        let installed = try HookConfig.installing(claude, hookPath: hookPath, into: original)

        #expect(installed.hasPrefix("{\n  \"model\": \"opus\",\n  \"hooks\": {"))
        #expect(try commands(in: installed).count == claude.bindings.count)
        #expect(try HookConfig.uninstalling(from: installed) == original)
    }

    @Test func startsANewFileWhenThereIsNone() throws {
        for missing in [nil, "", "  \n"] as [String?] {
            let installed = try HookConfig.installing(claude, hookPath: hookPath, into: missing)
            #expect(try commands(in: installed)["Stop"] == ["'\(hookPath)' claude stop"])
            // Nothing but Lidless in there: uninstalling leaves nothing worth keeping.
            #expect(try HookConfig.uninstalling(from: installed) == nil)
        }
    }

    @Test func onlyRemovesItsOwnHandlerFromAGroupItSharesWithTheUser() throws {
        let shared = """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "say done"
                  },
                  {
                    "type": "command",
                    "command": "'/somewhere/lidless-hook' claude stop"
                  }
                ]
              }
            ]
          }
        }
        """
        let cleaned = try #require(try HookConfig.uninstalling(from: shared))
        #expect(try commands(in: cleaned) == ["Stop": ["say done"]])
    }

    @Test func uninstallingAFileWithoutLidlessChangesNothing() throws {
        #expect(try HookConfig.uninstalling(from: busyClaudeSettings) == busyClaudeSettings)
    }

    @Test(arguments: [
        "{ // comments are not JSON\n  \"hooks\": {}\n}",
        "[1, 2, 3]",
        #"{"hooks": "nope"}"#,
        #"{"hooks": {"Stop": {"hooks": []}}}"#,
        #"{"hooks": {"Stop": ["not a group"]}}"#,
        #"{"hooks": {"Stop": [{"hooks": "nope"}]}}"#,
    ])
    func refusesToEditAFileItDoesNotFullyUnderstand(text: String) {
        #expect(throws: HookConfigError.self) {
            try HookConfig.installing(claude, hookPath: hookPath, into: text)
        }
        #expect(throws: HookConfigError.self) {
            try HookConfig.uninstalling(from: text)
        }
    }

    @Test func aHookPathWithAnApostropheIsStillOneShellWord() throws {
        let installed = try HookConfig.installing(claude, hookPath: "/Users/o'neil/bin/lidless-hook", into: nil)
        #expect(try commands(in: installed)["Stop"] == [#"'/Users/o'\''neil/bin/lidless-hook' claude stop"#])
    }

    @Test func knowsWhetherAFileIsUpToDate() throws {
        let installed = try HookConfig.installing(claude, hookPath: hookPath, into: busyClaudeSettings)
        #expect(HookConfig.state(of: claude, hookPath: hookPath, in: installed) == .installed)
        #expect(HookConfig.state(of: claude, hookPath: hookPath, in: busyClaudeSettings) == .notInstalled)
        #expect(HookConfig.state(of: claude, hookPath: hookPath, in: nil) == .notInstalled)
        #expect(HookConfig.state(of: claude, hookPath: "/moved/lidless-hook", in: installed) == .outdated)

        // The user deleted one of the entries by hand.
        let partial = installed.replacingOccurrences(of: "claude stop", with: "claude prompt")
        #expect(HookConfig.state(of: claude, hookPath: hookPath, in: partial) == .outdated)
        #expect(HookConfig.state(of: claude, hookPath: hookPath, in: "{ broken") == .unreadable)
    }
}

@Suite("What Lidless asks each agent to call")
struct AgentHookSpecTests {
    private func events(_ agent: Agent) -> [String] {
        AgentHookSpec.spec(for: agent).bindings.map { "\($0.nativeEvent)=\($0.event.rawValue)" }
    }

    @Test func claudeCode() throws {
        #expect(events(.claude) == [
            "SessionStart=start", "UserPromptSubmit=prompt", "PreToolUse=activity",
            "PostToolUse=activity", "Stop=stop", "SessionEnd=end",
        ])
        let installed = try HookConfig.installing(.spec(for: .claude), hookPath: "/bin/lidless-hook", into: nil)
        #expect(installed.contains("""
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "'/bin/lidless-hook' claude stop",
                    "timeout": 5
                  }
                ]
              }
            ]
        """))
        // Claude Code stretches its whole exit budget to the longest SessionEnd timeout: set none.
        #expect(installed.contains("""
                    "command": "'/bin/lidless-hook' claude end"
                  }
        """))
    }

    @Test func codexOnlyUsesEventsEveryRecentVersionKnows() {
        #expect(events(.codex) == [
            "SessionStart=start", "UserPromptSubmit=prompt", "PreToolUse=activity",
            "PostToolUse=activity", "Stop=stop",
        ])
    }

    @Test func geminiUsesItsOwnEventNamesMillisecondsAndANamedHook() throws {
        #expect(events(.gemini) == [
            "SessionStart=start", "BeforeAgent=prompt", "BeforeTool=activity",
            "AfterTool=activity", "AfterAgent=stop", "SessionEnd=end",
        ])
        let installed = try HookConfig.installing(.spec(for: .gemini), hookPath: "/bin/lidless-hook", into: nil)
        #expect(installed.contains("""
                  {
                    "name": "lidless",
                    "type": "command",
                    "command": "'/bin/lidless-hook' gemini prompt",
                    "timeout": 5000
                  }
        """))
    }
}
