-- hints.lua - K on a word = what is it?      :Speeds = SFM / IPR per tool
-- Add your own in init.lua:   vim.g.gcode = { hints = { M123 = 'MY CUSTOM M CODE' } }
-- The G/M/word tables are the Okuma OSP meanings; other controls get dialect.hint.
local U = require('gcode.util')
local Mo = require('gcode.motion')
local cfg = require('gcode.config')
local H = {}

local G = {
  [0] = 'Rapid move', [1] = 'Straight feed move', [2] = 'Arc clockwise (I J = center from the start point)',
  [3] = 'Arc counterclockwise (I J = center from the start point)', [4] = 'Dwell - F or P = seconds',
  [15] = 'Work offset - H = which fixture offset (VZOF...[H])',
  [17] = 'XY plane', [18] = 'ZX plane', [19] = 'YZ plane', [20] = 'Inch', [21] = 'Metric',
  [30] = 'Go to a machine zero point - P = which one',
  [40] = 'Cutter comp OFF', [41] = 'Cutter comp LEFT (climb) - DA = this tool\'s own offset',
  [42] = 'Cutter comp RIGHT', [56] = 'Tool length offset ON - HA = this tool\'s own length',
  [71] = 'Return level for the drill cycles that follow (Z)', [73] = 'High-speed peck drill',
  [74] = 'Reverse tap', [76] = 'Fine bore - stops, shifts off the wall, then pulls out',
  [80] = 'Cancel drill cycle', [81] = 'Drill', [82] = 'Drill with a dwell at the bottom (P)',
  [83] = 'Deep peck drill (Q = peck)', [84] = 'Tap', [85] = 'Bore - feed in, feed out',
  [86] = 'Bore - feed in, spindle stop, rapid out', [87] = 'Back bore', [89] = 'Bore with dwell, feed out',
  [90] = 'Absolute positions', [91] = 'Incremental moves (from where it is now)',
  [94] = 'Feed per MINUTE', [95] = 'Feed per REV (taps: F = pitch)',
  [116] = 'Tool change macro (machine-builder or user G-code) - T tool, Q next tool to call up',
  [284] = 'Tap cycle - used with G95, F = pitch',
}
local M = {
  [0] = 'Program STOP', [1] = 'OPTIONAL stop (only if the panel switch is on)', [2] = 'End of program',
  [30] = 'End of program and rewind', [3] = 'Spindle ON clockwise', [4] = 'Spindle ON counterclockwise',
  [5] = 'Spindle STOP', [6] = 'Tool change', [8] = 'Coolant ON', [9] = 'Coolant OFF',
  [19] = 'Spindle orient (stop at the tool change angle)',
  [142] = 'Torque monitor OFF', [143] = 'Torque monitor ON',
  [278] = 'Chip conveyor OFF', [279] = 'Chip conveyor ON (M278 = off)',
}
local WORDS = {
  VMLOK = 'Machine lock - not 0 when it is ON', VRSTT = 'Restart mode - not 0 when it is ON',
  VACOD = 'Holds the VC number tied to the fixture offset in use (PS=VACOD). VC[VACOD] = 0 skips this part, 7 runs it',
  VTODW = 'Wear offset: VTODW[VTLCN,10001] = cutter (diameter) wear for the tool in the spindle',
  VTLCN = 'Tool in the spindle right now', VTLNN = 'Next tool (the one called up)',
  VTLD1 = 'Tool group number of a tool (backup tools)',
  VUACM = 'Alarm / message text - 16 characters max', VDOUT = 'VDOUT[992]=2 raises the alarm after VUACM',
  VORD = 'Override switch check (spindle / rapid / feed at 100%)',
  VSLNO = 'Load monitor register', VSLDT = 'Load monitor settings',
  VZOFX = 'Fixture offset X', VZOFY = 'Fixture offset Y', VZOFZ = 'Fixture offset Z',
  VZOFA = 'Fixture offset A', VZOFC = 'Fixture offset C',
  VS84 = 'Probe result - measured value',
  VS88 = 'Probe result - part found (7) or not (0)', VDIN = 'VC[199]=VDIN[1001] stops look-ahead (buffering)',
  CASCME = 'Collision avoidance model - CASCME EMPTY = none', EMPTY = 'No value (an argument that wasn\'t given)',
  FUP = 'Round UP to a whole number', FIX = 'Round DOWN to a whole number', ROUND = 'Round to nearest',
  RTS = 'End of subprogram - go back', NEND = 'Label at the end of a sub (part-skip jumps here)',
  CALL = 'Run a subprogram', GOTO = 'Jump to a label', DA = 'This tool\'s own cutter comp offset',
  HA = 'This tool\'s own length offset',
}
local VC = { [199] = 'Often used with VDIN to stop look-ahead (VC[199]=VDIN[1001])' }

-- row: the cursor line, so a label is looked up in its own program/sub first
local function lookup(word, lines, control, row, path)
  local w = word:upper()
  local context = require('gcode.profile').resolve(lines,control,path)
  if context.mode~='generic' then return {w..' - no controller selected'} end
  local extra = cfg.hints or {}
  if extra[w] then return { w .. ' - ' .. extra[w] } end
  if context.control~='okuma' then return require('gcode.dialect').hint(w,context.control) end
  local l, n = w:match('^([GM])(%d+)$')
  if l then
    local t = (l == 'G' and G or M)[tonumber(n)]
    local out = { w .. ' - ' .. (t or 'no hint yet - add one in vim.g.gcode.hints') }
    if l == 'M' then          -- what this program's own comments say about it
      for _, x in ipairs(lines) do
        local c = x:match('%f[%w]' .. w .. '%s*%((.-)%)') or x:match('%f[%w]M0*' .. n .. '%s*%((.-)%)')
        if c then out[#out + 1] = 'this program says: ' .. c break end
      end
    end
    return out
  end
  local vc = w:match('^VC(%d+)$')
  if vc then
    local k = tonumber(vc)
    local t = VC[k] or 'Common variable'
    local uses = 0
    for _, x in ipairs(lines) do if x:upper():find('%f[%w]' .. w .. '%f[%W]') then uses = uses + 1 end end
    return { w .. ' - ' .. t, uses .. ' lines use it  (:Uses ' .. w .. ' lists them)' }
  end
  if w:match('^O%w+$') then
    for _, x in ipairs(lines) do
      local d = x:match('^' .. w .. '%s*%((.-)%)')
      if d then return { w .. ' - sub in this program: ' .. d, 'gd jumps to it' } end
    end
    return { w .. ' - not in this file (a sub stored on the control?)' }
  end
  if w:match('^N%w+$') then
    -- OSP jumps stay inside their own program/sub (NEND is in nearly every sub): look there first
    local s, e = 1, #lines
    for _, sec in ipairs(row and Mo.sections(lines) or {}) do
      if sec.s <= row then s, e = sec.s, sec.e end
    end
    for _, range in ipairs({ { s, e }, { 1, #lines } }) do
      for i = range[1], range[2] do
        local x = lines[i]
        if U.tc(x):match('^' .. w .. '%f[%W]') or U.tc(x) == w then
          return { w .. ' - label on line ' .. i .. ':  ' .. U.trim(x), 'gd jumps to it' }
        end
      end
    end
  end
  if WORDS[w] then return { w .. ' - ' .. WORDS[w] } end
  return nil
end
H.lookup = lookup

local function show()
  if not require('gcode.profile').interpret('K') then return end
  local w = vim.fn.expand('<cword>')
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local t = lookup(w, lines, vim.b.gcode_control, vim.api.nvim_win_get_cursor(0)[1], vim.api.nvim_buf_get_name(0))
  if not t then return vim.notify('No hint for ' .. w .. ' - add one in vim.g.gcode.hints') end
  vim.lsp.util.open_floating_preview(t, 'text', { border = 'rounded', focusable = false })
end

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'gcode',
  callback = function(a) vim.keymap.set('n', 'K', show, { buffer = a.buf, desc = 'What is this code?' }) end,
})
if vim.bo.filetype == 'gcode' then vim.keymap.set('n', 'K', show, { buffer = 0, desc = 'What is this code?' }) end

-- ---------------------------------------------------------------------
-- :Speeds  -> per tool: diameter (from the tool list), S, SFM, cutting F, IPR
-- ---------------------------------------------------------------------
function H.diameter(desc)
  if not desc then return nil end
  local frac
  for v in desc:gmatch('([%d%./]+)"') do        -- first inch size; a decimal beats a fraction
    local a, b = v:match('^(%d+)/(%d+)$')
    if a then frac = frac or tonumber(a) / tonumber(b)
    elseif tonumber(v) then return tonumber(v) end
  end
  if frac then return frac end
  local mm = desc:match('(%d*%.?%d+)%s*MM')
  if mm then return tonumber(mm) / 25.4 end
  local lead = desc:match('^%s*(%d*%.?%d+)')
  return lead and tonumber(lead) or nil
end

vim.api.nvim_create_user_command('Speeds', function()
  if not require('gcode.profile').interpret('Speeds') then return end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local tools = {}
  local in_t = false
  for _, l in ipairs(lines) do
    if l:match('^%(T%-START') then in_t = true end
    if in_t then
      local n, d = l:match('^%((%d+)%s*;[^;]*;%s*(.-)%s*%)')
      if n then tools[n] = d end
    end
    if l:match('^%(T%-END') then break end
  end
  local secs, subtool = Mo.sub_tools(lines)
  local per, order = {}, {}
  for _, sec in ipairs(secs) do
    local t = subtool[sec.name]
    if t then
      local moves = Mo.walk(lines, sec, t)
      for _, m in ipairs(moves) do
        if m.kind ~= 'rapid' and m.kind ~= 'home' and m.feed and m.feed ~= cfg.fast_feed then
          if not per[t] then per[t] = { s = {}, f = {}, fpr = false }; order[#order + 1] = t end
          local p = per[t]
          if m.s then p.s[m.s] = true end
          p.f[m.feed] = true
          if m.fpr then p.fpr = true end
        end
      end
    end
  end
  local function range(set)
    local lo, hi
    for v in pairs(set) do lo = math.min(lo or v, v); hi = math.max(hi or v, v) end
    return lo, hi
  end
  local out = {
    'SPEEDS & FEEDS - cutting moves only' .. (cfg.fast_feed and (' (F' .. cfg.fast_feed .. ' moves left out)') or '') .. '   (q closes)',
    'Diameter comes from the tool list description. IPR = F / S. Divide IPR by the flutes for chip load.',
    '',
    string.format('%-6s %-7s %-12s %-12s %-14s %-14s', 'TOOL', 'DIA', 'S', 'SFM', 'F', 'IPR'),
  }
  for _, t in ipairs(order) do
    local p = per[t]
    local d = H.diameter(tools[t])
    local s1, s2 = range(p.s)
    local f1, f2 = range(p.f)
    local function r(a, b, fmt) if not a then return '-' end
      return a == b and string.format(fmt, a) or (string.format(fmt, a) .. '-' .. string.format(fmt, b)) end
    local sfm = (d and s1) and r(s1 * math.pi * d / 12, s2 * math.pi * d / 12, '%.0f') or '-'
    local ipr
    if p.fpr then ipr = r(f1, f2, '%.4f') .. ' (G95)'
    elseif s1 and f1 then ipr = r(f1 / s2, f2 / s1, '%.4f') else ipr = '-' end
    out[#out + 1] = string.format('%-6s %-7s %-12s %-12s %-14s %-14s', 'T' .. t, d and string.format('%.4f', d) or '?',
      r(s1, s2, '%d'), sfm, p.fpr and '-' or r(f1, f2, '%.2f'), ipr)
    if not tools[t] then out[#out] = out[#out] .. '  (not in tool list)' end
  end
  Mo.report('Speeds', out)
end, { desc = 'SFM and IPR per tool' })

return H
