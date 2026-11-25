#!/usr/bin/env python3
"""Extract one milestone's process metrics for /milestone:retro (docs/retros/README.md).

Usage:
  scripts/retro/extract.py <milestone> [--since ISO] [--until ISO] [--no-tickets]
  scripts/retro/extract.py --hook          SubagentStop hook: reads the hook JSON on stdin
  scripts/retro/extract.py --self-test

Reads, on this Mac only (a milestone runs on one Mac):
  .build/auto-loop/run.log            the loop's events (windows: `loop start <M>` .. `loop end`)
  .build/gate/<run>/                  gate runs started inside the milestone's span
  .build/retro/agents.jsonl           per-agent records the hook kept (transcripts expire)
  ~/.claude/projects/<checkout>*/     session and subagent transcripts of every checkout
  scripts/tickets list --milestone    the milestone's tickets (skipped with --no-tickets)
`.build/` is read in every checkout `git worktree list` names (a loop logs where it ran);
the hook's records and the outliers live in the main checkout's.

Writes:
  docs/retros/<M>.metrics.json        committed: numbers only, no transcript paths
  .build/retro/<M>/outliers.md        not committed: what to look at, with <file>:<line>

Attribution of an API call:
  subagent                -> its ticket (first HE-NNN in the agent's description or prompt)
  main session that ran /ticket:auto, in a loop window -> loop (the orchestrator)
  main session, on a milestone ticket's branch   -> attended, that ticket
  main session, otherwise inside the span        -> overhead, by git branch
`tok_eq` is one comparable number per call, in input-token equivalents:
input + 1.25 * cache write + 0.1 * cache read + 5 * output. It is a ratio, not a bill.
"""
import collections
import datetime
import glob
import json
import os
import re
import statistics
import subprocess
import sys

IV = re.compile(r"HE-(\d+)")
PEAK_CTX = 150_000          # an agent above this is an outlier
ORCH_CTX = 200_000          # an orchestrator session above this is an outlier
REPEAT = 3                  # the same command or file read this often in one agent
MAX_ERRORS = 60             # tool errors listed in outliers.md


def ts(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def tok_eq(u):
    return round(u["in"] + 1.25 * u["cw"] + 0.1 * u["cr"] + 5 * u["out"])


def new_usage():
    return {"calls": 0, "in": 0, "cw": 0, "cr": 0, "out": 0, "peak_ctx": 0}


def add_call(acc, usage):
    i, cw = usage.get("input_tokens", 0), usage.get("cache_creation_input_tokens", 0)
    cr, out = usage.get("cache_read_input_tokens", 0), usage.get("output_tokens", 0)
    acc["calls"] += 1
    acc["in"] += i
    acc["cw"] += cw
    acc["cr"] += cr
    acc["out"] += out
    acc["peak_ctx"] = max(acc["peak_ctx"], i + cw + cr)
    return i + cw + cr


def entries(path):
    """(line number, entry) for every JSON line that parses."""
    with open(path, errors="replace") as f:
        for n, line in enumerate(f, 1):
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if isinstance(o, dict):
                yield n, o


def blocks(o):
    c = (o.get("message") or {}).get("content")
    return c if isinstance(c, list) else []


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(b.get("text", "") for b in content if isinstance(b, dict))
    return ""


# ---------------------------------------------------------------- run logs

def parse_log(path):
    rows = []
    if not os.path.exists(path):
        return rows
    for line in open(path, errors="replace"):
        p = line.rstrip("\n").split(" ", 3)
        if len(p) < 3:
            continue
        try:
            t = ts(p[0])
        except ValueError:
            continue
        rows.append({"t": t, "who": p[1], "event": p[2], "detail": p[3] if len(p) > 3 else ""})
    return rows


def code_windows(rows, milestone):
    """[(start, end, rows)] for each `loop start` .. `loop end` that names the milestone."""
    out, cur = [], None
    for r in rows:
        if r["who"] == "loop" and r["event"] == "start":
            if cur:
                out.append(cur)
            cur = {"rows": [r], "names": r["detail"]}
        elif cur:
            cur["rows"].append(r)
            if r["who"] == "loop" and r["event"] == "end":
                cur["names"] += " " + r["detail"]
                out.append(cur)
                cur = None
    if cur:
        out.append(cur)
    token = re.compile(r"(^|\s)%s(\s|$)" % re.escape(milestone))
    return [(w["rows"][0]["t"], w["rows"][-1]["t"], w["rows"]) for w in out if token.search(w["names"])]


def ticket_events(rows):
    """Per ticket: what the loop logged about it."""
    tickets = {}
    for r in rows:
        m = IV.fullmatch(r["who"])
        if not m:
            continue
        k = "HE-" + m.group(1)
        t = tickets.setdefault(k, {"first": r["t"], "last": r["t"], "rounds": [], "fixes": 0,
                                   "full_runs": [], "infra": 0, "outcome": None, "notes": []})
        t["last"] = r["t"]
        e, d = r["event"], r["detail"]
        if e == "claim":
            t.setdefault("claimed", r["t"])
        elif e == "implement-done":
            t.setdefault("implemented", r["t"])
        elif e == "review":
            p = d.split()
            if len(p) >= 2 and p[0].isdigit():
                findings = int(p[2]) if len(p) > 2 and p[2].isdigit() else None
                t["rounds"].append({"round": int(p[0]), "verdict": p[1], "findings": findings})
        elif e == "fix":
            t["fixes"] += 1
        elif e == "full":
            p = d.split()
            t["full_runs"].append({"run": os.path.basename(p[0]) if p else "", "exit": p[1] if len(p) > 1 else ""})
        elif e in ("infra", "halt"):
            t["infra"] += 1
            t["notes"].append("%s %s %s" % (iso(r["t"]), e, d))
        elif e in ("shipped", "parked", "blocked", "landed-unapproved"):
            t["outcome"] = "landed" if e == "landed-unapproved" else e
            if e not in ("shipped", "landed-unapproved"):
                t["notes"].append("%s %s %s" % (iso(r["t"]), e, d))
        elif e in ("resumed", "stashed", "rebase", "rebased", "retest", "owner", "challenge", "approved"):
            t["notes"].append("%s %s %s" % (iso(r["t"]), e, d))
    for t in tickets.values():
        t["wall_s"] = round(t["last"] - t["first"])
        if "claimed" in t and "implemented" in t:
            t["implement_s"] = round(t["implemented"] - t["claimed"])
        for k in ("first", "last", "claimed", "implemented"):
            if k in t:
                t[k] = iso(t[k])
    return tickets


# ---------------------------------------------------------------- transcripts

def agent_stats(path, meta=None, want_pointers=False):
    """One subagent transcript -> its record. Also what the SubagentStop hook stores."""
    meta = meta or {}
    use = new_usage()
    seen, tools, heads, cmds, reads = set(), collections.Counter(), collections.Counter(), collections.Counter(), collections.Counter()
    pending, errors, first, last, turns, prompt, sleeps = {}, [], None, None, 0, "", 0
    for n, o in entries(path):
        t = o.get("timestamp")
        if t:
            t = ts(t)
            first = first or t
            last = t
        kind = o.get("type")
        if kind == "assistant":
            msg = o.get("message") or {}
            mid = msg.get("id") or o.get("requestId") or o.get("uuid")
            if mid not in seen:
                seen.add(mid)
                add_call(use, msg.get("usage") or {})
            for b in blocks(o):
                if b.get("type") != "tool_use":
                    continue
                name, inp = b.get("name", "?"), b.get("input") or {}
                tools[name] += 1
                label = name
                if name == "Bash":
                    cmd = " ".join(str(inp.get("command", "")).split())
                    cmds[cmd[:300]] += 1
                    heads[" ".join(cmd.split()[:2])[:40]] += 1
                    sleeps += 1 if re.search(r"(^|[;&|]\s*)sleep \d", cmd) else 0
                    label = "Bash: " + cmd[:160]
                elif name == "Read":
                    reads[str(inp.get("file_path", ""))] += 1
                    label = "Read: " + str(inp.get("file_path", ""))
                pending[b.get("id")] = label
        elif kind == "user":
            c = (o.get("message") or {}).get("content")
            if isinstance(c, str) or not any(b.get("type") == "tool_result" for b in blocks(o)):
                turns += 1
                prompt = prompt or text_of(c)
            for b in blocks(o):
                if b.get("type") == "tool_result" and b.get("is_error"):
                    errors.append({"line": n, "tool": pending.get(b.get("tool_use_id"), "?"),
                                   "error": " ".join(text_of(b.get("content")).split())[:300]})
    desc = meta.get("description", "")
    m = IV.search(desc) or IV.search(prompt[:400])
    rec = {
        "agent_id": os.path.basename(path)[len("agent-"):-len(".jsonl")],
        "type": meta.get("agentType", "?"),
        "description": desc[:120],
        "ticket": "HE-" + m.group(1) if m else None,
        "start": iso(first) if first else None,
        "end": iso(last) if last else None,
        "wall_s": round(last - first) if first else 0,
        "turns": turns,
        "tool_calls": sum(tools.values()),
        "tools": dict(tools.most_common()),
        "tool_errors": len(errors),
        "sleeps": sleeps,
        "bash_heads": dict(heads.most_common(8)),
        "repeated_commands": sum(1 for v in cmds.values() if v >= REPEAT),
        "reread_files": sum(1 for v in reads.values() if v >= REPEAT),
        **use,
    }
    rec["tok_eq"] = tok_eq(rec)
    if want_pointers:
        rec["_errors"] = errors
        rec["_repeats"] = [(c, v) for c, v in cmds.most_common(5) if v >= REPEAT]
        rec["_rereads"] = [(f, v) for f, v in reads.most_common(5) if v >= REPEAT]
    return rec


def scan_session(path, in_loop, in_span, branch_ticket, calls_seen):
    """One main-session transcript -> its per-bucket usage inside the milestone."""
    buckets = collections.defaultdict(new_usage)
    ctx = collections.defaultdict(list)
    tools, waits, pending = collections.Counter(), collections.Counter(), {}
    errors, compactions, cost, commands, first, last = [], 0, None, collections.Counter(), None, None
    runs_loop = False
    for n, o in entries(path):
        kind = o.get("type")
        if kind == "user" and not runs_loop:
            runs_loop = bool(re.search(r"/?ticket:auto\b", text_of((o.get("message") or {}).get("content"))[:2000]))
        if kind == "cost-state":
            cost = o.get("totalCostUSD")
            continue
        raw = o.get("timestamp")
        if not raw:
            continue
        t = ts(raw)
        ticket = branch_ticket(o.get("gitBranch") or "")
        if runs_loop and in_loop(t):
            bucket = "loop"
        elif ticket:
            bucket = "attended:" + ticket
        elif in_span(t):
            bucket = "overhead:" + (o.get("gitBranch") or "?")
        else:
            continue
        first = first or t
        last = t
        if kind == "system" and o.get("subtype") == "compact_boundary":
            compactions += 1
        elif kind == "assistant":
            msg = o.get("message") or {}
            mid = msg.get("id") or o.get("requestId") or o.get("uuid")
            if mid not in calls_seen:
                calls_seen.add(mid)
                ctx[bucket].append(add_call(buckets[bucket], msg.get("usage") or {}))
            for b in blocks(o):
                if b.get("type") == "tool_use":
                    tools[b.get("name", "?")] += 1
                    pending[b.get("id")] = (b.get("name", "?"), t)
        elif kind == "user":
            c = (o.get("message") or {}).get("content")
            for name in re.findall(r"<command-name>(/[\w:-]+)", c if isinstance(c, str) else ""):
                commands[name] += 1
            for b in blocks(o):
                if b.get("type") != "tool_result":
                    continue
                name, started = pending.pop(b.get("tool_use_id"), ("?", t))
                waits[name] += t - started
                if b.get("is_error"):
                    errors.append({"line": n, "tool": name,
                                   "error": " ".join(text_of(b.get("content")).split())[:300]})
    if not buckets:
        return None
    out = {"session": os.path.basename(path)[:-len(".jsonl")], "start": iso(first), "end": iso(last),
           "cost_usd_whole_session": round(cost, 2) if cost else None, "compactions": compactions,
           "commands": dict(commands), "tools": dict(tools.most_common()),
           "tool_wait_s": {k: round(v) for k, v in waits.most_common() if v >= 60},
           "tool_errors": len(errors), "buckets": {}, "_errors": errors, "_path": path}
    for k, u in buckets.items():
        u["median_ctx"] = round(statistics.median(ctx[k])) if ctx[k] else 0
        u["tok_eq"] = tok_eq(u)
        out["buckets"][k] = u
    return out


# ---------------------------------------------------------------- the milestone

def main_checkout():
    common = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True, check=True).stdout.strip()
    return os.path.dirname(common)


def worktrees():
    out = subprocess.run(["git", "worktree", "list", "--porcelain"], capture_output=True, text=True, check=True).stdout
    return [line[len("worktree "):] for line in out.splitlines() if line.startswith("worktree ")]


def project_dirs(main, root):
    slug = re.sub(r"[^A-Za-z0-9]", "-", main)
    return [d for d in sorted(glob.glob(os.path.join(root, slug + "*")))
            if os.path.basename(d) == slug or os.path.basename(d).startswith(slug + "-")]


def milestone_tickets(main, milestone):
    try:
        p = subprocess.run([os.path.join(main, "scripts/tickets"), "list", "--milestone", milestone,
                            "--state", "all", "--json"], capture_output=True, text=True, timeout=120, cwd=main)
        rows = json.loads(p.stdout) if p.returncode == 0 else []
    except (OSError, ValueError, subprocess.TimeoutExpired):
        rows = []
    return {"HE-%d" % r["number"]: r for r in rows if r.get("kind") == "ticket"}


def test_runs(build, in_span):
    out = []
    for d in sorted(glob.glob(os.path.join(build, "gate", "2*"))):
        meta = {}
        try:
            for line in open(os.path.join(d, "meta.txt")):
                k, _, v = line.strip().partition("=")
                meta[k] = v
            started = float(meta.get("started", 0))
        except (OSError, ValueError):
            continue
        if not in_span(started):
            continue
        ex = os.path.join(d, "exit.txt")
        done = os.path.exists(ex)
        steps = {}
        try:
            summary = json.load(open(os.path.join(d, "summary.json")))
            steps = {"steps_s": {x["step"]: x["seconds"] for x in summary.get("steps", []) if x.get("seconds")},
                     "failed_steps": [x["step"] for x in summary.get("steps", []) if x.get("status") == "FAIL"],
                     "survivors": len(summary.get("survivors", [])), "flaky": len(summary.get("flaky", [])),
                     "diffcov": (summary.get("diffcov") or {}).get("percent"), "ticket": summary.get("ticket")}
        except (OSError, ValueError):
            pass
        out.append({**steps, "run": os.path.basename(d), "start": iso(started),
                    "wall_s": round(os.path.getmtime(ex) - started) if done else None,
                    "exit": open(ex).read().strip() if done else None,
                    "full": meta.get("tier", "") == "full", "filters": meta.get("tier", "")[:120],
                    "head": meta.get("head", "")[:8]})
    return out


def extract(milestone, main, projects_root, since=None, until=None, tickets=None, checkouts=None):
    build = os.path.join(main, ".build")
    builds = [os.path.join(c, ".build") for c in (checkouts or [main])]
    windows, loop_rows = [], []
    for b in builds:
        for start, end, rows in code_windows(parse_log(os.path.join(b, "auto-loop", "run.log")), milestone):
            windows.append((start, end, "code"))
            loop_rows += rows
    windows.sort()
    loop_rows.sort(key=lambda r: r["t"])
    logged = ticket_events(loop_rows)
    tickets = tickets if tickets is not None else {}
    ticket_ids = set(logged) | set(tickets)

    lo = ts(since) if since else min([w[0] for w in windows], default=None)
    hi = ts(until) if until else max([w[1] for w in windows], default=None)
    if lo is None or hi is None:
        raise SystemExit("extract: no run log names %s; pass --since and --until" % milestone)

    def in_span(t):
        return lo <= t <= hi

    def in_loop(t):
        return any(a <= t <= b for a, b, _ in windows)

    def branch_ticket(branch):
        m = IV.search(branch)
        return "HE-" + m.group(1) if m and "HE-" + m.group(1) in ticket_ids else None

    sessions, agents, calls_seen, agents_seen = [], [], set(), set()
    for d in project_dirs(main, projects_root):
        for path in sorted(glob.glob(os.path.join(d, "*.jsonl"))):
            if os.path.getmtime(path) < lo - 86400 and not ticket_ids:
                continue
            s = scan_session(path, in_loop, in_span, branch_ticket, calls_seen)
            if s:
                sessions.append(s)
            for ap in sorted(glob.glob(os.path.join(path[:-len(".jsonl")], "subagents", "agent-*.jsonl"))):
                if os.path.basename(ap) in agents_seen:
                    continue
                try:
                    meta = json.load(open(ap[:-len(".jsonl")] + ".meta.json"))
                except (OSError, ValueError):
                    meta = {}
                a = agent_stats(ap, meta, want_pointers=True)
                if not a["start"]:
                    continue
                if not (a["ticket"] in ticket_ids or in_span(ts(a["start"]))):
                    continue
                agents_seen.add(os.path.basename(ap))
                a["track"] = "loop" if in_loop(ts(a["start"])) else "attended"
                a["_path"] = ap
                agents.append(a)

    # Agents whose transcripts are gone but whose record the hook kept.
    have = {a["agent_id"] for a in agents}
    for _, a in entries(os.path.join(build, "retro", "agents.jsonl")) if os.path.exists(os.path.join(build, "retro", "agents.jsonl")) else []:
        if a.get("agent_id") in have or not a.get("start"):
            continue
        if a.get("ticket") in ticket_ids or in_span(ts(a["start"])):
            have.add(a["agent_id"])
            a["track"] = "loop" if in_loop(ts(a["start"])) else "attended"
            a["source"] = "hook"
            agents.append(a)

    by_type = {}
    for name in sorted({a["type"] for a in agents}):
        group = [a for a in agents if a["type"] == name]
        eq = [a["tok_eq"] for a in group]
        by_type[name] = {
            "n": len(group), "calls": sum(a["calls"] for a in group),
            "tok_eq": sum(eq), "median_tok_eq": round(statistics.median(eq)), "max_tok_eq": max(eq),
            "out": sum(a["out"] for a in group), "cr": sum(a["cr"] for a in group), "cw": sum(a["cw"] for a in group),
            "max_peak_ctx": max(a["peak_ctx"] for a in group),
            "wall_s": sum(a["wall_s"] for a in group), "tool_calls": sum(a["tool_calls"] for a in group),
            "tool_errors": sum(a["tool_errors"] for a in group), "sleeps": sum(a["sleeps"] for a in group),
        }

    per_ticket = {}
    for k in sorted(ticket_ids, key=lambda s: int(s[3:])):
        mine = [a for a in agents if a["ticket"] == k]
        attended = sum(s["buckets"].get("attended:" + k, {}).get("tok_eq", 0) for s in sessions)
        if not mine and not attended and k not in logged:
            continue
        row = dict(logged.get(k, {}))
        if k in tickets:
            row.update({f: tickets[k].get(f) for f in ("title", "type", "effort", "risk", "stage")})
        row["agents"] = {t: sum(1 for a in mine if a["type"] == t) for t in sorted({a["type"] for a in mine})}
        row["agent_tok_eq"] = sum(a["tok_eq"] for a in mine)
        row["attended_tok_eq"] = attended
        row["agent_tool_errors"] = sum(a["tool_errors"] for a in mine)
        per_ticket[k] = row

    totals = collections.Counter()
    overhead = collections.Counter()
    for s in sessions:
        for k, u in s["buckets"].items():
            totals["orchestrator" if k == "loop" else k.split(":")[0]] += u["tok_eq"]
            if k.startswith("overhead:"):
                overhead[k[len("overhead:"):]] += u["tok_eq"]
    totals["agents"] = sum(a["tok_eq"] for a in agents)

    runs = sorted((r for b in builds for r in test_runs(b, in_span)), key=lambda r: r["start"])
    shipped_blind = sorted(k for k, t in logged.items() if t.get("outcome") == "shipped"
                           and not any(a["ticket"] == k for a in agents))
    metrics = {
        "milestone": milestone,
        "span": {"start": iso(lo), "end": iso(hi)},
        "loop_windows": [{"track": tr, "start": iso(a), "end": iso(b), "hours": round((b - a) / 3600, 1)}
                         for a, b, tr in windows],
        "coverage": {"sessions": len(sessions), "agents": len(agents),
                     "agents_from_hook_only": sum(1 for a in agents if a.get("source") == "hook"),
                     "shipped_without_transcripts": shipped_blind},
        "tok_eq_totals": dict(totals),
        "outcomes": dict(collections.Counter(t.get("outcome") or "open" for t in logged.values())),
        "review_rounds": dict(collections.Counter(str(len(t["rounds"])) for t in logged.values() if t["rounds"])),
        "agent_types": by_type,
        "tickets": per_ticket,
        "sessions": [{k: v for k, v in s.items() if not k.startswith("_")} for s in sessions],
        "overhead_by_branch": dict(overhead.most_common(12)),
        "test_runs": {"n": len(runs), "full": sum(1 for r in runs if r["full"]),
                      "red": sum(1 for r in runs if r["exit"] not in ("0", None)),
                      "wall_s": sum(r["wall_s"] or 0 for r in runs), "runs": runs},
        "agents": [{k: v for k, v in a.items() if not k.startswith("_")}
                   for a in sorted(agents, key=lambda a: a["start"])],
    }
    return metrics, outliers(milestone, metrics, sessions, agents, logged)


def outliers(milestone, metrics, sessions, agents, logged):
    """Markdown: where a reader should look, each with the evidence's place on disk."""
    o = ["# Outliers for %s" % milestone, "",
         "Pointers are `<transcript>:<line>`; read a few lines around each, not the file.", ""]

    o += ["## Tickets that did not go straight through", ""]
    for k, t in sorted(logged.items()):
        if len(t["rounds"]) > 1 or t["notes"] or t.get("outcome") not in ("shipped", "submitted"):
            rounds = ", ".join("%s %s (%s)" % (r["round"], r["verdict"], r["findings"]) for r in t["rounds"])
            o.append("- %s: outcome %s; rounds: %s; %d fix(es); wall %dm" %
                     (k, t.get("outcome") or "open", rounds or "none", t["fixes"], t["wall_s"] // 60))
            o += ["  - " + n for n in t["notes"]]
    o += ["", "## Agents far above their type", ""]
    for a in sorted(agents, key=lambda a: -a["tok_eq"]):
        med = metrics["agent_types"][a["type"]]
        heavy = med["n"] >= 4 and a["tok_eq"] > 1.5 * med["median_tok_eq"]
        if heavy or a["peak_ctx"] > PEAK_CTX:
            o.append("- %s %s (%s): tok_eq %d against a median of %d, peak context %d, %d calls, %d turns, %dm -- %s" %
                     (a["type"], a["agent_id"], a["ticket"] or a["description"], a["tok_eq"], med["median_tok_eq"],
                      a["peak_ctx"], a["calls"], a["turns"], a["wall_s"] // 60, a.get("_path", "transcript gone")))
    o += ["", "## Orchestrator sessions", ""]
    for s in sessions:
        peak = max(u["peak_ctx"] for u in s["buckets"].values())
        if peak > ORCH_CTX or s["compactions"]:
            o.append("- %s: peak context %d, %d compaction(s), waits %s -- %s" %
                     (s["session"], peak, s["compactions"], s["tool_wait_s"], s["_path"]))
    o += ["", "## Repeated work inside one agent", ""]
    for a in agents:
        for cmd, n in a.get("_repeats", []):
            o.append("- %s %s (%s): %dx `%s` -- %s" % (a["type"], a["agent_id"], a["ticket"], n, cmd[:140], a["_path"]))
        for f, n in a.get("_rereads", []):
            o.append("- %s %s (%s): read %dx %s -- %s" % (a["type"], a["agent_id"], a["ticket"], n, f, a["_path"]))
        if a["sleeps"] >= REPEAT:
            o.append("- %s %s (%s): %d sleep polls" % (a["type"], a["agent_id"], a["ticket"], a["sleeps"]))
    o += ["", "## Tool errors", ""]
    errs = [(a["type"], a["ticket"], a["_path"], e) for a in agents for e in a.get("_errors", [])]
    errs += [("orchestrator", None, s["_path"], e) for s in sessions for e in s["_errors"]]
    for who, ticket, path, e in errs[:MAX_ERRORS]:
        o.append("- %s%s: `%s` -> %s -- %s:%d" % (who, " (%s)" % ticket if ticket else "", e["tool"][:120],
                                                  e["error"][:200], path, e["line"]))
    if len(errs) > MAX_ERRORS:
        o.append("- ... and %d more" % (len(errs) - MAX_ERRORS))
    o += ["", "## Test runs", ""]
    for r in metrics["test_runs"]["runs"]:
        if r["exit"] != "0":
            o.append("- %s: exit %s, %s, head %s" % (r["run"], r["exit"], "full" if r["full"] else r["filters"], r["head"]))
    return "\n".join(o) + "\n"


# ---------------------------------------------------------------- entry points

def hook():
    """SubagentStop: keep the agent's record, since transcripts are deleted after cleanupPeriodDays."""
    try:
        data = json.load(sys.stdin)
        path = data.get("agent_transcript_path")
        if not path or not os.path.exists(path):
            return 0
        try:
            meta = json.load(open(path[:-len(".jsonl")] + ".meta.json"))
        except (OSError, ValueError):
            meta = {}
        meta.setdefault("agentType", data.get("agent_type", "?"))
        rec = agent_stats(path, meta)
        rec["session"] = data.get("session_id")
        out = os.path.join(main_checkout(), ".build", "retro")
        os.makedirs(out, exist_ok=True)
        with open(os.path.join(out, "agents.jsonl"), "a") as f:
            f.write(json.dumps(rec) + "\n")
    except Exception as e:  # a hook never gets in the way of the agent it observes
        print("retro hook: %s" % e, file=sys.stderr)
    return 0


def self_test():
    import tempfile

    def line(**kw):
        return json.dumps(kw) + "\n"

    def call(mid, t, out=10, cr=1000, tool=None, branch="HEAD"):
        content = [{"type": "tool_use", "id": tool[0], "name": tool[1], "input": tool[2]}] if tool else []
        return line(type="assistant", timestamp=t, gitBranch=branch,
                    message={"id": mid, "usage": {"input_tokens": 1, "cache_read_input_tokens": cr, "output_tokens": out},
                             "content": content})

    def result(tid, t, error=False, branch="HEAD"):
        return line(type="user", timestamp=t, gitBranch=branch,
                    message={"content": [{"type": "tool_result", "tool_use_id": tid, "is_error": error, "content": "boom"}]})

    with tempfile.TemporaryDirectory() as tmp:
        main = os.path.join(tmp, "repo")
        proj = os.path.join(tmp, "projects", re.sub(r"[^A-Za-z0-9]", "-", main))
        sub = os.path.join(proj, "s1", "subagents")
        os.makedirs(sub)
        os.makedirs(os.path.join(main, ".build", "auto-loop"))
        os.makedirs(os.path.join(main, ".build", "gate", "20260101-100500"))
        os.makedirs(os.path.join(tmp, "projects", os.path.basename(proj) + "Other"))  # a sibling project, not ours
        with open(os.path.join(main, ".build", "auto-loop", "run.log"), "w") as f:
            f.write("2026-01-01T09:00:00Z loop start v9.8\n2026-01-01T09:30:00Z loop end\n"
                    "2026-01-01T10:00:00Z loop start v9.9 --unattended\n2026-01-01T10:01:00Z HE-7 claim\n"
                    "2026-01-01T10:20:00Z HE-7 implement-done\n2026-01-01T10:40:00Z HE-7 review 1 CHANGES_REQUESTED 2 findings\n"
                    "2026-01-01T10:40:00Z HE-7 full .build/gate/20260101-100500 1\n2026-01-01T10:45:00Z HE-7 fix 1\n"
                    "2026-01-01T11:00:00Z HE-7 review 2 APPROVE 0 findings\n2026-01-01T11:01:00Z HE-7 shipped\n"
                    "2026-01-01T11:02:00Z HE-8 claim\n2026-01-01T11:03:00Z HE-8 parked needs owner\n"
                    "2026-01-01T12:00:00Z loop end v9.9 1 shipped 1 parked\n")
        with open(os.path.join(main, ".build", "gate", "20260101-100500", "meta.txt"), "w") as f:
            f.write("head=abcdef0123\ntree=clean\ntier=full\nstarted=%d\n" % ts("2026-01-01T10:05:00Z"))
        with open(os.path.join(main, ".build", "gate", "20260101-100500", "exit.txt"), "w") as f:
            f.write("1\n")
        with open(os.path.join(proj, "s1.jsonl"), "w") as f:
            f.write(line(type="user", timestamp="2026-01-01T09:59:00Z", gitBranch="HEAD",
                         message={"content": "<command-name>/ticket:auto</command-name>"}))
            f.write(call("m1", "2026-01-01T10:00:30Z", tool=("t1", "Agent", {})))
            f.write(call("m1", "2026-01-01T10:00:30Z"))                       # same call, second block
            f.write(result("t1", "2026-01-01T10:20:30Z"))
            f.write(call("m2", "2026-01-01T10:21:00Z", cr=300000))
            f.write(line(type="system", subtype="compact_boundary", timestamp="2026-01-01T10:22:00Z", gitBranch="HEAD"))
            f.write(call("m3", "2026-01-01T12:30:00Z"))                       # after the window: not counted
            f.write(line(type="cost-state", totalCostUSD=1.234))
        with open(os.path.join(proj, "s2.jsonl"), "w") as f:                  # attended, days later, on the ticket's branch
            f.write(call("m9", "2026-01-05T08:00:00Z", branch="fix/HE-8-thing"))
            f.write(call("m10", "2026-01-01T11:30:00Z", branch="tooling/x"))   # in the loop window, but no loop session
        with open(os.path.join(sub, "agent-a1.meta.json"), "w") as f:
            json.dump({"agentType": "ticket-implementer", "description": "Implement HE-7"}, f)
        with open(os.path.join(sub, "agent-a1.jsonl"), "w") as f:
            f.write(line(type="user", timestamp="2026-01-01T10:01:00Z", message={"content": "implement HE-7"}))
            for i in range(3):
                f.write(call("a%d" % i, "2026-01-01T10:0%d:00Z" % (2 + i), tool=("b%d" % i, "Bash", {"command": "git  status"})))
                f.write(result("b%d" % i, "2026-01-01T10:0%d:30Z" % (2 + i), error=i == 2))
            f.write(line(type="user", timestamp="2026-01-01T10:45:00Z", message={"content": "fix HE-7"}))
        hook_dir = os.path.join(main, ".build", "retro")
        os.makedirs(hook_dir)
        with open(os.path.join(hook_dir, "agents.jsonl"), "w") as f:
            gone = agent_stats(os.path.join(sub, "agent-a1.jsonl"), {"agentType": "ticket-reviewer", "description": "Review HE-7"})
            gone["agent_id"] = "gone1"
            f.write(json.dumps(gone) + "\n")
            f.write(json.dumps(dict(gone, agent_id="a1")) + "\n")             # already read from its transcript

        m, md = extract("v9.9", main, os.path.join(tmp, "projects"), tickets={"HE-8": {"title": "T", "type": "bug"}})
        t7, a1 = m["tickets"]["HE-7"], next(a for a in m["agents"] if a["agent_id"] == "a1")
        checks = [
            ("one window, the v9.9 one", len(m["loop_windows"]) == 1 and m["loop_windows"][0]["hours"] == 2.0),
            ("rounds parsed", [r["verdict"] for r in t7["rounds"]] == ["CHANGES_REQUESTED", "APPROVE"] and t7["fixes"] == 1),
            ("implement time", t7["implement_s"] == 19 * 60 and t7["outcome"] == "shipped"),
            ("parked noted", m["tickets"]["HE-8"]["outcome"] == "parked" and m["outcomes"] == {"shipped": 1, "parked": 1}),
            ("agent joined to its ticket", a1["ticket"] == "HE-7" and t7["agents"] == {"ticket-implementer": 1, "ticket-reviewer": 1}),
            ("agent calls, turns, errors", (a1["calls"], a1["turns"], a1["tool_errors"], a1["repeated_commands"]) == (3, 2, 1, 1)),
            ("hook record fills in for a lost transcript", m["coverage"]["agents_from_hook_only"] == 1 and m["coverage"]["agents"] == 2),
            ("api call counted once", m["sessions"][0]["buckets"]["loop"]["calls"] == 2),
            ("peak context and compaction", m["sessions"][0]["buckets"]["loop"]["peak_ctx"] == 300001 and m["sessions"][0]["compactions"] == 1),
            ("agent wait measured", m["sessions"][0]["tool_wait_s"] == {"Agent": 1200}),
            ("attended work found by branch", m["tickets"]["HE-8"]["attended_tok_eq"] > 0),
            ("a session that ran no loop is not the loop", m["sessions"][1]["buckets"]["overhead:tooling/x"]["calls"] == 1),
            ("red full run", m["test_runs"]["red"] == 1 and m["test_runs"]["runs"][0]["wall_s"] is not None),
            ("no paths in metrics", tmp not in json.dumps(m)),
            ("outliers point at lines", "agent-a1.jsonl:7" in md and "3x `git status`" in md and "HE-8: outcome parked" in md),
            ("tok_eq", tok_eq({"in": 1, "cw": 4, "cr": 10, "out": 2}) == 17),
        ]
        bad = [name for name, ok in checks if not ok]
        for name in bad:
            print("FAIL " + name)
        print("extract self-test: %d checks, %d failed" % (len(checks), len(bad)))
        return 1 if bad else 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    if "--hook" in argv:
        return hook()
    args = [a for a in argv if not a.startswith("--")]
    opt = {a: argv[i + 1] for i, a in enumerate(argv[:-1]) if a in ("--since", "--until")}
    args = [a for a in args if a not in opt.values()]
    if len(args) != 1:
        print(__doc__.split("Reads,")[0].strip(), file=sys.stderr)
        return 2
    milestone, repo = args[0], main_checkout()
    tickets = {} if "--no-tickets" in argv else milestone_tickets(repo, milestone)
    metrics, md = extract(milestone, repo, os.path.expanduser("~/.claude/projects"),
                          opt.get("--since"), opt.get("--until"), tickets, worktrees())
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
    out_json = os.path.join(top, "docs", "retros", milestone + ".metrics.json")
    out_md = os.path.join(repo, ".build", "retro", milestone, "outliers.md")
    os.makedirs(os.path.dirname(out_json), exist_ok=True)
    os.makedirs(os.path.dirname(out_md), exist_ok=True)
    with open(out_json, "w") as f:
        json.dump(metrics, f, indent=1)
        f.write("\n")
    with open(out_md, "w") as f:
        f.write(md)
    c = metrics["coverage"]
    print("retro extract %s: %d sessions, %d agents (%d from the hook only), %d tickets, tok_eq %s" %
          (milestone, c["sessions"], c["agents"], c["agents_from_hook_only"], len(metrics["tickets"]),
           json.dumps(metrics["tok_eq_totals"])))
    if c["shipped_without_transcripts"]:
        print("warning: shipped with no agent transcript on this Mac: " + ", ".join(c["shipped_without_transcripts"]))
    print(out_json)
    print(out_md)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
