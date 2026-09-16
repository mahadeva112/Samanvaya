#!/usr/bin/env python3
"""
test_progress.py — checks for the anti-stall machinery.

A long run and a hung run look identical from the REAPER panel unless every
phase keeps the log breathing, so these are the guarantees that stop a silent
stretch from reappearing: the matcher heartbeat ticks and then stops, source
durations are probed once rather than per clip, a failed extraction never
sends an hour-long stem to ASR, and none of the new log lines are mistaken by
the Lua poller for clip progress.

No network and no API keys — everything runs against synthetic WAVs.

    python tools/test_progress.py
"""

import io
import re
import sys
import time
import wave
import struct
import tempfile
import contextlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import sync_matcher  # noqa: E402
from sync_matcher import (  # noqa: E402
    _Heartbeat,
    _source_duration,
    _extract_failed,
    _FFMPEG_TIMEOUT,
)

FAILURES = []

# The pattern auto_sync_pipeline.lua uses to count transcribed clips:
#   line:match('%[%s*%d+%]%s+"')
LUA_CLIP_LINE = re.compile(r'\[\s*\d+\]\s+"')


def check(name, condition, detail=""):
    if condition:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}  {detail}")
        FAILURES.append(name)


def make_wav(path, seconds, sr=16000):
    """A silent PCM WAV of the given length."""
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(struct.pack("<h", 0) * int(sr * seconds))
    return str(path)


def test_heartbeat():
    print("\nMatcher heartbeat")
    buf = io.StringIO()
    hb = _Heartbeat("unit test", every=0.25)
    with contextlib.redirect_stdout(buf):
        hb.start()
        time.sleep(1.1)
        hb.stop()
        time.sleep(0.6)          # nothing may be printed after stop()
    ticks = [l for l in buf.getvalue().splitlines() if "[WAIT]" in l]

    check("ticks while the call is in flight", len(ticks) >= 3,
          f"got {len(ticks)}")
    check("goes quiet once stopped", len(ticks) <= 5, f"got {len(ticks)}")
    check("reports elapsed time", bool(ticks) and "elapsed" in ticks[0])
    check("stop() is idempotent", (hb.stop() is None))


def test_source_duration(tmp):
    print("\nSource duration probe")
    short = make_wav(Path(tmp) / "short.wav", 2.0)
    sync_matcher._SOURCE_DURATION_CACHE.clear()

    d = _source_duration(short)
    check("reads a real duration", d is not None and abs(d - 2.0) < 0.05,
          f"got {d}")
    check("caches it", short in sync_matcher._SOURCE_DURATION_CACHE)
    check("second read agrees", _source_duration(short) == d)
    check("unreadable file is None, not a crash",
          _source_duration(str(Path(tmp) / "does-not-exist.wav")) is None)


def test_extract_failure_policy(tmp):
    print("\nExtraction-failure policy")
    short = make_wav(Path(tmp) / "clip.wav", 2.0)
    long_ = make_wav(Path(tmp) / "stem.wav", 45.0)
    sync_matcher._SOURCE_DURATION_CACHE.clear()

    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        r_short = _extract_failed(1, short, RuntimeError("boom"))
        r_long = _extract_failed(2, long_, RuntimeError("boom"))
    log = buf.getvalue()

    check("a clip-length source still falls back to the whole file",
          r_short == short, f"got {r_short}")
    check("an hour-long stem is skipped instead of sent to ASR",
          r_long is None, f"got {r_long}")
    check("the skip is explained in the log", "skipping this clip" in log)
    check("the original error is still reported", "boom" in log)


def test_ffmpeg_timeout():
    print("\nffmpeg is bounded")
    src = Path(sync_matcher.__file__).read_text(encoding="utf-8")
    check("timeout is set and positive", _FFMPEG_TIMEOUT > 0)
    check("subprocess.run carries it", "timeout=_FFMPEG_TIMEOUT" in src)
    check("a timeout becomes a readable error",
          "ffmpeg timed out after" in src)


def test_lua_log_parsing():
    print("\nLua poller still reads the log correctly")
    slice_line = '  [SLICE] EN: 100/2217 clips cut (7s)'
    wait_line = '  [WAIT] matcher call in flight - 20s elapsed'
    clip_line = '  [  3] "With little more"'

    check("[SLICE] is not counted as a transcribed clip",
          not LUA_CLIP_LINE.search(slice_line))
    check("[WAIT] is not counted as a transcribed clip",
          not LUA_CLIP_LINE.search(wait_line))
    check("a real transcript line is still counted",
          bool(LUA_CLIP_LINE.search(clip_line)))
    check("neither line fakes a STEP transition",
          "STEP" not in slice_line and "STEP" not in wait_line)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        test_heartbeat()
        test_source_duration(tmp)
        test_extract_failure_policy(tmp)
        test_ffmpeg_timeout()
        test_lua_log_parsing()

    print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) FAILED: {', '.join(FAILURES)}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
