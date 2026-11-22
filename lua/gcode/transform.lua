-- transform.lua - Cimco-style math on the selected lines (V first, or just the cursor line)
--   :Shift X.01 Y-.02 Z-.005 ... move absolute X/Y/Z (incremental G91 lines are left alone)
--   :Mirror X  /  :Mirror Y 1.5  flip about X0 (or X1.5); arcs and G41/G42 swap direction
--                                (G17 only: refuses G18/G19 arcs and comp)
--   :Rotate 90  /  :Rotate 90 1.0 2.0   turn XY (and I/J) about X0 Y0 (or the given X Y)
--   Mirror / Rotate: nothing carries past an O header - each sub starts over, the same as
--   a selection starting at that O line (position unknown, G90, G17, no arc).
--   :StripComments ............ remove (comments) - whole file unless lines are selected
-- One undo (u) puts it all back.
local U = require('gcode.util')
local Mo = require('gcode.motion')
local T = {}

-- 1.5 -> 1.5   -0.4 -> -.4   0 -> 0.   2.12345 -> 2.1235
function T.fmt(v)
  local s = string.format('%.4f', v):gsub('0+$', '')
  s = s:gsub('^(%-?)0%.', '%1.')
  if s == '.' or s == '-.' then s = '0.' end
  return s
end
local function signed(d) return (d >= 0 and '+' or '-') .. T.fmt(math.abs(d)) end

local function section_of(lines, l)
  for _, s in ipairs(Mo.sections(lines)) do if l >= s.s and l <= s.e then return s end end
end

-- modal state just before line l (G90/G91, G02/G03...)
local function state_before(lines, l)
  local sec = section_of(lines, l)
  if not sec or l <= sec.s then return { abs = true, g = 0, plane = 17 } end
  local _, _, st = Mo.walk(lines, { name = sec.name, s = sec.s, e = l - 1 })
  return st
end

-- O header lines: a sub starts over (nothing known), the same as a selection starting there
local function sub_starts(lines)
  local first = {}
  for _, s in ipairs(Mo.sections(lines)) do first[s.s] = true end
  return first
end

-- an arc on this line? (g = the motion mode after the line's own G words)
local function arcs(g, gs, w)
  if g ~= 2 and g ~= 3 then return false end
  if gs[2] or gs[3] then return true end
  for _, x in ipairs(w) do
    if x.l == 'X' or x.l == 'Y' or x.l == 'Z' or x.l == 'I' or x.l == 'J' or x.l == 'K' then return true end
  end
  return false
end

-- replace words in a line: reps = { {col, len, text}, ... }
local function apply(line, reps)
  table.sort(reps, function(a, b) return a.col > b.col end)
  for _, r in ipairs(reps) do
    line = line:sub(1, r.col - 1) .. r.text .. line:sub(r.col + r.len)
  end
  return line
end
local function wlen(w) return 1 + (w.expr and (1 + #w.expr) or #(w.v or '')) end

local function gwords(w)
  local gs = {}
  for _, x in ipairs(w) do if x.l == 'G' then gs[tonumber(x.v) or -1] = x end end
  return gs
end

-- ---------------------------------------------------------------------
vim.api.nvim_create_user_command('Shift', function(o)
  if not require('gcode.profile').interpret('Shift') then return end
  local d = {}
  for _, a in ipairs(o.fargs) do
    local l, v = a:upper():match('^([XYZ])([%+%-]?[%d%.]+)$')
    if not l or not tonumber(v) then return vim.notify('Usage: :Shift X.01 Y-.02 Z-.005') end
    d[l] = tonumber(v)
  end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local source=require('gcode.profile').mask(lines)
  local st = state_before(lines, o.line1)
  local abs, cyc = st.abs, st.cyc ~= nil
  local n, skipped = 0, 0
  for i = o.line1, o.line2 do
    local code = source[i]
    if Mo.is_nc(code) then
      local w = Mo.words(code)
      local gs = gwords(w)
      if gs[90] then abs = true end
      if gs[91] then abs = false end
      for g in pairs(gs) do if Mo.CYCLES[g] then cyc = true elseif g >= 0 and g <= 3 or g == 80 then cyc = false end end
      local special = gs[30] or gs[28] or gs[15] or gs[4]
      local reps = {}
      for _, x in ipairs(w) do
        local dv = d[x.l] or ((x.l == 'R' and cyc) and d.Z) or nil
        if dv and not special then
          if not abs then
            skipped = skipped + 1
          elseif x.expr then
            reps[#reps + 1] = { col = x.col, len = wlen(x), text = x.l .. '=' .. x.expr .. signed(dv) }
          elseif tonumber(x.v) then
            reps[#reps + 1] = { col = x.col, len = wlen(x), text = x.l .. T.fmt(tonumber(x.v) + dv) }
          end
        end
      end
      if #reps > 0 then lines[i] = apply(lines[i], reps); n = n + #reps end
    end
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.notify('Shifted ' .. n .. ' values' .. (skipped > 0 and ('  |  ' .. skipped .. ' incremental (G91) values left alone') or '')
    .. '  (u to undo)')
end, { nargs = '+', range = true, desc = 'Move X/Y/Z on the selected lines' })

-- ---------------------------------------------------------------------
vim.api.nvim_create_user_command('Mirror', function(o)
  if not require('gcode.profile').interpret('Mirror') then return end
  local axis = (o.fargs[1] or ''):upper()
  if axis ~= 'X' and axis ~= 'Y' then return vim.notify('Usage: :Mirror X  or  :Mirror Y 1.5') end
  local c = tonumber(o.fargs[2] or '0') or 0
  local ij = axis == 'X' and 'I' or 'J'
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local source=require('gcode.profile').mask(lines)
  local st = state_before(lines, o.line1)
  local abs, g, plane = st.abs, st.g, st.plane or 17
  local first = sub_starts(lines)
  local gave_g, n, warn = false, 0, {}
  for i = o.line1, o.line2 do
    if first[i] and i > o.line1 then abs, g, plane, gave_g = true, 0, 17, false end
    local code = source[i]
    if Mo.is_nc(code) then
      local w = Mo.words(code)
      local gs = gwords(w)
      if gs[90] then abs = true end
      if gs[91] then abs = false end
      for _, p in ipairs({ 17, 18, 19 }) do if gs[p] then plane = p end end
      local reps = {}
      for k, x in pairs(gs) do
        local sw = ({ [2] = 'G03', [3] = 'G02', [41] = 'G42', [42] = 'G41' })[k]
        if sw then reps[#reps + 1] = { col = x.col, len = wlen(x), text = sw } end
        if k >= 0 and k <= 3 then g = k; gave_g = true end
      end
      -- a ZX / YZ arc only turns the other way when the mirrored axis is in its plane:
      -- not worked out here, so G18/G19 arcs and comp are refused rather than guessed
      if plane ~= 17 and (gs[41] or gs[42] or arcs(g, gs, w)) then
        return vim.notify('Mirror refused: line ' .. i .. ' has an arc or cutter comp in G' .. plane
          .. ' (only G17 XY is mirrored) - nothing changed', vim.log.levels.WARN)
      end
      local moves = false
      for _, x in ipairs(w) do
        if x.l == axis or x.l == ij then
          if x.expr then
            warn[#warn + 1] = i
          elseif tonumber(x.v) then
            local v = tonumber(x.v)
            local nv = (x.l == ij or not abs) and -v or (2 * c - v)
            reps[#reps + 1] = { col = x.col, len = wlen(x), text = x.l .. T.fmt(nv) }
          end
        end
        if x.l == 'X' or x.l == 'Y' or x.l == 'Z' or x.l == 'I' or x.l == 'J' then moves = true end
      end
      -- an arc carried over from above the selection needs its own (swapped) G word
      if moves and not gave_g and (g == 2 or g == 3) then
        reps[#reps + 1] = { col = 1, len = 0, text = (g == 2 and 'G03 ' or 'G02 ') }
        gave_g = true
      end
      if #reps > 0 then lines[i] = apply(lines[i], reps); n = n + 1 end
    end
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  local msg = 'Mirrored ' .. axis .. ' about ' .. axis .. T.fmt(c) .. ' on ' .. n .. ' lines (G02/G03 and G41/G42 swapped)'
  if #warn > 0 then msg = msg .. '  |  variables NOT changed on line ' .. table.concat(warn, ', ') end
  -- the next line that moves (past blank / comment-only / M08 lines) is still the old arc;
  -- stop at a G00-G03, an O header or a label / CALL / RTS
  local k = o.line2 + 1
  while (g == 2 or g == 3) and k <= #lines and not first[k]
      and (U.trim(source[k]) == '' or Mo.is_nc(source[k])) do
    local w = Mo.words(source[k])
    local gs = gwords(w)
    if gs[0] or gs[1] or gs[2] or gs[3] then break end
    if arcs(g, gs, w) then
      msg = msg .. '  |  CHECK line ' .. k .. ': the arc keeps going past the selection'
      break
    end
    k = k + 1
  end
  vim.notify(msg .. '  (u to undo)')
end, { nargs = '+', range = true, desc = 'Mirror X or Y on the selected lines' })

-- ---------------------------------------------------------------------
vim.api.nvim_create_user_command('Rotate', function(o)
  if not require('gcode.profile').interpret('Rotate') then return end
  local deg = tonumber(o.fargs[1] or '')
  if not deg then return vim.notify('Usage: :Rotate 90   or   :Rotate 90 1.0 2.0  (about X1.0 Y2.0)') end
  local cx, cy = tonumber(o.fargs[2] or '0') or 0, tonumber(o.fargs[3] or '0') or 0
  local a = math.rad(deg)
  local ca, sa = math.cos(a), math.sin(a)
  local function rot(x, y) return ca * x - sa * y, sa * x + ca * y end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local source=require('gcode.profile').mask(lines)
  -- positions from each sub's own walk: nothing carries past an O header
  local at = {}
  for _, sec in ipairs(Mo.sections(lines)) do
    if sec.e >= o.line1 and sec.s <= o.line2 then
      for _, m in ipairs(Mo.walk(lines, { name = sec.name, s = sec.s, e = math.min(sec.e, o.line2) })) do
        if not at[m.line] then at[m.line] = m end
      end
    end
  end
  local st = state_before(lines, o.line1)
  local abs, g, plane = st.abs, st.g, st.plane or 17
  local first = sub_starts(lines)
  local n, warn = 0, {}
  for i = o.line1, o.line2 do
    if first[i] and i > o.line1 then abs, g, plane = true, 0, 17 end
    local code = source[i]
    if Mo.is_nc(code) then
      local w = Mo.words(code)
      local gs = gwords(w)
      if gs[90] then abs = true end
      if gs[91] then abs = false end
      for k = 0, 3 do if gs[k] then g = k end end
      for _, p in ipairs({ 17, 18, 19 }) do if gs[p] then plane = p end end
      -- turning XY can't keep a ZX / YZ arc in its plane
      if plane ~= 17 and arcs(g, gs, w) then
        return vim.notify('Rotate refused: line ' .. i .. ' has an arc in G' .. plane
          .. ' (only G17 XY arcs turn) - nothing changed', vim.log.levels.WARN)
      end
      local by = {}
      for _, x in ipairs(w) do by[x.l] = x end
      local reps = {}
      local function pair(wx, wy, nx, ny, lx, ly)
        local tx, ty = lx .. T.fmt(nx), ly .. T.fmt(ny)
        if wx and wy then
          reps[#reps + 1] = { col = wx.col, len = wlen(wx), text = tx }
          reps[#reps + 1] = { col = wy.col, len = wlen(wy), text = ty }
        else
          local wd = wx or wy
          reps[#reps + 1] = { col = wd.col, len = wlen(wd), text = tx .. ' ' .. ty }
        end
      end
      local ok = true
      for _, l in ipairs({ 'X', 'Y', 'I', 'J' }) do if by[l] and by[l].expr then ok = false end end
      if not ok then
        warn[#warn + 1] = i
      else
        if (by.X or by.Y) and not (gs[30] or gs[28]) then
          if abs then
            local m = at[i]
            if m and m.to.x and m.to.y then
              local nx, ny = rot(m.to.x - cx, m.to.y - cy)
              pair(by.X, by.Y, nx + cx, ny + cy, 'X', 'Y')
            else
              warn[#warn + 1] = i
            end
          else
            local nx, ny = rot(tonumber(by.X and by.X.v) or 0, tonumber(by.Y and by.Y.v) or 0)
            pair(by.X, by.Y, nx, ny, 'X', 'Y')
          end
        end
        if by.I or by.J then
          local ni, nj = rot(tonumber(by.I and by.I.v) or 0, tonumber(by.J and by.J.v) or 0)
          pair(by.I, by.J, ni, nj, 'I', 'J')
        end
      end
      if #reps > 0 then lines[i] = apply(lines[i], reps); n = n + 1 end
    end
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.notify('Rotated ' .. T.fmt(deg) .. ' deg on ' .. n .. ' lines' ..
    (#warn > 0 and ('  |  NOT changed (variables / position unknown): line ' .. table.concat(warn, ', ')) or '')
    .. '  (u to undo)')
end, { nargs = '+', range = true, desc = 'Rotate XY on the selected lines' })

-- ---------------------------------------------------------------------
vim.api.nvim_create_user_command('StripComments', function(o)
  if not require('gcode.profile').interpret('StripComments') then return end
  local lines = vim.api.nvim_buf_get_lines(0,0,-1,false)
  local regions={}
  require('gcode.profile').mask(lines,regions)
  local depth,quote=0,nil
  local messages={}
  for i=1,o.line2 do
    if i==o.line1 and depth>0 then
      return vim.notify('StripComments refused: range starts inside a comment; nothing changed',vim.log.levels.WARN)
    end
    local _
    _,depth,quote=require('gcode.profile').executable(lines[i],depth,quote)
    messages[i]=quote
  end
  if depth>0 then
    return vim.notify('StripComments refused: range ends inside a comment; nothing changed',vim.log.levels.WARN)
  end
  local out, n, gone = {}, 0, 0
  for i=o.line1,o.line2 do
    local l,new=lines[i],lines[i]
    for k=#regions[i],1,-1 do
      local r=regions[i][k]
      if r.kind=='comment' then new=new:sub(1,r.s-1)..new:sub(r.e+1) end
    end
    if new~=l then
      if not messages[i] then new=new:gsub('%s+$','') end
      n=n+1
    end
    if U.trim(new)=='' and U.trim(l)~='' then gone=gone+1 else out[#out+1]=new end
  end
  vim.api.nvim_buf_set_lines(0, o.line1 - 1, o.line2, false, out)
  vim.notify('Comments removed from ' .. n .. ' lines (' .. gone .. ' comment-only lines deleted)  (u to undo)')
end, { range = '%', desc = 'Remove (comments)' })

return T
