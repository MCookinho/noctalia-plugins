--!nonstrict
-- Username presence checks against public, key-free APIs.
-- Each entry exposes: id, name, glyph, url, group and check(u, cb) -> started bool.
-- cb receives a card table: { title, glyph, group, found, rows, url, avatar, note }.
-- Presence is determined via public JSON endpoints where available, otherwise
-- by HTTP status / HTML markers. All checks are key-free.
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

local BROWSER_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
local IG_UA = "Instagram 269.0.0.18.85 Android (23/8.0; 420dpi; 1080x2340; unknown; unknown; en_US; 123)"
local HTML_HEADERS = {
  "User-Agent: " .. BROWSER_UA,
  "Accept-Language: en-US,en;q=0.9",
}

-- Generic HTML presence check. opts: { name, glyph, url(u), public_url(u), verify(body,u)?, rows(body,u)? }.
local function htmlCheck(opts)
  return function(u, cb)
    local started = util.httpGet(opts.url(u), HTML_HEADERS, { follow_redirects = true }, function(res)
      local card = { title = opts.name, glyph = opts.glyph, group = opts.group, url = opts.public_url(u) }
      local body = type(res.body) == "string" and res.body or ""
      if util.statusOk(res) then
        if opts.verify then
          if opts.verify(body, u) then
            card.found = true
            if opts.rows then
              card.rows = opts.rows(body, u)
            end
          else
            card.found = false
          end
        else
          card.found = true
          if opts.rows then
            card.rows = opts.rows(body, u)
          end
        end
      elseif res.status == 403 or res.status == 429 or res.status == 999 then
        card.found = false
        card.note = "note_blocked"
      else
        card.found = false
      end
      cb(card)
    end)
    return started
  end
end

-- Parse a JSON integer value that may appear in a HTML page near key.
local function jsNumber(body, key)
  local found = body:find(key, 1, true)
  if not found then
    return nil
  end
  local value = body:match("(%d+)", found)
  if value == nil then
    return nil
  end
  return value
end

local function github()
  return {
    id = "github",
    name = "GitHub",
    glyph = "brand-github",
    url = "https://github.com/",
    group = "graph.dev",
    check = function(u, cb)
      local started = util.httpGet("https://api.github.com/users/" .. noctalia.string.urlEncode(u), {
        "Accept: application/vnd.github+json",
        "User-Agent: noctalia-osint",
      }, nil, function(res)
        local card = { title = "GitHub", glyph = "brand-github", group = "graph.dev" }
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
    group = "graph.dev",
    check = function(u, cb)
      local started = util.httpGet("https://gitlab.com/api/v4/users?username=" .. noctalia.string.urlEncode(u), nil, nil, function(res)
        local card = { title = "GitLab", glyph = "brand-gitlab", group = "graph.dev", url = "https://gitlab.com/" .. u }
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
    group = "graph.dev",
    check = function(u, cb)
      local started = util.httpGet("https://hacker-news.firebaseio.com/v0/user/" .. noctalia.string.urlEncode(u) .. ".json", nil, nil, function(res)
        local card = { title = "Hacker News", glyph = "brand-ycombinator", group = "graph.dev", url = "https://news.ycombinator.com/user?id=" .. u }
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
    group = "graph.dev",
    check = function(u, cb)
      local started = util.httpGet("https://pypi.org/pypi/" .. noctalia.string.urlEncode(u) .. "/json", nil, nil, function(res)
        local card = { title = "PyPI", glyph = "brand-python", group = "graph.dev", url = "https://pypi.org/project/" .. u }
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
    glyph = "brand-npm",
    url = "https://www.npmjs.com/package/",
    group = "graph.dev",
    check = function(u, cb)
      local started = util.httpGet("https://registry.npmjs.org/" .. noctalia.string.urlEncode(u), nil, nil, function(res)
        local card = { title = "npm", glyph = "brand-npm", group = "graph.dev", url = "https://www.npmjs.com/package/" .. u }
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
    group = "graph.dev",
    check = function(u, cb)
      local started = util.httpGet("https://keybase.io/_/api/1.0/user/lookup.json?usernames=" .. noctalia.string.urlEncode(u), nil, nil, function(res)
        local card = { title = "Keybase", glyph = "key", group = "graph.dev", url = "https://keybase.io/" .. u }
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
    glyph = "brand-bluesky",
    url = "https://bsky.app/profile/",
    group = "graph.social",
    check = function(u, cb)
      local started = util.httpGet("https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile?actor=" .. noctalia.string.urlEncode(u), {
        "Accept: application/json",
        "User-Agent: noctalia-osint/1.0",
      }, nil, function(res)
        local card = { title = "Bluesky", glyph = "brand-bluesky", group = "graph.social", url = "https://bsky.app/profile/" .. u }
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

local MASTODON_INSTANCES = {
  "mastodon.social",
  "mstdn.social",
  "mastodon.online",
  "fosstodon.org",
  "techhub.social",
  "mastodon.world",
}

local function mastodon()
  return {
    id = "mastodon",
    name = "Mastodon",
    glyph = "brand-mastodon",
    url = "https://mastodon.social/",
    group = "graph.social",
    check = function(u, cb)
      local pending = #MASTODON_INSTANCES
      local finished = false
      local card = { title = "Mastodon", glyph = "brand-mastodon", group = "graph.social", url = "https://mastodon.social/@" .. u }

      local function maybeDone()
        pending = pending - 1
        if pending <= 0 and not finished then
          finished = true
          cb(card)
        end
      end

      for _, instance in ipairs(MASTODON_INSTANCES) do
        local started = util.httpGet(
          "https://" .. instance .. "/.well-known/webfinger?resource=acct:" .. noctalia.string.urlEncode(u) .. "@" .. instance,
          { "Accept: application/jrd+json" },
          nil,
          function(res)
            if finished then
              return
            end
            local json = util.decodeJson(res.body)
            if util.statusOk(res) and type(json) == "table" and type(json.subject) == "string" then
              finished = true
              card.found = true
              local rows = {}
              table.insert(rows, { label = noctalia.tr("row.handle"), value = valueText(json.subject or (u .. "@" .. instance)) })
              if type(json.aliases) == "table" and #json.aliases > 0 then
                card.url = json.aliases[1]
                if type(json.links) == "table" then
                  for _, link in ipairs(json.links) do
                    if type(link) == "table" and type(link.avatar) == "string" then
                      card.avatar = link.avatar
                    end
                  end
                end
              end
              card.rows = rows
              cb(card)
            else
              maybeDone()
            end
          end
        )
        if not started then
          maybeDone()
        end
      end
      return true
    end,
  }
end

local function telegram()
  return {
    id = "telegram",
    name = "Telegram",
    glyph = "brand-telegram",
    url = "https://t.me/",
    group = "graph.social",
    check = function(u, cb)
      local started = util.httpGet("https://t.me/" .. noctalia.string.urlEncode(u), {
        "User-Agent: " .. BROWSER_UA,
      }, { follow_redirects = true }, function(res)
        local card = { title = "Telegram", glyph = "brand-telegram", group = "graph.social", url = "https://t.me/" .. u }
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

local function twitter()
  return {
    id = "twitter",
    name = "X",
    glyph = "brand-x",
    url = "https://x.com/",
    group = "graph.social",
    check = function(u, cb)
      local started = util.httpGet("https://publish.x.com/oembed?url=https://x.com/" .. noctalia.string.urlEncode(u), {
        "User-Agent: " .. BROWSER_UA,
      }, nil, function(res)
        local card = { title = "X", glyph = "brand-x", group = "graph.social", url = "https://x.com/" .. u }
        if res.status == 429 then
          card.found = false
          card.note = "note_blocked"
          cb(card)
          return
        end
        local json = util.decodeJson(res.body)
        if not util.statusOk(res) or type(json) ~= "table" then
          card.found = false
          cb(card)
          return
        end
        card.found = true
        local rows = {}
        table.insert(rows, { label = noctalia.tr("row.handle"), value = "@" .. u })
        if type(json.author_name) == "string" and json.author_name ~= "" then
          table.insert(rows, { label = noctalia.tr("row.name"), value = json.author_name })
        end
        local htmlText = type(json.html) == "string" and json.html:match("%>([^<]+)%</a>") or nil
        if htmlText and htmlText ~= "" then
          table.insert(rows, { label = noctalia.tr("row.bio"), value = htmlText })
        end
        card.rows = rows
        cb(card)
      end)
      return started
    end,
  }
end

local function reddit()
  return {
    id = "reddit",
    name = "Reddit",
    glyph = "brand-reddit",
    url = "https://www.reddit.com/user/",
    group = "graph.social",
    check = function(u, cb)
      local started = util.httpGet("https://www.reddit.com/user/" .. noctalia.string.urlEncode(u) .. "/about.json", {
        "User-Agent: " .. BROWSER_UA,
      }, nil, function(res)
        local card = { title = "Reddit", glyph = "brand-reddit", group = "graph.social", url = "https://www.reddit.com/user/" .. u .. "/" }
        if res.status == 429 then
          card.found = false
          card.note = "note_blocked"
          cb(card)
          return
        end
        local json = util.decodeJson(res.body)
        local data = type(json) == "table" and type(json.data) == "table" and json.data
        if not util.statusOk(res) or data == nil then
          card.found = false
          cb(card)
          return
        end
        card.found = true
        local rows = {}
        local name = data.name or u
        if type(data.title) == "string" and data.title ~= "" then
          table.insert(rows, { label = noctalia.tr("row.name"), value = data.title })
        end
        table.insert(rows, { label = noctalia.tr("row.handle"), value = valueText(name) })
        if type(data.comment_karma) == "number" then
          table.insert(rows, { label = noctalia.tr("row.comment_karma"), value = tostring(data.comment_karma) })
        end
        if type(data.link_karma) == "number" then
          table.insert(rows, { label = noctalia.tr("row.link_karma"), value = tostring(data.link_karma) })
        end
        local created = dateFromUnix(data.created_utc)
        if created then
          table.insert(rows, { label = noctalia.tr("row.created"), value = created })
        end
        card.rows = rows
        if type(data.icon_img) == "string" and data.icon_img ~= "" and data.icon_img:find("^https?://") then
          card.avatar = data.icon_img
        end
        cb(card)
      end)
      return started
    end,
  }
end

local function instagram()
  return {
    id = "instagram",
    name = "Instagram",
    glyph = "brand-instagram",
    url = "https://www.instagram.com/",
    group = "graph.social",
    check = function(u, cb)
      local started = util.httpGet("https://i.instagram.com/api/v1/users/web_profile_info/?username=" .. noctalia.string.urlEncode(u), {
        "User-Agent: " .. IG_UA,
        "Accept: */*",
      }, nil, function(res)
        local card = { title = "Instagram", glyph = "brand-instagram", group = "graph.social", url = "https://www.instagram.com/" .. u .. "/" }
        if res.status == 400 or res.status == 403 or res.status == 429 then
          card.found = false
          card.note = "note_blocked"
          cb(card)
          return
        end
        local json = util.decodeJson(res.body)
        local user = type(json) == "table" and type(json.data) == "table" and type(json.data.user) == "table" and json.data.user
        if not util.statusOk(res) or user == nil or type(user.username) ~= "string" then
          card.found = false
          cb(card)
          return
        end
        card.found = true
        if user.username:lower() ~= string.lower(u) then
          user = nil
        end
        if user == nil then
          card.found = false
          cb(card)
          return
        end
        card.avatar = (type(user.profile_pic_url_hd) == "string" and user.profile_pic_url_hd ~= "") and user.profile_pic_url_hd
          or (type(user.profile_pic_url) == "string" and user.profile_pic_url or nil)
        local rows = {}
        if type(user.full_name) == "string" and user.full_name ~= "" then
          table.insert(rows, { label = noctalia.tr("row.display_name"), value = user.full_name })
        end
        if type(user.biography) == "string" and user.biography ~= "" then
          table.insert(rows, { label = noctalia.tr("row.bio"), value = user.biography })
        end
        if type(user.edge_followed_by) == "table" and type(user.edge_followed_by.count) == "number" then
          table.insert(rows, { label = noctalia.tr("row.followers"), value = tostring(user.edge_followed_by.count) })
        end
        if type(user.edge_follow) == "table" and type(user.edge_follow.count) == "number" then
          table.insert(rows, { label = noctalia.tr("row.following"), value = tostring(user.edge_follow.count) })
        end
        if type(user.edge_owner_to_timeline_media) == "table" and type(user.edge_owner_to_timeline_media.count) == "number" then
          table.insert(rows, { label = noctalia.tr("row.posts"), value = tostring(user.edge_owner_to_timeline_media.count) })
        end
        card.rows = rows
        cb(card)
      end)
      return started
    end,
  }
end

local function youtube()
  return {
    id = "youtube",
    name = "YouTube",
    glyph = "brand-youtube",
    url = "https://www.youtube.com/",
    group = "graph.social",
    check = htmlCheck({
      name = "YouTube",
      glyph = "brand-youtube",
      group = "graph.social",
      url = function(u) return "https://www.youtube.com/@" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://www.youtube.com/@" .. u end,
      rows = function(body)
        local rows = {}
        local name = body:match("<meta itemprop=\"name\" content=\"([^\"]+)\"")
        if name and name ~= "" and not name:find("Sorry", 1, true) then
          table.insert(rows, { label = noctalia.tr("row.name"), value = name })
        end
        local subs = jsNumber(body, "subscriberCount")
        if subs then
          table.insert(rows, { label = noctalia.tr("row.subscribers"), value = subs })
        end
        return rows
      end,
    }),
  }
end

local function tiktok()
  return {
    id = "tiktok",
    name = "TikTok",
    glyph = "brand-tiktok",
    url = "https://www.tiktok.com/",
    group = "graph.social",
    check = htmlCheck({
      name = "TikTok",
      glyph = "brand-tiktok",
      group = "graph.social",
      url = function(u) return "https://www.tiktok.com/@" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://www.tiktok.com/@" .. u end,
      verify = function(body, u)
        return body:lower():find('"uniqueid":"' .. u:lower(), 1, true) ~= nil
      end,
      rows = function(body)
        local rows = {}
        local followers = jsNumber(body, "followerCount")
        if followers then
          table.insert(rows, { label = noctalia.tr("row.followers"), value = followers })
        end
        local following = jsNumber(body, "followingCount")
        if following then
          table.insert(rows, { label = noctalia.tr("row.following"), value = following })
        end
        local likes = jsNumber(body, "heartCount")
        if likes then
          table.insert(rows, { label = noctalia.tr("row.likes"), value = likes })
        end
        return rows
      end,
    }),
  }
end

local function threads()
  return {
    id = "threads",
    name = "Threads",
    glyph = "brand-threads",
    url = "https://www.threads.net/",
    group = "graph.social",
    check = htmlCheck({
      name = "Threads",
      glyph = "brand-threads",
      group = "graph.social",
      url = function(u) return "https://www.threads.net/@" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://www.threads.net/@" .. u end,
      rows = function(body)
        local rows = {}
        local followers = jsNumber(body, "follower_count")
        if not followers then
          followers = jsNumber(body, "followers_count")
        end
        if followers then
          table.insert(rows, { label = noctalia.tr("row.followers"), value = followers })
        end
        local fullName = body:match('"displayName%s*:%s*"([^"]*)"')
        if fullName and fullName ~= "" then
          table.insert(rows, { label = noctalia.tr("row.display_name"), value = fullName })
        end
        return rows
      end,
    }),
  }
end

local function twitch()
  return {
    id = "twitch",
    name = "Twitch",
    glyph = "brand-twitch",
    url = "https://www.twitch.tv/",
    group = "graph.social",
    check = htmlCheck({
      name = "Twitch",
      glyph = "brand-twitch",
      group = "graph.social",
      url = function(u) return "https://decapi.me/twitch/id/" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://www.twitch.tv/" .. u end,
      verify = function(body, u)
        return body:match("%d+") ~= nil and body:lower():find("invalid", 1, true) == nil
      end,
    }),
  }
end

local function kick()
  return {
    id = "kick",
    name = "Kick",
    glyph = "brand-kick",
    url = "https://kick.com/",
    group = "graph.social",
    check = htmlCheck({
      name = "Kick",
      glyph = "brand-kick",
      group = "graph.social",
      url = function(u) return "https://kick.com/" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://kick.com/" .. u end,
    }),
  }
end

local function soundcloud()
  return {
    id = "soundcloud",
    name = "SoundCloud",
    glyph = "brand-soundcloud",
    url = "https://soundcloud.com/",
    group = "graph.social",
    check = htmlCheck({
      name = "SoundCloud",
      glyph = "brand-soundcloud",
      group = "graph.social",
      url = function(u) return "https://soundcloud.com/" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://soundcloud.com/" .. u end,
    }),
  }
end

local function vimeo()
  return {
    id = "vimeo",
    name = "Vimeo",
    glyph = "brand-vimeo",
    url = "https://vimeo.com/",
    group = "graph.social",
    check = htmlCheck({
      name = "Vimeo",
      glyph = "brand-vimeo",
      group = "graph.social",
      url = function(u) return "https://vimeo.com/" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://vimeo.com/" .. u end,
    }),
  }
end

local function behance()
  return {
    id = "behance",
    name = "Behance",
    glyph = "brand-behance",
    url = "https://www.behance.net/",
    group = "graph.social",
    check = htmlCheck({
      name = "Behance",
      glyph = "brand-behance",
      group = "graph.social",
      url = function(u) return "https://www.behance.net/" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://www.behance.net/" .. u end,
    }),
  }
end

local function dribbble()
  return {
    id = "dribbble",
    name = "Dribbble",
    glyph = "brand-dribbble",
    url = "https://dribbble.com/",
    group = "graph.social",
    check = htmlCheck({
      name = "Dribbble",
      glyph = "brand-dribbble",
      group = "graph.social",
      url = function(u) return "https://dribbble.com/" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://dribbble.com/" .. u end,
    }),
  }
end

local function medium()
  return {
    id = "medium",
    name = "Medium",
    glyph = "brand-medium",
    url = "https://medium.com/",
    group = "graph.social",
    check = htmlCheck({
      name = "Medium",
      glyph = "brand-medium",
      group = "graph.social",
      url = function(u) return "https://medium.com/@" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://medium.com/@" .. u end,
    }),
  }
end

local function linkedin()
  return {
    id = "linkedin",
    name = "LinkedIn",
    glyph = "brand-linkedin",
    url = "https://www.linkedin.com/in/",
    group = "graph.social",
    check = htmlCheck({
      name = "LinkedIn",
      glyph = "brand-linkedin",
      group = "graph.social",
      url = function(u) return "https://www.linkedin.com/in/" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://www.linkedin.com/in/" .. u end,
    }),
  }
end

local function pinterest()
  return {
    id = "pinterest",
    name = "Pinterest",
    glyph = "brand-pinterest",
    url = "https://www.pinterest.com/",
    group = "graph.social",
    check = htmlCheck({
      name = "Pinterest",
      glyph = "brand-pinterest",
      group = "graph.social",
      url = function(u) return "https://www.pinterest.com/" .. noctalia.string.urlEncode(u) .. "/" end,
      public_url = function(u) return "https://www.pinterest.com/" .. u .. "/" end,
      verify = function(body, u)
        local lower = u:lower()
        return body:lower():find('pinterest.com/' .. lower .. '/', 1, true) ~= nil
      end,
    }),
  }
end

local function patreon()
  return {
    id = "patreon",
    name = "Patreon",
    glyph = "brand-patreon",
    url = "https://www.patreon.com/",
    group = "graph.social",
    check = htmlCheck({
      name = "Patreon",
      glyph = "brand-patreon",
      group = "graph.social",
      url = function(u) return "https://www.patreon.com/" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://www.patreon.com/" .. u end,
    }),
  }
end

local function okru()
  return {
    id = "okru",
    name = "OK.ru",
    glyph = "brand-ok-ru",
    url = "https://ok.ru/",
    group = "graph.social",
    check = htmlCheck({
      name = "OK.ru",
      glyph = "brand-ok-ru",
      group = "graph.social",
      url = function(u) return "https://ok.ru/" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://ok.ru/" .. u end,
    }),
  }
end

local function rumble()
  return {
    id = "rumble",
    name = "Rumble",
    glyph = "brand-rumble",
    url = "https://rumble.com/",
    group = "graph.social",
    check = htmlCheck({
      name = "Rumble",
      glyph = "brand-rumble",
      group = "graph.social",
      url = function(u) return "https://rumble.com/user/" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://rumble.com/user/" .. u end,
    }),
  }
end

local function devto()
  return {
    id = "devto",
    name = "DEV.to",
    glyph = "code",
    url = "https://dev.to/",
    group = "graph.dev",
    check = htmlCheck({
      name = "DEV.to",
      glyph = "code",
      group = "graph.dev",
      url = function(u) return "https://dev.to/" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://dev.to/" .. u end,
      rows = function(body)
        local rows = {}
        local name = body:match('<meta property="og:title" content="([^"]+)"')
        if name and name ~= "" then
          table.insert(rows, { label = noctalia.tr("row.name"), value = name })
        end
        return rows
      end,
    }),
  }
end

local function hashnode()
  return {
    id = "hashnode",
    name = "Hashnode",
    glyph = "hash",
    url = "https://hashnode.com/",
    group = "graph.dev",
    check = htmlCheck({
      name = "Hashnode",
      glyph = "hash",
      group = "graph.dev",
      url = function(u) return "https://hashnode.com/@" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://hashnode.com/@" .. u end,
    }),
  }
end

local function codeberg()
  return {
    id = "codeberg",
    name = "Codeberg",
    glyph = "brand-git",
    url = "https://codeberg.org/",
    group = "graph.dev",
    check = htmlCheck({
      name = "Codeberg",
      glyph = "brand-git",
      group = "graph.dev",
      url = function(u) return "https://codeberg.org/" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://codeberg.org/" .. u end,
    }),
  }
end

local function bitbucket()
  return {
    id = "bitbucket",
    name = "Bitbucket",
    glyph = "brand-bitbucket",
    url = "https://bitbucket.org/",
    group = "graph.dev",
    check = htmlCheck({
      name = "Bitbucket",
      glyph = "brand-bitbucket",
      group = "graph.dev",
      url = function(u) return "https://bitbucket.org/" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://bitbucket.org/" .. u end,
    }),
  }
end

local function sourceforge()
  return {
    id = "sourceforge",
    name = "SourceForge",
    glyph = "brand-git",
    url = "https://sourceforge.net/u/",
    group = "graph.dev",
    check = htmlCheck({
      name = "SourceForge",
      glyph = "brand-git",
      group = "graph.dev",
      url = function(u) return "https://sourceforge.net/u/" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://sourceforge.net/u/" .. u end,
    }),
  }
end

local function deviantart()
  return {
    id = "deviantart",
    name = "DeviantArt",
    glyph = "brand-deviantart",
    url = "https://www.deviantart.com/",
    group = "graph.social",
    check = htmlCheck({
      name = "DeviantArt",
      glyph = "brand-deviantart",
      group = "graph.social",
      url = function(u) return "https://www.deviantart.com/" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://www.deviantart.com/" .. u end,
    }),
  }
end

local function flickr()
  return {
    id = "flickr",
    name = "Flickr",
    glyph = "brand-flickr",
    url = "https://www.flickr.com/photos/",
    group = "graph.social",
    check = htmlCheck({
      name = "Flickr",
      glyph = "brand-flickr",
      group = "graph.social",
      url = function(u) return "https://www.flickr.com/photos/" .. noctalia.string.urlEncode(u) end,
      public_url = function(u) return "https://www.flickr.com/photos/" .. u end,
    }),
  }
end

local buffered
M.usernameChecks = nil

function M.buildUsernameChecks()
  if buffered then
    return buffered
  end
  local list = {}
  local builders = {
    github,
    gitlab,
    twitter,
    instagram,
    tiktok,
    threads,
    youtube,
    reddit,
    twitch,
    kick,
    telegram,
    bluesky,
    mastodon,
    linkedin,
    soundcloud,
    vimeo,
    dribbble,
    behance,
    medium,
    devto,
    hashnode,
    codeberg,
    bitbucket,
    sourceforge,
    pypi,
    npm,
    hackernews,
    keybase,
    pinterest,
    patreon,
    okru,
    rumble,
    deviantart,
    flickr,
  }
  for _, builder in ipairs(builders) do
    local entry = builder()
    table.insert(list, entry)
  end
  buffered = list
  return list
end

return M