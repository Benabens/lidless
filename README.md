<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="design/logo/lidless-lockup-on-dark.svg">
    <img src="design/logo/lidless-lockup.svg" alt="Lidless" width="320">
  </picture>
</p>

<p align="center"><b>Keeps your Mac awake while coding agents work, then lets it sleep.</b></p>

Lidless is a macOS menu bar app. While Claude Code, Codex or Gemini CLI is working, the Mac stays awake, with the lid closed and on battery if you want. The moment they are done, it sleeps as usual. No timer to guess, nothing to remember to turn off.

## Install

1. Download `Lidless.zip` from the [latest release](https://github.com/Benabens/lidless/releases/latest), unzip it and move **Lidless** to Applications.
2. Open it. The app is not notarized, so macOS blocks the first launch. On macOS 15 or later, go to **System Settings → Privacy & Security** and click **Open Anyway**. On macOS 13 and 14, right-click the app and choose **Open**.
3. Turn on the agents you use in the settings window that opens.

Or build it from source, with the Xcode Command Line Tools:

```sh
git clone https://github.com/Benabens/lidless.git && cd lidless
./scripts/bundle.sh
./scripts/install-dev.sh
```

Requires macOS 13 or later, on Apple Silicon or Intel.

## How it works

- **It listens to the agents.** Turning an agent on adds one hook to its configuration. Your own hooks are left untouched, the original file is backed up, and turning the agent off removes only what Lidless added.
- **It holds the Mac awake only while a session is working**, plus two minutes after the last turn. The display still turns off on its usual schedule.
- **It errs on the side of sleep.** An agent that dies, or goes silent for 30 minutes, stops counting, and nothing is held for more than 6 hours in a row. Settings changes all of it.
- **It costs nothing at rest.** No polling: about 3 wake-ups a minute and 14 MB of memory. The hook takes 5 to 6 ms and never prints anything into an agent's context.
- **Keep Awake For** holds the Mac awake for a set time, agents or not: 15 minutes to 4 hours, until you turn it off, or any duration you type.

More in [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) and [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Closed-lid mode

Close the lid, put the Mac in your bag, and the agents keep going.

- **You arm it** from the menu. While an agent is working, Lidless turns system sleep off, on the power adapter or on battery.
- **It turns itself off** when every agent has finished, when the battery drops below 20%, when the Mac gets hot, or after 6 hours. A notification tells you why.
- **It needs a one-time setup**: a sudoers rule that lets your account run exactly two commands without a password, `pmset -a disablesleep 1` and `pmset -a disablesleep 0`. Nothing else, and Settings removes it.
- **It always gives sleep back**: when it quits, when it starts, and through a watchdog if it crashes or freezes. It opens at login for the same reason.
- **Mind the heat.** A closed Mac in a bag sheds heat poorly. Give it some air, and never leave it running under a duvet.

The details and the trade-offs are in [docs/CLOSED-LID.md](docs/CLOSED-LID.md).

## Uninstall

In Settings, turn every agent off and remove the closed-lid rule. Quit Lidless, then delete `Lidless.app` and `~/Library/Application Support/Lidless`.

## Development

```sh
swift build && swift test
```

Everything that decides anything lives in `Sources/LidlessCore`, without AppKit and under test. If `swift build` fails before compiling anything, see [Building it](docs/HOW-IT-WORKS.md#building-it). The logo and its usage guide are in [design/logo](design/logo).

## License

[MIT](LICENSE) © 2026 Ben (Benabens)
