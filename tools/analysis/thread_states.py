#!/usr/bin/env python3
"""Per-thread working, spinning, runnable and asleep time, and core tier.

  thread_states.py record PID SECONDS OUT.trace   # Instruments System Trace
  thread_states.py analyze OUT.trace [--json FILE] [--spin-frame NAME ...]

From the trace's thread-state intervals: Running (+ Interrupted) is on a core,
Runnable/Preempted is waiting for a core, Blocked is asleep. Running time is
split by the core type it ran on (Super or Performance) and, using the 1 ms
on-CPU time-profile samples, into working and spinning.

A sample is spinning when every frame from the leaf up to the nearest wait
loop is wait machinery (yields, clocks, queue polls, event and lock calls);
anything else, such as a job a waiter runs, is working. Wait loops are BG3's
idle and wait functions plus the yield calls themselves.
"""
import argparse, collections, json, re, subprocess, sys
import xml.etree.ElementTree as ET

WAIT_LOOPS = ("GameClock::CapFrame", "WorkerThreadBatch::WaitForCompletion", "WorkerThreadWorker::DoWork",
              "WorkerThreadScheduler::DoWork", "WaitForEventAndDoWork",
              "pthread_yield_np", "cthread_yield", "swtch_pri", "sched_yield", "thread_switch")
WAIT_MACHINERY = ("yield", "swtch_pri", "thread_switch", "mach_absolute_time", "mach_timebase_info", "ToMicrosec",
                  "StealJob", "MPMCQueue", "SRWKernelLock", "ScopedReadLock", "WaitEvent", "ThreadEvent",
                  "semaphore_", "mach_wait_until", "os_unfair_lock", "__ulock", "pthread_mutex", "__psynch",
                  "objc_autoreleasePool", "AutoreleasePool")


def export(trace, schema):
    """Stream one table's rows as dicts keyed by column mnemonic."""
    proc = subprocess.Popen(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                             f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'],
                            stdout=subprocess.PIPE)
    values, columns = {}, []
    for event, element in ET.iterparse(proc.stdout, events=("end",)):
        tag = element.tag
        if tag == "mnemonic":
            columns.append(element.text)
            continue
        if tag != "row":
            ref = element.get("ref")
            if ref is None and element.get("id") is not None:
                values[element.get("id")] = value(element, values)
            continue
        row = {}
        for column, child in zip(columns, element):
            ref = child.get("ref")
            row[column] = values.get(ref) if ref is not None else (None if child.tag == "sentinel" else value(child, values))
        yield row
        element.clear()
    proc.wait()


def resolved(element, values):
    ref = element.get("ref")
    return values.get(ref) if ref is not None else value(element, values)


def value(element, values):
    tag = element.tag
    if tag == "thread":
        pid = element.find("process/pid")
        process = element.find("process")
        if pid is None and process is not None:
            pid_value = (values.get(process.get("ref")) or {}).get("pid")
        else:
            pid_value = int(pid.text) if pid is not None else None
        tid = element.find("tid")
        return {"name": element.get("fmt", ""), "tid": int(tid.text) if tid is not None and tid.text else None,
                "pid": pid_value}
    if tag == "process":
        pid = element.find("pid")
        return {"pid": int(pid.text) if pid is not None else None}
    if tag == "core":
        return {"cpu": int(element.text), "tier": "super" if "(S Core)" in element.get("fmt", "") else "performance"}
    if tag in ("duration", "weight", "start-time", "sample-time"):
        return int(element.text)
    if tag == "frame":
        return element.get("name") or element.get("addr", "?")
    if tag == "tagged-backtrace" or tag == "backtrace":
        return tuple(resolved(frame, values) for frame in element.findall("frame"))
    return element.text


def thread_name(fmt):
    name = re.sub(r" \(0x[0-9a-f]+\) \(.*\)$", "", fmt)
    return "(unnamed)" if name.startswith("0x") or not name else name


def group_name(name):
    return re.sub(r"\d+$", "*", name)


def classify(stack, spin_frames):
    # On core inside a contended os_unfair_lock: the kernel spins while the
    # owner runs. Counted separately from job work and from wait loops.
    for frame in stack[:4]:
        if "os_unfair_lock_lock_slow" in frame or "os_unfair_lock_unlock_slow" in frame:
            return "lock"
        if not any(part in frame for part in WAIT_MACHINERY):
            break
    for frame in stack:
        if any(loop in frame for loop in WAIT_LOOPS) or frame in spin_frames:
            return "spinning"
        if not any(part in frame for part in WAIT_MACHINERY):
            return "working"
    return "working"


def lock_caller(stack):
    # The first frame past the lock and wait machinery: the code that took it.
    for frame in stack:
        if not any(part in frame for part in WAIT_MACHINERY):
            return frame.split("(")[0]
    return "?"


def analyze(trace, spin_frames):
    # Samples first: they bound the recorded window (thread-state also has a
    # synthetic interval from time 0 to each thread's first event) and give
    # each thread's working/spinning split.
    samples = collections.defaultdict(collections.Counter)
    callers = collections.Counter()
    first = last = None
    for row in export(trace, "time-profile"):
        time = row.get("time")
        first = time if first is None else min(first, time)
        last = time if last is None else max(last, time)
        thread = row.get("thread") or {}
        if thread.get("tid") is not None:
            kind = classify(row.get("stack") or (), spin_frames)
            samples[thread["tid"]][kind] += 1
            if kind == "lock":
                callers[lock_caller(row.get("stack") or ())] += 1
    threads = collections.defaultdict(collections.Counter)
    names = {}
    for row in export(trace, "thread-state"):
        thread = row.get("thread") or {}
        tid = thread.get("tid")
        if tid is None or row.get("duration") is None:
            continue
        names[tid] = thread_name(thread.get("name", ""))
        start = row.get("start") or 0
        duration = min(start + row["duration"], last) - max(start, first)
        if duration <= 0:
            continue
        counts, state = threads[tid], row.get("state")
        if state in ("Running", "Interrupted"):
            counts["running"] += duration
            counts[(row.get("core") or {}).get("tier", "unknown")] += duration
        elif state in ("Runnable", "Preempted"):
            counts["runnable"] += duration
        else:
            counts["asleep"] += duration
    rows = []
    for tid, counts in threads.items():
        total = counts["running"] + counts["runnable"] + counts["asleep"]
        if not total:
            continue
        sampled = samples[tid]
        share = {kind: sampled[kind] / max(sum(sampled.values()), 1) for kind in ("working", "spinning", "lock")}
        if not sum(sampled.values()):
            share["working"] = 1
        rows.append({"thread": names[tid], "tid": tid, "observed_ns": total,
                     "working_ns": counts["running"] * share["working"], "spinning_ns": counts["running"] * share["spinning"],
                     "lock_ns": counts["running"] * share["lock"],
                     "runnable_ns": counts["runnable"], "asleep_ns": counts["asleep"],
                     "super_ns": counts["super"], "performance_ns": counts["performance"],
                     "unknown_core_ns": counts["unknown"], "samples": dict(sampled)})
    return {"trace": trace, "window_ns": last - first, "threads": rows, "lock_callers": dict(callers.most_common())}


def report(result):
    groups = collections.OrderedDict()
    for row in sorted(result["threads"], key=lambda r: -(r["working_ns"] + r["spinning_ns"] + r["lock_ns"])):
        groups.setdefault(group_name(row["thread"]), []).append(row)
    print(f"{'thread':34s} {'n':>3s} {'cores':>6s} {'work':>6s} {'spin':>6s} {'lock':>6s} {'runbl':>6s} {'asleep':>6s} {'super':>6s} {'perf':>6s}")
    print(f"{'':34s} {'':>3s} {'':>6s} {'(% of each thread’s time)':>34s} {'(% of on-core)':>13s}")
    total_cores = 0
    for name, rows in groups.items():
        observed = sum(r["observed_ns"] for r in rows)
        on = sum(r["working_ns"] + r["spinning_ns"] + r["lock_ns"] for r in rows)
        cores = on / result["window_ns"]
        total_cores += cores
        if on < 0.005 * result["window_ns"] and all(r["runnable_ns"] < 0.005 * r["observed_ns"] for r in rows):
            continue
        pct = lambda key: 100 * sum(r[key] for r in rows) / observed
        tier = lambda key: 100 * sum(r[key] for r in rows) / on if on else 0
        print(f"{name[:34]:34s} {len(rows):3d} {cores:6.2f} {pct('working_ns'):6.1f} {pct('spinning_ns'):6.1f} {pct('lock_ns'):6.1f} "
              f"{pct('runnable_ns'):6.1f} {pct('asleep_ns'):6.1f} {tier('super_ns'):6.1f} {tier('performance_ns'):6.1f}")
    print(f"total on-core: {total_cores:.2f} cores over {result['window_ns'] / 1e9:.2f} s")
    callers = result.get("lock_callers") or {}
    if callers:
        total = sum(callers.values())
        print(f"lock samples by caller ({total}):")
        for caller, count in list(callers.items())[:12]:
            print(f"  {100 * count / total:5.1f}%  {caller[:110]}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    record = commands.add_parser("record")
    record.add_argument("pid")
    record.add_argument("seconds", type=float)
    record.add_argument("output")
    analysis = commands.add_parser("analyze")
    analysis.add_argument("trace")
    analysis.add_argument("--json")
    analysis.add_argument("--spin-frame", action="append", default=[])
    args = parser.parse_args()
    if args.command == "record":
        sys.exit(subprocess.call(["xcrun", "xctrace", "record", "--template", "System Trace", "--attach", args.pid,
                                  "--time-limit", f"{args.seconds:g}s", "--output", args.output, "--no-prompt"]))
    result = analyze(args.trace, set(args.spin_frame))
    if args.json:
        json.dump(result, open(args.json, "w"), indent=1)
    report(result)


if __name__ == "__main__":
    main()
