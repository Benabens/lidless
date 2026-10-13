# Performance

Every figure here was measured, on one machine: a MacBook Pro with an Apple M3 Pro and 18 GB of memory, macOS 27.0.1, with the universal release bundle of Lidless 0.1.0 (`scripts/bundle.sh`), on 13 October 2026. The scripts in `scripts/perf/` reproduce all of them. Where a figure moved between runs, the range is given rather than the best one.

## `lidless-hook`

The agents run `lidless-hook` on every prompt, every tool call and every end of turn, so its cost is paid many times per session. The target was to stay under 10 ms per call.

`scripts/perf/bench-hook.py`, 200 calls per case, in milliseconds:

| Case | Mean | Median | 95th percentile |
| --- | ---: | ---: | ---: |
| Bare process spawn (`/usr/bin/true`), for reference | 1.78 | 1.72 | 2.18 |
| `prompt`: start of a turn, writes the session file | 5.87 | 5.45 | 7.63 |
| `activity`: tool call mid-turn, no write | 5.22 | 5.01 | 6.51 |
| `activity` with a 200 KB tool result on stdin | 5.57 | 5.44 | 6.53 |
| `stop`: end of a turn, writes the session file | 5.87 | 5.60 | 7.06 |

- A call costs 5 to 6 ms, of which 1.7 ms is the price of starting any process at all. An earlier run of the same benchmark gave 4.9 to 5.5 ms. It is under the target with room to spare, so it was not optimised further.
- Claude Code calls it before and after each tool, which adds up to roughly 10 ms per tool call.
- The size of the payload barely matters: 200 KB adds about 0.4 ms.
- Mid-turn events rewrite the session file at most once every 15 seconds; in between, the hook reads and exits.
- `hyperfine` was not installed, so the timings come from a Python loop around `subprocess.Popen`. The reference row is measured the same way and carries the same overhead.

**It prints nothing.** Whatever a hook prints can end up in the agent's context, and so in every later request. `HookExecutableTests` runs the real executable for the three agents and all five events, with wrong arguments, with unreadable input and with a 4 MB tool result, and requires empty stdout, empty stderr and exit status 0 every time.

## The app

`scripts/perf/measure-app.sh` runs the bundled app against a throwaway home and reads the kernel's accounting for the process (`proc_pid_rusage`) at both ends of a two-minute window. Wake-ups are package-idle plus interrupt wake-ups, the counter `top` shows as `IDLEW`.

Two runs of the final design, each window 120 s:

| Scenario | CPU time | Average CPU | Wake-ups | Memory footprint | Resident size |
| --- | ---: | ---: | ---: | ---: | ---: |
| At rest, agents connected, no session | 3.6 – 5.4 ms | 0.003 – 0.005 % | 5 – 6 (0.04 – 0.05/s) | 14.1 – 14.5 MB | 62 – 63 MB |
| 3 sessions working, no tool call | 34 – 202 ms | 0.03 – 0.17 % | 15 – 50 (0.12 – 0.42/s) | 14.2 – 14.8 MB | 67 – 68 MB |
| 3 sessions working, each calling a tool every 2 s | 47 – 239 ms | 0.04 – 0.20 % | 25 – 106 (0.21 – 0.88/s) | 14.2 – 14.8 MB | 63 – 64 MB |

- **At rest the app does nothing.** A third run, minute by minute over four minutes, gave 0.8 to 3.4 ms of CPU and 1 to 3 wake-ups per minute.
- **While agents work, it runs one pass every 10 seconds**, 12 in a window, plus one per burst of session changes. Counting them confirmed there is no other trigger. The spread between runs is the cost of waking a cold process, not extra work: the pass itself takes 0.19 ms when timed in a loop, about 3 ms of wall time when it runs once every 10 seconds, and the process as a whole is charged 3 to 17 ms for it depending on the state of the machine.
- The memory footprint is what Lidless itself costs, the figure Activity Monitor shows. The resident size is larger because it counts the pages of AppKit and SwiftUI that every app shares. The app runs 3 threads.

What keeps these numbers low:

- **No polling at rest.** The periodic pass (every 10 seconds, with 3 seconds of tolerance so macOS can group it with other wake-ups) only runs while time alone can change the outcome: an agent working, a grace period, a keep-awake timer, or sleep disabled for a closed lid. Otherwise the app waits on events: a change in the sessions folder, the power source, heat, waking from sleep.
- **Bursts are folded.** Session files often change several times in a row; one pass 0.2 s later handles them all.
- **The menu bar item is only touched when it changes.** Reassigning its tooltip on every pass cost a redraw each time. A run before that fix measured 116 ms and 135 wake-ups for three working sessions, and 316 ms and 254 wake-ups with tool calls. That run's footprint was 22 MB instead of 14 MB, which suggests the menu was opened while it ran, so it is not a clean comparison.

## Size

| | On disk |
| --- | ---: |
| `Lidless.app`, universal | 3.92 MB |
| the same, zipped | 1.97 MB |
| `Contents/MacOS/Lidless` (arm64 0.93 MB + x86_64 0.93 MB) | 1.88 MB |
| `Contents/MacOS/lidless-hook` (arm64 0.58 MB + x86_64 0.56 MB) | 1.17 MB |
| `Contents/Resources/AppIcon.icns` | 1.04 MB |

The binaries are not stripped. No dependency beyond the system frameworks.

## Not measured

- **Energy impact.** `powermetrics` reports it, but needs `sudo`.
- **Closed-lid mode engaged.** It adds one `pmset -g` process to each pass. Nothing here ran `pmset`.
- **The settings window open**, where SwiftUI redraws as the state changes.
- **An Intel Mac.** The x86_64 slice is built, but was not run.
