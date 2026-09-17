--!nonstrict
-- Watch Anime panel.
--
-- Search an anime (AniList primary, Kitsu fallback - both key-free and
-- stable), browse pretty result cards with poster, synopsis, genres and an
-- episode grid, then either stream it straight into the player or download
-- headless via the GoAnime CLI - always from this panel, never a terminal.
-- Watch streams online via the bundled `goanime-stream` helper (compiled in
-- the background on first use into <pluginDataDir>/bin); until it is ready it
-- falls back to fetching the episode into a temporary cache and opening mpv as
-- soon as it is ready — the cache is deleted after playback, so nothing is
-- saved. Download / Download all keep files in the downloads folder.
-- Type `/watch-anime <query>` in the launcher to open the panel.
local util = require("./lib/util.luau")

local SOURCES = { "all", "anidb", "animefire", "goyabu" }
local SOURCE_KEYS = { "source.all", "source.anidb", "source.animefire", "source.goyabu" }
local QUALITIES = { "best", "worst", "1080p", "720p", "480p" }

local function L(key)
  return util.tr(key)
end

local function tr(key, subst)
  return util.tr(key, subst)
end

local raw = ""
local sourceIndex = 0
local qualityIndex = 0
local epText = ""
local statusMsg = ""
local history = {}
local selected = nil
local results = {}
local searching = false
local lastSearched = ""
local render = nil

-- Download-selection mode (pick individual episodes in the grid) and the
-- live download job tracked through a progress file.
local selectMode = false
local selectEps = {} -- ep number -> true
local dlActive = false
local dlJob = nil -- { query, total, done }
local lastPollCount = -1

-- Episode grid paging: long series (One Piece: 1000+) would otherwise render
-- one giant chip list. We show a fixed window and let the user page through.
local EP_PAGE_SIZE = 100
local epPage = 0 -- 0-based page index

local histFile = nil

local function historyPath()
  if histFile ~= nil then
    return histFile
  end
  local dir = noctalia.pluginDataDir()
  if type(dir) == "string" and dir ~= "" then
    histFile = dir .. "/history.json"
  else
    histFile = ""
  end
  return histFile
end

local function loadHistory()
  local p = historyPath()
  if p == "" then
    return
  end
  local text = noctalia.readFile(p)
  if type(text) ~= "string" or text == "" then
    return
  end
  local data = util.decodeJson(text)
  if type(data) == "table" and type(data.searches) == "table" then
    history = data.searches
  end
end

local function saveHistory()
  local p = historyPath()
  if p == "" then
    return
  end
  noctalia.writeFile(p, util.encodeJson({ searches = history }))
end

local function addHistory(query)
  local q = util.trim(query)
  if q == "" then
    return
  end
  for i, entry in ipairs(history) do
    if entry.q == q then
      table.remove(history, i)
      break
    end
  end
  table.insert(history, 1, { q = q, t = noctalia.nowMs() })
  while #history > 20 do
    table.remove(history)
  end
  saveHistory()
end

-- History is recorded on search/selection; it is never shown as a fixed
-- block — matching previous searches surface as suggestions while typing.

local function config()
  local source = noctalia.getConfig("source_default")
  if type(source) ~= "string" or source == "" then
    source = "all"
  end
  local quality = noctalia.getConfig("quality_default")
  if type(quality) ~= "string" or quality == "" then
    quality = "best"
  end
  local downloadDir = noctalia.getConfig("download_dir")
  if type(downloadDir) ~= "string" then
    downloadDir = ""
  end
  local openAfter = noctalia.getConfig("open_after_download") ~= false
  return {
    source = source,
    quality = quality,
    downloadDir = util.trim(downloadDir),
    openAfter = openAfter,
  }
end

local function indexOf(list, value)
  for i, item in ipairs(list) do
    if item == value then
      return i - 1
    end
  end
  return 0
end

local function currentQuery()
  return util.trim(raw)
end

local function openUrl(url)
  if type(url) ~= "string" or url == "" then
    return
  end
  noctalia.runAsync("xdg-open " .. util.shellQuote(url))
end

local function openFolder(path)
  if path == "" then
    return
  end
  noctalia.runAsync("nohup xdg-open " .. util.shellQuote(path) .. " >/dev/null 2>&1 &")
end

local function downloadsFolder(cfg)
  if cfg.downloadDir ~= "" then
    return cfg.downloadDir
  end
  local home = util.home()
  if home ~= "" then
    -- GoAnime CLI's real default downloads folder.
    return home .. "/.local/goanime/downloads/anime"
  end
  return ""
end

local function notifyStatus(key, subst)
  statusMsg = tr(key, subst)
  render()
end

local function watchAnimeAvailable()
  return noctalia.commandExists("goanime") == true
end

local function episodeSpec()
  local t = util.trim(epText):lower()
  if t == "" then
    t = "1"
  end
  if t == "all" then
    return { all = true }
  end
  if util.isDigits(t) then
    return { episode = t }
  end
  if util.isRange(t) then
    return { range = t }
  end
  return nil
end

local function sourceFlag(source)
  if source == "all" or source == "" then
    return ""
  end
  return "--source " .. source
end

local function watchAnimeQuery()
  if selected and selected.query ~= "" then
    return selected.query
  end
  return currentQuery()
end

local function watchAnimeParts(spec, cfg)
  local source = SOURCES[sourceIndex + 1]
  if source == nil then
    source = cfg.source
  end
  local quality = QUALITIES[qualityIndex + 1]
  if quality == nil then
    quality = cfg.quality
  end
  local parts = { "goanime", "-d" }
  if spec.range then
    parts[#parts + 1] = "-r"
  elseif spec.all then
    parts[#parts + 1] = "-a"
  end
  local sf = sourceFlag(source)
  if sf ~= "" then
    parts[#parts + 1] = sf
  end
  parts[#parts + 1] = "--quality " .. util.shellQuote(quality)
  if cfg.downloadDir ~= "" then
    parts[#parts + 1] = "-o " .. util.shellQuote(cfg.downloadDir)
  end
  parts[#parts + 1] = util.shellQuote(watchAnimeQuery())
  if spec.episode then
    parts[#parts + 1] = spec.episode
  elseif spec.range then
    parts[#parts + 1] = spec.range
  end
  return parts
end

local function logAppend(cmd)
  local dir = noctalia.pluginDataDir()
  if type(dir) == "string" and dir ~= "" then
    return "nohup " .. cmd .. " >> " .. util.shellQuote(dir .. "/download.log") .. " 2>&1 &"
  end
  return "nohup " .. cmd .. " >/dev/null 2>&1 &"
end

-- ---- download runner (per-episode, with progress) --------------------------
-- Downloads run as ONE detached `sh` batch (survives panel close). Each
-- episode is its own `goanime -d "<q>" <n>` invocation; completion markers
-- ("D <n>" / "F <n>" / "END") are appended to a progress file that the
-- panel's update() re-reads on a one-second tick, driving a live bar. The
-- batch is setid'd into its own process group so Cancel can kill the whole
-- tree with a single signal. Episode stdout goes to download.log (Bubble Tea
-- ANSI noise included) — only the markers feed the panel.

local function dataDir()
  local dir = noctalia.pluginDataDir()
  if type(dir) == "string" and dir ~= "" then
    return dir
  end
  return nil
end

local function dlLogPath()
  local dir = dataDir()
  if dir == nil then
    return ""
  end
  return dir .. "/download.log"
end

local function dlProgressPath()
  local dir = dataDir()
  if dir == nil then
    return ""
  end
  return dir .. "/dl-progress.txt"
end

local function dlStatePath()
  local dir = dataDir()
  if dir == nil then
    return ""
  end
  return dir .. "/dl-state.json"
end

local function dlPidPath()
  local dir = dataDir()
  if dir == nil then
    return ""
  end
  return dir .. "/dl.pid"
end

local function dlScriptPath()
  local dir = dataDir()
  if dir == nil then
    return ""
  end
  return dir .. "/dl-batch.sh"
end

-- Parse a snapshot of the progress file. Only complete lines (file ends with
-- \n) are counted, so a torn mid-write read is simply caught on the next tick.
local function parseProgress(text)
  local done, fail, finished = 0, 0, false
  if type(text) ~= "string" or text == "" then
    return done, fail, finished
  end
  local complete = text:match("^(.*)\n") or ""
  for line in complete:gmatch("[^\n]+") do
    if line == "END" then
      finished = true
    else
      local kind = line:match("^([DF])%s")
      if kind == "D" then
        done = done + 1
      elseif kind == "F" then
        fail = fail + 1
      end
    end
  end
  return done, fail, finished
end

-- Turn an episodeSpec into a concrete, enumerable list. `all` with an unknown
-- count returns nil → the caller falls back to the CLI's own "-a" mode.
local function episodesFromSpec(spec)
  if spec.all then
    local n = (type(selected) == "table" and type(selected.episodes) == "number") and selected.episodes or 0
    if type(n) ~= "number" or n <= 0 then
      return nil
    end
    local eps = {}
    for i = 1, math.min(n, 400) do
      eps[#eps + 1] = i
    end
    return eps
  end
  if spec.episode then
    local n = tonumber(spec.episode)
    if n ~= nil and n > 0 then
      return { n }
    end
    return {}
  end
  if spec.range then
    local a, b = spec.range:match("^(%d+)-(%d+)$")
    a, b = tonumber(a), tonumber(b)
    if a == nil or b == nil or a > b then
      return {}
    end
    local bCap = math.min(b, a + 399)
    local eps = {}
    for i = a, bCap do
      eps[#eps + 1] = i
    end
    return eps
  end
  return {}
end

local function countSelectEps()
  local n = 0
  for _ in pairs(selectEps) do
    n = n + 1
  end
  return n
end

local function resetSelection()
  selectMode = false
  selectEps = {}
end

local function buildDownloadScript(eps, cfg)
  local logPath = dlLogPath()
  local progressPath = dlProgressPath()
  local lines = { "set +e" }
  for _, ep in ipairs(eps) do
    local spec = { episode = tostring(ep) }
    local cmd = table.concat(watchAnimeParts(spec, cfg), " ")
    lines[#lines + 1] = cmd .. " </dev/null >> " .. util.shellQuote(logPath) .. " 2>&1"
    lines[#lines + 1] = "if [ $? -eq 0 ]; then echo \"D " .. tostring(ep) .. "\" >> " .. util.shellQuote(progressPath)
      .. "; else echo \"F " .. tostring(ep) .. "\" >> " .. util.shellQuote(progressPath) .. "; fi"
  end
  lines[#lines + 1] = "echo \"END\" >> " .. util.shellQuote(progressPath)
  return table.concat(lines, "\n")
end

-- Old single-shot path (no progress): used for `download all` on anime with an
-- unknown episode count, where the CLI's "-a" enumerates them internally.
local function launchLegacy(spec, cfg)
  addHistory(watchAnimeQuery())
  noctalia.runAsync(logAppend(table.concat(watchAnimeParts(spec, cfg), " ")))
  statusMsg = ""
  render()
  noctalia.notify(L("title"), tr("status.downloading", { q = watchAnimeQuery() }))
  if cfg.openAfter then
    openFolder(downloadsFolder(cfg))
  end
end

-- Launch a tracked, per-episode batch. Returns true once the batch is running.
local function startDownload(eps)
  local q = watchAnimeQuery()
  if q == "" then
    return false
  end
  if not watchAnimeAvailable() then
    notifyStatus("status.no_goanime")
    noctalia.notifyError(L("title"), L("status.no_goanime"))
    return false
  end
  if dlActive then
    noctalia.notifyError(L("title"), L("download.busy"))
    return false
  end
  if #eps == 0 then
    notifyStatus("status.bad_episodes")
    return false
  end
  if dataDir() == nil then
    launchLegacy({ episode = tostring(eps[1]) }, config())
    return false
  end
  local cfg = config()
  addHistory(q)

  dlJob = { query = q, total = #eps, done = 0, failedCount = 0 }
  dlActive = true
  lastPollCount = -1

  noctalia.writeFile(dlStatePath(), util.encodeJson({ query = q, total = #eps, started = noctalia.nowMs() }))
  noctalia.writeFile(dlProgressPath(), "")
  noctalia.writeFile(dlScriptPath(), buildDownloadScript(eps, cfg))

  -- setsid grants the batch its own process group so Cancel can kill the tree.
  noctalia.runAsync(
    "setsid sh " .. util.shellQuote(dlScriptPath()) .. " >/dev/null 2>&1 < /dev/null & echo $! > " .. util.shellQuote(dlPidPath())
  )

  statusMsg = tr("status.downloading", { q = q })
  render()
  noctalia.notify(L("title"), statusMsg)

  if cfg.openAfter then
    openFolder(downloadsFolder(cfg))
  end
  return true
end

local function pollDownloadCleanup()
  noctalia.removeFile(dlStatePath())
  noctalia.removeFile(dlProgressPath())
  noctalia.removeFile(dlPidPath())
  noctalia.removeFile(dlScriptPath())
  dlActive = false
  dlJob = nil
  lastPollCount = -1
end

local function pollDownload()
  if not dlActive or dlJob == nil then
    return
  end
  local done, fail, finished = parseProgress(noctalia.readFile(dlProgressPath()))
  local total = dlJob.total
  if total == nil or total <= 0 then
    total = 1
  end
  done = math.min(done, total)
  if done == lastPollCount and not finished then
    return
  end
  if finished then
    local ok = math.max(0, total - fail)
    local msg = fail == 0
      and tr("download.finished_ok", { ok = tostring(ok), total = tostring(total) })
      or tr("download.finished_fail", { ok = tostring(ok), total = tostring(total), fail = tostring(fail) })
    pollDownloadCleanup()
    statusMsg = msg
    render()
    noctalia.notify(L("title"), msg)
  else
    dlJob.done = done
    dlJob.failedCount = fail
    lastPollCount = done
    render()
  end
end

function update()
  if dlActive then
    pollDownload()
  end
end

-- Resume a batch that is still running after the panel was closed/reopened.
local function loadDlState()
  local text = noctalia.readFile(dlStatePath())
  if type(text) ~= "string" or text == "" then
    return
  end
  local data = util.decodeJson(text)
  local q = type(data) == "table" and tostring(data.query or "") or ""
  local total = type(data) == "table" and tonumber(data.total) or 0
  if q == "" or total == nil or total <= 0 then
    pollDownloadCleanup()
    return
  end
  local done, fail, finished = parseProgress(noctalia.readFile(dlProgressPath()))
  if finished then
    pollDownloadCleanup()
    return
  end
  dlActive = true
  dlJob = { query = q, total = total, done = math.min(done, total), failedCount = fail }
  lastPollCount = dlJob.done
  statusMsg = tr("status.downloading", { q = q })
end

local function renderDownloadProgress()
  local job = dlJob
  if job == nil then
    return nil
  end
  local total = (job.total ~= nil and job.total > 0) and job.total or 1
  local done = math.min(job.done or 0, total)
  local pct = math.max(0, math.min(1, done / total))
  local failNote = ""
  if job.failedCount ~= nil and job.failedCount > 0 then
    failNote = " " .. tr("download.failed_count", { n = tostring(job.failedCount) })
  end
  return ui.column({ gap = 6, align = "stretch" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "download", size = 14, color = "primary" }),
      ui.label({
        text = tr("status.downloading", { q = job.query }) .. failNote,
        fontSize = 12,
        fontWeight = "medium",
        color = "on_surface",
        flexGrow = 1,
        maxLines = 1,
      }),
      ui.label({
        text = tr("download.count", { done = tostring(done), total = tostring(total) }),
        fontSize = 12,
        color = "on_surface_variant",
      }),
      ui.button({ glyph = "x", glyphSize = 14, variant = "ghost", tooltip = L("download.cancel_tooltip"), onClick = "onDownloadCancelClicked" }),
    }),
    ui.progress({ progress = pct, fill = "primary", track = "surface_variant", height = 6, radius = 3 }),
  })
end

-- ---- goanime-stream self-install ------------------------------------------
-- True online streaming needs the `goanime-stream` helper (resolves the
-- episode to its direct stream URL and opens mpv on it — nothing on disk).
-- The helper ships bundled with this plugin (stream/main.go + build.sh); on
-- the first Watch without a binary, the panel compiles it into
-- <pluginDataDir>/bin in the background (needs git + go), notifying the user
-- when it is ready. Until then, Watch falls back to the temp-cache mode.

local STREAM_BUILD_TIMEOUT_MS = 10 * 60 * 1000 -- stale build marker threshold

local streamBin = nil            -- resolved binary (PATH first, then data dir)
local streamBuildScript = nil    -- pluginDir()/stream/build.sh if bundled
local streamInstallSent = false  -- "installing" notify sent (for ready notify)

local function streamBinDir()
  local dir = noctalia.pluginDataDir()
  if type(dir) ~= "string" or dir == "" then
    return nil
  end
  return dir .. "/bin"
end

local function streamBuildMarker()
  local dir = streamBinDir()
  if dir == nil then
    return nil
  end
  return dir .. "/.stream-building"
end

local function streamIsBuilding()
  local marker = streamBuildMarker()
  if marker == nil then
    return false
  end
  local text = noctalia.readFile(marker)
  local start = tonumber(text)
  if start == nil then
    return false
  end
  return noctalia.nowMs() - start < STREAM_BUILD_TIMEOUT_MS
end

-- Path of the goanime-stream binary to use: one on PATH wins, then the panel's
-- self-built copy in the plugin data dir. Returns nil when unavailable.
local function streamBinary()
  if streamBin ~= nil then
    return streamBin
  end
  if noctalia.commandExists("goanime-stream") == true then
    streamBin = "goanime-stream"
    return streamBin
  end
  local dir = streamBinDir()
  if dir ~= nil and noctalia.fileExists(dir .. "/goanime-stream") then
    streamBin = dir .. "/goanime-stream"
    return streamBin
  end
  return nil
end

local function streamBuildScriptPath()
  if streamBuildScript ~= nil then
    return streamBuildScript
  end
  local plugin = noctalia.pluginDir()
  if type(plugin) == "string" and plugin ~= "" then
    local script = plugin .. "/stream/build.sh"
    if noctalia.fileExists(script) then
      streamBuildScript = script
    end
  end
  return streamBuildScript
end

-- Make goanime-stream available, compiling the bundled source in the
-- background when missing. Returns nil when already available, otherwise a
-- reason string: "started" | "building" | "unavailable" | "no-toolchain".
local function streamEnsure()
  if streamBinary() ~= nil then
    return nil
  end
  local marker = streamBuildMarker()
  if marker ~= nil and noctalia.fileExists(marker) and streamIsBuilding() then
    return "building"
  end
  local script = streamBuildScriptPath()
  if script == nil then
    return "unavailable"
  end
  if noctalia.commandExists("go") ~= true or noctalia.commandExists("git") ~= true then
    return "no-toolchain"
  end
  local dir = streamBinDir()
  if dir == nil then
    return "unavailable"
  end
  noctalia.mkdirAll(dir)
  -- (Re)start the build; overwriting the marker also clears stale markers.
  noctalia.writeFile(marker, tostring(noctalia.nowMs()))
  local log = noctalia.pluginDataDir() .. "/stream-build.log"
  local cmd = "nohup bash " .. util.shellQuote(script) .. " " .. util.shellQuote(dir)
    .. " >> " .. util.shellQuote(log) .. " 2>&1 &"
  noctalia.log("goanime-stream: starting background build -> " .. dir)
  noctalia.runAsync(cmd)
  return "started"
end

-- Drop the build marker once the binary exists; keep it while still compiling
-- so reopening the panel mid-build doesn't start a second build.
local function streamCleanup()
  local marker = streamBuildMarker()
  if marker == nil or not noctalia.fileExists(marker) then
    return
  end
  if streamBinary() ~= nil then
    noctalia.removeFile(marker)
    return
  end
  if not streamIsBuilding() then
    noctalia.removeFile(marker) -- stale: the next Watch will retry
  end
end

-- ---- "Watch" streams:
-- Preferred path: goanime-stream resolves the episode to its direct stream URL
-- and opens mpv on it — true online playback, nothing on disk. Fallback: fetch
-- the episode into a temporary cache, open the player (mpv) the moment it is
-- ready, and delete the cache after playback. Either way nothing is saved to
-- the downloads folder.

local watchCacheBase = nil

local function watchCacheDir()
  if watchCacheBase ~= nil then
    return watchCacheBase
  end
  local base = noctalia.getenv("XDG_CACHE_HOME")
  if type(base) ~= "string" or base == "" then
    base = util.home() .. "/.cache"
  end
  local dir = base .. "/watch-anime/watch"
  noctalia.mkdirAll(dir)
  watchCacheBase = dir
  return dir
end

local function streamEpisodeNumber(spec)
  if spec.episode then
    return spec.episode
  end
  if spec.range then
    local first = spec.range:match("^(%d+)")
    if first ~= nil then
      return first
    end
  end
  if spec.all then
    return "1"
  end
  return nil
end

local function streamParts(spec, cfg, epNum)
  local source = SOURCES[sourceIndex + 1]
  if source == nil then
    source = cfg.source
  end
  local quality = QUALITIES[qualityIndex + 1]
  if quality == nil then
    quality = cfg.quality
  end
  local parts = { "goanime", "-d", "-o", "\"$CACHE\"" }
  local sf = sourceFlag(source)
  if sf ~= "" then
    parts[#parts + 1] = sf
  end
  parts[#parts + 1] = "--quality " .. util.shellQuote(quality)
  parts[#parts + 1] = util.shellQuote(watchAnimeQuery())
  parts[#parts + 1] = epNum
  return parts
end

local function streamOneLiner(parts)
  local dir = watchCacheDir()
  if dir == "" then
    return nil
  end
  local oneLiner = "CACHE=$(mktemp -d " .. util.shellQuote(dir .. "/watch.XXXXXX")
    .. ") || exit 1; "
    .. table.concat(parts, " ")
    .. "; L=$(ls -1t \"$CACHE\"/*.mp4 2>/dev/null | head -1)"
    .. "; if [ -n \"$L\" ]; then"
    .. "  if command -v mpv >/dev/null 2>&1; then mpv \"$L\"; rm -rf \"$CACHE\";"
    .. "  else xdg-open \"$L\"; fi;"
    .. " else rm -rf \"$CACHE\"; fi; exit 0"
  return "nohup bash -c " .. util.shellQuote(oneLiner) .. " >/dev/null 2>&1 &"
end

local function streamCliCmd(spec, cfg, epNum, bin)
  local source = SOURCES[sourceIndex + 1]
  if source == nil then
    source = cfg.source
  end
  local quality = QUALITIES[qualityIndex + 1]
  if quality == nil then
    quality = cfg.quality
  end
  local args = { util.shellQuote(bin) }
  if source ~= "all" then
    args[#args + 1] = "--source " .. source
  end
  args[#args + 1] = "--quality " .. util.shellQuote(quality)
  args[#args + 1] = util.shellQuote(watchAnimeQuery())
  args[#args + 1] = epNum
  -- < /dev/null guarantees goanime-stream never hangs waiting for a TTY.
  return logAppend(table.concat(args, " ") .. " < /dev/null")
end

function onWatch()
  local query = currentQuery()
  if query == "" and not (selected and selected.query ~= "") then
    return
  end
  if not watchAnimeAvailable() then
    notifyStatus("status.no_goanime")
    noctalia.notifyError(L("title"), L("status.no_goanime"))
    return
  end
  local spec = episodeSpec()
  if spec == nil then
    notifyStatus("status.bad_episodes")
    return
  end
  local epNum = streamEpisodeNumber(spec)
  if epNum == nil then
    epNum = "1"
  end
  local cfg = config()
  local bin = streamBinary()
  local cmd
  local note
  if bin ~= nil then
    cmd = streamCliCmd(spec, cfg, epNum, bin)
    if streamInstallSent then
      streamInstallSent = false
      noctalia.notify(L("title"), L("stream.ready"))
    end
    streamCleanup()
  else
    cmd = streamOneLiner(streamParts(spec, cfg, epNum))
    if cmd == nil then
      notifyStatus("status.no_cache")
      return
    end
    local st = streamEnsure()
    if st == "started" then
      streamInstallSent = true
      note = tr("stream.installing")
      noctalia.notify(L("title"), L("stream.installing"))
    elseif st == "building" then
      note = tr("stream.building")
    elseif st == "no-toolchain" then
      note = tr("stream.needs_toolchain")
    end
  end
  addHistory(watchAnimeQuery())
  noctalia.runAsync(cmd)
  statusMsg = note or ""
  render()
  noctalia.notify(L("title"), tr("status.watching", { q = watchAnimeQuery() }))
end

function onWatchClicked()
  onWatch()
end

function onDownload()
  local query = currentQuery()
  if query == "" and not (selected and selected.query ~= "") then
    return
  end
  if not watchAnimeAvailable() then
    notifyStatus("status.no_goanime")
    noctalia.notifyError(L("title"), L("status.no_goanime"))
    return
  end
  if dlActive then
    noctalia.notifyError(L("title"), L("download.busy"))
    return
  end
  local spec = episodeSpec()
  if spec == nil then
    notifyStatus("status.bad_episodes")
    return
  end
  local eps = episodesFromSpec(spec)
  if eps == nil then
    -- Ongoing anime with an unknown episode count: let the CLI's "-a" pick.
    launchLegacy(spec, config())
    return
  end
  startDownload(eps)
end

function toggleSelectEp(ep)
  if selectEps[ep] then
    selectEps[ep] = nil
  else
    selectEps[ep] = true
  end
  render()
end

function onSelectModeClicked()
  if dlActive then
    noctalia.notifyError(L("title"), L("download.busy"))
    return
  end
  selectMode = true
  selectEps = {}
  render()
end

-- "Select all" scopes to the currently visible page so it stays sane for very
-- long series (One Piece: 1000+). Selection accumulates across pages.
function onSelectAllClicked()
  local n = (type(selected) == "table" and type(selected.episodes) == "number") and selected.episodes or 0
  if n <= 0 then
    return
  end
  local totalPages = math.max(1, math.ceil(n / EP_PAGE_SIZE))
  local page = math.min(math.max(epPage, 0), totalPages - 1)
  local firstEp = page * EP_PAGE_SIZE + 1
  local lastEp = math.min(firstEp + EP_PAGE_SIZE - 1, n)
  for i = firstEp, lastEp do
    selectEps[i] = true
  end
  render()
end

function onEpPagePrev()
  epPage = math.max(0, epPage - 1)
  render()
end

function onEpPageNext()
  epPage = epPage + 1
  render()
end

function onEpPageFirst()
  epPage = 0
  render()
end

function onEpPageLast()
  local n = (type(selected) == "table" and type(selected.episodes) == "number") and selected.episodes or 0
  epPage = math.max(0, math.ceil(n / EP_PAGE_SIZE) - 1)
  render()
end

function onSelectClearClicked()
  selectEps = {}
  render()
end

function onSelectCancelClicked()
  resetSelection()
  render()
end

function onDownloadSelectedClicked()
  local eps = {}
  for ep in pairs(selectEps) do
    eps[#eps + 1] = ep
  end
  table.sort(eps)
  if #eps == 0 then
    return
  end
  if startDownload(eps) then
    resetSelection()
  end
end

function onDownloadCancelClicked()
  local pidText = noctalia.readFile(dlPidPath())
  if type(pidText) == "string" then
    local pid = pidText:match("(%d+)")
    if pid ~= nil then
      -- setsid gives the batch its own group; -<pid> kills the whole tree.
      noctalia.runAsync("kill -TERM -- -" .. pid .. " 2>/dev/null; kill -TERM " .. pid .. " 2>/dev/null; true")
    end
  end
  pollDownloadCleanup()
  statusMsg = L("download.cancelled")
  render()
  noctalia.notify(L("title"), L("download.cancelled"))
end

function onDownloadClicked()
  onDownload()
end

function onDownloadAllClicked()
  epText = "all"
  onDownload()
end

function onOpenDownloadsClicked()
  local cfg = config()
  openFolder(downloadsFolder(cfg))
end

function onEpisodeWatchClick(ep)
  epText = tostring(ep)
  onWatch()
end

local posterCacheDir = nil

local function posterDir()
  if posterCacheDir then
    return posterCacheDir
  end
  local dir = noctalia.pluginDataDir()
  if type(dir) == "string" and dir ~= "" then
    posterCacheDir = dir .. "/posters"
    noctalia.mkdirAll(posterCacheDir)
  end
  return posterCacheDir
end

local function resultKey(anime)
  return tostring(anime.mal_id)
end

local posterPaths = {}
local posterInflight = {}

local function requestPoster(url, key)
  if posterPaths[key] ~= nil or posterInflight[key] ~= nil then
    return
  end
  local dir = posterDir()
  if dir == nil then
    return
  end
  local dest = dir .. "/" .. key .. ".jpg"
  if noctalia.fileExists(dest) then
    posterPaths[key] = dest
    return
  end
  posterInflight[key] = true
  local started = noctalia.download(url, dest, function(ok)
    posterInflight[key] = nil
    if ok then
      posterPaths[key] = dest
      render()
    end
  end)
  if not started then
    posterInflight[key] = nil
  end
  return started
end

local function posterPathFor(anime)
  if anime == nil then
    return nil
  end
  local init = type(anime.image_url) == "string" and anime.image_url or ""
  if init ~= "" then
    requestPoster(init, resultKey(anime))
  end
  return posterPaths[resultKey(anime)]
end

local function cleanAnime(item)
  local genres = {}
  if type(item.genres) == "table" then
    for _, g in ipairs(item.genres) do
      if type(g) == "table" and type(g.name) == "string" then
        genres[#genres + 1] = g.name
      end
    end
  end
  local jpg = type(item.images) == "table" and type(item.images.jpg) == "table"
    and item.images.jpg or nil
  return {
    mal_id = item.mal_id,
    title = item.title ~= nil and item.title or "",
    title_english = item.title_english ~= nil and item.title_english or "",
    title_japanese = item.title_japanese ~= nil and item.title_japanese or "",
    show_type = item.type ~= nil and item.type or "",
    episodes = item.episodes ~= nil and item.episodes or nil,
    status = item.status ~= nil and item.status or "",
    score = item.score ~= nil and item.score or nil,
    year = item.year ~= nil and item.year or nil,
    synopsis = item.synopsis ~= nil and item.synopsis or "",
    url = item.url ~= nil and item.url or "",
    genres = genres,
    image_url = jpg ~= nil and jpg.image_url or "",
    query = (type(item.title) == "string" and item.title ~= "") and item.title
      or ((type(item.title_english) == "string" and item.title_english) or item.title or ""),
  }
end

local function stripHtml(text)
  text = text:gsub("<br%s*/?>", "\n")
  text = text:gsub("<[^>]+>", "")
  text = text:gsub("%[%![^%]!]+%!%]", "")
  text = text:gsub("__%*%*", ""):gsub("%*%*__", ""):gsub("%*%*", "")
  text = text:gsub("&nbsp;", " "):gsub("&quot;", '"'):gsub("&#039;", "'")
  text = text:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
  text = text:gsub("%s+", " ")
  return util.trim(text)
end

local function pickFirst(value, ...)
  for i = 1, select("#", ...) do
    if type(value) == "string" and value ~= "" then
      return value
    end
    value = select(i, ...)
  end
  return type(value) == "string" and value or ""
end

-- AniList reports `episodes: null` for currently-releasing shows; the released
-- count is then `nextAiringEpisode.episode - 1` (One Piece → 1178). Without
-- this, long running series showed no episode grid at all.
local function anilistEpisodeCount(item)
  if type(item.episodes) == "number" and item.episodes > 0 then
    return item.episodes
  end
  local nextEp = type(item.nextAiringEpisode) == "table" and item.nextAiringEpisode or nil
  local n = nextEp ~= nil and nextEp.episode or nil
  if type(n) == "number" and n > 1 then
    return n - 1
  end
  return nil
end

local function fromAnilist(item)
  local title = type(item.title) == "table" and item.title or nil
  local romaji = title ~= nil and type(title.romaji) == "string" and title.romaji or ""
  local english = title ~= nil and type(title.english) == "string" and title.english or ""
  local native = title ~= nil and type(title.native) == "string" and title.native or ""
  local cover = type(item.coverImage) == "table" and item.coverImage or nil
  local startDate = type(item.startDate) == "table" and item.startDate or nil
  local genres = type(item.genres) == "table" and item.genres or {}
  local cleanGenres = {}
  for _, g in ipairs(genres) do
    if type(g) == "string" and g ~= "" then
      cleanGenres[#cleanGenres + 1] = g
    end
  end
  local score = item.averageScore
  if type(score) == "number" then
    score = math.floor(score / 10 * 10 + 0.5) / 10
  end
  return {
    mal_id = item.id,
    title = romaji,
    title_english = english,
    title_japanese = native,
    show_type = type(item.format) == "string" and item.format or "",
    episodes = anilistEpisodeCount(item),
    status = type(item.status) == "string" and item.status or "",
    score = score,
    year = startDate ~= nil and startDate.year or nil,
    synopsis = stripHtml(type(item.description) == "string" and item.description or ""),
    url = type(item.siteUrl) == "string" and item.siteUrl or "",
    genres = cleanGenres,
    image_url = cover ~= nil
      and (type(cover.extraLarge) == "string" and cover.extraLarge
        or (type(cover.large) == "string" and cover.large or "")) or "",
    query = pickFirst(english, romaji),
  }
end

local function fromKitsu(item)
  local attrs = type(item.attributes) == "table" and item.attributes or {}
  local titles = type(attrs.titles) == "table" and attrs.titles or {}
  local english = pickFirst(titles.en, titles.en_jp, titles.en_us)
  local canonical = type(attrs.canonicalTitle) == "string" and attrs.canonicalTitle or ""
  local poster = type(attrs.posterImage) == "table" and attrs.posterImage or {}
  local genres = {}
  local rel = type(item.relationships) == "table" and item.relationships or {}
  if type(rel.categories) == "table" then
    local data = rel.categories.data
    if type(data) == "table" then
      for _, ref in ipairs(data) do
        if type(ref) == "table" and type(ref.id) == "string" then
          genres[#genres + 1] = ref.id
        end
      end
    end
  end
  local score = tonumber(attrs.averageRating)
  if score ~= nil then
    score = math.floor(score / 10 * 10 + 0.5) / 10
  end
  local year = nil
  if type(attrs.startDate) == "string" and attrs.startDate:match("^(%d%d%d%d)%-") then
    year = tonumber(attrs.startDate:match("^(%d%d%d%d)%-"))
  end
  local url = ""
  if type(attrs.slug) == "string" and attrs.slug ~= "" then
    url = "https://kitsu.io/anime/" .. attrs.slug
  end
  return {
    mal_id = item.id,
    title = pickFirst(english, canonical),
    title_english = english,
    title_japanese = pickFirst(titles.ja_jp),
    show_type = type(attrs.subtype) == "string" and attrs.subtype or "",
    episodes = attrs.episodeCount,
    status = type(attrs.status) == "string" and attrs.status or "",
    score = score,
    year = year,
    synopsis = stripHtml(type(attrs.synopsis) == "string" and attrs.synopsis or ""),
    url = url,
    genres = genres,
    image_url = type(poster.large) == "string" and poster.large
      or (type(poster.medium) == "string" and poster.medium or ""),
    query = pickFirst(english, canonical),
  }
end

local function prettyStatus(code)
  local norm = (type(code) == "string" and code or ""):lower():gsub("_", " ")
  if norm == "finished" or norm == "complete" or norm == "completed" then
    return L("status.map.finished")
  elseif norm == "releasing" or norm == "airing" or norm == "current" or norm == "ongoing" then
    return L("status.map.airing")
  elseif norm == "not yet aired" or norm == "not yet released" then
    return L("status.map.not_yet")
  elseif norm == "cancelled" or norm == "canceled" then
    return L("status.map.cancelled")
  elseif norm == "hiatus" or norm == "on hiatus" then
    return L("status.map.hiatus")
  elseif norm == "upcoming" or norm == "planned" then
    return L("status.map.upcoming")
  elseif norm == "unreleased" then
    return L("status.map.unreleased")
  end
  return type(code) == "string" and code or ""
end

local apiOrder = { "anilist", "kitsu" }
local apiIndex = 0
local lastFailCode = "network"

local function searchNext()
  apiIndex = apiIndex + 1
  local name = apiOrder[apiIndex]
  if name == nil then
    searching = false
    statusMsg = tr("status.search_failed", { code = lastFailCode or "network" })
    render()
    return
  end
  if name == "anilist" then
    searchAnilist()
  else
    searchKitsu()
  end
end

local function searchFinished(items)
  searching = false
  results = items or {}
  if #results == 0 then
    statusMsg = tr("status.search_empty")
  end
  render()
end

local function onSearchResponse(response, parse)
  if not util.statusOk(response) then
    lastFailCode = tostring(response and response.status or "network")
    searchNext()
    return
  end
  local ok, json = pcall(parse)
  if not ok or type(json) ~= "table" then
    lastFailCode = "data"
    searchNext()
    return
  end
  searchFinished(json)
end

function searchAnilist()
  local q = currentQuery()
  local graphql = "query($search:String){Page(page:1,perPage:9){media"
    .. "(search:$search,type:ANIME,sort:POPULARITY_DESC){id title{romaji english native}"
    .. " coverImage{extraLarge large} startDate{year} episodes status averageScore"
    .. " nextAiringEpisode{episode} genres format description siteUrl}}}"
  local body = util.encodeJson({ query = graphql, variables = { search = q } })
  if type(body) ~= "string" or body == "" then
    lastFailCode = "data"
    searchNext()
    return
  end
  local started = util.httpPost(
    "https://graphql.anilist.co",
    body,
    { "Content-Type: application/json", "Accept: application/json" },
    { follow_redirects = true },
    function(response)
      onSearchResponse(response, function()
        local parsed = util.decodeJson(response.body)
        local items = {}
        if type(parsed) == "table" and type(parsed.data) == "table"
          and type(parsed.data.Page) == "table" and type(parsed.data.Page.media) == "table" then
          for _, item in ipairs(parsed.data.Page.media) do
            items[#items + 1] = fromAnilist(item)
          end
        end
        return items
      end)
    end)
  if not started then
    lastFailCode = "network"
    searchNext()
  end
end

function searchKitsu()
  local q = noctalia.string.urlEncode(currentQuery())
  local url = "https://kitsu.io/api/edge/anime?filter[text]=" .. q
    .. "&page[limit]=9&sort=popularityRank"
  local started = util.httpGet(
    url,
    { "Accept: application/vnd.api+json", "Accept: application/json" },
    { follow_redirects = true },
    function(response)
      onSearchResponse(response, function()
        local parsed = util.decodeJson(response.body)
        local items = {}
        if type(parsed) == "table" and type(parsed.data) == "table" then
          local genres = {}
          if type(parsed.included) == "table" then
            for _, entry in ipairs(parsed.included) do
              if type(entry) == "table" and entry.type == "categories"
                and type(entry.attributes) == "table" and type(entry.attributes.title) == "string" then
                genres[entry.id] = entry.attributes.title
              end
            end
          end
          for _, item in ipairs(parsed.data) do
            local anime = fromKitsu(item)
            if #anime.genres > 0 then
              local named = {}
              for _, id in ipairs(anime.genres) do
                if type(genres[id]) == "string" and genres[id] ~= "" then
                  named[#named + 1] = genres[id]
                end
              end
              anime.genres = named
            end
            items[#items + 1] = anime
          end
        end
        return items
      end)
    end)
  if not started then
    lastFailCode = "network"
    searchNext()
  end
end

function runSearch()
  local q = currentQuery()
  if q == "" then
    return
  end
  if not watchAnimeAvailable() then
    notifyStatus("status.no_goanime")
    noctalia.notifyError(L("title"), L("status.no_goanime"))
    return
  end
  searching = true
  selected = nil
  results = {}
  statusMsg = ""
  lastSearched = currentQuery()
  apiIndex = 0
  lastFailCode = "network"
  render()
  searchNext()
end

function onSearch()
  runSearch()
end

function selectResult(entry)
  local anime = results[entry]
  if anime == nil and type(entry) == "table" then
    anime = entry
  end
  if anime == nil then
    return
  end
  selected = anime
  epText = ""
  statusMsg = ""
  resetSelection()
  epPage = 0
  addHistory(anime.query)
  render()
end

function onResultClick(anime)
  selectResult(anime)
end

function renderResultRow(anime)
  local captionParts = {}
  if anime.show_type ~= "" then
    captionParts[#captionParts + 1] = anime.show_type
  end
  if anime.year ~= nil then
    captionParts[#captionParts + 1] = tostring(anime.year)
  end
  if anime.episodes ~= nil then
    captionParts[#captionParts + 1] = tr("result.episodes", { n = tostring(anime.episodes) })
  end
  if anime.score ~= nil then
    captionParts[#captionParts + 1] = "★ " .. tostring(anime.score)
  end
  local poster = posterPathFor(anime)
  local children = {}
  if poster then
    children[#children + 1] = ui.image({ path = poster, width = 46, height = 64, radius = 8, fit = "cover" })
  else
    children[#children + 1] = ui.column({
      width = 46,
      height = 64,
      radius = 8,
      fill = "surface_variant/0.5",
      align = "center",
    }, {
      ui.glyph({ name = "movie", size = 18, color = "on_surface_variant" }),
    })
  end
  local title = anime.title_english ~= "" and anime.title_english or anime.title
  children[#children + 1] = ui.column({ flexGrow = 1, gap = 2 }, {
    ui.label({ text = title, fontWeight = "medium", fontSize = 13, color = "on_surface", maxLines = 2 }),
    ui.label({ text = table.concat(captionParts, "  ·  "), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
  })
  return ui.row({
    gap = 10,
    paddingV = 8,
    paddingH = 10,
    fill = "surface_variant/0.45",
    radius = 10,
    align = "center",
    onClick = function()
      selectResult(anime)
    end,
  }, children)
end

function renderDetail(anime)
  local poster = posterPathFor(anime)
  local title = anime.title_english ~= "" and anime.title_english or anime.title

  local meta = {}
  if anime.show_type ~= "" then
    meta[#meta + 1] = { text = anime.show_type }
  end
  if anime.year ~= nil then
    meta[#meta + 1] = { text = tostring(anime.year) }
  end
  if anime.status ~= "" then
    meta[#meta + 1] = { text = prettyStatus(anime.status) }
  end
  if anime.score ~= nil then
    meta[#meta + 1] = { text = "★ " .. tostring(anime.score) }
  end
  if anime.episodes ~= nil then
    meta[#meta + 1] = { text = tr("detail.episodes", { n = tostring(anime.episodes) }) }
  end

  local metaChildren = {}
  for _, m in ipairs(meta) do
    metaChildren[#metaChildren + 1] = ui.column({
      paddingH = 10,
      paddingV = 2,
      radius = 99,
      fill = "primary/0.12",
    }, {
      ui.label({ text = m.text, fontSize = 11, color = "primary" }),
    })
  end

  local genreText = table.concat(anime.genres, " · ")
  local header = ui.row({ gap = 14, align = "stretch" }, {
    (poster and ui.image({ path = poster, width = 108, height = 152, radius = 12, fit = "cover" })
      or ui.column({
          width = 108,
          height = 152,
          radius = 12,
          fill = "surface_variant/0.5",
          align = "center",
        }, {
          ui.glyph({ name = "movie", size = 28, color = "on_surface_variant" }),
        })),
    ui.column({ flexGrow = 1, gap = 6, align = "stretch" }, {
      ui.label({ text = title, fontSize = 16, fontWeight = "bold", color = "on_surface", maxLines = 2 }),
      ui.row({ gap = 6 }, metaChildren),
      (genreText ~= "" and ui.label({ text = genreText, fontSize = 11, color = "on_surface_variant", maxLines = 2 }) or nil),
      ui.row({ gap = 6 }, {
        ui.button({ text = "MAL", glyph = "external-link", glyphSize = 12, variant = "ghost", onClick = function()
          openUrl(anime.url)
        end }),
      }),
    }),
  })

  local synopsis = anime.synopsis
  if type(synopsis) == "string" and #synopsis > 260 then
    synopsis = synopsis:sub(1, 259) .. "…"
  end

  return ui.column({ gap = 12, align = "stretch" }, {
    header,
    (synopsis ~= "" and ui.label({ text = synopsis, fontSize = 12, color = "on_surface_variant", maxLines = 5 }) or nil),
  })
end

function renderEpisodeGrid(anime)
  local n = anime.episodes
  if type(n) ~= "number" or n <= 0 then
    return ui.label({ text = tr("episodes.unknown"), fontSize = 11, color = "on_surface_variant" })
  end
  local totalPages = math.max(1, math.ceil(n / EP_PAGE_SIZE))
  if epPage < 0 then
    epPage = 0
  elseif epPage > totalPages - 1 then
    epPage = totalPages - 1
  end
  local firstEp = epPage * EP_PAGE_SIZE + 1
  local lastEp = math.min(firstEp + EP_PAGE_SIZE - 1, n)
  local cells = {}
  for i = firstEp, lastEp do
    local isSel = selectMode and selectEps[i] == true
    cells[#cells + 1] = ui.button({
      text = tostring(i),
      width = 48,
      height = 32,
      variant = selectMode and (isSel and "primary" or "secondary") or "ghost",
      tooltip = selectMode
        and tr("episodes.select_hint", { ep = tostring(i) })
        or tr("episodes.watch_hint", { ep = tostring(i) }),
      onClick = function()
        if selectMode then
          toggleSelectEp(i)
        else
          onEpisodeWatchClick(i)
        end
      end,
    })
  end
  local grid = {}
  local perRow = 11
  for start = 1, #cells, perRow do
    local rowChildren = {}
    for i = start, math.min(start + perRow - 1, #cells) do
      rowChildren[#rowChildren + 1] = cells[i]
    end
    grid[#grid + 1] = ui.row({ gap = 6 }, rowChildren)
  end

  local columnChildren = {
    ui.label({ text = tr("detail.episodes", { n = tostring(n) }), fontSize = 12, fontWeight = "medium", color = "on_surface" }),
  }
  if totalPages > 1 then
    columnChildren[#columnChildren + 1] = ui.row({ gap = 6, align = "center" }, {
      ui.button({ glyph = "chevrons-left", glyphSize = 14, variant = "ghost", enabled = epPage > 0, tooltip = L("episodes.page_first"), onClick = "onEpPageFirst" }),
      ui.button({ glyph = "chevron-left", glyphSize = 14, variant = "ghost", enabled = epPage > 0, tooltip = L("episodes.page_prev"), onClick = "onEpPagePrev" }),
      ui.label({ text = tr("episodes.page", { from = tostring(firstEp), to = tostring(lastEp), total = tostring(n) }), fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
      ui.button({ glyph = "chevron-right", glyphSize = 14, variant = "ghost", enabled = epPage < totalPages - 1, tooltip = L("episodes.page_next"), onClick = "onEpPageNext" }),
      ui.button({ glyph = "chevrons-right", glyphSize = 14, variant = "ghost", enabled = epPage < totalPages - 1, tooltip = L("episodes.page_last"), onClick = "onEpPageLast" }),
    })
  end
  for _, row in ipairs(grid) do
    columnChildren[#columnChildren + 1] = row
  end
  return ui.column({ gap = 8, align = "stretch" }, columnChildren)
end

function buildActions(cfg)
  local sourceOptions = {}
  for _, key in ipairs(SOURCE_KEYS) do
    sourceOptions[#sourceOptions + 1] = L(key)
  end
  if selectMode then
    local n = countSelectEps()
    return {
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = L("source.label") .. ":", fontSize = 12, color = "on_surface_variant", width = 56 }),
        ui.select({
          key = "source_select",
          options = sourceOptions,
          selectedIndex = sourceIndex,
          onChange = "onSourceSelect",
        }),
        ui.label({ text = L("quality.label") .. ":", fontSize = 12, color = "on_surface_variant", width = 70 }),
        ui.select({
          key = "quality_select",
          options = QUALITIES,
          selectedIndex = qualityIndex,
          onChange = "onQualitySelect",
        }),
        ui.label({
          text = tr("episodes.selected", { n = tostring(n) }),
          fontSize = 12,
          fontWeight = "medium",
          color = "primary",
          flexGrow = 1,
        }),
      }),
      ui.row({ gap = 8, align = "center" }, {
        ui.button({
          text = tr("download.selected", { n = tostring(n) }),
          glyph = "download",
          variant = "primary",
          enabled = n > 0,
          onClick = "onDownloadSelectedClicked",
        }),
        ui.button({ text = L("download.select_page"), glyph = "checks", variant = "secondary", onClick = "onSelectAllClicked" }),
        ui.button({ text = L("download.select_clear"), glyph = "eraser", variant = "ghost", onClick = "onSelectClearClicked" }),
        ui.button({ text = L("download.select_cancel"), glyph = "close", variant = "ghost", onClick = "onSelectCancelClicked" }),
        ui.spacer(),
      }),
    }
  end
  return {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = L("source.label") .. ":", fontSize = 12, color = "on_surface_variant", width = 56 }),
      ui.select({
        key = "source_select",
        options = sourceOptions,
        selectedIndex = sourceIndex,
        onChange = "onSourceSelect",
      }),
      ui.label({ text = L("quality.label") .. ":", fontSize = 12, color = "on_surface_variant", width = 70 }),
      ui.select({
        key = "quality_select",
        options = QUALITIES,
        selectedIndex = qualityIndex,
        onChange = "onQualitySelect",
      }),
      ui.label({ text = L("episode.label") .. ":", fontSize = 12, color = "on_surface_variant", width = 70 }),
      ui.input({
        key = "episode_input",
        value = epText,
        placeholder = L("episode.placeholder"),
        onChange = "onEpisodeChanged",
        flexGrow = 1,
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.button({ text = L("watch.button"), glyph = "play", variant = "primary", onClick = "onWatchClicked" }),
      ui.button({ text = L("download.button"), glyph = "download", variant = "secondary", onClick = "onDownloadClicked" }),
      ui.button({ text = L("download.all"), glyph = "download", variant = "secondary", onClick = "onDownloadAllClicked" }),
      ui.button({ text = L("download.select"), glyph = "list-check", variant = "ghost", onClick = "onSelectModeClicked" }),
      ui.button({ text = L("open.downloads"), glyph = "folder", variant = "ghost", onClick = "onOpenDownloadsClicked" }),
      ui.spacer(),
    }),
  }
end

-- While the user types (query not yet searched), surface previous searches
-- that match it (case-insensitive) — no fixed history block anymore.
local function historyMatches(query)
  local q = util.trim(query or ""):lower()
  if q == "" then
    return {}
  end
  local out = {}
  for _, entry in ipairs(history) do
    local eq = tostring(entry.q or ""):lower()
    if eq ~= "" and eq:find(q, 1, true) ~= nil then
      out[#out + 1] = entry
      if #out >= 6 then
        break
      end
    end
  end
  return out
end

function buildHistorySuggestions(query)
  local matches = historyMatches(query)
  if #matches == 0 then
    return nil
  end
  local children = {}
  for _, entry in ipairs(matches) do
    children[#children + 1] = ui.button({
      text = entry.q,
      glyph = "history",
      variant = "ghost",
      contentAlign = "start",
      tooltip = entry.q,
      onClick = function()
        onResume(entry.q)
      end,
    })
  end
  return ui.column({ gap = 6, align = "stretch" }, children)
end

function onResume(query)
  raw = query or ""
  selected = nil
  results = {}
  epText = ""
  statusMsg = ""
  resetSelection()
  epPage = 0
  render()
  runSearch()
end

function onQueryChanged(value)
  raw = value or ""
  statusMsg = ""
  render()
end

function onSourceSelect(index, _text)
  sourceIndex = tonumber(index) or 0
  render()
end

function onQualitySelect(index, _text)
  qualityIndex = tonumber(index) or 0
  render()
end

function onEpisodeChanged(value)
  epText = value or ""
end

function onClearClicked()
  raw = ""
  epText = ""
  statusMsg = ""
  selected = nil
  results = {}
  searching = false
  lastSearched = ""
  resetSelection()
  epPage = 0
  render()
end

function onCloseClicked()
  panel.close()
end

render = function()
  local cfg = config()
  if sourceIndex == 0 and qualityIndex == 0 then
    sourceIndex = indexOf(SOURCES, cfg.source)
    qualityIndex = indexOf(QUALITIES, cfg.quality)
  end

  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = "movie", size = 18, color = "primary" }),
        ui.label({ text = L("title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
      }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),

    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = "query_input",
        value = raw,
        placeholder = L("query.placeholder"),
        flexGrow = 1,
        onChange = "onQueryChanged",
        onSubmit = "onSearch",
      }),
      ui.button({ text = L("search.button"), glyph = "search", variant = "secondary", onClick = "onSearch" }),
      ui.button({ glyph = "eraser", glyphSize = 14, variant = "ghost", tooltip = L("clear.button"), onClick = "onClearClicked" }),
    }),
  }

  local body = {}

  if dlActive then
    body[#body + 1] = renderDownloadProgress()
    body[#body + 1] = ui.separator({ spacing = 4 })
  end

  if searching then
    body[#body + 1] = ui.label({ text = L("status.searching"), fontSize = 12, color = "primary" })
  elseif selected ~= nil then
    body[#body + 1] = renderDetail(selected)
    if statusMsg ~= "" and not dlActive then
      body[#body + 1] = ui.label({ text = statusMsg, fontSize = 12, color = "primary", maxLines = 2 })
    end

    for _, child in ipairs(buildActions(cfg)) do
      body[#body + 1] = child
    end
    body[#body + 1] = ui.separator({ spacing = 4 })
    body[#body + 1] = renderEpisodeGrid(selected)
  elseif currentQuery() ~= "" and currentQuery() ~= lastSearched and statusMsg == "" then
    -- Typing a new query: offer past searches that match before searching.
    local sugg = buildHistorySuggestions(currentQuery())
    if sugg ~= nil then
      body[#body + 1] = ui.label({
        text = L("history.suggest_title"),
        fontSize = 12,
        fontWeight = "medium",
        color = "on_surface_variant",
      })
      body[#body + 1] = sugg
    end
  elseif #results > 0 then
    body[#body + 1] = ui.label({
      text = tr("results.title", { q = currentQuery() }),
      fontSize = 12,
      fontWeight = "medium",
      color = "on_surface_variant",
    })
    local rows = {}
    for _, anime in ipairs(results) do
      rows[#rows + 1] = renderResultRow(anime)
    end
    body[#body + 1] = ui.column({ gap = 6, align = "stretch" }, rows)
  elseif currentQuery() ~= "" and statusMsg == "" then
    body[#body + 1] = ui.label({ text = tr("results.empty", { q = currentQuery() }), fontSize = 12, color = "on_surface_variant", maxLines = 2 })
  elseif statusMsg ~= "" then
    body[#body + 1] = ui.label({ text = statusMsg, fontSize = 12, color = "primary", maxLines = 2 })
  else
    body[#body + 1] = ui.label({ text = L("launcher.hint"), fontSize = 12, color = "on_surface_variant", maxLines = 2 })
  end

  children[#children + 1] = ui.scroll({ flexGrow = 1, gap = 12, align = "stretch" }, body)

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

function onOpen(_)
  loadHistory()
  -- Second ticks drive the live download-progress bar while the panel is open.
  panel.setWantsSecondTicks(true)
  loadDlState()
  -- A previous session may have left a goanime-stream build running; tell the
  -- user as soon as the panel notices the binary is finally there.
  local marker = streamBuildMarker()
  local hadBuild = marker ~= nil and noctalia.fileExists(marker)
  if streamInstallSent or hadBuild then
    if streamBinary() ~= nil then
      streamInstallSent = false
      streamCleanup()
      noctalia.notify(L("title"), L("stream.ready"))
    elseif hadBuild then
      streamCleanup() -- stale marker (build failed) — the next Watch retries
    end
  end
  local pending = noctalia.state.get("watch_anime_pending_query")
  if type(pending) == "string" and pending ~= "" then
    raw = pending
    noctalia.state.set("watch_anime_pending_query", "")
    loadHistory()
    runSearch()
  else
    -- Refresh so a resumed download bar / status shows immediately on reopen.
    render()
  end
end

noctalia.state.watch("watch_anime_pending_query", function(value)
  if type(value) == "string" and value ~= "" then
    raw = value
    noctalia.state.set("watch_anime_pending_query", "")
    render()
    runSearch()
  end
end)

render()