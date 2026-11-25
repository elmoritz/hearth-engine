#!/usr/bin/env python3
"""Performance tripwire on the development Mac: probes against a committed baseline.

  scripts/perf.py check            run the probes, compare with docs/perf/baseline.json
  scripts/perf.py update           run the probes and rewrite the baseline (on a ticket branch only)
  scripts/perf.py --self-test

A probe is a test whose suite or function name contains `Perf`, in a release build. It prints one
line per measurement on stdout:

    PERF <key> <value> <unit> <count|time>

`count` is for numbers that must not depend on the machine: draw calls, instances, bytes uploaded,
allocations per frame, pipelines built. Any increase over the baseline fails, and the three runs
must agree exactly. `time` is wall or CPU time; the median of three runs may exceed the baseline by
PERF_TIME_TOLERANCE (default 0.25) before it fails. Prefer counts: they catch the regression on
every machine and never flake.

This is not the device suite. The budgets of the catalogue's D ids are measured on the test
devices (D2) by the benchmark app; this only stops a branch from making the Mac numbers worse
without saying so. A branch that means to raise a number runs `update`, commits the baseline with
the change, and says why in the ticket's Evidence; the reviewer reads the baseline's diff.

Exit codes: 0 ok, 1 a regression or a probe failure, 4 nothing to check (no probes yet).
"""
import json
import os
import re
import statistics
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, "docs", "perf", "baseline.json")
LINE = re.compile(r"^PERF (\S+) (-?[\d.]+(?:e-?\d+)?) (\S+) (count|time)\s*$", re.M)
RUNS = 3


def probe_once():
    r = subprocess.run(["swift", "test", "-c", "release", "-Xswiftc", "-enable-testing", "--filter", "Perf",
                        "--scratch-path", os.path.join(ROOT, ".build", "perf")],
                       cwd=ROOT, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def parse(out):
    return {m.group(1): {"value": float(m.group(2)), "unit": m.group(3), "kind": m.group(4)} for m in LINE.finditer(out)}


def measure():
    """-> (probes {key: {value, unit, kind}}, problems [str]) or (None, [why])."""
    samples = []
    for _ in range(RUNS):
        code, out = probe_once()
        got = parse(out)
        if code != 0 and got:
            return None, ["a probe failed: " + " | ".join(l for l in out.splitlines() if "error" in l.lower() or "failed" in l)[:400]]
        if not got:
            return ({}, []) if code == 0 or "No matching test" in out or "no tests" in out.lower() else (
                None, ["the probe run failed: " + " | ".join(out.strip().splitlines()[-3:])[:400]])
        samples.append(got)
    return combine(samples)


def combine(samples):
    probes, problems = {}, []
    for key in sorted(set().union(*samples)):
        vals = [s[key]["value"] for s in samples if key in s]
        first = next(s[key] for s in samples if key in s)
        if len(vals) != len(samples):
            problems.append("%s: reported in %d of %d runs" % (key, len(vals), len(samples)))
        if first["kind"] == "count":
            if len(set(vals)) > 1:
                problems.append("%s: a count that varies between runs (%s); make it deterministic or call it time" % (
                    key, ", ".join("%g" % v for v in vals)))
            value = max(vals)
        else:
            value = statistics.median(vals)
        probes[key] = {"value": value, "unit": first["unit"], "kind": first["kind"]}
    return probes, problems


def compare(probes, base, tolerance):
    """-> (failures, notes)."""
    fails, notes = [], []
    for key, p in probes.items():
        b = base.get(key)
        if b is None:
            fails.append("%s: %g %s is not in the baseline; run scripts/perf.py update and commit it" % (key, p["value"], p["unit"]))
            continue
        limit = b["value"] if p["kind"] == "count" else b["value"] * (1 + tolerance)
        if p["value"] > limit:
            fails.append("%s: %g %s, baseline %g (%s, limit %g)" % (key, p["value"], p["unit"], b["value"], p["kind"], limit))
        elif p["value"] < b["value"] * (0.8 if p["kind"] == "time" else 1) and p["value"] != b["value"]:
            notes.append("%s improved: %g -> %g %s; ratchet it with scripts/perf.py update" % (key, b["value"], p["value"], p["unit"]))
    for key in base:
        if key not in probes:
            fails.append("%s: in the baseline but no probe reported it" % key)
    return fails, notes


def load_baseline():
    if not os.path.isfile(BASELINE):
        return {}
    with open(BASELINE) as f:
        return json.load(f)["probes"]


def self_test():
    out = "noise\nPERF draws.postcard 8 draws count\nPERF encode.postcard 1.25 ms time\nPERF bad line\n"
    p = parse(out)
    s = [{"a": {"value": v, "unit": "ms", "kind": "time"}, "n": {"value": 8, "unit": "draws", "kind": "count"}} for v in (1.0, 9.0, 1.2)]
    probes, problems = combine(s)
    s[1]["n"] = {"value": 9, "unit": "draws", "kind": "count"}
    _, vary = combine(s)
    base = {"a": {"value": 1.0, "unit": "ms", "kind": "time"}, "n": {"value": 8, "unit": "draws", "kind": "count"}}
    f = lambda a, n: compare({"a": {"value": a, "unit": "ms", "kind": "time"}, "n": {"value": n, "unit": "draws", "kind": "count"}}, base, 0.25)
    checks = [
        ("parse", list(p) == ["draws.postcard", "encode.postcard"] and p["encode.postcard"]["value"] == 1.25),
        ("median of time", probes["a"]["value"] == 1.2 and not problems),
        ("varying count flagged", len(vary) == 1 and "varies" in vary[0]),
        ("within tolerance", f(1.2, 8) == ([], [])),
        ("time regression", len(f(1.3, 8)[0]) == 1),
        ("count regression", len(f(1.0, 9)[0]) == 1),
        ("improvement noted", len(f(0.5, 7)[1]) == 2 and not f(0.5, 7)[0]),
        ("new probe fails", len(compare({"z": {"value": 1, "unit": "x", "kind": "count"}}, {}, 0.25)[0]) == 1),
        ("lost probe fails", len(compare({}, base, 0.25)[0]) == 2),
    ]
    failed = [n for n, ok in checks if not ok]
    for n in failed:
        print("FAIL " + n)
    print("perf self-test: %d/%d" % (len(checks) - len(failed), len(checks)))
    return 1 if failed else 0


def main():
    args = sys.argv[1:]
    if "--self-test" in args:
        sys.exit(self_test())
    if args not in (["check"], ["update"]):
        print(__doc__)
        sys.exit(64)
    if not os.path.isfile(os.path.join(ROOT, "Package.swift")):
        print("perf: no Package.swift yet")
        sys.exit(4)
    probes, problems = measure()
    if probes is None:
        print("perf: " + problems[0])
        sys.exit(1)
    base = load_baseline()
    if not probes and not base:
        print("perf: no probes yet (a test named *Perf* printing `PERF <key> <value> <unit> <count|time>`)")
        sys.exit(4)
    if args == ["update"]:
        if problems:
            for p in problems:
                print("perf: " + p)
            sys.exit(1)
        os.makedirs(os.path.dirname(BASELINE), exist_ok=True)
        with open(BASELINE, "w") as f:
            json.dump({"note": "Mac tripwire, not the device budgets. See scripts/perf.py.", "probes": probes}, f, indent=1, sort_keys=True)
            f.write("\n")
        print("perf: baseline written with %d probe(s)" % len(probes))
        return
    fails, notes = compare(probes, base, float(os.environ.get("PERF_TIME_TOLERANCE", "0.25")))
    for line in problems + fails + notes:
        print("perf: " + line)
    bad = problems + fails
    print("perf: %d probe(s), %d regression(s)" % (len(probes), len(bad)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
