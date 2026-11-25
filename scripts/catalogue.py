#!/usr/bin/env python3
"""The test catalogue as data: ids, a ticket's brief, and the id-to-test trace.

  scripts/catalogue.py ids [--section E-HAR]          every id with its kind
  scripts/catalogue.py ticket-ids N                   the ids ticket N must pass, split local / device
  scripts/catalogue.py brief N [--out FILE]           one file with everything ticket N cites
  scripts/catalogue.py trace [--ticket N | --ids-file F] [--xunit X.xml ...] [--tests DIR]
  scripts/catalogue.py --self-test

`brief` is what an agent reads instead of the whole catalogue, Decisions and research: the ticket
body, the catalogue rows of its ids (with each section's method notes), the Decisions it names and
the research sections it names. It also writes `.build/tickets/HE-N-ids.txt` for `trace` and the gate.

`trace` joins catalogue ids to tests. A test carries its id in its function name, because that is
the name xunit reports: a raw identifier (`E-HAR-1 red quad reads back`) or underscores
(`E_HAR_1_redQuad`). Without --xunit it reads the test sources; with it, each id gets
passed / failed / skipped / missing. A local id that is missing, failed or skipped exits 1: skipped
is not passed (E-PROOF-2). A test naming an id the catalogue lacks also exits 1 (a test without a
catalogue id is a catalogue change, CLAUDE.md). Device ids (prefix D, or kind M alone) cannot be
proven on the Mac: they are listed, never counted.

Exit codes: 0 ok, 1 a trace failure, 2 usage or a missing input.
"""
import argparse
import glob
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOGUE = os.path.join(ROOT, "docs", "TestCatalogue.md")
DECISIONS = os.path.join(ROOT, "docs", "Decisions.md")
RESEARCH = os.path.join(ROOT, "docs", "research")

ID = re.compile(r"\b([EDBKCU])-([A-Z]+)-(\d+)\b")
RANGE = re.compile(r"\b([EDBKCU]-[A-Z]+-)(\d+)\.\.(\d+)\b")
SHORT = re.compile(r"\b([EDBKCU]-[A-Z]+-)(\d+)((?:\s*,\s*-\d+)+)")
ROW = re.compile(r"^\|\s*((?:\*\*)?[EDBKCU]-[A-Z]+-\d+(?:\*\*)?)\s*\|(.*)\|\s*$")


def die(msg, code=2):
    print("catalogue: " + msg, file=sys.stderr)
    sys.exit(code)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def id_key(i):
    m = ID.match(i)
    return (m.group(1), m.group(2), int(m.group(3)))


def parse_catalogue(text):
    """-> (rows {id: {section, kind, line}}, sections {title: text}, order [ids])."""
    rows, sections, order = {}, {}, []
    title, buf = None, []
    for line in text.splitlines():
        if line.startswith("## ") or line.startswith("### "):
            if title is not None:
                sections[title] = "\n".join(buf).rstrip()
            title, buf = line.lstrip("# ").strip(), []
            continue
        buf.append(line)
        m = ROW.match(line)
        if m:
            i = m.group(1).strip("*")
            cells = [c.strip() for c in m.group(2).split("|")]
            kind = cells[1] if len(cells) > 1 else ""
            rows[i] = {"section": title, "kind": kind, "line": line}
            order.append(i)
    if title is not None:
        sections[title] = "\n".join(buf).rstrip()
    return rows, sections, order


def expand(text):
    """Every catalogue id a passage names. Parentheses are asides ("E-BLEND-4 moved to ..."), not asks."""
    text = re.sub(r"\([^()]*\)", " ", text)
    out = []

    def add(i):
        if i not in out:
            out.append(i)

    for m in RANGE.finditer(text):
        for n in range(int(m.group(2)), int(m.group(3)) + 1):
            add("%s%d" % (m.group(1), n))
    for m in SHORT.finditer(text):
        add(m.group(1) + m.group(2))
        for n in re.findall(r"-(\d+)", m.group(3)):
            add(m.group(1) + n)
    for m in ID.finditer(RANGE.sub(" ", text)):
        add(m.group(0))
    return sorted(out, key=id_key)


def is_device(i, rows):
    kind = rows.get(i, {}).get("kind", "")
    return i.startswith("D-") or kind.replace(" ", "") == "M"


def body_section(body, heading):
    out, on = [], False
    for line in body.splitlines():
        if line.startswith("## "):
            on = line[3:].strip().lower() == heading.lower()
            continue
        if on:
            out.append(line)
    return "\n".join(out).strip()


def ticket_body(n):
    r = subprocess.run([os.path.join(ROOT, "scripts", "tickets"), "show", str(n), "--body"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        die("scripts/tickets show %s --body failed: %s" % (n, r.stderr.strip()))
    return r.stdout


def ticket_ids(n, rows, body=None):
    body = body if body is not None else ticket_body(n)
    ids = expand(body_section(body, "Must pass"))
    unknown = [i for i in ids if i not in rows]
    local = [i for i in ids if i in rows and not is_device(i, rows)]
    device = [i for i in ids if i in rows and is_device(i, rows)]
    return local, device, unknown


def decisions(text):
    """{D12: paragraph} for every `**Dn. ...**` entry."""
    out = {}
    for m in re.finditer(r"^\*\*(D\d+)\..*?(?=^\*\*D\d+\.|^#{2,3} |\Z)", text, re.S | re.M):
        out[m.group(1)] = m.group(0).rstrip()
    return out


def research_sections(cited):
    """`performance-and-power.md section 5, image-quality.md section 6` -> [(file, heading, text)]."""
    out = []
    for m in re.finditer(r"([a-z-]+\.md)((?:\s+sections?\s+[\d,\sand-]+)?)", cited):
        path = os.path.join(RESEARCH, m.group(1))
        if not os.path.isfile(path):
            continue
        nums = re.findall(r"\d+", m.group(2))
        text = read(path)
        if not nums:
            out.append((m.group(1), "(whole file cited; read the sections you need)", ""))
            continue
        for num in nums:
            s = re.search(r"^## %s\. .*?(?=^## |\Z)" % re.escape(num), text, re.S | re.M)
            if s:
                out.append((m.group(1), s.group(0).splitlines()[0], s.group(0).rstrip()))
    return out


def brief(n, out_path):
    rows, sections, order = parse_catalogue(read(CATALOGUE))
    body = ticket_body(n)
    local, device, unknown = ticket_ids(n, rows, body)
    must = body_section(body, "Must pass")
    parts = ["# Brief for HE-%s" % n, "",
             "Assembled by `scripts/catalogue.py brief %s`. It quotes the ticket, the catalogue rows, the" % n,
             "Decisions and the research sections the ticket cites. Read the originals only where this is not enough.",
             "", "## Ticket", "", re.sub(r"(?m)^## ", "### ", body.strip()), "", "## Catalogue rows", ""]
    by_section = {}
    for i in local + device:
        by_section.setdefault(rows[i]["section"], []).append(i)
    for title, ids in by_section.items():
        parts.append("### " + title)
        text = sections[title]
        intro = [l for l in text.splitlines() if l.strip() and not l.startswith("|")]
        if intro:
            parts += ["", "\n".join(intro)]
        header = [l for l in text.splitlines() if l.startswith("|")][:2]
        parts += [""] + header + [rows[i]["line"] for i in ids] + [""]
    for name in re.findall(r"\*([A-Z][^*]+)\*", must):
        if name in sections:
            parts += ["### " + name, "", sections[name], ""]
    if device:
        parts += ["Device ids (not provable on the Mac; list them under *Device checks* in Evidence): " + ", ".join(device), ""]
    if unknown:
        parts += ["**Not in the catalogue:** " + ", ".join(unknown) +
                  ". The ticket is stale or the catalogue is; say which in the plan.", ""]
    dec = decisions(read(DECISIONS))
    cited = re.findall(r"\bD\d+\b", body_section(body, "Decisions"))
    if cited:
        parts += ["## Decisions", ""]
        for d in dict.fromkeys(cited):
            parts += [dec.get(d, "**%s** is not in docs/Decisions.md." % d), ""]
    res = research_sections(body_section(body, "Research"))
    if res:
        parts += ["## Research", ""]
        for fname, heading, text in res:
            parts += ["### docs/research/%s: %s" % (fname, heading.lstrip("# ")), ""]
            if text:
                parts += ["\n".join(text.splitlines()[1:]).strip(), ""]
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(parts).rstrip() + "\n")
    ids_path = os.path.join(os.path.dirname(out_path), "HE-%s-ids.txt" % n)
    with open(ids_path, "w", encoding="utf-8") as f:
        f.write("".join("%s local\n" % i for i in local) + "".join("%s device\n" % i for i in device))
    size = os.path.getsize(out_path)
    print("brief: %s (%d bytes, %d local ids, %d device ids%s)" % (
        os.path.relpath(out_path, ROOT), size, len(local), len(device),
        ", NOT IN CATALOGUE: " + " ".join(unknown) if unknown else ""))
    print("ids: " + os.path.relpath(ids_path, ROOT))


def ids_in_name(name):
    """Catalogue ids in a test's function name: `E-HAR-1 red quad`() or E_HAR_1_redQuad()."""
    norm = name.replace("_", "-").upper()
    return sorted({m.group(0) for m in ID.finditer(norm)}, key=id_key)


FUNC = re.compile(r"\bfunc\s+(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)\s*[(<]")


def tests_from_sources(tests_dir):
    """{id: [test name]} from the function names under the tests directory."""
    out = {}
    for path in sorted(glob.glob(os.path.join(tests_dir, "**", "*.swift"), recursive=True)):
        for m in FUNC.finditer(read(path)):
            for i in ids_in_name(m.group(1)):
                out.setdefault(i, []).append(m.group(1).strip("`"))
    return out


def tests_from_xunit(paths):
    """{id: {test name: passed|failed|skipped}}, plus the same for tests with no id."""
    by_id, plain = {}, {}
    for path in paths:
        if not os.path.isfile(path) or os.path.getsize(path) == 0:
            continue
        for case in ET.parse(path).getroot().iter("testcase"):
            name = case.get("name", "")
            if case.find("failure") is not None or case.find("error") is not None:
                status = "failed"
            elif case.find("skipped") is not None:
                status = "skipped"
            else:
                status = "passed"
            full = "%s.%s" % (case.get("classname", ""), name)
            ids = ids_in_name(name)
            for i in ids:
                by_id.setdefault(i, {})[full] = status
            if not ids:
                plain[full] = status
    return by_id, plain


def read_ids_file(path):
    local, device = [], []
    for line in read(path).split("\n"):
        p = line.split()
        if p:
            (device if len(p) > 1 and p[1] == "device" else local).append(p[0])
    return local, device


def trace(args):
    rows, _, _ = parse_catalogue(read(CATALOGUE))
    local, device = [], []
    if args.ticket:
        local, device, unknown = ticket_ids(args.ticket, rows)
        if unknown:
            print("trace: ticket names ids the catalogue lacks: " + " ".join(unknown))
    elif args.ids_file:
        local, device = read_ids_file(args.ids_file)
    bad = 0
    src = tests_from_sources(args.tests)
    foreign = sorted((i for i in src if i not in rows), key=id_key)
    if foreign:
        bad = 1
        for i in foreign:
            print("trace: FAIL %s is not in the catalogue (test %s)" % (i, src[i][0]))
    if args.xunit:
        by_id, plain = tests_from_xunit(args.xunit)
        counts = {"passed": 0, "failed": 0, "skipped": 0}
        for d in list(by_id.values()) + [plain]:
            for s in d.values():
                counts[s] += 1
        print("trace: %d tests: %d passed, %d failed, %d skipped; %d catalogue ids have a test" % (
            sum(counts.values()), counts["passed"], counts["failed"], counts["skipped"], len(by_id)))
        for i in local:
            res = by_id.get(i)
            if not res:
                state = "missing" if i not in src else "not-run"
            elif "failed" in res.values():
                state = "failed"
            elif "skipped" in res.values():
                state = "skipped"
            else:
                state = "passed"
            if state != "passed":
                bad = 1
                print("trace: FAIL %s %s%s" % (i, state, "" if not res else " (" + ", ".join(
                    n.split(".")[-1] for n, s in res.items() if s != "passed") + ")"))
        if local and not bad:
            print("trace: all %d local ids passed, none skipped" % len(local))
        skipped = sorted(n for d in list(by_id.values()) + [plain] for n, s in d.items() if s == "skipped")
        if skipped:
            print("trace: skipped (not passed): " + ", ".join(dict.fromkeys(skipped)))
    else:
        missing = [i for i in local if i not in src]
        for i in missing:
            bad = 1
            print("trace: FAIL %s has no test" % i)
        print("trace: %d catalogue ids have a test in %s%s" % (
            len([i for i in src if i in rows]), os.path.relpath(args.tests, ROOT),
            "" if not local else "; %d of the ticket's %d local ids" % (len(local) - len(missing), len(local))))
    if device:
        print("trace: device ids, not provable here: " + " ".join(device))
    return bad


def self_test():
    cat = ("## Golden-image method\n\n- Render offscreen.\n\n## E. Engine suite\n\n### E-HAR: harness\n\nNote.\n\n"
           "| Id | Requirement | Kind | Pass |\n|---|---|---|---|\n"
           "| E-HAR-1 | Headless | G | reads back |\n| E-HAR-2 | Time | P+S | identical |\n"
           "| E-HAR-5 | Skip | P | skipped |\n| E-QUAL-7 | Banding | M | on device |\n"
           "| **E-COL-5** | Oracle | G | FLIP |\n## D. Device suite\n\n| Id | R | Kind | Pass |\n|---|---|---|---|\n"
           "| D-PACE-1 | Pace | M | x |\n")
    rows, sections, order = parse_catalogue(cat)
    checks = [
        ("rows parsed", order == ["E-HAR-1", "E-HAR-2", "E-HAR-5", "E-QUAL-7", "E-COL-5", "D-PACE-1"]),
        ("kind read", rows["E-HAR-2"]["kind"] == "P+S" and rows["E-COL-5"]["section"] == "E-HAR: harness"),
        ("section kept", "Render offscreen" in sections["Golden-image method"]),
        ("range", expand("E-HAR-1..3, E-VAL-1") == ["E-HAR-1", "E-HAR-2", "E-HAR-3", "E-VAL-1"]),
        ("aside dropped", expand("E-BLEND-1..2, E-BLEND-5 (E-BLEND-4 moved to C-MAN-2, D21)") ==
         ["E-BLEND-1", "E-BLEND-2", "E-BLEND-5"]),
        ("short form", expand("E-QUAL-1, -2, -4") == ["E-QUAL-1", "E-QUAL-2", "E-QUAL-4"]),
        ("sorted by number", expand("E-TEX-10, E-TEX-9") == ["E-TEX-9", "E-TEX-10"]),
        ("device by prefix and kind", is_device("D-PACE-1", rows) and is_device("E-QUAL-7", rows)
         and not is_device("E-HAR-2", rows)),
        ("raw identifier", ids_in_name("`E-HAR-1 red quad`") == ["E-HAR-1"]),
        ("underscores", ids_in_name("e_har_5_gpuSkipped") == ["E-HAR-5"]),
        ("two ids", ids_in_name("E_HAR_1_and_E_HAR_12") == ["E-HAR-1", "E-HAR-12"]),
        ("no id", ids_in_name("clampHigh") == []),
        ("ticket ids", ticket_ids(0, rows, "## Goal\nx\n## Must pass\n\nE-HAR-1..2, D-PACE-1, E-NOPE-1 in x\n\n## Done when\n")
         == (["E-HAR-1", "E-HAR-2"], ["D-PACE-1"], ["E-NOPE-1"])),
        ("decisions", list(decisions("## Decided\n\n**D2. A.** x\ny\n\n**D12. B.** z\n\n## Open\n\n**D1. C.** q\n"))
         == ["D2", "D12", "D1"]),
        ("func regex", FUNC.findall("@Test func `E-HAR-1 a b`() {}\n  func E_X_2_y<T>(") == ["`E-HAR-1 a b`", "E_X_2_y"]),
    ]
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        x = os.path.join(tmp, "x.xml")
        with open(x, "w") as f:
            f.write('<testsuites><testsuite><testcase classname="T.S" name="`E-HAR-1 a`()"/>'
                    '<testcase classname="T.S" name="E_HAR_2_b()"><failure message="m"/></testcase>'
                    '<testcase classname="T.S" name="e_har_5_c()"><skipped/></testcase>'
                    '<testcase classname="T.S" name="plain()"/></testsuite></testsuites>')
        by_id, plain = tests_from_xunit([x, os.path.join(tmp, "none.xml")])
        checks.append(("xunit statuses", by_id["E-HAR-1"] == {"T.S.`E-HAR-1 a`()": "passed"}
                       and list(by_id["E-HAR-2"].values()) == ["failed"]
                       and list(by_id["E-HAR-5"].values()) == ["skipped"] and plain == {"T.S.plain()": "passed"}))
    failed = [name for name, ok in checks if not ok]
    for name in failed:
        print("FAIL " + name)
    print("catalogue self-test: %d/%d" % (len(checks) - len(failed), len(checks)))
    return 1 if failed else 0


def main():
    if "--self-test" in sys.argv[1:]:
        sys.exit(self_test())
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("ids")
    s.add_argument("--section")
    s = sub.add_parser("ticket-ids")
    s.add_argument("n")
    s = sub.add_parser("brief")
    s.add_argument("n")
    s.add_argument("--out")
    s = sub.add_parser("trace")
    s.add_argument("--ticket")
    s.add_argument("--ids-file")
    s.add_argument("--xunit", nargs="*", default=[])
    s.add_argument("--tests", default=os.path.join(ROOT, "Tests"))
    a = p.parse_args()
    if a.cmd == "ids":
        rows, _, order = parse_catalogue(read(CATALOGUE))
        for i in order:
            if not a.section or i.startswith(a.section + "-"):
                print("%s\t%s\t%s" % (i, rows[i]["kind"], "device" if is_device(i, rows) else "local"))
    elif a.cmd == "ticket-ids":
        rows, _, _ = parse_catalogue(read(CATALOGUE))
        local, device, unknown = ticket_ids(a.n, rows)
        print("local: " + " ".join(local))
        print("device: " + " ".join(device))
        if unknown:
            print("not in catalogue: " + " ".join(unknown))
    elif a.cmd == "brief":
        brief(a.n, a.out or os.path.join(ROOT, ".build", "tickets", "HE-%s-brief.md" % a.n))
    elif a.cmd == "trace":
        sys.exit(trace(a))


if __name__ == "__main__":
    main()
