--!nonstrict
-- Username presence checks against public, key-free APIs.
-- Each entry exposes: id, name, glyph, url and check(u, cb) -> started bool.
-- cb receives a card table: { title, glyph, found, rows, url, avatar, note }.
local M = {}

local util = require("./util.luau")

local function dateFromIso(value)
  if type(value) ~= "string" then
    return nil
  end
  return value:sub(1, 10)
end

local function dateFromUnix(value)
  local n = tonumber(value)
  if n == nil then
    return nil
  end
  return os.date("%Y-%m-%d", n)
end

local function valueText(value)
  return util.toText(value)
end

local function github()
  return {
    id = "github",
    name = "GitHub",
    glyph = "brand-github",
    url = "https://github.com/",
    check = function(u, cb)
      local started = util.httpGet("https://api.github.com/users/" .. noctalia.string.urlEncode(u), {
        "Accept: application/vnd.github+json",
        "User-Agent: noctalia-osint",
      }, nil, function(res)
        local card = { title = "GitHub", glyph = "brand-github" }
        if res.status == 403 and type(res.body) == "string" and res.body:find("API rate limit") then
          card.found = false
          card.note = "note_rate_limit"
          cb(card)
          return
        end
        local json = util.decodeJson(res.body)
        if not util.statusOk(res) or type(json) ~= "table" or type(json.login) ~= "string" then
          card.found = false
          card.url = "https://github.com/" .. u
          cb(card)
          return
        end
        card.found = true
        card.url = type(json.html_url) == "string" and json.html_url or ("https://github.com/" .. json.login)
        card.avatar = json.avatar_url
        local rows = {}
        table.insert(rows, { label = noctalia.tr("row.name"), value = valueText(json.name or json.login) })
        if type(json.bio) == "string" and json.bio ~= "" then
          table.insert(rows, { label = noctalia.tr("row.bio"), value = json.bio })
        end
        if type(json.location) == "string" and json.location ~= "" then
          table.insert(rows, { label = noctalia.tr("row.location"), value = json.location })
        end
        if type(json.company) == "string" and json.company ~= "" then
          table.insert(rows, { label = noctalia.tr("row.company"), value = json.company })
        end
        local created = dateFromIso(json.created_at)
        if created then
          table.insert(rows, { label = noctalia.tr("row.created"), value = created })
        end
        table.insert(rows, { label = noctalia.tr("row.followers"), value = tostring(json.followers or 0) })
        table.insert(rows, { label = noctalia.tr("row.repos"), value = tostring(json.public_repos or 0) })
        card.rows = rows
        cb(card)
      end)
      return started
    end,
  }
end

local function gitlab()
  return {
    id = "gitlab",
    name = "GitLab",
    glyph = "brand-gitlab",
    url = "https://gitlab.com/",
    check = function(u, cb)
      local started = util.httpGet("https://gitlab.com/api/v4/users?username=" .. noctalia.string.urlEncode(u), nil, nil, function(res)
        local card = { title = "GitLab", glyph = "brand-gitlab", url = "https://gitlab.com/" .. u }
        local json = util.decodeJson(res.body)
        if not util.statusOk(res) or type(json) ~= "table" or #json == 0 then
          card.found = false
          cb(card)
          return
        end
        local user = json[1]
        card.found = true
        card.url = type(user.web_url) == "string" and user.web_url or ("https://gitlab.com/" .. u)
        local rows = {}
        table.insert(rows, { label = noctalia.tr("row.display_name"), value = valueText(user.name or user.username) })
        if type(user.state) == "string" and user.state ~= "" then
          table.insert(rows, { label = noctalia.tr("row.state"), value = user.state })
        end
        card.rows = rows
        cb(card)
      end)
      return started
    end,
  }
end

local function hackernews()
  return {
    id = "hackernews",
    name = "Hacker News",
    glyph = "brand-ycombinator",
    url = "https://news.ycombinator.com/user?id=",
    check = function(u, cb)
      local started = util.httpGet("https://hacker-news.firebaseio.com/v0/user/" .. noctalia.string.urlEncode(u) .. ".json", nil, nil, function(res)
        local card = { title = "Hacker News", glyph = "brand-ycombinator", url = "https://news.ycombinator.com/user?id=" .. u }
        local json = util.decodeJson(res.body)
        if type(json) ~= "table" or type(json.id) ~= "string" then
          card.found = false
          cb(card)
          return
        end
        card.found = true
        local rows = {}
        table.insert(rows, { label = noctalia.tr("row.karma"), value = tostring(json.karma or 0) })
        local created = dateFromUnix(json.created)
        if created then
          table.insert(rows, { label = noctalia.tr("row.created"), value = created })
        end
        if type(json.about) == "string" and json.about ~= "" then
          table.insert(rows, { label = noctalia.tr("row.about"), value = json.about })
        end
        card.rows = rows
        cb(card)
      end)
      return started
    end,
  }
end

local function pypi()
  return {
    id = "pypi",
    name = "PyPI",
    glyph = "brand-python",
    url = "https://pypi.org/project/",
    check = function(u, cb)
      local started = util.httpGet("https://pypi.org/pypi/" .. noctalia.string.urlEncode(u) .. "/json", nil, nil, function(res)
        local card = { title = "PyPI", glyph = "brand-python", url = "https://pypi.org/project/" .. u }
        local json = util.decodeJson(res.body)
        if not util.statusOk(res) or type(json) ~= "table" or type(json.info) ~= "table" then
          card.found = false
          cb(card)
          return
        end
        local info = json.info
        card.found = true
        local rows = {}
        table.insert(rows, { label = noctalia.tr("row.name"), value = valueText(info.name or u) })
        if type(info.summary) == "string" and info.summary ~= "" then
          table.insert(rows, { label = noctalia.tr("row.summary"), value = info.summary })
        end
        if type(info.author_email) == "string" and info.author_email ~= "" then
          table.insert(rows, { label = noctalia.tr("row.author"), value = info.author_email })
        end
        table.insert(rows, { label = noctalia.tr("row.version"), value = valueText(info.version or "") })
        card.rows = rows
        cb(card)
      end)
      return started
    end,
  }
end

local function npm()
  return {
    id = "npm",
    name = "npm",
    glyph = "n",
    url = "https://www.npmjs.com/package/",
    check = function(u, cb)
      local started = util.httpGet("https://registry.npmjs.org/" .. noctalia.string.urlEncode(u), nil, nil, function(res)
        local card = { title = "npm", glyph = "n", url = "https://www.npmjs.com/package/" .. u }
        local json = util.decodeJson(res.body)
        if not util.statusOk(res) or type(json) ~= "table" or type(json.name) ~= "string" then
          card.found = false
          cb(card)
          return
        end
        card.found = true
        local rows = {}
        table.insert(rows, { label = noctalia.tr("row.name"), value = json.name })
        if type(json.description) == "string" and json.description ~= "" then
          table.insert(rows, { label = noctalia.tr("row.description"), value = json.description })
        end
        card.rows = rows
        cb(card)
      end)
      return started
    end,
  }
end

local function keybase()
  return {
    id = "keybase",
    name = "Keybase",
    glyph = "key",
    url = "https://keybase.io/",
    check = function(u, cb)
      local started = util.httpGet("https://keybase.io/_/api/1.0/user/lookup.json?usernames=" .. noctalia.string.urlEncode(u), nil, nil, function(res)
        local card = { title = "Keybase", glyph = "key", url = "https://keybase.io/" .. u }
        local json = util.decodeJson(res.body)
        local them = type(json) == "table" and json.them
        local profile = type(them) == "table" and them[1]
        local code = type(json) == "table" and type(json.status) == "table" and json.status.code
        if code ~= 0 or type(profile) ~= "table" then
          card.found = false
          cb(card)
          return
        end
        card.found = true
        local rows = {}
        local basics = type(profile.basics) == "table" and profile.basics or {}
        local details = type(profile.profile) == "table" and profile.profile or {}
        table.insert(rows, { label = noctalia.tr("row.handle"), value = valueText(basics.username or u) })
        if type(basics.full_name) == "string" and basics.full_name ~= "" then
          table.insert(rows, { label = noctalia.tr("row.name"), value = basics.full_name })
        end
        if type(details.bio) == "string" and details.bio ~= "" then
          table.insert(rows, { label = noctalia.tr("row.bio"), value = details.bio })
        end
        if type(details.location) == "string" and details.location ~= "" then
          table.insert(rows, { label = noctalia.tr("row.location"), value = details.location })
        end
        card.rows = rows
        if type(details.avatar) == "string" and details.avatar ~= "" then
          card.avatar = details.avatar
        end
        cb(card)
      end)
      return started
    end,
  }
end

local function bluesky()
  return {
    id = "bluesky",
    name = "Bluesky",
    glyph = "shield",
    url = "https://bsky.app/profile/",
    check = function(u, cb)
      local started = util.httpGet("https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile?actor=" .. noctalia.string.urlEncode(u), {
        "Accept: application/json",
        "User-Agent: noctalia-osint/1.0",
      }, nil, function(res)
        local card = { title = "Bluesky", glyph = "shield", url = "https://bsky.app/profile/" .. u }
        local json = util.decodeJson(res.body)
        if type(json) ~= "table" or type(json.handle) ~= "string" then
          card.found = false
          cb(card)
          return
        end
        card.found = true
        card.url = "https://bsky.app/profile/" .. json.handle
        local rows = {}
        table.insert(rows, { label = noctalia.tr("row.handle"), value = json.handle })
        if type(json.displayName) == "string" and json.displayName ~= "" then
          table.insert(rows, { label = noctalia.tr("row.display_name"), value = json.displayName })
        end
        if type(json.description) == "string" and json.description ~= "" then
          table.insert(rows, { label = noctalia.tr("row.bio"), value = json.description })
        end
        table.insert(rows, { label = noctalia.tr("row.followers"), value = tostring(json.followersCount or 0) })
        table.insert(rows, { label = noctalia.tr("row.posts"), value = tostring(json.postsCount or 0) })
        local created = dateFromIso(json.createdAt)
        if created then
          table.insert(rows, { label = noctalia.tr("row.created"), value = created })
        end
        card.rows = rows
        if type(json.avatar) == "string" and json.avatar ~= "" then
          card.avatar = json.avatar
        end
        cb(card)
      end)
      return started
    end,
  }
end

local function mastodon()
  return {
    id = "mastodon",
    name = "Mastodon",
    glyph = "elephant",
    url = "https://mastodon.social/",
    check = function(u, cb)
      local instance = "mastodon.social"
      local started = util.httpGet(
        "https://" .. instance .. "/.well-known/webfinger?resource=acct:" .. noctalia.string.urlEncode(u) .. "@" .. instance,
        { "Accept: application/jrd+json" }, nil, function(res)
        local card = { title = "Mastodon", glyph = "elephant", url = "https://mastodon.social/@" .. u }
        local json = util.decodeJson(res.body)
        if not util.statusOk(res) or type(json) ~= "table" then
          card.found = false
          cb(card)
          return
        end
        card.found = true
        local rows = {}
        table.insert(rows, { label = noctalia.tr("row.handle"), value = valueText(json.subject or (u .. "@mastodon.social")) })
        if type(json.aliases) == "table" and #json.aliases > 0 then
          card.url = json.aliases[1]
          for _, link in ipairs(json.links) do
            if type(link) == "table" and type(link.avatar) == "string" then
              card.avatar = link.avatar
            end
          end
        end
        card.rows = rows
        cb(card)
      end)
      return started
    end,
  }
end

local function telegram()
  return {
    id = "telegram",
    name = "Telegram",
    glyph = "send",
    url = "https://t.me/",
    check = function(u, cb)
      local started = util.httpGet("https://t.me/" .. noctalia.string.urlEncode(u), {
        "User-Agent: Mozilla/5.0",
      }, { follow_redirects = true }, function(res)
        local card = { title = "Telegram", glyph = "send", url = "https://t.me/" .. u }
        local body = type(res.body) == "string" and res.body or ""
        if util.statusOk(res) and body:find("Telegram: View @", 1, true) then
          card.found = true
          card.note = "note_heuristic"
        else
          card.found = false
        end
        cb(card)
      end)
      return started
    end,
  }
end

local buffered
M.usernameChecks = nil

function M.buildUsernameChecks()
  if buffered then
    return buffered
  end
  local list = {}
  local builders = { github, gitlab, hackernews, pypi, npm, keybase, bluesky, mastodon, telegram }
  for _, builder in ipairs(builders) do
    table.insert(list, builder())
  end
  buffered = list
  return list
end

return M