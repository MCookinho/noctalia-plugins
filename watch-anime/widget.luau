--!nonstrict
-- Bar widget: one icon that opens the Watch Anime panel.
local util = require("./lib/util.luau")

local function render()
  barWidget.setGlyph(noctalia.getConfig("glyph"))
  barWidget.setTooltip(util.tr("title"))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("mcookinho/watch-anime:dashboard")
end

render()