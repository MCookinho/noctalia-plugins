--!nonstrict
-- Shared plumbing for GoAnime Tools: shell quoting, JSON and HTTP helpers.
local M = {}

function M.httpGet(url, headers, opts, cb)
  local req = { url = url, headers = headers or { "Accept: application/json" } }
  if opts then
    if opts.follow_redirects then
      req.follow_redirects = true
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

return M