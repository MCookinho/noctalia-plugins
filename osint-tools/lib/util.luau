--!nonstrict
-- Shared plumbing: HTTP helpers, a bounded async task pool, shell quoting.
local M = {}

function M.trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return noctalia.string.trim(value)
end

function M.httpGet(url, headers, opts, cb)
  local req = { url = url, headers = headers or { "Accept: application/json" } }
  if opts then
    if opts.follow_redirects then
      req.follow_redirects = true
    end
    if opts.allow_insecure_tls then
      req.allow_insecure_tls = true
    end
  end
  return noctalia.http(req, function(response)
    cb(response)
  end)
end

function M.statusOk(response)
  return response ~= nil and response.status ~= nil
    and response.status >= 200 and response.status < 300
end

function M.decodeJson(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local decoded, err = noctalia.json.decode(text)
  if decoded == nil then
    return nil, err
  end
  return decoded
end

function M.makePool(maxConcurrent)
  local pool = { max = maxConcurrent or 6, queue = {}, active = 0 }

  function pool.drain()
    while pool.active < pool.max and #pool.queue > 0 do
      local factory = table.remove(pool.queue, 1)
      pool.active = pool.active + 1
      local started = factory(function()
        pool.active = pool.active - 1
        pool.drain()
      end)
      if not started then
        pool.active = pool.active - 1
        pool.drain()
      end
    end
  end

  function pool.submit(factory)
    table.insert(pool.queue, factory)
    pool.drain()
  end

  return pool
end

function M.shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.toText(value)
  if value == nil then
    return ""
  end
  if type(value) == "boolean" then
    return value and "true" or "false"
  end
  if type(value) == "table" then
    local parts = {}
    for k, v in pairs(value) do
      if type(k) == "string" and type(v) ~= "table" then
        parts[#parts + 1] = k .. ": " .. M.toText(v)
      end
    end
    table.sort(parts)
    return table.concat(parts, ", ")
  end
  return tostring(value)
end

function M.flattenJson(json, limit)
  local rows = {}
  local count = 0
  if type(json) ~= "table" then
    return rows
  end
  for k, v in pairs(json) do
    if count >= (limit or 14) then
      break
    end
    if type(k) == "string" and type(v) ~= "table" and tostring(k) ~= "status" then
      rows[#rows + 1] = { label = k, value = M.toText(v) }
      count = count + 1
    end
  end
  return rows
end

function M.md5Hex(text)
  local md5 = require("./md5.luau")
  return md5.md5(string.lower(text or ""))
end

-- ---- i18n ----
-- Effective language: the plugin "language" setting wins; otherwise follow the
-- shell language (shell.lang, then the environment locale). Only en + pt-BR
-- catalogs are bundled; anything that is not Portuguese falls back to English.
local catalogs = {}

local function normalizeLang(raw)
  local l = tostring(raw or ""):lower()
  l = l:gsub("_", "-")
  l = l:match("^[%a][%a-]*")
  return l or ""
end

local function forcedLang()
  local v = noctalia.getConfig("language")
  if type(v) == "string" and v ~= "default" and v ~= "system" and v ~= "" then
    return v
  end
  return nil
end

local shellLang = false
local function shellLanguage()
  if shellLang == false then
    local l = ""
    if noctalia.getSetting ~= nil then
      local v = noctalia.getSetting("shell.lang")
      if type(v) == "string" then
        l = v
      end
    end
    if l == "" then
      l = noctalia.getenv("LC_ALL") or noctalia.getenv("LC_MESSAGES") or noctalia.getenv("LANG") or ""
    end
    shellLang = normalizeLang(l)
  end
  return shellLang
end

local function effectiveLanguage()
  local forced = forcedLang()
  if forced ~= nil then
    return forced
  end
  local lang = shellLanguage()
  if lang:find("^pt") then
    return "pt-BR"
  end
  return "en"
end

local function loadCatalog(lang)
  local cached = catalogs[lang]
  if cached ~= nil then
    return cached
  end
  local t = {}
  local raw = noctalia.readFile("translations/" .. lang .. ".json")
  if type(raw) == "string" then
    local decoded = noctalia.json.decode(raw)
    if type(decoded) == "table" then
      t = decoded
    end
  end
  catalogs[lang] = t
  return t
end

function M.tr(key, subst)
  if type(key) ~= "string" then
    return key
  end
  local lang = effectiveLanguage()
  local s = loadCatalog(lang)[key]
  if type(s) ~= "string" and lang ~= "en" then
    s = loadCatalog("en")[key]
  end
  if type(s) ~= "string" then
    s = key
  end
  if subst ~= nil then
    s = (s:gsub("%{([%w_.]+)%}", function(k)
      local v = subst[k]
      if v ~= nil then
        return tostring(v)
      end
      return nil
    end))
  end
  return s
end

function M.trp(key, count, subst)
  local n = tonumber(count) or 0
  if n == 1 then
    local one = M.tr(key .. ".one", subst)
    if one ~= key .. ".one" then
      return one
    end
  end
  local other = M.tr(key .. ".other", subst)
  if other ~= key .. ".other" then
    return other
  end
  return M.tr(key, subst)
end

return M