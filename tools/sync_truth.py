#!/usr/bin/env python3
"""
sync_truth.py — score a sync against positions a person fixed by hand.

sync_metrics.py scores a run against its own targets, so a clip matched to
the wrong line still scores well there. This scores against ground truth:
where an editor actually put each dub clip.

Make a benchmark once
---------------------
1. Run a sync in Samanvaya as usual.
2. In REAPER, fix every clip that landed wrong, and move any clip on the
   Un sync track that does have a place back onto the dub track. Clips that
   truly have no place stay on Un sync. Save the project.
3. Capture it:

    python tools/sync_truth.py capture "D:/Projects/Episode 2.RPP" --name ep2

   That writes benchmarks/ep2/ with the hand-fixed positions (truth.json)
   and copies of the run's sync_config.json, sync_results.json and
   sync_targets.json. Do it before the next sync, which overwrites them.

Score
-----
    python tools/sync_truth.py score ep2                 # the captured run
    python tools/sync_truth.py score ep2 --replay        # + current placer code
    python tools/sync_truth.py score ep2 other.json      # + any results file

--replay re-runs placement with the code as it is now on the benchmark's own
sections and onsets (no API calls), so a placer change shows up as a column
next to the run it was captured from.

Clips are matched between the run and the project by their source, not their
id or position: same file, same start offset into it, same length. Moving a
clip never changes those. A clip whose length was trimmed by hand still
matches on file and offset.

What the columns mean
---------------------
compared      Clips placed by the run and on the dub track in the truth.
median/p90    |placed - truth| in milliseconds. Lower is better.
within N ms   Share of compared clips that landed within N ms of the truth.
bias          Mean signed error. Negative means the run places clips early.
wrong drop    Sent to Un sync by the run, but the editor found it a place.
wrong place   Placed by the run, but the editor moved it to Un sync.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BENCH = ROOT / "benchmarks"


def _load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _save(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def _pct(sorted_vals, frac):
    if not sorted_vals:
        return 0.0
    return sorted_vals[min(len(sorted_vals) - 1, int(frac * len(sorted_vals)))]


# ── Reading a REAPER project ─────────────────────────────────

def _unquote(s):
    """First token of an RPP value: quoted (spaces allowed) or bare.

    REAPER can follow a value with flags, e.g. FILE "a b.mp3" 1.
    """
    s = s.strip()
    if s and s[0] in "\"'`":
        end = s.find(s[0], 1)
        return s[1:end] if end > 0 else s[1:]
    return s.split()[0] if s else s


def read_rpp_items(rpp_path):
    """Every item in a .RPP as {track, position, length, soffs, file}.

    A small block parser, not a regex over the file: items nest inside
    tracks, sources nest inside items, and a NAME line means the track's name
    only when it sits directly in the TRACK block. Only the first take of an
    item is read; Samanvaya clips have one.
    """
    items = []
    stack = []            # block names, outermost first
    track_name = None
    item = None
    with open(rpp_path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if line.startswith("<"):
                block = line[1:].split(None, 1)[0].upper()
                stack.append(block)
                if block == "TRACK":
                    track_name = ""
                elif block == "ITEM" and stack[-2:-1] == ["TRACK"]:
                    item = {"track": track_name, "position": None,
                            "length": None, "soffs": 0.0, "file": None,
                            "_soffs_seen": False}
                continue
            if line == ">":
                if stack:
                    closed = stack.pop()
                    if closed == "ITEM" and item is not None:
                        item.pop("_soffs_seen", None)
                        if item["position"] is not None and item["file"]:
                            items.append(item)
                        item = None
                continue

            top = stack[-1] if stack else None
            key, _, rest = line.partition(" ")
            if top == "TRACK" and key == "NAME":
                track_name = _unquote(rest)
            elif top == "ITEM" and item is not None:
                if key == "POSITION":
                    item["position"] = float(rest.split()[0])
                elif key == "LENGTH":
                    item["length"] = float(rest.split()[0])
                elif key == "SOFFS" and not item["_soffs_seen"]:
                    item["soffs"] = float(rest.split()[0])
                    item["_soffs_seen"] = True
                elif key == "TAKE":
                    item["_soffs_seen"] = True     # later takes: ignore
            elif top == "SOURCE" and item is not None and key == "FILE" \
                    and item["file"] is None:
                item["file"] = _unquote(rest)
    return items


def _track_names_from_settings():
    path = ROOT / "sync_pipeline_settings.json"
    try:
        s = _load(path)
    except Exception:
        s = {}
    return (s.get("track_dub") or "Dub"), (s.get("track_unsync") or "Un sync")


# ── Matching clips between a run and the truth ───────────────

_TOL = 0.002   # seconds; REAPER writes positions to 1e-14, the config to 1e-6


def _base(path):
    return os.path.basename((path or "").replace("\\", "/")).lower()


def map_truth(config, truth):
    """dub id → truth entry, matched on source file + offset (+ length)."""
    by_file = {}
    for t in truth["items"]:
        by_file.setdefault(_base(t["file"]), []).append(t)
    used = set()
    out = {}
    for d in config["dub_items"]:
        cands = by_file.get(_base(d.get("wav_path")), [])
        off = d.get("take_offset", 0.0) or 0.0
        dur = d.get("duration", 0.0) or 0.0
        pick = None
        # Exact source slice first, then the same start with a trimmed tail.
        for strict in (True, False):
            for k, t in enumerate(cands):
                if id(t) in used or abs(t["soffs"] - off) > _TOL:
                    continue
                if strict and abs((t["length"] or 0.0) - dur) > _TOL:
                    continue
                pick = t
                break
            if pick:
                break
        if pick:
            used.add(id(pick))
            out[d["id"]] = pick
    return out


def score(config, truth, results):
    """Metrics for one results file against the truth."""
    tmap = map_truth(config, truth)
    errs, rows = [], []
    wrong_drop = wrong_place = no_truth = 0
    for r in results["results"]:
        did = r.get("dub_id")
        t = tmap.get(did)
        if t is None:
            no_truth += 1
            continue
        placed = r.get("status") == "matched"
        home = t["placed"]
        if placed and home:
            e = float(r["new_position"]) - t["position"]
            errs.append(e)
            rows.append((abs(e), e, did, r.get("en_id")))
        elif placed and not home:
            wrong_place += 1
        elif home and not placed:
            wrong_drop += 1
    a = sorted(abs(e) for e in errs)
    n = len(a)
    within = lambda ms: (100.0 * sum(1 for x in a if x * 1000 <= ms) / n) if n else 0.0
    return {
        "compared": n,
        "median": _pct(a, 0.5) * 1000,
        "p90": _pct(a, 0.9) * 1000,
        "max": (a[-1] * 1000) if a else 0.0,
        "w40": within(40), "w100": within(100), "w250": within(250),
        "bias": (sum(errs) / n * 1000) if n else 0.0,
        "wrong_drop": wrong_drop,
        "wrong_place": wrong_place,
        "no_truth": no_truth,
        "worst": sorted(rows, reverse=True)[:8],
        "truth_matched": len(tmap),
        "total_dub": len(config["dub_items"]),
    }


# ── Commands ─────────────────────────────────────────────────

def cmd_capture(args):
    dub_name, unsync_name = _track_names_from_settings()
    dub_name = args.track or dub_name
    unsync_name = args.unsync or unsync_name

    items = read_rpp_items(args.project)
    keep = []
    for it in items:
        if it["track"] == dub_name:
            it["placed"] = True
        elif it["track"] == unsync_name:
            it["placed"] = False
        else:
            continue
        keep.append(it)
    if not keep:
        names = sorted({i["track"] for i in items})
        raise SystemExit(f"No items on '{dub_name}' or '{unsync_name}' in "
                         f"{args.project}. Tracks with items: {names}")

    cfg_path = Path(args.config)
    config = _load(cfg_path)
    truth = {
        "project": str(Path(args.project).resolve()),
        "captured": datetime.now().isoformat(timespec="seconds"),
        "dub_track": dub_name,
        "unsync_track": unsync_name,
        "items": keep,
    }
    tmap = map_truth(config, truth)

    out = BENCH / args.name
    if out.exists() and not args.force:
        raise SystemExit(f"{out} exists. Pick another --name or pass --force.")
    out.mkdir(parents=True, exist_ok=True)
    _save(out / "truth.json", truth)
    shutil.copyfile(cfg_path, out / "config.json")
    for src, dst in ((args.results, "results.json"), (args.targets, "targets.json")):
        if src and Path(src).exists():
            shutil.copyfile(src, out / dst)

    placed = sum(1 for t in keep if t["placed"])
    print(f"  Project:   {args.project}")
    print(f"  Truth:     {placed} placed on '{dub_name}', "
          f"{len(keep) - placed} left on '{unsync_name}'")
    print(f"  Matched:   {len(tmap)} of {len(config['dub_items'])} run clips "
          f"found in the project by source")
    if len(tmap) < len(config["dub_items"]):
        print("  [WARN] Unmatched clips were split, re-recorded or belong to "
              "another run; they are left out of the score.")
    print(f"  Saved:     {out}")


def _replay(bench):
    """Placement with the current code on the benchmark's own inputs."""
    targets = bench / "targets.json"
    if not targets.exists():
        raise SystemExit(f"--replay needs {targets} (captured from a live run).")
    fd, tmp = tempfile.mkstemp(suffix=".json", prefix="replay_")
    os.close(fd)
    cmd = [sys.executable, str(ROOT / "tools" / "replay_placer.py"),
           "--config", str(bench / "config.json"),
           "--targets", str(targets),
           "--cache", str(ROOT / "sync_cache.json"),
           "--placer", "isotonic", "--out", tmp]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stdout[-2000:], proc.stderr[-2000:])
        raise SystemExit("replay failed")
    data = _load(tmp)
    for p in (tmp, Path(tmp).with_name(Path(tmp).stem + "_targets.json")):
        try:
            os.remove(p)
        except OSError:
            pass
    return data


def cmd_score(args):
    bench = BENCH / args.name if not Path(args.name).is_dir() else Path(args.name)
    truth = _load(bench / "truth.json")
    config = _load(bench / "config.json")

    runs = []
    if (bench / "results.json").exists():
        runs.append(("captured run", _load(bench / "results.json")))
    if args.replay:
        runs.append(("replay (code now)", _replay(bench)))
    for p in args.results:
        runs.append((Path(p).name, _load(p)))
    if not runs:
        raise SystemExit("Nothing to score: no results.json in the benchmark "
                         "and no results files given.")

    scored = [(name, score(config, truth, res)) for name, res in runs]
    first = scored[0][1]
    print(f"\n  Benchmark {bench.name}: {first['truth_matched']} of "
          f"{first['total_dub']} clips have a hand-fixed position\n")

    lines = [
        ("compared",      lambda m: f"{m['compared']}"),
        ("median ms",     lambda m: f"{m['median']:.0f}"),
        ("p90 ms",        lambda m: f"{m['p90']:.0f}"),
        ("max ms",        lambda m: f"{m['max']:.0f}"),
        ("within 40 ms",  lambda m: f"{m['w40']:.0f}%"),
        ("within 100 ms", lambda m: f"{m['w100']:.0f}%"),
        ("within 250 ms", lambda m: f"{m['w250']:.0f}%"),
        ("bias ms",       lambda m: f"{m['bias']:+.0f}"),
        ("wrong drop",    lambda m: f"{m['wrong_drop']}"),
        ("wrong place",   lambda m: f"{m['wrong_place']}"),
    ]
    w = max(18, *(len(n) + 2 for n, _ in scored))
    print("  " + "".ljust(16) + "".join(n.rjust(w) for n, _ in scored))
    for label, fmt in lines:
        print("  " + label.ljust(16) + "".join(fmt(m).rjust(w) for _, m in scored))

    for name, m in scored:
        if not m["worst"]:
            continue
        print(f"\n  Worst clips, {name}:")
        for _, e, did, eid in m["worst"]:
            side = "early" if e < 0 else "late"
            print(f"    dub {did:>4}  (EN {eid})  {abs(e) * 1000:7.0f} ms {side}")
    print()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("capture", help="save hand-fixed positions as a benchmark")
    c.add_argument("project", help="the saved .RPP with the hand-fixed clips")
    c.add_argument("--name", required=True, help="benchmark name, e.g. ep2")
    c.add_argument("--track", help="dub track name (default: from settings)")
    c.add_argument("--unsync", help="Un sync track name (default: from settings)")
    c.add_argument("--config", default=str(ROOT / "sync_config.json"))
    c.add_argument("--results", default=str(ROOT / "sync_results.json"))
    c.add_argument("--targets", default=str(ROOT / "sync_targets.json"))
    c.add_argument("--force", action="store_true", help="overwrite the benchmark")
    c.set_defaults(func=cmd_capture)

    s = sub.add_parser("score", help="score runs against a benchmark")
    s.add_argument("name", help="benchmark name or folder")
    s.add_argument("results", nargs="*", help="extra results files to score")
    s.add_argument("--replay", action="store_true",
                   help="also score placement re-run with the current code")
    s.set_defaults(func=cmd_score)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
