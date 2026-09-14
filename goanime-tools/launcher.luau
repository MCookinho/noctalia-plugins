--!nonstrict
-- Launcher provider: type `/goanime <query>` to open the GoAnime panel pre-filled.
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
      glyph = "movie",
    }})
    return
  end
  launcher.setResults(query, {{
    id = "run",
    title = noctalia.tr("launcher.title", { q = lastQuery }),
    subtitle = L("launcher.subtitle"),
    glyph = "movie",
  }})
end

function onActivate(id)
  if id ~= "run" then
    return
  end
  if lastQuery ~= "" then
    noctalia.state.set("goanime_pending_query", lastQuery)
  end
  noctalia.togglePanel("mcookinho/goanime-tools:dashboard")
end