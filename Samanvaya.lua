-- ============================================================
-- SAMANVAYA  ·  समन्वय
-- Dub alignment for REAPER — collect, AI-match, place on the timeline.
--
-- What it does:
--   1. Reads every item from your VO track and your Dub track
--   2. Writes a config JSON with source paths + chunk offsets
--   3. Calls sync_matcher.py (transcribes both sides, matches semantically)
--   4. Moves each Dub item to the position of the line it matches
--   5. Parks anything it could not place on an "Un sync" track
--
-- Requirements:
--   - ReaImGui (free, via ReaPack). Missing? The script walks you through it.
--   - Python 3.9+ (3.11+ recommended)
--   - One-time install: setup.bat (Windows) / setup.sh (macOS) builds ./venv.
--     Server mode needs only the standard library; direct mode adds
--     google-genai + soundfile (install with:  setup.bat --direct)
--   - sync_matcher.py + run_sync.py must sit in the SAME folder as this file.
--
-- How to run:
--   Actions > Show action list > New action > Load ReaScript
--   Select this file, then Run
-- ============================================================

-- ── DEFAULT SETTINGS  (dialog lets you change these) ─────
local TRACK_VO_NAME    = "Dialogue VO"
local TRACK_DUB_NAME   = "Dub"
local TRACK_UNSYNC     = "Un sync"
local DUB_LANGUAGE     = "ne"
local MATCH_MODE       = "gemini"      -- locked: Gemini semantic matching only

-- Transcription provider — which service turns audio → text:
--   elevenlabs | gemini
local ASR_PROVIDER     = "elevenlabs"

-- Which Scribe generation transcribes. v2 is the default; the matcher and the
-- proxy server default to the same name, so the pane never reports a
-- generation different from the one that actually ran. Saved to
-- sync_pipeline_settings.json and exported as SYNC_ELEVENLABS_MODEL, so
-- changing it here changes it for the whole pipeline.
local ELEVENLABS_MODEL = "scribe_v2"

-- Matching always uses Gemini. Backend chooses HOW to call it:
--   vertex  = Google Cloud service-account JSON (fast, no rate limits)
--   rest    = Google AI Studio API key (AIza...), Gemini's native endpoint
--   gateway = an OpenAI-compatible proxy serving Gemini (e.g. an internal
--             LiteLLM gateway). Uses {GEMINI_BASE_URL}/v1/chat/completions
--             with the Gemini key sent as a Bearer token (often "sk-...").
local GEMINI_BACKEND   = "vertex"

-- Gemini model — edit freely. Look up current names at
-- https://ai.google.dev/gemini-api/docs/models  (or check Vertex Model Garden).
local GEMINI_MODEL     = "gemini-2.5-pro"

-- Base URL for the OpenAI-compatible gateway. Only used when
-- GEMINI_BACKEND = "gateway". Example: https://your-gateway.example.com
-- Blank = not used (vertex/rest talk to Google directly).
local GEMINI_BASE_URL  = ""

-- Per-provider keys. Stored locally in sync_pipeline_settings.json (gitignored).
local ELEVENLABS_KEY   = ""
local GEMINI_KEY       = ""

-- Path to a Google Cloud service-account JSON for Vertex AI. Blank = look
-- for "vertex_key.json" next to this script.
local VERTEX_KEY_PATH  = ""

-- Server proxy (thin-client mode). When API_BASE is set, every AI call is
-- routed through your server, which holds the real provider keys — so the
-- ElevenLabs/Gemini keys above can stay blank on shared machines. API_TOKEN
-- is the per-user access token you issued. Blank API_BASE = direct/local mode.
-- API_BASE is the EFFECTIVE value handed to Python; it is derived from
-- CONN_MODE + SERVER_URL by _apply_conn_mode(), never edited directly.
local API_BASE         = ""
local API_TOKEN        = ""

-- Connection mode — the single top-level choice the dialog presents:
--   "server"  : route everything through your proxy (SERVER_URL + API_TOKEN)
--   "studio"  : direct, Google AI Studio key (AIza…)      -> gemini_backend rest
--   "vertex"  : direct, Google service account JSON        -> gemini_backend vertex
--   "gateway" : direct, OpenAI-compatible LiteLLM base URL -> gemini_backend gateway
-- SERVER_URL is remembered separately from API_BASE so toggling modes never
-- loses the typed proxy URL. _apply_conn_mode() maps CONN_MODE onto the
-- underlying API_BASE / GEMINI_BACKEND that the rest of the code + Python read.
local CONN_MODE        = "gateway"
local SERVER_URL       = ""

-- Reference (dub) script. Pasted straight into the panel. REAPER's input
-- box collapses newlines on macOS, so use "||" between paragraphs — the
-- save step converts those to real newlines.
local SCRIPT_TEXT      = ""

-- Resolved at runtime by find_python() — never exposed in the dialog.
local PYTHON_CMD       = ""
-- ─────────────────────────────────────────────────────────


-- ═══════════════════════════════════════════════════════════
-- PERSISTENT SETTINGS (saved to settings.json next to script)
-- ═══════════════════════════════════════════════════════════

local function get_settings_path()
  local info = debug.getinfo(1, "S")
  local src  = info.source:match("@(.+)") or ""
  local dir  = src:match("(.+)[/\\]") or "."
  return dir .. "/sync_pipeline_settings.json"
end

-- Coerce free-text values to what the Python side accepts, so a typo or a
-- stray capital letter ("Gemini", "VERTEX") can never crash argparse.
-- Defined BEFORE load_settings so its body can see them (lexical scoping).
local function _norm_mode(m)
  -- Gemini semantic matching is the ONLY supported mode. Legacy settings
  -- files may still say hybrid/duration — coerce them. If Gemini fails the
  -- Python side hard-errors (exit 1) instead of falling back.
  return "gemini"
end

local function _norm_backend(b)
  b = tostring(b or ""):lower()
  if b ~= "vertex" and b ~= "rest" and b ~= "gateway" and b ~= "auto" then
    b = "vertex"
  end
  return b
end

local function _norm_conn_mode(m)
  m = tostring(m or ""):lower()
  if m ~= "server" and m ~= "studio" and m ~= "vertex" and m ~= "gateway" then
    return nil   -- caller derives from legacy fields
  end
  return m
end

-- Map the single CONN_MODE choice onto the underlying values the rest of the
-- code and the Python worker actually read (API_BASE gates proxy mode;
-- GEMINI_BACKEND selects how Gemini is called). Idempotent — safe to call every
-- UI frame and again right before a run/save.
local function _apply_conn_mode()
  if CONN_MODE == "server" then
    API_BASE = SERVER_URL          -- non-empty URL turns the proxy on
  else
    API_BASE = ""                  -- direct: never route through a proxy
    if     CONN_MODE == "studio"  then GEMINI_BACKEND = "rest"
    elseif CONN_MODE == "vertex"  then GEMINI_BACKEND = "vertex"
    elseif CONN_MODE == "gateway" then GEMINI_BACKEND = "gateway" end
  end
end

local function load_settings()
  local path = get_settings_path()
  local f = io.open(path, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()

  -- Simple JSON parsing for flat key-value pairs.
  -- IMPORTANT: unescape \\ and \" — save_settings() escapes them, so without
  -- this a Windows path like C:\Users\... doubles its backslashes on every
  -- save/load cycle (C:\\Users → C:\\\\Users → ...) and slowly corrupts.
  local function jval(key)
    local val = content:match('"' .. key .. '"%s*:%s*"([^"]*)"')
    if val then val = val:gsub('\\(["\\])', '%1') end
    return val
  end

  local v
  v = jval("track_vo")         if v and v ~= "" then TRACK_VO_NAME    = v end
  v = jval("track_dub")        if v and v ~= "" then TRACK_DUB_NAME   = v end
  v = jval("language")         if v and v ~= "" then DUB_LANGUAGE     = v end
  v = jval("match_mode")       if v and v ~= "" then MATCH_MODE       = v end
  v = jval("track_unsync")     if v and v ~= "" then TRACK_UNSYNC     = v end
  v = jval("asr_provider")     if v and v ~= "" then ASR_PROVIDER     = v end
  v = jval("gemini_backend")   if v and v ~= "" then GEMINI_BACKEND   = v end
  v = jval("gemini_model")     if v and v ~= "" then GEMINI_MODEL     = v end
  v = jval("gemini_base_url")  if v then GEMINI_BASE_URL = v end

  -- Per-provider keys
  v = jval("elevenlabs_key")   if v then ELEVENLABS_KEY  = v end
  -- Blank in an older settings file means "never chosen" — keep the v3
  -- default rather than writing an empty model id into the request.
  v = jval("elevenlabs_model") if v and v ~= "" then ELEVENLABS_MODEL = v end
  v = jval("gemini_key")       if v then GEMINI_KEY      = v end
  v = jval("vertex_key_path")  if v then VERTEX_KEY_PATH = v end
  v = jval("api_base")         if v then API_BASE        = v end
  v = jval("api_token")        if v then API_TOKEN       = v end
  -- SERVER_URL remembers the proxy URL across mode toggles; fall back to the
  -- legacy api_base value so older settings files still load their server.
  v = jval("server_url")
  if v and v ~= "" then SERVER_URL = v
  elseif API_BASE ~= "" then SERVER_URL = API_BASE end

  -- Transcription is locked to ElevenLabs. Coerce any legacy value
  -- (gemini/bhashini/openai) so nothing else can leak in from an old or
  -- hand-edited settings.json.
  ASR_PROVIDER = "elevenlabs"
  -- Same for mode/backend — a hand-edited or legacy settings.json must never
  -- feed a value the Python argparse would reject.
  MATCH_MODE     = _norm_mode(MATCH_MODE)
  GEMINI_BACKEND = _norm_backend(GEMINI_BACKEND)

  -- Connection mode: use the saved value, else derive from legacy fields so
  -- existing installs land on the right mode without re-picking it.
  CONN_MODE = _norm_conn_mode(jval("conn_mode"))
  if not CONN_MODE then
    if API_BASE ~= "" then CONN_MODE = "server"
    elseif GEMINI_BACKEND == "rest"    then CONN_MODE = "studio"
    elseif GEMINI_BACKEND == "gateway" then CONN_MODE = "gateway"
    else CONN_MODE = "vertex" end
  end

  -- Multi-line script_text needs special parsing (jval bails at first quote).
  -- Capture between "script_text":" ... " just before the next key line.
  do
    local raw = content:match('"script_text"%s*:%s*"(.-)"%s*[,}]')
    if raw then
      raw = raw:gsub('\\"', '"'):gsub('\\n', '\n'):gsub('\\t', '\t'):gsub('\\\\', '\\')
      SCRIPT_TEXT = raw
    end
  end

  -- Legacy migration from earlier versions
  v = jval("api_key")
  if v and v ~= "" and ELEVENLABS_KEY == "" then
    ELEVENLABS_KEY = v
  end

  v = jval("python_cmd")       if v and v ~= "" then PYTHON_CMD = v end

  -- Reconcile API_BASE / GEMINI_BACKEND to the chosen connection mode.
  _apply_conn_mode()
end

-- Trim a pasted OpenAI-compatible base down to what the matcher wants: the
-- host (optionally plus /v1), with no endpoint path, no chat-UI "/ui" path
-- and no trailing slash.
local function normalize_gateway_base(u)
  return (u or ""):gsub("^%s+", ""):gsub("%s+$", "")
    :gsub("/+$", "")
    :gsub("/[Cc][Hh][Aa][Tt]/[Cc][Oo][Mm][Pp][Ll][Ee][Tt][Ii][Oo][Nn][Ss]$", "")
    :gsub("/[Uu][Ii]$", "")
    :gsub("/+$", "")
end

local function save_settings()
  local path = get_settings_path()
  local f = io.open(path, "w")
  if not f then return end

  -- Escape backslashes and quotes for JSON
  local function je(s)
    s = tostring(s or "")
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    return s
  end

  -- Escape newlines/tabs/quotes for JSON string value.
  local function jstr(s)
    s = tostring(s or "")
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"',  '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return s
  end

  -- The matcher appends "/v1/chat/completions" itself, so strip a pasted
  -- endpoint path, a chat-UI "/ui" path (it serves HTML and bounces API calls
  -- to a login page) and any trailing slash before this value is saved.
  -- Normalised into a local, NOT back into GEMINI_BASE_URL: autosave writes
  -- this file while that field may still hold the caret, and rewriting the
  -- variable under a live InputText would eat the character just typed.
  local gbase = normalize_gateway_base(GEMINI_BASE_URL)

  f:write('{\n')
  f:write(string.format('  "track_vo": "%s",\n',         je(TRACK_VO_NAME)))
  f:write(string.format('  "track_dub": "%s",\n',        je(TRACK_DUB_NAME)))
  f:write(string.format('  "track_unsync": "%s",\n',     je(TRACK_UNSYNC)))
  f:write(string.format('  "language": "%s",\n',         je(DUB_LANGUAGE)))
  f:write(string.format('  "match_mode": "%s",\n',       je(MATCH_MODE)))
  f:write(string.format('  "asr_provider": "%s",\n',     je(ASR_PROVIDER)))
  f:write(string.format('  "gemini_backend": "%s",\n',   je(GEMINI_BACKEND)))
  f:write(string.format('  "gemini_model": "%s",\n',     je(GEMINI_MODEL)))
  f:write(string.format('  "gemini_base_url": "%s",\n',  je(gbase)))
  f:write(string.format('  "elevenlabs_key": "%s",\n',   je(ELEVENLABS_KEY)))
  f:write(string.format('  "elevenlabs_model": "%s",\n',   je(ELEVENLABS_MODEL)))
  f:write(string.format('  "gemini_key": "%s",\n',       je(GEMINI_KEY)))
  f:write(string.format('  "vertex_key_path": "%s",\n',  je(VERTEX_KEY_PATH)))
  f:write(string.format('  "api_base": "%s",\n',         je(API_BASE)))
  f:write(string.format('  "api_token": "%s",\n',        je(API_TOKEN)))
  f:write(string.format('  "conn_mode": "%s",\n',        je(CONN_MODE)))
  f:write(string.format('  "server_url": "%s",\n',       je(SERVER_URL)))
  -- Persist the user-pinned interpreter override; without this line a
  -- hand-edited "python_cmd" would be erased on the next dialog OK.
  f:write(string.format('  "python_cmd": "%s",\n',       je(PYTHON_CMD)))
  f:write(string.format('  "script_text": "%s"\n',       jstr(SCRIPT_TEXT)))
  f:write('}\n')
  f:close()
end

-- Load saved settings on script start
load_settings()


-- ═══════════════════════════════════════════════════════════
-- AUTOSAVE — the settings file follows the fields, not the button
-- ═══════════════════════════════════════════════════════════
-- Settings used to reach disk only inside start_sync_run(), so a key pasted
-- into the Connection pane was gone again the moment the window closed
-- without a run. This watches the persisted values and writes the file once
-- typing has settled, plus one final flush when the window closes.
--
-- Debounced rather than per-keystroke: SCRIPT_TEXT lives in the same file and
-- is often 100 kB, which is not something to rewrite on every character.
local _autosave = {
  saved = nil,    -- signature of what is currently on disk
  seen  = nil,    -- signature seen last frame, while it is still changing
  at    = 0,      -- when `seen` stopped changing
  delay = 0.8,    -- seconds of quiet before the write
}

-- Every field save_settings() writes, joined by a byte that cannot occur in
-- any of them. Cheap to build and compare once a frame.
local function _settings_sig()
  local parts = {}
  local function p(v) parts[#parts + 1] = tostring(v or "") end
  p(TRACK_VO_NAME)  p(TRACK_DUB_NAME) p(TRACK_UNSYNC)   p(DUB_LANGUAGE)
  p(MATCH_MODE)     p(ASR_PROVIDER)   p(GEMINI_BACKEND) p(GEMINI_MODEL)
  p(GEMINI_BASE_URL) p(ELEVENLABS_KEY) p(GEMINI_KEY)    p(VERTEX_KEY_PATH)
  p(API_BASE)       p(API_TOKEN)      p(CONN_MODE)      p(SERVER_URL)
  p(PYTHON_CMD)     p(SCRIPT_TEXT)
  return table.concat(parts, "\1")
end

-- Write now if anything differs from disk. Used on window close, where there
-- is no next frame to wait for the debounce in.
local function settings_autosave_flush()
  if _settings_sig() == _autosave.saved then return false end
  save_settings()
  _autosave.saved, _autosave.seen, _autosave.at = _settings_sig(), nil, 0
  return true
end

-- Called once per frame. Returns true on the frames where it wrote.
local function settings_autosave_tick()
  local sig = _settings_sig()
  if sig == _autosave.saved then
    _autosave.seen, _autosave.at = nil, 0
    return false
  end
  if sig ~= _autosave.seen then      -- still changing — restart the clock
    _autosave.seen, _autosave.at = sig, reaper.time_precise()
    return false
  end
  if reaper.time_precise() - _autosave.at < _autosave.delay then return false end
  return settings_autosave_flush()
end

-- Baseline: what load_settings() just gave us is, by definition, what is on
-- disk. Without this the first frame would rewrite the file for nothing.
_autosave.saved = _settings_sig()


-- ═══════════════════════════════════════════════════════════
-- GUI (ReaImGui) — state + shared helpers
-- ═══════════════════════════════════════════════════════════
-- The front-end is a single ReaImGui window that walks through four phases:
--   setup → running → success → failure
-- ReaImGui is REQUIRED. If it is not installed, main() shows a one-time
-- install prompt (with the ReaPack steps) and exits without doing anything.

-- Enough of a key to recognise it in a screenshot, not enough to use it.
local function _mask_key(key)
  if not key or key == "" then return "" end
  if #key <= 10 then return string.rep("*", #key) end
  return key:sub(1, 4) .. "******" .. key:sub(-3)
end

-- ── UI state machine ──────────────────────────────────────
local _ui_ctx          = nil
local _ui_phase        = "setup"   -- setup | running | success | failure
local _ui_banner       = nil       -- { kind = "error"|"info"|"warn", text }
local _ui_setup_card   = nil       -- transient info card over the setup form
local _ui_window_open  = true
local _ui_step_label   = "Preparing…"
local _ui_step_idx     = 0         -- 0..3
local _ui_font         = nil       -- Unicode/Indic-capable font for log lines
local _ui_result       = nil       -- success summary text
local _ui_failure      = nil       -- { error_tail, log_path }
local _log_buffer      = {}        -- ring of last ~500 log lines for display
local _log_stamp       = {}        -- seconds into the run for each of those
local _log_autoscroll  = true
local _ui_log_level    = 'all'     -- 'all' | 'err' | 'warn'
local _ui_log_filter   = ''
-- Which font the UI found at startup. A note about this app, not a line the
-- worker printed — keeping it out of the log is what lets the Run pane say
-- "no run yet" before the first run.
local _ui_font_note    = nil
local _ui_show_keys    = false     -- toggle plaintext key display

-- Progress tracking (drives the progress bar + per-step detail)
local _ui_progress     = 0.0
local _ui_en_total     = 0
local _ui_dub_total    = 0
local _ui_en_done      = 0
local _ui_dub_done     = 0
local _poll_step_phase = 0         -- 1=EN transcribe, 2=DUB, 3=Gemini, 4=apply
local _ui_cancelled    = false
local _ui_results_rows = {}        -- per-clip rows for the success table

-- Poll state — shared by the running-phase renderer and the poller. Declared
-- here (before the UI renderers) so both capture the same upvalues.
local _poll_log_path     = nil
local _poll_done_path    = nil
local _poll_results_path = nil
local _poll_dub_items    = nil
local _poll_last_size    = 0
local _poll_start_time   = 0
-- When the log last grew. A long run and a hung run look identical without
-- this, so the running panel reports how long Python has been quiet.
local _poll_last_change  = 0

-- Version-safe BeginDisabled / EndDisabled (older ReaImGui lacks them).
local function _ui_begin_disabled(ctx, cond)
  if reaper.ImGui_BeginDisabled then reaper.ImGui_BeginDisabled(ctx, cond) end
end
local function _ui_end_disabled(ctx)
  if reaper.ImGui_EndDisabled then reaper.ImGui_EndDisabled(ctx) end
end

local function log_append(line)
  if not line or line == "" then return end
  local n = #_log_buffer + 1
  _log_buffer[n] = line
  -- Seconds into the run, stamped on arrival. Poll ticks land in batches, so
  -- this is when the line reached the UI, not when Python wrote it — close
  -- enough to answer "where did the three minutes go".
  _log_stamp[n]  = (_poll_start_time > 0) and (os.time() - _poll_start_time) or nil
  if n > 500 then
    table.remove(_log_buffer, 1)
    table.remove(_log_stamp, 1)
  end
end

local function log_clear()
  _log_buffer, _log_stamp = {}, {}
end

local function ui_set_banner(kind, text) _ui_banner = { kind = kind, text = text } end
local function ui_clear_banner() _ui_banner = nil end

-- Version-safe child-window border flag. ReaImGui renamed this across
-- releases (ChildFlags_Border → ChildFlags_Borders).
local function _child_border_flag()
  if reaper.ImGui_ChildFlags_Borders then return reaper.ImGui_ChildFlags_Borders() end
  if reaper.ImGui_ChildFlags_Border  then return reaper.ImGui_ChildFlags_Border()  end
  return 0
end

-- Dear ImGui throws away a borderless child's horizontal WindowPadding unless
-- it is asked to keep it — so every pane that pushed a padding and drew no
-- border was silently rendering flush to its own edge. That is what put the
-- rail's spine and the session card's right-hand captions hard against the
-- panel lines. Returns the child flag that keeps the padding, and (for the
-- builds that predate the flag) the equivalent window flag as a second value.
local function _child_pad_flag()
  if reaper.ImGui_ChildFlags_AlwaysUseWindowPadding then
    return reaper.ImGui_ChildFlags_AlwaysUseWindowPadding(), 0
  end
  if reaper.ImGui_WindowFlags_AlwaysUseWindowPadding then
    return 0, reaper.ImGui_WindowFlags_AlwaysUseWindowPadding()
  end
  return 0, 0
end

-- Robust ReaImGui detection. Some installs register the symbol before the
-- extension is fully loaded, so APIExists alone can be a false positive that
-- then crashes the unprotected ImGui_CreateContext in main(). Probe with a
-- real CreateContext whenever the function is callable, and trust that.
local function imgui_available()
  if reaper.ImGui_CreateContext ~= nil then
    local ok, ctx = pcall(reaper.ImGui_CreateContext, 'probe')
    if ok and ctx then
      if reaper.ImGui_DestroyContext then pcall(reaper.ImGui_DestroyContext, ctx) end
      return true
    end
    return false   -- symbol present but not actually usable yet
  end
  -- Not even a callable symbol; last-resort registry check.
  if reaper.APIExists and reaper.APIExists('ImGui_CreateContext') then
    return true
  end
  return false
end

-- Each language code → its Unicode script, to pick the right Noto font.
-- Assamese is written in the Bengali-Assamese script, so it shares Bengali's
-- font — the two extra letters it uses (ৰ, ৱ) live in the Bengali block.
local _LANG_TO_SCRIPT = {
  as = "Bengali",    bn = "Bengali",    gu = "Gujarati",
  hi = "Devanagari", kn = "Kannada",    ml = "Malayalam",
  mr = "Devanagari", ne = "Devanagari", ta = "Tamil",
  te = "Telugu",
}

-- Codes are what the engine speaks; full names are what the user reads. Every
-- place a language reaches the UI or the log goes through lang_name().
-- _LANG_ORDER is the order the combo shows: alphabetical by the name the user
-- reads, not by code, so scanning the list works the way a reader expects.
local _LANG_ORDER = { 'as','bn','gu','hi','kn','ml','mr','ne','ta','te' }
local _LANG_NAME  = {
  as = "Assamese",  bn = "Bengali",   gu = "Gujarati",
  hi = "Hindi",     kn = "Kannada",   ml = "Malayalam",
  mr = "Marathi",   ne = "Nepali",    ta = "Tamil",
  te = "Telugu",
}
-- Full names in the same order as _LANG_ORDER, for the combo.
local _LANG_NAMES = {}
for i, code in ipairs(_LANG_ORDER) do _LANG_NAMES[i] = _LANG_NAME[code] end

-- Full name for a code; unknown/empty codes come back as-is (or "?").
local function lang_name(code)
  if not code or code == "" then return "?" end
  return _LANG_NAME[code] or code
end

-- Attach a font that covers the configured DUB_LANGUAGE script so Indic log
-- lines render with proper glyphs. Falls back to the default font.
local function _attach_unicode_font(ctx)
  if not reaper.ImGui_CreateFont then return nil end
  local script = _LANG_TO_SCRIPT[DUB_LANGUAGE or ""] or "Devanagari"
  local paths = {}
  if reaper.GetOS():match("Win") then
    local local_fonts = (os.getenv("LOCALAPPDATA") or "")
                         :gsub("\\", "/") .. "/Microsoft/Windows/Fonts"
    paths[#paths+1] = local_fonts .. "/NotoSerif" .. script .. "-Regular.ttf"
    paths[#paths+1] = "C:/Windows/Fonts/NotoSerif" .. script .. "-Regular.ttf"
    paths[#paths+1] = local_fonts .. "/NotoSans"  .. script .. "-Regular.ttf"
    paths[#paths+1] = "C:/Windows/Fonts/NotoSans"  .. script .. "-Regular.ttf"
    paths[#paths+1] = "C:/Windows/Fonts/Nirmala.ttf"   -- all-Indic system font
    paths[#paths+1] = "C:/Windows/Fonts/NirmalaB.ttf"
    paths[#paths+1] = "C:/Windows/Fonts/segoeui.ttf"
  else
    paths = {
      '/Library/Fonts/NotoSerif'..script..'-Regular.ttf',
      '/Library/Fonts/NotoSans'..script..'-Regular.ttf',
      '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
      '/Library/Fonts/Arial Unicode.ttf',
    }
  end
  for _, p in ipairs(paths) do
    local fh = io.open(p, 'rb')
    if fh then
      fh:close()
      local ok, font = pcall(reaper.ImGui_CreateFont, p, 16)
      if ok and font then
        if pcall(reaper.ImGui_Attach, ctx, font) then
          -- Basename only: the note reassures, it is not a path to copy.
          _ui_font_note = 'Indic font: ' .. (p:match('[^/\\]+$') or p)
          return font
        end
      end
    end
  end
  _ui_font_note = 'No Indic font found — Devanagari may render as boxes.'
  return nil
end

-- Open a file/URL with the OS default handler.
local function open_path(path)
  if reaper.CF_ShellExecute then reaper.CF_ShellExecute(path)
  elseif reaper.GetOS():match('Win') then os.execute('start "" "' .. path .. '"')
  elseif reaper.GetOS():match('OSX') or reaper.GetOS():match('macOS') then
    os.execute('open "' .. path .. '"')
  else os.execute('xdg-open "' .. path .. '"') end
end
local function open_url(url) open_path(url) end

-- Try to install ReaImGui via ReaPack's Lua API (when ReaPack is present).
-- ReaPack has no public "silently install one package" call — the closest we
-- can do without pulling the entire ReaTeam repo is: add the repo, refresh its
-- index, then open Browse Packages pre-filtered to ReaImGui so the user only
-- has to click Install → Apply → restart. Returns true if that flow ran.
local REAIMGUI_REPO_URL = "https://github.com/ReaTeam/Extensions/raw/master/index.xml"
local function try_reapack_install()
  if not (reaper.APIExists and reaper.APIExists('ReaPack_AddSetRepository')) then
    return false
  end
  -- Add (or re-enable) the ReaTeam Extensions repo. Signature:
  --   ReaPack_AddSetRepository(name, url, enable, autoInstall)  -> bool, error
  -- autoInstall: 0=manual, 1=when synchronizing, 2=obey user setting.
  -- Per the ReaPack API docs: "usually set to 2". Anything else (e.g. -1)
  -- fails with "invalid value for autoInstall".
  local ok, err = reaper.ReaPack_AddSetRepository(
    'ReaTeam Extensions', REAIMGUI_REPO_URL, true, 2)
  if not ok then
    reaper.ShowMessageBox(
      "Could not add the ReaImGui repository automatically:\n" ..
      tostring(err) .. "\n\nFalling back to manual steps.",
      "ReaPack", 0)
    return false
  end
  -- Persist the repo change and refresh its index so the package shows up.
  if reaper.APIExists('ReaPack_ProcessQueue') then
    pcall(reaper.ReaPack_ProcessQueue, true)
  end
  -- Open the package browser filtered to ReaImGui for the final click.
  if reaper.APIExists('ReaPack_BrowsePackages') then
    pcall(reaper.ReaPack_BrowsePackages, 'ReaImGui')
  end
  reaper.ShowMessageBox(
    "The ReaImGui repository was added and the package browser opened.\n\n" ..
    "Finish the install:\n" ..
    "  1. Right-click 'ReaImGui: ReaScript binding for Dear ImGui'.\n" ..
    "  2. Choose Install, then click Apply.\n" ..
    "  3. Restart REAPER and run this script again.",
    "Almost done", 0)
  return true
end

-- Pick the ReaPack release asset matching this REAPER build. reaper.GetOS()
-- is the authoritative architecture signal — it returns exactly one of
-- "Win64"/"Win32"/"macOS-arm64"/"OSX64"/"OSX"(or "OSX32")/"linux-x86_64"/
-- "linux-aarch64"/"linux-armv7l"/"linux-i686". We branch on that, not on the
-- looser GetAppVersion() string. Returns nil for anything we can't map, so the
-- caller shows manual steps instead of downloading a binary that won't load.
local function _reapack_asset()
  local os_str = reaper.GetOS() or ""
  local v = (reaper.GetAppVersion() or ""):lower()
  if os_str == "Win64" then
    -- Native Windows-on-ARM REAPER carries arm64 in the version string; the
    -- overwhelming majority of Win64 users are x64 (and x64 also runs under
    -- Windows' x64-on-ARM emulation), so x64.dll is the safe default.
    if v:match("arm64") then return "reaper_reapack-arm64ec.dll" end
    return "reaper_reapack-x64.dll"
  elseif os_str == "Win32" then
    return "reaper_reapack-x86.dll"
  elseif os_str == "macOS-arm64" then
    return "reaper_reapack-arm64.dylib"
  elseif os_str == "OSX64" then
    return "reaper_reapack-x86_64.dylib"
  elseif os_str:match("^OSX") then      -- 32-bit macOS (OSX / OSX32)
    return "reaper_reapack-i386.dylib"
  elseif os_str == "linux-x86_64" then
    return "reaper_reapack-x86_64.so"
  elseif os_str == "linux-aarch64" then
    return "reaper_reapack-aarch64.so"
  elseif os_str == "linux-armv7l" then
    return "reaper_reapack-armv7l.so"
  elseif os_str == "linux-i686" then
    return "reaper_reapack-i686.so"
  end
  return nil                            -- unknown OS/arch → manual install
end

-- ReaPack itself is missing: download its extension binary straight into
-- REAPER's UserPlugins folder with curl (bundled on Windows 10+/macOS).
-- After a REAPER restart, ReaPack is live and try_reapack_install() can take
-- over. Returns true if the download succeeded.
local function try_reapack_bootstrap()
  local asset = _reapack_asset()
  if not asset or not reaper.ExecProcess then return false end
  local res = reaper.GetResourcePath()
  local sep = package.config:sub(1, 1)
  local dir = res .. sep .. "UserPlugins"
  reaper.RecursiveCreateDirectory(dir, 0)
  local dest = dir .. sep .. asset
  local url  = "https://github.com/cfillion/reapack/releases/latest/download/" .. asset
  -- Full path on macOS/Linux — ExecProcess may not search a login-shell PATH.
  local curl = reaper.GetOS():match("Win") and "curl.exe" or "/usr/bin/curl"
  local ret = reaper.ExecProcess(
    curl .. ' -fsSL --retry 2 -o "' .. dest .. '" "' .. url .. '"', 120000)
  local code = ret and ret:match("^(%-?%d+)")
  -- Sanity: exit 0 and a plausibly-sized binary (assets are ~2 MB).
  local f = io.open(dest, "rb")
  local size = 0
  if f then size = f:seek("end") or 0; f:close() end
  if code ~= "0" or size < 500000 then
    os.remove(dest)
    return false
  end
  return true
end

-- Combo helper: items as a table, returns (changed, new_value).
local function _ui_combo(ctx, label, current, items)
  local idx = 0
  for i, v in ipairs(items) do if v == current then idx = i - 1 break end end
  local rv, new_idx = reaper.ImGui_Combo(ctx, label, idx, table.concat(items, "\0") .. "\0")
  if rv then return true, items[new_idx + 1] end
  return false, current
end

-- Colored banner across the top of the window.
-- A message strip. The tone is carried by a tinted ground and a matching
-- hairline rim rather than by the words themselves: a whole paragraph in red
-- shouts, and most of what lands here is ordinary news. The cross closes it.
-- Drawn by hand rather than through SUI because SUI is declared further down
-- the file and is not in scope here. The tones follow the panel's palette:
-- red for errors, amber for warnings, teal for "done, here is what happened".
local _BANNER_TONE = {
  error = { rim = 0xF06A6A59, bg = 0x1F1517FF, dot = 0xF06A6AFF, fg = 0xF6DADAFF, sub = 0xC9A9ABFF },
  warn  = { rim = 0xF2C14E59, bg = 0x1F1B12FF, dot = 0xF2C14EFF, fg = 0xF4E6C4FF, sub = 0xC4B48FFF },
  info  = { rim = 0x38C9B059, bg = 0x112019FF, dot = 0x38C9B0FF, fg = 0xD3EFE9FF, sub = 0x9FC2BBFF },
}

-- An info banner reports something that already happened, so it clears
-- itself; errors and warnings stay until they are dismissed or fixed.
local _BANNER_INFO_SECS = 8

local function _ui_render_banner(ctx)
  if not _ui_banner then return end
  local now = reaper.time_precise and reaper.time_precise() or os.clock()
  _ui_banner.at = _ui_banner.at or now
  if _ui_banner.kind == 'info' and now - _ui_banner.at > _BANNER_INFO_SECS then
    _ui_banner = nil
    return
  end
  local t = _BANNER_TONE[_ui_banner.kind] or _BANNER_TONE.info

  -- The first sentence is the headline; whatever follows is the advice, set
  -- a step quieter on its own line. "No items on track X." / "Import … first."
  local text = _ui_banner.text or ''
  local head, rest = text:match('^(.-[%.!%?])%s+(.+)$')
  if not head then head, rest = text, nil end

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 12.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildBorderSize(), 1.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 12.0, 10.0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), t.bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),  t.rim)
  local bflags, bh = _child_border_flag(), rest and 60 or 42
  if reaper.ImGui_ChildFlags_AutoResizeY then
    bflags, bh = bflags | reaper.ImGui_ChildFlags_AutoResizeY(), 0
  end
  local nosb = (reaper.ImGui_WindowFlags_NoScrollbar
                and reaper.ImGui_WindowFlags_NoScrollbar()) or 0
  if reaper.ImGui_BeginChild(ctx, '##banner', -1, bh, bflags, nosb) then
    local dl = reaper.ImGui_GetWindowDrawList and reaper.ImGui_GetWindowDrawList(ctx)
    local okp, sx, sy = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
    local x0    = reaper.ImGui_GetCursorPosX(ctx)
    local y0    = reaper.ImGui_GetCursorPosY(ctx)
    local avail = reaper.ImGui_GetContentRegionAvail(ctx)
    local ICON, CLOSE = 20, 22

    -- Icon: a tinted disc with a mark drawn in strokes (no glyphs — the
    -- default face stops at Latin-1).
    if dl and okp and type(sx) == 'number' then
      local cx, cy = sx + ICON * 0.5, sy + ICON * 0.5
      pcall(reaper.ImGui_DrawList_AddCircleFilled, dl, cx, cy, ICON * 0.5,
            (t.dot & ~0xFF) | 0x2E)
      if _ui_banner.kind == 'info' then
        pcall(reaper.ImGui_DrawList_AddLine, dl, cx - 4, cy, cx - 1, cy + 3, t.dot, 1.8)
        pcall(reaper.ImGui_DrawList_AddLine, dl, cx - 1, cy + 3, cx + 4.5, cy - 3.5, t.dot, 1.8)
      else
        pcall(reaper.ImGui_DrawList_AddLine, dl, cx, cy - 5, cx, cy + 1.5, t.dot, 2.0)
        pcall(reaper.ImGui_DrawList_AddCircleFilled, dl, cx, cy + 4.6, 1.2, t.dot)
      end
    end
    reaper.ImGui_Dummy(ctx, ICON, ICON)
    reaper.ImGui_SameLine(ctx, 0, 10)

    -- Text column, wrapped short of the close button's column.
    reaper.ImGui_SetCursorPosY(ctx, y0 + 2)
    reaper.ImGui_BeginGroup(ctx)
    local wrapped = false
    if reaper.ImGui_PushTextWrapPos and type(x0) == 'number' and type(avail) == 'number' then
      reaper.ImGui_PushTextWrapPos(ctx, x0 + math.max(160, avail - CLOSE - 8))
      wrapped = true
    end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), t.fg)
    if wrapped then reaper.ImGui_Text(ctx, head) else reaper.ImGui_TextWrapped(ctx, head) end
    reaper.ImGui_PopStyleColor(ctx)
    if rest then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), t.sub)
      if wrapped then reaper.ImGui_Text(ctx, rest) else reaper.ImGui_TextWrapped(ctx, rest) end
      reaper.ImGui_PopStyleColor(ctx)
    end
    if wrapped then reaper.ImGui_PopTextWrapPos(ctx) end
    reaper.ImGui_EndGroup(ctx)

    -- Close: a thin cross in strokes, with a soft square behind it on hover.
    if type(x0) == 'number' and type(avail) == 'number' then
      reaper.ImGui_SetCursorPos(ctx, x0 + avail - CLOSE, y0 - 1)
      local okb, bx, by = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
      local hit = reaper.ImGui_InvisibleButton(ctx, '##bannerclose', CLOSE, CLOSE)
      local okh, hov = pcall(reaper.ImGui_IsItemHovered, ctx)
      hov = okh and hov
      if dl and okb and type(bx) == 'number' then
        if hov then
          pcall(reaper.ImGui_DrawList_AddRectFilled, dl, bx, by, bx + CLOSE, by + CLOSE,
                0xFFFFFF14, 6.0)
        end
        local c, cx, cy = hov and t.fg or t.sub, bx + CLOSE * 0.5, by + CLOSE * 0.5
        pcall(reaper.ImGui_DrawList_AddLine, dl, cx - 4, cy - 4, cx + 4, cy + 4, c, 1.2)
        pcall(reaper.ImGui_DrawList_AddLine, dl, cx + 4, cy - 4, cx - 4, cy + 4, c, 1.2)
      end
      if hit then _ui_banner = nil end
    end
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_PopStyleVar(ctx, 3)
  reaper.ImGui_Dummy(ctx, 0, 6)
end

local function _spinner_glyph()
  local frames = { '|','/','-','\\' }
  return frames[math.floor(os.clock() * 8) % #frames + 1]
end

-- Cancel a running sync by killing the worker PID that run_sync.py published.
-- Dir is resolved inline (get_script_dir is defined later in the file).
local function cancel_python()
  if _ui_cancelled then return end
  _ui_cancelled = true
  local info = debug.getinfo(1, 'S')
  local src  = info.source:match('@(.+)') or ''
  local dir  = src:match('(.+)[/\\]') or '.'
  local f = io.open(dir .. '/sync_python_pid.txt', 'r')
  if not f then return end
  local pid = (f:read('*a') or ''):match('(%d+)')
  f:close()
  if not pid then return end
  if reaper.GetOS():match('Win') then
    -- /T kills the whole tree (run_sync.py's child matcher included).
    os.execute(string.format('taskkill /F /T /PID %s > nul 2>&1', pid))
  else
    os.execute(string.format('kill -9 %s 2>/dev/null', pid))
  end
end


-- ═══════════════════════════════════════════════════════════
-- UTILITY FUNCTIONS
-- ═══════════════════════════════════════════════════════════

local function log(msg)
  -- (console output removed: the Logs pane is the console)
  log_append(msg)   -- mirror into the GUI Logs tab
end

local function find_track_by_name(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i)
    local _, tname = reaper.GetTrackName(t)
    if tname == name then return t end
  end
  return nil
end

local function find_or_create_track(name)
  local t = find_track_by_name(name)
  if t then return t end
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  t = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(t, "P_NAME", name, true)
  return t
end

-- Returns items sorted by timeline position.
-- Each entry: { item, pos, len, seq }
-- seq = 1-based sequential number in sorted order (used as ID in Python)
local function get_items_sorted(track)
  local items = {}
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    items[#items + 1] = { item = item, pos = pos, len = len }
  end
  table.sort(items, function(a, b) return a.pos < b.pos end)
  -- Assign sequential IDs AFTER sorting so they match Python output
  for i, v in ipairs(items) do v.seq = i end
  return items
end

local function get_script_dir()
  local info = debug.getinfo(1, "S")
  local src  = info.source:match("@(.+)") or ""
  return src:match("(.+)[/\\]") or "."
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a"); f:close(); return c
end

-- FIX: GetMediaSourceFileName requires TWO arguments in Reaper's Lua API.
-- The second argument is a string buffer — pass "" and use the return value.
local function get_source_path(item)
  local take = reaper.GetActiveTake(item)
  if not take then return "" end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return "" end
  local path = reaper.GetMediaSourceFileName(src, "")   -- ← BUG 1 fixed: added ""
  return path or ""
end

local function get_take_offset(item)
  local take = reaper.GetActiveTake(item)
  if not take then return 0 end
  return reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0
end


-- ═══════════════════════════════════════════════════════════
-- PROJECT STRUCTURE — what the Create button builds
-- ═══════════════════════════════════════════════════════════
-- Every dub session starts from the same tracks: the Video, the reference
-- VO, the Dub, and the tray unmatched takes are parked on — each one
-- carrying the FX chain the studio has settled on. Writing those chains out
-- in Lua would mean re-typing a dozen serialised plugin states and then
-- watching them drift from what the engineers actually use, so the shape is
-- kept somewhere it can be edited in REAPER itself: AutoSync/AutoSync.RPP.
-- The template IS the spec — open it, change it, save it, and Create follows.
--
-- Only the track chunks and the master chain are read out of it. Tempo,
-- render paths and window positions belong to whoever saved the template,
-- not to the session being started.

local TEMPLATE_REL = "/AutoSync/AutoSync.RPP"

local function template_path() return get_script_dir() .. TEMPLATE_REL end

-- RPP quotes a value only when it has to, picking whichever of " ' ` is not
-- already inside it.
local function _rpp_unquote(s)
  local q = s:sub(1, 1)
  if #s >= 2 and s:sub(-1) == q and (q == '"' or q == "'" or q == "`") then
    return s:sub(2, -2)
  end
  return s
end

-- Top-level blocks of one kind, in file order. An RPP is line-oriented: a
-- line that opens with '<' starts a block, a line that is nothing but '>'
-- closes it. The base64 payloads inside the FX blocks cannot be mistaken for
-- either — that alphabet has no angle brackets — so the nesting can be
-- counted without parsing a single token inside it.
local function _rpp_blocks(txt, tag)
  local out, depth, cur = {}, 0, nil
  for raw in (txt .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local line = raw:match("^%s*(.-)%s*$")
    if line ~= "" then
      if not cur and depth == 1 and line:match("^<([%w_]+)") == tag then
        cur = { indent = #(raw:match("^(%s*)")), lines = {} }
      end
      if cur then cur.lines[#cur.lines + 1] = raw end
      if line:sub(1, 1) == "<" then
        depth = depth + 1
      elseif line == ">" then
        depth = depth - 1
        if cur and depth == 1 then
          -- Strip the block's own indent from every line: that is the shape
          -- GetTrackStateChunk hands back, and the shape SetTrackStateChunk
          -- expects to be given.
          local pat, buf = "^" .. string.rep(" ", cur.indent), {}
          for i, l in ipairs(cur.lines) do buf[i] = (l:gsub(pat, "", 1)) end
          local chunk = table.concat(buf, "\n")
          out[#out + 1] = {
            chunk = chunk,
            name  = _rpp_unquote(chunk:match("\n%s*NAME%s+([^\r\n]+)") or ""),
          }
          cur = nil
        end
      end
    end
  end
  return out
end

-- AUXRECV names its source by track index, counted from the top of the
-- project. Dropping the block below tracks that are already there would
-- point every receive at the wrong one, so the indices move with it.
local function _rpp_shift_auxrecv(chunk, base)
  if base == 0 then return chunk end
  return (chunk:gsub("(\n%s*AUXRECV%s+)(%d+)", function(head, n)
    return head .. tostring(tonumber(n) + base)
  end))
end

local _tpl_at, _tpl_blocks = -1, nil

-- What Create would build, re-read at most once a second so an edit to the
-- template shows up in the panel without it reading the file every frame.
-- nil means there is no usable template to build from.
local function template_probe()
  local now = os.clock()
  if now - _tpl_at < 1.0 then return _tpl_blocks end
  _tpl_at = now
  local txt    = read_file(template_path())
  local blocks = txt and _rpp_blocks(txt, "TRACK") or {}
  _tpl_blocks  = (#blocks > 0) and blocks or nil
  return _tpl_blocks
end

-- Lay the template's tracks out at the end of the current project, FX and
-- all. Returns the names it created, or nil plus the reason it could not.
local function create_project_structure()
  local path = template_path()
  local txt  = read_file(path)
  if not txt then return nil, "No project template at " .. path end
  local blocks = _rpp_blocks(txt, "TRACK")
  if #blocks == 0 then return nil, "No tracks in " .. path end

  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()

  -- Two passes. A chunk can carry a receive from a track further down the
  -- list, and a receive from a track that does not exist yet is dropped in
  -- silence — so every track is in place before any chunk is applied.
  local base = reaper.CountTracks(0)
  for i = 1, #blocks do reaper.InsertTrackAtIndex(base + i - 1, false) end

  local made = {}
  for i, b in ipairs(blocks) do
    local tr = reaper.GetTrack(0, base + i - 1)
    if tr then
      -- The new track keeps its own GUID rather than the template's: two
      -- tracks sharing an identifier is how routing and automation get
      -- crossed, and the same template may be built twice in one session.
      local guid  = reaper.GetTrackGUID(tr)
      local chunk = _rpp_shift_auxrecv(b.chunk, base)
      chunk = chunk:gsub("^<TRACK%s+{[^}]*}", "<TRACK " .. guid, 1)
      chunk = chunk:gsub("(\n%s*TRACKID%s+){[^}]*}", "%1" .. guid, 1)
      reaper.SetTrackStateChunk(tr, chunk, false)
      local _, nm = reaper.GetTrackName(tr)
      made[#made + 1] = (nm ~= "" and nm) or b.name
    end
  end

  -- The master chain rides along, but only onto a master that is still bare:
  -- a limiter the engineer put there themselves outranks the template's.
  local mfx = _rpp_blocks(txt, "MASTERFXLIST")[1]
  if mfx then
    local m = reaper.GetMasterTrack(0)
    if m and reaper.TrackFX_GetCount(m) == 0 then
      local got, cur = reaper.GetTrackStateChunk(m, "", false)
      local body = got and cur and cur:match("^(.*)\n>%s*$")
      if body then
        -- One block, two spellings: the project file calls the master's
        -- chain MASTERFXLIST, a track chunk calls the same thing FXCHAIN.
        local chain = mfx.chunk:gsub("^<MASTERFXLIST", "<FXCHAIN")
        chain = chain:gsub("[^\n]+", "  %0")
        reaper.SetTrackStateChunk(m, body .. "\n" .. chain .. "\n>", false)
      end
    end
  end

  reaper.Undo_EndBlock("Samanvaya: create project structure", -1)
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  return made
end


-- ═══════════════════════════════════════════════════════════
-- AUTO-DETECT PYTHON + FIRST-TIME SETUP
-- ═══════════════════════════════════════════════════════════

local function _is_windows()
  return reaper.GetOS():match("Win") ~= nil
end

-- ═══════════════════════════════════════════════════════════
-- CREDENTIAL DETECTION + LIVE MODEL CHECK
-- ═══════════════════════════════════════════════════════════
-- Two halves, and only the first one is instant.
--
-- Detection is local: an issued key carries its provider in its prefix, so
-- the pane can name the provider the moment a key is pasted, offline.
--
-- Verification asks the provider what it has RIGHT NOW. No model list is
-- baked into this file on purpose — the catalogues move faster than the
-- script does, and a hard-coded list is wrong the week after it ships.
--
-- The call goes out through curl, fire-and-forget, writing its body and its
-- headers to files the frame loop polls. A blocking ExecProcess would freeze
-- REAPER for the length of every round trip.
--
-- The key never reaches the command line. It goes into a curl config file
-- (-K) that is deleted the moment the response lands, so it cannot be read
-- out of the process list the way a -H argument could.

local PROBE_TIMEOUT  = 20    -- seconds before curl is declared unreachable
local PROBE_DEBOUNCE = 1.2   -- seconds of quiet typing before a check fires

local _probe = {
  state    = 'idle',   -- idle | running
  job      = nil,
  queue    = {},
  started  = 0,
  next_at  = 0,
  size     = -1,
  stable   = 0,
  dirty_at = 0,        -- >0 while an edit is settling
  results  = {},       -- keyed 'matcher' | 'asr' | 'server'
}

-- Who issued this? The prefixes are the providers' own convention and they
-- are stable — which is why this can be decided without a network call.
local function detect_provider(key, base_url)
  key = key or ''
  if key == '' then
    if (base_url or '') ~= '' then
      return 'openai', 'OpenAI-compatible endpoint', 'from the URL — no key yet'
    end
    return nil, nil, nil
  end
  if key:match('^AIza')       then return 'studio',     'Google AI Studio',   'AIza… key'     end
  if key:match('^sk_')        then return 'elevenlabs', 'ElevenLabs',         'sk_… key'      end
  if key:match('^sk%-ant%-')  then return 'anthropic',  'Anthropic',          'sk-ant-… key'  end
  if key:match('^sk%-proj%-') then return 'openai',     'OpenAI',             'sk-proj-… key' end
  if key:match('^sk%-')       then return 'openai',     'OpenAI-compatible',  'sk-… key'      end
  if key:match('^hf_')        then return 'hf',         'Hugging Face',       'hf_… token'    end
  if key:match('^ya29%.')     then return 'vertex',     'Google OAuth token', 'ya29.… token'  end
  return 'unknown', 'Unrecognised', string.format('%d characters', #key)
end

-- The other half of "detect from what was pasted": a model NAME also says
-- which family it belongs to, which is how a gateway model gets a provider
-- even though the gateway itself is generic.
local function detect_model_family(name)
  name = (name or ''):lower()
  if name == '' then return nil end
  name = name:gsub('^models/', '')
  if name:match('^gemini')   then return 'Google Gemini'     end
  if name:match('^gpt')      then return 'OpenAI GPT'        end
  if name:match('^o%d')      then return 'OpenAI reasoning'  end
  if name:match('^claude')   then return 'Anthropic Claude'  end
  if name:match('^llama')    then return 'Meta Llama'        end
  if name:match('^mistral') or name:match('^mixtral') then return 'Mistral' end
  if name:match('^qwen')     then return 'Qwen'              end
  if name:match('^deepseek') then return 'DeepSeek'          end
  if name:match('^scribe')   then return 'ElevenLabs Scribe' end
  return nil
end

local function _probe_paths()
  local dir = os.getenv('TEMP') or os.getenv('TMP') or '/tmp'
  local pre = dir .. package.config:sub(1, 1) .. 'samanvaya_probe_'
  return pre .. 'body.json', pre .. 'head.txt', pre .. 'cfg.txt'
end

-- An OpenAI-compatible base may or may not already carry /v1; the client in
-- sync_matcher.py appends it too, so the same normalisation lives here.
local function _openai_base(u)
  u = (u or ''):gsub('%s+$', ''):gsub('/+$', '')
  if not u:match('/v1$') then u = u .. '/v1' end
  return u
end

-- A credential that could break out of the curl config file is not one we
-- are willing to send anywhere.
local function _key_is_sane(k)
  return k ~= '' and not k:find('[%c"]') and not k:find(string.char(92), 1, true)
end

local function _probe_finish(id, status, msg, models)
  _probe.results[id] = { status = status, msg = msg or '',
                         models = models or {}, at = os.time() }
  _probe.state, _probe.job = 'idle', nil
end

-- Model ids out of whichever shape the provider answers with. Pattern-based
-- rather than a JSON parse: these three responses are flat lists of ids and
-- Lua ships no JSON reader.
local function _parse_models(kind, body)
  local out, seen = {}, {}
  local function add(m)
    if m and m ~= '' and not seen[m] then seen[m] = true; out[#out + 1] = m end
  end
  if kind == 'google' then
    for m in body:gmatch('"name"%s*:%s*"models/([^"]+)"') do add(m) end
  elseif kind == 'elevenlabs' then
    for m in body:gmatch('"model_id"%s*:%s*"([^"]+)"') do add(m) end
  else
    for m in body:gmatch('"id"%s*:%s*"([^"]+)"') do add(m) end
  end
  table.sort(out)
  return out
end

-- The LAST status line wins. With -L the dump file holds one block per hop,
-- so a 301 followed by a 200 must read as 200, not 301.
local function _http_code(head)
  local last = 0
  for c in (head or ''):gmatch('HTTP/[%d%.]+%s+(%d%d%d)') do last = tonumber(c) end
  return last or 0
end

-- Has curl finished writing a header block, or is the file merely open?
-- curl creates the -D file the moment it starts, so "the file exists" says
-- nothing. A block is complete once a status line is followed by the blank
-- line that terminates it.
local function _head_complete(head)
  head = head or ''
  if not head:match('HTTP/[%d%.]+%s+%d%d%d') then return false end
  return head:find('\r\n\r\n', 1, true) ~= nil
      or head:find('\n\n', 1, true) ~= nil
end

-- Start one check. Old files go first: a leftover body from the last check
-- would otherwise read as an instant answer to this one.
local function _probe_start(job)
  local body, head, cfg = _probe_paths()
  os.remove(body); os.remove(head); os.remove(cfg)

  local lines = { 'silent', 'show-error' }
  for _, h in ipairs(job.headers or {}) do
    lines[#lines + 1] = 'header = "' .. h .. '"'
  end
  local fh = io.open(cfg, 'w')
  if not fh then
    _probe_finish(job.id, 'unverified', 'No writable temp folder for the request.')
    return
  end
  fh:write(table.concat(lines, '\n') .. '\n')
  fh:close()

  local curl = _is_windows() and 'curl.exe' or '/usr/bin/curl'
  local cmd  = string.format(
    '"%s" -sS -L --max-time 12 -K "%s" -o "%s" -D "%s" "%s"',
    curl, cfg, body, head, job.url)

  _probe.state, _probe.job = 'running', job
  _probe.started, _probe.next_at = reaper.time_precise(), 0
  _probe.size, _probe.stable = -1, 0
  _probe.results[job.id] = {
    status = 'checking', msg = 'Asking ' .. job.label .. '…',
    models = (_probe.results[job.id] or {}).models or {} }

  if _is_windows() then
    if reaper.ExecProcess then
      if reaper.ExecProcess(cmd, -2) == nil then
        _probe_finish(job.id, 'unverified', 'Could not launch curl.')
      end
    else
      os.execute('start "" /b ' .. cmd)
    end
  else
    os.execute(cmd .. ' >/dev/null 2>&1 &')
  end
end

-- What the response means, in the words the pane shows.
local function _probe_read(job, code, body)
  local models = (code == 200) and _parse_models(job.kind, body) or {}

  if code == 0 then
    return 'unverified', 'No reply — check the URL, or that curl is installed.', models
  elseif code == 401 or code == 403 then
    return 'invalid_key', 'The provider rejected this key.', models
  elseif code == 404 then
    return 'not_found', 'That endpoint does not exist — check the base URL.', models
  elseif code == 429 then
    return 'rate_limited', 'The key works, but it is rate-limited right now.', models
  elseif code >= 500 then
    return 'provider_down', string.format('%s answered %d.', job.label, code), models
  elseif code ~= 200 then
    return 'unverified', string.format('Unexpected reply (%d).', code), models
  end

  -- The server check has no model list; a 200 from /health is the whole answer.
  if job.kind == 'health' then
    return 'ok', 'Server is up and accepting this token.', models
  end
  if #models == 0 then
    return 'unverified', 'Answered, but listed no models.', models
  end

  local n    = #models
  local word = (n == 1) and 'model' or 'models'
  local want = (job.want or ''):gsub('^models/', '')
  if want == '' then
    return 'ok', string.format('%d %s available.', n, word), models
  end
  for _, m in ipairs(models) do
    if m == want then
      return 'ok', string.format('%s is live  ·  %d %s available.', want, n, word), models
    end
  end
  return 'model_missing',
    string.format('"%s" is not among the %d %s this key can reach.', want, n, word),
    models
end

-- What to ask, given the mode and the fields as they stand. Rebuilt on every
-- check so it always reflects what is actually in the boxes.
local function _probe_jobs()
  local jobs = {}
  if CONN_MODE == 'server' then
    if (SERVER_URL or '') ~= '' then
      local hdr = {}
      if _key_is_sane(API_TOKEN or '') then
        hdr[1] = 'Authorization: Bearer ' .. API_TOKEN
      end
      jobs[#jobs + 1] = { id = 'server', kind = 'health',
        label = 'Samanvaya server', headers = hdr,
        url = (SERVER_URL:gsub('/+$', '')) .. '/health' }
    end
    return jobs
  end

  if CONN_MODE == 'studio' and _key_is_sane(GEMINI_KEY or '') then
    jobs[#jobs + 1] = { id = 'matcher', kind = 'google',
      label = 'Google AI Studio', want = GEMINI_MODEL,
      headers = { 'x-goog-api-key: ' .. GEMINI_KEY },
      url = 'https://generativelanguage.googleapis.com/v1beta/models' }
  elseif CONN_MODE == 'gateway' and _key_is_sane(GEMINI_KEY or '')
         and (GEMINI_BASE_URL or '') ~= '' then
    jobs[#jobs + 1] = { id = 'matcher', kind = 'openai',
      label = 'the gateway', want = GEMINI_MODEL,
      headers = { 'Authorization: Bearer ' .. GEMINI_KEY },
      url = _openai_base(GEMINI_BASE_URL) .. '/models' }
  end

  -- ElevenLabs transcribes in every direct mode, so it is always worth asking.
  if _key_is_sane(ELEVENLABS_KEY or '') then
    -- No `want`: /v1/models lists the speech models, and the Scribe STT
    -- family is not always among them. Asserting a model that the endpoint
    -- never lists would report a false "not found" on a perfectly good key.
    jobs[#jobs + 1] = { id = 'asr', kind = 'elevenlabs',
      label = 'ElevenLabs', want = '',
      headers = { 'xi-api-key: ' .. ELEVENLABS_KEY },
      url = 'https://api.elevenlabs.io/v1/models' }
  end
  return jobs
end

-- Called every frame from refresh_state. Cheap while idle.
local function probe_tick()
  if _probe.dirty_at > 0 and _probe.state == 'idle'
     and reaper.time_precise() - _probe.dirty_at >= PROBE_DEBOUNCE then
    _probe.dirty_at = 0
    _probe.queue    = _probe_jobs()
  end

  if _probe.state == 'idle' then
    local job = table.remove(_probe.queue, 1)
    if job then _probe_start(job) end
    return
  end

  local now = reaper.time_precise()
  if now < _probe.next_at then return end
  _probe.next_at = now + 0.25

  local body, head, cfg = _probe_paths()
  local job = _probe.job
  -- Both files exist from the instant curl starts, so their presence proves
  -- nothing. Wait for a COMPLETE header block — DNS plus the TLS handshake to
  -- api.elevenlabs.io routinely outlasts two polls, and reading the empty
  -- dump file in that window used to parse as code 0 and report a good key
  -- as "No reply", every time.
  local hdr = read_file(head) or ''
  if _head_complete(hdr) then
    -- Headers are in; now let the body settle before parsing it.
    local txt = read_file(body) or ''
    if #txt == _probe.size then _probe.stable = _probe.stable + 1
    else _probe.size, _probe.stable = #txt, 0 end
    if _probe.stable >= 2 then
      local status, msg, models = _probe_read(job, _http_code(hdr), txt)
      os.remove(cfg); os.remove(body); os.remove(head)
      _probe_finish(job.id, status, msg, models)
      return
    end
  end

  if now - _probe.started > PROBE_TIMEOUT then
    -- Nothing at all on disk means curl never started; a partial dump means
    -- it started and the host did not finish answering. Different problems,
    -- so say which one it was.
    local launched = file_exists(head) or file_exists(body)
    os.remove(cfg); os.remove(body); os.remove(head)
    _probe_finish(job.id, 'unverified', launched
      and ('No reply in ' .. PROBE_TIMEOUT .. 's — the host may be unreachable.')
      or  'curl never started — check that curl.exe is on PATH.')
  end
end

-- An edit happened; check once the typing settles.
local function probe_mark_dirty()
  _probe.dirty_at = reaper.time_precise()
end

-- Check now, no debounce — the Re-check button.
local function probe_now()
  _probe.dirty_at = 0
  _probe.queue    = _probe_jobs()
end

-- Resolve a Python *command* to a real interpreter path by RUNNING it.
-- io.open() resolves relative names against REAPER's cwd, never the PATH,
-- so bare names like "python" can only be validated by execution. This also
-- rejects the Microsoft Store placeholder alias that stock Windows 10/11
-- puts on the PATH: it opens fine as a file, but running it with arguments
-- just prints "Python was not found" and exits non-zero.
local function probe_python(cmd)
  if not reaper.ExecProcess then return nil end
  local ret = reaper.ExecProcess(
    cmd .. ' -c "import sys;print(sys.executable)"', 15000)
  if not ret then return nil end
  -- ExecProcess returns "<exit code>\n<output>".
  local code, out = ret:match("^(%-?%d+)[\r\n]+(.*)$")
  if code ~= "0" or not out then return nil end
  local path = out:match("^%s*([^\r\n]+)")
  if path then path = path:gsub("%s+$", "") end
  if path and path ~= "" and file_exists(path) then return path end
  return nil
end

-- Set by find_python() when the local venv exists on disk but its
-- interpreter no longer runs (its base Python was removed or upgraded).
-- start_sync_run() then routes to ensure_setup() for a rebuild instead of
-- silently running on a system interpreter.
local _venv_broken = false

-- Returns the first working python path among the candidates, or nil.
local function find_python()
  local script_dir = get_script_dir()
  _venv_broken = false

  -- 1. User-pinned override (loaded from settings.json) takes priority.
  if PYTHON_CMD ~= "" then
    if file_exists(PYTHON_CMD) then return PYTHON_CMD end
    -- A bare command name ("python", "py", "py -3") can't be checked with
    -- io.open — resolve it against the PATH by executing it. A value with a
    -- space is a command plus args: pass it raw, not quoted as one token.
    if not PYTHON_CMD:find("[/\\]") then
      local probe_cmd = PYTHON_CMD:find("%s") and PYTHON_CMD
                        or ('"' .. PYTHON_CMD .. '"')
      local resolved = probe_python(probe_cmd)
      if resolved then return resolved end
    end
  end

  local sep = _is_windows() and "\\" or "/"
  local bin = _is_windows() and "Scripts\\python.exe" or "bin/python3"

  -- 2a. Bundled runtime — the Windows installer (Samanvaya_Setup.exe) ships
  -- an embeddable Python with every package preinstalled in ./python, so a
  -- fresh machine needs no Python of its own and no setup.bat run.
  if _is_windows() then
    local bundled = script_dir .. "\\python\\python.exe"
    if file_exists(bundled)
       and (not reaper.ExecProcess or probe_python('"' .. bundled .. '"')) then
      return bundled
    end
  end

  -- 2. Local venv next to this script — what setup.bat / setup.sh create.
  -- A venv whose base Python was uninstalled or upgraded still has its
  -- interpreter on disk but cannot run — probe by EXECUTING it, not just
  -- io.open (on old REAPER builds without ExecProcess, keep the old
  -- existence check).
  local local_venv = script_dir .. sep .. "venv" .. sep .. bin
  if file_exists(local_venv) then
    if not reaper.ExecProcess or probe_python('"' .. local_venv .. '"') then
      return local_venv
    end
    _venv_broken = true
  end

  -- 3. Common system installs (fallback when the venv is missing — the thin
  --    client needs only the standard library, so any Python 3 works).
  if _is_windows() then
    -- No fixed install path on Windows: resolve via the PATH by execution.
    -- "py -3" is the official launcher and exists even when python.exe is
    -- only the Store stub; sys.executable gives the real interpreter path.
    for _, c in ipairs({ 'py -3', 'python', 'python3' }) do
      local resolved = probe_python(c)
      if resolved then return resolved end
    end
  else
    local candidates = {
      "/opt/homebrew/bin/python3",         -- Apple Silicon Homebrew
      "/usr/local/bin/python3",            -- Intel Homebrew
      "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
      "/opt/homebrew/Cellar/python@3.13/3.13.12_1/bin/python3.13",
      "/usr/bin/python3",                  -- system
    }
    for _, c in ipairs(candidates) do
      if file_exists(c) then return c end
    end
  end

  return nil
end

-- Open a setup/update script in a visible terminal WITHOUT relying on macOS
-- AppleEvents. The old `osascript -e 'tell application "Terminal"...'` route
-- needs Automation permission (REAPER → Terminal); when that was never
-- granted — or was denied — the call fails SILENTLY and the button looks
-- dead. That was the #1 "Update/Setup does nothing" report on macOS.
--   macOS: write a .command wrapper to the temp dir and `open` it. `open`
--          needs no special permission, and a locally-written file carries
--          no Gatekeeper quarantine, so it just runs in Terminal.
--   Windows: `start "" "<script>"` runs the .bat in a NEW console that stays
--          up (our .bat scripts end with `pause`). Empty title so a path
--          with spaces (…/fast syncs/…) is treated as the program, not the
--          window title. This replaces the fragile nested-quote `cmd /k`.
-- Returns the shell command actually run (shown as a manual fallback).
local function _spawn_terminal_script(script_path, extra_args)
  extra_args = (extra_args and extra_args ~= "") and (" " .. extra_args) or ""
  if _is_windows() then
    local cmd = 'start "" "' .. script_path .. '"' .. extra_args
    os.execute(cmd)
    return cmd
  end
  local osname = reaper.GetOS() or ""
  local opener = (osname:match("OSX") or osname:match("[Mm]ac")) and "open"
                 or "xdg-open"
  local tmp = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
  local tag = (script_path:match("([^/\\]+)$") or "run"):gsub("[^%w%-_.]", "_")
  local wrapper = tmp .. "/fs_" .. tag .. ".command"
  local dir = script_path:match("^(.*)[/\\][^/\\]*$") or "."
  local f = io.open(wrapper, "wb")
  if f then
    f:write("#!/bin/bash\n")
    f:write('cd "' .. dir .. '"\n')
    f:write('bash "' .. script_path .. '"' .. extra_args .. "\n")
    f:write('status=$?\n')
    f:write('echo; echo "[Finished (exit $status) — press Return to close.]"; read _\n')
    f:close()
    os.execute('chmod +x "' .. wrapper .. '"')
    os.execute(opener .. ' "' .. wrapper .. '"')
    return opener .. ' "' .. wrapper .. '"'
  end
  -- Fallback: open the script directly (may open in an editor on some setups).
  os.execute(opener .. ' "' .. script_path .. '"')
  return opener .. ' "' .. script_path .. '"'
end

-- Run setup.sh if the local venv is missing (first-time install for a new user).
local function ensure_setup()
  local script_dir = get_script_dir()
  local venv_py    = script_dir .. (_is_windows() and "\\venv\\Scripts\\python.exe"
                                                  or "/venv/bin/python3")
  -- Healthy = exists AND runs. A venv whose base Python was removed or
  -- upgraded still has its interpreter on disk but cannot run; setup
  -- deletes and rebuilds it.
  local venv_exists = file_exists(venv_py)
  if venv_exists and (not reaper.ExecProcess
                      or probe_python('"' .. venv_py .. '"')) then
    return true
  end

  local choice = reaper.MB(
    (venv_exists
      and ("The Python virtualenv is broken — its Python was removed or " ..
           "upgraded.\n\nI'll rebuild it in:\n  ")
      or  ("First-time setup — Python virtualenv not found.\n\n" ..
           "I'll create one in:\n  ")) .. script_dir .. "/venv\n\n" ..
    "and install the required Python packages.\n\n" ..
    "Continue?",
    "Samanvaya — Setup", 1)
  if choice ~= 1 then return false end

  local setup = script_dir .. (_is_windows() and "\\setup.bat" or "/setup.sh")
  if not file_exists(setup) then
    reaper.MB("Setup script missing — run it manually:\n\n  " ..
              (_is_windows() and ("double-click setup.bat in:\n  " .. script_dir)
                              or ('cd "' .. script_dir .. '"\n  bash setup.sh')),
              "Setup script not found", 0)
    return false
  end
  -- Rebuild --direct installs the same way (setup writes the .direct-mode marker).
  local direct = file_exists(script_dir .. (_is_windows() and "\\.direct-mode"
                                                            or "/.direct-mode"))
  local cmd = _spawn_terminal_script(setup, direct and "--direct" or "")
  reaper.MB("Setup is opening in a new terminal window.\n\n" ..
            "When it says 'Setup complete', close it and run this script " ..
            "again.\n\nIf no window appeared, run this manually:\n  " .. cmd,
            "Setup running", 0)
  return false
end

-- ═══════════════════════════════════════════════════════════
-- BUILD CONFIG JSON  (written to disk, read by Python)
-- ═══════════════════════════════════════════════════════════

local function esc(s)
  -- Escape a string for JSON
  s = tostring(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"',  '\\"')
  s = s:gsub('\n', '\\n')
  s = s:gsub('\r', '\\r')
  s = s:gsub('\t', '\\t')
  return s
end

local function build_item_json(id, pos, dur, wav_path, take_offset)
  return string.format(
    '{"id":%d,"position":%.6f,"duration":%.6f,"wav_path":"%s","take_offset":%.6f}',
    id, pos, dur, esc(wav_path), take_offset
  )
end

local function write_config(en_items, dub_items, results_path)
  local script_dir  = get_script_dir()
  local config_path = script_dir .. "/sync_config.json"

  local lines = {}
  lines[#lines+1] = '{'
  lines[#lines+1] = string.format('  "output_path": "%s",', esc(results_path))

  -- Optional reference script. Passed inline as script_text so the user
  -- never has to type a file path.
  if SCRIPT_TEXT and SCRIPT_TEXT ~= "" then
    lines[#lines+1] = string.format('  "script_text": "%s",', esc(SCRIPT_TEXT))
  end

  -- EN items array
  lines[#lines+1] = '  "en_items": ['
  for i, v in ipairs(en_items) do
    local comma = (i < #en_items) and "," or ""
    lines[#lines+1] = "    " ..
      build_item_json(v.seq, v.pos, v.len,
                      get_source_path(v.item),
                      get_take_offset(v.item)) .. comma
  end
  lines[#lines+1] = '  ],'

  -- Dub items array
  lines[#lines+1] = '  "dub_items": ['
  for i, v in ipairs(dub_items) do
    local comma = (i < #dub_items) and "," or ""
    lines[#lines+1] = "    " ..
      build_item_json(v.seq, v.pos, v.len,
                      get_source_path(v.item),
                      get_take_offset(v.item)) .. comma
  end
  lines[#lines+1] = '  ]'
  lines[#lines+1] = '}'

  local f = io.open(config_path, "w")
  if not f then
    reaper.ShowMessageBox("Cannot write config to:\n" .. config_path, "Error", 0)
    return nil
  end
  f:write(table.concat(lines, "\n"))
  f:close()
  return config_path
end


-- ═══════════════════════════════════════════════════════════
-- RUN PYTHON MATCHER (non-blocking with live console output)
-- ═══════════════════════════════════════════════════════════

-- Windows: python.exe is a CONSOLE-subsystem program, so a detached launch
-- (ExecProcess with a negative timeout, or `start /b`) gives it a brand-new
-- console of its own — the blank black window that used to sit on screen for
-- the whole run. pythonw.exe is the very same interpreter linked as a GUI
-- subsystem binary: it never allocates one. run_sync.py never writes to
-- stdout (it opens sync_python_log.txt itself and hands that fd to the
-- worker), so losing the std streams costs nothing. Falls back to the given
-- command when there is no pythonw.exe beside it.
local function windowless_python(cmd)
  if not _is_windows() then return cmd end
  local base = cmd:match("([^/\\]+)$")
  if not base or base:lower() ~= "python.exe" then return cmd end
  local w = cmd:sub(1, #cmd - #base) .. "pythonw.exe"
  if file_exists(w) then return w end
  return cmd
end

local function build_python_cmd(config_path)
  local script_dir  = get_script_dir()
  local matcher     = script_dir .. "/sync_matcher.py"
  local log_path    = script_dir .. "/sync_python_log.txt"
  local pid_path    = script_dir .. "/sync_python_pid.txt"
  local done_path   = script_dir .. "/sync_python_done.txt"

  if not file_exists(matcher) then
    reaper.ShowMessageBox(
      "sync_matcher.py not found at:\n" .. matcher ..
      "\n\nMake sure it is in the SAME folder as this Lua script.",
      "File not found", 0)
    return nil
  end

  -- Cross-platform launch via run_sync.py.
  --
  -- run_sync.py reads the provider keys + Vertex path + server proxy settings
  -- from sync_pipeline_settings.json (already saved by the dialog), sets the
  -- SYNC_* environment for the worker, redirects output to the log file, and
  -- writes the exit code to the done file. Doing this in Python means the
  -- launch command has NO POSIX-only `VAR=val cmd` env prefix and NO bash-only
  -- `( ... ; echo $? > done ) &` wrapper — both of which failed on Windows.
  -- Secrets never appear on the command line either (so they can't leak via
  -- the process list).
  local launcher = script_dir .. "/run_sync.py"
  if not file_exists(launcher) then
    reaper.ShowMessageBox(
      "run_sync.py not found at:\n" .. launcher ..
      "\n\nMake sure it is in the SAME folder as this Lua script.",
      "File not found", 0)
    return nil
  end

  local cmd
  if _is_windows() then
    -- Plain quoted command line — launched via reaper.ExecProcess(cmd, -2),
    -- which uses CreateProcess directly (no cmd.exe). ExecProcess does not
    -- pass CREATE_NO_WINDOW on the no-wait paths, so the console-subsystem
    -- python.exe would still pop its own window; windowless_python() swaps in
    -- pythonw.exe, which cannot.
    cmd = string.format(
      '"%s" "%s" "%s" --language %s --mode %s --asr %s',
      windowless_python(PYTHON_CMD), launcher, script_dir,
      DUB_LANGUAGE, MATCH_MODE, ASR_PROVIDER
    )
  else
    -- Trailing & backgrounds the launcher; it manages the log + done files.
    cmd = string.format(
      '"%s" "%s" "%s" --language %s --mode %s --asr %s >/dev/null 2>&1 &',
      PYTHON_CMD, launcher, script_dir,
      DUB_LANGUAGE, MATCH_MODE, ASR_PROVIDER
    )
  end

  return cmd, log_path, done_path
end


-- ═══════════════════════════════════════════════════════════
-- PARSE RESULTS AND MOVE ITEMS
-- ═══════════════════════════════════════════════════════════

local function apply_results(results_path, dub_items)
  local content = read_file(results_path)
  if not content then
    reaper.ShowMessageBox(
      "Results file not found:\n" .. results_path ..
      "\n\nThe Python matcher may have failed or produced no output.",
      "Missing results", 0)
    return 0, 0
  end

  -- Parse results line by line
  -- Each result block in JSON looks like:
  --   { "dub_id": N, "status": "matched", "new_position": X.XXX, ... }
  local results_data = {}
  local cur = nil

  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    local dub_id = line:match('"dub_id"%s*:%s*(%d+)')
    if dub_id then
      cur = { dub_id = tonumber(dub_id) }
      results_data[#results_data + 1] = cur
    end
    if cur then
      local status  = line:match('"status"%s*:%s*"([^"]+)"')
      local new_pos = line:match('"new_position"%s*:%s*(%-?[%d%.]+)')
      if status  then cur.status      = status            end
      if new_pos then cur.new_position = tonumber(new_pos) end
    end
  end

  -- FIX BUG 2: Build lookup keyed on seq (1-based sorted position),
  -- which is exactly what Python uses as dub_id.
  local dub_lookup = {}
  for _, d in ipairs(dub_items) do
    dub_lookup[d.seq] = d        -- seq == the id Python was given
  end

  local unsync_track  = nil
  local moved         = 0
  local unmatched_cnt = 0

  for _, r in ipairs(results_data) do
    local d = dub_lookup[r.dub_id]
    if not d then
      log(string.format("  [WARN] No item found for dub_id=%d", r.dub_id))
      goto continue
    end

    -- One row per clip for the Results table — where it was, where it went.
    _ui_results_rows[#_ui_results_rows + 1] = {
      dub_id = r.dub_id, status = r.status, item = d.item,
      old_position = d.pos,
      new_position = (r.status ~= "missing_file") and r.new_position or d.pos,
    }

    if r.status == "matched" and r.new_position then
      reaper.SetMediaItemInfo_Value(d.item, "D_POSITION", r.new_position)
      moved = moved + 1
      log(string.format("  MOVED  dub[%d] → %.3fs", r.dub_id, r.new_position))

    elseif r.status == "unmatched" then
      if not unsync_track then
        unsync_track = find_or_create_track(TRACK_UNSYNC)
      end
      -- Use the Python-computed new_position (beside previous DUB in
      -- chronological order). Fall back to the clip's original position
      -- if new_position is absent (e.g. older results file).
      local place_pos
      if r.new_position then
        place_pos = r.new_position
      else
        place_pos = reaper.GetMediaItemInfo_Value(d.item, "D_POSITION")
      end
      reaper.MoveMediaItemToTrack(d.item, unsync_track)
      reaper.SetMediaItemInfo_Value(d.item, "D_POSITION", place_pos)
      unmatched_cnt = unmatched_cnt + 1
      log(string.format("  UNSYNC dub[%d] at %.3fs", r.dub_id, place_pos))

    elseif r.status == "missing_file" then
      if not unsync_track then
        unsync_track = find_or_create_track(TRACK_UNSYNC)
      end
      local orig = reaper.GetMediaItemInfo_Value(d.item, "D_POSITION")
      reaper.MoveMediaItemToTrack(d.item, unsync_track)
      reaper.SetMediaItemInfo_Value(d.item, "D_POSITION", orig)
      unmatched_cnt = unmatched_cnt + 1
      log(string.format("  MISSING dub[%d] (audio file not found, moved to unsync)", r.dub_id))
    end

    ::continue::
  end

  return moved, unmatched_cnt
end


-- ═══════════════════════════════════════════════════════════
-- READ SUMMARY FROM RESULTS JSON
-- ═══════════════════════════════════════════════════════════

local function read_summary(results_path)
  local c = read_file(results_path)
  if not c then return nil end
  return {
    total_en  = c:match('"total_en"%s*:%s*(%d+)')  or "?",
    total_dub = c:match('"total_dub"%s*:%s*(%d+)') or "?",
    matched   = c:match('"matched"%s*:%s*(%d+)')   or "?",
    unmatched = c:match('"unmatched"%s*:%s*(%d+)') or "?",
    model     = c:match('"model"%s*:%s*"([^"]+)"') or "?",
    language  = c:match('"language"%s*:%s*"([^"]+)"') or "?",
    backend   = c:match('"backend"%s*:%s*"([^"]+)"') or "?",
  }
end


-- ═══════════════════════════════════════════════════════════
-- SAMANVAYA DESIGN SYSTEM
-- ═══════════════════════════════════════════════════════════
-- One table, not two dozen locals: a Lua chunk gets 200 local slots and the
-- engine above already spends most of them. Everything cosmetic lives on SUI
-- so the UI can grow without starving the code that does the actual work.

local SUI = {}

-- Filled in by main() once, from the VERSION file.
local _APP_VERSION = ''

SUI.col = {
  -- The two lanes are the whole job, so they own the colour: teal is the VO
  -- (what is already right), amber is the dub (what gets moved). Amber is
  -- also the one action that moves it, Start sync. Everything else is ink.
  bg      = 0x0D0F14FF,   -- window
  rail    = 0x13161DFF,   -- workflow rail, log drawer
  card    = 0x13161DFF,   -- raised surface
  cardhi  = 0x1A1E27FF,   -- control on a card
  line    = 0x323846FF,   -- hairline
  rim     = 0x262B36FF,   -- quieter hairline, lane wells
  hair    = 0xFFFFFF0E,   -- card rim: white at 5%, so it reads on any ground
  well    = 0x0A0C10FF,   -- sunken: editor, log lines, timeline
  text    = 0xE9ECF2FF,
  dim     = 0xA3AABAFF,   -- secondary copy
  faint   = 0x8A93A6FF,   -- tertiary copy (clears 4.5:1 on the rail)
  gutter  = 0x6E778AFF,   -- log time column, placeholder text, idle dot
  accent  = 0xF0A24BFF,   -- amber: the dub lane and the primary action
  accent2 = 0x38C9B0FF,   -- teal: the VO lane
  vo      = 0x38C9B0FF,
  dub     = 0xF0A24BFF,
  ink_on  = 0x1D1206FF,   -- type on an amber fill
  ok      = 0x4BD08BFF,
  warn    = 0xF2C14EFF,
  err     = 0xF06A6AFF,
  white   = 0xFFFFFFFF,
}

-- Colour + style-var tables are applied by name so a ReaImGui that predates
-- any single entry simply skips it instead of erroring out.
SUI.theme = {
  { 'WindowBg',             0x0D0F14FF },
  { 'ChildBg',              0x00000000 },
  { 'PopupBg',              0x13161DFF },
  { 'Border',               0x262B36FF },
  { 'FrameBg',              0x0A0C10FF },
  { 'FrameBgHovered',       0x12151BFF },
  { 'FrameBgActive',        0x161A22FF },
  { 'TitleBg',              0x13161DFF },
  { 'TitleBgActive',        0x13161DFF },
  { 'Text',                 0xE9ECF2FF },
  { 'TextDisabled',         0x5C6577FF },
  { 'Button',               0x1A1E27FF },
  { 'ButtonHovered',        0x262B36FF },
  { 'ButtonActive',         0x323846FF },
  { 'Header',               0x1A1E27FF },
  { 'HeaderHovered',        0x262B36FF },
  { 'HeaderActive',         0x323846FF },
  { 'Separator',            0x262B36FF },
  { 'ScrollbarBg',          0x00000000 },
  { 'ScrollbarGrab',        0x2E3542FF },
  { 'ScrollbarGrabHovered', 0x3A4354FF },
  { 'ScrollbarGrabActive',  0x46516AFF },
  { 'PlotHistogram',        0xF0A24BFF },
  { 'CheckMark',            0xF0A24BFF },
  { 'TableHeaderBg',        0x1A1E27FF },
  { 'TableBorderLight',     0x262B36FF },
  { 'TableBorderStrong',    0x323947FF },
  { 'TableRowBg',           0x00000000 },
  { 'TableRowBgAlt',        0xFFFFFF08 },
}

SUI.vars = {
  { 'WindowRounding',    10.0 },
  { 'ChildRounding',     10.0 },
  { 'FrameRounding',      8.0 },
  { 'PopupRounding',      8.0 },
  { 'GrabRounding',       6.0 },
  { 'ScrollbarRounding',  8.0 },
  { 'ScrollbarSize',      9.0 },
  { 'FrameBorderSize',    1.0 },
  { 'ChildBorderSize',    0.0 },
  { 'WindowBorderSize',   1.0 },
  { 'WindowPadding',     12.0, 10.0 },
  { 'FramePadding',       8.0,  4.0 },
  { 'ItemSpacing',        8.0,  5.0 },
  { 'ItemInnerSpacing',   7.0,  4.0 },
}

-- The button family's corner. 8, not a full pill: a solid rectangle with a
-- soft corner is the shape the panel was signed off on, and it is the shape
-- that survives a 26px Paste button and a 38px Start sync equally well — a
-- pill at 26px is all corner and no edge.
SUI.BTN_R = 8.0

SUI._ncol, SUI._nvar = 0, 0

-- Pushed BEFORE Begin() (the window background is a style colour too) and
-- popped after End().
function SUI.push_theme(ctx)
  local n = 0
  for _, e in ipairs(SUI.theme) do
    local getter = reaper['ImGui_Col_' .. e[1]]
    if getter then
      reaper.ImGui_PushStyleColor(ctx, getter(), e[2])
      n = n + 1
    end
  end
  SUI._ncol = n

  local v = 0
  for _, e in ipairs(SUI.vars) do
    local getter = reaper['ImGui_StyleVar_' .. e[1]]
    if getter then
      if e[3] then reaper.ImGui_PushStyleVar(ctx, getter(), e[2], e[3])
      else         reaper.ImGui_PushStyleVar(ctx, getter(), e[2]) end
      v = v + 1
    end
  end
  SUI._nvar = v
end

function SUI.pop_theme(ctx)
  if SUI._nvar > 0 then reaper.ImGui_PopStyleVar(ctx, SUI._nvar) end
  if SUI._ncol > 0 then reaper.ImGui_PopStyleColor(ctx, SUI._ncol) end
  SUI._ncol, SUI._nvar = 0, 0
end

-- ── primitives ────────────────────────────────────────────

function SUI.gap(ctx, h) reaper.ImGui_Dummy(ctx, 0, h or 6) end

function SUI.text(ctx, col, s)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col)
  reaper.ImGui_Text(ctx, s)
  reaper.ImGui_PopStyleColor(ctx)
end

-- Text that shares a row with a framed widget — an input, a combo, a
-- checkbox, a tall button. Plain Text() sits at the TOP of the row, so the
-- caption beside a 26px frame rides several pixels high; this drops it onto
-- the frame's own text line. Same trick SUI.field uses for its gutter label.
function SUI.ftext(ctx, col, s)
  if reaper.ImGui_AlignTextToFramePadding then
    pcall(reaper.ImGui_AlignTextToFramePadding, ctx)
  end
  SUI.text(ctx, col, s)
end

-- A progress bar is shorter than a line of text, so a bar with a read-out
-- SameLine'd after it centres several pixels above that text. Nudge the bar
-- down by half the difference and the two read as one row.
function SUI.bar(ctx, frac, w, h)
  local lh = 15
  if reaper.ImGui_GetTextLineHeight then
    local ok, v = pcall(reaper.ImGui_GetTextLineHeight, ctx)
    if ok and type(v) == 'number' then lh = v end
  end
  if h < lh and reaper.ImGui_GetCursorPosY then
    local ok, y = pcall(reaper.ImGui_GetCursorPosY, ctx)
    if ok and type(y) == 'number' then
      reaper.ImGui_SetCursorPosY(ctx, y + math.floor((lh - h) * 0.5))
    end
  end
  reaper.ImGui_ProgressBar(ctx, frac, w, h, '')
end

-- Breathing room between the last glyph of a wrapped line and the pane edge.
SUI.EDGE = 10

-- TextWrapped on its own wraps at the host window's work rect. In a child laid
-- out with SameLine that rect can sit past the visible right edge, and the
-- paragraph runs off the panel. Pin the wrap to THIS pane's content width
-- instead, less a margin, so no line ever touches the edge.
--   maxw: optional cap, for copy that should not stretch into a long measure.
function SUI.wrap(ctx, col, s, maxw)
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  local wrapw = math.max(140, (avail or 400) - SUI.EDGE)
  if maxw and maxw < wrapw then wrapw = maxw end

  local pushed = false
  if reaper.ImGui_PushTextWrapPos and reaper.ImGui_GetCursorPosX then
    local ok, cx = pcall(reaper.ImGui_GetCursorPosX, ctx)
    if ok and type(cx) == 'number' then
      reaper.ImGui_PushTextWrapPos(ctx, cx + wrapw)
      pushed = true
    end
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col)
  -- With a wrap position pushed, Text() wraps at it; without one we still want
  -- wrapping, so fall back to TextWrapped.
  if pushed then reaper.ImGui_Text(ctx, s) else reaper.ImGui_TextWrapped(ctx, s) end
  reaper.ImGui_PopStyleColor(ctx)
  if pushed then reaper.ImGui_PopTextWrapPos(ctx) end
end

function SUI.big(ctx, col, s, size)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col)
  if _ui_font then pcall(reaper.ImGui_PushFont, ctx, _ui_font, size or 22) end
  reaper.ImGui_Text(ctx, s)
  if _ui_font then pcall(reaper.ImGui_PopFont, ctx) end
  reaper.ImGui_PopStyleColor(ctx)
end

-- The brand rule: a short gradient accent, drawn with the draw list, with a
-- separator as the fallback. Unused since the Studio pane header took over
-- the job of opening a pane — kept because it is the only rounded-free
-- gradient primitive here and the next band-shaped thing will want it.
function SUI.brandbar(ctx, w)
  if reaper.ImGui_GetWindowDrawList and reaper.ImGui_DrawList_AddRectFilledMultiColor then
    local dl     = reaper.ImGui_GetWindowDrawList(ctx)
    local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
    local avail  = reaper.ImGui_GetContentRegionAvail(ctx)
    local ww     = math.min(w or avail, avail)
    local ok = pcall(reaper.ImGui_DrawList_AddRectFilledMultiColor, dl,
      cx, cy, cx + ww, cy + 3,
      SUI.col.accent, SUI.col.accent2, SUI.col.accent2, SUI.col.accent)
    if ok then reaper.ImGui_Dummy(ctx, 0, 3); return end
  end
  reaper.ImGui_Separator(ctx)
end

-- Section eyebrow: a small, wide-set label above a group of fields.
function SUI.eyebrow(ctx, s)
  SUI.text(ctx, SUI.col.faint, (s:upper():gsub('(.)', '%1 '):gsub(' $', '')))
end

-- ── No scrollbars ─────────────────────────────────────────
-- Every scrolling region here is driven by the wheel. ImGui would otherwise
-- park a permanent grey rail down the right edge of each one and take 9px of
-- content width to do it, which is a lot of furniture for something nobody
-- drags. NoScrollbar hides the rail AND gives the width back; the wheel keeps
-- working, since that is NoScrollWithMouse's job, not this flag's.
SUI.NOSB = (reaper.ImGui_WindowFlags_NoScrollbar
            and reaper.ImGui_WindowFlags_NoScrollbar()) or 0

-- A child region with its own background and inner padding. ImGui reads
-- WindowPadding at BeginChild time, so the padding has to be pushed here —
-- and a borderless child DROPS that padding unless it is flagged to keep it,
-- which is what _child_pad_flag() supplies.
-- The shell lays the three regions out with zero item spacing so they sit
-- flush; each pane restores normal spacing for its own contents.
function SUI.pane(ctx, id, w, h, bg, padx, pady, rounding)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),
    padx or 14.0, pady or 12.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), rounding or 0.0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), bg or 0x00000000)
  local cf, wf = _child_pad_flag()
  local open = reaper.ImGui_BeginChild(ctx, id, w, h, cf, SUI.NOSB | wf)
  if open then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 8.0, 5.0)
  end
  return open
end

function SUI.pane_end(ctx, open)
  if open then
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleVar(ctx, 2)
end

-- A rounded surface inside a pane. Auto-heights where ReaImGui supports it;
-- `h` is the fallback for older builds.
function SUI.card_begin(ctx, id, h)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 14.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildBorderSize(), 1.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 15.0, 12.0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), SUI.col.card)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),  SUI.col.hair)
  local flags, hh = _child_border_flag(), (h or 120)
  if reaper.ImGui_ChildFlags_AutoResizeY then
    flags = flags | reaper.ImGui_ChildFlags_AutoResizeY()
    hh = 0
  end
  return reaper.ImGui_BeginChild(ctx, id, -1, hh, flags, SUI.NOSB)
end

function SUI.card_end(ctx, open)
  if open then reaper.ImGui_EndChild(ctx) end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_PopStyleVar(ctx, 3)
end

-- Status pill. Buttons give us rounding + padding for free; callers that
-- don't want a click simply ignore the result.
function SUI.pill(ctx, label, bg, fg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          fg)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 20.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 11.0, 4.0)
  local hit = reaper.ImGui_Button(ctx, label)
  reaper.ImGui_PopStyleVar(ctx, 2)
  reaper.ImGui_PopStyleColor(ctx, 4)
  return hit
end

function SUI.dotcol(state)
  if state == 'ok'   then return SUI.col.ok   end
  if state == 'warn' then return SUI.col.warn end
  if state == 'err'  then return SUI.col.err  end
  return SUI.col.gutter
end

-- One-of-N selector. Returns the (possibly new) 1-based index.
-- The chosen segment is lifted (the 'raised' tone) rather than amber, so the
-- mode you are in never competes with Start sync for the eye. The rest are
-- hairline outlines, which keeps the row quiet until you look at it.
function SUI.segmented(ctx, id, labels, cur)
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  local n, gap = #labels, 6
  local w = math.floor((avail - gap * (n - 1)) / n)
  local out = cur
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), SUI.BTN_R)
  for i = 1, n do
    local on = (i == cur)
    if on then
      if SUI.cta(ctx, labels[i] .. '##' .. id .. i, w, 30, 'raised') then out = i end
    else
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x00000000)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xFFFFFF0F)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0xFFFFFF17)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          SUI.col.dim)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        SUI.col.line)
      if reaper.ImGui_Button(ctx, labels[i] .. '##' .. id .. i, w, 30) then out = i end
      reaper.ImGui_PopStyleColor(ctx, 5)
    end
    if i < n then reaper.ImGui_SameLine(ctx, 0, gap) end
  end
  reaper.ImGui_PopStyleVar(ctx)
  return out
end

-- Draw the first of `candidates` that fits `maxw` at `size`, measured in the
-- panel's own face. Wide-set small caps stop fitting long before ordinary
-- text does, so the rail's eyebrow degrades on purpose — it sheds the version
-- suffix, then the letter-spacing — instead of running off the rail's edge.
function SUI.fitline(ctx, col, candidates, size, maxw)
  local pushed = false
  if _ui_font and size then
    pushed = pcall(reaper.ImGui_PushFont, ctx, _ui_font, size)
  end
  local pick = candidates[#candidates]
  for _, cand in ipairs(candidates) do
    local ok, w = pcall(reaper.ImGui_CalcTextSize, ctx, cand)
    -- No CalcTextSize on this build: take the shortest candidate rather than
    -- gambling on the widest one.
    if not (ok and type(w) == 'number') then break end
    if w <= maxw then pick = cand break end
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), col)
  reaper.ImGui_Text(ctx, pick)
  reaper.ImGui_PopStyleColor(ctx)
  if pushed then pcall(reaper.ImGui_PopFont, ctx) end
end

-- The negative item width that leaves room for a right-hand caption column.
-- A hard-coded number was fine until the widest caption ("made if absent")
-- grew past it, and then the caption ran under the card's rim. Measure the
-- longest one instead and hand back a width that always clears it.
--   gap:    space between the control and the caption
--   margin: space between the longest caption and the card's inner edge
function SUI.capw(ctx, captions, gap, margin)
  gap, margin = gap or 10, margin or 8
  local widest = 0
  for _, s in ipairs(captions) do
    local ok, w = pcall(reaper.ImGui_CalcTextSize, ctx, s)
    if ok and type(w) == 'number' and w > widest then widest = w end
  end
  if widest == 0 then widest = 108 end          -- no CalcTextSize: old default
  return -(math.ceil(widest) + gap + margin)
end

-- Label in a fixed left gutter, control filling the rest of the row.
function SUI.field(ctx, label, gutter, itemw)
  if reaper.ImGui_AlignTextToFramePadding then
    reaper.ImGui_AlignTextToFramePadding(ctx)
  end
  SUI.text(ctx, SUI.col.dim, label)
  reaper.ImGui_SameLine(ctx, gutter or 108)
  reaper.ImGui_SetNextItemWidth(ctx, itemw or -1)
end

-- ── gradient pills ────────────────────────────────────────
-- The Samanvaya blue-to-violet ramp is the panel's one piece of colour, so
-- the primary control wears it. ImGui has no rounded gradient: the only
-- gradient primitive, AddRectFilledMultiColor, takes no rounding. So a pill
-- is drawn as three pieces — a left cap, a right cap, and the straight middle
-- that carries the ramp — with each cap taking the ramp's colour at its own
-- centre. The seams land on matching values, so the joins are invisible.

local function _col_lerp(a, b, t)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local function ch(shift)
    local ca = (a >> shift) & 0xFF
    local cb = (b >> shift) & 0xFF
    return math.floor(ca + (cb - ca) * t + 0.5) & 0xFF
  end
  return (ch(24) << 24) | (ch(16) << 16) | (ch(8) << 8) | ch(0)
end

-- Same colour with its alpha scaled — for the glow and the rim light.
local function _col_fade(c, mul)
  local a = math.floor((c & 0xFF) * mul + 0.5)
  if a < 0 then a = 0 elseif a > 0xFF then a = 0xFF end
  return (c & ~0xFF) | a
end

local _RC_L, _RC_R = nil, nil   -- resolved once, on first use

-- Fills x0..x1 with the c1 -> c2 ramp, rounded by `r` at both ends.
function SUI.grad_pill(dl, x0, y0, x1, y1, c1, c2, r)
  local w = x1 - x0
  if w <= 0 then return end
  r = math.min(r, (y1 - y0) * 0.5, w * 0.5)
  -- A flat fill is one rectangle. Going through the three-piece path with the
  -- same colour in every piece would work, but the two joins are antialiased
  -- edges laid against each other, which can leave a hairline down a large
  -- solid button.
  if c1 == c2 then
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, c1, r)
    return
  end
  if _RC_L == nil then
    _RC_L = (reaper.ImGui_DrawFlags_RoundCornersLeft
             and reaper.ImGui_DrawFlags_RoundCornersLeft()) or 0
    _RC_R = (reaper.ImGui_DrawFlags_RoundCornersRight
             and reaper.ImGui_DrawFlags_RoundCornersRight()) or 0
  end
  -- Caps first, then the ramp between them.
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + r, y1,
    _col_lerp(c1, c2, (r * 0.5) / w), r, _RC_L)
  reaper.ImGui_DrawList_AddRectFilled(dl, x1 - r, y0, x1, y1,
    _col_lerp(c1, c2, (w - r * 0.5) / w), r, _RC_R)
  if w > r * 2 then
    local a = _col_lerp(c1, c2, r / w)
    local b = _col_lerp(c1, c2, (w - r) / w)
    pcall(reaper.ImGui_DrawList_AddRectFilledMultiColor, dl,
      x0 + r, y0, x1 - r, y1, a, b, b, a)
  end
end

-- Everything the panel's buttons have in common: an invisible hit area, then
-- the pill painted over it and the label centred on top. Drawing AFTER the
-- button is what lets the fill depend on hover and press without a frame of
-- lag — InvisibleButton paints nothing, so nothing is covered up.
--
-- `spec` carries the three states: {c1, c2} pairs for a ramp, or a single
-- colour in c1 for a flat fill. `fg` is the label. `rad` is the corner radius,
-- defaulting to a full pill; `shade` is the colour of the soft spill under the
-- button — near-black for a drop shadow, the fill's own hue for a glow.
local function _pill_button(ctx, id, w, h, spec, fg, rim, shade, dim, rad)
  -- The caption is everything before ImGui's "##" id separator.
  local cap = id:match('^(.-)##') or id
  if w <= 0 then
    local okc, tw = pcall(reaper.ImGui_CalcTextSize, ctx, cap)
    w = (okc and type(tw) == 'number') and (tw + 32) or 120
  end
  local ok_pos, x0, y0 = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
  local hit = reaper.ImGui_InvisibleButton(ctx, id, w, h)
  if not ok_pos or not reaper.ImGui_GetWindowDrawList then return hit end

  local hovered, held = false, false
  if not dim then
    local okh, v = pcall(reaper.ImGui_IsItemHovered, ctx)
    hovered = okh and v or false
    local oka, a = pcall(reaper.ImGui_IsItemActive, ctx)
    held = oka and a or false
  end
  local st = held and 3 or (hovered and 2 or 1)
  local c1, c2 = spec[st][1], spec[st][2] or spec[st][1]
  if dim then
    c1, c2 = _col_lerp(c1, SUI.col.rail, 0.55), _col_lerp(c2, SUI.col.rail, 0.55)
  end

  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local x1, y1 = x0 + w, y0 + h
  local r = rad or (h * 0.5)

  -- The spill: three rounded rings under the button, fading outwards and
  -- offset down. Cheaper than a blur and, at these radii, indistinguishable
  -- from one. A dark `shade` reads as a drop shadow, a bright one as a glow.
  if shade and not dim then
    local lift = held and 0.6 or (hovered and 1.35 or 1.0)
    for i = 3, 1, -1 do
      local sp = i * 1.6
      pcall(reaper.ImGui_DrawList_AddRectFilled, dl,
        x0 - sp, y0 - sp * 0.4 + 2, x1 + sp, y1 + sp * 0.9 + 2,
        _col_fade(shade, 0.055 * lift * (4 - i)), r + sp)
    end
  end

  SUI.grad_pill(dl, x0, y0, x1, y1, c1, c2, r)

  -- A solid fill takes a highlight along its top edge only — the button reads
  -- as lit from above, which a rim running all the way round would undo by
  -- lighting the underside too. An outlined button wants the whole rim, since
  -- there the rim IS the button.
  if rim then
    if spec.outline then
      pcall(reaper.ImGui_DrawList_AddRect, dl, x0, y0, x1, y1,
        _col_fade(rim, dim and 0.4 or 1.0), r, 0, 1.0)
    else
      pcall(reaper.ImGui_DrawList_AddLine, dl,
        x0 + r, y0 + 0.5, x1 - r, y0 + 0.5,
        _col_fade(rim, dim and 0.4 or 1.0), 1.0)
    end
  end

  local tw, th = 0, h * 0.5
  local okt, a, b = pcall(reaper.ImGui_CalcTextSize, ctx, cap)
  if okt and type(a) == 'number' then tw, th = a, b or th end
  pcall(reaper.ImGui_DrawList_AddText, dl,
    x0 + math.floor((w - tw) * 0.5), y0 + math.floor((h - th) * 0.5),
    dim and _col_lerp(fg, SUI.col.rail, 0.5) or fg, cap)
  return hit
end

-- Call-to-action. `tone` picks the palette; returns true on click.
-- `dim` renders the disabled look — ImGui has no way to ask whether we are
-- inside a BeginDisabled block, so the caller that opened one says so.
--
-- The fills are flat. The blue-to-violet ramp still exists (SUI.grad_pill,
-- and the rail's selected node) but it is not what a button wears: a solid
-- #4F8CFF with a lit top edge is quieter, and next to a form full of inputs
-- the quieter control is the one that reads as pressable.
function SUI.cta(ctx, label, w, h, tone, dim)
  local spec, fg, rim, shade
  if tone == 'danger' then
    spec = { { 0x8E2C31FF }, { 0xA83840FF }, { 0x74232AFF } }
    fg, rim, shade = SUI.col.white, 0xFFFFFF2A, 0x070B12FF
  elseif tone == 'raised' then
    -- A chosen segment: lifted off the well, but not amber. Amber is kept for
    -- the one control that starts the job.
    spec = { { 0x262B36FF }, { 0x2E3441FF }, { 0x323846FF } }
    fg, rim, shade = SUI.col.text, 0xFFFFFF1F, nil
  elseif tone == 'ghost' then
    spec = { { 0x00000000 }, { 0x1A1E27FF }, { 0x262B36FF }, outline = true }
    fg, rim, shade = SUI.col.dim, SUI.col.line, nil
  else
    spec = { { SUI.col.accent }, { 0xF5B266FF }, { 0xD98E3AFF } }
    fg, rim, shade = SUI.col.ink_on, 0xFFFFFF59, 0x050608FF
  end
  return _pill_button(ctx, label, w or 0, h or 32, spec, fg, rim, shade, dim,
                      SUI.BTN_R)
end

-- Big number over a small caption. Used on the Results pane.
-- The number and its caption are centred in the card, both ways. Pinned to
-- the top-left they sat hard against the rounded corner — at 22px the digits
-- read as spilling out of the tile rather than sitting in it.
function SUI.stat(ctx, id, value, caption, col, w)
  local VSZ, CSZ, GAPY, CARD_H = 25, 11, 4, 80

  -- Width at the size the line will actually be drawn at, so the font has to
  -- be pushed around the measurement as well as around the draw.
  local function measure(str, size)
    local pushed = _ui_font and pcall(reaper.ImGui_PushFont, ctx, _ui_font, size)
    local ok, tw, th = pcall(reaper.ImGui_CalcTextSize, ctx, str)
    if pushed then pcall(reaper.ImGui_PopFont, ctx) end
    if ok and type(tw) == 'number' then return tw, th end
    return nil, size + 3
  end

  -- One centred line: measure, offset from the card's own left padding, draw.
  local function line(str, size, colour, avail, basex)
    local tw = measure(str, size)
    if tw and type(avail) == 'number' and avail > tw then
      reaper.ImGui_SetCursorPosX(ctx, basex + math.floor((avail - tw) * 0.5))
    end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), colour)
    local pushed = _ui_font and pcall(reaper.ImGui_PushFont, ctx, _ui_font, size)
    reaper.ImGui_Text(ctx, str)
    if pushed then pcall(reaper.ImGui_PopFont, ctx) end
    reaper.ImGui_PopStyleColor(ctx)
  end

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 14.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildBorderSize(), 1.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 14.0, 10.0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x232A36FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),  SUI.col.hair)
  -- ChildBorderSize alone draws nothing: the border is opt-in per child, so
  -- the flag has to come along or the rim is pushed and never painted.
  if reaper.ImGui_BeginChild(ctx, id, w, CARD_H, _child_border_flag(), SUI.NOSB) then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 0.0, GAPY)

    local avail, availy = reaper.ImGui_GetContentRegionAvail(ctx)
    local basex = reaper.ImGui_GetCursorPosX(ctx)
    local _, vh = measure(value, VSZ)
    local _, ch = measure(caption, CSZ)

    -- Vertical centring, minus a hair: a block on the exact centre line reads
    -- as sitting low, because the caption is the lighter of the two rows.
    if type(availy) == 'number' then
      local block = vh + GAPY + ch
      local top   = (availy - block) * 0.5 - 1
      -- Dummy is an item, so ImGui adds one ItemSpacing after it.
      if top > GAPY then SUI.gap(ctx, math.floor(top - GAPY)) end
    end

    line(value,   VSZ, col,           avail, basex)
    line(caption, CSZ, SUI.col.faint, avail, basex)

    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_PopStyleVar(ctx, 3)
end

-- What a pane says when there is nothing to show there yet.
-- An empty pane is mostly space, so the message goes in the middle of it
-- rather than stranded against the top edge. Optically centred — 0.42 rather
-- than a true half, because a block pinned at exact centre reads as low.
function SUI.empty(ctx, title, body)
  local _, availy = reaper.ImGui_GetContentRegionAvail(ctx)
  local blockh = 96
  if type(availy) == 'number' and availy > blockh + 60 then
    SUI.gap(ctx, math.floor((availy - blockh) * 0.42))
  else
    SUI.gap(ctx, 26)
  end
  SUI.big(ctx, SUI.col.dim, title, 16)
  SUI.gap(ctx, 2)
  -- Held to a readable measure instead of the full pane width.
  SUI.wrap(ctx, SUI.col.faint, body, 460)
end

function SUI.mmss(s)
  s = math.max(0, math.floor(s or 0))
  return string.format('%02d:%02d', math.floor(s / 60), s % 60)
end

-- Colour a log line by what it is saying. Keeps a 400-line wall readable.
function SUI.log_colour(line)
  if line:find('ERROR', 1, true) or line:find('Traceback', 1, true)
     or line:find('FAIL', 1, true)   then return SUI.col.err   end
  if line:find('WARN', 1, true)      then return SUI.col.warn  end
  if line:find('[STEP', 1, true)     then return SUI.col.accent end
  if line:find('✓', 1, true) or line:find('done', 1, true)
                                     then return SUI.col.ok    end
  return 0xB9C0CEFF
end

-- Same rules as the colour, named. The chips filter on these.
function SUI.log_is_err(line)
  return (line:find('ERROR', 1, true) or line:find('Traceback', 1, true)
          or line:find('FAIL', 1, true)) ~= nil
end

function SUI.log_is_warn(line)
  return line:find('WARN', 1, true) ~= nil
end

-- Track probe: how many items are sitting on the two named tracks right now.
-- Re-read at most once a second — the answer changes when the user edits the
-- timeline behind the window, and a per-frame scan of every item is wasteful.
local _probe_at, _probe_en, _probe_dub = -1, -1, -1
local function probe_tracks()
  local now = os.clock()
  if now - _probe_at < 1.0 then return _probe_en, _probe_dub end
  _probe_at = now
  local tv = (TRACK_VO_NAME  or '') ~= '' and find_track_by_name(TRACK_VO_NAME)  or nil
  local td = (TRACK_DUB_NAME or '') ~= '' and find_track_by_name(TRACK_DUB_NAME) or nil
  _probe_en  = tv and #get_items_sorted(tv) or -1
  _probe_dub = td and #get_items_sorted(td) or -1
  return _probe_en, _probe_dub
end

-- Run outcome, filled in by on_python_done below. The Results pane reads
-- these instead of scraping the summary paragraph.
local _ui_run_secs   = 0
local _ui_summary    = nil    -- parsed sync_results.json summary, or nil
local _ui_moved      = 0
local _ui_unmatched  = 0
local _ui_row_filter = ''

-- ── Timeline ──────────────────────────────────────────────
-- The job drawn the way REAPER holds it: one lane per track, one block per
-- item. Read from the project at most twice a second. The blocks are
-- positions, not waveforms — enough to see at a glance whether the dub lines
-- up under the VO, and which clips ended up parked.
SUI.tl = { at = -1, lanes = nil }

function SUI.tl_dirty() SUI.tl.at = -1 end

function SUI.tl_read()
  local now = os.clock()
  if SUI.tl.lanes and now - SUI.tl.at < 0.5 then return SUI.tl.lanes end
  SUI.tl.at = now
  local function grab(name, col)
    local tr = (name or '') ~= '' and find_track_by_name(name) or nil
    return { name = name or '', col = col, found = tr ~= nil,
             items = tr and get_items_sorted(tr) or {} }
  end
  SUI.tl.lanes = {
    grab(TRACK_VO_NAME,  SUI.col.vo),
    grab(TRACK_DUB_NAME, SUI.col.dub),
    grab(TRACK_UNSYNC,   SUI.col.err),
  }
  return SUI.tl.lanes
end

-- Draws the lanes into an `h`-tall strip at the cursor, full width.
-- `lit`, when given, is how many items of each lane to draw at full strength;
-- the rest are dimmed. During a run that is how far transcription has got.
function SUI.timeline(ctx, h, lit)
  local lanes = SUI.tl_read()
  local show = {}
  for i, L in ipairs(lanes) do
    -- The parking lane only earns its row once something is parked on it.
    if i <= 2 or #L.items > 0 then
      show[#show + 1] = { L = L, idx = i }
    end
  end

  local okp, x0, y0 = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
  local w = reaper.ImGui_GetContentRegionAvail(ctx)
  if type(w) ~= 'number' or w < 60 then w = 300 end
  reaper.ImGui_Dummy(ctx, w, h)
  if not okp or type(x0) ~= 'number' or not reaper.ImGui_GetWindowDrawList then
    return
  end
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  local t0, t1 = math.huge, -math.huge
  for _, e in ipairs(show) do
    for _, it in ipairs(e.L.items) do
      if it.pos < t0 then t0 = it.pos end
      if it.pos + it.len > t1 then t1 = it.pos + it.len end
    end
  end

  local LBL, GAP = 96, 6
  local n  = #show
  local lh = math.floor((h - GAP * (n - 1)) / n)
  local lx0, lx1 = x0 + LBL, x0 + w
  local okt, _, th = pcall(reaper.ImGui_CalcTextSize, ctx, 'Ag')
  th = (okt and type(th) == 'number') and th or 14

  for row, e in ipairs(show) do
    local L  = e.L
    local ly = y0 + (row - 1) * (lh + GAP)
    local cy = ly + lh * 0.5
    pcall(reaper.ImGui_DrawList_AddRectFilled, dl, x0, cy - 4, x0 + 8, cy + 4, L.col, 2.0)
    pcall(reaper.ImGui_DrawList_PushClipRect, dl, x0, ly, lx0 - 8, ly + lh, true)
    pcall(reaper.ImGui_DrawList_AddText, dl, x0 + 14, cy - th * 0.5,
      L.found and SUI.col.dim or SUI.col.warn, L.name ~= '' and L.name or '(no name)')
    pcall(reaper.ImGui_DrawList_PopClipRect, dl)

    pcall(reaper.ImGui_DrawList_AddRectFilled, dl, lx0, ly, lx1, ly + lh, SUI.col.well, 6.0)

    if not L.found then
      pcall(reaper.ImGui_DrawList_AddText, dl, lx0 + 10, cy - th * 0.5,
        SUI.col.warn, 'no track by this name')
    elseif t1 > t0 then
      local sx  = (lx1 - lx0 - 8) / (t1 - t0)
      local lim = lit and lit[e.idx]
      for k, it in ipairs(L.items) do
        local a = lx0 + 4 + (it.pos - t0) * sx
        local b = math.max(a + 2, a + it.len * sx - 1)
        local c = _col_fade(L.col, (lim and k > lim) and 0.25 or 0.85)
        pcall(reaper.ImGui_DrawList_AddRectFilled, dl, a, ly + 4, b, ly + lh - 4, c, 3.0)
      end
    end
  end

  if t1 <= t0 then
    local msg = 'No items on these tracks yet'
    local okm, mw = pcall(reaper.ImGui_CalcTextSize, ctx, msg)
    mw = (okm and type(mw) == 'number') and mw or 180
    pcall(reaper.ImGui_DrawList_AddText, dl,
      lx0 + math.max(8, (lx1 - lx0 - mw) * 0.5), y0 + h * 0.5 - th * 0.5,
      SUI.col.faint, msg)
  end
end

-- Collect / Match / Place as three boxes, each with its own bar. Done is
-- teal, the one in progress is amber, the rest wait in a hairline.
SUI.PHASES = {
  { 'Collect', 'reading items, writing config', 0.00, 0.05 },
  { 'Match',   'transcribe, then align',        0.05, 0.92 },
  { 'Place',   'move dub items into place',     0.92, 1.00 },
}

function SUI.phase_strip(ctx)
  local H, GAP = 62, 8
  local okp, x0, y0 = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
  local w = reaper.ImGui_GetContentRegionAvail(ctx)
  if type(w) ~= 'number' or w < 60 then w = 300 end
  reaper.ImGui_Dummy(ctx, w, H)
  if not okp or type(x0) ~= 'number' or not reaper.ImGui_GetWindowDrawList then
    return
  end
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local bw = (w - GAP * 2) / 3
  local all_done = (_ui_phase == 'success')
  for i, p in ipairs(SUI.PHASES) do
    local bx = x0 + (i - 1) * (bw + GAP)
    local frac = 0
    if all_done or _ui_step_idx > i then
      frac = 1
    elseif _ui_step_idx == i and _ui_phase == 'running' then
      frac = (_ui_progress - p[3]) / (p[4] - p[3])
      if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    end
    local done   = frac >= 1
    local active = (not done) and _ui_phase == 'running' and _ui_step_idx == i
    local edge   = done and _col_fade(SUI.col.vo, 0.55)
                   or (active and SUI.col.dub or SUI.col.rim)

    pcall(reaper.ImGui_DrawList_AddRectFilled, dl, bx, y0, bx + bw, y0 + H, SUI.col.well, 10.0)
    pcall(reaper.ImGui_DrawList_AddRect, dl, bx, y0, bx + bw, y0 + H, edge, 10.0, 0, 1.0)

    -- Number in a ring, or a tick in a filled teal disc once done.
    local cx, cy = bx + 20, y0 + 19
    if done then
      pcall(reaper.ImGui_DrawList_AddCircleFilled, dl, cx, cy, 9, SUI.col.vo)
      SUI.tick(dl, cx, cy, SUI.col.bg)
    else
      pcall(reaper.ImGui_DrawList_AddCircle, dl, cx, cy, 9,
        active and SUI.col.dub or SUI.col.line, 0, 1.5)
      SUI.centre_text(ctx, dl, cx, cy, tostring(i),
        active and SUI.col.dub or SUI.col.faint)
    end
    pcall(reaper.ImGui_DrawList_PushClipRect, dl, bx, y0, bx + bw - 8, y0 + H, true)
    pcall(reaper.ImGui_DrawList_AddText, dl, bx + 36, y0 + 11,
      (done or active) and SUI.col.text or SUI.col.dim, p[1])
    pcall(reaper.ImGui_DrawList_AddText, dl, bx + 12, y0 + 32, SUI.col.faint, p[2])
    pcall(reaper.ImGui_DrawList_PopClipRect, dl)

    local by = y0 + H - 9
    pcall(reaper.ImGui_DrawList_AddRectFilled, dl, bx + 12, by, bx + bw - 12, by + 3,
      SUI.col.rim, 2.0)
    if frac > 0 then
      pcall(reaper.ImGui_DrawList_AddRectFilled, dl, bx + 12, by,
        bx + 12 + (bw - 24) * frac, by + 3, done and SUI.col.vo or SUI.col.dub, 2.0)
    end
  end
end

-- A tick drawn as two strokes: the default face stops at Latin-1, so a ✓
-- glyph would render as a box on most installs.
function SUI.tick(dl, cx, cy, col)
  pcall(reaper.ImGui_DrawList_AddLine, dl, cx - 4, cy, cx - 1, cy + 3, col, 1.8)
  pcall(reaper.ImGui_DrawList_AddLine, dl, cx - 1, cy + 3, cx + 4.5, cy - 3.5, col, 1.8)
end

function SUI.centre_text(ctx, dl, cx, cy, s, col)
  local ok, tw, th = pcall(reaper.ImGui_CalcTextSize, ctx, s)
  if not (ok and type(tw) == 'number') then tw, th = 7, 13 end
  pcall(reaper.ImGui_DrawList_AddText, dl, cx - tw * 0.5, cy - (th or 13) * 0.5, col, s)
end

-- The window's close button, drawn the way REAPER's own windows draw theirs:
-- a thin cross with nothing around it, and a red block behind it on hover.
-- ImGui's own is a heavy cross in a circle and cannot be restyled, so the
-- window opens without one while floating (see frame()) and this is painted
-- in its place on the title bar.
--
-- It is NOT an ImGui item. Placing a button on the title bar means moving the
-- cursor there and back, and ImGui 1.89+ throws at End() when a SetCursorPos
-- is the last thing in a window — which stopped the whole script. So this
-- only draws, and reads the mouse itself: armed on a press inside the box,
-- fired on a release still inside it, like a real button.
--
-- `native_close` hands closing back to ImGui: when docked (no title bar;
-- REAPER's docker owns it), when an API it needs is missing, or if drawing
-- ever fails. The window must never end up with no way to close.
SUI.native_close = not (reaper.ImGui_GetMousePos and reaper.ImGui_IsMouseClicked
  and reaper.ImGui_IsMouseReleased and reaper.ImGui_IsWindowHovered
  and reaper.ImGui_DrawList_PushClipRect and reaper.ImGui_GetWindowDrawList)
SUI.close_armed = false

function SUI.close_x(ctx, title_h, on_close)
  local docked = false
  if reaper.ImGui_IsWindowDocked then
    local ok, d = pcall(reaper.ImGui_IsWindowDocked, ctx)
    docked = (ok and d) and true or false
  end
  if docked then SUI.native_close = true; return end
  if SUI.native_close and not docked and SUI._api_missing then return end
  SUI.native_close = false

  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local ww = reaper.ImGui_GetWindowWidth(ctx)
  if type(wx) ~= 'number' or type(ww) ~= 'number' then return end

  local W, H = 40, title_h
  local x0, y0, x1, y1 = wx + ww - 1 - W, wy + 1, wx + ww - 1, wy + H

  -- Hover: the pointer is in the box and nothing else is on top of us.
  -- AllowWhenBlockedByActiveItem, because pressing on the title bar makes
  -- ImGui start a window move, which would otherwise hide the release.
  local hf = reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem
             and reaper.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem() or 0
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  local inside = type(mx) == 'number' and mx >= x0 and mx < x1 and my >= y0 and my < y1
  local hov = inside and reaper.ImGui_IsWindowHovered(ctx, hf)

  if hov and reaper.ImGui_IsMouseClicked(ctx, 0) then SUI.close_armed = true end
  local fire = false
  if SUI.close_armed and reaper.ImGui_IsMouseReleased(ctx, 0) then
    fire = inside
    SUI.close_armed = false
  end

  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  -- The title bar lies outside the content clip rect; lift it for the paint.
  reaper.ImGui_DrawList_PushClipRect(dl, wx, wy, wx + ww, wy + H, false)
  if hov or SUI.close_armed then
    local TR = reaper.ImGui_DrawFlags_RoundCornersTopRight
               and reaper.ImGui_DrawFlags_RoundCornersTopRight() or 0
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1,
      SUI.close_armed and 0xA3241AFF or 0xC42B1CFF, 9.0, TR)
  end
  local c = (hov or SUI.close_armed) and SUI.col.white or SUI.col.dim
  local cx, cy, r = (x0 + x1) * 0.5, (y0 + y1) * 0.5, 4.5
  reaper.ImGui_DrawList_AddLine(dl, cx - r, cy - r, cx + r, cy + r, c, 1.0)
  reaper.ImGui_DrawList_AddLine(dl, cx + r, cy - r, cx - r, cy + r, c, 1.0)
  reaper.ImGui_DrawList_PopClipRect(dl)

  if fire then on_close() end
end
SUI._api_missing = SUI.native_close

-- Back to the setup form after a run, keeping the settings.
function SUI.reset_run()
  _ui_phase = 'setup'; _ui_failure = nil
  _ui_step_idx = 0; _ui_progress = 0.0
  _ui_en_total = 0; _ui_dub_total = 0; _ui_en_done = 0; _ui_dub_done = 0
  _poll_step_phase = 0; _ui_cancelled = false
  _ui_results_rows = {}; _ui_summary = nil; _ui_row_filter = ''
  log_clear(); _ui_result = nil
  SUI.tl_dirty()
end

-- The log lives in a drawer under the pane, not on a page of its own: the
-- one line you want during a run is the newest, and it should be readable
-- from whichever page you are on.
SUI.drawer_open = false
SUI.DRAWER_SHUT = 42

-- Gateway first: your own OpenAI-compatible LLM plus an ElevenLabs key is
-- the usual setup, so it is the mode the panel opens on.
local CONN_LABELS = { 'Gateway', 'Server', 'AI Studio', 'Vertex' }
local CONN_VALUES = { 'gateway', 'server', 'studio',    'vertex' }


-- ═══════════════════════════════════════════════════════════
-- NAVIGATION SHELL — a rail of stages, one detail pane, one action bar
-- ═══════════════════════════════════════════════════════════
-- The rail is the same in every phase, so a finished run is somewhere you can
-- navigate back to rather than a screen that replaced the form. `_ui_phase`
-- still owns what the engine is doing; `_ui_nav` owns what you are looking at.

-- Shell metrics. SHELL_PAD is the margin between the window border and the
-- three regions — without it the rail sits flush against the frame and the
-- rounded window corner gets painted over by a square child.
local RAIL_W, SHELL_PAD = 212, 10

-- Title-bar metrics. ImGui draws the bar inside Begin() off whatever font and
-- FramePadding are on the stack, and sizes its close button off the FONT
-- alone — so these three numbers are the whole geometry of that bar.
local TITLE_PX, TITLE_PAD_X, TITLE_PAD_Y = 12, 10, 5

local _ui_nav        = 'session'
local _ui_last_phase = nil

-- One size for every section. An earlier build fitted the window to whichever
-- pane was showing, which meant the window jumped on every click of the rail —
-- so the size is set once, from the section that needs the most room (the
-- script box and the worker log), and the shorter forms simply sit in it.

-- Per-frame readiness, computed once in the shell and read by every pane and
-- by the action bar. Recomputing it inside each pane would mean the rail dot
-- and the Start button could disagree within a single frame.
local _st = {}

-- One dialog at a time. A pane that wants to ask something fills this in;
-- the shell opens and draws it at WINDOW scope, because a popup opened from
-- inside a child belongs to that child and gets clipped by it.
--   { title, body, items, note, ok, cancel, tone, on_ok }
local _ui_dialog = nil

local function ui_ask(spec) _ui_dialog = spec end

-- The log is not a stage: it is the drawer under every page.
local NAV = {
  { key = 'session',    num = '1', label = 'Session'    },
  { key = 'connection', num = '2', label = 'Connection' },
  { key = 'script',     num = '3', label = 'Script'     },
  { key = 'run',        num = '4', label = 'Run'        },
  { key = 'results',    num = '5', label = 'Results'    },
}

local PANE_HEAD = {
  session    = { 'Session',
                 'Which tracks Samanvaya reads, and what language the dub is in.' },
  connection = { 'Connection',
                 'ElevenLabs transcribes; an LLM matches the lines.' },
  script     = { 'Reference script',
                 'Optional. The matcher pivots through it to group lines.' },
  run        = { 'Run',
                 'Collect, match, place. REAPER stays usable throughout.' },
  log        = { 'Worker log',
                 'Every line the Python worker printed, newest at the bottom.' },
  results    = { 'Results',
                 'What was placed, what was not, and where to find it.' },
}

-- Recompute everything the rail, the panes and the action bar share.
local function refresh_state()
  -- The credential check runs off the frame loop: debounce, launch, poll.
  probe_tick()

  local function fexists(p)
    local h = io.open(p, 'r'); if h then h:close(); return true end; return false
  end

  -- Matching is Gemini and transcription is ElevenLabs, always. Pin them here
  -- so a hand-edited settings file cannot smuggle another value into a run.
  MATCH_MODE, ASR_PROVIDER = 'gemini', 'elevenlabs'

  _st.en, _st.dub = probe_tracks()
  _st.tracks_named = (TRACK_VO_NAME ~= '' and TRACK_DUB_NAME ~= '')
  _st.tracks_ok    = _st.tracks_named and _st.en > 0 and _st.dub > 0

  _st.has_vertex_file = fexists(get_script_dir() .. '/vertex_key.json')
    or (VERTEX_KEY_PATH ~= '' and fexists(VERTEX_KEY_PATH))

  _st.conn_idx = 1
  for i, v in ipairs(CONN_VALUES) do if v == CONN_MODE then _st.conn_idx = i end end

  -- What is still missing, named exactly as the field is labelled.
  local miss = {}
  if TRACK_VO_NAME  == '' then miss[#miss+1] = 'VO track name'  end
  if TRACK_DUB_NAME == '' then miss[#miss+1] = 'Dub track name' end
  _st.session_missing = #miss

  if CONN_MODE == 'server' then
    if (SERVER_URL or '') == '' then miss[#miss+1] = 'Server URL'   end
    if (API_TOKEN  or '') == '' then miss[#miss+1] = 'Access token' end
  else
    if CONN_MODE == 'gateway' then
      if (GEMINI_BASE_URL or '') == '' then miss[#miss+1] = 'LLM URL'     end
      if (GEMINI_KEY      or '') == '' then miss[#miss+1] = 'LLM API key' end
    elseif CONN_MODE == 'vertex' then
      if not _st.has_vertex_file and (VERTEX_KEY_PATH or '') == '' then
        miss[#miss+1] = 'Vertex service JSON'
      end
    else
      if (GEMINI_KEY or '') == '' then miss[#miss+1] = 'Gemini key' end
    end
    -- ElevenLabs turns audio into text; the Gemini matcher never touches
    -- audio, so a direct-mode run needs that key whichever backend is picked.
    if (ELEVENLABS_KEY or '') == '' then miss[#miss+1] = 'ElevenLabs key' end
  end
  _st.missing    = miss
  _st.conn_ok    = (#miss == _st.session_missing)
  _st.can_start  = (#miss == 0)
  _st.script_on  = ((SCRIPT_TEXT or '') ~= '')
  _st.running    = (_ui_phase == 'running')
  _st.finished   = (_ui_phase == 'success' or _ui_phase == 'failure')

  local backend
  if     CONN_MODE == 'server'  then backend = SERVER_URL ~= '' and SERVER_URL or 'server'
  elseif CONN_MODE == 'studio'  then backend = 'AI Studio'
  elseif CONN_MODE == 'vertex'  then backend = 'Vertex'
  else   backend = GEMINI_BASE_URL ~= '' and GEMINI_BASE_URL or 'gateway' end
  _st.footnote = string.format('%s   ·   %s   ·   %s',
    lang_name(DUB_LANGUAGE), GEMINI_MODEL or '?', backend)

  -- Rail dots.
  _st.dot_session = _st.tracks_ok and 'ok' or 'warn'
  _st.dot_conn    = _st.conn_ok   and 'ok' or 'warn'
  _st.dot_script  = _st.script_on and 'ok' or 'off'
  _st.dot_run     = _st.running and 'ok' or (_st.finished and 'ok' or 'off')
  _st.dot_log     = (#_log_buffer > 0) and (_st.running and 'ok' or 'dim') or 'off'
  if _ui_phase == 'success' then
    _st.dot_results = (_ui_unmatched > 0) and 'warn' or 'ok'
  elseif _ui_phase == 'failure' then
    _st.dot_results = 'err'
  else
    _st.dot_results = 'off'
  end

  -- One line under each rail entry, so the rail answers "what is set" without
  -- opening anything.
  local function items(n) return n == 1 and '1 clip' or (n .. ' clips') end
  local R = {}
  if not _st.tracks_named then
    R.session = { 'warn', 'Name the two tracks' }
  elseif _st.en < 0 or _st.dub < 0 then
    R.session = { 'warn', 'Track not found' }
  elseif not _st.tracks_ok then
    R.session = { 'warn', 'No items on the tracks' }
  else
    R.session = { 'ok', string.format('%s VO · %s dub', _st.en, _st.dub) }
  end

  local mode = CONN_LABELS[_st.conn_idx] or 'Gateway'
  local pr = _probe.results and _probe.results[CONN_MODE == 'server' and 'server' or 'matcher']
  local pst = pr and pr.status
  if not _st.conn_ok then
    R.connection = { 'warn', 'Needs ' .. (_st.missing[_st.session_missing + 1] or 'a key') }
  elseif pst == 'invalid_key' or pst == 'not_found' or pst == 'provider_down' then
    R.connection = { 'err', mode .. ' · check the key' }
  elseif pst == 'ok' then
    R.connection = { 'ok', mode .. ' · verified' }
  elseif pst == 'checking' then
    R.connection = { 'ok', mode .. ' · checking' }
  else
    R.connection = { 'ok', mode .. ' · set' }
  end

  if _st.script_on then
    local paras = 1
    for _ in SCRIPT_TEXT:gmatch('\n%s*\n') do paras = paras + 1 end
    R.script = { 'ok', paras .. (paras == 1 and ' topic' or ' topics') }
  else
    R.script = { 'off', 'Optional' }
  end

  if _st.running then
    R.run = { 'run', string.format('Running · %d%%', math.floor(_ui_progress * 100)) }
  elseif _ui_phase == 'success' then
    R.run = { 'ok', 'Done · ' .. SUI.mmss(_ui_run_secs) }
  elseif _ui_phase == 'failure' then
    R.run = { 'err', _ui_cancelled and 'Cancelled' or 'Failed' }
  else
    R.run = { 'off', _st.can_start and 'Ready to sync' or 'Not ready yet' }
  end

  if _ui_phase == 'success' then
    R.results = { _ui_unmatched > 0 and 'warn' or 'ok',
      string.format('%d placed · %d parked', _ui_moved, _ui_unmatched) }
  elseif _ui_phase == 'failure' then
    R.results = { 'err', 'See the log' }
  else
    R.results = { 'off', 'After the run' }
  end
  R.items = items
  _st.rail = R
end

-- Follow the engine: a run that starts pulls you to Run, a run that ends
-- pulls you to Results, and going back to setup lands on Session. Doing it
-- here rather than at each transition site means one rule instead of four.
local function sync_nav_to_phase()
  if _ui_phase == _ui_last_phase then return end
  _ui_last_phase = _ui_phase
  if     _ui_phase == 'running' then _ui_nav = 'run'
  elseif _ui_phase == 'success' or _ui_phase == 'failure' then
    _ui_nav = 'results'
    SUI.tl_dirty()
    if _ui_phase == 'failure' then SUI.drawer_open = true end
  elseif _ui_phase == 'setup'   then _ui_nav = 'session' end
end


-- ─── The rail ─────────────────────────────────────────────
-- Wordmark, the five stages with a status line under each, and — pinned to
-- the foot — the readiness card that holds Start sync. The button lives here
-- rather than on one page, so it is in reach from wherever you are setting up.
local function ui_rail(ctx, on_start)
  local open = SUI.pane(ctx, '##rail', RAIL_W, 0, SUI.col.rail, 12.0, 14.0, 14.0)
  if open then
    local INNER_W = RAIL_W - 24
    do
      local oka, aw = pcall(reaper.ImGui_GetContentRegionAvail, ctx)
      if oka and type(aw) == 'number' and aw > 0 then INNER_W = aw end
    end
    local dl = reaper.ImGui_GetWindowDrawList(ctx)

    -- Wordmark: a tile split teal | amber — the two lanes — then the name.
    do
      local okp, x0, y0 = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
      reaper.ImGui_Dummy(ctx, 24, 24)
      if okp and type(x0) == 'number' then
        local L = reaper.ImGui_DrawFlags_RoundCornersLeft
                  and reaper.ImGui_DrawFlags_RoundCornersLeft() or 0
        local Rr = reaper.ImGui_DrawFlags_RoundCornersRight
                   and reaper.ImGui_DrawFlags_RoundCornersRight() or 0
        pcall(reaper.ImGui_DrawList_AddRectFilled, dl, x0, y0, x0 + 12, y0 + 24, SUI.col.vo, 7.0, L)
        pcall(reaper.ImGui_DrawList_AddRectFilled, dl, x0 + 12, y0, x0 + 24, y0 + 24, SUI.col.dub, 7.0, Rr)
      end
      reaper.ImGui_SameLine(ctx, 0, 9)
      local cy = reaper.ImGui_GetCursorPosY(ctx)
      reaper.ImGui_SetCursorPosY(ctx, cy + 2)
      SUI.big(ctx, SUI.col.white, 'Samanvaya', 16)
    end
    local ver = (_APP_VERSION ~= '' and ('  ·  v' .. _APP_VERSION) or '')
    SUI.fitline(ctx, SUI.col.faint, {
      'DUB ALIGNMENT' .. ver, 'DUB ALIGNMENT',
    }, 10, INNER_W)
    SUI.gap(ctx, 10)
    SUI.eyebrow(ctx, 'Workflow')
    SUI.gap(ctx, 2)

    local R = _st.rail or {}
    local ROW_H = 44
    for _, e in ipairs(NAV) do
      local on    = (_ui_nav == e.key)
      local st    = R[e.key] or { 'off', '' }
      local state, line = st[1], st[2]

      local okp, x0, y0 = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
      if reaper.ImGui_InvisibleButton(ctx, '##nav' .. e.key, INNER_W, ROW_H) then
        _ui_nav = e.key
      end
      local okh, hov = pcall(reaper.ImGui_IsItemHovered, ctx)
      hov = okh and hov or false

      if okp and type(x0) == 'number' then
        local x1, y1 = x0 + INNER_W, y0 + ROW_H
        if on then
          pcall(reaper.ImGui_DrawList_AddRectFilled, dl, x0, y0 + 1, x1, y1 - 1, SUI.col.cardhi, 9.0)
          pcall(reaper.ImGui_DrawList_AddRect, dl, x0, y0 + 1, x1, y1 - 1, SUI.col.line, 9.0, 0, 1.0)
        elseif hov then
          pcall(reaper.ImGui_DrawList_AddRectFilled, dl, x0, y0 + 1, x1, y1 - 1, 0xFFFFFF08, 9.0)
        end

        -- The disc: you-are-here wins, then the stage's own state.
        local cx, cy = x0 + 18, y0 + ROW_H * 0.5
        local ring = ({ ok = SUI.col.vo, warn = SUI.col.warn, err = SUI.col.err,
                        run = SUI.col.dub })[state] or SUI.col.line
        if on then
          pcall(reaper.ImGui_DrawList_AddCircleFilled, dl, cx, cy, 11, SUI.col.text)
          if state == 'ok' then SUI.tick(dl, cx, cy, SUI.col.bg)
          else SUI.centre_text(ctx, dl, cx, cy, e.num, SUI.col.bg) end
        else
          pcall(reaper.ImGui_DrawList_AddCircle, dl, cx, cy, 11, ring, 0, 1.5)
          if state == 'ok' then SUI.tick(dl, cx, cy, SUI.col.vo)
          else
            SUI.centre_text(ctx, dl, cx, cy, e.num,
              state == 'off' and SUI.col.faint or ring)
          end
        end

        pcall(reaper.ImGui_DrawList_PushClipRect, dl, x0, y0, x1 - 6, y1, true)
        pcall(reaper.ImGui_DrawList_AddText, dl, x0 + 38, y0 + 6,
          on and SUI.col.white or SUI.col.text, e.label)
        local lc = ({ warn = SUI.col.warn, err = SUI.col.err, run = SUI.col.dub })[state]
                   or SUI.col.faint
        if _ui_font then
          local pushed = pcall(reaper.ImGui_PushFont, ctx, _ui_font, 11)
          pcall(reaper.ImGui_DrawList_AddText, dl, x0 + 38, y0 + 24, lc, line)
          if pushed then pcall(reaper.ImGui_PopFont, ctx) end
        else
          pcall(reaper.ImGui_DrawList_AddText, dl, x0 + 38, y0 + 23, lc, line)
        end
        pcall(reaper.ImGui_DrawList_PopClipRect, dl)
      end
    end

    -- ── Readiness card, pinned to the foot ──
    local CARD_H = 142
    local _, ry = reaper.ImGui_GetContentRegionAvail(ctx)
    if type(ry) == 'number' and ry > CARD_H + 6 then SUI.gap(ctx, ry - CARD_H - 6) end

    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 12.0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildBorderSize(), 1.0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 12.0, 11.0)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), SUI.col.bg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),  SUI.col.rim)
    local cf, wf = _child_pad_flag()
    if reaper.ImGui_BeginChild(ctx, '##ready', -1, CARD_H,
                               _child_border_flag() | cf, SUI.NOSB | wf) then
      local fullw = reaper.ImGui_GetContentRegionAvail(ctx)
      if type(fullw) ~= 'number' or fullw < 80 then fullw = 160 end
      local set = (_st.session_missing == 0 and _st.tracks_ok and 1 or 0)
                + (_st.conn_ok and 1 or 0)
      SUI.eyebrow(ctx, 'Ready')
      reaper.ImGui_SameLine(ctx)
      local tag = set .. ' of 2 set'
      local okw, tw = pcall(reaper.ImGui_CalcTextSize, ctx, tag)
      local cw = reaper.ImGui_GetContentRegionAvail(ctx)
      if okw and type(tw) == 'number' and type(cw) == 'number' then
        reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + cw - tw)
      end
      SUI.text(ctx, SUI.col.faint, tag)

      -- Three segments: session, connection, and the optional script — which
      -- fills teal when present and stays a hairline when not, never amber.
      do
        local okp, mx, my = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
        local mw = reaper.ImGui_GetContentRegionAvail(ctx)
        reaper.ImGui_Dummy(ctx, mw, 4)
        if okp and type(mx) == 'number' and type(mw) == 'number' then
          local segs = { _st.tracks_ok, _st.conn_ok, _st.script_on }
          local sw = (mw - 8) / 3
          for i, on in ipairs(segs) do
            local sx = mx + (i - 1) * (sw + 4)
            pcall(reaper.ImGui_DrawList_AddRectFilled, reaper.ImGui_GetWindowDrawList(ctx),
              sx, my, sx + sw, my + 4, on and SUI.col.vo or SUI.col.rim, 2.0)
          end
        end
      end
      SUI.gap(ctx, 4)

      local label, tone, act, disabled, hint, hint_col
      if _st.running then
        label, tone, act = 'Cancel run', 'danger', cancel_python
        hint, hint_col = string.format('Matching · %d%%', math.floor(_ui_progress * 100)),
                         SUI.col.dub
      elseif _st.finished then
        label, act = 'Sync again', SUI.reset_run
        hint_col = (_ui_phase == 'success') and SUI.col.ok or SUI.col.err
        hint = (_ui_phase == 'success')
          and string.format('%d placed · %d parked', _ui_moved, _ui_unmatched)
          or (_ui_cancelled and 'Cancelled.' or 'Run failed — see the log.')
      else
        label, act = 'Start sync', on_start
        disabled = not _st.can_start
        if disabled then
          hint, hint_col = 'Needs: ' .. table.concat(_st.missing, ', '), SUI.col.warn
        elseif not _st.tracks_ok then
          hint, hint_col = 'No items on the tracks yet.', SUI.col.warn
        else
          hint, hint_col = string.format('%s dub → %s', R.items(_st.dub), TRACK_VO_NAME),
                           SUI.col.faint
        end
      end
      _ui_begin_disabled(ctx, disabled == true)
      if SUI.cta(ctx, label .. '##go', fullw, 38, tone, disabled == true) then
        act()
      end
      _ui_end_disabled(ctx)
      SUI.gap(ctx, 1)
      SUI.wrap(ctx, hint_col, hint)
      reaper.ImGui_EndChild(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 2)
    reaper.ImGui_PopStyleVar(ctx, 3)
  end
  SUI.pane_end(ctx, open)
end


-- ─── Panes ────────────────────────────────────────────────
local function ui_pane_session(ctx)
  -- Negative item widths, so the input stretches with the window and the
  -- caption to its right always keeps its own column. A fixed width overlaps
  -- the caption the moment the window is dragged narrow.
  -- The caption column is measured, not guessed: every caption this pane can
  -- show is listed here, and the widest one sets the column. "no track" and
  -- the item counts swap in and out with the timeline, so the column has to
  -- be wide enough for the worst case or the row would reflow as you type.
  local GUT = 92
  local CAPW = SUI.capw(ctx, {
    'no track', '9999 items', 'of the dub', 'made if absent',
  })

  local open = SUI.card_begin(ctx, '##c_session', 150)
  if open then
    local rv
    SUI.field(ctx, 'VO track', GUT, CAPW)
    rv, TRACK_VO_NAME = reaper.ImGui_InputText(ctx, '##votrk', TRACK_VO_NAME or '')
    reaper.ImGui_SameLine(ctx, 0, 10)
    SUI.ftext(ctx, _st.en < 0 and SUI.col.warn or SUI.col.faint,
      _st.en < 0 and 'no track'
                 or string.format('%d item%s', _st.en, _st.en == 1 and '' or 's'))

    SUI.field(ctx, 'Dub track', GUT, CAPW)
    rv, TRACK_DUB_NAME = reaper.ImGui_InputText(ctx, '##dubtrk', TRACK_DUB_NAME or '')
    reaper.ImGui_SameLine(ctx, 0, 10)
    SUI.ftext(ctx, _st.dub < 0 and SUI.col.warn or SUI.col.faint,
      _st.dub < 0 and 'no track'
                  or string.format('%d item%s', _st.dub, _st.dub == 1 and '' or 's'))

    SUI.field(ctx, 'Language', GUT, CAPW)
    do
      local picked_ok, picked = _ui_combo(ctx, '##dublang',
        lang_name(DUB_LANGUAGE), _LANG_NAMES)
      if picked_ok then
        for i, name in ipairs(_LANG_NAMES) do
          if name == picked then DUB_LANGUAGE = _LANG_ORDER[i] break end
        end
      end
    end
    reaper.ImGui_SameLine(ctx, 0, 10)
    SUI.ftext(ctx, SUI.col.faint, 'of the dub')

    SUI.field(ctx, 'Unplaced to', GUT, CAPW)
    rv, TRACK_UNSYNC = reaper.ImGui_InputText(ctx, '##unsynctrk', TRACK_UNSYNC or '')
    reaper.ImGui_SameLine(ctx, 0, 10)
    SUI.ftext(ctx, SUI.col.faint, 'made if absent')
  end
  SUI.card_end(ctx, open)

  -- ── Build the session ───────────────────────────────────
  -- A blank project is how a session normally starts, and the tracks it
  -- needs are a fixed thing, so the panel offers to lay them out rather than
  -- leaving the engineer to import a template by hand. The row names what it
  -- would build before it builds it, and goes quiet once those tracks are
  -- there: Create never touches a project that already has them.
  SUI.gap(ctx, 10)
  SUI.eyebrow(ctx, 'Project structure')
  SUI.gap(ctx, 2)
  do
    local blocks = template_probe()
    local names, clash = {}, nil
    if blocks then
      for _, b in ipairs(blocks) do
        if b.name ~= '' then
          names[#names + 1] = b.name
          if not clash and find_track_by_name(b.name) then clash = b.name end
        end
      end
    end
    local can = (blocks ~= nil) and (clash == nil)

    _ui_begin_disabled(ctx, not can)
    if SUI.cta(ctx, 'Create##struct', 108, 30, nil, not can) and can then
      -- Ask before touching the timeline. Building tracks is cheap to undo
      -- but it is still the panel writing into someone's project, and the
      -- list in the dialog is also the last chance to notice that the
      -- template is not the one they meant.
      ui_ask({
        title = 'Create the project structure?',
        body  = 'These tracks will be added to the current project, each '
             .. 'with the FX chain saved in AutoSync.RPP:',
        items = names,
        note  = 'Nothing already in the project is touched, and the whole '
             .. 'build is a single undo step.',
        ok    = 'Create',
        on_ok = function()
          local made, why = create_project_structure()
          if made then
            _probe_at = -1      -- the counts above are stale; re-read them now
            SUI.tl_dirty()
            log(string.format('Created %d track%s from the template: %s',
              #made, #made == 1 and '' or 's', table.concat(made, ', ')))
            ui_set_banner('info', string.format('%d track%s added — %s.',
              #made, #made == 1 and '' or 's', table.concat(made, ', ')))
          else
            ui_set_banner('error',
              why or 'Could not build the project structure.')
          end
        end,
      })
    end
    _ui_end_disabled(ctx)

    -- The caption sits on the button's own text line rather than the top of
    -- a 30px row — the nudge SUI.ftext makes for a framed widget, done by
    -- hand because this button is taller than a frame.
    reaper.ImGui_SameLine(ctx, 0, 12)
    local cx, cy = reaper.ImGui_GetCursorPos(ctx)
    reaper.ImGui_SetCursorPos(ctx, cx, cy + 8)
    if not blocks then
      SUI.text(ctx, SUI.col.warn, 'AutoSync template not found')
    elseif clash then
      SUI.text(ctx, SUI.col.faint, 'already in this project')
    else
      SUI.text(ctx, SUI.col.faint, table.concat(names, '  ·  '))
    end
  end

  SUI.gap(ctx, 12)
  SUI.eyebrow(ctx, 'What the run will see')
  SUI.gap(ctx, 3)
  SUI.timeline(ctx, 70)
  SUI.gap(ctx, 6)
  SUI.wrap(ctx, SUI.col.faint,
    'Counts and lanes come straight from the timeline, so a wrong track name '
    .. 'shows up here rather than three minutes into a run. Create builds the '
    .. 'tracks and FX chains saved in AutoSync/AutoSync.RPP.')
end


-- ─── What was pasted, and whether it works ────────────────
-- Detection is offline and immediate; the status pill next to it comes from
-- the provider itself. Nothing here is a stored list of models — an empty
-- pane means the check has not answered yet, never that we assumed.
local PROBE_WORDS = {
  checking      = { 'Checking…',        'dim'   },
  ok            = { 'Available',        'ok'    },
  model_missing = { 'Model not found',  'warn'  },
  invalid_key   = { 'Invalid API key',  'err'   },
  not_found     = { 'Endpoint missing', 'err'   },
  rate_limited  = { 'Rate limited',     'warn'  },
  provider_down = { 'Unavailable',      'err'   },
  unverified    = { 'Not verified',     'dim'   },
}

local function ui_status_pill(ctx, status)
  local w = PROBE_WORDS[status] or PROBE_WORDS.unverified
  local bg, fg
  if     w[2] == 'ok'   then bg, fg = 0x16352AFF, SUI.col.ok
  elseif w[2] == 'warn' then bg, fg = 0x3A2F16FF, SUI.col.warn
  elseif w[2] == 'err'  then bg, fg = 0x3A1A1EFF, SUI.col.err
  else                       bg, fg = SUI.col.cardhi, SUI.col.dim end
  SUI.pill(ctx, w[1] .. '##st' .. status, bg, fg)
end

-- One provider: what it is, what it said, and the models it offered.
-- `current` is the model the row should show as selected; `on_pick` is only
-- for rows whose choice writes back into a setting.
local function ui_probe_row(ctx, id, key, base, on_pick, current)
  local r = _probe.results[id]
  local pid, plabel, phint = detect_provider(key, base)
  local fam = detect_model_family(id == 'asr' and ELEVENLABS_MODEL or GEMINI_MODEL)

  SUI.ftext(ctx, SUI.col.text, plabel or 'No credential yet')
  if phint then
    reaper.ImGui_SameLine(ctx, 0, 8)
    SUI.ftext(ctx, SUI.col.faint, phint .. ((key ~= '') and ('  ·  ' .. _mask_key(key)) or ''))
  end
  reaper.ImGui_SameLine(ctx)
  -- Right-aligned against the card's inner edge. The pill is as wide as its
  -- own word plus its frame padding, so "Endpoint missing" no longer pushes
  -- past the rim the way a fixed 118px budget let it.
  do
    local word = (PROBE_WORDS[(r and r.status) or 'unverified']
                  or PROBE_WORDS.unverified)[1]
    local okw, tw = pcall(reaper.ImGui_CalcTextSize, ctx, word)
    local pill_w = (okw and type(tw) == 'number') and (tw + 22) or 118
    reaper.ImGui_SetCursorPosX(ctx,
      math.max(160, reaper.ImGui_GetWindowWidth(ctx) - 15 - pill_w))
  end
  ui_status_pill(ctx, r and r.status or 'unverified')

  if fam then
    SUI.text(ctx, SUI.col.faint, fam)
  end
  if r and r.msg ~= '' then
    local col = SUI.col.dim
    if r.status == 'invalid_key' or r.status == 'not_found'
       or r.status == 'provider_down'  then col = SUI.col.err
    elseif r.status == 'model_missing'
       or r.status == 'rate_limited'   then col = SUI.col.warn
    elseif r.status == 'ok'            then col = SUI.col.ok end
    SUI.wrap(ctx, col, r.msg)
  end

  -- The live list. On the matcher row, picking from it writes the model back
  -- into the field, so "model not found" is one click from fixed. On the
  -- ElevenLabs row there is nothing to write to — the STT model is fixed —
  -- but the list is still shown, because "9 models available" with no way to
  -- see WHICH nine is a dead end. Its selection is remembered per row so
  -- browsing it does not snap back to the first entry every frame.
  if r and #r.models > 0 then
    SUI.gap(ctx, 1)
    SUI.field(ctx, 'Available', 92, 260)
    _st.probe_pick = _st.probe_pick or {}
    local cur = current
    if cur == nil or cur == '' then cur = _st.probe_pick[id] end
    if cur == nil or cur == '' then cur = r.models[1] end
    local okp, picked = _ui_combo(ctx, '##models' .. id, cur, r.models)
    if okp and picked then
      _st.probe_pick[id] = picked
      if on_pick then on_pick(picked) end
    end
    if not on_pick then
      reaper.ImGui_SameLine(ctx, 0, 8)
      SUI.ftext(ctx, SUI.col.faint, 'reference only')
    end
  end
end

local function ui_detection_card(ctx)
  SUI.eyebrow(ctx, 'Detected')
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetCursorPosX(ctx,
    math.max(120, reaper.ImGui_GetWindowWidth(ctx) - 16 - 72))
  if reaper.ImGui_SmallButton(ctx, 'Re-check') then probe_now() end
  SUI.gap(ctx, 2)

  local open = SUI.card_begin(ctx, '##c_detect', 190)
  if open then
    if CONN_MODE == 'server' then
      ui_probe_row(ctx, 'server', API_TOKEN or '', SERVER_URL or '', nil)

    elseif CONN_MODE == 'vertex' then
      -- A service account cannot be checked with a header — it needs a signed
      -- JWT exchanged for a token, which Python does at run time. So this row
      -- reports what the file IS, and says plainly that it is unverified.
      local path = (VERTEX_KEY_PATH ~= '' and VERTEX_KEY_PATH)
        or (get_script_dir() .. '/vertex_key.json')
      local body = read_file(path)
      if body then
        local proj = body:match('"project_id"%s*:%s*"([^"]+)"')
        local mail = body:match('"client_email"%s*:%s*"([^"]+)"')
        SUI.text(ctx, SUI.col.text, 'Google Vertex service account')
        SUI.text(ctx, SUI.col.faint,
          (proj and ('project ' .. proj) or 'no project_id in the file')
          .. (mail and ('  ·  ' .. mail) or ''))
        SUI.wrap(ctx, SUI.col.dim,
          'Checked at run time — a service account signs a JWT for its token, '
          .. 'which this panel cannot do.')
      else
        SUI.text(ctx, SUI.col.warn, 'No service-account JSON at ' .. path)
      end
      SUI.gap(ctx, 3)
      ui_probe_row(ctx, 'asr', ELEVENLABS_KEY or '', '', nil)

    else
      ui_probe_row(ctx, 'matcher', GEMINI_KEY or '', GEMINI_BASE_URL or '',
        function(m) GEMINI_MODEL = m; probe_mark_dirty() end,
        GEMINI_MODEL)
      SUI.gap(ctx, 3)
      reaper.ImGui_Separator(ctx)
      SUI.gap(ctx, 3)
      ui_probe_row(ctx, 'asr', ELEVENLABS_KEY or '', '', nil)
    end
  end
  SUI.card_end(ctx, open)
end


local function ui_pane_connection(ctx)
  local pw = (_ui_show_keys and 0)
    or (reaper.ImGui_InputTextFlags_Password and reaper.ImGui_InputTextFlags_Password() or 0)

  local pick = SUI.segmented(ctx, 'conn', CONN_LABELS, _st.conn_idx)
  if pick ~= _st.conn_idx then
    CONN_MODE = CONN_VALUES[pick]
    probe_mark_dirty()   -- a different mode asks a different provider
  end
  _apply_conn_mode()   -- keep API_BASE / GEMINI_BACKEND in step with the mode
  SUI.gap(ctx, 4)

  local open = SUI.card_begin(ctx, '##c_conn', 190)
  if open then
    -- Any edit here arms the debounce; probe_tick() fires the check once the
    -- typing settles, so a pasted key verifies itself without a button press.
    local rv, edited = false, false
    local function ed(changed) edited = edited or changed end
    if CONN_MODE == 'server' then
      SUI.field(ctx, 'Server URL', 108)
      rv, SERVER_URL = reaper.ImGui_InputText(ctx, '##srvurl', SERVER_URL or ''); ed(rv)
      SUI.field(ctx, 'Access token', 108)
      rv, API_TOKEN  = reaper.ImGui_InputText(ctx, '##srvtok', API_TOKEN or '', pw); ed(rv)
    else
      -- No model field here: the model is picked from the verified list on the
      -- matcher row above, so a second, always-blank-looking box only ate space.
      if CONN_MODE == 'studio' then
        SUI.field(ctx, 'Gemini key', 108)
        rv, GEMINI_KEY = reaper.ImGui_InputText(ctx, '##gkey', GEMINI_KEY or '', pw); ed(rv)
      elseif CONN_MODE == 'vertex' then
        SUI.field(ctx, 'Service JSON', 108)
        rv, VERTEX_KEY_PATH = reaper.ImGui_InputText(ctx, '##vpath', VERTEX_KEY_PATH or ''); ed(rv)
      elseif CONN_MODE == 'gateway' then
        SUI.field(ctx, 'LLM URL', 108)
        rv, GEMINI_BASE_URL = reaper.ImGui_InputText(ctx, '##gwurl', GEMINI_BASE_URL or ''); ed(rv)
        SUI.field(ctx, 'LLM API key', 108)
        rv, GEMINI_KEY = reaper.ImGui_InputText(ctx, '##gwkey', GEMINI_KEY or '', pw); ed(rv)
      end

      SUI.field(ctx, 'ElevenLabs key', 108)
      rv, ELEVENLABS_KEY = reaper.ImGui_InputText(ctx, '##elkey', ELEVENLABS_KEY or '', pw); ed(rv)
    end
    if edited then probe_mark_dirty() end
    SUI.gap(ctx, 2)
    rv, _ui_show_keys = reaper.ImGui_Checkbox(ctx, 'Show keys', _ui_show_keys)
  end
  SUI.card_end(ctx, open)

  SUI.gap(ctx, 6)
  ui_detection_card(ctx)

  SUI.gap(ctx, 6)
  if CONN_MODE == 'server' then
    SUI.wrap(ctx, SUI.col.faint,
      'Every AI call goes through your server, which holds the real provider '
      .. 'keys. Nothing secret lives on this machine — just the access token '
      .. 'you were given. Best choice for people you share this with.')
  elseif CONN_MODE == 'studio' then
    SUI.wrap(ctx, SUI.col.faint,
      'Google AI Studio key — starts with "AIza". Get one at '
      .. 'aistudio.google.com/apikey.')
  elseif CONN_MODE == 'vertex' then
    if _st.has_vertex_file then
      SUI.wrap(ctx, SUI.col.ok,
        '✓  vertex_key.json found next to the script — nothing else needed here.')
    else
      SUI.wrap(ctx, SUI.col.faint,
        'Path to your Google service-account JSON — or drop a file named '
        .. 'vertex_key.json next to this script and leave this blank.')
    end
  else
    SUI.wrap(ctx, SUI.col.faint,
      'Your own OpenAI-compatible LLM. Paste the base address — the host, or '
      .. 'the host plus /v1 — not the chat page. Samanvaya adds '
      .. '/v1/chat/completions itself. Pick the model from the list the '
      .. 'endpoint returns above. Example: http://172.18.1.17:14005')
  end
  if CONN_MODE ~= 'server' then
    SUI.gap(ctx, 6)
    SUI.wrap(ctx, SUI.col.faint,
      'ElevenLabs turns the audio into text. The LLM only reads that text to '
      .. 'match lines — it never hears the audio.')
  end
end


-- Character count in glyphs rather than bytes. The script is Devanagari or
-- Bengali far more often than not, where one letter is three bytes and a raw
-- #SCRIPT_TEXT reads roughly triple what the user can see on screen.
local function _utf8_len(s)
  local n = 0
  for _ in s:gmatch('[^\128-\191]') do n = n + 1 end
  return n
end

-- A line that is nothing but a speaker heading — "Sadhguru:". The matcher
-- drops these as labels rather than speech (_SPEAKER_RE in sync_matcher.py),
-- but only when they stand alone, so reflowing must never fold one into the
-- paragraph under it. Same rule as the Python: 40 chars or fewer, ends in a
-- colon, no sentence punctuation.
local function _is_speaker_line(ln)
  return ln:sub(-1) == ':' and _utf8_len(ln) <= 40 and not ln:find('[%.%?!]')
end

-- Inner width of the editor, measured after it draws. Used by the reflow on
-- the frame after, which is soon enough — nothing reflows on frame one.
local _script_px = 0

-- What the buffer in the box was last reflowed against. The soft wrap is
-- automatic — there is no Wrap button — so these two are what tells the next
-- frame whether the text on screen still matches the box it sits in: the
-- width changed (the window was resized) or the length changed (something was
-- typed or pasted straight in).
local _script_wrap_px  = 0
local _script_wrap_len = -1

-- ImGui's InputTextMultiline has no soft wrap: a long line runs off to the
-- right and you scroll to read it. So wrap the buffer itself, the way
-- Notepad's Word Wrap would, measuring real glyph widths rather than
-- counting characters — Devanagari and Latin are nowhere near the same width.
--
-- Safe to do because the matcher joins the lines inside a paragraph back
-- together with spaces before it reads them. Blank lines are the one piece
-- of layout it does read, so those survive verbatim.
local function _script_rewrap(ctx, s, px)
  if not s or s == '' or not px or px < 80 then return s end

  -- Measure in the face the editor actually renders with. Called from the
  -- toolbar, where that font is not on the stack — measuring Devanagari with
  -- the default Latin UI font would wrap to the wrong width every time.
  local pushed = false
  if _ui_font then pushed = pcall(reaper.ImGui_PushFont, ctx, _ui_font, 13) end

  local out = {}
  for para in (s .. '\n\n'):gmatch('(.-)\n%s*\n') do
    -- Collapse the paragraph back to its logical blocks first, so a reflow
    -- of already-wrapped text re-wraps cleanly instead of compounding.
    local blocks, buf = {}, {}
    for raw in (para .. '\n'):gmatch('(.-)\n') do
      -- A fresh local, not the loop variable: Lua 5.4 makes for-loop control
      -- variables const, so assigning back into it refuses to compile.
      local ln = raw:match('^%s*(.-)%s*$')
      if ln ~= '' then
        if _is_speaker_line(ln) then
          if #buf > 0 then blocks[#blocks + 1] = table.concat(buf, ' '); buf = {} end
          blocks[#blocks + 1] = ln
        else
          buf[#buf + 1] = ln
        end
      end
    end
    if #buf > 0 then blocks[#blocks + 1] = table.concat(buf, ' ') end

    for _, b in ipairs(blocks) do
      local line
      for word in b:gmatch('%S+') do
        local try = line and (line .. ' ' .. word) or word
        local okw, w = pcall(reaper.ImGui_CalcTextSize, ctx, try)
        if line and okw and type(w) == 'number' and w > px then
          out[#out + 1] = line
          line = word          -- a word wider than the box gets its own line
        else
          line = try
        end
      end
      if line then out[#out + 1] = line end
    end
    if #blocks > 0 then out[#out + 1] = '' end
  end

  if pushed then pcall(reaper.ImGui_PopFont, ctx) end

  -- Drop the blank line the last paragraph added.
  while #out > 0 and out[#out] == '' do out[#out] = nil end
  return table.concat(out, '\n')
end

local function ui_pane_script(ctx)
  local has = (SCRIPT_TEXT or '') ~= ''

  -- Toolbar. The counts sit left as a live read-out of what is in the box;
  -- the actions sit right, where a toolbar's verbs belong.
  if has then
    -- No line count: once the box reflows, the number of lines says more
    -- about how wide the window is than about the script.
    local paras = 1
    for _ in SCRIPT_TEXT:gmatch('\n%s*\n') do paras = paras + 1 end
    SUI.ftext(ctx, SUI.col.dim, string.format(
      '%d paragraph%s  ·  %d characters',
      paras, paras == 1 and '' or 's', _utf8_len(SCRIPT_TEXT)))
  else
    SUI.ftext(ctx, SUI.col.faint, 'Nothing pasted yet — optional, but it helps')
  end

  -- Right-aligned against the pane, so the buttons hold their place whether
  -- the read-out on the left says "Nothing pasted yet" or a row of counts.
  local btnw, gap = 68, 6
  local nbtn = has and 3 or 2
  local row  = btnw * nbtn + gap * (nbtn - 1)
  -- Where the read-out on the left actually ends, in window coords, so the
  -- two never collide on a narrow window — a fixed 120px floor used to let
  -- them run together.
  local lx = 120
  local oki, ix = pcall(reaper.ImGui_GetItemRectMax, ctx)
  local okw, wx = pcall(reaper.ImGui_GetWindowPos, ctx)
  if oki and okw and type(ix) == 'number' and type(wx) == 'number' then
    lx = ix - wx
  end
  reaper.ImGui_SameLine(ctx)
  local rx = reaper.ImGui_GetCursorPosX(ctx)
  reaper.ImGui_SetCursorPosX(ctx, math.max(lx + gap,
    rx + reaper.ImGui_GetContentRegionAvail(ctx) - row))

  if SUI.cta(ctx, 'Paste##scr', btnw, 26, 'ghost') then
    local okc, clip = pcall(reaper.ImGui_GetClipboardText, ctx)
    if okc and type(clip) == 'string' and clip ~= '' then
      SCRIPT_TEXT = _script_rewrap(ctx, clip, _script_px)
    else
      ui_set_banner('warn', 'Nothing on the clipboard to paste.')
    end
  end
  reaper.ImGui_SameLine(ctx, 0, gap)

  if SUI.cta(ctx, 'Load…##scr', btnw, 26, 'ghost') then
    local okf, path = reaper.GetUserFileNameForRead('', 'Open dub script', '.txt')
    if okf and path and path ~= '' then
      local fh = io.open(path, 'rb')
      if fh then
        local body = fh:read('*a'); fh:close()
        -- Strip a UTF-8 BOM and normalise CRLF, or every line ends in a
        -- stray \r that the matcher would carry into its prompts.
        body = (body or ''):gsub('^\239\187\191', ''):gsub('\r\n', '\n')
        SCRIPT_TEXT = _script_rewrap(ctx, body, _script_px)
        ui_set_banner('info', string.format('Loaded %d characters from %s',
          _utf8_len(body), path:match('[^/\\]+$') or path))
      else
        ui_set_banner('error', 'Could not read ' .. path)
      end
    end
  end

  if has then
    reaper.ImGui_SameLine(ctx, 0, gap)
    if SUI.cta(ctx, 'Clear##scr', btnw, 26, 'ghost') then SCRIPT_TEXT = '' end
  end
  SUI.gap(ctx, 4)

  -- Re-read: a Paste or Load this frame has already filled the box, and the
  -- placeholder below must not draw over what it just put there.
  has = (SCRIPT_TEXT or '') ~= ''

  -- The editor. Darker than the pane so it reads as a well you type into
  -- rather than another card, and padded like a document rather than a form
  -- field. The Indic font goes on here too — the script is in the dub
  -- language, so without it the box renders boxes.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        0x10131AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x10131AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),  0x10131AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),         SUI.col.line)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 12.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 12.0, 10.0)
  -- 13, not the log's 16: Devanagari and Bengali carry tall ascenders and
  -- descenders, so an Indic face at a Latin face's size sets far looser than
  -- it looks on paper and a pasted script fills the box in a few lines.
  if _ui_font then pcall(reaper.ImGui_PushFont, ctx, _ui_font, 13) end

  -- InputTextMultiline paints its own scrollbar inside the frame, and it
  -- takes no window flags — so it is starved of width the same way the
  -- results table is. The box still scrolls on the wheel and follows the caret.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarSize(), 0.0)
  local rv
  rv, SCRIPT_TEXT = reaper.ImGui_InputTextMultiline(ctx, '##script',
    SCRIPT_TEXT or '', -1, -46)
  reaper.ImGui_PopStyleVar(ctx)

  -- Inner width, for the reflow below. 24 is the frame padding either side;
  -- the 8 is breathing room so the last glyph on a line is not flush against
  -- the edge — there is no scrollbar in there to reserve for any more.
  local okz, zw = pcall(reaper.ImGui_GetItemRectSize, ctx)
  if okz and type(zw) == 'number' then _script_px = math.max(0, zw - 24 - 8) end

  -- Soft wrap, kept true without a button to press. Reflow when the box has
  -- changed width (the window was resized) or when the buffer has changed
  -- length (Ctrl+V, or typing) — and never while the caret is in the box,
  -- because rewriting the buffer under an active InputText throws the caret
  -- back to the start. So an edit settles onto the new wrap on blur.
  if has and _script_px >= 80 and not reaper.ImGui_IsItemActive(ctx)
     and (math.abs(_script_px - _script_wrap_px) > 2
          or #SCRIPT_TEXT ~= _script_wrap_len) then
    SCRIPT_TEXT      = _script_rewrap(ctx, SCRIPT_TEXT, _script_px)
    _script_wrap_px  = _script_px
    _script_wrap_len = #SCRIPT_TEXT
  end

  -- Placeholder. InputTextMultiline has no hint of its own, so it is drawn
  -- over the empty box — inside the same padding the real text would use.
  if not has and reaper.ImGui_GetItemRectMin and reaper.ImGui_DrawList_AddText then
    local okr, bx, by = pcall(reaper.ImGui_GetItemRectMin, ctx)
    if okr and type(bx) == 'number' then
      pcall(reaper.ImGui_DrawList_AddText, reaper.ImGui_GetWindowDrawList(ctx),
        bx + 12, by + 10, SUI.col.gutter,
        'Paste the dub script here…')
    end
  end

  if _ui_font then pcall(reaper.ImGui_PopFont, ctx) end
  reaper.ImGui_PopStyleVar(ctx, 2)
  reaper.ImGui_PopStyleColor(ctx, 4)

  SUI.gap(ctx, 2)
  SUI.wrap(ctx, SUI.col.faint,
    'A blank line marks a topic change — the matcher pivots through those '
    .. 'groups to place lines it is unsure about.')
end


local function ui_pane_run(ctx)
  SUI.phase_strip(ctx)
  SUI.gap(ctx, 8)

  if _st.running then
    local elapsed = os.time() - _poll_start_time
    SUI.text(ctx, SUI.col.dub, _spinner_glyph() .. '   Running')
    reaper.ImGui_SameLine(ctx, 0, 14)
    local clock = SUI.mmss(elapsed) .. ' elapsed'
    if _ui_progress > 0.05 and _ui_progress < 0.99 then
      clock = clock .. '   ·   about '
        .. SUI.mmss(elapsed * (1.0 - _ui_progress) / _ui_progress) .. ' left'
    end
    SUI.text(ctx, SUI.col.dim, clock)
    SUI.gap(ctx, 2)
    SUI.bar(ctx, _ui_progress, -52, 8)
    reaper.ImGui_SameLine(ctx, 0, 10)
    SUI.text(ctx, SUI.col.dim, string.format('%.0f%%', _ui_progress * 100))
  elseif _ui_phase == 'success' then
    SUI.text(ctx, SUI.col.ok, _ui_result or 'Run complete.')
  elseif _ui_phase == 'failure' then
    SUI.text(ctx, SUI.col.err, _ui_cancelled and 'Cancelled. The timeline was not touched.'
                                             or 'The run stopped. The log below says why.')
  elseif _st.can_start and _st.tracks_ok then
    SUI.text(ctx, SUI.col.dim, string.format(
      'Ready: %d VO clips, %d dub clips. Press Start sync.', _st.en, _st.dub))
  else
    SUI.text(ctx, SUI.col.warn, 'Not ready yet. Needs: '
      .. (#_st.missing > 0 and table.concat(_st.missing, ', ') or 'items on the tracks'))
  end
  SUI.text(ctx, SUI.col.faint, _st.footnote)
  SUI.gap(ctx, 8)

  -- The timeline, lit up as far as transcription has got.
  local open = SUI.card_begin(ctx, '##c_lanes', 160)
  if open then
    SUI.eyebrow(ctx, 'Timeline')
    SUI.gap(ctx, 3)
    local lit = nil
    if _st.running and _ui_step_idx <= 2 then
      lit = { _ui_en_done, _ui_dub_done, nil }
    end
    SUI.timeline(ctx, 92, lit)

    if _st.running and _ui_step_idx == 2 then
      SUI.gap(ctx, 6)
      local function meter(label, n, total)
        if total <= 0 then return end
        SUI.text(ctx, SUI.col.dim, label)
        reaper.ImGui_SameLine(ctx, 170)
        SUI.bar(ctx, n / total, 170, 6)
        reaper.ImGui_SameLine(ctx, 0, 10)
        SUI.text(ctx, SUI.col.faint, string.format('%d / %d', n, total))
      end
      meter('VO clips transcribed',  _ui_en_done,  _ui_en_total)
      meter('Dub clips transcribed', _ui_dub_done, _ui_dub_total)
      if     _poll_step_phase == 3 then
        SUI.text(ctx, SUI.col.dub, 'Waiting for the LLM to match the lines…')
      elseif _poll_step_phase == 4 then
        SUI.text(ctx, SUI.col.dub, 'Placing clips on the timeline…')
      end
      -- Slow and hung look identical without this. Every Python phase
      -- reports on a timer, so a long silence is a genuine stall.
      local quiet = os.time() - _poll_last_change
      if quiet >= 60 then
        SUI.text(ctx, quiet >= 240 and SUI.col.err or SUI.col.warn,
          string.format('No output for %s%s', SUI.mmss(quiet),
            quiet >= 240 and '  —  may be stalled' or ''))
      end
    end
  end
  SUI.card_end(ctx, open)
end


-- ─── The worker log, as a drawer ──────────────────────────
-- A log you can only scroll is a wall. The one thing you actually want out
-- of a three-minute run is the clip that went wrong, so the open drawer
-- carries a level filter, a text filter and a time gutter — and nothing else.
local function ui_log_body(ctx)
  if #_log_buffer == 0 then
    SUI.text(ctx, SUI.col.faint,
      'Every line the Python worker prints lands here as it happens.')
    if _ui_font_note then SUI.text(ctx, SUI.col.faint, _ui_font_note) end
    return
  end

  local nerr, nwarn = 0, 0
  for i = 1, #_log_buffer do
    if     SUI.log_is_err(_log_buffer[i])  then nerr  = nerr  + 1
    elseif SUI.log_is_warn(_log_buffer[i]) then nwarn = nwarn + 1 end
  end

  -- Level chips. A chip that would filter to nothing still shows its zero —
  -- "Errors 0" is the answer to a question you were about to ask.
  local function chip(label, n, key, tone)
    local on  = (_ui_log_level == key)
    local bg  = on and tone or SUI.col.cardhi
    local fg  = on and 0x0E1219FF or (n > 0 and SUI.col.dim or SUI.col.faint)
    if SUI.pill(ctx, string.format('%s %d##lvl' .. key, label, n), bg, fg) then
      _ui_log_level = on and 'all' or key
    end
  end

  chip('All', #_log_buffer, 'all', SUI.col.accent)
  reaper.ImGui_SameLine(ctx, 0, 6)
  chip('Errors', nerr, 'err', SUI.col.err)
  reaper.ImGui_SameLine(ctx, 0, 6)
  chip('Warnings', nwarn, 'warn', SUI.col.warn)

  -- Filter box and Follow, right-aligned against the pane's own width — from
  -- GetContentRegionAvail after a SameLine they would measure the space left
  -- of the cursor, not the pane, and both would drift as the chips changed.
  local fw, foll = 150, 76
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetCursorPosX(ctx,
    math.max(150, reaper.ImGui_GetWindowWidth(ctx) - 16 - fw - 10 - foll))
  reaper.ImGui_SetNextItemWidth(ctx, fw)
  local rv
  rv, _ui_log_filter = reaper.ImGui_InputText(ctx, '##logfilter', _ui_log_filter or '')
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Filter by text — a clip number, a phase, "gemini"')
  end
  reaper.ImGui_SameLine(ctx, 0, 10)
  rv, _log_autoscroll = reaper.ImGui_Checkbox(ctx, 'Follow', _log_autoscroll)
  SUI.gap(ctx, 2)

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 12.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 12.0, 10.0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x10131AFF)
  if reaper.ImGui_BeginChild(ctx, '##loglines', -1, -30, 0, SUI.NOSB) then
    -- 12px, not the 15 this used to run at: log lines are long and the big
    -- face wrapped every second one, which read as noise rather than a log.
    if _ui_font then pcall(reaper.ImGui_PushFont, ctx, _ui_font, 12) end
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 0.0, 3.0)

    local needle = (_ui_log_filter or ''):lower()
    local shown  = 0
    -- Newest 400 MATCHES, so a filter reaches back past the tail: walk from
    -- the end, collect, then draw in order.
    local pick = {}
    for i = #_log_buffer, 1, -1 do
      local ln = _log_buffer[i]
      local lvl_ok = (_ui_log_level == 'all')
        or (_ui_log_level == 'err'  and SUI.log_is_err(ln))
        or (_ui_log_level == 'warn' and SUI.log_is_warn(ln))
      if lvl_ok and (needle == '' or ln:lower():find(needle, 1, true)) then
        pick[#pick + 1] = i
        if #pick >= 400 then break end
      end
    end
    for k = #pick, 1, -1 do
      local i  = pick[k]
      local at = _log_stamp[i]
      SUI.text(ctx, SUI.col.gutter, at and SUI.mmss(at) or '  ·  ')
      reaper.ImGui_SameLine(ctx, 46)
      SUI.text(ctx, SUI.log_colour(_log_buffer[i]), _log_buffer[i])
      shown = shown + 1
    end
    if shown == 0 then
      SUI.text(ctx, SUI.col.faint, 'No line matches that filter.')
    end

    reaper.ImGui_PopStyleVar(ctx)
    if _ui_font then pcall(reaper.ImGui_PopFont, ctx) end
    -- Following a filtered view would pin you to the last match, which is
    -- rarely where you were reading — so it only follows the live tail.
    if _log_autoscroll and _st.running
       and _ui_log_level == 'all' and needle == '' then
      reaper.ImGui_SetScrollHereY(ctx, 1.0)
    end
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleVar(ctx, 2)

  if reaper.ImGui_SmallButton(ctx, 'Open log file') then
    if _poll_log_path then open_path(_poll_log_path) end
  end
  reaper.ImGui_SameLine(ctx)
  if _ui_font then pcall(reaper.ImGui_PushFont, ctx, _ui_font, 12) end
  SUI.text(ctx, SUI.col.faint,
    (_poll_log_path or '') .. (_ui_font_note and ('   ·   ' .. _ui_font_note) or ''))
  if _ui_font then pcall(reaper.ImGui_PopFont, ctx) end
end


-- The drawer itself: a one-line header that always shows the newest line,
-- and the full filterable log underneath when it is open.
local function ui_log_drawer(ctx)
  local open = SUI.pane(ctx, '##drawer', -1, 0, SUI.col.rail, 16.0, 9.0, 14.0)
  if open then
    local okp, x0, y0 = pcall(reaper.ImGui_GetCursorScreenPos, ctx)
    local ww = reaper.ImGui_GetWindowWidth(ctx)
    local BW = 74

    if reaper.ImGui_AlignTextToFramePadding then
      pcall(reaper.ImGui_AlignTextToFramePadding, ctx)
    end
    SUI.eyebrow(ctx, 'Log')
    reaper.ImGui_SameLine(ctx, 0, 14)
    local okc, lx = pcall(reaper.ImGui_GetCursorScreenPos, ctx)

    -- Newest line, clipped to the room left of the button.
    local last = _log_buffer[#_log_buffer]
    if okc and type(lx) == 'number' and okp and type(x0) == 'number' then
      local dl = reaper.ImGui_GetWindowDrawList(ctx)
      local wx = reaper.ImGui_GetWindowPos(ctx)
      local right = wx + ww - 16 - BW - 12
      local okt, _, th = pcall(reaper.ImGui_CalcTextSize, ctx, 'Ag')
      th = (okt and type(th) == 'number') and th or 14
      pcall(reaper.ImGui_DrawList_PushClipRect, dl, lx, y0, right, y0 + 26, true)
      pcall(reaper.ImGui_DrawList_AddText, dl, lx, y0 + (26 - th) * 0.5,
        last and SUI.log_colour(last) or SUI.col.faint,
        last and (last:gsub('^%s+', '')) or 'Nothing logged yet.')
      pcall(reaper.ImGui_DrawList_PopClipRect, dl)
    end

    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetCursorPosX(ctx, math.max(120, ww - 16 - BW))
    reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) - 1)
    if SUI.cta(ctx, (SUI.drawer_open and 'Close' or 'Open') .. '##drawer', BW, 26, 'ghost') then
      SUI.drawer_open = not SUI.drawer_open
    end

    if SUI.drawer_open then
      SUI.gap(ctx, 4)
      ui_log_body(ctx)
    end
  end
  SUI.pane_end(ctx, open)
end


local function ui_pane_results(ctx)
  if _ui_phase == 'failure' then
    SUI.big(ctx, SUI.col.err, _ui_cancelled and '■  Cancelled' or '✗  Sync failed', 18)
    SUI.gap(ctx, 4)
    if _ui_failure then
      SUI.eyebrow(ctx, 'Last output')
      SUI.gap(ctx, 2)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 12.0)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 12.0, 10.0)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x1A1114FF)
      if reaper.ImGui_BeginChild(ctx, '##errtail', -1, -128, 0, SUI.NOSB) then
        if _ui_font then pcall(reaper.ImGui_PushFont, ctx, _ui_font, 13) end
        SUI.wrap(ctx, 0xFFB8BCFF, _ui_failure.error_tail or '(no output)')
        if _ui_font then pcall(reaper.ImGui_PopFont, ctx) end
        reaper.ImGui_EndChild(ctx)
      end
      reaper.ImGui_PopStyleColor(ctx)
      reaper.ImGui_PopStyleVar(ctx, 2)

      SUI.gap(ctx, 6)
      SUI.eyebrow(ctx, 'Usual culprits')
      SUI.gap(ctx, 2)
      SUI.text(ctx, SUI.col.dim, '·  A key or URL is wrong — check Connection.')
      SUI.text(ctx, SUI.col.dim, '·  The venv is stale — re-run setup.bat / setup.sh.')
      SUI.text(ctx, SUI.col.dim, '·  Direct mode needs its extras — setup.bat --direct.')
    end
    return
  end

  if _ui_phase ~= 'success' then
    SUI.empty(ctx, 'Nothing to show yet',
      'When a run finishes, the counts and the per-clip breakdown land here — '
      .. 'including which clips could not be placed and where they went.')
    return
  end

  -- Counts straight from the per-clip rows, so the tiles always agree with
  -- the table under them even when the summary file is missing.
  local matched, unmatched, failed = 0, 0, 0
  for _, r in ipairs(_ui_results_rows) do
    if     r.status == 'matched'   then matched   = matched + 1
    elseif r.status == 'unmatched' then unmatched = unmatched + 1
    else                                failed    = failed + 1 end
  end
  local total = matched + unmatched + failed
  if total == 0 then
    matched, unmatched = _ui_moved, _ui_unmatched
    total = _ui_moved + _ui_unmatched
  end

  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  local tw = math.floor((avail - 27) / 4)
  SUI.stat(ctx, '##s1', tostring(matched), 'placed', SUI.col.ok, tw)
  reaper.ImGui_SameLine(ctx, 0, 9)
  SUI.stat(ctx, '##s2', tostring(unmatched), 'unmatched',
    unmatched > 0 and SUI.col.warn or SUI.col.dim, tw)
  reaper.ImGui_SameLine(ctx, 0, 9)
  SUI.stat(ctx, '##s3', tostring(total), 'dub clips', SUI.col.text, tw)
  reaper.ImGui_SameLine(ctx, 0, 9)
  SUI.stat(ctx, '##s4', SUI.mmss(_ui_run_secs), 'run time', SUI.col.text, tw)
  SUI.gap(ctx, 6)

  if unmatched > 0 then
    SUI.wrap(ctx, SUI.col.warn, string.format(
      '%d clip%s could not be placed and %s waiting on the "%s" track. Click '
      .. 'a row to select it, then select the VO item it belongs to and run '
      .. 'Sync_Item.lua.',
      unmatched, unmatched == 1 and '' or 's',
      unmatched == 1 and 'is' or 'are', TRACK_UNSYNC))
  else
    SUI.wrap(ctx, SUI.col.ok, 'Every dub clip found a home. Nothing was left on the "'
      .. TRACK_UNSYNC .. '" track.')
  end
  if _ui_summary then
    SUI.gap(ctx, 2)
    SUI.text(ctx, SUI.col.faint, string.format(
      'VO clips analysed %s   ·   %s   ·   %s   ·   %s',
      tostring(_ui_summary.total_en), tostring(_ui_summary.model),
      lang_name(_ui_summary.language), tostring(_ui_summary.backend)))
  end
  SUI.gap(ctx, 6)

  if #_ui_results_rows > 0 then
    if reaper.ImGui_AlignTextToFramePadding then
      pcall(reaper.ImGui_AlignTextToFramePadding, ctx)
    end
    SUI.eyebrow(ctx, 'Per clip')
    -- Right-align the filter box against the pane's own width. Deriving it
    -- from GetContentRegionAvail after a SameLine would measure the space
    -- left of the cursor, not the pane, and the box would drift.
    reaper.ImGui_SameLine(ctx)
    local fw = 170
    local ww = reaper.ImGui_GetWindowWidth(ctx)
    reaper.ImGui_SetCursorPosX(ctx, math.max(120, ww - 16 - fw))
    reaper.ImGui_SetNextItemWidth(ctx, fw)
    local rv
    rv, _ui_row_filter = reaper.ImGui_InputText(ctx, '##rowfilter', _ui_row_filter or '')
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, 'Filter by clip number or status (e.g. "parked")')
    end
    SUI.gap(ctx, 2)

    local tf = 0
    if reaper.ImGui_TableFlags_RowBg          then tf = tf | reaper.ImGui_TableFlags_RowBg()          end
    if reaper.ImGui_TableFlags_ScrollY        then tf = tf | reaper.ImGui_TableFlags_ScrollY()        end
    if reaper.ImGui_TableFlags_Resizable      then tf = tf | reaper.ImGui_TableFlags_Resizable()      end
    if reaper.ImGui_TableFlags_BordersInnerV  then tf = tf | reaper.ImGui_TableFlags_BordersInnerV()  end
    -- ImGui's default cell padding is 4x2: the clip numbers sat on the column
    -- borders and the rows read as one block. Guarded — older ReaImGui builds
    -- have no CellPadding var, and an unguarded push/pop would not pair.
    local padded = (reaper.ImGui_StyleVar_CellPadding ~= nil)
    if padded then
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding(), 10.0, 5.0)
    end
    -- BeginTable takes no NoScrollbar, so the inner window's bar is starved
    -- of width instead. Same result: wheel scrolling, nothing drawn.
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarSize(), 0.0)
    if reaper.ImGui_BeginTable(ctx, '##results', 5, tf, 0, -1) then
      reaper.ImGui_TableSetupColumn(ctx, 'Clip')
      reaper.ImGui_TableSetupColumn(ctx, 'Status')
      reaper.ImGui_TableSetupColumn(ctx, 'Was at')
      reaper.ImGui_TableSetupColumn(ctx, 'Now at')
      reaper.ImGui_TableSetupColumn(ctx, 'Moved')
      reaper.ImGui_TableHeadersRow(ctx)
      local span = reaper.ImGui_SelectableFlags_SpanAllColumns
                   and reaper.ImGui_SelectableFlags_SpanAllColumns() or 0
      local function t(x) return x and SUI.mmss(x) .. string.format('.%d', math.floor((x % 1) * 10)) or '—' end
      local needle = (_ui_row_filter or ''):lower()
      for _, r in ipairs(_ui_results_rows) do
        local word = (r.status == 'matched') and 'placed'
          or (r.status == 'missing_file' and 'no audio' or 'parked')
        local hay = tostring(r.dub_id or '') .. ' ' .. tostring(r.status or '') .. ' ' .. word
        if needle == '' or hay:lower():find(needle, 1, true) then
          reaper.ImGui_TableNextRow(ctx)
          reaper.ImGui_TableSetColumnIndex(ctx, 0)
          -- The whole row is a button: it selects that item in REAPER and
          -- puts the edit cursor on it, so "which one was parked" is one click.
          if reaper.ImGui_Selectable(ctx, string.format('#%d##row%d', r.dub_id or 0, r.dub_id or 0),
                                     false, span) then
            if r.item and reaper.ValidatePtr2 and reaper.ValidatePtr2(0, r.item, 'MediaItem*') then
              reaper.Main_OnCommand(40289, 0)          -- unselect all items
              reaper.SetMediaItemSelected(r.item, true)
              reaper.SetEditCurPos(reaper.GetMediaItemInfo_Value(r.item, 'D_POSITION'), true, false)
              reaper.UpdateArrange()
            end
          end
          reaper.ImGui_TableSetColumnIndex(ctx, 1)
          local col = SUI.col.ok
          if     r.status == 'unmatched'    then col = SUI.col.warn
          elseif r.status == 'missing_file' then col = SUI.col.err end
          SUI.text(ctx, col, word)
          reaper.ImGui_TableSetColumnIndex(ctx, 2)
          SUI.text(ctx, SUI.col.faint, t(r.old_position))
          reaper.ImGui_TableSetColumnIndex(ctx, 3)
          SUI.text(ctx, SUI.col.text, t(r.new_position))
          reaper.ImGui_TableSetColumnIndex(ctx, 4)
          if r.old_position and r.new_position then
            local d = r.new_position - r.old_position
            SUI.text(ctx, SUI.col.dim, string.format('%+.1f s', d))
          else
            SUI.text(ctx, SUI.col.faint, '—')
          end
        end
      end
      reaper.ImGui_EndTable(ctx)
    end
    reaper.ImGui_PopStyleVar(ctx)
    if padded then reaper.ImGui_PopStyleVar(ctx) end
  end
end


-- ─── The detail pane: header, then whichever section is selected ──
local function ui_detail(ctx, h)
  if _ui_nav == 'log' then SUI.drawer_open = true; _ui_nav = 'run' end
  local open = SUI.pane(ctx, '##detail', -1, h, 0x00000000, 18.0, 14.0)
  if open then
    -- Studio drops the little gradient rule that used to sit above the
    -- title: the rail's node and the primary button already carry the
    -- ramp, and a third instance three lines apart was one too many. The
    -- title carries the hierarchy on its own at this size.
    local head = PANE_HEAD[_ui_nav] or PANE_HEAD.session
    SUI.big(ctx, SUI.col.white, head[1], 23)
    SUI.gap(ctx, 1)
    SUI.text(ctx, SUI.col.dim, head[2])
    SUI.gap(ctx, 7)
    _ui_render_banner(ctx)

    if _ui_setup_card then
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 14.0)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 12.0, 9.0)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x2A2418FF)
      local cpad, wpad = _child_pad_flag()
      local cflags, chh = cpad, 82
      if reaper.ImGui_ChildFlags_AutoResizeY then
        cflags, chh = cflags | reaper.ImGui_ChildFlags_AutoResizeY(), 0
      end
      if reaper.ImGui_BeginChild(ctx, '##setupcard', -1, chh, cflags, SUI.NOSB | wpad) then
        SUI.wrap(ctx, SUI.col.warn, _ui_setup_card)
        reaper.ImGui_EndChild(ctx)
      end
      reaper.ImGui_PopStyleColor(ctx)
      reaper.ImGui_PopStyleVar(ctx, 2)
      SUI.gap(ctx, 1)
      if reaper.ImGui_SmallButton(ctx, 'Dismiss##card') then _ui_setup_card = nil end
      SUI.gap(ctx, 6)
    end

    if     _ui_nav == 'session'    then ui_pane_session(ctx)
    elseif _ui_nav == 'connection' then ui_pane_connection(ctx)
    elseif _ui_nav == 'script'     then ui_pane_script(ctx)
    elseif _ui_nav == 'run'        then ui_pane_run(ctx)
    elseif _ui_nav == 'results'    then ui_pane_results(ctx)
    end
  end
  SUI.pane_end(ctx, open)
end


-- ═══════════════════════════════════════════════════════════
-- LIVE LOG TAIL + RESULT HANDLING
-- ═══════════════════════════════════════════════════════════

local function on_python_done(success)
  if not success then return end

  _ui_step_idx     = 3
  _poll_step_phase = 4
  _ui_progress     = 0.92
  _ui_step_label   = "Applying to timeline..."
  log("\n[STEP 3] Applying results to timeline...")

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local moved, unmatched = apply_results(_poll_results_path, _poll_dub_items)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Samanvaya — sync dub to VO", -1)

  _ui_progress = 1.0

  -- Feed the results screen. It reads the structured values for its stat
  -- tiles and keeps `_ui_result` only as the plain-text fallback for a run
  -- whose summary file never appeared.
  local s = read_summary(_poll_results_path)
  local elapsed = os.time() - _poll_start_time
  _ui_run_secs  = elapsed
  _ui_summary   = s
  _ui_moved     = moved
  _ui_unmatched = unmatched

  local msg
  if s then
    msg = string.format(
      "Matched %s of %s dub clips in %ds (%s / %s).",
      s.matched, s.total_dub, elapsed, s.model, lang_name(s.language))
  else
    msg = string.format("Moved %d clips, %d unmatched, in %ds.",
                        moved, unmatched, elapsed)
  end

  _ui_result = msg
  _ui_phase  = "success"
end

-- Poll the log/done files. Driven by the ImGui frame loop (NOT reaper.defer)
-- so log appends + spinner stay in sync with rendering. Updates UI state and
-- flips _ui_phase to success/failure when the run ends.
local function poll_python_step()
  -- Read new log content → console + UI buffer, and advance progress.
  local f = io.open(_poll_log_path, "r")
  if f then
    local content = f:read("*a")
    f:close()
    if content and #content > _poll_last_size then
      local new_text = content:sub(_poll_last_size + 1)
      for line in new_text:gmatch("([^\n]*)\n?") do
        if line and line ~= "" then
          log_append("  " .. line)
          if line:find("STEP 1", 1, true) then
            _ui_step_idx = math.max(_ui_step_idx, 1); _poll_step_phase = 1
            _ui_progress = math.max(_ui_progress, 0.08)
          end
          if line:find("STEP 2", 1, true) then
            _ui_step_idx = math.max(_ui_step_idx, 2); _poll_step_phase = 2
            _ui_progress = math.max(_ui_progress, 0.40)
          end
          if line:find("STEP 3", 1, true) then
            _poll_step_phase = 3; _ui_progress = math.max(_ui_progress, 0.75)
          end
          if line:find("STEP 4", 1, true) then
            _poll_step_phase = 4; _ui_progress = math.max(_ui_progress, 0.88)
          end
          if line:match("%[%s*%d+%]%s+\"") then
            if _poll_step_phase == 1 then
              _ui_en_done = _ui_en_done + 1
              if _ui_en_total > 0 then
                _ui_progress = math.max(_ui_progress,
                  0.08 + (_ui_en_done / _ui_en_total) * 0.32)
              end
            elseif _poll_step_phase == 2 then
              _ui_dub_done = _ui_dub_done + 1
              if _ui_dub_total > 0 then
                _ui_progress = math.max(_ui_progress,
                  0.40 + (_ui_dub_done / _ui_dub_total) * 0.35)
              end
            end
          end
        end
      end
      _poll_last_size   = #content
      _poll_last_change = os.time()
    end
  end

  -- Done? (done file present with exit code)
  local df = io.open(_poll_done_path, "r")
  if df then
    local exit_code_str = df:read("*a")
    df:close()
    if exit_code_str and exit_code_str:match("%d") then
      local exit_code = tonumber(exit_code_str:match("(%d+)"))
      local f2 = io.open(_poll_log_path, "r")
      if f2 then
        local final = f2:read("*a")
        f2:close()
        if final and #final > _poll_last_size then
          for line in final:sub(_poll_last_size + 1):gmatch("([^\n]*)\n?") do
            if line and line ~= "" then
              log_append("  " .. line)
            end
          end
        end
      end

      local elapsed = os.time() - _poll_start_time
      log(string.format("\n──── Python finished in %ds (exit code %d) ────",
        elapsed, exit_code or -1))
      os.remove(_poll_done_path)

      if (exit_code == 0) and file_exists(_poll_results_path) then
        on_python_done(true)
      else
        local python_log = read_file(_poll_log_path) or "(no output)"
        local short_log = python_log
        if #short_log > 1200 then short_log = "...\n" .. short_log:sub(-1200) end
        if _ui_cancelled then
          _ui_failure = { error_tail = "Cancelled by user.\n\n" .. short_log,
                          log_path = _poll_log_path }
        else
          _ui_failure = { error_tail = short_log, log_path = _poll_log_path }
        end
        _ui_phase = "failure"
      end
      return
    end
  end

  -- Watchdog: run_sync.py writes its "[run_sync] launching:" line within a
  -- couple of seconds of a successful start. If the log is still empty after
  -- 90 s, the launch failed in a way we couldn't detect — surface it instead
  -- of spinning the spinner forever.
  if _poll_last_size == 0 and (os.time() - _poll_start_time) > 90 then
    log("\nERROR: no output from Python after 90 s — launch likely failed.")
    _ui_failure = {
      error_tail = "Python produced no output for 90 seconds — the launch " ..
                   "probably failed.\n\nThings to check:\n" ..
                   "  - the venv exists and runs — re-run setup.bat / " ..
                   "setup.sh once; it rebuilds a broken venv\n" ..
                   "    automatically\n" ..
                   "  - the interpreter path is valid",
      log_path = _poll_log_path,
    }
    _ui_phase = "failure"
    return
  end
end


-- ═══════════════════════════════════════════════════════════
-- ORCHESTRATION — validate inputs and launch the Python matcher
-- ═══════════════════════════════════════════════════════════
-- Called when the user clicks "Start Sync". Returns true if Python was
-- launched and the UI should switch to the running phase; false (with a
-- banner set) to stay on the setup form.
local function start_sync_run()
  ui_clear_banner()
  _apply_conn_mode()   -- ensure API_BASE / GEMINI_BACKEND match the chosen mode
  -- Tidy the visible field too, now that nobody is typing into it.
  GEMINI_BASE_URL = normalize_gateway_base(GEMINI_BASE_URL)
  save_settings()
  log_clear()

  -- ── Auto-detect Python ────────────────────────────────
  local py = find_python()
  if not py then
    if not ensure_setup() then return false end
    py = find_python()
    if not py then
      ui_set_banner("error",
        "Could not find a Python interpreter even after setup. " ..
        (_is_windows()
          and "Install Python 3.11+ (python.org) and re-run setup.bat."
          or  "Install Python 3.11+ and re-run setup.sh."))
      return false
    end
  end
  if _venv_broken then
    -- The venv exists but its Python no longer runs (removed/upgraded).
    -- Running on a system interpreter instead would break direct-mode
    -- installs and mask the problem — offer the rebuild now; the user
    -- clicks Start again once setup finishes.
    ensure_setup()
    return false
  end
  PYTHON_CMD = py
  log(string.format("  Python    : %s", PYTHON_CMD))

  -- ── Find tracks ───────────────────────────────────────
  local track_vo  = find_track_by_name(TRACK_VO_NAME)
  local track_dub = find_track_by_name(TRACK_DUB_NAME)
  if not track_vo then
    ui_set_banner("error", 'Track "' .. TRACK_VO_NAME ..
      '" not found. Check the name matches exactly (capital letters matter).')
    return false
  end
  if not track_dub then
    ui_set_banner("error", 'Track "' .. TRACK_DUB_NAME ..
      '" not found. Check the name matches exactly (capital letters matter).')
    return false
  end

  local vo_items  = get_items_sorted(track_vo)
  local dub_items = get_items_sorted(track_dub)
  if #vo_items == 0 then
    ui_set_banner("error", 'No items on track "' .. TRACK_VO_NAME ..
      '". Import English audio and use Dynamic Split first.')
    return false
  end
  if #dub_items == 0 then
    ui_set_banner("error", 'No items on track "' .. TRACK_DUB_NAME ..
      '". Import dubbed audio and use Dynamic Split first.')
    return false
  end

  log("\n" .. string.rep("=", 60))
  log("  AUTO SYNC PIPELINE v1.1")
  log(string.rep("=", 60))
  log(string.format("  VO items  : %d", #vo_items))
  log(string.format("  Dub items : %d", #dub_items))
  log(string.format("  Language  : %s", lang_name(DUB_LANGUAGE)))
  log(string.format("  ASR       : %s", ASR_PROVIDER))
  log(string.format("  Matcher   : Gemini (%s, model: %s)", GEMINI_BACKEND, GEMINI_MODEL))
  if API_BASE ~= "" then
    log(string.format("  Backend   : server proxy (%s)", API_BASE))
  elseif GEMINI_BACKEND == "gateway" then
    log(string.format("  Backend   : gateway (%s)",
        (GEMINI_BASE_URL ~= "" and GEMINI_BASE_URL or "NO URL SET!")))
  else
    log("  Backend   : direct (keys on this machine)")
  end
  if SCRIPT_TEXT and SCRIPT_TEXT ~= "" then
    log(string.format("  Script    : loaded (%d chars)", #SCRIPT_TEXT))
  end

  local script_dir   = get_script_dir()
  local results_path = script_dir .. "/sync_results.json"
  os.remove(results_path)

  _ui_step_idx = 1
  log("\n[STEP 1] Writing config JSON...")
  local config_path = write_config(vo_items, dub_items, results_path)
  if not config_path then
    ui_set_banner("error", "Could not write sync_config.json next to the script.")
    return false
  end
  log("  Written: " .. config_path)

  local cmd, log_path, done_path = build_python_cmd(config_path)
  if not cmd then
    ui_set_banner("error", "sync_matcher.py or run_sync.py is missing next to this script.")
    return false
  end
  os.remove(done_path)

  -- Truncate the stale log so the poller reads only this run's output.
  local lf = io.open(log_path, "w")
  if lf then lf:close() end
  -- Clear any stale PID so a Cancel can't signal a recycled, unrelated PID.
  os.remove(script_dir .. "/sync_python_pid.txt")

  local asr_info = "ASR: elevenlabs"
  do
    -- Transcription is always ElevenLabs; matching is always Gemini.
    if MATCH_MODE == "gemini" then
      asr_info = asr_info .. " (ElevenLabs + Gemini semantic match)"
    elseif GEMINI_KEY and GEMINI_KEY ~= "" then
      asr_info = asr_info .. " (ElevenLabs + Gemini translate)"
    else
      asr_info = asr_info .. " (ElevenLabs Scribe)"
    end
  end

  _ui_step_idx = 2
  log("\n[STEP 2] Launching AI matcher in background...")
  log("  Mode     : " .. MATCH_MODE)
  log("  " .. asr_info)
  log("  Language : " .. lang_name(DUB_LANGUAGE))
  log("  Log file : " .. log_path)
  log("\n──── Live Python output ────────────────────────────────")

  _poll_log_path     = log_path
  _poll_done_path    = done_path
  _poll_results_path = results_path
  _poll_dub_items    = dub_items
  _poll_last_size    = 0
  _poll_start_time   = os.time()
  _poll_last_change  = os.time()

  -- Progress tracking for the running phase.
  _ui_progress     = 0.05
  _ui_en_total     = #vo_items
  _ui_dub_total    = #dub_items
  _ui_en_done      = 0
  _ui_dub_done     = 0
  _poll_step_phase = 0
  _ui_cancelled    = false
  _ui_results_rows = {}

  -- Launch (non-blocking).
  --  Windows: ExecProcess(-2) = fire-and-forget CreateProcess (no console
  --  window). Falls back to start /b on very old REAPER builds.
  --  macOS: shell launch with trailing & (needed for the redirect syntax).
  if _is_windows() then
    if reaper.ExecProcess then
      local ret = reaper.ExecProcess(cmd, -2)
      if ret == nil then
        ui_set_banner("error",
          "Could not launch Python. Check the interpreter path " ..
          "(re-run setup.bat if the venv was deleted).")
        return false
      end
    else
      os.execute('start "" /b ' .. cmd)
    end
  else
    os.execute(cmd)
  end

  _ui_phase = "running"
  return true
end


-- ═══════════════════════════════════════════════════════════
-- MAIN — single ReaImGui frame loop drives all phases
-- ═══════════════════════════════════════════════════════════

-- ─── The dialog ───────────────────────────────────────────
-- Centred on the panel rather than the screen — a dialog centred on the
-- display while the panel sits in a corner reads as some other application's
-- — sized to its own content, and modal: while it is up the rail and the
-- action bar are inert, which is the point. The question is the only thing
-- there is to answer.
local DLG_ID = 'Samanvaya##dlg'

local function ui_render_dialog(ctx)
  local d = _ui_dialog
  if not d then return end

  if not d.shown then
    reaper.ImGui_OpenPopup(ctx, DLG_ID)
    d.shown = true
  end

  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local ww, wh = reaper.ImGui_GetWindowSize(ctx)
  reaper.ImGui_SetNextWindowPos(ctx, wx + ww * 0.5, wy + wh * 0.5,
    reaper.ImGui_Cond_Always(), 0.5, 0.5)
  -- Fixed width, automatic height. A two-line question and a five-line one
  -- should not produce two differently shaped dialogs.
  reaper.ImGui_SetNextWindowSize(ctx, 404, 0, reaper.ImGui_Cond_Always())

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 20.0, 18.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 14.0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(), SUI.col.rail)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),  SUI.col.line)

  local flags = reaper.ImGui_WindowFlags_NoTitleBar()
              | reaper.ImGui_WindowFlags_NoResize()
              | reaper.ImGui_WindowFlags_NoMove()
              | SUI.NOSB

  local run_after = nil
  local visible   = reaper.ImGui_BeginPopupModal(ctx, DLG_ID, nil, flags)
  if visible then
    SUI.big(ctx, SUI.col.white, d.title or 'Are you sure?', 16)
    if d.body then
      SUI.gap(ctx, 7)
      SUI.wrap(ctx, SUI.col.dim, d.body)
    end

    -- What the answer commits to, named one per line. A dialog that says
    -- "create the structure" and nothing else asks to be trusted; this one
    -- shows its work first.
    if d.items and #d.items > 0 then
      SUI.gap(ctx, 10)
      local open = SUI.card_begin(ctx, '##dlglist', #d.items * 19 + 24)
      if open then
        for _, s in ipairs(d.items) do
          -- A drawn dot rather than a bullet glyph, for the same reason the
          -- banner's close is a ×: the default face stops at Latin-1.
          local dx, dy = reaper.ImGui_GetCursorScreenPos(ctx)
          if type(dx) == 'number' and reaper.ImGui_GetWindowDrawList then
            pcall(reaper.ImGui_DrawList_AddCircleFilled,
                  reaper.ImGui_GetWindowDrawList(ctx),
                  dx + 3, dy + 8, 2.5, SUI.col.accent)
          end
          reaper.ImGui_Dummy(ctx, 13, 0)
          reaper.ImGui_SameLine(ctx, 0, 0)
          SUI.text(ctx, SUI.col.text, s)
        end
      end
      SUI.card_end(ctx, open)
    end

    if d.note then
      SUI.gap(ctx, 9)
      SUI.wrap(ctx, SUI.col.faint, d.note)
    end

    -- Both buttons pinned to the right, the confirm last: the eye finishes
    -- the sentence where the action is.
    SUI.gap(ctx, 15)
    local BW, BH, GAP = 106, 32, 9
    local availw = reaper.ImGui_GetContentRegionAvail(ctx)
    local cx     = reaper.ImGui_GetCursorPosX(ctx)
    if type(availw) == 'number' and type(cx) == 'number' then
      reaper.ImGui_SetCursorPosX(ctx, cx + math.max(0, availw - (BW * 2 + GAP)))
    end
    local cancel = SUI.cta(ctx, (d.cancel or 'Cancel') .. '##dlgno', BW, BH, 'ghost')
    reaper.ImGui_SameLine(ctx, 0, GAP)
    local accept = SUI.cta(ctx, (d.ok or 'OK') .. '##dlgyes', BW, BH, d.tone)

    -- Enter confirms. Escape is ImGui's own — it closes the modal, which the
    -- branch below reads as a cancel.
    if reaper.ImGui_IsKeyPressed and reaper.ImGui_Key_Enter then
      local okk, hit = pcall(reaper.ImGui_IsKeyPressed, ctx,
                             reaper.ImGui_Key_Enter(), false)
      if okk and hit then accept = true end
    end

    if accept or cancel then
      if accept then run_after = d.on_ok end
      _ui_dialog = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  else
    -- Escape, or a click on the dimmed ground: the popup is gone but the
    -- request would still be on the table, so drop that too.
    _ui_dialog = nil
  end

  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_PopStyleVar(ctx, 2)

  -- The action runs after EndPopup, never inside it: it may raise a banner
  -- or a second dialog, and neither can be opened from inside the popup it
  -- would be replacing.
  if run_after then run_after() end
end


-- One frame of the whole app: rail, detail pane, action bar. `_ui_phase`
-- says what the engine is doing; `_ui_nav` says what you are looking at, and
-- sync_nav_to_phase() is the single place the first pulls the second along.
-- The three regions sit flush, so item spacing goes to zero for the layout
-- itself and each pane restores it for its own contents.
local function render_active_phase(ctx, on_close)
  on_close = on_close or function() end
  sync_nav_to_phase()
  refresh_state()

  -- The three regions are separated by SHELL_PAD, and the window itself
  -- carries the same padding (pushed around Begin), so nothing touches the
  -- frame and each region keeps its own rounded corners.
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),
    SHELL_PAD, SHELL_PAD)
  ui_rail(ctx, start_sync_run)
  reaper.ImGui_SameLine(ctx, 0, SHELL_PAD)
  -- Right-hand column: the page, and the log drawer under it. Shut, the
  -- drawer is one line; open, it takes a little under half the column.
  reaper.ImGui_BeginGroup(ctx)
  local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  avail_h = (type(avail_h) == 'number') and avail_h or 480
  local drawer_h = SUI.drawer_open and math.max(200, math.floor(avail_h * 0.45))
                   or SUI.DRAWER_SHUT
  ui_detail(ctx, -(drawer_h + SHELL_PAD))
  ui_log_drawer(ctx)
  reaper.ImGui_EndGroup(ctx)
  reaper.ImGui_PopStyleVar(ctx)

  -- Last, and outside the three regions: a modal opened from inside one of
  -- those children would belong to it and be clipped by it.
  ui_render_dialog(ctx)
end


local function main()
  -- ReaImGui is required. Show a one-time install prompt and exit if missing.
  if not imgui_available() then
    -- If ReaPack is installed, offer to add the repo + open the browser for the
    -- user automatically (removes most of the manual steps).
    if reaper.APIExists and reaper.APIExists('ReaPack_AddSetRepository') then
      -- Yes / No / Cancel  (type 3): Yes = auto, No = manual steps, Cancel = quit.
      local choice = reaper.ShowMessageBox(
        "This script needs ReaImGui (free).\n\n" ..
        "ReaPack was detected. Install ReaImGui automatically?\n" ..
        "(This adds the repository and opens the package browser so you\n" ..
        "just click Install → Apply, then restart REAPER.)\n\n" ..
        "Yes  = do it automatically\n" ..
        "No   = show me the manual steps instead\n" ..
        "Cancel = quit",
        "ReaImGui not installed", 3)
      if choice == 6 then       -- Yes
        if try_reapack_install() then return end
        -- install flow failed (e.g. repo add rejected) → fall through to the
        -- manual instructions below instead of exiting silently.
      elseif choice == 2 then   -- Cancel
        return
      end
      -- choice == 7 (No): fall through to the manual instructions below.
    else
      -- No ReaPack either — offer to download the ReaPack extension itself
      -- into UserPlugins, so after one restart the automatic ReaImGui flow
      -- above can run.
      local choice = reaper.ShowMessageBox(
        "This script needs ReaImGui, which installs through ReaPack —\n" ..
        "and ReaPack is not installed yet either.\n\n" ..
        "Install ReaPack automatically now?\n" ..
        "(Downloads the official extension into REAPER's UserPlugins\n" ..
        "folder. Then: restart REAPER, run this script again, and it\n" ..
        "will offer to install ReaImGui for you.)\n\n" ..
        "Yes  = do it automatically\n" ..
        "No   = show me the manual steps instead\n" ..
        "Cancel = quit",
        "ReaImGui + ReaPack not installed", 3)
      if choice == 6 then       -- Yes
        if try_reapack_bootstrap() then
          reaper.ShowMessageBox(
            "ReaPack was installed.\n\n" ..
            "  1. Restart REAPER.\n" ..
            "  2. Run this script again — it will offer to install\n" ..
            "     ReaImGui automatically.",
            "Restart REAPER", 0)
        else
          reaper.ShowMessageBox(
            "Automatic download failed (offline, or an unusual REAPER\n" ..
            "build). Install ReaPack manually from https://reapack.com\n" ..
            "— opening that page now — then run this script again.",
            "Download failed", 0)
          open_url("https://reapack.com/user-guide#installation")
        end
        return
      elseif choice == 2 then   -- Cancel
        return
      end
      -- No: fall through to the manual instructions below.
    end

    -- Manual fallback, tailored to whether ReaPack is present: its menu steps
    -- only make sense if the user actually has ReaPack.
    local has_reapack = reaper.APIExists and reaper.APIExists('ReaPack_AddSetRepository')
    if has_reapack then
      local choice = reaper.ShowMessageBox(
        "This script needs ReaImGui (free).\n\n" ..
        "Quickest install (REAPER must restart after):\n" ..
        "  1. Extensions - ReaPack - Import repositories...\n" ..
        "  2. Paste:\n" ..
        "     " .. REAIMGUI_REPO_URL .. "\n" ..
        "  3. Extensions - ReaPack - Browse packages - search\n" ..
        "     'ReaImGui' - right-click - Install - Apply.\n" ..
        "  4. Restart REAPER and run this script again.\n\n" ..
        "Open the ReaImGui homepage in your browser now?",
        "ReaImGui not installed", 4)
      if choice == 6 then
        open_url("https://github.com/cfillion/reaimgui#installation")
      end
    else
      local choice = reaper.ShowMessageBox(
        "This script needs ReaImGui, which installs through ReaPack —\n" ..
        "and neither is installed yet.\n\n" ..
        "Manual setup (REAPER must restart along the way):\n" ..
        "  1. Install ReaPack from https://reapack.com, then restart\n" ..
        "     REAPER.\n" ..
        "  2. Run this script again — it will offer to install ReaImGui\n" ..
        "     for you (or use ReaPack's Browse packages to add it).\n\n" ..
        "Open the ReaPack website now?",
        "ReaPack not installed", 4)
      if choice == 6 then
        open_url("https://reapack.com/")
      end
    end
    return
  end


  _ui_ctx  = reaper.ImGui_CreateContext('Samanvaya')
  _ui_font = _attach_unicode_font(_ui_ctx)

  -- Verify whatever was loaded from settings once, on the first frame. A key
  -- that expired between sessions should say so here, not three minutes into
  -- a run.
  probe_mark_dirty()

  local function close_window() _ui_window_open = false end

  -- App version from the VERSION file next to this script (read once).
  do
    local f = io.open(get_script_dir() .. package.config:sub(1, 1) .. "VERSION", "r")
    if f then
      _APP_VERSION = (f:read("*l") or ""):match("^%s*(.-)%s*$") or ""
      f:close()
    end
  end

  -- ReaImGui restores this window's last position from its own .ini. A stale
  -- position (monitor unplugged, or a corrupted negative cache) leaves the
  -- window fully off-screen: the action runs, nothing appears. Once per
  -- session, move it back only when the title bar is unreachable on the
  -- nearest monitor's work area.
  local _pos_checked = false
  local _pos_fix     = nil   -- {x, y} to apply before the NEXT Begin()

  local function check_offscreen(ctx)
    if _pos_checked then return end
    _pos_checked = true
    if not (reaper.ImGui_GetWindowPos and reaper.ImGui_SetNextWindowPos
            and reaper.my_getViewport) then return end
    local ok, x, y = pcall(reaper.ImGui_GetWindowPos, ctx)
    if not ok or type(x) ~= "number" or type(y) ~= "number" then return end
    local w, h = 760, 580
    if reaper.ImGui_GetWindowSize then
      local ok2, gw, gh = pcall(reaper.ImGui_GetWindowSize, ctx)
      if ok2 and type(gw) == "number" and gw > 0 then w, h = gw, gh end
    end
    local okv, l, t, r, b = pcall(reaper.my_getViewport,
                                  x, y, x + w, y + h,
                                  x, y, x + w, y + h, true)
    if not okv or type(l) ~= "number" then return end
    if x >= l - 8 and y >= t - 8 and x <= r - 80 and y <= b - 40 then return end
    _pos_fix = { l + 60, t + 60 }
    ui_set_banner('warn', string.format(
      "The window was off-screen at %d,%d (monitor work area %d,%d..%d,%d)"
      .. " — moved it back.", x, y, l, t, r, b))
  end

  local function frame()
    if _pos_fix then
      reaper.ImGui_SetNextWindowPos(_ui_ctx, _pos_fix[1], _pos_fix[2])
      _pos_fix = nil
    end
    -- Sized for the script box and the worker log — the two sections that
    -- want real estate. Every other section sits inside the same frame, so
    -- clicking down the rail never moves the window.
    -- Studio's rail is 12px wider and its spine rows are taller than the
    -- old 26px nav buttons, so the default and the floor both move up: at
    -- 440 the six spine rows plus the rail's footer no longer fit and the
    -- "Unplaced clips park on" line would clip.
    -- Both move up again now that the three panes actually honour their own
    -- inner padding: that is 24px of height the rail no longer has for its
    -- spine, and 32px of width the detail pane no longer has for its card.
    reaper.ImGui_SetNextWindowSize(_ui_ctx, 920, 640, reaper.ImGui_Cond_FirstUseEver())
    if reaper.ImGui_SetNextWindowSizeConstraints then
      pcall(reaper.ImGui_SetNextWindowSizeConstraints, _ui_ctx, 780, 580, 1e9, 1e9)
    end

    -- The theme wraps Begin/End: WindowBg and WindowRounding are style state,
    -- so they have to be on the stack before the window is opened.
    SUI.push_theme(_ui_ctx)
    -- A uniform SHELL_PAD margin around the three regions, so the rail and
    -- the action bar sit inside the rounded frame instead of against it.
    -- ImGui reads WindowPadding at Begin(), hence the push/pop here rather
    -- than in the theme — children and popups keep the themed value.
    reaper.ImGui_PushStyleVar(_ui_ctx, reaper.ImGui_StyleVar_WindowPadding(),
      SHELL_PAD, SHELL_PAD)
    -- The title bar is drawn INSIDE Begin(), off whatever font and frame
    -- padding are on the stack at that moment — and ImGui sizes its close
    -- button off the font alone (a circle of FontSize/2 + 1, with the cross
    -- at FontSize * 0.354). At the default 13px face that is a 15px button
    -- with a heavy cross, which is what made the X read as oversized. TITLE_PX
    -- drops the title and its button a notch together; the FramePadding then
    -- buys the bar back the height the smaller type gave up (22px, not 20)
    -- and pushes the button 10px off the right edge instead of 8 — a small
    -- control with room around it, rather than a big one wedged in a corner.
    -- Both are popped immediately after Begin, so the panel's own contents
    -- and every child window keep the themed values.
    local title_font = _ui_font
      and pcall(reaper.ImGui_PushFont, _ui_ctx, _ui_font, TITLE_PX)
    reaper.ImGui_PushStyleVar(_ui_ctx, reaper.ImGui_StyleVar_FramePadding(),
      TITLE_PAD_X, TITLE_PAD_Y)

    -- "###" pins the window ID so a version bump in the visible title never
    -- resets the saved window position.
    local visible, open = reaper.ImGui_Begin(_ui_ctx,
      'Samanvaya' .. (_APP_VERSION ~= '' and ('  ·  v' .. _APP_VERSION) or '')
      .. '###samanvaya',
      SUI.native_close and true or nil, reaper.ImGui_WindowFlags_NoCollapse() | SUI.NOSB)
    if open == nil then open = true end
    reaper.ImGui_PopStyleVar(_ui_ctx, 2)
    if title_font then pcall(reaper.ImGui_PopFont, _ui_ctx) end
    -- Outside the `visible` guard: a fully off-screen window can report
    -- itself as not visible — the exact case that needs the rescue.
    check_offscreen(_ui_ctx)
    if visible then
      if _ui_phase == "running" then
        poll_python_step()   -- refresh log/progress before rendering
      end
      render_active_phase(_ui_ctx, close_window)
      -- Guarded: if painting the close ever fails, ImGui's own close comes
      -- back on the next frame instead of the script stopping.
      if not pcall(SUI.close_x, _ui_ctx, TITLE_PX + TITLE_PAD_Y * 2, close_window) then
        SUI.native_close, SUI._api_missing = true, true
      end
    end
    reaper.ImGui_End(_ui_ctx)   -- always paired with Begin()
    SUI.pop_theme(_ui_ctx)

    _ui_window_open = _ui_window_open and open
    if _ui_window_open then
      -- A pasted key persists on its own, a second or so after the typing
      -- stops — no Start Sync and no OK button in the loop.
      settings_autosave_tick()
      reaper.defer(frame)
    else
      -- Last chance: the debounce may not have elapsed when the X was hit.
      settings_autosave_flush()
    end
    -- If the window closes mid-run the Python keeps going in the background
    -- (it still writes the log + done files); we simply stop polling.
  end

  reaper.defer(frame)
end

-- Re-running the action never shows REAPER's "ReaScript task control" dialog
-- (7.03+): the window simply restarts.
if reaper.set_action_options then reaper.set_action_options(2) end
reaper.defer(main)
