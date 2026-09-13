--!nonstrict
-- Launcher provider: type `/osint <query>` to kick off an investigation.
local lastQuery = ""

local function L(key)
  return noctalia.tr(key)
end

function onQuery(query)
  local text = noctalia.string.trim(query or "")
  lastQuery = text
  if text == "" then
    launcher.setResults(query, {{
      id = "",
      title = L("launcher.hint"),
      subtitle = L("launcher.hint_subtitle"),
      glyph = "user-search",
    }})
    return
  end
  launcher.setResults(query, {{
    id = "run",
    title = L("launcher.title"),
    subtitle = L("launcher.subtitle"),
    glyph = "user-search",
  }})
end

function onActivate(id)
  if id ~= "run" then
    return
  end
  if lastQuery ~= "" then
    noctalia.state.set("pending_query", lastQuery)
  end
  noctalia.togglePanel("mcookinho/osint-tools:dashboard")
end