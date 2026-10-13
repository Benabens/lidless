# Performance

Every figure here was measured, on one machine: a MacBook Pro with an Apple M3 Pro and 18 GB of memory, macOS 27.0.1, with the universal release bundle of Lidless 0.1.0 (`scripts/bundle.sh`), on 13 October 2026. Each figure comes from a single run unless stated otherwise. The scripts in `scripts/perf/` reproduce all of them.

## `lidless-hook`

The agents run `lidless-hook` on every prompt, every tool call and every end of turn, so its cost is paid many times per session. The target was to stay under 10 ms per call.

`scripts/perf/bench-hook.py`, 200 calls per case, in milliseconds:

| Case | Mean | Median | 95th percentile |
| --- | ---: | ---: | ---: |
| Bare process spawn (`/usr/bin/true`), for reference | 1.63 | 1.59 | 2.01 |
| `prompt`: start of a turn, writes the session file | 5.51 | 5.21 | 6.41 |
| `activity`: tool call mid-turn, no write | 4.86 | 4.74 | 5.81 |
| `activity` with a 200 KB tool result on stdin | 5.30 | 5.13 | 6.34 |
| `stop`: end of a turn, writes the session file | 5.37 | 5.22 | 6.46 |

- A call costs about 5 ms, of which 1.6 ms is the price of starting any process at all. It is under the target with room to spare, so it was not optimised further.
- Claude Code calls it before and after each tool, which adds up to roughly 10 ms per tool call.
- The size of the payload barely matters: 200 KB adds about 0.4 ms.
- Mid-turn events rewrite the session file at most once every 15 seconds; in between, the hook reads and exits.
- `hyperfine` was not installed, so the timings come from a Python loop around `subprocess.Popen`. The reference row is measured the same way and carries the same overhead.

**It prints nothing.** Whatever a hook prints can end up in the agent's context, and so in every later request. `HookExecutableTests` runs the real executable for the three agents and all five events, with wrong arguments, with unreadable input and with a 4 MB tool result, and requires empty stdout, empty stderr and exit status 0 every time.

## The app

`scripts/perf/measure-app.sh` runs the bundled app against a throwaway home and reads the kernel's accounting for the process (`proc_pid_rusage`) at both ends of a two-minute window. Wake-ups are package-idle plus interrupt wake-ups, the counter `top` shows as `IDLEW`.

| Scenario, over 120 s | CPU time | Average CPU | Wake-ups | Memory footprint | Resident size |
| --- | ---: | ---: | ---: | ---: | ---: |
| At rest, agents connected, no session | 5.4 ms | 0.0045 % | 6 (0.05/s) | 14.1 MB | 62.1 MB |
| 3 sessions working, no tool call | 34.4 ms | 0.029 % | 15 (0.12/s) | 14.2 MB | 67.6 MB |
| 3 sessions working, each calling a tool every 2 s | 47.1 ms | 0.039 % | 25 (0.21/s) | 14.2 MB | 64.2 MB |

A second run at rest, minute by minute over four minutes, gave 0.8 to 3.4 ms of CPU and 1 to 3 wake-ups per minute. The app runs 3 threads.

The memory footprint is what Lidless itself costs, the figure Activity Monitor shows. The resident size is larger because it counts the pages of AppKit and SwiftUI that every app shares.

What keeps these numbers low:

- **No polling at rest.** The periodic pass (every 10 seconds, with 3 seconds of tolerance so macOS can group it with other wake-ups) only runs while time alone can change the outcome: an agent working, a grace period, a keep-awake timer, or sleep disabled for a closed lid. Otherwise the app waits on events: a change in the sessions folder, the power source, heat, waking from sleep.
- **Bursts are folded.** Session files often change several times in a row; one pass 0.2 s later handles them all.
- **The menu bar item is only touched when it changes.** Reassigning its tooltip on every pass cost a redraw each time. A run before that fix measured 115.6 ms and 135 wake-ups for three working sessions, and 316 ms and 254 wake-ups with tool calls. That run's footprint was 22 MB instead of 14 MB, which suggests the menu was opened while it ran, so only part of the difference is the fix.

## Size

| | On disk |
| --- | ---: |
| `Lidless.app`, universal | 3.90 MB |
| the same, zipped | 1.96 MB |
| `Contents/MacOS/Lidless` (arm64 0.91 MB + x86_64 0.92 MB) | 1.82 MB |
| `Contents/MacOS/lidless-hook` (arm64 0.58 MB + x86_64 0.56 MB) | 1.14 MB |
| `Contents/Resources/AppIcon.icns` | 1.01 MB |

The binaries are not stripped. No dependency beyond the system frameworks.

## Not measured

- **Energy impact.** `powermetrics` reports it, but needs `sudo`.
- **Closed-lid mode engaged.** It adds one `pmset -g` process to each pass. Nothing here ran `pmset`.
- **The settings window open**, where SwiftUI redraws as the state changes.
- **An Intel Mac.** The x86_64 slice is built, but was not run.
