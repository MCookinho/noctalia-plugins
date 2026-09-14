--!nonstrict
-- GoAnime Tools panel.
--
-- Search for an anime and either open GoAnime's own picker in a terminal
-- (Watch) or start a headless download from here: single episode, a range,
-- or the whole show - with chosen source, quality and output folder.
-- Type `/goanime <query>` in the launcher to open this panel pre-filled.
local util = require("./lib/util.luau")

local SOURCES = { "all", "allanime", "animefire", "goyabu" }
local SOURCE_KEYS = { "source.all", "source.allanime", "source.animefire", "source.goyabu" }
local QUALITIES = { "best", "worst", "1080p", "720p", "480p" }

local function L(key)
  return noctalia.tr(key)
end

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local raw = ""
local sourceIndex = 0
local qualityIndex = 0
local epText = ""
local statusMsg = ""
local history = {}
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
  parts[#parts + 1] = util.shellQuote(currentQuery())
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

local function playOneLiner(parts, cfg)
  local dir = downloadsFolder(cfg)
  local oneLiner = "DLDIR=" .. util.shellQuote(dir)
    .. "; " .. table.concat(parts, " ")
    .. "; L=$(ls -1t \"$DLDIR\"/*.mp4 2>/dev/null | head -1)"
    .. "; [ -n \"$L\" ] && { if command -v mpv >/dev/null 2>&1; then exec mpv \"$L\"; else exec xdg-open \"$L\"; fi; }; exit 0"
  return "nohup bash -c " .. util.shellQuote(oneLiner) .. " >/dev/null 2>&1 &"
end

function onWatch()
  local query = currentQuery()
  if query == "" then
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
  addHistory(query)
  noctalia.runAsync(playOneLiner(goanimeParts(spec, cfg), cfg))
  statusMsg = ""
  render()
  noctalia.notify(L("title"), tr("status.watching", { q = query }))
end

function onWatchClicked()
  onWatch()
end

function onDownload()
  local query = currentQuery()
  if query == "" then
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

  addHistory(query)

  noctalia.runAsync(logAppend(table.concat(goanimeParts(spec, cfg), " ")))

  statusMsg = ""
  render()
  noctalia.notify(L("title"), tr("status.downloading", { q = query }))

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

function onResume(query)
  raw = query or ""
  epText = ""
  render()
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
  render()
end

function onCloseClicked()
  panel.close()
end

local function sourceOptions()
  local out = {}
  for _, key in ipairs(SOURCE_KEYS) do
    out[#out + 1] = L(key)
  end
  return out
end

local function buildActions(cfg)
  local source = SOURCES[sourceIndex + 1]
  if source == nil then
    source = cfg.source
  end
  local quality = QUALITIES[qualityIndex + 1]
  if quality == nil then
    quality = cfg.quality
  end
  local actions = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = L("source.label") .. ":", fontSize = 12, color = "on_surface_variant", width = 56 }),
      ui.select({
        key = "source_select",
        options = sourceOptions(),
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

local function buildHistorySection()
  local children = {
    ui.label({ text = L("history.title"), fontSize = 13, fontWeight = "medium", color = "on_surface" }),
  }
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
        justify = "start",
        tooltip = entry.q,
        onClick = function()
          onResume(entry.q)
        end,
      })
    end
  end
  return ui.column({ gap = 6, align = "stretch" }, children)
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
        onSubmit = "onWatch",
      }),
      ui.button({ glyph = "eraser", glyphSize = 14, variant = "ghost", tooltip = L("clear.button"), onClick = "onClearClicked" }),
    }),
  }

  if util.trim(raw) ~= "" then
    for _, child in ipairs(buildActions(cfg)) do
      children[#children + 1] = child
    end
    if statusMsg ~= "" then
      children[#children + 1] = ui.label({ text = statusMsg, fontSize = 12, color = "primary", maxLines = 2 })
    end
  end

  children[#children + 1] = buildHistorySection()

  children[#children + 1] = ui.label({
    text = L("footer.note"),
    fontSize = 11,
    color = "on_surface_variant",
    maxLines = 3,
  })

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

function onOpen(_)
  loadHistory()
  local pending = noctalia.state.get("goanime_pending_query")
  if type(pending) == "string" and pending ~= "" then
    raw = pending
    noctalia.state.set("goanime_pending_query", "")
    render()
  end
end

noctalia.state.watch("goanime_pending_query", function(value)
  if type(value) == "string" and value ~= "" then
    raw = value
    noctalia.state.set("goanime_pending_query", "")
    render()
  end
end)

render()