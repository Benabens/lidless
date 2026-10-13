# Closed-lid mode

Keeps agents working with the lid closed, on the power adapter or on battery, and gives sleep back
as soon as it is no longer needed. This page covers what it does, what it asks of you, and where
it stops.

## What it does

Closing the lid normally puts a Mac to sleep whatever is running. Closed-lid mode is a switch **you** arm from the menu. It works on the power adapter and on battery: unplugging changes nothing.

While it is armed and at least one agent is working, Lidless runs `pmset -a disablesleep 1` and the Mac keeps working with the lid closed. It runs `pmset -a disablesleep 0` and disarms itself as soon as any of these is true:

- every agent has finished, after the grace period (an agent that went silent counts as finished);
- the battery drops below the level you set (20% by default), plugged in or not;
- the Mac gets hot: macOS reports *serious* or *critical* thermal pressure;
- the awake limit is reached (6 hours by default).

When one of the last three cuts a run short, a notification tells you why once you open the Mac. If you never want the Mac awake on battery, turn on **Only on power adapter** in Settings: unplugging then disarms closed-lid mode too.

**Heat.** A closed Mac sheds heat less well, and a bag traps what it sheds. Agents mostly wait on the network, so the load is usually light, but builds and test suites running locally are not. Use a bag or sleeve with some air around the Mac, not a tightly packed pocket, and never leave it running under a duvet or a cushion. The thermal rule above is a backstop, not a reason to skip this.

Lidless also puts the setting back when it launches and when it quits, and a small watchdog does it if the app is killed, crashes or freezes. It only ever undoes its own change: if `disablesleep` was already on when you armed the mode, Lidless leaves it alone.

The **Keep Awake For** timer has the same option, **Also with Lid Closed**. It uses the same switch and obeys the same battery and heat rules. It ends with the timer, and *Until I Turn It Off* ends at the awake limit. It is never remembered: it unchecks itself when the hold ends.

## The sudoers rule

`pmset disablesleep` needs administrator rights, and Lidless must be able to turn it back **off** without waiting for a password. So closed-lid mode needs a one-time setup, from **Settings → Closed-Lid Mode → Install…**. After the standard macOS password prompt, it writes `/etc/sudoers.d/lidless`:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

The rule is checked with `visudo -c` before it is put in place. **Remove…** deletes it.

## What you are agreeing to

- **The sudoers rule** lets any program running as your user turn system sleep off or on without a password. It allows those two exact commands and no others. The worst a malicious program gains from it is keeping your Mac awake. If that is not acceptable, do not install the rule: everything except closed-lid mode works without it.

## Limits

- If the Mac restarts or is powered off hard while sleep is disabled, it stays disabled until Lidless starts again, which in a bag means a Mac that cannot sleep. That is why Lidless turns on **Open at login** the first time you use the lid closed; leave it on. Before you log in again nothing can fix it automatically, and `sudo pmset -a disablesleep 0` does it by hand.
- The thermal rule relies on what macOS reports. It reacts to the Mac running hot, not to how warm the bag is.

## Turning it off for good

Settings → Closed-Lid Mode → **Remove…** deletes the rule. Lidless turns sleep back on first, and
keeps the rule if that fails, so it can never strand the Mac with sleep disabled.
