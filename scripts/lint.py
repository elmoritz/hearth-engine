#!/usr/bin/env python3
"""Static rules the catalogue and CLAUDE.md state as "a lint fails on ...". No build needed.

  scripts/lint.py [--root DIR]      check the tree; prints `path:line: [rule] text`, exits 1 on any hit
  scripts/lint.py --rules           the rules, with the catalogue id or decision each one enforces
  scripts/lint.py --self-test

A deliberate exception carries a marker on the same line or the line above:
    // lint:allow <rule> - <why>
The reviewer reads every new marker; a marker without a reason is a finding.

A ticket whose S-kind catalogue id calls for a new lint adds a rule here, with a self-test case.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (rule, enforces, path regex, exempt path regex or None, pattern, message)
RULES = [
    ("clock", "E-HAR-2", r"^(Sources|Tests)/.*\.swift$", r"DisplayLink",
     r"\bDate\(\)|\bDate\.now\b|\bCACurrentMediaTime\b|\bmach_absolute_time\b|\bmach_continuous_time\b"
     r"|\bCFAbsoluteTimeGetCurrent\b|\bDispatchTime\.now\b|\bContinuousClock\b|\bSuspendingClock\b"
     r"|\bsystemUptime\b|\bclock_gettime\b",
     "clock read outside the display-link adapter; time is injected"),
    ("sleep", "E-HAR-3", r"^(Sources|Tests)/.*\.swift$", None,
     r"\bsleep\(|\busleep\(|\bTask\.sleep\b|\bThread\.sleep\b",
     "a sleep makes the result depend on the machine"),
    ("loader", "E-TEX-1", r"^Sources/.*\.swift$", None,
     r"\bUIImage\(|\bNSImage\(|\bCGImageSourceCreate\w*|\bMTKTextureLoader\b",
     "image-framework loader; textures load through the engine's container"),
    ("mips", "E-TEX-2", r"^Sources/.*\.swift$", None, r"\bgenerateMipmaps\b",
     "mips are shipped, never generated at run time"),
    ("metal4", "D4, E-API-3", r"^Sources/.*\.(swift|metal|h)$", None, r"\bMTL4\w+",
     "Metal 4 API; the engine stays on the Metal 3-era API"),
    ("family", "E-API-3", r"^Sources/.*\.swift$", None, r"\bsupportsFamily\(",
     "probe the capability, not the GPU family"),
    ("shader-source", "B-METALLIB-1", r"^Sources/.*\.swift$", None, r"\bmakeLibrary\(\s*source\s*:",
     "shader source compiled at run time; shaders ship as a metallib"),
    ("crash", "E-HAR-4", r"^Sources/.*\.swift$", None,
     r"\btry!|\bfatalError\(|\bpreconditionFailure\(|\bassertionFailure\(|\bas!|\bunsafeBitCast\(",
     "a crash path; the engine throws typed errors"),
    ("concurrency", "E-API-1", r"^Sources/.*\.swift$", None,
     r"@unchecked\s+Sendable|\bnonisolated\(unsafe\)|@preconcurrency\b",
     "an escape from strict concurrency"),
    ("agnostic", "CLAUDE.md", r"^(Sources/.*|Package\.swift)$", None,
     r"IdleVillage|\bGameState\b|village_kit|\bIV-\d+",
     "a consumer's name in the engine; the engine is game-agnostic"),
    ("deps", "E-API-1", r"^Package\.swift$", None, r"\.package\(",
     "a package dependency; the engine has none"),
]
EMOJI = re.compile("[%s-%s%s-%s%s%s%s]" % tuple(chr(c) for c in (0x1F000, 0x1FAFF, 0x2600, 0x27BF, 0x2B50, 0x2B55, 0xFE0F)))
EMOJI_PATHS = re.compile(r"\.(swift|metal|h|md|py|sh|json|yml|yaml|txt)$|^scripts/[^/.]+$|^Package\.swift$")
ALLOW = re.compile(r"lint:allow\s+([a-z0-9-]+)\s*(?:-\s*(\S.*))?")


def tracked(root):
    r = subprocess.run(["git", "-C", root, "ls-files", "-co", "--exclude-standard"], capture_output=True, text=True)
    if r.returncode == 0:
        return [p for p in r.stdout.splitlines() if p]
    out = []
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in (".build", ".git", ".swiftpm")]
        out += [os.path.relpath(os.path.join(d, f), root) for f in files]
    return out


def code_part(line):
    """The line without its trailing // comment (naive about // inside strings, which only loses a check)."""
    i = line.find("//")
    return line if i < 0 else line[:i]


def lint(root, paths=None):
    hits = []
    for rel in sorted(paths if paths is not None else tracked(root)):
        full = os.path.join(root, rel)
        rules = [r for r in RULES if re.search(r[2], rel) and not (r[3] and re.search(r[3], rel))]
        emoji = bool(EMOJI_PATHS.search(rel)) or bool(EMOJI.search(rel))
        if not rules and not emoji:
            continue
        try:
            with open(full, encoding="utf-8") as f:
                lines = f.read().split("\n")
        except (OSError, UnicodeDecodeError):
            continue
        if EMOJI.search(rel):
            hits.append((rel, 0, "emoji", "an emoji in a filename"))
        block = False
        for n, line in enumerate(lines, 1):
            if emoji and EMOJI.search(line):
                hits.append((rel, n, "emoji", "no emojis in code, docs or filenames"))
            if not rules:
                continue
            stripped = line.strip()
            if block:
                block = "*/" not in stripped
                continue
            if stripped.startswith("/*"):
                block = "*/" not in stripped
                continue
            code = code_part(line)
            if not code.strip():
                continue
            allowed = {}
            for src in (line, lines[n - 2] if n > 1 else ""):
                m = ALLOW.search(src)
                if m:
                    allowed[m.group(1)] = m.group(2)
            for rule, _, _, _, pattern, message in rules:
                if re.search(pattern, code):
                    if rule in allowed:
                        if not allowed[rule]:
                            hits.append((rel, n, rule, "lint:allow without a reason"))
                        continue
                    hits.append((rel, n, rule, message))
    return hits


def self_test():
    import tempfile
    cases = {
        "Sources/Engine/A.swift": [
            ("let t = CACurrentMediaTime()", ["clock"]),
            ("let t = Date()", ["clock"]),
            ("// Date() in a comment", []),
            ("let d = Date(timeIntervalSince1970: 0)", []),
            ("let x = try! f()", ["crash"]),
            ("let y = a as! B // lint:allow crash - checked one line up", []),
            ("// lint:allow crash - unreachable by construction", []),
            ("fatalError(\"x\")", []),
            ("fatalError(\"y\") // lint:allow crash", ["crash"]),
            ("final class C: @unchecked Sendable {}", ["concurrency"]),
            ("let l = MTKTextureLoader(device: d)", ["loader"]),
            ("blit.generateMipmaps(for: t)", ["mips"]),
            ("let q: MTL4CommandQueue", ["metal4"]),
            ("if d.supportsFamily(.apple5) {}", ["family"]),
            ("try d.makeLibrary(source: s, options: nil)", ["shader-source"]),
            ("// for IdleVillage", []),
            ("struct GameStateAdapter {}", []),
            ("let s: GameState", ["agnostic"]),
            ("let ok = !done", []),
        ],
        "Sources/Engine/DisplayLinkAdapter.swift": [("let t = CACurrentMediaTime()", [])],
        "Tests/EngineTests/T.swift": [("try await Task.sleep(for: .seconds(1))", ["sleep"]),
                                      ("let x = try! f()", [])],
        "Package.swift": [(".package(url: \"x\", from: \"1.0.0\"),", ["deps"])],
        "docs/x.md": [("fine", []), ("party \U0001F389", ["emoji"])],
    }
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        for rel, rows in cases.items():
            os.makedirs(os.path.dirname(os.path.join(tmp, rel)), exist_ok=True)
            with open(os.path.join(tmp, rel), "w", encoding="utf-8") as f:
                f.write("\n".join(r[0] for r in rows) + "\n")
        hits = lint(tmp, list(cases))
        total = 0
        for rel, rows in cases.items():
            for n, (text, want) in enumerate(rows, 1):
                total += 1
                got = sorted(h[2] for h in hits if h[0] == rel and h[1] == n)
                if got != sorted(want):
                    bad += 1
                    print("FAIL %s:%d %r: want %s, got %s" % (rel, n, text, want, got))
    print("lint self-test: %d/%d" % (total - bad, total))
    return 1 if bad else 0


def main():
    args = sys.argv[1:]
    if "--self-test" in args:
        sys.exit(self_test())
    if "--rules" in args:
        for rule, enforces, paths, exempt, _, message in RULES:
            print("%-14s %-12s %s%s: %s" % (rule, enforces, paths, " except " + exempt if exempt else "", message))
        print("%-14s %-12s %s" % ("emoji", "CLAUDE.md", "no emojis in code, docs or filenames"))
        return
    root = args[args.index("--root") + 1] if "--root" in args else ROOT
    hits = lint(root)
    for rel, n, rule, message in hits:
        print("%s:%d: [%s] %s" % (rel, n, rule, message))
    print("lint: %d hit(s)" % len(hits))
    sys.exit(1 if hits else 0)


if __name__ == "__main__":
    main()
