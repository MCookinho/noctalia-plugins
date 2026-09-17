--!nonstrict
-- Launcher provider: type `/goanime <query>` to open the GoAnime panel pre-filled.
local util = require("./lib/util.luau")
local lastQuery = ""

local function L(key, subst)
  return util.tr(key, subst)
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
    title = util.tr("launcher.title", { q = lastQuery }),
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