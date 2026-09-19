-- Lua entrypoint for the "hello" app.
function on_enter(root)
  local lbl = badge.ui.label(root, "hello, world")
  lbl:set_font_size("large")
  lbl:align("center", 0, 0)
end

function on_button(b, kind)
  if kind ~= badge.input.KIND.PRESSED then return end
  -- handle buttons here
end
