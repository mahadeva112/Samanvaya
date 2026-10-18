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

**Windows, easiest:** run `Samanvaya_Setup_<version>.exe`. It needs no admin
rights and no Python. It installs into `%APPDATA%\REAPER\Scripts\Samanvaya`
(or a portable REAPER folder you pick), bundles its own Python, and adds
`Samanvaya.lua` to REAPER's Action List. Close REAPER before you run it.
Your API keys stay in place across updates and uninstalls.

To build that exe (needs Python 3.12 and Inno Setup 6 on the build machine):

```bash
powershell -ExecutionPolicy Bypass -File installer\build.ps1
```

The result is `installer\dist\Samanvaya_Setup_<version>.exe`. The version
comes from `VERSION`.

**Manual setup** — builds a local `venv` and installs the Python side:

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

A rail down the left lists the five stages of the job, each with a one-line
status under it ("6 VO · 6 dub", "Gateway · verified", "Optional"), so you can
see what is set without opening anything. The page you pick fills the middle,
and the worker log sits in a drawer along the bottom.

The foot of the rail holds the **Ready** card: a three-part meter (session,
connection, and the optional script), then **Start sync**, with either what
is still missing or what the run will do underneath. It turns into **Cancel
run** while a run is going and **Sync again** once one has finished. Because
it lives in the rail, it is in reach from every page.

The colours follow the job: teal is the VO lane, amber is the dub lane and the
one action that moves it.

**1 Session**: the two track names, the dub language, and where unplaced
clips are parked. Below them, a lane view draws every item REAPER currently
sees on those tracks, refreshed twice a second, so a wrong track name shows up
here rather than three minutes into a run.

**2 Connection**: how AI calls are made. Four modes, Gateway first:

| Mode | What it needs | When to use it |
|---|---|---|
| **Gateway** | LLM URL + LLM API key + ElevenLabs key | Your own OpenAI-compatible LLM endpoint. Give the host (or host + `/v1`); the client appends `/v1/chat/completions` itself. Pick the model from the list the endpoint returns. |
| **Server** | Server URL + access token | Shared machines. Your proxy holds the real keys; nothing secret lands locally. |
| **AI Studio** | Google AI Studio key (`AIza…`) + ElevenLabs key | Quickest Google route on your own machine. |
| **Vertex** | Service-account JSON + ElevenLabs key | No rate limits. Drop `vertex_key.json` next to the script and leave the path blank. |

Transcription is always ElevenLabs. The LLM only reads the transcripts to
match lines; it never hears the audio.

**3 Script**: optional. Paste the dub script and the matcher uses it as a
pivot; a blank line marks a topic change it relies on.

**4 Run**: Collect, Match and Place as three boxes with their own bars, the
overall progress and time left, and the lane view lit up as far as
transcription has got. If the worker goes quiet for more than a minute the
page says so, and after four minutes it flags a probable stall.

**5 Results**: four counts, then a filterable per-clip table showing where
each clip was, where it is now and how far it moved. Click a row to select
that item in REAPER and put the edit cursor on it.

**Log drawer**: shut, it shows the newest line the worker printed. Open, it
has level chips (errors, warnings), a text filter and a time gutter. A failed
run opens it for you.

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
