# Changelog

All notable changes to Lidless are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.0] - Unreleased

First version.

### Added

- Menu bar app that keeps the Mac awake while a Claude Code, Codex or Gemini CLI session is
  working, and releases it when they are done. The display is still allowed to sleep.
- `lidless-hook`, the executable agents call from their hooks, and one-switch installation into
  each agent's hook configuration. Existing hooks are preserved, the original file is backed up,
  and disconnecting removes only Lidless's entries.
- Safety rules: grace period after the last turn, dead-process detection, a timeout for sessions
  that go silent, power-adapter-only mode, a battery floor and an absolute awake limit.
- Closed-lid mode: a switch that keeps agents working with the lid closed on power, and disarms
  itself when they finish, on battery, on low battery or at the awake limit. Backed by an optional
  sudoers rule limited to two `pmset` commands, and a watchdog that restores sleep if the app dies
  or freezes.
- "Keep Awake Anyway", open at login, and a settings window.
- `scripts/bundle.sh` to build a universal `Lidless.app`, and `scripts/swiftw` to build with a
  Command Line Tools install that an in-place update left broken.
