#!/usr/bin/env python3
"""
replay_placer.py — re-run placement on a finished sync. No API calls.

Transcription and matching are the expensive, non-deterministic half of the
pipeline; placement is neither. This replays just the placement step against
a config + a cached matcher response, so a placer change can be measured on
real material in a second.

    python tools/replay_placer.py --placer isotonic --out iso.json
    python tools/replay_placer.py --placer spring   --out spring.json
    python tools/sync_metrics.py iso.json spring.json --sections iso_targets.json

Sections come from sync_targets.json if it exists, otherwise from the cached
Gemini response in sync_cache.json (the sectioned reply is found automatically).

Speech onsets: sync_targets.json carries them. Without it they are unavailable
offline — the cache is keyed on the audio bytes, and the chunk files are
temporary — so onsets fall back to 0 for BOTH placers. Relative comparison
stays valid; absolute onset accuracy will be slightly better in a live run.
"""

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import sync_matcher as sm  # noqa: E402


def _load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _parse_sections(raw):
    """Pull {'sections': [...]} out of a raw model reply."""
    text = raw.strip() if isinstance(raw, str) else ""
    if text.startswith("```"):
        text = re.sub(r"^```\w*\n?", "", text)
        text = re.sub(r"\n?```$", "", text).strip()
    try:
        parsed = json.loads(text)
    except Exception:
        return None
    if isinstance(parsed, dict) and isinstance(parsed.get("sections"), list):
        return parsed
    return None


def _sections_from_cache(cache_path, en_ids, dub_ids):
    """Find the cached sectioned reply that best covers this config."""
    cache = _load(cache_path)
    best, best_cov = None, -1
    for key, val in cache.items():
        parsed = _parse_sections(val)
        if not parsed:
            continue
        seen_en, seen_dub = set(), set()
        for sec in parsed["sections"]:
            seen_en.update(sec.get("en") or [])
            seen_dub.update(sec.get("dub") or [])
        cov = len(seen_en & en_ids) + len(seen_dub & dub_ids)
        if cov > best_cov:
            best, best_cov = (key, parsed), cov
    if not best:
        return None, None, 0
    return best[0], best[1], best_cov


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=str(ROOT / "sync_config.json"))
    ap.add_argument("--cache", default=str(ROOT / "sync_cache.json"))
    ap.add_argument("--targets", default=str(ROOT / "sync_targets.json"),
                    help="sync_targets.json from a live run (for sections + onsets)")
    ap.add_argument("--placer", required=True, choices=["isotonic", "spring"])
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    config = _load(args.config)
    dub_items = [dict(i) for i in config["dub_items"]]
    dub_ids = {i["id"] for i in dub_items}

    sections = unmatched_dub = None
    diag = None
    targets_path = Path(args.targets)
    if targets_path.exists():
        diag = _load(targets_path)
        sections = diag.get("sections")
        if sections:
            print(f"  Sections from {targets_path.name}: {len(sections)}")

    # The EN track as the matcher saw it, including virtual sub-items cut out
    # of over-long clips. Falls back to the raw config when unavailable.
    en_src = (diag or {}).get("en_items") or config["en_items"]
    en_items = [dict(i) for i in en_src]
    en_ids = {i["id"] for i in en_items}
    if (diag or {}).get("en_items"):
        virtual = sum(1 for i in en_items if i.get("virtual_from"))
        print(f"  EN clips from {targets_path.name}: {len(en_items)} "
              f"({virtual} virtual sub-items)")

    if not sections:
        key, parsed, cov = _sections_from_cache(args.cache, en_ids, dub_ids)
        if not parsed:
            print("  [ERROR] No sectioned matcher reply found. Run a live sync "
                  "once (it writes sync_targets.json), or pass --targets.")
            raise SystemExit(1)
        sections = parsed["sections"]
        unmatched_dub = parsed.get("unmatched_dub") or []
        print(f"  Sections from cache entry {key}: {len(sections)} "
              f"(covers {cov} of {len(en_ids) + len(dub_ids)} ids)")

    if unmatched_dub is None:
        in_sections = set()
        for sec in sections:
            in_sections.update(sec.get("dub") or [])
        unmatched_dub = sorted(dub_ids - in_sections)

    # Restore speech onsets and ends when a live run recorded them. Runs from
    # before speech ends were recorded have none, and the placer then
    # measures those clips to their item end, as it did then.
    restored = {}
    for field in ("speech_start", "speech_end"):
        table_by_side = (diag or {}).get(field) or {}
        restored[field] = 0
        for side, items in (("en", en_items), ("dub", dub_items)):
            table = table_by_side.get(side) or {}
            for item in items:
                val = table.get(str(item["id"]))
                if val is not None:
                    item[field] = val
                    restored[field] += 1
    print(f"  Speech onsets restored: {restored['speech_start']} "
          f"(0 means onsets default to clip start for both placers)")
    print(f"  Speech ends restored:   {restored['speech_end']}")

    en_total = max(i["position"] + i["duration"] for i in en_items)
    sm._LAST_DIAG.clear()
    sm._LAST_DIAG["placer"] = args.placer
    sm._LAST_DIAG["sections"] = sections

    print(f"\n  Replaying placer: {args.placer}\n")
    if args.placer == "spring":
        results = sm._place_with_springs(en_items, dub_items, sections,
                                        list(unmatched_dub), en_total)
    else:
        results = sm._place_isotonic(en_items, dub_items, sections,
                                     list(unmatched_dub), en_total)

    n_matched = sum(1 for r in results if r["status"] == "matched")
    out = {
        "results": results,
        "summary": {
            "total_en": len(en_items),
            "total_dub": len(dub_items),
            "matched": n_matched,
            "unmatched": len(results) - n_matched,
            "placer": args.placer,
            "replay": True,
        },
    }
    out_path = Path(args.out)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)

    diag_out = dict(sm._LAST_DIAG)
    diag_out["speech_start"] = {
        "en":  {str(i["id"]): i.get("speech_start") or 0.0 for i in en_items},
        "dub": {str(i["id"]): i.get("speech_start") or 0.0 for i in dub_items},
    }
    diag_out["speech_end"] = {
        "en":  {str(i["id"]): i.get("speech_end") or 0.0 for i in en_items},
        "dub": {str(i["id"]): i.get("speech_end") or 0.0 for i in dub_items},
    }
    sidecar = out_path.with_name(out_path.stem + "_targets.json")
    with open(sidecar, "w", encoding="utf-8") as f:
        json.dump(diag_out, f, ensure_ascii=False, indent=2)

    print(f"\n  {n_matched}/{len(dub_items)} matched → {out_path}")
    print(f"  sections + onsets → {sidecar}")


if __name__ == "__main__":
    main()
