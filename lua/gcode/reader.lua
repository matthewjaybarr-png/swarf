-- reader.lua - Haas and Toshiba (TOSNUC) programs: recognize them, describe their
-- operations for :Outline and walk the toolpath for :Backplot.
--   Haas:            O00032 program number, (HAAS ...) header comment, N1 T1 M06 (...)
--                    blocks, G154 P work offsets, M97 local subs after M30, M98 subs
--   Toshiba TOSNUC:  $61 program number, N on every line, T1(...) then M06, G57 H work
--                    offsets, B faces, machine-position retracts, [V3001=...] macros
-- Like mazak.lua the walk is forgiving: what it cannot draw is listed and skipped, and
-- drawing picks up again at the next fully known position. Assumptions are listed too.
local Mo = require('gcode.motion')
local R = {}

R.names = { haas = 'Haas', tosnuc = 'Toshiba TOSNUC', mazak = 'Mazak', ['mazak-matrix'] = 'Mazak Matrix', okuma = 'Okuma OSP' }

-- Haas and TOSNUC comments end with their line: (( DATE. 08-27-19 ) and N7 ( #39 (.0995) DRILL )
-- are whole comments (proven programs run with them), and a missing ) never hides the lines
-- below. (profile.mask follows the Okuma rules, where a comment runs on to the next line.)
-- Columns are kept.
function R.mask(lines)
  local out = {}
  for i, line in ipairs(lines) do
    if not line:find('[()]') then out[i] = line else
      local depth, chars = 0, {}
      for k = 1, #line do
        local ch = line:sub(k, k)
        if ch == '(' then depth = depth + 1 end
        chars[k] = (depth > 0 or ch == ')') and ' ' or ch
        if ch == ')' and depth > 0 then depth = depth - 1 end
      end
      out[i] = table.concat(chars)
    end
  end
  return out
end

-- your machines (config machine_controls), entries with a control: { ['101'] = { control, name } }
function R.table()
  local out = {}
  for id, e in pairs(require('gcode.config').machine_controls or {}) do
    if type(e) == 'string' then e = { control = e } end
    if type(e) == 'table' and e.control then out[tostring(id)] = e end
  end
  return out
end

-- machine numbers a header comment names: '#101-#102', 'MACH 102 ONLY', 'HAAS 101/102'
-- Only after # or a machine word: '#14001' and '#800=' are macro variables, not machines.
-- Upper case text. Each number goes in once: 'MACHINE #101' is read by both '#' and 'MACHINE'.
local function numbers(text, out)
  local function run(s)
    local n, rest = s:match('^(%d+)(.*)$')
    while n do
      if #n >= 2 and #n <= 4 and not rest:match('^%s*=') and not vim.tbl_contains(out, n) then out[#out + 1] = n end
      n, rest = rest:match('^%s*[%-/,&]%s*#?%s*(%d+)(.*)$')
    end
  end
  for _, key in ipairs({ '#', 'MACHINE', 'MACH', 'HAAS', 'MZK', 'MAZAK', 'TOSHIBA' }) do
    local from = 1
    while true do
      local s, e = text:find(key, from, true)
      if not s then break end
      if key == '#' or not text:sub(s - 1, s - 1):match('%w') then run((text:sub(e + 1):gsub('^[%.%s#]*', ''))) end
      from = e + 1
    end
  end
end

R.numbers = numbers

-- the machines the top of the program names in its comments: { {n, line}, ... }
function R.named(lines)
  local out = {}
  for i = 1, math.min(#lines, 30) do
    for text in lines[i]:upper():gmatch('%(([^()]*)%)?') do
      local found = {}
      numbers(text, found)
      for _, n in ipairs(found) do out[#out + 1] = { n = n, line = i } end
    end
  end
  return out
end

-- the folder a program is opened from, named for its machines: .../Machines/101,
-- .../Machines/101-102 (M101-M102 and 101 & 102 work too). Nearest folder first.
function R.folder(path, known)
  if not path or path == '' then return nil end
  local parts = vim.split((path:gsub('\\', '/')), '/', { plain = true })
  for k = #parts - 1, 1, -1 do
    local part = parts[k]:upper()
    if part:match('^[M#]?%d+[%s%-_,&/+M#%d]*$') then
      local control, nums = nil, {}
      for n in part:gmatch('%d+') do
        local e = known[n]
        if not e or (control and e.control ~= control) then control = false break end
        control = e.control; nums[#nums + 1] = n
      end
      if control then return { control = control, machines = nums, folder = parts[k] } end
    end
  end
end

-- lines (+ the file's path) -> { control, reason, machines } or nil
-- The program's own words decide first: a $61 program-number line is TOSNUC, an O-number
-- program with HAAS in its header is Haas. Then the machine number in the header comments,
-- then the folder (both through your machine list). A program with Okuma words is only ever
-- matched to one of your Okuma machines, never read as Haas or Toshiba.
function R.identify(lines, path)
  local source = R.mask(lines)
  local okuma
  -- Okuma words (VC1, CALL OSUB, RTS, G116, an OSET1 name) are never Haas or Toshiba,
  -- whatever the header or the folder says (the same words highlight.lua colors as Okuma)
  for _, code in ipairs(source) do
    local c = code:upper()
    if c:find('%f[%w]VC%[?%w') or c:find('%f[%w]CALL%s*O%w') or c:find('^%s*RTS%f[%W]')
      or c:find('%f[%w]G116%f[%D]') or c:find('^%s*O%u[%u%d]*%f[%W]') then okuma = true break end
  end
  local known = R.table()
  local count, dollar, onum = 0, nil, nil
  for i, code in ipairs(source) do
    local c = code:upper()
    if c:match('%S') and not c:match('^%s*%%%s*$') then
      count = count + 1
      if count <= 3 then dollar = dollar or (c:match('^%s*%$%w+%s*;?%s*$') and i) end
      if count <= 5 then onum = onum or (c:match('^%s*O%d+%s*;?%s*$') and i) end
      if count > 5 then break end
    end
  end
  local named, haas = {}, nil
  for _, m in ipairs(R.named(lines)) do
    if known[m.n] then named[#named + 1] = m end
  end
  for i = 1, math.min(#lines, 30) do
    for text in lines[i]:upper():gmatch('%(([^()]*)%)?') do
      if not haas and text:match('%f[%w]HAAS%f[%W]') then haas = i end
    end
  end
  local function machines(control)
    local out, seen = {}, {}
    for _, m in ipairs(named) do
      if known[m.n].control == control and not seen[m.n] then seen[m.n] = true; out[#out + 1] = m.n end
    end
    return out
  end
  local folder = R.folder(path, known)
  local function found(control, reason)
    local list = machines(control)
    if #list == 0 and folder and folder.control == control then list = folder.machines end
    return { control = control, reason = reason, machines = list }
  end
  if okuma then
    local m = machines('okuma')
    if #m > 0 then return found('okuma', 'machine #' .. m[1] .. ' in the header (your machine list)') end
    if folder and folder.control == 'okuma' then return found('okuma', 'folder ' .. folder.folder .. ' (your machine list)') end
    return nil
  end
  if dollar then return found('tosnuc', '$ program number at line ' .. dollar) end
  if onum and haas then return found('haas', 'HAAS named in the header at line ' .. haas) end
  local controls = {}
  for _, m in ipairs(named) do controls[known[m.n].control] = controls[known[m.n].control] or m end
  if vim.tbl_count(controls) == 1 then
    local control, m = next(controls)
    return found(control, 'machine #' .. m.n .. ' at line ' .. m.line .. ' (your machine list)')
  end
  if folder then return found(folder.control, 'folder ' .. folder.folder .. ' (your machine list)') end
end

-- 'Haas #101/#102', 'Toshiba TOSNUC'
function R.label(reader, machines)
  local name = R.names[reader] or reader
  local list = {}
  for _, n in ipairs(machines or {}) do list[#list + 1] = '#' .. n end
  return name .. (#list > 0 and (' ' .. table.concat(list, '/')) or '')
end

-- what :Control says about the machines (their names from your machine list)
function R.notes(machines)
  local known, out = R.table(), {}
  for _, n in ipairs(machines or {}) do
    local text = known[n] and (known[n].name or known[n].note)
    if text then out[#out + 1] = '#' .. n .. ': ' .. text end
  end
  return out
end

local function strip(text)
  return text and vim.trim((text:gsub('^[%*%s]+', ''):gsub('[%*%s]+$', ''):gsub('%s+', ' '))) or nil
end

-- Haas header rows: ( N1 4.0 X 45 R-M T144 P2-P5 ) / ( N1 - RGH SLOTS - MAIN - T4 - P2)
--   -> { label = 'N1', desc = '4.0 X 45 R-M P2-P5', tool = '144', name = '4.0 X 45 R-M' }
function R.header_row(line)
  local n, text = line:match('^%s*%(%s*N(%d+)%s+(.-)%s*%)%s*$')
  if not n or text:gsub('%b()', ''):find('[()]') then return nil end
  local tool
  for t in text:gmatch('%f[%w]T(%d+)%f[%W]') do tool = t end
  if tool then text = text:gsub('%f[%w]T' .. tool .. '%f[%W]', '') end
  text = vim.trim((text:gsub('^[%s%-]+', ''):gsub('[%s%-]+$', ''):gsub('%s+%-%s+%-%s+', ' - '):gsub('%s+', ' ')))
  if text == '' then return nil end
  return { label = 'N' .. tonumber(n), desc = text, tool = tool, name = vim.trim(text:match('^(.-)%s*%-?%s+P%d') or text) }
end

-- Toshiba tool lines: N1090 T118( **** 4.0" X 45 RGH MILL B0. SIDE H901 **** )
--   -> { tool = '118', desc = '4.0" X 45 RGH MILL B0. SIDE H901', name = '4.0" X 45 RGH MILL' }
function R.tool_line(line, code)
  local t = code:upper():match('^%s*N%d+%s*T(%d+)%s*$')
  local desc = t and strip(line:match('%((.*)%)'))
  if not desc or desc == '' then return nil end
  local name = desc:match('^(.-)%s+B%-?%d') or desc:match('^(.-)%s+H%d+$') or desc
  return { tool = t, desc = desc, name = vim.trim(name) }
end

-- Where the operations start: { [line] = { name, desc } }
--   Haas: an N label with a comment, or with a tool change before the next N label; not
--   after M30 (N2411 (ROTATION SUB) there is an M97 sub)
--   Toshiba (N on every line): the T line an M06 loads, and comment-only N lines
function R.starts(lines, family, source)
  source = source or R.mask(lines)
  local out, labels, ended = {}, {}, false
  for i, code in ipairs(source) do
    local c = code:upper()
    if c:match('^%s*O%d') then ended = false end
    local n = not c:match('^%s*/') and c:match('^%s*N(%d+)')
    if n and not (family == 'haas' and ended) then
      -- a Haas copy saved back from the control writes N01 for N1
      if family == 'haas' then n = tostring(tonumber(n)) end
      labels[#labels + 1] = { line = i, label = 'N' .. n, rest = vim.trim((c:gsub('^%s*N%d+', ''))) }
    end
    if not c:match('^%s*/') and c:match('%f[%a]M0*30%f[%D]') then ended = true end
  end
  local function six(c) return c:match('%f[%a]M0*6%f[%D]') ~= nil end
  if family == 'haas' then
    for k, l in ipairs(labels) do
      local stop = labels[k + 1] and labels[k + 1].line - 1 or #lines
      local comment = lines[l.line]:match('%((.-)%)')
      local change = false
      for i = l.line, stop do
        local c = source[i]:upper()
        if i > l.line and c:match('^%s*O%d') then break end
        if six(c) then change = true break end
      end
      if comment or change then out[l.line] = { name = l.label, desc = strip(comment) } end
    end
    return out
  end
  local at = {}
  for _, l in ipairs(labels) do at[l.line] = l end
  for _, l in ipairs(labels) do
    if l.rest == '' and lines[l.line]:match('%((.-)%)') then
      out[l.line] = { name = l.label, desc = strip(lines[l.line]:match('%((.*)%)')) }
    end
  end
  for i, code in ipairs(source) do
    if six(code:upper()) then
      -- the T line right before the M06 names the operation; else the M06 line itself
      local start, back = i, 0
      for j = i, math.max(1, i - 6), -1 do
        local c = source[j]:upper()
        if c:match('%S') then
          if c:match('%f[%a]T%d') then start = j break end
          back = back + 1
          if back > 3 then break end
        end
      end
      local l = at[start]
      if l then
        out[start] = { name = l.label, desc = strip(lines[start]:match('%((.*)%)')) or (out[start] and out[start].desc) }
      end
    end
  end
  return out
end

-- G codes each reader knows. Anything else is listed: not drawn when the line moves an axis,
-- an assumption (no move, no coordinate change) when it does not.
local KNOWN = {
  haas = { 0, 1, 2, 3, 4, 10, 12, 13, 17, 18, 19, 20, 21, 28, 30, 40, 41, 42, 43, 44, 49, 53, 54, 55, 56,
           57, 58, 59, 65, 68, 69, 70, 71, 72, 73, 74, 76, 77, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89,
           90, 91, 93, 94, 95, 98, 99, 103, 154, 187 },
  -- G998/G999: torque monitor on/off (the programs' own comments); not motion
  tosnuc = { 0, 1, 2, 3, 4, 12, 13, 17, 18, 19, 22, 23, 24, 25, 26, 27, 28, 40, 41, 42, 43, 44, 49,
             53, 57, 58, 70, 71, 72, 73, 77, 78, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 94,
             95, 98, 99, 201, 202, 222, 998, 999 },
}
for f, list in pairs(KNOWN) do
  local set = {}
  for _, g in ipairs(list) do set[g] = true end
  KNOWN[f] = set
end
local CYCLE = {
  haas = { [73] = true, [74] = true, [76] = true, [77] = true, [81] = true, [82] = true, [83] = true,
           [84] = true, [85] = true, [86] = true, [87] = true, [88] = true, [89] = true },
  tosnuc = { [77] = true, [78] = true, [81] = true, [82] = true, [83] = true, [84] = true, [85] = true,
             [86] = true, [87] = true, [88] = true, [89] = true },
}

local function num(v) return v and tonumber(v) or nil end

-- lines, 'haas' | 'tosnuc' -> sections { {name, s, desc, tool, moves} }, issues, arcs
-- moves use motion.walk's shape (arcs carry plane and center), so motion.points draws them.
-- arcs is for :ArcCheck: bad = { {line, r1, r2[, R]} | {line, text} } (in program units),
-- noarc = { line }, unchecked = { {line, why[, after]} } (an arc from a position that is not
-- known; after = the line that lost it).
-- The main program runs from the top to M30/M02; M97/M98 (Haas) and G72 $ (Toshiba) calls
-- to subs in this file are followed and drawn in the calling block.
-- opts.timing (CycleTime): moves from a position that is not known are kept too (axes = the
-- axes the line names), feeds are inch/min (G93: 1/min, inverse = true), G28/G30/G53 add a
-- 'home' move, a G98 hole from an unknown level starts at R; fourth return value
-- stats = { ntc, dwells = { {line, tool, seconds} }, probes = { {line, tool, name} }, unknown = { {line, text} } }.
function R.walk(lines, family, opts)
  local source = R.mask(lines)
  local starts = R.starts(lines, family, source)
  local haas = family == 'haas'
  local timing = opts and opts.timing
  local stats = { ntc = 0, dwells = {}, probes = {}, unknown = {} }
  local secs, issues, once, said = {}, {}, {}, {}
  local function issue(i, text, kind)
    -- a sub called 8 times says it once
    if said[i .. text] then return end
    said[i .. text] = true
    issues[#issues + 1] = { line = i, text = text, kind = kind, invalid = false, blocking = false }
  end
  -- each arc line once (a sub called 8 times is checked on its first call)
  local arcs, arced, lost = { bad = {}, noarc = {}, unchecked = {} }, {}, nil
  local tol = require('gcode.config').arc_tol or .0005
  local function arc_result(list, i, item)
    if arced[i] then return end
    arced[i] = true
    if list then arcs[list][#arcs[list] + 1] = item end
  end
  local function note(i, text) lost = { line = i, text = text }; issue(i, 'Not drawn: ' .. text, 'unsupported') end
  local function assume(i, text) issue(i, 'Assumed: ' .. text, 'assumed') end
  local function first(key, i, text) if not once[key] then once[key] = true; assume(i, text) end end
  -- every line once: upper case, block delete off; N labels and programs ($61 / O00032) by number
  local code, labels, programs, main, count = {}, {}, {}, 1, 0
  for i, raw in ipairs(source) do
    local c = raw:upper()
    code[i] = { c = c }
    if c:match('^%s*/') then code[i] = { c = c:gsub('^%s*/%d?%s*', ''), skip = true } end
    c = code[i].c
    local n = c:match('^%s*N(%d+)')
    if n then labels[tonumber(n)] = labels[tonumber(n)] or i end
    local p = haas and c:match('^%s*O(%d+)%s*;?%s*$') or not haas and c:match('^%s*%$(%w+)%s*;?%s*$')
    if p then
      code[i].program = p
      local key = p:gsub('^O', '')
      key = tonumber(key) or key
      programs[key] = programs[key] or i
    end
    -- text above the program's own number line is not program (notes, a stray comment end)
    if c:match('%S') and not c:match('^%s*%%%s*$') then
      count = count + 1
      if p and count <= 5 and main == 1 then main = i end
    end
  end
  -- a forward jump that only skips variable lines (#14021= ..., [V961=...]) changes no move
  local function harmless(from, to)
    if not to or to <= from then return false end
    for j = from + 1, to - 1 do
      local c = vim.trim((code[j].c:gsub('^%s*N%d+%s*', '')))
      if c ~= '' and not c:match('^#') and not c:match('^%[') then return false end
    end
    return true
  end
  local st = { abs = true, g = 0, plane = 17, unit = 1, ret = 98 }
  local sec, tool, pending
  local function reset() st.x, st.y, st.z = nil, nil, nil end
  local function open(i, name, desc)
    sec = { name = name, s = i, desc = desc, carried = tool, moves = {} }
    secs[#secs + 1] = sec
  end
  local function add(m)
    if not sec then return end
    m.tool = tool; m.feed = st.f
    if timing then
      m.inverse = st.fmode == 93 or nil
      m.feed = st.f and (m.inverse and st.f or st.f * st.unit)
      if st.fmode == 95 then m.fpr, m.s = true, st.s end
      if m.kind == 'cycle' then
        m.cyc = st.cyc
        -- Toshiba M843 synchronous tapping: G84 / G74 F is the pitch (F.0909 for 5/8-11)
        if st.sync and (st.cyc == 84 or st.cyc == 74) then m.fpr, m.s = true, st.s end
      end
    end
    sec.moves[#sec.moves + 1] = m
  end
  local function known(p) return p.x and p.y and p.z end
  -- a full circle of radius r around (cx, cy) at z; from the center and back when asked
  local function circle(i, cx, cy, r, z, cw, center)
    local at = { x = cx + r, y = cy, z = z }
    if center then add({ line = i, kind = 'feed', from = { x = cx, y = cy, z = z }, to = at }) end
    add({ line = i, kind = 'arc', from = at, to = { x = at.x, y = at.y, z = z }, cx = cx, cy = cy, r = r, cw = cw, plane = 17 })
    if center then add({ line = i, kind = 'feed', from = { x = at.x, y = at.y, z = z }, to = { x = cx, y = cy, z = z } }) end
  end
  local data, visits, stop = false, 0, false
  -- Haas #500= 0 (ROTATE MILL PATH IN DEGREES): a plain number set in the program, for G68 R#500
  local vars = {}
  local run

  -- one line; returns 'end' (the program ends) or 'return' (the sub ends)
  local function step(i, sub, depth)
    local ln = code[i]
    local c = ln.c
    if ln.program then
      if sub then note(i, 'a sub that runs into the next program without M99'); return 'return' end
      if #secs > 0 then return 'end' end
      open(i, haas and ('O' .. ln.program) or ('$' .. ln.program), (lines[i]:match('%((.-)%)')))
      return
    end
    if ln.skip then first('/', i, 'block-delete (/) lines are drawn, as with Block Delete off') end
    if c:match('^%s*N%d') then
      if not sub and starts[i] then open(i, starts[i].name, starts[i].desc) end
      c = c:gsub('^%s*N%d+%s*', '')
    end
    c = vim.trim(c)
    if c == '' or c == '%' then return end
    if data then
      -- TOSNUC G58 L50 ... G58 L99: parameter data, not motion
      if c:match('^G0*58%f[%D]') and c:match('L0*99%f[%D]') then data = false end
      return
    end
    -- macro statements: #vars, IF / GOTO / WHILE (Haas); [V..=..], [IF,..,GO,..] (TOSNUC)
    if haas and c:match('^#%s*3000%s*=') then
      -- #3000= 15 (CHECK FOR MISLOADED PARTS): the control stops with that alarm
      if sub then first('alarmsub', i, '#3000 alarm stop ends the sub it is in: drawing goes on after the call'); return 'return' end
      first('alarm', i, '#3000 alarm stop: drawn as if the program goes on at the next line')
      return
    end
    if haas and (c:match('^#') or c:match('^IF%f[%W]') or c:match('^WHILE%f[%W]') or c:match('^GOTO')
      or c:match('^END%d') or c:match('^DO%d')) or not haas and c:match('^%[') then
      local vn, rest = c:match('^#%s*(%d+)%s*=%s*(.-)%s*$')
      if vn then vars[vn] = tonumber(rest) and { v = tonumber(rest), line = i } or nil end
      local target = haas and c:match('GOTO%s*(%d+)') or not haas and c:match('GO%s*,%s*(%-?%d+)')
      local back = target and target:sub(1, 1) == '-'
      local to = target and labels[math.abs(tonumber(target))]
      if (target or c:match('^WHILE') or c:match('^END%d')) and (back or not harmless(i, to)) then
        first('jump', i, (haas and 'IF/GOTO jumps and loops' or '[IF,..,GO,..] jumps')
          .. ' are not followed: every line is drawn once, in order')
      end
      return
    end
    -- G72 $8100: a TOSNUC sub call (the $ is no address word)
    local call = not haas and c:match('^G0*72%s*%$(%w+)%s*$')
    if call then
      local key = call:gsub('^O', '')
      local at = programs[tonumber(key) or key]
      if at and depth < 4 then
        if run(at + 1, true, depth + 1) == 'end' then return 'end' end
      else reset(); note(i, 'G72 $' .. call .. ' calls a program that is not in this file') end
      return
    end
    -- G1 Z#753 / G00Z[V3]: like Okuma's Z=VC43, drawn at the last plain Z
    local n1, n2
    c, n1 = c:gsub('Z%s*%-?%s*#%d+', '')
    c, n2 = c:gsub('Z%s*%-?%s*%b[]', '')
    if n1 + n2 > 0 then assume(i, 'variable Z drawn at the last plain Z') end
    -- G68 R#500: a rotation by a variable angle (handled below)
    local varrot = haas and c:match('%f[%a]G0*68%f[%D]') and c:match('R%s*[#%[]')
    local rvar = varrot and c:match('R%s*#%s*(%d+)%s*$')
    if varrot then c = c:gsub('R%s*[#%[].*$', '') end
    if c:find('[#%[%]%$]') then
      if c:match('[XYZABC]') then reset(); note(i, 'variable or expression in a move') end
      return
    end
    local words, bad = Mo.words(c)
    for _, w in ipairs(words) do
      if w.l:match('^[XYZIJKRABC]$') and not num(w.v) then bad[#bad + 1] = { col = w.col, empty = w.l } end
    end
    if #bad > 0 then
      -- name the piece that does not read: F.19.2, G65 99811, a line starting with 1, an X with no number
      local at = bad[1].col
      local piece = c:sub(1, at - 1):match('(%S*)$') .. c:sub(at):match('^(%S*)')
      local why = bad[1].empty and (bad[1].empty .. ' has no number') or ('"' .. piece .. '" is not a G-code word')
      if c:match('[XYZABC]') then reset(); note(i, 'this line cannot be read (' .. why .. ')') end
      return
    end
    local has, gs, ms = {}, {}, {}
    for _, w in ipairs(words) do
      if w.l == 'G' then gs[#gs + 1] = w.v elseif w.l == 'M' then ms[#ms + 1] = tonumber(w.v) else has[w.l] = has[w.l] or w end
    end
    local function g(n) for _, v in ipairs(gs) do if tonumber(v) == n and not v:find('.', 1, true) then return true end end end
    local function m(n) for _, v in ipairs(ms) do if v == n then return true end end end
    local axes = has.X or has.Y or has.Z
    -- a tool change starts over: the spindle went to the changer
    if has.T and num(has.T.v) then pending = tostring(math.floor(num(has.T.v))) end
    if m(6) then
      tool = pending or tool
      if sec then sec.tool = sec.tool or tool end
      reset()
      stats.ntc = stats.ntc + 1
    end
    if not haas and m(843) then st.sync = true elseif not haas and m(845) then st.sync = nil end
    if m(60) then                                                      -- pallet change
      reset()
      if timing then stats.unknown[#stats.unknown + 1] = { line = i, text = 'M60 pallet change' } end
    end
    if g(4) then                                                       -- dwell: P / F is a time
      -- F and P. are seconds; Haas P1000 is milliseconds; a Toshiba P without a point is not known
      if timing then
        local f, p = has.F and num(has.F.v), has.P and num(has.P.v)
        local s = f or p and (has.P.v:find('.', 1, true) and p or haas and p / 1000) or nil
        stats.dwells[#stats.dwells + 1] = { line = i, tool = tool, seconds = s }
      end
      return
    end
    if haas and g(10) then reset(); return end                         -- offsets set by the program
    if not haas and g(58) then data = c:match('L0*50%f[%D]') ~= nil; return end
    for _, v in ipairs(gs) do
      local n = tonumber(v)
      local ok = n and (v:find('.', 1, true) and haas and v == '54.1' or not v:find('.', 1, true) and KNOWN[family][n])
      if not ok then
        if axes or has.A or has.B or has.C then reset(); note(i, 'G' .. v .. ' is not a code this reader knows'); return end
        assume(i, 'G' .. v .. ' (not a code this reader knows) neither moves the tool nor changes coordinates')
      end
    end
    -- modes (before any call: G90 M98 P2415 runs the sub in G90)
    if g(20) or g(21) or not haas and (g(70) or g(71)) then st.unitset = true end
    if g(20) or not haas and g(70) then st.unit = 1 elseif g(21) or not haas and g(71) then st.unit = 1 / 25.4 end
    if g(90) then st.abs = true elseif g(91) then st.abs = false end
    if g(17) then st.plane = 17 elseif g(18) then st.plane = 18 elseif g(19) then st.plane = 19 end
    if g(98) then st.ret = 98 elseif g(99) then st.ret = 99 end
    if g(80) then st.cyc, st.cz, st.cr = nil, nil, nil end
    if g(93) then st.fmode = 93 elseif g(94) then st.fmode = nil elseif g(95) then st.fmode = 95 end
    if has.S and num(has.S.v) then st.s = num(has.S.v) end
    if g(41) or g(42) then first('comp', i, 'cutter compensation (G41/G42) is not applied: the programmed path is drawn, not the tool center') end
    -- (a G65 F is the macro's own feed, not the modal one)
    if has.F and num(has.F.v) and not (timing and haas and g(65)) then st.f = num(has.F.v) end
    if axes and not st.unitset then first('unit', i, 'inch units (the program does not say ' .. (haas and 'G20' or 'G70') .. ')') end
    -- program flow: ends, M97 local subs (N label), M98 subs (O program), M99 returns
    if m(30) or m(2) then
      -- Toshiba: N5100 M30 then N77777 T15(...): a second part, started by hand after the
      -- part is turned; it is drawn too (Haas lines after M30 are M97 subs)
      if haas or sub then return 'end' end
      for j = i + 1, #lines do
        local nc = vim.trim((code[j].c:gsub('^%s*N%d+', '')))
        if code[j].program then return 'end' end
        if nc ~= '' and nc ~= '%' then
          reset()
          first('parts', i, 'the program goes on after M' .. (m(30) and '30' or '02')
            .. ' (a second part started by hand): what follows is drawn too')
          return
        end
      end
      return 'end'
    end
    if haas and (m(97) or m(98)) then
      local p = has.P and num(has.P.v)
      local at = p and (m(97) and labels[p] or programs[p])
      local times = has.L and num(has.L.v) or 1
      local word = (m(97) and 'M97 P' or 'M98 P') .. (has.P and has.P.v or '?')
      if at and depth < 4 and times >= 0 and times <= 100 then
        for _ = 1, times do
          if run(m(97) and at or at + 1, true, depth + 1) == 'end' then return 'end' end
        end
      else
        reset()
        note(i, word .. (at and ' (nested too deep or repeated too often)'
          or m(97) and ' has no N' .. (has.P and has.P.v or '') .. ' in this file' or ' calls a program that is not in this file'))
      end
      return
    end
    if m(99) then return sub and 'return' or 'end' end
    -- Haas probe macros: P9810 is a protected move (drawn as a feed); measuring cycles
    -- return to their start point; P9832/P9833 switch the probe on and off
    local oneshot
    local function probe(p) if timing then stats.probes[#stats.probes + 1] = { line = i, tool = tool, name = 'G65 P' .. p } end end
    if haas and g(65) then
      local p = has.P and has.P.v
      if (p == '9810' or p == '9809') and axes then oneshot = 1
      elseif p == '9832' or p == '9833' then probe(p); return
      elseif p and p:match('^98[12]%d$') then
        first('probe', i, 'Probe measuring cycles (G65 P9811-P9823) return to their start point; their touch moves are not drawn')
        probe(p)
        return
      else reset(); note(i, 'G65 P' .. (p or '?') .. ' macro call'); return end
    end
    -- work offsets and faces: the position is unknown until the next full X Y Z
    if haas and (g(54) or g(55) or g(56) or g(57) or g(58) or g(59) or g(154) or vim.tbl_contains(gs, '54.1')) then reset() end
    if not haas and (g(57) or g(53)) then reset() end                 -- G57 H fixture offset; G53 cancels it
    if has.B or not haas and has.A then reset() end                   -- table turned: a new face
    if g(43) or g(44) or g(49) then st.z = nil end                     -- tool length on/off moves the Z frame
    if haas and (has.A or has.C) then
      -- G0 A90.: the part turned to a new face, the X Y Z on the line start it; an A that
      -- moves while cutting (G1, G93) is a 4th-axis cut, not drawn
      local gm = st.g
      for _, v in ipairs(gs) do
        local n = not v:find('.', 1, true) and tonumber(v)
        if n and n >= 0 and n <= 3 then gm = n end
      end
      reset()
      if gm ~= 0 or g(93) then note(i, 'rotary ' .. (has.A and 'A' or 'C') .. ' cut (4th axis)'); return end
    end
    if haas and g(53) or g(28) or g(30) or not haas and g(73) then
      -- machine position (Haas G53, G28/G30 home, TOSNUC G73 Z47.): those axes are unknown here
      if timing and axes then
        local at = { x = st.x, y = st.y, z = st.z }
        add({ line = i, kind = 'home', from = at, to = at })
      end
      for _, a in ipairs({ 'X', 'Y', 'Z' }) do if has[a] then st[a:lower()] = nil end end
      return
    end
    -- Haas G68 rotation: drawn turned about its center; a variable angle stops the drawing
    if haas and g(69) then st.rot = nil; reset() end
    if haas and g(68) then
      local x, y = st.x, st.y
      reset()
      local r = not varrot and has.R and num(has.R.v)
      if rvar and vars[rvar] and not once.jump then
        -- G68 R#500 after #500= 0 with no jump in between: the angle is that number
        r = vars[rvar].v
        assume(i, 'G68 R#' .. rvar .. ' drawn with #' .. rvar .. ' = ' .. vars[rvar].v .. ' (set at line ' .. vars[rvar].line .. ')')
      end
      local cx, cy = has.X and num(has.X.v), has.Y and num(has.Y.v)
      local prev = not st.abs and st.rot or nil
      if not r then st.rot = false; note(i, 'G68 rotation by a variable angle: moves until G69 are not drawn'); return end
      if cx or cy then
        local ax, ay = (cx or 0) * st.unit, (cy or 0) * st.unit
        if not st.abs then ax, ay = x and x + ax, y and y + ay end
        st.rot = ax and ay and { a = (prev and prev.a or 0) + r, x = ax, y = ay } or false
      elseif prev then st.rot = { a = prev.a + r, x = prev.x, y = prev.y }
      elseif x and y then
        -- no X Y: it turns about the position it is read at
        st.rot = { a = r, x = x, y = y }
        if r ~= 0 and (math.abs(x) > 1e-9 or math.abs(y) > 1e-9) then
          assume(i, string.format('G68 without X Y turns about the current position X%.4f Y%.4f', x / st.unit, y / st.unit))
        end
      else st.rot = false end
      if st.rot == false then note(i, 'G68 rotation about an unknown center: moves until G69 are not drawn') end
      return
    end
    if st.rot == false then return end
    if not haas and (g(201) or g(202)) then reset(); note(i, 'G' .. (g(201) and '201' or '202') .. ' probe cycle (its moves are not known here)'); return end
    if not sec then return end
    for _, l in ipairs({ 'X', 'Y', 'Z', 'I', 'J', 'K', 'R' }) do
      local w = has[l]
      if w and w.v and not w.v:find('.', 1, true) and num(w.v) and num(w.v) ~= 0 and not (haas and g(65)) then
        first('decimal', i, 'values without a decimal point (' .. l .. w.v .. ') are whole ' .. (st.unit == 1 and 'inches' or 'millimeters'))
      end
    end
    local function axis(l, cur)
      local w = has[l]
      if not w then return cur, false end
      local v = num(w.v)
      if not v then return nil, true end
      v = v * st.unit
      if st.abs then return v, true end
      return cur and cur + v or nil, true
    end
    -- circles: Haas G12/G13 circular pocket (I, or K the finished radius; Z depth, or a step
    -- in G91 with L passes); TOSNUC G12/G13, G22/G23 true circle (R) around the current
    -- position; TOSNUC G222 X Y I circle (a custom circle-milling macro on some controls)
    local gc = g(12) and 12 or g(13) and 13 or not haas and (g(22) and 22 or g(23) and 23) or nil
    if gc then
      local word = haas and (has.K and 'K' or 'I') or 'R'
      local r = has[word] and num(has[word].v)
      local cx, cy = st.x, st.y
      if not (r and r > 0 and cx and cy and (st.z or has.Z and st.abs)) then
        reset(); note(i, 'G' .. gc .. ' circle without a known center, radius or depth'); return
      end
      r = r * st.unit
      local depths, passes = {}, haas and has.L and num(has.L.v) or 1
      if has.Z and num(has.Z.v) then
        local z = num(has.Z.v) * st.unit
        for k = 1, math.max(1, passes) do depths[#depths + 1] = st.abs and z or st.z + z * k end
      else depths[1] = st.z end
      local z0 = st.z
      for _, z in ipairs(depths) do
        if z0 and z0 ~= z then add({ line = i, kind = 'feed', from = { x = cx, y = cy, z = z0 }, to = { x = cx, y = cy, z = z } }) end
        circle(i, cx, cy, r, z, gc == 12 or gc == 22, true)
        z0 = z
      end
      st.z = depths[#depths]
      assume(i, 'G' .. gc .. ' drawn as ' .. (#depths > 1 and (#depths .. ' full circles') or 'a full circle') .. ' of radius '
        .. word .. has[word].v .. ' around the current position: the finished size, the tool center runs one tool radius'
        .. (has.D and (' (D' .. has.D.v .. ')') or '') .. ' inside; entry, stepover and exit are not shown'
        .. (not haas and has.I and ('; I' .. has.I.v .. ' is not drawn') or ''))
      return
    end
    if not haas and g(222) then
      local cx, cy = num((has.X or {}).v), num((has.Y or {}).v)
      local r, z = num((has.I or {}).v), num((has.Z or {}).v)
      if not (cx and cy and r and r > 0 and z and st.abs) then reset(); note(i, 'G222 without X Y I Z'); return end
      circle(i, cx * st.unit, cy * st.unit, r * st.unit, z * st.unit, false, false)
      assume(i, 'G222 (a custom circle-milling macro) drawn as one full circle of radius I' .. has.I.v
        .. ' around X Y at Z: the tool radius' .. (has.D and (' (D' .. has.D.v .. ')') or '') .. ' is not applied; entry and direction are not shown')
      st.x, st.y, st.z = nil, nil, z * st.unit
      return
    end
    -- canned cycles: a hole at X Y (or at each bolt-pattern position), R start, Z bottom;
    -- back to the start level (G98) or to R (G99)
    if not oneshot then
      local cycle_line = false
      for _, v in ipairs(gs) do
        local n = not v:find('.', 1, true) and tonumber(v)
        if n and n >= 0 and n <= 3 then st.g = n; st.cyc = nil
        elseif n and CYCLE[family][n] then st.cyc = n; cycle_line = true; st.top = st.z
        elseif n == 79 and not haas then st.cyc = nil; reset(); note(i, 'G79 back boring'); return end
      end
      local pattern = haas and (g(70) and 70 or g(71) and 71 or g(72) and 72)
      if pattern and not st.cyc then reset(); note(i, 'bolt pattern G' .. pattern .. ' without an active drilling cycle'); return end
      if st.cyc then
        if has.Z and num(has.Z.v) then st.cz = num(has.Z.v) * st.unit end
        if has.R and num(has.R.v) then st.cr = num(has.R.v) * st.unit end
        if not st.abs and (has.Z or has.R) then st.cz, st.cr = nil, nil end
        local holes = {}
        if pattern == 70 or pattern == 71 then
          -- bolt hole circle (G70) / arc (G71) around the current position:
          -- I radius, J first angle, K angle step (G71), L holes
          local r, a, k, l = num((has.I or {}).v), num((has.J or {}).v) or 0, num((has.K or {}).v), num((has.L or {}).v)
          if pattern == 70 and l and l > 0 then k = 360 / l end
          if st.x and st.y and r and k and l and l >= 1 then
            for n = 0, l - 1 do
              local ang = math.rad(a + k * n)
              holes[#holes + 1] = { x = st.x + r * st.unit * math.cos(ang), y = st.y + r * st.unit * math.sin(ang) }
            end
          else note(i, 'bolt pattern G' .. pattern .. ' without a known center or I J L') end
        elseif pattern == 72 then reset(); note(i, 'G72 bolt holes along an angle')
        elseif (has.X or has.Y or cycle_line) and not (has.L and num(has.L.v) == 0) then
          holes[1] = { x = (axis('X', st.x)), y = (axis('Y', st.y)) }
        elseif has.X or has.Y then
          st.x, st.y = axis('X', st.x), axis('Y', st.y)                -- L0: only positions
        end
        for _, h in ipairs(holes) do
          local r, z = st.cr, st.cz
          -- CycleTime times Z back to R inside the cycle move: only R to the return level is a rapid
          local up = timing and r or z
          if st.x and st.y and st.z and h.x and h.y and (st.x ~= h.x or st.y ~= h.y) then
            add({ line = i, kind = 'rapid', from = { x = st.x, y = st.y, z = st.z }, to = { x = h.x, y = h.y, z = st.z } })
          end
          if timing and r and z and not (h.x and h.y and st.z) then
            -- from a position that is not known: an approach to R (only the hole's depth counts);
            -- a G98 hole from a level that is not known goes back to R
            local back = st.ret == 99 and r or st.top or st.z or r
            if st.ret == 98 and not (st.top or st.z) then
              first('hole', i, 'a G98 hole from a level that is not known is timed as if it starts at R')
            end
            local hx, hy = h.x or 0, h.y or 0
            add({ line = i, kind = 'rapid', from = { x = st.x, y = st.y, z = st.z }, to = { x = h.x, y = h.y, z = r },
              axes = { x = true, y = true, z = true } })
            add({ line = i, kind = 'cycle', from = { x = hx, y = hy, z = r }, to = { x = hx, y = hy, z = z } })
            add({ line = i, kind = 'rapid', from = { x = hx, y = hy, z = up }, to = { x = hx, y = hy, z = back } })
            st.z = back
          elseif h.x and h.y and r and z and st.z then
            if st.z ~= r then add({ line = i, kind = 'rapid', from = { x = h.x, y = h.y, z = st.z }, to = { x = h.x, y = h.y, z = r } }) end
            add({ line = i, kind = 'cycle', from = { x = h.x, y = h.y, z = r }, to = { x = h.x, y = h.y, z = z } })
            local back = st.ret == 99 and r or st.top or st.z
            add({ line = i, kind = 'rapid', from = { x = h.x, y = h.y, z = up }, to = { x = h.x, y = h.y, z = back } })
            st.z = back
          elseif not (r and z) then
            note(i, 'G' .. st.cyc .. ' hole without ' .. (r and 'a Z depth' or z and 'an R level' or 'R and Z')
              .. ' (where it starts or stops feeding is not known)')
          end
          st.x, st.y = h.x, h.y
        end
        if pattern then st.x, st.y = nil, nil end                        -- where it ends is not shown
        return
      end
    end
    -- straight moves and arcs
    local gm = oneshot or st.g
    local nx, mx = axis('X', st.x)
    local ny, my = axis('Y', st.y)
    local nz, mz = axis('Z', st.z)
    local pl = Mo.PLANES[st.plane]
    local ci, cj = has[pl.i], has[pl.j]
    local arc = gm == 2 or gm == 3
    -- G3 I-.5 with no end point: a full circle back to the start
    local full = arc and (ci or cj) and not (mx or my or mz)
    if not (mx or my or mz or full) then return end
    local from, to = { x = st.x, y = st.y, z = st.z }, { x = nx, y = ny, z = nz }
    if known(from) and known(to) then
      local mv = { line = i, kind = gm == 0 and 'rapid' or 'feed', from = from, to = to, plane = st.plane }
      if arc then
        mv.kind, mv.cw = 'arc', gm == 2
        local a, b = pl.a, pl.b
        if ci or cj then
          mv['c' .. a] = from[a] + (num(ci and ci.v) or 0) * st.unit
          mv['c' .. b] = from[b] + (num(cj and cj.v) or 0) * st.unit
          mv.r = math.sqrt((from[a] - mv['c' .. a]) ^ 2 + (from[b] - mv['c' .. b]) ^ 2)
          local r2 = math.sqrt((to[a] - mv['c' .. a]) ^ 2 + (to[b] - mv['c' .. b]) ^ 2)
          if math.abs(r2 - mv.r) > 0.002 then
            assume(i, string.format('the arc ends %.4f off its radius: drawn on its start radius', math.abs(r2 - mv.r) / st.unit))
          end
          arc_result(math.abs(r2 - mv.r) > tol * st.unit and 'bad', i, { line = i, r1 = mv.r / st.unit, r2 = r2 / st.unit })
        elseif has.R and num(has.R.v) then
          -- R arc: center on the perpendicular bisector; negative R = the long way round
          local r = num(has.R.v) * st.unit
          local da, db = to[a] - from[a], to[b] - from[b]
          local d = math.sqrt(da * da + db * db)
          if d > 0 and d <= 2 * math.abs(r) + 1e-6 then
            local h = math.sqrt(math.max(r * r - d * d / 4, 0))
            local side = ((gm == 2) == (r > 0)) and -1 or 1
            mv['c' .. a] = from[a] + da / 2 + side * h * -db / d
            mv['c' .. b] = from[b] + db / 2 + side * h * da / d
            mv.r = math.abs(r)
            arc_result(nil, i)
          else
            mv.kind = 'feed'; note(i, 'R arc that cannot reach its end point (drawn straight)')
            if d == 0 then arc_result('bad', i, { line = i, text = 'R arc that ends where it starts (R cannot make a full circle)' })
            else arc_result(d / 2 - math.abs(r) > tol * st.unit and 'bad', i, { line = i, r1 = math.abs(r) / st.unit, r2 = d / 2 / st.unit, R = true }) end
          end
        else mv.kind = 'feed'; arc_result('noarc', i, i); note(i, 'arc without I J K or R (drawn straight)') end
      end
      if st.rot then
        -- G68: every point (and the arc center) turned about the rotation center
        local ca, sa = math.cos(math.rad(st.rot.a)), math.sin(math.rad(st.rot.a))
        local function turn(p, xk, yk)
          local dx, dy = p[xk] - st.rot.x, p[yk] - st.rot.y
          p[xk], p[yk] = st.rot.x + dx * ca - dy * sa, st.rot.y + dx * sa + dy * ca
        end
        mv.from, mv.to = { x = from.x, y = from.y, z = from.z }, { x = to.x, y = to.y, z = to.z }
        turn(mv.from, 'x', 'y'); turn(mv.to, 'x', 'y')
        if mv.kind == 'arc' then
          if st.plane == 17 then turn(mv, 'cx', 'cy')
          else mv.kind = 'feed'; note(i, 'G18/G19 arc under a G68 rotation (drawn straight)') end
        end
      end
      add(mv)
      if timing and oneshot then
        -- G65 P9810 X.. F..: the protected move runs at the macro's F
        mv.feed, mv.inverse, mv.fpr = has.F and num(has.F.v) and num(has.F.v) * st.unit, nil, nil
      end
    else
      if arc and sec then
        arc_result('unchecked', i, { line = i, after = lost and lost.line, why = lost and lost.text or 'the start point is not known' })
      end
      -- a rapid from a position not known is an approach; a feed or arc from one has no length
      if timing then
        add({ line = i, kind = gm == 0 and 'rapid' or 'feed', from = from, to = to, plane = st.plane,
          axes = not arc and { x = mx, y = my, z = mz } or nil })
      end
    end
    st.x, st.y, st.z = nx, ny, nz
  end

  -- from line `from` until the program (main) or the sub (M99) ends
  run = function(from, sub, depth)
    for i = from, #lines do
      visits = visits + 1
      if visits > 200000 then
        if not stop then
          note(i, 'the rest of the program: its subs repeat too often to draw')
          arcs.unchecked[#arcs.unchecked + 1] = { line = i, why = 'the subs repeat too often to follow' }
        end
        stop = true
      end
      if stop then return 'end' end
      local r = step(i, sub, depth)
      if r then return r end
    end
    if sub then note(#lines, 'a sub that ends without M99') end
    return 'end'
  end
  run(main, false, 0)
  for _, s in ipairs(secs) do s.tool, s.carried = s.tool or s.carried, nil end
  return secs, issues, arcs, stats
end

return R
