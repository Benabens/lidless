# Lidless

A macOS menu bar app that keeps your Mac awake **only while a coding agent is working** — Claude Code, Codex or Gemini CLI — and lets it sleep normally the moment they are done. It can also keep them working with the lid closed, plugged in or not.

Start a long agent run, close the lid, put the Mac in your bag. When the last agent finishes, the Mac goes back to sleeping as usual. No timer to guess, nothing to remember to turn off.

## How it works

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

## Requirements

- macOS 13 or later, Apple Silicon or Intel.
- To build: the Xcode Command Line Tools (`xcode-select --install`). Xcode itself is not needed.

## Install

There is no prebuilt download yet. Build it:

```sh
git clone https://github.com/Benabens/lidless.git
cd lidless
./scripts/bundle.sh        # builds dist/Lidless.app (universal, signed ad hoc)
./scripts/install-dev.sh   # copies it to /Applications and opens it
```

On first launch the settings window opens. Turn on the agents you use, and that is it.

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

## Closed-lid mode

Closing the lid normally puts a Mac to sleep whatever is running. Closed-lid mode is a switch **you** arm from the menu. It works on the power adapter and on battery: unplugging changes nothing.

While it is armed and at least one agent is working, Lidless runs `pmset -a disablesleep 1` and the Mac keeps working with the lid closed. It runs `pmset -a disablesleep 0` and disarms itself as soon as any of these is true:

- every agent has finished, after the grace period (an agent that went silent counts as finished);
- the battery drops below the level you set (20% by default), plugged in or not;
- the Mac gets hot: macOS reports *serious* or *critical* thermal pressure;
- the awake limit is reached (6 hours by default).

When one of the last three cuts a run short, a notification tells you why once you open the Mac. If you never want the Mac awake on battery, turn on **Only on power adapter** in Settings: unplugging then disarms closed-lid mode too.

**Heat.** A closed Mac sheds heat less well, and a bag traps what it sheds. Agents mostly wait on the network, so the load is usually light, but builds and test suites running locally are not. Use a bag or sleeve with some air around the Mac, not a tightly packed pocket, and never leave it running under a duvet or a cushion. The thermal rule above is a backstop, not a reason to skip this.

Lidless also puts the setting back when it launches and when it quits, and a small watchdog does it if the app is killed, crashes or freezes. It only ever undoes its own change: if `disablesleep` was already on when you armed the mode, Lidless leaves it alone.

### The sudoers rule

`pmset disablesleep` needs administrator rights, and Lidless must be able to turn it back **off** without waiting for a password. So closed-lid mode needs a one-time setup, from **Settings → Closed-Lid Mode → Install…**. After the standard macOS password prompt, it writes `/etc/sudoers.d/lidless`:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

The rule is checked with `visudo -c` before it is put in place. **Remove…** deletes it.

## Security

Be clear about what you are agreeing to:

- **The sudoers rule** lets any program running as your user turn system sleep off or on without a password. It allows those two exact commands and no others. The worst a malicious program gains from it is keeping your Mac awake. If that is not acceptable, do not install the rule: everything except closed-lid mode works without it.
- **The hooks** make your agents run `lidless-hook` on the events listed above. It reads the session ID and working directory from the hook payload, writes the session file, prints nothing and always exits 0. It does not read your prompts or tool output, and Lidless never uses the network.
- **Session files** hold the agent name, process ID, working directory and timestamps. They stay on your Mac.
- The app is signed ad hoc and not notarized, which is why you build it yourself.

## Limitations

- If the Mac restarts or is powered off hard while sleep is disabled, it stays disabled until Lidless starts again, which in a bag means a Mac that cannot sleep. That is why Lidless turns on **Open at login** the first time you use the lid closed; leave it on. Before you log in again nothing can fix it automatically, and `sudo pmset -a disablesleep 0` does it by hand.
- The thermal rule relies on what macOS reports. It reacts to the Mac running hot, not to how warm the bag is.
- An agent turn you interrupt is not reported by the agents. Lidless notices after the silent-agent timeout (30 minutes by default), or immediately if you quit the agent.
- A single tool call that runs longer than that timeout without any other activity looks the same as a stuck session. Raise the timeout, or set it to *Never*, if your runs do that.
- The awake limit also stops legitimate long runs. Raise it if you need more than 6 hours.
- Lidless does not stop sleep you ask for (Apple menu → Sleep), nor sleep forced by macOS (critically low battery, overheating).
- Codex does not announce the end of a session on every version; such sessions disappear when the process exits or after a day idle.

## Performance

Measured on an M3 Pro, details and method in [docs/PERFORMANCE.md](docs/PERFORMANCE.md):

- `lidless-hook` takes 5 to 6 ms per call (1.7 ms of which is starting a process), and prints nothing, ever: nothing of it lands in an agent's context.
- At rest the app uses 0.003 to 0.005% of a CPU and wakes it about 3 times a minute. It does not poll: the 10-second check only runs while an agent is working or a timer is running.
- With three agents working, each calling a tool every 2 seconds: 0.04 to 0.2% of a CPU and under one wake-up per second, depending on the run.
- 14 MB of memory. The universal bundle is 3.9 MB (2 MB zipped).

## Uninstall

1. Settings → turn every agent off (removes the hooks).
2. Settings → Closed-Lid Mode → **Remove…** (deletes the sudoers rule).
3. Quit Lidless, then delete `/Applications/Lidless.app` and `~/Library/Application Support/Lidless`.

## Development

```sh
swift build
swift test
./scripts/bundle.sh --native   # quick bundle for this Mac only
```

To try the whole app without touching a real agent configuration, point it at a throwaway home: `LIDLESS_HOME=/tmp/pretend-home LIDLESS_SUPPORT_DIR=/tmp/lidless-support dist/Lidless.app/Contents/MacOS/Lidless`.

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

## Prior art

Lidless was inspired by [insomnia](https://github.com/phin/insomnia) by phin (MIT), which had the idea of tying wakefulness to agent activity. Lidless shares no code with it.

Related tools: Amphetamine, the built-in `caffeinate`, Adrafinil and LidAwake. Lidless is narrower on purpose: it only follows coding agents.

## License

[MIT](LICENSE) © 2026 Ben (Benabens)
