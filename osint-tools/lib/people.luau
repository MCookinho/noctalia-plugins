--!nonstrict
-- Related-people lookup using public, key-free APIs:
-- GitHub followers, Mastodon following, Instagram @mentions in public posts.
-- Each entry exposes a check(u, cb) -> started bool; cb receives a list of
-- person nodes: { login, name, source, url, avatar }. No API key required.
local M = {}

local util = require("./util.luau")
local platforms = require("./platforms.luau")

local INSTA_UA = "Instagram 269.0.0.18.85 Android (23/8.0; 420dpi; 1080x2340; unknown; unknown; en_US; 123)"

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
          local person = { login = login, source = "GitHub" }
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

function M.mastodonFollowing(u, cb)
  local out = {}
  local instances = platforms.mastodonInstances()
  local pending = #instances
  local done = false

  local function resolve(instance)
    if done then
      return
    end
    done = true
    util.httpGet("https://" .. instance .. "/api/v1/accounts/lookup?acct=%40" .. noctalia.string.urlEncode(u) .. "%40" .. instance, {
      "Accept: application/json",
    }, nil, function(res)
      local json = util.decodeJson(res.body)
      local id = type(json) == "table" and json.id or nil
      if id == nil then
        cb(out)
        return
      end
      util.httpGet("https://" .. instance .. "/api/v1/accounts/" .. tostring(id) .. "/following?limit=80", {
        "Accept: application/json",
      }, nil, function(res2)
        local arr = util.decodeJson(res2.body)
        local seen = {}
        if type(arr) == "table" then
          for _, item in ipairs(arr) do
            local acct = type(item) == "table" and item.acct or nil
            if type(acct) == "string" and #out < 6 and not seen[acct] then
              seen[acct] = true
              local person = { login = acct, source = "Mastodon" }
              if type(item.url) == "string" and item.url ~= "" then
                person.url = item.url
              end
              if type(item.avatar) == "string" and item.avatar ~= "" then
                person.avatar = item.avatar
              end
              if type(item.display_name) == "string" and item.display_name ~= "" then
                person.name = item.display_name
              end
              out[#out + 1] = person
            end
          end
        end
        cb(out)
      end)
    end)
  end

  for _, instance in ipairs(instances) do
    local started = util.httpGet(
      "https://" .. instance .. "/.well-known/webfinger?resource=acct:" .. noctalia.string.urlEncode(u) .. "@" .. instance,
      { "Accept: application/jrd+json" },
      nil,
      function(res)
        if done then
          return
        end
        local json = util.decodeJson(res.body)
        if util.statusOk(res) and type(json) == "table" and type(json.subject) == "string" then
          resolve(instance)
        else
          pending = pending - 1
          if pending <= 0 and not done then
            done = true
            cb(out)
          end
        end
      end
    )
    if not started then
      pending = pending - 1
      if pending <= 0 and not done then
        done = true
        cb(out)
      end
    end
  end
  return true
end

function M.instagramMentions(u, cb)
  local started = util.httpGet("https://i.instagram.com/api/v1/users/web_profile_info/?username=" .. noctalia.string.urlEncode(u), {
    "User-Agent: " .. INSTA_UA,
    "Accept: */*",
  }, nil, function(res)
    local out = {}
    if res.status == 400 or res.status == 403 or res.status == 429 or not util.statusOk(res) then
      cb(out)
      return
    end
    local json = util.decodeJson(res.body)
    local media = type(json) == "table" and type(json.data) == "table" and type(json.data.user) == "table"
      and type(json.data.user.edge_owner_to_timeline_media) == "table"
      and json.data.user.edge_owner_to_timeline_media.edges or nil
    local seen = {}
    if type(media) == "table" then
      for _, edge in ipairs(media) do
        local caps = type(edge) == "table" and type(edge.node) == "table" and type(edge.node.edge_media_to_caption) == "table"
          and edge.node.edge_media_to_caption.edges or nil
        if type(caps) == "table" then
          for _, ce in ipairs(caps) do
            local text = type(ce) == "table" and type(ce.node) == "table" and ce.node.text or nil
            if type(text) == "string" then
              for m in text:gmatch("@([%w%.]+)") do
                local login = cleanLogin(m)
                if login and not seen[login] then
                  seen[login] = true
                  table.insert(out, { login = login, source = "Instagram", url = "https://www.instagram.com/" .. login .. "/" })
                end
                if #out >= 6 then
                  break
                end
              end
            end
            if #out >= 6 then
              break
            end
          end
        end
        if #out >= 6 then
          break
        end
      end
    end
    cb(out)
  end)
  return started
end

function M.buildUsernamePeopleChecks()
  return {
    { id = "github_followers", check = M.githubFollowers },
    { id = "mastodon_following", check = M.mastodonFollowing },
    { id = "instagram_mentions", check = M.instagramMentions },
  }
end

return M