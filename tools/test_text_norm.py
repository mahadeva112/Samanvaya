#!/usr/bin/env python3
"""
test_text_norm.py — checks for Indic text normalisation and the language gate.

Normalisation bugs are silent: text still looks right in the log while every
comparison against it quietly fails. These tests pin the folding rules and the
wrong-language detector.

    python tools/test_text_norm.py
"""

import io
import sys
import unicodedata
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from sync_matcher import (  # noqa: E402
    _check_language,
    _dominant_script,
    normalize_text,
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


# ── Zero-width marks ─────────────────────────────────────────
eq("strips ZWJ", normalize_text("क‍ष"), "कष")
eq("strips ZWNJ", normalize_text("ক‌ষ"), "কষ")
eq("strips BOM and soft hyphen", normalize_text("﻿ab­c"), "abc")

# ── Nukta folding: both spellings must converge ───────────────
# Bengali য় — precomposed U+09DF vs base + nukta.
eq("bengali ya-nukta folds",
   normalize_text("য়"), normalize_text("য়"))
check("bengali ya-nukta is decomposed",
      "য়" not in normalize_text("য়"))
# Devanagari ज़ — precomposed U+095B vs base + nukta.
eq("devanagari za folds",
   normalize_text("ज़"), normalize_text("ज़"))
# A real word both ways: বাংলায় written with either spelling.
eq("same Bangla word, two spellings",
   normalize_text("বাংলায়"), normalize_text("বাংলায়"))

# NFC must run before folding, or a decomposed input would recompose later
# and miss the table.
eq("NFC then fold",
   normalize_text(unicodedata.normalize("NFD", "ज़")),
   normalize_text("ज़"))

# ── Digits ───────────────────────────────────────────────────
eq("devanagari digits", normalize_text("२०२६"), "2026")
eq("bengali digits", normalize_text("১২৩"), "123")
eq("tamil digits", normalize_text("௧௨௩"), "123")
eq("urdu digits", normalize_text("۱۲۳"), "123")

# ── Punctuation ──────────────────────────────────────────────
eq("danda becomes a full stop", normalize_text("शुरू करो।"), "शुरू करो.")
eq("double danda too", normalize_text("शान्ति॥"), "शान्ति.")
eq("urdu full stop", normalize_text("ختم۔"), "ختم.")
eq("smart quotes", normalize_text("“hi”"), '"hi"')
eq("em dash", normalize_text("a—b"), "a-b")

# ── Whitespace ───────────────────────────────────────────────
eq("collapses whitespace", normalize_text("  a \t\n b  "), "a b")
eq("empty input", normalize_text(""), "")
eq("None input", normalize_text(None), "")

# ── keep_lines: the dubbing script's structure must survive ──
script = "Para one line A.\nline B.\n\n\n\nPara two.\n"
kept = normalize_text(script, keep_lines=True)
check("keep_lines keeps the line break", "\n" in kept, repr(kept))
check("keep_lines keeps the paragraph break", "\n\n" in kept, repr(kept))
check("keep_lines caps blank runs at one", "\n\n\n" not in kept, repr(kept))
eq("keep_lines still folds danda",
   normalize_text("एक।\n\nदो।", keep_lines=True), "एक.\n\nदो.")
check("default mode flattens the script",
      "\n" not in normalize_text(script), repr(normalize_text(script)))

# ── Script detection ─────────────────────────────────────────
eq("detects devanagari", _dominant_script("नमस्ते"), "devanagari")
eq("detects bengali", _dominant_script("নমস্কার"), "bengali")
eq("detects tamil", _dominant_script("வணக்கம்"), "tamil")
eq("detects latin", _dominant_script("hello"), "latin")
eq("no script in digits", _dominant_script("123 !?"), None)
eq("ignore_latin skips loanwords",
   _dominant_script("Samyama মানে", ignore_latin=True), "bengali")
eq("ignore_latin on pure latin", _dominant_script("hello", ignore_latin=True), None)


# ── The wrong-language gate ──────────────────────────────────
def gate(texts, language):
    items = [{"transcript": t} for t in texts]
    buf = io.StringIO()
    with redirect_stdout(buf):
        _check_language(items, language, "DUB")
    return buf.getvalue()


bangla = ["আমি বাংলায় কথা বলছি"] * 40
hindi = ["मैं हिंदी में बोल रहा हूँ"] * 40

out = gate(bangla, "bn")
check("gate is quiet when the script matches",
      "WRONG LANGUAGE" not in out and "consistent with 'bn'" in out, out.strip())

out = gate(hindi, "bn")
check("gate fires when Bangla was asked for but Devanagari came back",
      "WRONG LANGUAGE" in out and "bengali" in out and "devanagari" in out,
      out.strip())

out = gate(bangla, "hi")
check("gate fires the other way round too", "WRONG LANGUAGE" in out, out.strip())

out = gate(bangla[:5], "hi")
check("gate stays silent on too small a sample", out.strip() == "", out.strip())

out = gate(["hello world"] * 40, "bn")
check("all-Latin transcripts don't trigger a false alarm",
      "WRONG LANGUAGE" not in out, out.strip())

# A real dub is mostly Bangla with English loanwords sprinkled in.
mixed = (["আমি বাংলায় কথা বলছি"] * 30 + ["Samyama"] * 8
         + ["meditation programme"] * 5)
out = gate(mixed, "bn")
check("loanword-heavy Bangla passes", "WRONG LANGUAGE" not in out, out.strip())

out = gate([], "bn")
check("no items is safe", out.strip() == "")
out = gate(bangla, "en")
check("english target is skipped", out.strip() == "")
out = gate(bangla, None)
check("missing language is safe", out.strip() == "")

print()
if FAILURES:
    print(f"{len(FAILURES)} check(s) failed: {', '.join(FAILURES)}")
    raise SystemExit(1)
print("all checks passed")
