# How Lidless works

Lidless keeps a Mac awake only while a coding agent is working. This page is the long version of
the [README](../README.md): how it knows, what it changes on your Mac, and where it stops.

## The loop

1. Each agent calls a tiny executable, `lidless-hook`, from its own hooks: when a session starts, when you submit a prompt, when it uses a tool, when the turn ends.
2. `lidless-hook` records that as one small JSON file per session in `~/Library/Application Support/Lidless/sessions/`.
3. The app watches that folder and decides, every time something changes, whether the Mac needs to stay awake. It only checks on a timer (every 10 seconds) while an agent is working or a timer is running; with nothing going on it does not wake the CPU at all.

While at least one session is working, Lidless holds a `PreventUserIdleSystemSleep` power assertion. That blocks system sleep only: **the display still turns off on its usual schedule.**

The decision is a pure function with a full test suite, and it errs on the side of letting the Mac sleep:

| Rule | Default |
| --- | --- |
| Stay awake a little after the last turn, so back-to-back turns and scripted runs do not race sleep | 2 minutes |
| A session whose process died no longer counts | always |
| A working session that sends no event for a while is treated as idle (agents do not report an interrupted turn) | 30 minutes |
| Hard ceiling on one uninterrupted stretch of wakefulness (a timer you set is its own limit) | 6 hours |
| Stop keeping awake when the battery drops below a level | 20% |
| Only keep awake on the power adapter | off |

## Keep awake for a while

Not everything is an agent. **Keep Awake For** in the menu holds the Mac awake for 15 minutes to 4 hours, until you turn it off, or for a duration you type (`45`, `1h30`, `2:15`, up to 24 hours), whether or not an agent is working.

- The menu shows the time left, and **Show the timer in the menu bar** in Settings puts it next to the icon.
- **Stop** ends it at once. When it ends by itself you get a quiet notification; if an agent is still working, Lidless simply goes on following it.
- **Also with Lid Closed** extends the hold to a closed lid, through the same `pmset` switch as closed-lid mode and under the same guards: battery level, heat, the watchdog. It needs the same one-time setup, and it is never remembered: it unchecks itself when the hold ends, so each lid-closed timer is a choice you make.
- A timer is its own limit, so the awake limit does not cut it short. *Until I Turn It Off* has no end of its own and stays subject to it.

## Connecting agents

Turning an agent on in **Settings** adds Lidless to that agent's hooks:

| Agent | File | Events used |
| --- | --- | --- |
| Claude Code | `~/.claude/settings.json` | `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `SessionEnd` |
| Codex | `~/.codex/hooks.json` | `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop` |
| Gemini CLI | `~/.gemini/settings.json` | `SessionStart`, `BeforeAgent`, `BeforeTool`, `AfterTool`, `AfterAgent`, `SessionEnd` |

Lidless **merges**; it never replaces:

- its entries are appended after yours; your hooks, your other settings and the order of everything stay as they are;
- the file as it was is copied to `<file>.lidless.bak` before Lidless adds anything;
- turning the agent off removes only Lidless's entries. If nothing else changed in the meantime, the file comes back byte for byte; if you edited it since, your edits are kept;
- only the exact commands Lidless wrote count as its own, so a hook of yours that happens to mention `lidless-hook` is never removed;
- a file that is not strict JSON (comments, trailing commas) is left alone, and the settings window says so;
- file permissions are kept, and a symlinked settings file is edited in place.

While an agent is connected its file is written in the standard JSON layout the agents use themselves, so a file you formatted by hand is re-indented until you disconnect.

Two things to know:

- **Codex** asks you to review new hooks the next time it starts. Choose *Trust all and continue*; until then it skips them. Codex's `config.toml` is never modified: hooks go in the separate `hooks.json` it also reads.
- Sessions that were already open when you connected an agent show up at their next event.

The hooks call `~/Library/Application Support/Lidless/bin/lidless-hook`, a copy the app keeps up to date, so they keep working if you move the app.

## What it touches

- **The hooks** make your agents run `lidless-hook` on the events listed above. It reads the session ID and working directory from the hook payload, writes the session file, prints nothing and always exits 0. It does not read your prompts or tool output, and Lidless never uses the network.
- **Session files** hold the agent name, process ID, working directory and timestamps. They stay on your Mac.
- The app is signed ad hoc and not notarized, which is why macOS asks you to confirm its first launch.

Closed-lid mode needs one more thing, a sudoers rule: see [CLOSED-LID.md](CLOSED-LID.md).

## Limits

- An agent turn you interrupt is not reported by the agents. Lidless notices after the silent-agent timeout (30 minutes by default), or immediately if you quit the agent.
- A single tool call that runs longer than that timeout without any other activity looks the same as a stuck session. Raise the timeout, or set it to *Never*, if your runs do that.
- The awake limit also stops legitimate long runs. Raise it if you need more than 6 hours.
- Lidless does not stop sleep you ask for (Apple menu → Sleep), nor sleep forced by macOS (critically low battery, overheating).
- Codex does not announce the end of a session on every version; such sessions disappear when the process exits or after a day idle.

## Building it

```sh
swift build
swift test
./scripts/bundle.sh --native   # quick bundle for this Mac only
```

To try the whole app without touching a real agent configuration, point it at a throwaway home: `LIDLESS_HOME=/tmp/pretend-home LIDLESS_SUPPORT_DIR=/tmp/lidless-support dist/Lidless.app/Contents/MacOS/Lidless`. Add `LIDLESS_DRY_RUN=1` and closed-lid mode goes through every step without running `pmset`.

- `Sources/LidlessCore` — all the logic, no AppKit: the reconciler, session files, the order-preserving JSON merge, the sudoers rule. This is what the tests cover.
- `Sources/Lidless` — the menu bar app (AppKit, SwiftUI for settings).
- `Sources/lidless-hook` — the executable the agents call.

The tests that touch agent configuration run against a temporary home directory. Nothing in the test suite uses `sudo` or `pmset`.

### If `swift build` fails before compiling anything

A Command Line Tools install that was updated in place can keep files from the previous release, which breaks every Swift package with errors like `redefinition of module 'SwiftBridging'` or `Undefined symbols … PackageDescription.Package.__allocating_init`. Without Xcode, `swift test` can also fail with `no such module 'Testing'`.

`./scripts/swiftw` is a drop-in for `swift` that works around all three (`./scripts/swiftw test`); `bundle.sh` already uses it. The real fix is a clean reinstall:

```sh
sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install
```
