#!/usr/bin/env python3
"""summarize.py, read against recorded runs, must still count what it counted.

tests/recorded/ holds the first of the twenty fresh clusters each network
plugin ran in run 43749621483, reduced to the files summarize.py reads (the
probes' logs gzipped, kindnet's own log kept for its sync times). The counts
summarize.py gave for them are in tests/recorded/expected.json. This check
runs summarize.py on the recorded data and compares; then it shows the
comparison every planted change below, each on a fresh copy, and each must
be caught. A check that has never failed proves nothing.

    python3 tests/check_recorded.py
"""
import gzip
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RECORDED = os.path.join(HERE, "recorded")
OUT_OK = ("reply", "connected")


def counts(path):
    """What a reader of the README cares about, per plugin."""
    out = subprocess.run([sys.executable, os.path.join(ROOT, "summarize.py"), "--json", path],
                         capture_output=True, text=True, check=True).stdout
    result = {}
    for job in json.loads(out):
        c = result.setdefault(job["cni"], dict.fromkeys(
            ("runs", "valid", "first", "got_out", "never_held", "held", "held_survived",
             "gated", "gated_got_out"), 0))
        c["runs"] += 1
        if not job["valid"]:
            continue
        c["valid"] += 1
        for p in job["pods"]:
            if not p["complete"]:
                continue
            if p["pod"].startswith("first-"):
                c["first"] += 1
                c["got_out"] += bool(p["got_out"])
                c["never_held"] += bool(p["never_held"])
                if p["got_out"] and p["held"]["established"]:
                    c["held"] += 1
                    c["held_survived"] += p["held"]["ok_after_policy_held"] > 0
            elif p["pod"].startswith("gated-"):
                c["gated"] += 1
                c["gated_got_out"] += bool(p["got_out"])
    return result


def edit_log(job, pod, change):
    """Rewrite one probe's result line in a copy of the recorded data."""
    path = os.path.join(job, pod + ".log.gz")
    with gzip.open(path, "rt") as f:
        lines = f.read().splitlines()
    for i, line in enumerate(lines):
        if line.startswith("{") and json.loads(line).get("event") == "result":
            d = json.loads(line)
            change(d)
            lines[i] = json.dumps(d)
            break
    else:
        raise SystemExit("stale plant: %s has no result line" % path)
    with gzip.open(path, "wt") as f:
        f.write("\n".join(lines) + "\n")


def first_attempt_answers(d):
    a = min(d["attempts"], key=lambda a: a["start_ms"])
    a["result"], a["reply"] = "reply", "planted"


def nothing_answers(d):
    for a in d["attempts"]:
        if a["result"] in OUT_OK:
            a["result"] = "timeout"
    d["hold"] = {"target": d["hold"]["target"], "established": False, "pings": []}


def connection_dies_at_the_wall(d):
    # The held connection stops answering 200 ms after the last attempt
    # that got out, as it would if the policy closed it.
    last = max(a["start_ms"] for a in d["attempts"] if a["result"] in OUT_OK)
    for p in d["hold"]["pings"]:
        if p["at_ms"] > last + 200:
            p["ok"], p["err"] = False, "planted"


def settled_never(job):
    with open(os.path.join(job, "settled.tries"), "w") as f:
        f.write("never\n")


def never_held(d):
    # Every attempt after the first answer answers too: still out at the end.
    first = min(a["start_ms"] for a in d["attempts"] if a["result"] in OUT_OK)
    for a in d["attempts"]:
        if a["start_ms"] >= first:
            a["result"], a["reply"] = "reply", "planted"


PLANTS = [
    ("a gated pod on kindnet that got out", "kindnet-1",
     lambda j: edit_log(j, "gated-1", first_attempt_answers)),
    ("a pod on Calico that got out", "calico-1",
     lambda j: edit_log(j, "first-1", first_attempt_answers)),
    ("a pod on kindnet held from its first attempt", "kindnet-1",
     lambda j: edit_log(j, "first-1", nothing_answers)),
    ("a connection that stopped answering when the policy held", "kindnet-gvisor-1",
     lambda j: edit_log(j, "first-1", connection_dies_at_the_wall)),
    ("a pod still getting out at its last attempt", "kindnet-1",
     lambda j: edit_log(j, "first-2", never_held)),
    ("a run whose settled pod was never blocked", "cilium-1", settled_never),
]


def main():
    expected = json.load(open(os.path.join(RECORDED, "expected.json")))
    got = counts(RECORDED)
    if got != expected:
        print("FAIL  summarize.py no longer counts the recorded runs as it did:")
        for cni in sorted(set(got) | set(expected)):
            if got.get(cni) != expected.get(cni):
                print("  %s: expected %s, got %s" % (cni, expected.get(cni), got.get(cni)))
        return 1
    print("ok    the recorded runs count as recorded: %s" % ", ".join(
        "%s %d of %d got out (gated %d of %d)" % (c, v["got_out"], v["first"], v["gated_got_out"], v["gated"])
        for c, v in sorted(got.items())))
    missed = 0
    for what, job, plant in PLANTS:
        work = tempfile.mkdtemp()
        try:
            copy = os.path.join(work, "recorded")
            shutil.copytree(RECORDED, copy)
            plant(os.path.join(copy, job))
            changed = counts(copy) != expected
        finally:
            shutil.rmtree(work)
        print("%s planted: %s" % ("ok   " if changed else "FAIL ", what))
        missed += not changed
    if missed:
        print("FAIL  %d planted change(s) went unnoticed" % missed)
        return 1
    print("all %d planted changes caught" % len(PLANTS))
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--write-expected":
        json.dump(counts(RECORDED), open(os.path.join(RECORDED, "expected.json"), "w"), indent=1, sort_keys=True)
        print("written")
    else:
        sys.exit(main())
