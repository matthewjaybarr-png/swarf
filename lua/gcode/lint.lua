-- lint.lua - :Lint lists what Swarf finds wrong or cannot read, in the quickfix list.
-- It reads the program, never changes it. Sources: comment/message masking (every control),
-- the program structure (:Outline) and the moves (:Backplot) for a known control.
local P = require('gcode.profile')
local L = {}

-- lines, explicit control, path -> { {line, text, kind} }, sorted, one per line+text
function L.run(lines, explicit, path)
  local c = P.resolve(lines, explicit, path)
  local found = {}
  if c.mode == 'generic' then
    local ok, o = pcall(require('gcode.outline').build, lines, explicit, path)
    if ok then vim.list_extend(found, o.issues) else found[#found + 1] = { line = 1, text = 'Outline failed: ' .. tostring(o) } end
    local data = require('gcode.backplot').build(lines, nil, explicit, path)
    if data then vim.list_extend(found, data.issues) end
  else
    local _, issues = P.mask(lines)
    vim.list_extend(found, issues)
  end
  local seen, out = {}, {}
  for _, p in ipairs(found) do
    local key = (p.line or 0) .. '\0' .. p.text
    if not seen[key] then seen[key] = true; out[#out + 1] = { line = p.line or 1, text = p.text, kind = p.kind } end
  end
  table.sort(out, function(a, b) return a.line < b.line or (a.line == b.line and a.text < b.text) end)
  return out, c
end

vim.api.nvim_create_user_command('Lint', function()
  local buf = vim.api.nvim_get_current_buf()
  local out, c = L.run(vim.api.nvim_buf_get_lines(buf, 0, -1, false), vim.b.gcode_control, vim.api.nvim_buf_get_name(buf))
  local items = vim.tbl_map(function(p) return { bufnr = buf, lnum = p.line, text = p.text } end, out)
  vim.fn.setqflist({}, ' ', { title = 'Lint', items = items })
  local note = c.mode == 'generic' and '' or ' (comments only: ' .. c.reason .. ')'
  if #items == 0 then return vim.notify('Lint: nothing found' .. note) end
  vim.cmd('copen')
  vim.notify(('Lint: %d note(s)%s'):format(#items, note))
end, { desc = 'List problems in this program (quickfix)' })

return L
