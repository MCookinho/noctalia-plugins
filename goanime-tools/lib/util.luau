--!nonstrict
-- Shared plumbing for Watch Anime: shell quoting, JSON and HTTP helpers.
local M = {}

local function makeRequest(url, method, body, headers, opts)
  local req = { url = url, method = method, headers = headers }
  if body ~= nil then
    req.body = body
  end
  if opts then
    if opts.follow_redirects then
      req.follow_redirects = true
    end
  end
  return req
end

function M.httpGet(url, headers, opts, cb)
  return noctalia.http(makeRequest(url, "GET", nil, headers, opts), function(response)
    cb(response)
  end)
end

function M.httpPost(url, body, headers, opts, cb)
  return noctalia.http(makeRequest(url, "POST", body, headers, opts), function(response)
    cb(response)
  end)
end

function M.statusOk(response)
  return response ~= nil and response.status ~= nil
    and response.status >= 200 and response.status < 300
end

function M.trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return noctalia.string.trim(value)
end

function M.shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.decodeJson(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  return noctalia.json.decode(text)
end

function M.encodeJson(value)
  return noctalia.json.encode(value)
end

function M.home()
  local home = noctalia.getenv("HOME")
  if type(home) == "string" and home ~= "" then
    return home
  end
  return ""
end

function M.isDigits(text)
  return type(text or "") == "string" and tostring(text):match("^%d+$") ~= nil
end

function M.isRange(text)
  local t = tostring(text or "")
  local a, b = t:match("^(%d+)-(%d+)$")
  return a ~= nil and b ~= nil
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