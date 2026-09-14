--!nonstrict
-- Bar widget: one icon that opens the GoAnime Tools panel.

local function render()
  barWidget.setGlyph(noctalia.getConfig("glyph"))
  barWidget.setTooltip(noctalia.tr("title"))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("mcookinho/goanime-tools:dashboard")
end

render()