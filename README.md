# Samanvaya · समन्वय

Dub alignment for REAPER. Point it at a VO track and a dub track, press one
button, and every dub clip lands on the position of the line it actually
corresponds to.

Samanvaya does one thing. It does not translate, it does not synthesise
speech, it does not touch your source audio — it only decides *where each dub
clip belongs* and moves it there.

---

## How a run works

1. **Collect** — reads every item on your VO track and your Dub track,
   writing their source paths and take offsets to `sync_config.json`.
2. **Match** — `sync_matcher.py` transcribes both sides with ElevenLabs, then
   asks Gemini which dub line corresponds to which VO line. If you pasted a
   reference script, it pivots through that for better grouping.
3. **Place** — each matched dub item moves to its VO counterpart's position,
   under a single undo point. Anything unmatched is parked on a separate
   track so nothing is ever silently lost.

Your timeline is untouched until step 3, so cancelling mid-run costs you
nothing but time.

---

## Install

**One-time setup** — builds a local `venv` and installs the Python side:

```bash
setup.bat
```

On macOS/Linux:

```bash
bash setup.sh
```

Add `--direct` (`setup.bat --direct`) if you plan to call Google directly
rather than through a proxy — it pulls in `google-genai` and `soundfile`.
Server mode needs only the standard library.

**Load the panel in REAPER:**

Actions → Show action list → New action → Load ReaScript… → pick
`Samanvaya.lua`. Assign it a toolbar button or a shortcut and you never have
to open that dialog again.

The panel needs **ReaImGui**. If it's missing, Samanvaya detects that on first
run and walks you through installing it (it can even install ReaPack for you).

---

## The panel

A rail down the left lists every stage of the job; the pane on the right shows
whichever one you select, and an action bar runs along the bottom. Neither the
rail nor the bar scrolls, so the Start button and the readiness line stay on
screen the whole time you are configuring.

The rail is the same in every phase, and covers the run and its results as well
as the setup sections — so a finished run is somewhere you navigate back to
rather than a screen that replaced the form. A divider separates the stages
that configure a run from the two that watch one, and each entry carries a
status dot: you can see Connection is complete without opening it.

**01 Session** — the two track names, the dub language, and where unplaced
clips are parked. It shows a live count of how many items REAPER currently
sees on each track, refreshed once a second, so a wrong track name shows up
here rather than three minutes into a run.

**02 Connection** — how AI calls are made. Four modes:

| Mode | What it needs | When to use it |
|---|---|---|
| **Server** | Server URL + access token | Shared machines. Your proxy holds the real keys; nothing secret lands locally. |
| **AI Studio** | Google AI Studio key (`AIza…`) | Quickest to get going on your own machine. |
| **Vertex** | Service-account JSON | No rate limits. Drop `vertex_key.json` next to the script and leave the path blank. |
| **Gateway** | OpenAI-compatible base URL + bearer key | An internal LiteLLM-style gateway. Give the host (or host + `/v1`); the client appends `/v1/chat/completions` itself. |

Transcription is always ElevenLabs and matching is always Gemini — Gemini
never sees the audio. In every mode except Server you need an ElevenLabs key
alongside whichever Gemini credential the mode asks for.

**03 Script** — optional. Paste the dub script and the matcher uses it as a
pivot; a blank line marks a topic change it relies on.

**04 Run** — live progress: the three steps, separate meters for VO and dub
transcription, and the worker log colour-coded by severity. If the worker goes
quiet for more than a minute the pane says so, and after four minutes it flags
a probable stall rather than spinning forever.

**05 Results** — what was placed and what was not: four counts, then a
filterable per-clip table. A failed run shows its error output here instead.

The action bar carries **Start sync** while you are configuring (with either what is still missing or "Ready
— 12 VO clips, 11 dub clips"), **Cancel run** while a run is going, and **Sync
again** once one has finished.

Settings are saved to `sync_pipeline_settings.json` next to the script. That
file holds your keys and is gitignored — keep it that way.

---

## Fixing what the matcher missed

Unmatched clips sit on the track named in **01 Session** (**Un sync** by
default). To place one by hand: select the VO item you want to align to,
hover the dub item, and run `Sync_Item.lua`
(load it as an action the same way). It snaps the hovered item to the selected
item's sync point, honouring snap offsets.

---

## Layout

```
Samanvaya.lua                 the REAPER panel — the whole UI
sync_matcher.py               the engine: transcribe, match, emit positions
run_sync.py                   cross-platform launcher REAPER calls
Sync_Item.lua                 manual single-item aligner
SyncingPrompt.txt             the matching prompt
sync_pipeline_settings.json   your settings and keys (gitignored)
setup.bat / setup.sh          one-time venv build
server/                       optional proxy for "Server" connection mode
tools/                        metrics and test harnesses for tuning matching
```

Files a run produces — `sync_config.json`, `sync_results.json`,
`sync_targets.json`, `sync_cache.json`, `sync_python_log.txt` — are written
next to the script and are safe to delete between sessions. The cache is worth
keeping: it saves re-transcribing clips you have already run.

---

## When something goes wrong

The **Run** pane is the whole story — it tails the Python worker live and
colours errors. `sync_python_log.txt` holds the same output on disk, and
**Results** keeps the error output of a failed run.

Most failures are one of three things: a wrong key or URL (check **02
Connection**), a stale venv (re-run `setup.bat`), or direct mode missing its
extra packages (`setup.bat --direct`).
