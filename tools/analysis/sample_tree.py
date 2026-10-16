#!/usr/bin/env python3
"""Summarize a macOS `sample` call graph: busy vs. waiting time per thread,
hottest self-time functions, and inclusive time for chosen functions.

usage: sample_tree.py SAMPLE.txt [--thread SUBSTR] [--top N] [--incl REGEX ...]
       sample_tree.py SAMPLE.txt --thread GameThread --children REGEX [--depth N]
"""
import argparse
import re
from collections import Counter, defaultdict

LINE = re.compile(r"^(?P<indent>[ +!:|]*)(?P<count>\d+) (?P<frame>.*)$")
# Leaf frames that mean the thread is blocked rather than doing work.
WAIT = re.compile(
    r"mach_msg|semaphore_timedwait|__recvfrom|start_wqthread|__psynch_cvwait|__psynch_mutexwait|__ulock_wait|semaphore_wait|"
    r"__semwait|kevent|__workq_kernreturn|__select|poll|nanosleep|__wait4|"
    r"usleep|_pthread_cond_wait|__sigsuspend|swtch_pri|thread_switch"
)


def clean(frame):
    frame = re.sub(r"\s+\[0x[0-9a-f]+(,0x[0-9a-f]+)*\]$", "", frame)
    frame = re.sub(r"\s+\+ \d+$", "", frame)
    return frame.strip()


class Node:
    __slots__ = ("name", "count", "children", "parent")

    def __init__(self, name, count, parent):
        self.name, self.count, self.children, self.parent = name, count, [], parent


def parse(path):
    threads = []
    in_graph = False
    stack = []  # (column, node)
    for raw in open(path, errors="replace"):
        raw = raw.rstrip("\n")
        if raw.startswith("Call graph:"):
            in_graph = True
            continue
        if not in_graph:
            continue
        if raw.startswith("Total number in stack") or raw.startswith("Sort by top of stack"):
            break
        m = LINE.match(raw)
        if not m:
            continue
        col = len(m.group("indent"))
        node = Node(clean(m.group("frame")), int(m.group("count")), None)
        while stack and stack[-1][0] >= col:
            stack.pop()
        if not stack:
            threads.append(node)
        else:
            node.parent = stack[-1][1]
            node.parent.children.append(node)
        stack.append((col, node))
    return threads


def walk(node):
    yield node
    for child in node.children:
        yield from walk(child)


def self_count(node):
    return node.count - sum(c.count for c in node.children)


def busy(thread):
    total = waiting = 0
    for n in walk(thread):
        s = self_count(n)
        if s <= 0:
            continue
        total += s
        if WAIT.search(n.name):
            waiting += s
    return total, waiting


def short(name, width=110):
    name = re.sub(r"\s+\(in [^)]*\)", "", name)
    return name if len(name) <= width else name[: width - 1] + "…"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sample")
    ap.add_argument("--thread", help="substring of thread names to focus on")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--incl", nargs="*", default=[], help="regexes for inclusive totals")
    ap.add_argument("--children", help="regex: print the callee breakdown under this frame")
    ap.add_argument("--depth", type=int, default=2)
    ap.add_argument("--group", help="regex: inclusive totals per matching frame name (outermost match)")
    args = ap.parse_args()

    threads = parse(args.sample)
    if args.thread:
        threads = [t for t in threads if args.thread in t.name]

    print(f"{'samples':>7} {'busy':>6} {'busy%':>6}  thread")
    rows = []
    for t in threads:
        total, waiting = busy(t)
        rows.append((total - waiting, total, t.name))
    for b, total, name in sorted(rows, reverse=True)[:60]:
        if b:
            print(f"{total:>7} {b:>6} {100.0 * b / max(total, 1):>5.1f}%  {short(name, 80)}")

    selfc = Counter()
    for t in threads:
        for n in walk(t):
            s = self_count(n)
            if s > 0 and not WAIT.search(n.name):
                selfc[short(n.name)] += s
    print(f"\nTop self (busy) frames{' in ' + args.thread if args.thread else ''}:")
    for name, c in selfc.most_common(args.top):
        print(f"{c:>7}  {name}")

    for rx in args.incl:
        r = re.compile(rx)
        total = 0
        for t in threads:
            for n in walk(t):
                if r.search(n.name):
                    # count only outermost match on each path
                    p, nested = n.parent, False
                    while p:
                        if r.search(p.name):
                            nested = True
                            break
                        p = p.parent
                    if not nested:
                        total += n.count
        print(f"\ninclusive {rx!r}: {total}")

    if args.group:
        r = re.compile(args.group)
        groups = Counter()

        def rec(node, inside):
            hit = (not inside) and r.search(node.name)
            if hit:
                groups[short(re.sub(r" \+ [\d,.]+.*$", "", node.name))] += node.count
            for c in node.children:
                rec(c, inside or bool(hit))

        for t in threads:
            rec(t, False)
        print(f"\nInclusive by {args.group!r}:")
        for name, c in groups.most_common(args.top):
            print(f"{c:>7}  {name}")

    if args.children:
        r = re.compile(args.children)
        agg = defaultdict(Counter)
        for t in threads:
            for n in walk(t):
                if r.search(n.name):
                    def rec(node, d, path):
                        for c in node.children:
                            key = path + (short(c.name, 90),)
                            agg[d][key] += c.count
                            if d < args.depth:
                                rec(c, d + 1, key)
                    rec(n, 1, ())
        print(f"\nCallees of {args.children!r}:")
        for d in sorted(agg):
            for key, c in agg[d].most_common(args.top):
                print(f"{c:>7}  {'  ' * (d - 1)}{key[-1]}")
            print()


if __name__ == "__main__":
    main()
