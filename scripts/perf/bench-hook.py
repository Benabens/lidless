#!/usr/bin/env python3
"""Times lidless-hook the way an agent calls it: one process per event, JSON on stdin.

    scripts/perf/bench-hook.py [path/to/lidless-hook] [calls per case]

Session files go to a temporary directory. The first row is a bare process spawn, to tell the
hook's own cost from the cost of starting any process.
"""
import os
import statistics
import subprocess
import sys
import tempfile
import time

hook = sys.argv[1] if len(sys.argv) > 1 else "dist/Lidless.app/Contents/MacOS/lidless-hook"
calls = int(sys.argv[2]) if len(sys.argv) > 2 else 200
support = tempfile.mkdtemp(prefix="lidless-bench-")
env = dict(os.environ, LIDLESS_SUPPORT_DIR=support)
pid = str(os.getpid())

small = (b'{"session_id":"bench-1","transcript_path":"/tmp/t.jsonl","cwd":"/Users/me/project",'
         b'"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"}}')
large = small[:-1] + b',"tool_response":{"stdout":"' + b"x" * 200_000 + b'"}}'


def run(arguments, payload, count):
    times = []
    for _ in range(count):
        started = time.perf_counter_ns()
        process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, env=env)
        process.communicate(payload)
        times.append((time.perf_counter_ns() - started) / 1e6)
    times.sort()
    return statistics.mean(times), times[len(times) // 2], times[int(len(times) * 0.95)]


cases = [
    ("bare process spawn (/usr/bin/true)", ["/usr/bin/true"], b"", False),
    ("prompt (writes the session file)", [hook, "claude", "prompt", "--pid", pid], small, False),
    ("activity, mid-turn (no write)", [hook, "claude", "activity", "--pid", pid], small, True),
    ("activity, 200 KB tool result", [hook, "claude", "activity", "--pid", pid], large, True),
    ("stop (writes the session file)", [hook, "claude", "stop", "--pid", pid], small, False),
]
print("%-38s %8s %8s %8s   (ms, n=%d)" % ("case", "mean", "median", "p95", calls))
for label, arguments, payload, needs_turn in cases:
    if needs_turn:
        run([hook, "claude", "prompt", "--pid", pid], small, 1)
    mean, median, p95 = run(arguments, payload, calls)
    print("%-38s %8.2f %8.2f %8.2f" % (label, mean, median, p95))
