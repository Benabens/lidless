import LidlessCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            agentsSection
            stayingAwakeSection
            closedLidSection
            generalSection
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 700)
    }

    // MARK: - Agents

    private var agentsSection: some View {
        Section {
            ForEach(Agent.allCases, id: \.self) { agent in
                agentRow(agent)
            }
        } header: {
            Text("Agents")
        } footer: {
            Text("Turning an agent on adds Lidless to the hooks in its configuration file. Your own hooks are left as they are, and the original file is backed up next to it.")
        }
    }

    @ViewBuilder
    private func agentRow(_ agent: Agent) -> some View {
        let status = model.integrationStatus[agent] ?? .agentNotFound
        Toggle(isOn: Binding(get: { status.isConnected }, set: { model.setIntegration(agent, enabled: $0) })) {
            Text(agent.displayName)
            Text(caption(for: agent, status: status))
        }
        .disabled(status == .agentNotFound || status == .unreadable)

        if status == .outdated {
            LabeledContent("Its hooks point to an older copy of Lidless.") {
                Button("Update") { model.setIntegration(agent, enabled: true) }
            }
        }
        if agent == .codex, status.isConnected {
            note(model.codexHasInlineHooks
                ? "Codex asks you to review new hooks the next time it starts. It will also warn that hooks come from both hooks.json and config.toml."
                : "Codex asks you to review new hooks the next time it starts. Choose “Trust all and continue”.")
        }
        if let error = model.integrationErrors[agent] {
            problem(error)
        }
    }

    private func caption(for agent: Agent, status: AgentIntegration.Status) -> String {
        let file = (AgentIntegration(agent: agent).configFile.path as NSString).abbreviatingWithTildeInPath
        switch status {
        case .agentNotFound: return "Not found on this Mac"
        case .notInstalled: return "Not connected"
        case .installed, .outdated: return "Connected through \(file)"
        case .unreadable: return "\(file) is not plain JSON, so Lidless will not edit it"
        }
    }

    // MARK: - Staying awake

    private var stayingAwakeSection: some View {
        Section {
            Picker("Stay awake after the last turn", selection: $model.settings.gracePeriod) {
                Text("Not at all").tag(TimeInterval(0))
                Text("30 seconds").tag(TimeInterval(30))
                Text("1 minute").tag(TimeInterval(60))
                Text("2 minutes").tag(TimeInterval(120))
                Text("5 minutes").tag(TimeInterval(300))
                Text("10 minutes").tag(TimeInterval(600))
                Text("15 minutes").tag(TimeInterval(900))
            }
            Toggle("Only on power adapter", isOn: $model.settings.acOnly)
            Picker("Stop below battery level", selection: $model.settings.batteryFloor) {
                Text("Never").tag(0)
                ForEach([10, 20, 30, 40, 50], id: \.self) { percent in
                    Text("\(percent)%").tag(percent)
                }
            }
            Picker("Give up on a silent agent after", selection: $model.settings.stallTimeout) {
                Text("15 minutes").tag(TimeInterval(15 * 60))
                Text("30 minutes").tag(TimeInterval(30 * 60))
                Text("1 hour").tag(TimeInterval(3600))
                Text("2 hours").tag(TimeInterval(2 * 3600))
                Text("Never").tag(TimeInterval(0))
            }
            Picker("Never stay awake longer than", selection: $model.settings.maxAwakeDuration) {
                ForEach([1, 2, 4, 6, 8, 12, 24], id: \.self) { hours in
                    Text(hours == 1 ? "1 hour" : "\(hours) hours").tag(TimeInterval(hours * 3600))
                }
            }
        } header: {
            Text("Staying Awake")
        } footer: {
            Text("Lidless only blocks system sleep. The display still turns off on its usual schedule.")
        }
    }

    // MARK: - Closed-lid mode

    private var closedLidSection: some View {
        Section {
            LabeledContent {
                Button(model.sudoersRuleInstalled ? "Remove…" : "Install…") {
                    if model.sudoersRuleInstalled {
                        model.removeSudoersRule()
                    } else {
                        model.installSudoersRule()
                    }
                }
                .disabled(model.sudoersRuleBusy)
            } label: {
                Text("Password-free sleep switch")
                Text(model.sudoersRuleInstalled
                    ? "Installed at /etc/sudoers.d/lidless"
                    : "Needed before closed-lid mode can be armed")
            }
            if let error = model.sudoersRuleError {
                problem(error)
            }
        } header: {
            Text("Closed-Lid Mode")
        } footer: {
            Text("While armed, Lidless turns system sleep off as long as agents work on power, then back on. That needs administrator rights, so the rule lets your account run two commands without a password: “pmset -a disablesleep 1” and “pmset -a disablesleep 0”. Nothing else.")
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section {
            Toggle("Open at login", isOn: Binding(
                get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }
            ))
            if let error = model.loginItemError {
                problem(error)
            }
        } header: {
            Text("General")
        } footer: {
            Text("Lidless \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build")")
        }
    }

    // MARK: - Pieces

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Something went wrong, said where it happened.
    private func problem(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
