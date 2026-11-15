#!/usr/bin/env python3
"""Read what run.sh wrote and count what got out.

    summarize.py DIR [DIR ...]          a markdown table per network plugin
    summarize.py --json DIR [DIR ...]   every pod's numbers as JSON

A DIR is one run's output, or a directory holding many of them. An attempt
"got out" when the destination answered: an echo line from the runner's
server, an HTTP status line from 1.1.1.1, or at least a completed TCP
handshake. A run counts only if its settled pod was blocked (the plugin had
handled the policy) and its control pod, with no policy, reached both.
"""
import datetime
import gzip
import json
import os
import statistics
import sys

OUT_OK = ("reply", "connected")
TARGETS = ("outside", "internet")


def events(path):
    out = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("{"):
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        pass
    except OSError:
        pass
    return out


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def target_numbers(attempts, name):
    atts = sorted((a for a in attempts if a["target"] == name), key=lambda a: a["start_ms"])
    got = [a for a in atts if a["result"] in OUT_OK]
    r = {"attempts": len(atts), "got_out": len(got)}
    if got:
        last = got[-1]["start_ms"]
        later = [a["start_ms"] for a in atts if a["start_ms"] > last]
        # Still getting out at the last attempt: the policy was never seen to
        # hold, which is reported as such, not as a time.
        r.update(first_out_ms=got[0]["start_ms"], last_out_ms=last,
                 holds_from_ms=later[0] if later else None, never_held=not later,
                 replies=sorted({a.get("reply", "") for a in got if a.get("reply")})[:3])
    elif atts:
        r["holds_from_ms"] = atts[0]["start_ms"]
    return r


def kindnet_syncs(job):
    """When kindnet finished rewriting its nftables rules, from its own log."""
    out = []
    try:
        with gzip.open(os.path.join(job, "cni.log.gz"), "rt") as f:
            for line in f:
                if '"Syncing nftables rules"' in line and "elapsed=" in line:
                    stamp = line.split()[0].rstrip("Z")
                    whole, _, frac = stamp.partition(".")
                    base = datetime.datetime.strptime(whole, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
                    out.append(int(base.timestamp()) * 10**9 + int(frac.ljust(9, "0")[:9]))
    except (OSError, ValueError):
        pass
    return out


def pod_numbers(job, name, syncs=()):
    evs = events(os.path.join(job, name + ".log"))
    start = next((e for e in evs if e.get("event") == "start"), None)
    result = next((e for e in evs if e.get("event") == "result"), None)
    p = {"pod": name, "complete": bool(start and result)}
    if not p["complete"]:
        return p
    t0 = start["t0_unix_ns"]
    for t in TARGETS:
        p[t] = target_numbers(result["attempts"], t)
    p["got_out"] = any(p[t]["got_out"] for t in TARGETS)
    p["never_held"] = any(p[t].get("never_held") for t in TARGETS)
    h = result["hold"]
    holds = p["outside"].get("holds_from_ms")
    after = [x for x in h["pings"] if x["ok"] and holds is not None and x["at_ms"] > holds + 1000]
    p["held"] = {"established": h["established"], "opened_at_ms": h.get("opened_at_ms"),
                 "pings": len(h["pings"]), "pings_ok": sum(x["ok"] for x in h["pings"]),
                 "ok_after_policy_held": len(after),
                 "last_ok_ms": max((x["at_ms"] for x in h["pings"] if x["ok"]), default=None)}
    created = read(os.path.join(job, name + ".created"))
    if created:
        p["created_to_start_ms"] = round((t0 - int(created)) / 1e6, 1)
    for line in read(os.path.join(job, "watch.log")).splitlines():
        f = line.split()
        if len(f) >= 4 and f[2] == name and f[3] not in ("", "<none>") and f[3][0].isdigit():
            p["ip_seen_ms"] = round((int(f[0]) - t0) / 1e6, 1)
            later = [s for s in syncs if s > int(f[0])]
            if later:
                p["plugin_synced_after_ip_ms"] = round((later[0] - t0) / 1e6, 1)
            break
    gate = next((e for e in events(os.path.join(job, name + ".gate.log")) if e.get("event") == "gate"), None)
    if gate:
        p["gate_held_at_ms"] = gate.get("held_at_ms")
    return p


def job_numbers(job):
    env = read(os.path.join(job, "env.txt"))
    cni = next((w.split("=", 1)[1] for w in env.split() if w.startswith("cni=")), "?")
    names = sorted({f[:-4] for f in os.listdir(job) if f.endswith(".log") and not f.endswith(".gate.log")
                    and f[:-4].split("-")[0] in ("first", "gated", "control")},
                   key=lambda n: (n.split("-")[0], int(n.split("-")[1])))
    syncs = kindnet_syncs(job) if cni.startswith("kindnet") else []
    pods = [pod_numbers(job, n, syncs) for n in names]
    control = next((p for p in pods if p["pod"].startswith("control")), None)
    settled = read(os.path.join(job, "settled.tries"), "never")
    problems = []
    if settled == "never":
        problems.append("the settled pod was never blocked")
    if not control or not control["complete"]:
        problems.append("no control result")
    elif not (control["outside"]["got_out"] and control["internet"]["got_out"]):
        problems.append("the control pod did not reach both destinations")
    return {"job": os.path.basename(os.path.normpath(job)), "cni": cni, "env": env,
            "settled_tries": settled, "valid": not problems, "problems": problems, "pods": pods}


def jobs_under(paths):
    for p in paths:
        if os.path.exists(os.path.join(p, "env.txt")):
            yield p
        elif os.path.isdir(p):
            for d in sorted(os.listdir(p)):
                if os.path.exists(os.path.join(p, d, "env.txt")):
                    yield os.path.join(p, d)


def spread(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return "–"
    q = lambda f: xs[min(len(xs) - 1, int(round(f * (len(xs) - 1))))]
    return f"{xs[0]:.0f} / {statistics.median(xs):.0f} / {q(0.9):.0f} / {xs[-1]:.0f} (n={len(xs)})"


def table(jobs):
    out = []
    for cni in sorted({j["cni"] for j in jobs}):
        js = [j for j in jobs if j["cni"] == cni]
        valid = [j for j in js if j["valid"]]
        first = [p for j in valid for p in j["pods"] if p["pod"].startswith("first-") and p["complete"]]
        gated = [p for j in valid for p in j["pods"] if p["pod"].startswith("gated-") and p["complete"]]
        esc = [p for p in first if p["got_out"]]
        jobs_esc = sum(any(p["got_out"] for p in j["pods"] if p["pod"].startswith("first-") and p["complete"])
                       for j in valid)
        held = [p for p in esc if p["held"]["established"]]
        out += [f"### {cni}", "",
                "| | |", "|---|---|",
                f"| runs (fresh clusters) | {len(js)}, valid {len(valid)} |",
                f"| runs with at least one pod that got out | {jobs_esc} of {len(valid)} |",
                f"| pods sending from their first instant | {len(first)} |",
                f"| … that got out to the runner's server | {sum(bool(p['outside']['got_out']) for p in first)} |",
                f"| … that got out to 1.1.1.1:80 | {sum(bool(p['internet']['got_out']) for p in first)} |",
                f"| … that got out to either | {len(esc)} |",
                f"| last attempt that got out, ms after start (min / median / p90 / max) | {spread(max(p[t].get('last_out_ms') or 0 for t in TARGETS) for p in esc)} |",
                f"| policy held from, ms after start (all first-instant pods) | {spread(p['outside'].get('holds_from_ms') for p in first)} |",
                f"| pods still getting out at their last attempt (never seen to hold) | {sum(p['never_held'] for p in first)} |",
                f"| pod IP first seen by a watcher on the API server, ms after start | {spread(p.get('ip_seen_ms') for p in first)} |",
                *([f"| kindnet's first nftables sync after that, ms after start | {spread(p.get('plugin_synced_after_ip_ms') for p in first)} |",
                   f"| … minus the last attempt that got out (escaped pods) | {spread(p['plugin_synced_after_ip_ms'] - max(p[t].get('last_out_ms') or 0 for t in TARGETS) for p in esc if p.get('plugin_synced_after_ip_ms') is not None)} |"]
                  if cni.startswith("kindnet") else []),
                f"| connections opened before the policy held, still answering 1 s after it held | {sum(p['held']['ok_after_policy_held'] > 0 for p in held)} of {len(held)} |",
                f"| gated pods (init container waits for the wall) | {len(gated)}, got out {sum(p['got_out'] for p in gated)} |",
                f"| gate passed at, ms after the gate started | {spread(p.get('gate_held_at_ms') for p in gated)} |",
                ""]
        bad = [j for j in js if not j["valid"]]
        if bad:
            out += ["Not counted: " + "; ".join(f"{j['job']} ({', '.join(j['problems'])})" for j in bad), ""]
    return "\n".join(out)


def main(argv):
    as_json = "--json" in argv
    paths = [a for a in argv if a != "--json"] or ["out"]
    jobs = [job_numbers(j) for j in jobs_under(paths)]
    if as_json:
        json.dump(jobs, sys.stdout, indent=1)
        print()
    else:
        print(table(jobs))


if __name__ == "__main__":
    main(sys.argv[1:])
