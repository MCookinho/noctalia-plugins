--!nonstrict
-- GoAnime Tools panel.
--
-- Search an anime through MyAnimeList (Jikan, key-free), browse a pretty
-- result card with poster, synopsis, genres and an episode grid, then either
-- open the player (mpv / system default) or download headless via the GoAnime
-- CLI - always from this panel, never a terminal.
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
  noctalia.runAsync(playOneLiner(goanimeParts(spec, cfg), cfg))
  statusMsg = ""
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
  render()
  local url = "https://api.jikan.moe/v4/anime?q=" .. noctalia.string.urlEncode(q)
    .. "&limit=9&order_by=members&sort=desc&sfw=true"
  local started = util.httpGet(url, nil, { follow_redirects = true }, function(response)
    searching = false
    if not util.statusOk(response) then
      statusMsg = tr("status.search_failed", { code = tostring(response and response.status) })
      render()
      return
    end
    local json = util.decodeJson(response and response.body)
    if type(json) ~= "table" or type(json.data) ~= "table" then
      statusMsg = tr("status.search_empty")
      render()
      return
    end
    results = {}
    for _, item in ipairs(json.data) do
      results[#results + 1] = cleanAnime(item)
    end
    if #results == 0 then
      statusMsg = tr("status.search_empty")
    end
    render()
  end)
  if not started then
    searching = false
    statusMsg = tr("status.search_failed", { code = "request" })
    render()
  end
end

function onSearch()
  runSearch()
end

function selectResult(index)
  local anime = results[index]
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
    meta[#meta + 1] = { text = anime.status }
  end
  if anime.score ~= nil then
    meta[#meta + 1] = { text = "★ " .. tostring(anime.score) }
  end
  if anime.episodes ~= nil then
    meta[#meta + 1] = { text = tr("detail.episodes", { n = tostring(anime.episodes) }) }
  end

  local metaChildren = {}
  for _, m in ipairs(meta) do
    metaChildren[#metaChildren + 1] = ui.label({
      text = m.text,
      fontSize = 11,
      color = "primary",
      fill = "primary/0.12",
      radius = 99,
      padding = { 2, 10 },
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
      ui.row({ wrap = true, gap = 6 }, metaChildren),
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
  return ui.column({ gap = 8, align = "stretch" }, {
    header,
    grid,
  })
end

function buildActions(cfg)
  local actions = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = L("source.label") .. ":", fontSize = 12, color = "on_surface_variant", width = 56 }),
      ui.select({
        key = "source_select",
        options = { L("source.all"), L("source.allanime"), L("source.animefire"), L("source.goyabu") },
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

function buildHistorySection()
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