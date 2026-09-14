--!nonstrict
-- Shared plumbing for GoAnime Tools: shell quoting + JSON helpers.
local M = {}

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