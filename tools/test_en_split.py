#!/usr/bin/env python3
"""
test_en_split.py — checks for the EN sub-splitter.

The splitter only runs when ASR returns word timings for an over-long clip,
which can't be reproduced offline. These tests drive it with synthetic word
streams instead, including the cases that would quietly corrupt a timeline:
no silences at all, silences too short to use, and pieces that would come out
below the minimum length.

    python tools/test_en_split.py
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from sync_matcher import (  # noqa: E402
    _clean_words,
    _split_words_into_segments,
)

MAX_LEN, MIN_GAP, MIN_LEN = 12.0, 0.30, 1.50
FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}  {detail}")
        FAILURES.append(name)


def words_from(spec):
    """spec: list of (start, end). Builds a word stream."""
    return [{"text": f"w{i}", "start": s, "end": e}
            for i, (s, e) in enumerate(spec)]


def stream(n, word_len=0.4, gap=0.1, big_gap_every=0, big_gap=0.8):
    """n words, `gap` apart, with a longer pause every `big_gap_every` words."""
    spec, t = [], 0.0
    for i in range(n):
        spec.append((t, t + word_len))
        t += word_len
        t += big_gap if (big_gap_every and (i + 1) % big_gap_every == 0) else gap
    return words_from(spec)


def spans(words, ranges):
    return [words[b - 1]["end"] - words[a]["start"] for a, b in ranges]


def assert_tiles(name, words, ranges):
    """Every word used exactly once, in order, nothing lost or duplicated."""
    check(f"{name}: covers all words",
          ranges and ranges[0][0] == 0 and ranges[-1][1] == len(words),
          f"{ranges[:2]}…{ranges[-1:]} vs {len(words)} words")
    contiguous = all(a[1] == b[0] for a, b in zip(ranges, ranges[1:]))
    check(f"{name}: pieces are contiguous", contiguous, str(ranges))
    check(f"{name}: no empty piece", all(b > a for a, b in ranges), str(ranges))


# ── 1. A long stream with clear sentence pauses ───────────────
w = stream(200, word_len=0.4, gap=0.08, big_gap_every=10, big_gap=0.9)
r = _split_words_into_segments(w, MAX_LEN, MIN_GAP, MIN_LEN)
assert_tiles("clear pauses", w, r)
check("clear pauses: every piece within max_len",
      all(s <= MAX_LEN + 1e-9 for s in spans(w, r)),
      f"max piece {max(spans(w, r)):.2f}s")
check("clear pauses: no piece under min_len",
      all(s >= MIN_LEN - 1e-9 for s in spans(w, r)),
      f"min piece {min(spans(w, r)):.2f}s")
check("clear pauses: produced several pieces", len(r) > 5, str(len(r)))

# ── 2. No silence anywhere — must keep the clip whole ─────────
w2 = stream(200, word_len=0.4, gap=0.05)
r2 = _split_words_into_segments(w2, MAX_LEN, MIN_GAP, MIN_LEN)
check("no usable silence: kept whole", r2 == [(0, len(w2))], str(r2))

# ── 3. Exactly one usable silence, in a bad place ─────────────
# One pause 0.5s in: splitting there would leave a piece under min_len, so
# the splitter must refuse and keep the clip whole rather than emit a scrap.
spec, t = [], 0.0
for i in range(60):
    spec.append((t, t + 0.4))
    t += 0.4 + (0.9 if i == 0 else 0.05)
w3 = words_from(spec)
r3 = _split_words_into_segments(w3, MAX_LEN, MIN_GAP, MIN_LEN)
check("only a bad split point: kept whole", r3 == [(0, len(w3))], str(r3))

# ── 4. Empty and single-word input ───────────────────────────
check("empty stream", _split_words_into_segments([], MAX_LEN, MIN_GAP, MIN_LEN) == [])
w4 = words_from([(0.0, 0.5)])
check("single word", _split_words_into_segments(w4, MAX_LEN, MIN_GAP, MIN_LEN) == [(0, 1)])

# ── 5. Already short enough — no split ───────────────────────
w5 = stream(10, word_len=0.4, gap=0.5)
r5 = _split_words_into_segments(w5, MAX_LEN, MIN_GAP, MIN_LEN)
check("already short: untouched", r5 == [(0, len(w5))], str(r5))

# ── 6. Balanced pieces, not ragged ───────────────────────────
# A uniform stream of equal pauses should split near the middle each time.
w6 = stream(150, word_len=0.4, gap=0.4)
r6 = _split_words_into_segments(w6, MAX_LEN, MIN_GAP, MIN_LEN)
s6 = spans(w6, r6)
assert_tiles("balanced", w6, r6)
check("balanced: pieces are similar length",
      (max(s6) - min(s6)) < MAX_LEN * 0.75,
      f"{min(s6):.2f}s–{max(s6):.2f}s")

# ── 7. A 352s clip like the one in the real project ──────────
w7 = stream(900, word_len=0.35, gap=0.05, big_gap_every=12, big_gap=0.7)
r7 = _split_words_into_segments(w7, MAX_LEN, MIN_GAP, MIN_LEN)
total = w7[-1]["end"] - w7[0]["start"]
assert_tiles("352s-like", w7, r7)
check("352s-like: all pieces within max_len",
      all(s <= MAX_LEN + 1e-9 for s in spans(w7, r7)),
      f"max piece {max(spans(w7, r7)):.2f}s")
check("352s-like: piece count is sane",
      total / MAX_LEN <= len(r7) <= total / MIN_LEN,
      f"{len(r7)} pieces for {total:.0f}s")

# ── 8. _clean_words filters non-word entries ─────────────────
raw = [
    {"type": "word", "text": "hello", "start": 0.0, "end": 0.4},
    {"type": "spacing", "text": " ", "start": 0.4, "end": 0.5},
    {"type": "audio_event", "text": "(laughs)", "start": 0.5, "end": 1.0},
    {"type": "word", "text": "world", "start": 1.0, "end": 1.4},
    {"type": "word", "text": "", "start": 1.4, "end": 1.5},          # empty
    {"type": "word", "text": "bad", "start": 2.0, "end": 1.0},       # end<start
    {"type": "word", "text": "notime"},                              # no timings
    {"text": "untyped", "start": 3.0, "end": 3.4},                   # legacy shape
]
cw = _clean_words(raw)
check("_clean_words keeps only real words",
      [x["text"] for x in cw] == ["hello", "world", "untyped"],
      str([x["text"] for x in cw]))
check("_clean_words on None", _clean_words(None) == [])
check("_clean_words sorts by start",
      _clean_words([{"text": "b", "start": 5.0, "end": 5.2},
                    {"text": "a", "start": 1.0, "end": 1.2}])[0]["text"] == "a")

# ── 9. End-to-end: _split_long_en_items builds valid sub-items ──
# Real audio isn't available offline, so stub the two I/O calls and check the
# arithmetic that actually matters: pieces must tile the original clip exactly,
# and each one's take_offset must still point at its own audio.
import sync_matcher as sm  # noqa: E402

_fake_words = stream(400, word_len=0.35, gap=0.06, big_gap_every=10, big_gap=0.8)
_parent_dur = round(_fake_words[-1]["end"] + 1.2, 6)   # trailing silence

sm.get_audio_for_item = lambda *a, **k: "stub.wav"
sm.transcribe = lambda *a, **k: {"text": "x", "speech_start": 0.0,
                                 "speech_end": 0.0, "words": _fake_words}

parent = {"id": 7, "position": 100.0, "duration": _parent_dur,
          "wav_path": "movie.mp4", "take_offset": 40.0}
neighbour = {"id": 8, "position": 100.0 + _parent_dur + 5.0, "duration": 2.0,
             "wav_path": "movie.mp4", "take_offset": 200.0}

out, added = sm._split_long_en_items([parent, neighbour], None,
                                     "elevenlabs", "k", None)
subs = [i for i in out if i.get("virtual_from") == 7]

check("e2e: parent replaced by sub-items", added == len(subs) - 1 and len(subs) > 5,
      f"added={added} subs={len(subs)}")
check("e2e: untouched neighbour survives",
      any(i["id"] == 8 for i in out) and not any(i["id"] == 7 for i in out))
check("e2e: sorted by position",
      all(a["position"] <= b["position"] for a, b in zip(out, out[1:])))
check("e2e: ids are unique",
      len({i["id"] for i in out}) == len(out))
check("e2e: first piece starts at the parent",
      abs(subs[0]["position"] - parent["position"]) < 1e-6,
      f"{subs[0]['position']}")
check("e2e: last piece ends at the parent's end",
      abs((subs[-1]["position"] + subs[-1]["duration"])
          - (parent["position"] + parent["duration"])) < 1e-6,
      f"{subs[-1]['position'] + subs[-1]['duration']} vs "
      f"{parent['position'] + parent['duration']}")
check("e2e: pieces tile with no gap or overlap",
      all(abs((a["position"] + a["duration"]) - b["position"]) < 1e-6
          for a, b in zip(subs, subs[1:])))
check("e2e: durations sum to the parent",
      abs(sum(i["duration"] for i in subs) - parent["duration"]) < 1e-6,
      f"{sum(i['duration'] for i in subs)} vs {parent['duration']}")
check("e2e: take_offset tracks position",
      all(abs((i["take_offset"] - parent["take_offset"])
              - (i["position"] - parent["position"])) < 1e-6 for i in subs))
check("e2e: speech_start is inside the piece",
      all(0.0 <= i["speech_start"] <= i["duration"] for i in subs),
      str([round(i["speech_start"], 3) for i in subs[:5]]))
check("e2e: every piece has text",
      all(i["transcript"].strip() for i in subs))
check("e2e: no word text lost",
      sum(len(i["transcript"].split()) for i in subs) == len(_fake_words),
      f"{sum(len(i['transcript'].split()) for i in subs)} vs {len(_fake_words)}")
check("e2e: short clips alone are a no-op",
      sm._split_long_en_items([neighbour], None, "elevenlabs", "k", None)
      == ([neighbour], 0))

print()
if FAILURES:
    print(f"{len(FAILURES)} check(s) failed: {', '.join(FAILURES)}")
    raise SystemExit(1)
print("all checks passed")
