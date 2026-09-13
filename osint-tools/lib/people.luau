--!nonstrict
-- Related-people lookup using public, key-free APIs (GitHub followers).
-- Each entry exposes a check(u, cb) -> started bool; cb receives a list of
-- person nodes: { login, name, url, avatar }. No API key required.
local M = {}

local util = require("./util.luau")

local function cleanLogin(login)
  if type(login) ~= "string" then
    return nil
  end
  login = noctalia.string.trim(login)
  if login == "" then
    return nil
  end
  return login
end

function M.githubFollowers(u, cb)
  local started = util.httpGet("https://api.github.com/users/" .. noctalia.string.urlEncode(u) .. "/followers?per_page=6", {
    "Accept: application/vnd.github+json",
    "User-Agent: noctalia-osint",
  }, nil, function(res)
    local out = {}
    if res.status == 403 or not util.statusOk(res) then
      cb(out)
      return
    end
    local json = util.decodeJson(res.body)
    if type(json) ~= "table" then
      cb(out)
      return
    end
    for _, item in ipairs(json) do
      if type(item) == "table" then
        local login = cleanLogin(item.login)
        if login then
          local person = { login = login }
          local name = item.name
          if type(name) == "string" and name ~= "" then
            person.name = name
          end
          if type(item.html_url) == "string" and item.html_url ~= "" then
            person.url = item.html_url
          end
          if type(item.avatar_url) == "string" and item.avatar_url ~= "" then
            person.avatar = item.avatar_url
          end
          out[#out + 1] = person
        end
      end
    end
    cb(out)
  end)
  return started
end

function M.buildUsernamePeopleChecks()
  return { { id = "github_followers", check = M.githubFollowers } }
end

return M