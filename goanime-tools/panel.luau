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
-- Type `/goanime <query>` in the launcher to open the panel.
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
local showHistory = true
local selected = nil
local results = {}
local searching = false
local render = nil

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

-- History is shown by default; a panel toggle (header of the history section)
-- hides it and remembers the choice in the plugin data dir, like history.json.
local histVisibleFile = nil

local function historyVisiblePath()
  if histVisibleFile ~= nil then
    return histVisibleFile
  end
  local dir = noctalia.pluginDataDir()
  if type(dir) == "string" and dir ~= "" then
    histVisibleFile = dir .. "/history-visible.json"
  else
    histVisibleFile = ""
  end
  return histVisibleFile
end

local function loadHistoryVisible()
  local p = historyVisiblePath()
  if p == "" then
    return
  end
  local text = noctalia.readFile(p)
  if text == "false" then
    showHistory = false
  end
end

local function saveHistoryVisible()
  local p = historyVisiblePath()
  if p == "" then
    return
  end
  noctalia.writeFile(p, showHistory and "true" or "false")
end

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
    return home .. "/.local/goanime/downloads/anime"
  end
  return ""
end

local function notifyStatus(key, subst)
  statusMsg = tr(key, subst)
  render()
end

local function goanimeAvailable()
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

local function goanimeQuery()
  if selected and selected.query ~= "" then
    return selected.query
  end
  return currentQuery()
end

local function goanimeParts(spec, cfg)
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
  parts[#parts + 1] = util.shellQuote(goanimeQuery())
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
  local dir = base .. "/goanime-tools/watch"
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
  parts[#parts + 1] = util.shellQuote(goanimeQuery())
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
  args[#args + 1] = util.shellQuote(goanimeQuery())
  args[#args + 1] = epNum
  -- < /dev/null guarantees goanime-stream never hangs waiting for a TTY.
  return logAppend(table.concat(args, " ") .. " < /dev/null")
end

function onWatch()
  local query = currentQuery()
  if query == "" and not (selected and selected.query ~= "") then
    return
  end
  if not goanimeAvailable() then
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
  addHistory(goanimeQuery())
  noctalia.runAsync(cmd)
  statusMsg = note or ""
  render()
  noctalia.notify(L("title"), tr("status.watching", { q = goanimeQuery() }))
end

function onWatchClicked()
  onWatch()
end

function onDownload()
  local query = currentQuery()
  if query == "" and not (selected and selected.query ~= "") then
    return
  end
  if not goanimeAvailable() then
    notifyStatus("status.no_goanime")
    noctalia.notifyError(L("title"), L("status.no_goanime"))
    return
  end
  local spec = episodeSpec()
  if spec == nil then
    notifyStatus("status.bad_episodes")
    return
  end
  local cfg = config()

  addHistory(goanimeQuery())

  noctalia.runAsync(logAppend(table.concat(goanimeParts(spec, cfg), " ")))

  statusMsg = ""
  render()
  noctalia.notify(L("title"), tr("status.downloading", { q = goanimeQuery() }))

  if cfg.openAfter then
    openFolder(downloadsFolder(cfg))
  end
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
    episodes = item.episodes,
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
    .. " genres format description siteUrl}}}"
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
  if not goanimeAvailable() then
    notifyStatus("status.no_goanime")
    noctalia.notifyError(L("title"), L("status.no_goanime"))
    return
  end
  searching = true
  selected = nil
  results = {}
  statusMsg = ""
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
  local display = math.min(n, 400)
  local cells = {}
  for i = 1, display do
    cells[#cells + 1] = ui.button({
      text = tostring(i),
      width = 42,
      height = 32,
      variant = "ghost",
      tooltip = tr("episodes.watch_hint", { ep = tostring(i) }),
      onClick = function()
        onEpisodeWatchClick(i)
      end,
    })
  end
  local grid = {}
  local perRow = 12
  for start = 1, #cells, perRow do
    local rowChildren = {}
    for i = start, math.min(start + perRow - 1, #cells) do
      rowChildren[#rowChildren + 1] = cells[i]
    end
    grid[#grid + 1] = ui.row({ gap = 6 }, rowChildren)
  end
  local header = ui.label({ text = tr("detail.episodes", { n = tostring(n) }), fontSize = 12, fontWeight = "medium", color = "on_surface" })
  if n > display then
    return ui.column({ gap = 8, align = "stretch" }, {
      header,
      ui.scroll({ flexGrow = 1, gap = 6, align = "stretch" }, grid),
      ui.label({ text = tr("episodes.more", { shown = tostring(display), total = tostring(n) }), fontSize = 11, color = "on_surface_variant" }),
    })
  end
  local columnChildren = { header }
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
  local actions = {
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
      ui.button({ text = L("open.downloads"), glyph = "folder", variant = "ghost", onClick = "onOpenDownloadsClicked" }),
      ui.spacer(),
    }),
  }
  return actions
end

function buildHistoryEntries()
  local children = {}
  if #history == 0 then
    children[#children + 1] = ui.label({
      text = L("history.empty"),
      fontSize = 12,
      color = "on_surface_variant",
      maxLines = 2,
    })
  else
    for _, entry in ipairs(history) do
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
  end
  return ui.column({ gap = 6, align = "stretch" }, children)
end

-- Collapsible history: the toggle row stays visible so the section can always
-- be brought back.
function buildHistorySection()
  return ui.column({ gap = 6, align = "stretch" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.toggle({
        checked = showHistory,
        tooltip = L("history.toggle"),
        onChange = "onToggleHistory",
      }),
      ui.label({
        text = L("history.title"),
        fontSize = 13,
        fontWeight = "medium",
        color = "on_surface",
        flexGrow = 1,
      }),
    }),
    showHistory and buildHistoryEntries() or nil,
  })
end

function onToggleHistory(value)
  showHistory = value == true
  saveHistoryVisible()
  render()
end

function onResume(query)
  raw = query or ""
  selected = nil
  results = {}
  epText = ""
  statusMsg = ""
  render()
  runSearch()
end

function onQueryChanged(value)
  raw = value or ""
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

  if searching then
    body[#body + 1] = ui.label({ text = L("status.searching"), fontSize = 12, color = "primary" })
  elseif selected ~= nil then
    body[#body + 1] = renderDetail(selected)
    if statusMsg ~= "" then
      body[#body + 1] = ui.label({ text = statusMsg, fontSize = 12, color = "primary", maxLines = 2 })
    end

    for _, child in ipairs(buildActions(cfg)) do
      body[#body + 1] = child
    end
    body[#body + 1] = ui.separator({ spacing = 4 })
    body[#body + 1] = renderEpisodeGrid(selected)
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
  end

  children[#children + 1] = ui.scroll({ flexGrow = 1, gap = 12, align = "stretch" }, body)

  children[#children + 1] = ui.separator({ spacing = 2 })
  children[#children + 1] = buildHistorySection()

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

function onOpen(_)
  loadHistory()
  loadHistoryVisible()
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
  local pending = noctalia.state.get("goanime_pending_query")
  if type(pending) == "string" and pending ~= "" then
    raw = pending
    noctalia.state.set("goanime_pending_query", "")
    loadHistory()
    render()
    runSearch()
  end
end

noctalia.state.watch("goanime_pending_query", function(value)
  if type(value) == "string" and value ~= "" then
    raw = value
    noctalia.state.set("goanime_pending_query", "")
    render()
    runSearch()
  end
end)

render()