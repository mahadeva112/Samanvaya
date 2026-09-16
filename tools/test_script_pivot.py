#!/usr/bin/env python3
"""
test_script_pivot.py — checks for script-unit splitting and token alignment.

The alignment is the part that must never silently go backwards or invent a
correspondence, so these tests hammer the ordering guarantees: ASR noise,
dropped words, repeated sentences, re-reads, and a script that doesn't belong
to the recording at all.

    python tools/test_script_pivot.py
"""

import io
import sys
import time
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from sync_matcher import (  # noqa: E402
    _lis_by_second,
    _match_tokens,
    align_clips_to_units,
    align_token_streams,
    split_script_units,
)

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}  {detail}")
        FAILURES.append(name)


def eq(name, got, want):
    check(name, got == want, f"got {got!r} want {want!r}")


def monotone(pairs):
    return all(a[0] < b[0] and a[1] < b[1] for a, b in zip(pairs, pairs[1:]))


# ── Script unit splitting ────────────────────────────────────
SCRIPT = """Sadhguru:
यह पहला वाक्य है। यह दूसरा वाक्य है।

यह तीसरा वाक्य है? हाँ!
और यह चौथा।
"""
units = split_script_units(SCRIPT)
eq("splits into thought units", len(units), 5)
check("speaker heading dropped",
      not any("Sadhguru" in u["text"] for u in units),
      str([u["text"] for u in units]))
# Unit text comes out normalised — danda folded to a full stop, which is what
# the matcher prompt's boundary rules look for.
eq("first unit", units[0]["text"], "यह पहला वाक्य है.")
check("paragraph index advances", units[0]["para"] != units[-1]["para"])
eq("ids are sequential", [u["id"] for u in units], list(range(len(units))))

# Danda-only script: normalisation folds । to '.', so it must still split.
danda = split_script_units("पहला वाक्य। दूसरा वाक्य। तीसरा वाक्य।")
eq("danda script splits", len(danda), 3)

eq("empty script", split_script_units(""), [])
eq("None script", split_script_units(None), [])
eq("punctuation-only script", split_script_units("... !!! ???"), [])
check("no-terminator script still yields a unit",
      len(split_script_units("just one line with no full stop")) == 1)

# Deeper levels cut further.
sentence = "First part, second part; third part."
check("level 1 keeps commas inside the unit",
      len(split_script_units(sentence, level=1)) == 1)
check("level 2 splits on semicolon",
      len(split_script_units(sentence, level=2)) == 2)
check("level 3 splits on comma too",
      len(split_script_units(sentence, level=3)) == 3)

# ── LIS ──────────────────────────────────────────────────────
eq("lis on empty", _lis_by_second([]), [])
eq("lis keeps an increasing run",
   _lis_by_second([(0, 1), (1, 2), (2, 3)]), [(0, 1), (1, 2), (2, 3)])
eq("lis drops the backward jump",
   _lis_by_second([(0, 1), (1, 9), (2, 2), (3, 3)]),
   [(0, 1), (2, 2), (3, 3)])
check("lis result is monotone on a shuffled input",
      monotone(_lis_by_second([(i, j) for i, j in
                               enumerate([5, 1, 6, 2, 7, 3, 8, 4])])))

# ── Token alignment ──────────────────────────────────────────
base = ("the mind is not a thing it is a process consciousness has no form "
        "and no boundary you cannot be what is yours samyama begins now")
a = base.split()

eq("identical streams align fully", len(align_token_streams(a, a)), len(a))
check("identical streams are monotone", monotone(align_token_streams(a, a)))

# ASR noise: a few words wrong.
noisy = list(a)
for idx in (3, 11, 19):
    noisy[idx] = "xxx"
pairs = align_token_streams(a, noisy)
check("noisy stream still mostly aligns", len(pairs) >= len(a) - 6, len(pairs))
check("noisy alignment is monotone", monotone(pairs))

# Dropped words.
missing = [w for i, w in enumerate(a) if i % 7]
pairs = align_token_streams(a, missing)
check("dropped words still align", len(pairs) >= len(missing) - 4, len(pairs))
check("dropped-word alignment is monotone", monotone(pairs))

# Empty inputs.
eq("empty vs full", align_token_streams([], a), [])
eq("full vs empty", align_token_streams(a, []), [])

# Unrelated text must not be forced into a correspondence.
other = "completely different words about unrelated subjects entirely".split()
pairs = align_token_streams(a, other)
check("unrelated streams align almost nothing", len(pairs) <= 2, str(pairs))

# Repetition: the same sentence twice must not scramble the order.
rep = (a + a)
pairs = align_token_streams(a, rep)
check("repeated content stays monotone", monotone(pairs), str(pairs[:6]))

# Performance guard on a realistic size.
big_script = (base + " ") * 260              # ~7800 tokens
big_asr = big_script.replace("process", "prosess")
t0 = time.time()
pairs = align_token_streams(big_script.split(), big_asr.split())
elapsed = time.time() - t0
check("7.8k-token alignment is monotone", monotone(pairs))
check(f"7.8k-token alignment finishes fast ({elapsed:.2f}s)", elapsed < 20.0,
      f"{elapsed:.1f}s")

# ── Clips to units ───────────────────────────────────────────
UNITS = split_script_units(
    "The mind is not a thing. It is a process. "
    "Consciousness has no form. Samyama begins now."
)
eq("four units for the fixture", len(UNITS), 4)


def clips(texts, start=0.0):
    out, t = [], start
    for i, text in enumerate(texts, 1):
        out.append({"id": i, "position": t, "duration": 2.0,
                    "transcript": text})
        t += 2.5
    return out


# One clip per unit, clean.
got, stats = align_clips_to_units(
    clips(["the mind is not a thing", "it is a process",
           "consciousness has no form", "samyama begins now"]), UNITS)
eq("clean case assigns every clip", len(got), 4)
eq("clean case units in order", [got[i]["unit"] for i in (1, 2, 3, 4)],
   [0, 1, 2, 3])
check("clean case is confident",
      all(got[i]["coverage"] > 0.9 for i in got), str(got))

# A sentence split across two clips must land on one unit.
got, _ = align_clips_to_units(
    clips(["the mind is not", "a thing", "it is a process"]), UNITS)
eq("split sentence shares a unit", got[1]["unit"], got[2]["unit"])
check("following clip advances", got[3]["unit"] > got[1]["unit"])

# An ASR failure (empty transcript) keeps the clip, at zero confidence.
got, stats = align_clips_to_units(
    clips(["the mind is not a thing", "", "consciousness has no form"]), UNITS)
eq("empty transcript keeps its clip", len(got), 3)
eq("empty transcript is carried", got[2]["coverage"], 0.0)
eq("carried count reported", stats["carried"], 1)

# A re-read: the artist repeats unit 0 after moving on. Monotone alignment
# finds nothing for the duplicate (the script pointer is already past unit 0),
# so the clip arrives with no votes and is carried forward. Both takes survive
# — choosing between them is not implemented, and the clip is never lost.
got, stats = align_clips_to_units(
    clips(["the mind is not a thing", "it is a process",
           "the mind is not a thing", "consciousness has no form"]), UNITS)
eq("re-read keeps every clip", len(got), 4)
eq("the duplicate is carried, not matched", stats["carried"], 1)
eq("nothing votes backwards", stats["backward_dropped"], 0)
check("assignment stays non-decreasing",
      all(got[i]["unit"] <= got[i + 1]["unit"]
          for i in sorted(got) if i + 1 in got), str(got))
check("the duplicate never lands before its predecessor",
      got[3]["unit"] >= got[2]["unit"], str(got))

# Wrong script entirely — coverage must collapse so the caller can bail.
got, stats = align_clips_to_units(
    clips(["completely unrelated speech about other matters"] * 4), UNITS)
check("wrong script gives near-zero coverage",
      stats["aligned_tokens"] <= 2, str(stats))

# Degenerate inputs.
eq("no units", align_clips_to_units(clips(["hello"]), [])[0], {})
eq("no clips", align_clips_to_units([], UNITS)[0], {})

# ── Tokenisation ─────────────────────────────────────────────
eq("tokens fold danda", _match_tokens("शुरू करो।"), ["शुरू", "करो"])
eq("tokens lowercase latin", _match_tokens("The Mind"), ["the", "mind"])
eq("tokens fold digits", _match_tokens("२०२६ में"), ["2026", "में"])
eq("tokens on empty", _match_tokens(""), [])

# ── Real Hindi text, end to end ──────────────────────────────
# Fixtures in English prove the algorithm; they prove nothing about Indic
# script handling, which is where `\w+` quietly destroyed every word. This
# builds a script out of real cached Hindi transcripts, cuts them into clips,
# corrupts words the way ASR does, and checks each clip finds its own unit.
# Skipped when no cache is present (fresh checkout).
cache_path = ROOT / "sync_cache.json"
if not cache_path.exists():
    print("  skip  real-Hindi end-to-end (no sync_cache.json)")
else:
    import json
    import random

    with open(cache_path, encoding="utf-8") as fh:
        cache = json.load(fh)
    sentences = [
        v["text"].strip()
        for k, v in cache.items()
        if isinstance(v, dict) and "__hi__" in k
        and len(_match_tokens(v.get("text") or "")) >= 4
    ][:200]

    if len(sentences) < 50:
        print(f"  skip  real-Hindi end-to-end (only {len(sentences)} usable)")
    else:
        check("real Hindi tokenises into whole words",
              all(len(_match_tokens(s)) >= 4 for s in sentences[:20]),
              str(_match_tokens(sentences[0])))
        # Devanagari words must survive intact, vowel signs and all.
        longest = max(_match_tokens(" ".join(sentences)), key=len)
        check("tokens keep combining marks", len(longest) >= 4, longest)

        script = "\n\n".join(
            " ".join(sentences[i:i + 4]) for i in range(0, len(sentences), 4))
        real_units = split_script_units(script)
        # Unit count tracks the script's punctuation, not its sentence count:
        # ASR text (used here as a stand-in script) often has no terminal
        # danda, so several sentences share a unit. A real dubbing script is
        # punctuated and splits finer. What must hold is that the paragraphs
        # split at all, and that clips find their unit — checked below.
        n_paras = script.count("\n\n") + 1
        check("real script splits past paragraph level",
              len(real_units) > n_paras,
              f"{len(real_units)} units from {n_paras} paragraphs")

        rng = random.Random(7)
        real_clips, expected, cid = [], {}, 0
        pos = 0.0
        for u_idx, unit in enumerate(real_units):
            words = _match_tokens(unit["text"])
            if not words:
                continue
            cut = len(words) // 2 if len(words) >= 6 else len(words)
            for chunk in ([words[:cut], words[cut:]] if cut < len(words)
                          else [words]):
                if not chunk:
                    continue
                noisy = [("zzq" + w if rng.random() < 0.10 else w)
                         for w in chunk]
                cid += 1
                real_clips.append({"id": cid, "position": pos, "duration": 1.5,
                                   "transcript": " ".join(noisy)})
                expected[cid] = u_idx
                pos += 2.0

        got, stats = align_clips_to_units(real_clips, real_units)
        assigned = len(got)
        correct = sum(1 for cid, info in got.items()
                      if info["unit"] == expected.get(cid))
        share = correct / max(1, len(real_clips))
        print(f"        {len(real_clips)} clips over {len(real_units)} units, "
              f"{stats['aligned_tokens']}/{stats['clip_tokens']} words aligned")
        check(f"real Hindi: assigns nearly every clip ({assigned}/{len(real_clips)})",
              assigned >= len(real_clips) * 0.95)
        check(f"real Hindi: lands on the right unit ({share * 100:.1f}%)",
              share >= 0.90, f"{correct}/{len(real_clips)}")
        check("real Hindi: assignment is non-decreasing",
              all(got[a]["unit"] <= got[b]["unit"]
                  for a, b in zip(sorted(got), sorted(got)[1:])))

print()
if FAILURES:
    print(f"{len(FAILURES)} check(s) failed: {', '.join(FAILURES)}")
    raise SystemExit(1)
print("all checks passed")
