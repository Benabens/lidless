#!/usr/bin/env python3
"""Reports what a process cost over a window: CPU time, wake-ups, memory.

    scripts/perf/rusage.py <pid> <seconds> <label>

Reads the kernel's own accounting through proc_pid_rusage, so it needs no sudo (powermetrics
does). Wake-ups are package-idle plus interrupt wake-ups.
"""
import ctypes
import sys
import time


class RUsageInfoV4(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins", "wired_size",
        "resident_size", "phys_footprint", "proc_start_abstime", "proc_exit_abstime",
        "child_user_time", "child_system_time", "child_pkg_idle_wkups", "child_interrupt_wkups",
        "child_pageins", "child_elapsed_abstime", "diskio_bytesread", "diskio_byteswritten",
        "qos_default", "qos_maintenance", "qos_background", "qos_utility", "qos_legacy",
        "qos_user_initiated", "qos_user_interactive", "billed_system_time", "serviced_system_time",
        "logical_writes", "lifetime_max_phys_footprint", "instructions", "cycles", "billed_energy",
        "serviced_energy", "interval_max_phys_footprint", "runnable_time")]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
timebase = Timebase()
libsystem.mach_timebase_info(ctypes.byref(timebase))


def sample(pid):
    usage = RUsageInfoV4()
    if libsystem.proc_pid_rusage(pid, 4, ctypes.byref(usage)) != 0:
        raise SystemExit("proc_pid_rusage failed for pid %d" % pid)
    # CPU times are in Mach time units, which are not nanoseconds on Apple Silicon.
    cpu_ns = (usage.user_time + usage.system_time) * timebase.numer / timebase.denom
    return cpu_ns, usage.pkg_idle_wkups + usage.interrupt_wkups, usage.resident_size, usage.phys_footprint


pid, seconds, label = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
cpu_before, wakeups_before, _, _ = sample(pid)
started = time.time()
time.sleep(seconds)
cpu_after, wakeups_after, resident, footprint = sample(pid)
elapsed = time.time() - started
cpu_ms = (cpu_after - cpu_before) / 1e6
wakeups = wakeups_after - wakeups_before
print("%-28s %4.0f s | CPU %6.1f ms (%.4f %%) | wake-ups %4d (%.2f/s) | footprint %5.1f MB | RSS %5.1f MB" % (
    label, elapsed, cpu_ms, cpu_ms / 10 / elapsed, wakeups, wakeups / elapsed,
    footprint / 1048576, resident / 1048576))
