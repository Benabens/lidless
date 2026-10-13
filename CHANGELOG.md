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
- Closed-lid mode: a switch that keeps agents working with the lid closed, on the power adapter or
  on battery, and disarms itself when they finish, when the battery gets low, when the Mac gets hot
  or at the awake limit, with a notification when a safety rule cuts a run short. Backed by an
  optional sudoers rule limited to two `pmset` commands, and a watchdog that restores sleep if the
  app dies or freezes.
- "Keep Awake For": a timer from 15 minutes to 4 hours, open-ended, or a typed duration, which
  holds the Mac awake whether or not an agent is working, optionally with the lid closed, with the
  time left in the menu or next to the icon.
- Open at login (turned on the first time the lid-closed switch is used), and a settings window.
- Measured performance in `docs/PERFORMANCE.md`, with the scripts to reproduce it in `scripts/perf/`.
- `scripts/bundle.sh` to build a universal `Lidless.app`, and `scripts/swiftw` to build with a
  Command Line Tools install that an in-place update left broken.
