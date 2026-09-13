--!nonstrict
-- Bar widget that toggles the OSINT Tools dashboard panel.
-- Add it from Settings → Bar → Widgets (type: mcookinho/osint-tools:bar).

local glyph = noctalia.getConfig("glyph")

local function render()
  barWidget.setGlyph(glyph)
  barWidget.setTooltip(noctalia.tr("title"))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("mcookinho/osint-tools:dashboard")
end

function onRightClick()
  noctalia.togglePanel("mcookinho/osint-tools:dashboard")
end

render()