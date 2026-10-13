import Foundation
import Testing
import LidlessCore

private let hookPath = "/Users/me/Library/Application Support/Lidless/bin/lidless-hook"

private let claudeSettings = """
{
  "model": "opus",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/notify-done.sh"
          }
        ]
      }
    ]
  }
}

"""

@Suite("Installing into a home directory")
struct AgentIntegrationTests {
    /// A pretend home directory: the real agent configurations are never touched.
    let home: TemporaryDirectory

    init() throws {
        home = try TemporaryDirectory()
    }

    private func integration(_ agent: Agent) -> AgentIntegration {
        AgentIntegration(agent: agent, home: home.url)
    }

    private func mode(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: home.file(path).path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    @Test func eachAgentHasItsOwnConfigurationFile() {
        #expect(integration(.claude).configFile.path == home.file(".claude/settings.json").path)
        #expect(integration(.codex).configFile.path == home.file(".codex/hooks.json").path)
        #expect(integration(.gemini).configFile.path == home.file(".gemini/settings.json").path)
    }

    @Test func anAgentThatIsNotInstalledIsLeftAlone() throws {
        #expect(integration(.gemini).status(hookPath: hookPath) == .agentNotFound)
        #expect(throws: AgentIntegrationError.agentNotFound(.gemini)) {
            try integration(.gemini).install(hookPath: hookPath)
        }
        #expect(!home.exists(".gemini"))
    }

    @Test func installsIntoAnExistingFileAndKeepsABackupOfTheOriginal() throws {
        try home.write(claudeSettings, to: ".claude/settings.json")
        let claude = integration(.claude)
        #expect(claude.status(hookPath: hookPath) == .notInstalled)

        try claude.install(hookPath: hookPath)

        #expect(claude.status(hookPath: hookPath) == .installed)
        let installed = try home.read(".claude/settings.json")
        #expect(installed.contains("bash ~/.claude/hooks/notify-done.sh"))
        #expect(installed.contains("lidless-hook' claude stop"))
        #expect(try home.read(".claude/settings.json.lidless.bak") == claudeSettings)
    }

    @Test func uninstallRestoresTheOriginalFile() throws {
        try home.write(claudeSettings, to: ".claude/settings.json")
        try integration(.claude).install(hookPath: hookPath)

        try integration(.claude).uninstall()

        #expect(try home.read(".claude/settings.json") == claudeSettings)
        #expect(integration(.claude).status(hookPath: hookPath) == .notInstalled)
    }

    @Test func aHandFormattedFileComesBackExactlyAsItWas() throws {
        // Installing re-indents a file like this one; uninstalling must not leave it that way.
        let handWritten = "{\"model\":\"opus\",   \"permissions\": {\"allow\": [\"Bash(ls:*)\", \"Read\"]},\n\t\"hooks\": {}\n}"
        try home.write(handWritten, to: ".claude/settings.json")
        let claude = integration(.claude)

        try claude.install(hookPath: hookPath)
        #expect(claude.status(hookPath: hookPath) == .installed)
        try claude.uninstall()

        #expect(try home.read(".claude/settings.json") == handWritten)
    }

    @Test func aFileThatWasAlreadyThereIsNeverDeleted() throws {
        try home.write("{}\n", to: ".gemini/settings.json")

        try integration(.gemini).install(hookPath: hookPath)
        try integration(.gemini).uninstall()

        #expect(try home.read(".gemini/settings.json") == "{}\n")
    }

    @Test func editsMadeWhileLidlessWasConnectedAreKept() throws {
        try home.write(claudeSettings, to: ".claude/settings.json")
        let claude = integration(.claude)
        try claude.install(hookPath: hookPath)
        let edited = try home.read(".claude/settings.json").replacingOccurrences(of: "\"opus\"", with: "\"sonnet\"")
        try home.write(edited, to: ".claude/settings.json")

        try claude.uninstall()

        #expect(try home.read(".claude/settings.json") == claudeSettings.replacingOccurrences(of: "\"opus\"", with: "\"sonnet\""))
    }

    @Test func connectedMeansLidlessHooksArePresentEvenIfOutdated() {
        #expect(AgentIntegration.Status.installed.isConnected)
        #expect(AgentIntegration.Status.outdated.isConnected)
        #expect(!AgentIntegration.Status.notInstalled.isConnected)
        #expect(!AgentIntegration.Status.agentNotFound.isConnected)
        #expect(!AgentIntegration.Status.unreadable.isConnected)
    }

    @Test func theBackupIsAlwaysTheLastStateBeforeLidless() throws {
        try home.write(claudeSettings, to: ".claude/settings.json")
        let claude = integration(.claude)
        try claude.install(hookPath: "/old/lidless-hook")
        // Reinstalling over a file that already has Lidless in it must not clobber the backup.
        try claude.install(hookPath: hookPath)
        #expect(try home.read(".claude/settings.json.lidless.bak") == claudeSettings)

        // After an uninstall the user edits the file; the next install backs up that version.
        try claude.uninstall()
        let edited = claudeSettings.replacingOccurrences(of: "opus", with: "sonnet")
        try home.write(edited, to: ".claude/settings.json")
        try claude.install(hookPath: hookPath)
        #expect(try home.read(".claude/settings.json.lidless.bak") == edited)
    }

    @Test func reinstallingWhenUpToDateDoesNotRewriteTheFile() throws {
        try home.write(claudeSettings, to: ".claude/settings.json")
        let claude = integration(.claude)
        try claude.install(hookPath: hookPath)
        let before = try FileManager.default.attributesOfItem(atPath: claude.configFile.path)[.modificationDate] as? Date

        try claude.install(hookPath: hookPath)

        let after = try FileManager.default.attributesOfItem(atPath: claude.configFile.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test func keepsTheFilePermissionsBecauseSettingsCanHoldSecrets() throws {
        try home.write(claudeSettings, to: ".claude/settings.json", mode: 0o600)

        try integration(.claude).install(hookPath: hookPath)

        #expect(try mode(of: ".claude/settings.json") == 0o600)
        #expect(try mode(of: ".claude/settings.json.lidless.bak") == 0o600)
    }

    @Test func writesThroughASymlinkInsteadOfReplacingIt() throws {
        // Dotfile managers symlink settings into a repository.
        try home.write(claudeSettings, to: "dotfiles/claude-settings.json")
        try FileManager.default.createDirectory(at: home.file(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.file(".claude/settings.json"), withDestinationURL: home.file("dotfiles/claude-settings.json")
        )

        try integration(.claude).install(hookPath: hookPath)

        let link = try FileManager.default.destinationOfSymbolicLink(atPath: home.file(".claude/settings.json").path)
        #expect(link.hasSuffix("dotfiles/claude-settings.json"))
        #expect(try home.read("dotfiles/claude-settings.json").contains("lidless-hook"))
    }

    @Test func aFileItCannotParseIsNeverModified() throws {
        let withComments = "{\n  // my notes\n  \"model\": \"opus\"\n}\n"
        try home.write(withComments, to: ".claude/settings.json")
        let claude = integration(.claude)

        #expect(claude.status(hookPath: hookPath) == .unreadable)
        #expect(throws: HookConfigError.self) {
            try claude.install(hookPath: hookPath)
        }
        #expect(try home.read(".claude/settings.json") == withComments)
        #expect(!home.exists(".claude/settings.json.lidless.bak"))
    }

    @Test func codexGetsADedicatedHooksFileThatGoesAwayOnUninstall() throws {
        // Codex reads hooks from ~/.codex/hooks.json next to config.toml, which stays untouched.
        let config = "model = \"gpt-5\"\nnotify = [\"/usr/local/bin/my-notifier\"]\n\n[features]\nfoo = true\n"
        try home.write(config, to: ".codex/config.toml")
        let codex = integration(.codex)
        #expect(codex.status(hookPath: hookPath) == .notInstalled)

        try codex.install(hookPath: hookPath)
        #expect(codex.status(hookPath: hookPath) == .installed)
        #expect(try home.read(".codex/hooks.json").contains("lidless-hook' codex prompt"))
        #expect(!home.exists(".codex/hooks.json.lidless.bak"))

        try codex.uninstall()
        #expect(!home.exists(".codex/hooks.json"))
        #expect(try home.read(".codex/config.toml") == config)
    }

    @Test func mergesIntoAnExistingCodexHooksFile() throws {
        let existing = """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "afplay /System/Library/Sounds/Glass.aiff"
                  }
                ]
              }
            ]
          }
        }

        """
        try home.write(existing, to: ".codex/hooks.json")

        try integration(.codex).install(hookPath: hookPath)
        #expect(try home.read(".codex/hooks.json").contains("afplay"))

        try integration(.codex).uninstall()
        #expect(try home.read(".codex/hooks.json") == existing)
    }

    @Test func warnsWhenCodexAlsoHasHooksInItsTOMLConfig() throws {
        try home.write("model = \"gpt-5\"\n", to: ".codex/config.toml")
        #expect(integration(.codex).hasInlineCodexHooks == false)

        try home.write("model = \"gpt-5\"\n\n[[hooks.Stop]]\n\n[[hooks.Stop.hooks]]\ntype = \"command\"\n", to: ".codex/config.toml")
        #expect(integration(.codex).hasInlineCodexHooks == true)
        #expect(integration(.claude).hasInlineCodexHooks == false)
    }

    @Test func geminiSettingsAreCreatedWhenMissingAndRemovedWhenOnlyLidlessWasThere() throws {
        try FileManager.default.createDirectory(at: home.file(".gemini"), withIntermediateDirectories: true)
        let gemini = integration(.gemini)

        try gemini.install(hookPath: hookPath)
        #expect(try home.read(".gemini/settings.json").contains("lidless-hook' gemini stop"))

        try gemini.uninstall()
        #expect(!home.exists(".gemini/settings.json"))
    }

    @Test func removesItsOwnFileEvenWhenTheHomePathIsNotCanonical() throws {
        // /var and /tmp are symlinks into /private on macOS; both spellings reach the same file.
        let canonical = home.url.resolvingSymlinksInPath().path
        let viaPrivate = URL(fileURLWithPath: canonical.hasPrefix("/private") ? canonical : "/private" + canonical)
        try FileManager.default.createDirectory(at: home.file(".codex"), withIntermediateDirectories: true)
        let codex = AgentIntegration(agent: .codex, home: viaPrivate)

        try codex.install(hookPath: hookPath)
        try codex.uninstall()

        #expect(!home.exists(".codex/hooks.json"))
    }

    @Test func aSymlinkedFileComesBackAsItWasAndStaysALink() throws {
        try home.write("", to: "dotfiles/gemini-settings.json")
        try FileManager.default.createDirectory(at: home.file(".gemini"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.file(".gemini/settings.json"), withDestinationURL: home.file("dotfiles/gemini-settings.json")
        )

        try integration(.gemini).install(hookPath: hookPath)
        try integration(.gemini).uninstall()

        #expect(try home.read("dotfiles/gemini-settings.json") == "")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: home.file(".gemini/settings.json").path)) != nil)
    }

    @Test func aSymlinkToAFileLidlessHadToCreateIsEmptiedNotBroken() throws {
        // The link points into a dotfiles folder where the file does not exist yet.
        try FileManager.default.createDirectory(at: home.file("dotfiles"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.file(".gemini"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.file(".gemini/settings.json"), withDestinationURL: home.file("dotfiles/gemini-settings.json")
        )

        try integration(.gemini).install(hookPath: hookPath)
        #expect(try home.read("dotfiles/gemini-settings.json").contains("lidless-hook"))
        try integration(.gemini).uninstall()

        #expect(try home.read("dotfiles/gemini-settings.json") == "{}\n")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: home.file(".gemini/settings.json").path)) != nil)
    }

    @Test func uninstallingWhereNothingIsInstalledDoesNothing() throws {
        try home.write(claudeSettings, to: ".claude/settings.json")
        try integration(.claude).uninstall()
        try integration(.gemini).uninstall()

        #expect(try home.read(".claude/settings.json") == claudeSettings)
        #expect(!home.exists(".gemini"))
    }
}
