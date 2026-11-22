-- mazak.lua - Mazak Matrix programs: recognize them and walk the machining-center
-- toolpath for :Backplot. Nothing here grants an edit.
--   mill-turn (G109 heads): recognized, not drawn yet (turning needs XZ diameter plots)
-- The walk is forgiving, unlike dialect.prepare: what it cannot draw (macros, variables,
-- M98 subs, frame changes) is listed and skipped, and drawing picks up again at
-- the next fully known position. Each N block is drawn in its own work offset.
local Mo = require('gcode.motion')
local M = {}

-- lines -> { kind = 'machining' | 'millturn', reason } or nil
-- Okuma words (VC200 selectors, G116 tool changes) always win: never Mazak.
function M.identify(lines, source)
  source = source or require('gcode.profile').mask(lines)
  local first, millturn, offsets
  for i, code in ipairs(source) do
    local c = code:upper()
    if c:find('%f[%w]VC200%f[^%w]') or c:match('%f[%w]G116%f[%D]') then return nil end
    if not first and c:match('%S') and not c:match('^%s*%%%s*$') then first = c end
    millturn = millturn or (c:match('%f[%a]G109%f[%D]') and i)
    offsets = offsets or (c:match('%f[%a]G54%.1%s*P%d') and i)
  end
  local header
  for i = 1, math.min(#lines, 30) do
    local l = lines[i]:upper()
    if l:match('%f[%w]MAZAK%f[%W]') or l:match('%f[%w]MZK%f[%W]') then header = i; break end
  end
  local kind = millturn and 'millturn' or 'machining'
  -- G54.1 P is Fanuc/Haas extended offsets too: alone it is not Mazak. It only names the
  -- reason beside other evidence (here the header; the signals above decide on their own).
  local why = millturn and ('G109 head selection at line ' .. millturn)
    or first and first:match('^%s*<[^>]+>') and 'Mazak <name> program line'
    or offsets and header and ('G54.1 P work offset at line ' .. offsets)
    or header and ('Mazak named in the header at line ' .. header)
  if why then return { kind = kind, reason = why } end
end

-- program header rows: (N6 - 1.0 FACE MILL  B90 P2 T10010001) / ( N3 - .500 DRILL  B0 P1 - 20020001)
--   -> { label = 'N6', desc = '1.0 FACE MILL B90 P2', tool = '10010001', name = '1.0 FACE MILL' }
function M.header_row(line)
  local n, text = line:match('^%s*%(%s*N(%d+)%s*%-%s*(.-)%s*%)%s*$')
  if not n then return nil end
  local tool = text:match('%sT(%d+)%s*$') or text:match('%s%-%s*T?(%d+)%s*$')
  if tool then text = text:gsub('%s*%-?%s*T?' .. tool .. '%s*$', '') end
  text = vim.trim((text:gsub('%s+', ' ')))
  return { label = 'N' .. n, desc = text, tool = tool,
           name = vim.trim(text:match('^(.-)%s+B%-?%d') or text) }
end

-- the tool an M6 line loads: the first T (T1 T10010001 M6 loads T1, readies T10010001)
function M.change(code)
  local first, six
  for _, w in ipairs((Mo.words(code))) do
    if w.l == 'T' and not first and w.v:match('^%d+$') then first = w.v end
    if w.l == 'M' and tonumber(w.v) == 6 then six = true end
  end
  return six and first or nil
end

-- Some posts start the op-table counter starts at 1, so the header rows run one number
-- ahead of their blocks: (N2 - ...) describes block N1, (N3 - ...) block N2. Rows pair with blocks
-- by order; the tools in the rows need not match the blocks. N1000 and up (fixture sections,
-- N3000 end) are not ops. Rows are the header_row lines before the first N label.
--   -> { state = 'ahead', pairs = { { line, row, block, block_line, row_tool, block_tool } } }
--      { state = 'matched' }  every op row already has its block's number
--      { why = '...' }        anything else (nothing is paired)
function M.header_shift(lines)
  local rows, blocks, seen, current = {}, {}, {}, nil
  for i, l in ipairs(lines) do
    local n = tonumber(l:match('^%s*/?%s*N(%d+)'))
    if n then
      current = nil
      if n < 1000 and not seen[n] then
        seen[n] = true
        current = { n = n, line = i }
        blocks[#blocks + 1] = current
      end
    elseif #blocks == 0 and not seen.any then
      local row = M.header_row(l)
      local rn = row and tonumber(row.label:sub(2))
      if rn and rn < 1000 then rows[#rows + 1] = { n = rn, line = i, tool = row.tool } end
    end
    if n then seen.any = true end
    if current and not current.tool then
      current.tool = M.change((l:gsub('%b()', ''):gsub('%(.*$', '')))
    end
  end
  if #rows == 0 then return { why = 'no header rows below N1000' } end
  if #blocks == 0 then return { why = 'no N blocks below N1000' } end
  if #rows ~= #blocks then
    return { why = ('%d header row(s) for %d block(s): rows and blocks cannot be paired by order'):format(#rows, #blocks) }
  end
  local same, ahead = true, true
  for k, r in ipairs(rows) do
    same = same and r.n == blocks[k].n
    ahead = ahead and r.n == blocks[k].n + 1
  end
  if same then return { state = 'matched' } end
  if not ahead then return { why = 'the header rows are not numbered one ahead of the blocks' } end
  local pairs_ = {}
  for k, r in ipairs(rows) do
    pairs_[k] = { line = r.line, row = r.n, block = blocks[k].n, block_line = blocks[k].line,
                  row_tool = r.tool, block_tool = blocks[k].tool }
  end
  return { state = 'ahead', pairs = pairs_ }
end

M.AHEAD = 'header rows are one number ahead of the blocks (:HeaderRows fixes it)'

-- the rows of an 'ahead' header_shift with their blocks' numbers; only the N number changes
function M.fix_header_rows(lines, shift)
  local out = vim.list_slice(lines)
  for _, p in ipairs(shift.pairs) do
    out[p.line] = lines[p.line]:gsub('^(%s*%(%s*N)%d+', '%1' .. p.block, 1)
  end
  return out
end

local function num(v) return v and tonumber(v) or nil end
local CYCLE = { [73]=true, [74]=true, [76]=true, [81]=true, [82]=true, [83]=true, [84]=true,
                [85]=true, [86]=true, [87]=true, [88]=true, [89]=true, ['84.2']=true, ['84.3']=true }

-- lines -> sections { {name, s, e, desc, tool, moves} }, issues
-- moves use motion.walk's shape, so motion.points draws them.
function M.walk(lines)
  local P = require('gcode.profile')
  local source = P.mask(lines)
  local secs, issues = {}, {}
  local function note(i, text)
    issues[#issues + 1] = { line = i, text = 'Not drawn: ' .. text, kind = 'unsupported', invalid = false, blocking = false }
  end
  local st = { abs = true, g = 0, plane = 17, unit = 1 }
  local tool, sec
  local function reset() st.x, st.y, st.z = nil, nil, nil end
  local function open(i, name, desc)
    sec = { name = name, s = i, e = #lines, desc = desc, carried = tool, moves = {} }
    if #secs > 0 then secs[#secs].e = i - 1 end
    secs[#secs + 1] = sec
    reset()
  end
  for i, raw in ipairs(source) do
    local code = raw:upper():gsub('^%s*/%d?%s*', '')
    local label = code:match('^%s*N(%d+)')
    if label then
      -- operations carry a comment; a bare N88805 is a GOTO target inside one
      local c = lines[i]:match('%((.-)%)')
      if c then open(i, 'N' .. label, vim.trim((c:gsub('^[%*%s]+', ''):gsub('[%*%s]+$', '')))) end
      code = code:gsub('^%s*N%d+%s*', '')
    elseif code:match('^%s*O%d') then
      open(i, code:match('^%s*(O%d+)'), lines[i]:match('%((.-)%)') or '')
      code = ''
    end
    local c = vim.trim(code)
    local t = M.change(c)
    if t then tool = t; if sec then sec.tool = sec.tool or t end; reset() end
    if c == '' or c:match('^IF') or c:match('^GOTO') or c:match('^WHILE') or c:match('^END')
      or c:match('^#') or c:match('^%%') then
      goto continue
    end
    do
      -- G1 Z#753: like Okuma's Z=VC43, drawn at the last plain Z
      local n1, n2
      c, n1 = c:gsub('Z%s*%-?%s*#%d+', '')
      c, n2 = c:gsub('Z%s*%[[^%]]*%]', '')
      if n1 + n2 > 0 then
        issues[#issues + 1] = { line = i, text = 'Assumed: variable Z drawn at the last plain Z', kind = 'assumed', invalid = false, blocking = false }
      end
      local words, bad = Mo.words(c)
      local has, gs = {}, {}
      for _, w in ipairs(words) do
        if w.l == 'G' then gs[#gs + 1] = w.v else has[w.l] = has[w.l] or w end
      end
      local function g(n) for _, v in ipairs(gs) do if tonumber(v) == n and not v:find('.', 1, true) then return true end end end
      local function gd(s) for _, v in ipairs(gs) do if v == s then return true end end end
      if g(10) or g(4) then goto continue end                          -- offset data, dwell
      local probe = g(65) and has.P and (has.P.v == '9809' or has.P.v == '9810')
      if g(65) and not probe then goto continue end                   -- probe cycles return to start
      if c:find('[#%[]') or #bad > 0 then
        if has.X or has.Y or has.Z or has.B then reset(); note(i, 'variable or expression in a move') end
        goto continue
      end
      if g(65) then
        local p = has.P and has.P.v
        if (p == '9809' or p == '9810') and (has.X or has.Y or has.Z) then
          gs, has.P = { p == '9809' and '0' or '1' }, nil
        else goto continue end                                         -- probe cycles return to start
      end
      if c:match('%f[%a]M0*98%f[%D]') then reset(); note(i, 'M98 subprogram call (a sub in this file is drawn as its own entry)'); goto continue end
      if gd('34.1') and not st.cyc then note(i, 'G34.1 pattern without an active drilling cycle'); goto continue end
      if g(20) then st.unit = 1 elseif g(21) then st.unit = 1 / 25.4 end
      if g(90) then st.abs = true elseif g(91) then st.abs = false end
      if g(17) then st.plane = 17 elseif g(18) then st.plane = 18 elseif g(19) then st.plane = 19 end
      if g(80) then st.cyc = nil end
      if gd('54.1') or g(54) or g(55) or g(56) or g(57) or g(58) or g(59) then reset() end
      if has.B then reset() end                                        -- table turned: a new face
      if has.F and num(has.F.v) then st.f = num(has.F.v) end
      local cycle_line = false
      for _, v in ipairs(gs) do
        local n = tonumber(v)
        if n and n >= 0 and n <= 3 and n % 1 == 0 and not v:find('.', 1, true) then st.g = n; st.cyc = nil
        elseif CYCLE[v] or (CYCLE[n] and not v:find('.', 1, true)) or v == '72.1' then st.cyc = v; cycle_line = true end
      end
      if g(28) or g(30) then
        -- G91 G28 Z0: up to machine home; that axis is unknown in the work frame
        for _, a in ipairs({ 'X', 'Y', 'Z' }) do if has[a] then st[a:lower()] = nil end end
        goto continue
      end
      if not sec then goto continue end
      local function axis(l, cur)
        local w = has[l]
        if not w then return cur, false end
        local v = num(w.v)
        if not v then return nil, true end
        v = v * st.unit
        if st.abs then return v, true end
        return cur and cur + v or nil, true
      end
      if st.cyc == '72.1' then
        -- G72.1 circle milling (as these posts use it): X Y center, R start level, Z depth, Q = radius of the
        -- tool-center circle (half the diameter -/+ the tool radius for a bore / an outside).
        -- Modal: Z.02 R.02 on the next line mills the same circle again, deeper.
        if cycle_line then st.ccx, st.ccy = axis('X', st.x), axis('Y', st.y) end
        if has.Q and num(has.Q.v) then st.cq = num(has.Q.v) * st.unit end
        if has.Z and num(has.Z.v) then st.cz = num(has.Z.v) * st.unit end
        if has.R and num(has.R.v) then st.cr = num(has.R.v) * st.unit end
        local cx, cy, q, z = st.ccx, st.ccy, st.cq, st.cz
        if not (cx and cy and q and q > 0 and z) then note(i, 'G72.1 without X Y Q Z'); reset(); goto continue end
        local top = st.cr or z
        local start = { x = cx + q, y = cy, z = top }
        if st.x and st.y and st.z then
          sec.moves[#sec.moves + 1] = { line = i, kind = 'rapid', from = { x = st.x, y = st.y, z = st.z },
            to = { x = start.x, y = start.y, z = st.z }, tool = tool }
          sec.moves[#sec.moves + 1] = { line = i, kind = 'rapid', from = { x = start.x, y = start.y, z = st.z }, to = start, tool = tool }
        end
        local bottom = { x = start.x, y = start.y, z = z }
        if top ~= z then
          sec.moves[#sec.moves + 1] = { line = i, kind = 'feed', from = start, to = bottom, feed = st.f, tool = tool }
        end
        sec.moves[#sec.moves + 1] = { line = i, kind = 'arc', from = bottom, to = { x = bottom.x, y = bottom.y, z = z },
          cx = cx, cy = cy, r = q, cw = false, feed = st.f, tool = tool }
        issues[#issues + 1] = { line = i, text = 'Assumed: G72.1 drawn as one full circle of radius Q at Z (entry and direction not shown)',
          kind = 'assumed', invalid = false, blocking = false }
        st.x, st.y, st.z = start.x, start.y, top
        goto continue
      end
      if st.cyc then
        if has.Z and num(has.Z.v) then st.cz = num(has.Z.v) * st.unit end
        if has.R and num(has.R.v) then st.cr = num(has.R.v) * st.unit end
        local holes = {}
        if gd('34.1') then
          -- bolt-hole circle: X Y center, I radius, J first angle, K count
          local cx, cy, r, a, k = num(has.X and has.X.v), num(has.Y and has.Y.v), num(has.I and has.I.v), num(has.J and has.J.v) or 0, num(has.K and has.K.v)
          if cx and cy and r and k and k >= 1 then
            for n = 0, k - 1 do
              local ang = math.rad(a + 360 / k * n)
              holes[#holes + 1] = { x = (cx + r * math.cos(ang)) * st.unit, y = (cy + r * math.sin(ang)) * st.unit }
            end
          else note(i, 'G34.1 pattern without X Y I K') end
        elseif (has.X or has.Y or cycle_line) and not (has.L and num(has.L.v) == 0) then
          local x = axis('X', st.x); local y = axis('Y', st.y)
          holes[1] = { x = x, y = y }
        end
        for _, h in ipairs(holes) do
          local from = { x = st.x, y = st.y, z = st.z }
          local to = { x = h.x, y = h.y, z = st.z }
          if from.x and from.y and from.z and to.x and to.y then
            sec.moves[#sec.moves + 1] = { line = i, kind = 'rapid', from = from, to = to, tool = tool }
            if st.cz then
              sec.moves[#sec.moves + 1] = { line = i, kind = 'cycle', from = { x = h.x, y = h.y, z = st.cr or st.z },
                to = { x = h.x, y = h.y, z = st.cz }, feed = st.f, tool = tool }
            end
          end
          st.x, st.y = h.x, h.y
        end
        goto continue
      end
      local nx, mx = axis('X', st.x)
      local ny, my = axis('Y', st.y)
      local nz, mz = axis('Z', st.z)
      -- G3 I-.5 with no X Y Z: a full circle back to the start
      local circle = (st.g == 2 or st.g == 3) and (has.I or has.J or has.K) and vim.iter(gs):all(function(v)
        local n = tonumber(v); return n == 2 or n == 3 or n == 17 or n == 18 or n == 19 or n == 90 or n == 91 end)
      if not (mx or my or mz or circle) then goto continue end
      local from, to = { x = st.x, y = st.y, z = st.z }, { x = nx, y = ny, z = nz }
      if from.x and from.y and from.z and to.x and to.y and to.z then
        local m = { line = i, kind = st.g == 0 and 'rapid' or 'feed', from = from, to = to, feed = st.f, tool = tool }
        if st.g == 2 or st.g == 3 then
          m.kind, m.cw = 'arc', st.g == 2
          if st.plane ~= 17 then
            m.kind = 'feed'; note(i, 'G18/G19 arc drawn as a straight line')
          elseif has.I or has.J then
            m.cx = from.x + (num(has.I and has.I.v) or 0) * st.unit
            m.cy = from.y + (num(has.J and has.J.v) or 0) * st.unit
            m.r = math.sqrt((from.x - m.cx) ^ 2 + (from.y - m.cy) ^ 2)
          elseif has.R and num(has.R.v) then
            -- R arc: center on the perpendicular bisector; negative R = the long way round
            local r = num(has.R.v) * st.unit
            local dx, dy = to.x - from.x, to.y - from.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d > 0 and d <= 2 * math.abs(r) + 1e-6 then
              local h = math.sqrt(math.max(r * r - d * d / 4, 0))
              local side = ((st.g == 2) == (r > 0)) and -1 or 1
              m.cx = from.x + dx / 2 + side * h * -dy / d
              m.cy = from.y + dy / 2 + side * h * dx / d
              m.r = math.abs(r)
            else m.kind = 'feed'; note(i, 'R arc that cannot reach its end point') end
          else m.kind = 'feed'; note(i, 'arc without I/J or R') end
        end
        sec.moves[#sec.moves + 1] = m
      end
      st.x, st.y, st.z = nx, ny, nz
    end
    ::continue::
  end
  for _, s in ipairs(secs) do s.tool, s.carried = s.tool or s.carried, nil end
  return secs, issues
end

return M
