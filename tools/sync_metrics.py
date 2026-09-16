#!/usr/bin/env python3
"""
sync_metrics.py — score a sync run without any ground truth.

Every number here is derived from the run's own inputs and outputs, so it
needs no human-corrected reference and no API call. Run it after every sync
and watch the columns; that is the regression gate.

    python tools/sync_metrics.py                          # scores sync_results.json
    python tools/sync_metrics.py a.json b.json            # compares two runs
    python tools/sync_metrics.py --config other_cfg.json  # non-default config

What the columns mean
---------------------
onset err     How far each clip's first spoken word landed from the target
              its own section implies. Lower is better. Needs sections, so
              it appears only when sync_targets.json is present or a
              --sections file is given.
gaps          Silence between consecutive placed clips. Clips 20ms apart are
              a packing artifact, not speech — that number should be ~0.
overlaps      Clips that collide on the main track. Must be 0.
order         Clips whose placed order differs from the recording order.
              Must be 0.
dropped       Clips sent to the Un sync track. Lower is better.
span          Where the placed dub starts and ends, against the EN content.
"""

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


def _load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _pct(sorted_vals, frac):
    if not sorted_vals:
        return 0.0
    return sorted_vals[min(len(sorted_vals) - 1, int(frac * len(sorted_vals)))]


def score(config, results, diag=None):
    """Return a dict of metrics for one results file."""
    # Prefer the EN track as the matcher actually saw it — it may contain
    # virtual sub-items cut out of an over-long clip, which the config has no
    # record of. Without them, targets for those clips can't be reproduced.
    en_src = (diag or {}).get("en_items") or config["en_items"]
    en = {i["id"]: dict(i) for i in en_src}
    dub = {i["id"]: dict(i) for i in config["dub_items"]}

    # Speech onsets, when the run recorded them.
    if diag and diag.get("speech_start"):
        for side, table in (("en", en), ("dub", dub)):
            for k, v in diag["speech_start"].get(side, {}).items():
                if int(k) in table and "speech_start" not in table[int(k)]:
                    table[int(k)]["speech_start"] = v

    rows = results["results"]
    matched = [r for r in rows if r.get("status") == "matched"]
    dropped = [r for r in rows if r.get("status") != "matched"]

    m = {
        "clips": len(rows),
        "placed": len(matched),
        "dropped": len(dropped),
    }

    # ── gaps, overlaps, order ─────────────────────────────────
    placed = sorted(matched, key=lambda r: r["new_position"])
    gaps = []
    for a, b in zip(placed, placed[1:]):
        gaps.append(b["new_position"] - (a["new_position"] + a["dub_duration"]))
    gaps_sorted = sorted(gaps)
    m["gap_lt_20ms"] = sum(1 for g in gaps if g < 0.02)
    m["gap_lt_120ms"] = sum(1 for g in gaps if g < 0.12)
    m["overlaps"] = sum(1 for g in gaps if g < -1e-9)
    m["gap_median"] = _pct(gaps_sorted, 0.5)
    m["gap_pairs"] = len(gaps)

    # Recording order must survive placement.
    by_record = sorted(matched, key=lambda r: dub[r["dub_id"]]["position"])
    m["order_breaks"] = sum(
        1 for a, b in zip(by_record, by_record[1:])
        if b["new_position"] < a["new_position"] - 1e-9
    )

    if matched:
        starts = [r["new_position"] for r in matched]
        ends = [r["new_position"] + r["dub_duration"] for r in matched]
        m["span_start"], m["span_end"] = min(starts), max(ends)
    else:
        m["span_start"] = m["span_end"] = 0.0
    m["en_end"] = max(i["position"] + i["duration"] for i in en.values())

    # ── onset error vs the target the sections imply ──────────
    sections = (diag or {}).get("sections")
    if sections:
        from sync_matcher import _compute_targets, _onset_abs

        targets = _compute_targets(list(en.values()), list(dub.values()), sections)
        errs = []
        for r in matched:
            did = r["dub_id"]
            if did not in targets:
                continue
            d = dub[did]
            onset = r["new_position"] + (_onset_abs(d) - d["position"])
            errs.append(abs(onset - targets[did]))
        errs.sort()
        if errs:
            m["err_n"] = len(errs)
            m["err_median"] = _pct(errs, 0.5)
            m["err_p90"] = _pct(errs, 0.9)
            m["err_max"] = errs[-1]
            m["err_le_250ms"] = sum(1 for e in errs if e <= 0.25)
            m["err_le_500ms"] = sum(1 for e in errs if e <= 0.5)
            m["err_le_1s"] = sum(1 for e in errs if e <= 1.0)
            m["err_gt_5s"] = sum(1 for e in errs if e > 5.0)

    # ── crude reference: distance to the matched EN clip's start ──
    # Comparable across placers and independent of the target model above.
    crude = []
    for r in matched:
        eid = r.get("en_id")
        if eid in en:
            crude.append(abs(r["new_position"] - en[eid]["position"]))
    crude.sort()
    if crude:
        m["crude_median"] = _pct(crude, 0.5)
        m["crude_p90"] = _pct(crude, 0.9)
        m["crude_gt_5s"] = sum(1 for v in crude if v > 5.0)

    return m


def _fmt(m, key, kind, total_key=None):
    if key not in m:
        return "–"
    v = m[key]
    if kind == "s":
        return f"{v:.3f}s"
    if kind == "s1":
        return f"{v:.1f}s"
    if kind == "pct":
        total = m.get(total_key) or 0
        return f"{v} ({100.0 * v / total:.0f}%)" if total else str(v)
    return str(v)


ROWS = [
    ("clips",                 "clips",        "n",   None),
    ("placed on main track",  "placed",       "pct", "clips"),
    ("dropped to Un sync",    "dropped",      "pct", "clips"),
    ("",                      None,           None,  None),
    ("onset err median",      "err_median",   "s",   None),
    ("onset err p90",         "err_p90",      "s",   None),
    ("onset err max",         "err_max",      "s",   None),
    ("within 250ms",          "err_le_250ms", "pct", "err_n"),
    ("within 500ms",          "err_le_500ms", "pct", "err_n"),
    ("within 1s",             "err_le_1s",    "pct", "err_n"),
    ("worse than 5s",         "err_gt_5s",    "pct", "err_n"),
    ("",                      None,           None,  None),
    ("gaps under 20ms",       "gap_lt_20ms",  "pct", "gap_pairs"),
    ("gaps under 120ms",      "gap_lt_120ms", "pct", "gap_pairs"),
    ("gap median",            "gap_median",   "s",   None),
    ("overlaps (must be 0)",  "overlaps",     "n",   None),
    ("order breaks (must be 0)", "order_breaks", "n", None),
    ("",                      None,           None,  None),
    ("dist. to EN start, median", "crude_median", "s", None),
    ("dist. to EN start, p90",    "crude_p90",    "s", None),
    ("dist. to EN start, >5s",    "crude_gt_5s",  "pct", "placed"),
    ("",                      None,           None,  None),
    ("span start",            "span_start",   "s1",  None),
    ("span end",              "span_end",     "s1",  None),
    ("EN content ends",       "en_end",       "s1",  None),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("results", nargs="*", default=None,
                    help="results JSON file(s); default sync_results.json")
    ap.add_argument("--config", default=str(ROOT / "sync_config.json"))
    ap.add_argument("--sections", default=None,
                    help="sync_targets.json (or any file with a 'sections' key) "
                         "to use for every results file")
    args = ap.parse_args()

    paths = [Path(p) for p in (args.results or [ROOT / "sync_results.json"])]
    config = _load(args.config)

    shared = _load(args.sections) if args.sections else None

    cols = []
    for p in paths:
        diag = shared
        if diag is None:
            sidecar = p.with_name("sync_targets.json")
            diag = _load(sidecar) if sidecar.exists() else None
        cols.append((p.stem, score(config, _load(p), diag)))

    width = max(len(label) for label, *_ in ROWS) + 2
    header = " " * width + "".join(f"{name[:22]:>24}" for name, _ in cols)
    print()
    print(header)
    print("-" * len(header))
    for label, key, kind, total in ROWS:
        if key is None:
            print()
            continue
        cells = "".join(f"{_fmt(m, key, kind, total):>24}" for _, m in cols)
        print(f"{label:<{width}}{cells}")
    print()


if __name__ == "__main__":
    main()
