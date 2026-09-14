--!nonstrict
-- High-level analyzers for e-mail, CPF and phone lookups.
-- Each returns an object with a `start(completion)` method; `completion` fires
-- once after all of that analyzer's async operations settle.
-- Only public, key-free sources are used (Gravatar, DoH-MX).
local M = {}

local util = require("./util.luau")
local brazil = require("./brazil.luau")
local detect = require("./detect.luau")

local function glyphForHost(host)
  local h = host:lower()
  if h:find("twitter") or h:find("x.co", 1, true) or h == "x.com" then
    return "brand-x"
  end
  if h:find("instagram", 1, true) then
    return "brand-instagram"
  end
  if h:find("github", 1, true) then
    return "brand-github"
  end
  if h:find("facebook", 1, true) then
    return "brand-facebook"
  end
  if h:find("linkedin", 1, true) then
    return "brand-linkedin"
  end
  if h:find("youtube", 1, true) then
    return "brand-youtube"
  end
  if h:find("tiktok", 1, true) then
    return "brand-tiktok"
  end
  if h:find("twitch", 1, true) then
    return "brand-twitch"
  end
  if h:find("discord", 1, true) then
    return "brand-discord"
  end
  return "link"
end

function M.email(value, ctx)
  return {
    start = function(completion)
      local lean = noctalia.string.trim(value):lower()
      local internal = 0
      local finished = false
      local function doneOne()
        internal = internal - 1
        if internal <= 0 and not finished then
          finished = true
          completion()
        end
      end

      local valid = detect.isEmail(lean)
      if not valid then
        ctx.deliver({
          title = noctalia.tr("email.title"),
          glyph = "mail",
          kind = "entity",
          found = false,
          rows = { { label = noctalia.tr("row.status"), value = noctalia.tr("email.invalid") } },
        })
      else
        ctx.deliver({
          title = noctalia.tr("email.title"),
          glyph = "mail",
          kind = "entity",
          found = true,
          rows = { { label = noctalia.tr("row.status"), value = noctalia.tr("email.valid") } },
        })

        internal = internal + 1
        ctx.dispatch(function(opFinished)
          local hash = util.md5Hex(lean)
          local url = "https://www.gravatar.com/" .. hash .. ".json?d=404"
          return util.httpGet(url, nil, { follow_redirects = true }, function(res)
            local json = util.decodeJson(res.body)
            local entry = type(json) == "table" and type(json.entry) == "table" and json.entry[1]
            if util.statusOk(res) and type(entry) == "table" then
              local rows = {}
              local name = entry.displayName or entry.name
              if type(name) == "string" and name ~= "" then
                table.insert(rows, { label = noctalia.tr("row.display_name"), value = name })
              end
              if type(entry.profileUrl) == "string" and entry.profileUrl ~= "" then
                table.insert(rows, { label = noctalia.tr("row.url"), value = entry.profileUrl, open = entry.profileUrl })
              end
              if type(entry.aboutMe) == "string" and entry.aboutMe ~= "" then
                table.insert(rows, { label = noctalia.tr("row.bio"), value = entry.aboutMe })
              end
              ctx.deliver({
                title = "Gravatar",
                glyph = "user-circle",
                kind = "platform",
                found = true,
                url = "https://www.gravatar.com/" .. hash,
                avatar = "https://www.gravatar.com/avatar/" .. hash .. "?s=256",
                rows = rows,
              })
              if type(entry.urls) == "table" then
                for i, link in ipairs(entry.urls) do
                  if type(link) == "table" and type(link.value) == "string" then
                    local linkValue = link.value
                    local host = (linkValue:match("://([^/]+)") or ""):lower():gsub("^www%.", "")
                    if host ~= "" then
                      local label = (type(link.title) == "string" and link.title ~= "") and link.title or host
                      ctx.deliver({
                        title = label,
                        glyph = glyphForHost(host),
                        kind = "platform",
                        group = "graph.linked",
                        found = true,
                        url = linkValue,
                        rows = {
                          { label = noctalia.tr("row.through"), value = label, open = linkValue },
                        },
                      })
                    end
                  end
                end
              end
            else
              ctx.deliver({
                title = "Gravatar",
                glyph = "user-circle",
                kind = "platform",
                found = false,
                url = "https://www.gravatar.com/" .. hash,
              })
            end
            opFinished()
          end)
        end, doneOne)

        internal = internal + 1
        ctx.dispatch(function(opFinished)
          local domain = lean:match("@(.+)$")
          if domain == nil then
            opFinished()
            return true
          end
          local url = "https://dns.google/resolve?name=" .. noctalia.string.urlEncode(domain) .. "&type=MX"
          return util.httpGet(url, nil, nil, function(res)
            local json = util.decodeJson(res.body)
            local servers = {}
            if util.statusOk(res) and type(json) == "table" and type(json.Answer) == "table" then
              for _, answer in ipairs(json.Answer) do
                if type(answer) == "table" and answer.type == 15 and type(answer.data) == "string" then
                  local data = noctalia.string.trim(answer.data)
                  if data ~= "" and data ~= "0 ." then
                    servers[#servers + 1] = data:gsub("%.?$", "")
                  end
                end
              end
            end
            if #servers > 0 then
              ctx.deliver({
                title = noctalia.tr("domain.title"),
                glyph = "world",
                kind = "entity",
                found = true,
                url = "https://" .. domain,
                rows = { { label = noctalia.tr("row.mail_servers"), value = table.concat(servers, " · ") } },
              })
            else
              ctx.deliver({
                title = noctalia.tr("domain.title"),
                glyph = "world",
                kind = "entity",
                found = false,
                url = "https://" .. domain,
                note = "note_no_mx",
              })
            end
            opFinished()
          end)
        end, doneOne)
      end

      if internal == 0 and not finished then
        finished = true
        completion()
      end
      return true
    end,
  }
end

function M.cpf(value, ctx)
  return {
    start = function(completion)
      local digits = brazil.onlyDigits(value)
      local valid = brazil.cpfIsValid(digits)
      local rows = {}
      table.insert(rows, { label = noctalia.tr("row.situation"), value = noctalia.tr(valid and "cpf.valid" or "cpf.invalid") })
      if #digits == 11 then
        table.insert(rows, { label = noctalia.tr("row.formatted"), value = brazil.cpfFormat(digits) })
        local ufr = brazil.cpfUfr(digits)
        if ufr then
          table.insert(rows, { label = noctalia.tr("row.uf_possible"), value = table.concat(ufr, ", ") })
        end
      end
      ctx.deliver({
        title = "CPF",
        glyph = "id",
        kind = "entity",
        found = valid,
        rows = rows,
      })
      completion()
      return true
    end,
  }
end

function M.phone(value, ctx)
  return {
    start = function(completion)
      local parsed = brazil.phoneParse(value)
      local rows = {}
      local card = { title = noctalia.tr("phone.title"), glyph = "phone", kind = "entity", found = parsed ~= nil }
      if parsed then
        table.insert(rows, { label = noctalia.tr("row.national"), value = parsed.national })
        table.insert(rows, { label = noctalia.tr("row.e164"), value = parsed.e164 })
        if parsed.ddd then
          table.insert(rows, { label = noctalia.tr("row.ddd"), value = parsed.ddd })
        end
        if parsed.uf then
          table.insert(rows, { label = noctalia.tr("row.uf"), value = parsed.uf })
        end
        if parsed.city then
          table.insert(rows, { label = noctalia.tr("row.city"), value = parsed.city })
        end
        if parsed.region then
          table.insert(rows, { label = noctalia.tr("row.region"), value = noctalia.tr("region." .. parsed.region) })
        end
        local classKey = parsed.class == "mobile" and "phone.mobile"
          or parsed.class == "landline" and "phone.landline"
          or parsed.class == "toll_free" and "phone.toll_free"
          or parsed.class == "commercial" and "phone.commercial"
          or parsed.class == "special" and "phone.special"
        if classKey then
          table.insert(rows, { label = noctalia.tr("row.line_type"), value = noctalia.tr(classKey) })
        end
        card.note = "note_phone_owner"
      else
        rows[1] = { label = noctalia.tr("row.status"), value = noctalia.tr("phone.invalid") }
      end
      card.rows = rows
      ctx.deliver(card)
      completion()
      return true
    end,
  }
end

return M