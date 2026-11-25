#!/usr/bin/env python3
"""Mutation check over a branch's changed lines: would a test notice if this line were wrong?

  scripts/mutate.py --base REV [--max 24] [--seconds 600] [--case-seconds 180] [--filter REGEX] [--out FILE]
  scripts/mutate.py --self-test

For each line the branch added or changed under Sources/ (Swift and Metal), it makes one small
change at a time (a comparison, an operator, a blend factor, a constant), rebuilds, and runs the
tests. A mutant the tests fail on is killed. One they pass on SURVIVED: either no test asserts
that line's behaviour, or the change is equivalent. The reviewer decides which; this script only
reports. A mutant that does not compile is discarded.

It edits the working tree and restores every file, also on an interrupt. It refuses a tree with
tracked changes, and nothing else may build in this checkout while it runs.

Exit codes: 0 ran (survivors or not), 1 could not run (dirty tree, no package, the unmutated
tests fail), 3 the tree was not restored (never seen; the file names are printed).
"""
import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (name, pattern, replacement). Spaces around binary operators keep generics, arrows and ranges out.
OPERATORS = [
    ("<= to <", r" <= ", " < "), (">= to >", r" >= ", " > "),
    ("< to <=", r" < ", " <= "), ("> to >=", r" > ", " >= "),
    ("== to !=", r" == ", " != "), ("!= to ==", r" != ", " == "),
    ("&& to ||", r" && ", " || "), ("|| to &&", r" \|\| ", " && "),
    ("+ to -", r" \+ ", " - "), ("- to +", r" - ", " + "),
    ("* to /", r" \* ", " / "), ("/ to *", r" / ", " * "),
    ("+= to -=", r" \+= ", " -= "), ("-= to +=", r" -= ", " += "),
    ("true to false", r"\btrue\b", "false"), ("false to true", r"\bfalse\b", "true"),
    ("min to max", r"\bmin\(", "max("), ("max to min", r"\bmax\(", "min("),
    ("floor to ceil", r"\bfloor\(", "ceil("), ("ceil to floor", r"\bceil\(", "floor("),
    (".one to .zero", r"\.one\b(?!Minus)", ".zero"), (".zero to .one", r"\.zero\b", ".one"),
    ("sourceAlpha to oneMinusSourceAlpha", r"\.sourceAlpha\b", ".oneMinusSourceAlpha"),
    ("oneMinusSourceAlpha to sourceAlpha", r"\.oneMinusSourceAlpha\b", ".sourceAlpha"),
    (".less to .greater", r"\.less\b", ".greater"), (".lessEqual to .less", r"\.lessEqual\b", ".less"),
    (".linear to .nearest", r"\.linear\b", ".nearest"), (".clampToEdge to .repeat", r"\.clampToEdge\b", ".repeat"),
    ("sin to cos", r"\bsin\(", "cos("), ("cos to sin", r"\bcos\(", "sin("),
    ("drop negation", r"(?<=[\s(])!(?=[A-Za-z_(])", ""),
    ("float literal doubled", r"(?<![\w.])(\d+\.\d+)(?![\w.])", lambda m: repr(float(m.group(1)) * 2 + 1)),
    ("int literal plus one", r"(?<![\w.])(\d+)(?![\w.]|\s*\.\.)", lambda m: str(int(m.group(1)) + 1)),
]
SKIP_LINE = re.compile(r"^\s*(//|/\*|\*|import |@|#|case \w+\s*$|\}|\{)|\b(let|var)\s+\w+\s*:\s*[\w.<>\[\]?]+\s*$")


def sh(cmd, cwd=ROOT, timeout=None):
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return 124, "timeout"


def changed_lines(base, root=ROOT):
    """{path: [line numbers]} added or changed since base under Sources/, Swift and Metal only."""
    code, out = sh(["git", "diff", "-U0", "--no-color", base, "HEAD", "--", "Sources"], cwd=root)
    if code != 0:
        raise SystemExit("mutate: git diff failed: " + out.strip())
    return parse_diff(out)


def parse_diff(out):
    files, path = {}, None
    for line in out.splitlines():
        if line.startswith("+++ "):
            p = line[4:].strip()
            path = p[2:] if p.startswith("b/") else None
            if path and not re.search(r"\.(swift|metal)$", path):
                path = None
        elif line.startswith("@@") and path:
            m = re.search(r"\+(\d+)(?:,(\d+))?", line)
            start, count = int(m.group(1)), int(m.group(2) or 1)
            files.setdefault(path, []).extend(range(start, start + count))
    return files


def strip_strings(code):
    """Blank out string literals so an operator inside one is never mutated; keeps column positions."""
    return re.sub(r'"(?:\\.|[^"\\])*"', lambda m: '"' + " " * (len(m.group(0)) - 2) + '"', code)


def mutants_for_line(text):
    """[(operator name, mutated line)] for one source line; at most one site per operator."""
    if SKIP_LINE.search(text):
        return []
    cut = text.find("//")
    code, tail = (text, "") if cut < 0 else (text[:cut], text[cut:])
    masked = strip_strings(code)
    out = []
    for name, pattern, repl in OPERATORS:
        m = re.search(pattern, masked)
        if not m:
            continue
        new = repl(m) if callable(repl) else repl
        mutated = code[:m.start()] + new + code[m.end():] + tail
        if mutated != text:
            out.append((name, mutated))
    return out


def plan(files, limit, root=ROOT):
    """Round-robin over lines so a long diff is sampled across its whole length, not its first file."""
    per_line = []
    for path in sorted(files):
        try:
            with open(os.path.join(root, path), encoding="utf-8") as f:
                lines = f.read().split("\n")
        except OSError:
            continue
        for n in sorted(set(files[path])):
            if n <= len(lines):
                ms = mutants_for_line(lines[n - 1])
                if ms:
                    per_line.append([(path, n, name, new) for name, new in ms])
    picked, depth = [], 0
    total = sum(len(x) for x in per_line)
    while len(picked) < limit and len(picked) < total:
        step = max(1, len(per_line) // max(1, limit))
        for group in (per_line[i] for i in list(range(0, len(per_line), step)) + list(range(len(per_line)))):
            if depth < len(group) and group[depth] not in picked and len(picked) < limit:
                picked.append(group[depth])
        depth += 1
    return picked, total


def run(a):
    if not os.path.isfile(os.path.join(ROOT, "Package.swift")):
        print("mutate: no Package.swift; nothing to mutate")
        return 1
    code, out = sh(["git", "status", "--porcelain", "--untracked-files=no"])
    if out.strip():
        print("mutate: tracked changes in the tree; commit first\n" + out.rstrip())
        return 1
    files = changed_lines(a.base)
    picked, total = plan(files, a.max)
    if not picked:
        print("mutate: 0 mutants (no mutable changed line under Sources/)")
        return 0
    test = ["swift", "test", "--skip-build"] + (["--filter", a.filter] if a.filter else [])
    code, out = sh(["swift", "build", "--build-tests", "--enable-code-coverage"])
    if code == 0:
        code, out = sh(test, timeout=a.case_seconds * 4)
    if code != 0:
        print("mutate: the unmutated tests do not pass; fix that first\n" + "\n".join(out.splitlines()[-8:]))
        return 1
    originals, results, started = {}, [], time.time()

    def restore(*_):
        for path, text in originals.items():
            with open(os.path.join(ROOT, path), "w", encoding="utf-8") as f:
                f.write(text)
        if _:
            print("mutate: interrupted; tree restored")
            sys.exit(130)

    signal.signal(signal.SIGINT, restore)
    signal.signal(signal.SIGTERM, restore)
    try:
        for path, n, name, new in picked:
            if time.time() - started > a.seconds:
                break
            full = os.path.join(ROOT, path)
            if path not in originals:
                with open(full, encoding="utf-8") as f:
                    originals[path] = f.read()
            lines = originals[path].split("\n")
            old = lines[n - 1]
            lines[n - 1] = new
            with open(full, "w", encoding="utf-8") as f:
                f.write("\n".join(lines))
            code, out = sh(["swift", "build", "--build-tests", "--enable-code-coverage"], timeout=a.case_seconds * 4)
            if code != 0:
                state = "invalid"
            else:
                code, out = sh(test, timeout=a.case_seconds)
                state = "survived" if code == 0 else ("killed-timeout" if code == 124 else "killed")
            with open(full, "w", encoding="utf-8") as f:
                f.write(originals[path])
            results.append({"file": path, "line": n, "operator": name, "state": state,
                            "was": old.strip(), "became": new.strip()})
    finally:
        restore()
    sh(["swift", "build", "--build-tests", "--enable-code-coverage"])
    code, out = sh(["git", "status", "--porcelain", "--untracked-files=no"])
    count = lambda s: sum(1 for r in results if r["state"].startswith(s))
    print("mutation: %d of %d possible mutants run (%d planned, %ds): %d killed, %d survived, %d invalid" % (
        len(results), total, len(picked), int(time.time() - started), count("killed"), count("survived"), count("invalid")))
    for r in results:
        if r["state"] == "survived":
            print("SURVIVED %s:%d [%s] `%s` -> `%s`" % (r["file"], r["line"], r["operator"], r["was"], r["became"]))
    if a.out:
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        with open(a.out, "w") as f:
            json.dump({"base": a.base, "possible": total, "results": results}, f, indent=1)
    if out.strip():
        print("mutate: TREE NOT RESTORED:\n" + out.rstrip())
        return 3
    return 0


def self_test():
    names = lambda text: [n for n, _ in mutants_for_line(text)]
    one = lambda text, name: dict(mutants_for_line(text)).get(name)
    checks = [
        ("comparison", one("    if x < lo { return lo }", "< to <=") == "    if x <= lo { return lo }"),
        ("generic untouched", names("    let a: Array<Int> = f()") == []),
        ("arrow untouched", "> to >=" not in names("    func f() -> Int { g() }")),
        ("comment skipped", names("    // a < b") == []),
        ("trailing comment kept", one("    a + b // sum", "+ to -") == "    a - b // sum"),
        ("string untouched", names('    log("a < b && c")') == []),
        ("blend factor", one("    d.sourceRGBBlendFactor = .one", ".one to .zero") == "    d.sourceRGBBlendFactor = .zero"),
        ("oneMinus is not .one", ".one to .zero" not in names("    d.destinationRGBBlendFactor = .oneMinusSourceAlpha")),
        ("oneMinus flips", one("    f = .oneMinusSourceAlpha", "oneMinusSourceAlpha to sourceAlpha") == "    f = .sourceAlpha"),
        ("float literal", one("    return a * 0.5", "float literal doubled") == "    return a * 2.0"),
        ("int literal", one("    let n = count / 2", "int literal plus one") == "    let n = count / 3"),
        ("range bound untouched", "int literal plus one" not in names("    for i in 0..<n {")),
        ("member digits untouched", "int literal plus one" not in names("    let v = p.x0")),
        ("negation", one("    if !ready { return }", "drop negation") == "    if ready { return }"),
        ("import skipped", names("import Metal") == []),
        ("diff parsed", parse_diff("+++ b/Sources/E/A.swift\n@@ -3,0 +4,2 @@\n+a\n+b\n+++ b/Sources/E/x.png\n@@ -1 +1 @@\n"
                                   "+++ b/Sources/E/s.metal\n@@ -9 +9 @@\n") == {"Sources/E/A.swift": [4, 5], "Sources/E/s.metal": [9]}),
    ]
    failed = [n for n, ok in checks if not ok]
    for n in failed:
        print("FAIL " + n)
    print("mutate self-test: %d/%d" % (len(checks) - len(failed), len(checks)))
    return 1 if failed else 0


def main():
    if "--self-test" in sys.argv[1:]:
        sys.exit(self_test())
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base", required=True)
    p.add_argument("--max", type=int, default=24)
    p.add_argument("--seconds", type=int, default=600)
    p.add_argument("--case-seconds", type=int, default=180)
    p.add_argument("--filter")
    p.add_argument("--out")
    sys.exit(run(p.parse_args()))


if __name__ == "__main__":
    main()
