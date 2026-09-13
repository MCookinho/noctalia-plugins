--!nonstrict
-- OSINT Tools dashboard panel.
--
-- Search by username / e-mail / CPF / phone, querying public key-free sources
-- (GitHub, GitLab, Hacker News, PyPI, npm, Keybase, Bluesky, Mastodon,
-- Telegram, Gravatar, DoH-MX, GitHub followers). Results are rendered as a
-- Maltego-style relationship graph (hub + rings of platform/entity/person
-- nodes). Click a node to inspect its details.
-- Use for legal, ethical research only. Respect privacy laws (e.g. LGPD).
local util = require("./lib/util.luau")
local detect = require("./lib/detect.luau")
local brazil = require("./lib/brazil.luau")
local platforms = require("./lib/platforms.luau")
local analyzers = require("./lib/analyzers.luau")
local people = require("./lib/people.luau")

local TYPE_OPTIONS = { "auto", "username", "email", "cpf", "phone" }
local TYPE_GLYPHS = { auto = "wifi", username = "at", email = "mail", cpf = "id", phone = "phone" }

local NODE_W = 116
local NODE_GAP = 10
local RING_MAX = 4

local function L(key)
  return noctalia.tr(key)
end

local raw = ""
local typeIndex = 0
local analyzing = false
local analyzingFinished = false
local lastSummary = nil
local cards = {}
local detected = nil
local peopleNodes = {}
local selected = nil

local avatarPaths = {}
local avatarInflight = {}
local avatarCacheDir = nil

local function avatarDir()
  if avatarCacheDir then
    return avatarCacheDir
  end
  local dir = noctalia.pluginDataDir()
  if dir then
    avatarCacheDir = dir .. "/avatars"
    noctalia.mkdirAll(avatarCacheDir)
  end
  return avatarCacheDir
end

local pool = util.makePool(5)

local function requestAvatar(url)
  if avatarPaths[url] ~= nil or avatarInflight[url] ~= nil then
    return
  end
  local dir = avatarDir()
  if dir == nil then
    return
  end
  local dest = dir .. "/" .. util.md5Hex(url) .. ".jpg"
  if noctalia.fileExists(dest) then
    avatarPaths[url] = dest
    return
  end
  avatarInflight[url] = true
  pool.submit(function(done)
    local started = noctalia.download(url, dest, function(ok)
      avatarInflight[url] = nil
      if ok then
        avatarPaths[url] = dest
        render()
      end
      done()
    end)
    if not started then
      avatarInflight[url] = nil
    end
    return started
  end)
end

local function openUrl(url)
  if type(url) ~= "string" or url == "" then
    return
  end
  noctalia.runAsync("xdg-open " .. util.shellQuote(url))
end

local function copyText(text)
  if text == nil then
    return
  end
  local ok = noctalia.copyToClipboard(tostring(text), "text/plain")
  if not ok then
    noctalia.notifyError(L("title"), L("copy.failed"))
  end
end

local function statusCaption(card)
  if card.found then
    return ui.label({ text = L("status.found"), fontSize = 11, color = "primary" })
  end
  return ui.label({ text = L("status.miss"), fontSize = 11, color = "on_surface_variant" })
end

local function copyButton(value)
  return ui.button({
    glyph = "copy",
    glyphSize = 12,
    variant = "ghost",
    tooltip = L("tooltip.copy"),
    onClick = function()
      copyText(value)
    end,
  })
end

local function rowView(row)
  local children = {
    ui.label({ text = row.label .. ":", fontSize = 12, color = "on_surface_variant", width = 132 }),
    ui.label({ text = tostring(row.value or ""), fontSize = 12, color = "on_surface", maxLines = 6, flexGrow = 1 }),
  }
  if row.copy ~= nil then
    children[#children + 1] = copyButton(row.copy)
  end
  return ui.row({ gap = 8, align = "center" }, children)
end

local function cardView(card)
  local header = {
    ui.glyph({
      name = card.glyph or "circle",
      size = 16,
      color = card.found and "primary" or "on_surface_variant",
    }),
    ui.label({ text = card.title, fontWeight = "medium", fontSize = 13, color = "on_surface", flexGrow = 1 }),
    statusCaption(card),
  }
  if card.url then
    header[#header + 1] = ui.button({
      glyph = "external-link",
      glyphSize = 12,
      variant = "ghost",
      tooltip = card.url,
      onClick = function()
        openUrl(card.url)
      end,
    })
  end
  local children = {
    ui.row({ gap = 8, align = "center" }, header),
  }

  if card.avatar and avatarPaths[card.avatar] then
    table.insert(children, ui.image({
      path = avatarPaths[card.avatar],
      width = 56,
      height = 56,
      radius = 28,
      fit = "cover",
    }))
  end

  if card.rows then
    for _, row in ipairs(card.rows) do
      table.insert(children, rowView(row))
    end
  end

  if card.note then
    table.insert(children, ui.label({
      text = L(card.note),
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 2,
    }))
  end

  return ui.column({
    fill = "surface_variant/0.6",
    radius = 14,
    padding = 12,
    gap = 8,
    key = card.title .. (card.url or ""),
  }, children)
end

local function shortLine(text, max)
  local s = tostring(text or "")
  if #s > max then
    s = s:sub(1, max - 1) .. "…"
  end
  return s
end

local function avatarCircle(url, size, glyph, found, isSelected)
  local localPath = url and avatarPaths[url]
  if localPath then
    return ui.image({
      path = localPath,
      width = size,
      height = size,
      radius = math.floor(size / 2),
      fit = "cover",
    })
  end
  return ui.column({
    width = size,
    height = size,
    radius = math.floor(size / 2),
    fill = found and "primary/0.16" or "surface_variant/0.5",
    borderWidth = isSelected and 3 or 2,
    border = isSelected and "primary" or (found and "primary/0.7" or "outline"),
    align = "center",
    justify = "center",
  }, {
    ui.glyph({ name = glyph or "circle", size = math.floor(size * 0.42), color = found and "primary" or "on_surface_variant" }),
  })
end

local function toggleSelect(card)
  if selected == card then
    selected = nil
  else
    selected = card
  end
  render()
end

local function graphNode(node)
  local isSelected = selected == node.card
  return ui.column({
    key = node.key,
    width = NODE_W,
    align = "center",
    gap = 4,
    radius = 12,
    paddingH = 4,
    paddingV = 6,
    onClick = function()
      toggleSelect(node.card)
    end,
  }, {
    ui.box({ width = 2, height = 12, fill = "outline", opacity = 0.6 }),
    avatarCircle(node.avatar, 52, node.glyph, node.found, isSelected),
    ui.label({
      text = shortLine(node.title, 24),
      fontSize = 12,
      fontWeight = node.found and "medium" or "normal",
      color = node.found and "on_surface" or "on_surface_variant",
      maxLines = 1,
    }),
    ui.label({ text = shortLine(node.subtitle, 28), fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
  })
end

local function ringRow(nodes)
  local total = #nodes * NODE_W + (#nodes - 1) * NODE_GAP
  local cols = {}
  for _, node in ipairs(nodes) do
    table.insert(cols, graphNode(node))
  end
  local children = {
    ui.row({ key = "crown", align = "center", justify = "center" }, {
      ui.box({ width = total, height = 2, radius = 1, fill = "outline", opacity = 0.8 }),
    }),
    ui.row({ key = "nodes", gap = NODE_GAP, align = "center", justify = "center" }, cols),
  }
  return ui.column({ align = "center", gap = 4 }, children)
end

local function ringSection(titleKey, nodes)
  local children = {
    ui.label({ text = L(titleKey), fontSize = 11, fontWeight = "medium", color = "on_surface_variant" }),
  }
  local chunks = {}
  for i = 1, #nodes, RING_MAX do
    local chunk = {}
    for j = i, math.min(i + RING_MAX - 1, #nodes) do
      table.insert(chunk, nodes[j])
    end
    table.insert(chunks, chunk)
  end
  for _, chunk in ipairs(chunks) do
    table.insert(children, ringRow(chunk))
  end
  return ui.column({ key = "ring-" .. titleKey, align = "center", gap = 10 }, children)
end

local function cardSubtitle(card)
  if type(card.rows) == "table" then
    for _, row in ipairs(card.rows) do
      local value = tostring(row.value or "")
      if value ~= "" then
        return shortLine(value, 26)
      end
    end
  end
  return card.note and L(card.note) or ""
end

local function personCard(p)
  local rows = {}
  table.insert(rows, { label = L("row.handle"), value = p.login, copy = p.login })
  if type(p.name) == "string" and p.name ~= "" then
    table.insert(rows, { label = L("row.name"), value = p.name })
  end
  table.insert(rows, { label = L("row.source"), value = "GitHub" })
  if type(p.url) == "string" and p.url ~= "" then
    table.insert(rows, { label = L("row.url"), value = p.url })
  end
  return {
    title = p.login,
    glyph = "user",
    kind = "person",
    found = true,
    url = (type(p.url) == "string" and p.url ~= "") and p.url or ("https://github.com/" .. p.login),
    avatar = p.avatar,
    rows = rows,
    note = "note_people",
  }
end

local function hubView()
  local avatarUrl = nil
  for _, card in ipairs(cards) do
    if card.found and card.avatar and card.kind ~= "identity" then
      avatarUrl = card.avatar
      break
    end
  end
  local parts = {}
  for _, card in ipairs(cards) do
    if card.found and card.kind ~= "identity" and #parts < 4 then
      table.insert(parts, card.title)
    end
  end
  local caption = L("type." .. detected.type)
  if #parts > 0 then
    caption = caption .. " · " .. table.concat(parts, " · ")
  end
  local children = {
    avatarCircle(avatarUrl, 72, TYPE_GLYPHS[detected.type] or "at", true, false),
    ui.label({
      text = shortLine(detected.display, 44),
      fontSize = 18,
      fontWeight = "bold",
      color = "on_surface",
      textAlign = "center",
      maxWidth = 500,
      maxLines = 2,
    }),
    ui.label({ text = caption, fontSize = 11, color = "on_surface_variant", textAlign = "center", maxWidth = 500, maxLines = 2 }),
    ui.box({ width = 2, height = 24, fill = "outline", opacity = 0.8 }),
  }
  return ui.column({ key = "hub", align = "center", gap = 6 }, children)
end

local function centerBlock(key, node)
  return ui.row({ key = key, justify = "center", align = "center" }, { node })
end

local function networkView()
  local serviceNodes = {}
  for _, card in ipairs(cards) do
    if card.kind ~= "identity" and card.found then
      table.insert(serviceNodes, {
        key = "card:" .. (card.title .. (card.url or "")),
        title = card.title,
        subtitle = cardSubtitle(card),
        glyph = card.glyph or "circle",
        found = card.found,
        avatar = card.avatar,
        card = card,
      })
    end
  end
  local personNodes = {}
  for _, p in ipairs(peopleNodes) do
    local card = personCard(p)
    table.insert(personNodes, {
      key = "person:" .. p.login,
      title = p.login,
      subtitle = (type(p.name) == "string" and p.name ~= "") and p.name or "GitHub",
      glyph = "user",
      found = true,
      avatar = p.avatar,
      card = card,
    })
  end

  local children = { centerBlock("hub-center", hubView()) }
  if #serviceNodes > 0 then
    table.insert(children, centerBlock("ring-services-center", ringSection("graph.services", serviceNodes)))
  end
  if #personNodes > 0 then
    table.insert(children, centerBlock("ring-people-center", ringSection("graph.people", personNodes)))
  end
  if selected then
    table.insert(children, cardView(selected))
  end

  return ui.column({ flexGrow = 1, fill = "surface_variant/0.25", radius = 16, padding = 18, gap = 14, align = "stretch" }, children)
end

local function identityRows()
  local rows = {}
  if detected then
    table.insert(rows, { label = L("row.type"), value = L("type." .. detected.type) })
    table.insert(rows, { label = L("row.value"), value = detected.display, copy = detected.display })
  end
  return rows
end

local function buildTypeOptions()
  local out = {}
  for _, key in ipairs(TYPE_OPTIONS) do
    out[#out + 1] = L("type_options." .. key)
  end
  return out
end

local function render()
  local typeOptions = buildTypeOptions()
  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = L("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),

    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = "query_input",
        value = raw,
        placeholder = L("search.placeholder"),
        flexGrow = 1,
        onChange = "onQueryChanged",
        onSubmit = "onQuerySubmit",
      }),
      ui.select({
        key = "type_select",
        options = typeOptions,
        selectedIndex = typeIndex,
        onChange = "onTypeSelect",
        width = 150,
      }),
    }),

    ui.row({ gap = 8, align = "center" }, {
      ui.button({ text = L("search.button"), glyph = "search", variant = "primary", onClick = "onSearchClicked", enabled = not analyzing }),
      ui.button({ text = L("clear.button"), variant = "ghost", onClick = "onClearClicked", enabled = #cards > 0 }),
    }),

    ui.row({ gap = 8, align = "center" }, {
      (function()
        if analyzing then
          return ui.label({ text = L("analyzing"), color = "primary", fontSize = 12 })
        elseif lastSummary then
          return ui.label({ text = lastSummary, color = "on_surface_variant", fontSize = 12 })
        else
          return ui.label({ text = L("empty.prompt"), color = "on_surface_variant", fontSize = 12 })
        end
      end)(),
      ui.spacer(),
    }),
  }

  if #cards > 0 then
    table.insert(children, ui.scroll({ flexGrow = 1, gap = 10, align = "stretch" }, {
      networkView(),
    }))
  else
    table.insert(children, ui.column({ flexGrow = 1, fill = "surface_variant/0.4", radius = 14, align = "center", justify = "center", gap = 8 }, {
      ui.glyph({ name = "user-search", size = 48, color = "on_surface_variant/0.6" }),
      ui.label({ text = L("empty.title"), fontSize = 14, fontWeight = "medium", color = "on_surface" }),
      ui.label({ text = L("empty.subtitle"), fontSize = 12, color = "on_surface_variant", textAlign = "center", maxWidth = 380 }),
    }))
  end

  table.insert(children, ui.label({ text = L("footer.legal"), fontSize = 11, color = "on_surface_variant", maxLines = 2 }))

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

local function loadConfig()
  return {
    site_checks = noctalia.getConfig("site_checks") ~= false,
  }
end

local function displayFor(detectedType, value)
  if detectedType == "username" then
    return "@" .. value
  elseif detectedType == "cpf" then
    local digits = brazil.onlyDigits(value)
    if #digits == 11 then
      return brazil.cpfFormat(digits)
    end
    return value
  elseif detectedType == "phone" then
    local parsed = brazil.phoneParse(value)
    if parsed then
      return parsed.national
    end
    return value
  end
  return value
end

local function analyzeDone()
  analyzing = false
  local foundTotal = 0
  local cardTotal = 0
  for _, card in ipairs(cards) do
    if card.kind ~= "identity" then
      cardTotal = cardTotal + 1
      if card.found then
        foundTotal = foundTotal + 1
      end
    end
  end
  lastSummary = noctalia.tr("summary.found", { n = tostring(foundTotal), t = tostring(cardTotal) })
  if #peopleNodes > 0 then
    lastSummary = lastSummary .. " · " .. noctalia.trp("summary.people", #peopleNodes, {})
  end
  render()
end

local function analyze()
  local value = noctalia.string.trim(raw)
  if value == "" then
    return
  end

  cards = {}
  detected = nil
  peopleNodes = {}
  selected = nil
  analyzing = true
  analyzingFinished = false
  lastSummary = nil
  noctalia.state.set("pending_query", "")
  render()

  local config = loadConfig()
  local resolvedType = TYPE_OPTIONS[typeIndex + 1] or "auto"
  if resolvedType == "auto" then
    resolvedType = detect.detect(value) or "username"
  end

  detected = {
    type = resolvedType,
    display = displayFor(resolvedType, value),
  }

  local asyncPool = util.makePool(5)
  local pending = 0
  local looping = true

  local function fulfill()
    pending = pending - 1
    if not looping then
      maybeFinish()
    end
  end

  local function maybeFinish()
    if pending <= 0 and not analyzingFinished then
      analyzingFinished = true
      analyzeDone()
    end
  end

  local function deliver(card)
    card.kind = card.kind or "platform"
    table.insert(cards, card)
    if card.avatar then
      requestAvatar(card.avatar)
    end
  end

  local function dispatch(startOp, opDone)
    pending = pending + 1
    asyncPool.submit(function(done)
      local finished = false
      local function mark()
        if finished then
          return
        end
        finished = true
        if opDone then
          opDone()
        end
        fulfill()
        done()
      end
      local started = startOp(mark)
      if not started then
        mark()
      end
      return started
    end)
  end

  local ctx = { dispatch = dispatch, deliver = deliver, config = config }

  deliver({
    title = L("identity.title"),
    glyph = TYPE_GLYPHS[resolvedType] or "search",
    kind = "identity",
    found = true,
    rows = identityRows(),
  })

  if resolvedType == "username" then
    if config.site_checks then
      for _, platform in ipairs(platforms.buildUsernameChecks()) do
        dispatch(function(opFinished)
          return platform.check(value, function(card)
            deliver(card)
            opFinished()
          end)
        end)
      end
      for _, personCheck in ipairs(people.buildUsernamePeopleChecks()) do
        dispatch(function(opFinished)
          return personCheck.check(value, function(list)
            for _, p in ipairs(list) do
              table.insert(peopleNodes, p)
              if p.avatar then
                requestAvatar(p.avatar)
              end
            end
            opFinished()
          end)
        end)
      end
    end
  elseif resolvedType == "email" then
    dispatch(function(opFinished)
      return analyzers.email(value, ctx).start(opFinished)
    end)
  elseif resolvedType == "cpf" then
    dispatch(function(opFinished)
      return analyzers.cpf(value, ctx).start(opFinished)
    end)
  elseif resolvedType == "phone" then
    dispatch(function(opFinished)
      return analyzers.phone(value, ctx).start(opFinished)
    end)
  end

  looping = false
  maybeFinish()
end

function onOpen(_context)
  render()
  local pendingQuery = noctalia.state.get("pending_query")
  if type(pendingQuery) == "string" and pendingQuery ~= "" then
    raw = pendingQuery
    analyze()
  end
end

noctalia.state.watch("pending_query", function(value)
  if type(value) == "string" and value ~= "" then
    raw = value
    analyze()
  end
end)

function onQueryChanged(value)
  raw = value or ""
end

function onQuerySubmit(value)
  raw = noctalia.string.trim(value or "")
  analyze()
end

function onSearchClicked()
  analyze()
end

function onTypeSelect(index, _text)
  typeIndex = tonumber(index) or 0
  render()
end

function onClearClicked()
  raw = ""
  cards = {}
  detected = nil
  peopleNodes = {}
  selected = nil
  lastSummary = nil
  render()
end

function onCloseClicked()
  panel.close()
end

render()