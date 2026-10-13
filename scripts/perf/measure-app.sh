#!/bin/bash
# Measures dist/Lidless.app at rest and with three working sessions, two minutes each.
#
#   scripts/bundle.sh && scripts/perf/measure-app.sh
#
# The app runs against a throwaway home and support directory (LIDLESS_HOME, LIDLESS_SUPPORT_DIR),
# so no real agent configuration or session is involved. Leave the Lidless menu alone while it
# runs: opening it is work, and it shows in the numbers.

set -u
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$root/dist/Lidless.app/Contents/MacOS/Lidless"
[ -x "$app" ] || { echo "measure-app.sh: build the bundle first (scripts/bundle.sh)" >&2; exit 1; }
window="${1:-120}"

work="$(mktemp -d)"
export LIDLESS_SUPPORT_DIR="$work/support" LIDLESS_HOME="$work/home"

# Three agents that look connected: one Lidless hook each is enough for the app to follow them.
for pair in claude:.claude/settings.json codex:.codex/hooks.json gemini:.gemini/settings.json; do
    agent="${pair%%:*}"; file="$work/home/${pair#*:}"
    mkdir -p "$(dirname "$file")"
    printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s %s stop"}]}]}}\n' "'/x/lidless-hook'" "$agent" > "$file"
done

defaults write com.benabens.lidless didShowWelcome -bool true   # no welcome window during the run
"$app" > /dev/null 2>&1 &
app_pid=$!
cleanup() {
    # Braces and wait keep bash from reporting each background job it terminates.
    { kill $loop_pid $agent_a $agent_b $agent_c; wait $loop_pid $agent_a $agent_b $agent_c; } 2>/dev/null
    kill -TERM $app_pid 2>/dev/null
    defaults delete com.benabens.lidless didShowWelcome 2>/dev/null
    rm -rf "$work"
}
loop_pid=""; agent_a=""; agent_b=""; agent_c=""
trap cleanup EXIT
sleep 12

"$root/scripts/perf/rusage.py" $app_pid "$window" "at rest, no session"

hook="$LIDLESS_SUPPORT_DIR/bin/lidless-hook"
sleep 3600 & agent_a=$!; sleep 3600 & agent_b=$!; sleep 3600 & agent_c=$!
payload() { printf '{"session_id":"%s","cwd":"/Users/me/project-%s","hook_event_name":"PreToolUse"}' "$1" "$1"; }
payload s1 | "$hook" claude prompt --pid $agent_a
payload s2 | "$hook" codex prompt --pid $agent_b
payload s3 | "$hook" gemini prompt --pid $agent_c
sleep 5
"$root/scripts/perf/rusage.py" $app_pid "$window" "3 working, no tool call"

( while true; do
    payload s1 | "$hook" claude activity --pid $agent_a
    payload s2 | "$hook" codex activity --pid $agent_b
    payload s3 | "$hook" gemini activity --pid $agent_c
    sleep 2
  done ) &
loop_pid=$!
sleep 3
"$root/scripts/perf/rusage.py" $app_pid "$window" "3 working, a tool call / 2 s"
