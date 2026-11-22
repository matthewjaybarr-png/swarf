-- motion.lua - reads a program the way the control would (one section at a time)
-- Used by :Range :CycleTime :ArcCheck :Lint :Backplot. Changes nothing.
--
-- Geometry reads sections independently in their own work offsets. CycleTime
-- opts into caller state and ordered CALL callbacks; geometry consumers do not.
-- Values written as variables (Z=VC43) are unknown: that axis is skipped until
-- the next plain number.
local U = require('gcode.util')
local M = {}

local CYCLES = {}
for _, g in ipairs({ 73, 74, 76, 81, 82, 83, 84, 85, 86, 87, 88, 89,
                     273, 274, 276, 281, 282, 283, 284, 285, 286, 287, 288, 289 }) do
  CYCLES[g] = true
end
M.CYCLES = CYCLES

-- arc planes: the two axes the arc turns in (a, b), the third axis (n) and the center words.
-- G2 is clockwise seen from the plus side of n; a, b, n is right-handed, so G18 is Z then X (Z x X = +Y).
local PLANES = { [17] = { a = 'x', b = 'y', n = 'z', i = 'I', j = 'J' },
                 [18] = { a = 'z', b = 'x', n = 'y', i = 'K', j = 'I' },
                 [19] = { a = 'y', b = 'z', n = 'x', i = 'J', j = 'K' } }
M.PLANES = PLANES
-- G words that may share a line with a full circle (G3 I-.5): anything else is not an arc
local CIRCLE_G = { [2] = true, [3] = true, [17] = true, [18] = true, [19] = true, [90] = true, [91] = true }
-- axes a work offset (G15 H frame, VZOFX..VZOFC) shifts; timing tracks A/B/C positions too
local FRAME_AXES = { 'x', 'y', 'z', 'a', 'b', 'c' }

-- split the code part of a line into address words
--   returns list of { l = 'X', v = '-.4066' }  /  { l = 'Z', expr = 'VC43+.25' }
--   plus a list of problems for :Lint
function M.words(code)
  local w, bad = {}, {}
  local i, n = 1, #code
  while i <= n do
    local c = code:sub(i, i)
    if c:match('%s') then
      i = i + 1
    elseif c:match('%a') then
      local two = code:sub(i, i + 1):upper()
      local name = code:match('^(%a%a+%w*)=', i)
      if (two == 'DA' or two == 'HA') and not code:sub(i + 2, i + 2):match('%w') then
        w[#w + 1] = { l = c:upper(), v = 'A', col = i }          -- G41 DA / G56 HA
        i = i + 2
      elseif name then
        -- Okuma named words: M19 RS=315 (orient angle), PF=VS59 (local variable) - not R + S=
        local e = code:match('^[^%s]+', i + #name + 1) or ''
        w[#w + 1] = { l = name:upper(), expr = e, col = i, low = name:match('%l') ~= nil }
        i = i + #name + 1 + #e
      elseif code:sub(i + 1, i + 1) == '=' then
        local e = code:match('^[^%s]+', i + 2) or ''
        w[#w + 1] = { l = c:upper(), expr = e, col = i }
        i = i + 2 + #e
      else
        local num = code:match('^[%+%-]?%d*%.?%d*', i + 1) or ''
        w[#w + 1] = { l = c:upper(), v = num, col = i, low = c:match('%l') ~= nil }
        i = i + 1 + #num
      end
    elseif c == '.' then
      local junk = code:match('^%.[%.%d]*', i)          -- X1.2.3 -> '.3' is the extra
      bad[#bad + 1] = { col = i, ch = '.', text = junk }
      i = i + #junk
    else
      bad[#bad + 1] = { col = i, ch = c }
      i = i + 1
    end
  end
  return w, bad
end

-- Strip only numeric rotary words from an otherwise G/A/C line; preserve modal words.
function M.strip_rotary(line, code)
  if not code then
    if not U.editable({line}) then return nil end
    code=require('gcode.profile').mask({line})[1]
  end
  local body=code:gsub('^%s*N%w+%s*','')
  local words,bad=M.words(body)
  if #bad > 0 then return nil end
  local rotary=false
  for _,w in ipairs(words) do
    if w.expr or not tonumber(w.v) or (w.l ~= 'G' and w.l ~= 'A' and w.l ~= 'C') then return nil end
    if w.l == 'A' or w.l == 'C' then rotary=true end
  end
  if not rotary then return nil end
  return U.trim((U.gsub(line,code,'%f[%w][AC][%+%-]?%d*%.?%d*','')))
end

-- is this a line of motion/address words (not a macro, label, IF, CALL...)?
function M.is_nc(code)
  local c = U.trim(code)
  if c == '' then return false end
  local first, rest = c:match('^N(%w+)%s*(.*)$')
  if first and first:match('%a') then return false end                         -- NST1 / N2ND labels
  local body = rest or c                                                       -- N10 CALL O0003 is a CALL too
  if body:match('^%a%a') and not body:match('^[DH]A%f[%W]') then return false end  -- IF, CALL, VC43=, GOTO, RTS, MSG...
  return c:match('^[%aN]') ~= nil
end

local function num(v)
  if not v or v == '' or v == '+' or v == '-' or v == '.' then return nil end
  return tonumber(v)
end

-- sections: MAIN + every sub
function M.sections(lines, masked)
  if not masked then lines=require('gcode.profile').mask(lines) end
  local out, fs = {}, U.first_sub(lines)
  out[1] = { name = 'MAIN', s = 1, e = fs - 1 }
  for i = fs, #lines do
    local nm = lines[i]:match('^%s*(O%w+)')
    if nm then
      out[#out].e = i - 1
      out[#out + 1] = { name = nm, s = i, e = #lines }
    end
  end
  return out
end

-- Read positioning from source; the diff retains this evaluator even if MR evidence is replaced.
local function positioning(lines, boundary_risk, present, entries)
  local issues
  lines,issues=require('gcode.profile').mask(lines)
  if #issues>0 then return {},{},true,{} end
  local secs = M.sections(lines)
  present=present or {}
  for _,sec in ipairs(secs) do present[sec.name]=true end
  -- ponytail: one G91 boundary disables rounding/splits file-wide; do call-graph dataflow if a real program gets >5 positioning flags.
  if boundary_risk == nil then
    boundary_risk=false
    for _,sec in ipairs(secs) do
      local absolute=true
      for i=sec.s,sec.e do
        local c=U.code_of(lines[i])
        if c:match('%f[%w]G90%f[%D]') then absolute=true end
        if c:match('%f[%w]G91%f[%D]') then absolute=false end
        if not absolute and (c:match('%f[%w]CALL%f[^%w]') or U.tc(c) == 'RTS' or c:match('%f[%w]M99%f[%D]') or c:match('%f[%w]M30%f[%D]') or c:match('%f[%w]M0?2%f[%D]') or i == sec.e) then boundary_risk=true end
      end
    end
  end
  -- ponytail: O(subs * lines) propagation; use a worklist if large call graphs become slow.
  if not entries then
    entries={}
    local graph,called={},{}
    for _,sec in ipairs(secs) do
      graph[sec.name]={}
      for i=sec.s,sec.e do
        local target=U.code_of(lines[i]):match('CALL%s+(O%w+)')
        if target then graph[sec.name][target]=true; called[target]=true end
      end
    end
    local function reaches(start,name,seen)
      for target in pairs(graph[name] or {}) do
        if target == start then return true end
        if not seen[target] then
          seen[target]=true
          if reaches(start,target,seen) then return true end
        end
      end
      return false
    end
    for _,sec in ipairs(secs) do
      entries[sec.name]=not boundary_risk and (sec.name == 'MAIN' or called[sec.name] == true) and not reaches(sec.name,sec.name,{})
    end
    local changed=true
    while changed do
      changed=false
      local _,calls=positioning(lines,boundary_risk,present,entries)
      for name,sites in pairs(calls) do
        for _,at in ipairs(sites) do
          if at.absolute ~= true and entries[name] then entries[name]=false; changed=true end
        end
      end
    end
  end
  local modes,contexts = {},{}
  for _,sec in ipairs(secs) do
    local absolute = entries[sec.name] and true or nil
    local axes={}
    for i=sec.s,sec.e do
      local c=U.code_of(lines[i])
      if c:match('%f[%w]G90%f[%D]') then absolute=true end
      if c:match('%f[%w]G91%f[%D]') then absolute=false end
      modes[i]=absolute
      if M.is_nc(c) then
        for _,w in ipairs(M.words(c)) do
          if w.l == 'A' or w.l == 'C' then
            axes[w.l]=absolute == true and tonumber(w.v) or nil
          end
        end
      end
      local called=c:match('CALL%s+(O%w+)')
      if called then
        contexts[called]=contexts[called] or {}
        local at={absolute=absolute,main=sec.name == 'MAIN'}
        for axis,v in pairs(axes) do at[axis]=math.floor(v+0.5) end
        contexts[called][#contexts[called]+1]=at
        -- ponytail: no callee execution model; explicit G90 re-arms external calls.
        if boundary_risk or U.is_external_sub(called) or not present[called] then absolute=nil end
        axes={}
      end
    end
  end
  return modes,contexts,boundary_risk,entries
end
M.positioning=positioning

-- walk one section. Returns:
--   moves = { {line, kind='rapid'|'feed'|'arc'|'cycle'|'home', from={x,y,z}, to={x,y,z},
--              cx, cy, cw, feed, fpr, s, tool}, ... }
--     arcs: center cx/cy (G18: cz/cx, G19: cy/cz, plane=18/19), r; no r = why it is only a chord
--   events = { calls = { {line, sub, tool, h} }, tools = { {line, t} }, dwell = seconds,
--              loops = n, arcbad = { {line, r1, r2[, R]} }, noarc = { line } , nofeed = { line },
--              tcfeed = { {line, tc, f} } (cut after a tool change with the old tool's F),
--              timing_unknown = { {line, text} }, tool_ops = { {line, t} } }
-- Unknown external/probe/control-flow effects cannot manufacture a return state.
function M.unknown_state()
  return {}
end

function M.walk(lines, sec, start_tool, options)
  local issues={}
  -- Timing plans are selected from profile.mask output; avoid rescanning the whole file per CALL.
  if not (options and options.masked) then lines,issues=require('gcode.profile').mask(lines) end
  local st = { x = nil, y = nil, z = nil, g = 0, abs = true, plane = 17, f = nil, fpr = false,
               s = nil, tool = start_tool, cyc = nil, cz = nil, cr = nil, h = nil }
  if options and options.state then st = vim.deepcopy(options.state) end
  local moves = {}
  local ev = { calls = {}, tools = {}, dwell = 0, loops = 0, arcbad = {}, noarc = {}, nofeed = {}, tcfeed = {} }
  -- F is modal across a tool change: the line of a change no F has followed yet
  local changed
  local function cut(i)                               -- a cut on the old tool's feed: once per change
    if changed and st.f then ev.tcfeed[#ev.tcfeed + 1] = { line = i, tc = changed, f = st.f } end
    changed = nil
  end
  -- Additive timing evidence; geometry/report consumers keep their existing moves.
  ev.timing_unknown, ev.tool_ops, ev.dwells = {}, {}, {}
  ev.issues=U.issues(issues)
  local function unknown(line, text)
    ev.timing_unknown[#ev.timing_unknown + 1] = { line = line, text = text, tool = st.tool }
  end
  local function dwell_operand(v, key, line)
    local n = num(v)
    if not n or n ~= n or n < 0 or n == math.huge then
      unknown(line, 'dwell ' .. key .. ' (invalid or unresolved operand)')
    else ev.dwell = ev.dwell + n; ev.dwells[#ev.dwells+1]={seconds=n,tool=st.tool} end
  end
  local labels = {}
  for i = sec.s, sec.e do
    local lab = U.tc(lines[i]):match('^N(%w+)')
    if lab then labels[lab] = i end
  end
  -- timing: the state the IFs and GOTOs not modeled bring to each label further down. Lines an
  -- IF can skip are walked as if they run; at the label only what the jump and the walk agree
  -- on (tool, modes, positions) is known.
  local targets = {}
  local function meet(a, b)
    local m = {}
    for k, v in pairs(a) do if vim.deep_equal(v, b[k]) then m[k] = vim.deepcopy(v) end end
    return m
  end
  for i = sec.s, sec.e do
    if options and options.resets and options.resets[i] then
      st.x,st.y,st.z,st.f,st.s=nil,nil,nil,nil,nil
    end
    if targets[i] then st = meet(st, targets[i]) end
    local raw = lines[i]
    local code = U.code_of(raw)
    local c = U.trim(code)
    -- Machine selectors choose timing profiles; other branches are not evaluated.
    local selector = not (options and options.timing) and require('gcode.profile').selector(c)
    if c:find('%f[%w]GOTO%f[^%w]') or (c:find('%f[%w]IF%f[^%w]') and not selector) then
      unknown(i, 'control flow (not modeled)')
      if options and options.timing then
        -- where it jumps: 'forward' to a label further down this section, 'back' (a loop: the
        -- walk goes on with the state it has, the loop counted once), or nil (no label here:
        -- the walk goes on knowing only the tool, which an IF or GOTO does not change)
        local jump, any, ahead = 'forward', false, {}
        for _, pat in ipairs({ '%]%s*N(%w+)', 'GOTO%s*N(%w+)' }) do
          for t in c:gmatch(pat) do
            any = true
            local at = labels[t]
            if not at then if jump ~= 'back' then jump = nil end
            elseif at < i then jump = 'back'; ev.timing_unknown[#ev.timing_unknown].back = at
            else ahead[#ahead + 1] = at end
          end
        end
        jump = any and jump or nil
        ev.timing_unknown[#ev.timing_unknown].jump = jump
        if jump then
          for _, at in ipairs(ahead) do targets[at] = targets[at] and meet(targets[at], st) or vim.deepcopy(st) end
        else
          local tool = st.tool
          st = M.unknown_state(); st.tool = tool
        end
      end
    end
    -- jumps back up = a loop (counted once)
    for t in c:gmatch('%]%s*N(%w+)') do if labels[t] and labels[t] < i then ev.loops = ev.loops + 1 end end
    for t in c:gmatch('GOTO%s*N(%w+)') do if labels[t] and labels[t] < i then ev.loops = ev.loops + 1 end end
    local call = c:match('^CALL%s+(O%w+)') or c:match('^N%w+%s+CALL%s+(O%w+)')    -- N10 CALL O0003
    if call then
      changed = nil                                   -- the sub may set its own feed
      ev.calls[#ev.calls + 1] = { line = i, sub = call, tool = st.tool, h = st.h }
      if options and options.call then st = options.call(call, st, i) end
    end
    if options and options.timing and c:find('%f[%w]VZOF') then
      -- VZOFX[1]=-8.4405 VZOFZ[1]=-1.4888: offset-table writes take no time. A write to the
      -- active frame (G15 H) moves the program position by the change.
      st.frames = st.frames or {}
      local found = false
      -- some posts write VZOFX [1]= -5.402VZOFY [1]= 14.: a space before [ and a value
      -- that runs into the next word (proven programs run like that)
      local spaced = c:gsub('(%S)(VZOF%a)', '%1 %2')
      for axis, n, v in spaced:gmatch('VZOF(%a)%s*%[([^%]]*)%]%s*=%s*([^%s]+)') do
        found = true
        local h, a = tonumber(n), axis:lower()
        if not h then st.frames = {}; for _, k in ipairs(FRAME_AXES) do st[k] = nil end
        else
          local f = st.frames[h] or {}
          st.frames[h] = f
          if h == tonumber(st.h) and st[a] ~= nil then
            st[a] = f[a] and tonumber(v) and st[a] + f[a] - tonumber(v) or nil
          end
          f[a] = tonumber(v)
        end
      end
      if not found then st.frames = {}; for _, k in ipairs(FRAME_AXES) do st[k] = nil end end
    end
    local nc = M.is_nc(code)
    if nc then
      local w = M.words(code)
      local has = {}
      local gs = {}
      for _, x in ipairs(w) do
        if x.l == 'G' then
          local g=num(x.v)
          if options and options.timing and not g then st=M.unknown_state(); unknown(i,'G operand') end
          gs[#gs + 1] = g
        else has[x.l] = x end
      end
      local cycle_line = false
      local return_level = vim.tbl_contains(gs,71)
      local dwell = false
      for _, g in ipairs(gs) do
        if g == 0 or g == 1 or g == 2 or g == 3 then
          if not return_level then st.g = g; st.cyc = nil end
        elseif g == 90 then st.abs = true
        elseif g == 91 then st.abs = false
        elseif g == 17 or g == 18 or g == 19 then st.plane = g
        elseif g == 94 then st.fpr = false
        elseif g == 95 then st.fpr = true
        elseif g == 80 then st.cyc = nil; st.cret = nil
        elseif g == 4 then dwell = true
        elseif g == 15 then if has.H then
          if options and options.timing and has.H.v ~= st.h then
            -- the machine does not move: new = old + old offset - new offset, per axis
            local old = st.frames and st.frames[tonumber(st.h)] or {}
            local new = st.frames and st.frames[tonumber(has.H.v)] or {}
            for _, a in ipairs(FRAME_AXES) do
              st[a] = st[a] and old[a] and new[a] and st[a] + old[a] - new[a] or nil
            end
          end
          st.h = has.H.v
        end
        elseif g == 56 and options and options.timing then
          -- G56 HA: tool length offset on. Z is unknown until it is on for this tool and H.
          local key = tostring(st.tool) .. ':' .. (has.H and has.H.v or '')
          if st.comp ~= key then st.z = nil; st.comp = key end
        elseif g == 53 and options and options.timing then st.z = nil; st.comp = nil   -- Okuma: length offset off
        elseif g == 116 then
          if has.T then
            if options and options.timing and (has.T.expr or not num(has.T.v)) then unknown(i,'tool selection operand') end
            if options and options.timing then st.comp = nil end
            if options and (options.generic or options.timing) then st.x,st.y,st.z=nil,nil,nil end
            ev.tool_ops[#ev.tool_ops + 1] = { line = i, t = has.T.v }
            if has.T.v ~= st.tool and has.T.v ~= '0' then
              ev.tools[#ev.tools + 1] = { line = i, t = has.T.v }
              changed = i
            end
            st.tool = has.T.v
          end
        elseif g and CYCLES[g] then st.cyc = g; cycle_line = true
        end
      end
      for _, x in ipairs(w) do
        local n = x.l == 'M' and num(x.v)
        if n == 52 or n == 53 or n == 54 then st.cret = n           -- cycle return: limit / G71 level / R
        elseif n == 6 then changed = i                            -- M6: tool change (dialects turn it into G116)
        elseif n == 97 or n == 98 or (x.l == 'G' and (num(x.v) == 65 or num(x.v) == 66)) then
          changed = nil                                           -- M98 / G65: the sub may set its own feed
        end
      end
      if has.F then
        local f = num(has.F.v)
        if dwell then
          dwell_operand(has.F.v, 'F', i)
        else st.f, st.feed_expr = f, has.F.expr; changed = nil end
      end
      if dwell and has.P then
        dwell_operand(has.P.v, 'P', i)
      end
      if dwell and not (has.F or has.P) then unknown(i, 'dwell operand') end
      if has.S and num(has.S.v) then st.s = num(has.S.v)
      elseif has.S and options and options.timing then st.s=nil end
      if options and options.timing then
        for _,key in ipairs({'I','J','R'}) do
          if has[key] and (has[key].expr or not num(has[key].v)) then unknown(i,'arc/cycle '..key..' operand') end
        end
      end
      local home = false
      for _, g in ipairs(gs) do if g == 30 or g == 28 then home = true end end
      if not dwell and not home then
        local function axis(l, cur)
          local x = has[l]
          if not x then return cur, false end
          if x.expr then return nil, true end
          local v = num(x.v)
          if v == nil then return nil, true end
          if options and options.timing and st.abs == nil then return nil,true end
          if st.abs then return v, true end
          if cur == nil then return nil, true end
          return cur + v, true
        end
        local from = { x = st.x, y = st.y, z = st.z }
        local nx, mx = axis('X', st.x)
        local ny, my = axis('Y', st.y)
        local nz, mz
        if return_level then
          -- Okuma OSP manual 5228-E, section 7 p.118: G71 sets the return level, not Z motion.
          -- After each hole M53 returns to it and M54 to the R level; M52 / none are not modeled.
          st.return_level_line = i
          if has.Z and not num(has.Z.v) then unknown(i, 'G71 return level') end
          st.rl = has.Z and num(has.Z.v)
          nz, mz = st.z, false
        elseif st.cyc then
          -- in a canned cycle Z/R are the hole bottom / R level, not a move
          if has.Z then st.cz = has.Z.expr and nil or num(has.Z.v) end
          if has.R then st.cr = num(has.R.v); st.cr_unknown = st.cr == nil end
          nz, mz = st.z, false
        else
          nz, mz = axis('Z', st.z)
        end
        -- G3 I-.5 with no X Y Z: a full circle back to the start
        local p = PLANES[st.plane]
        local circle = (st.g == 2 or st.g == 3) and not st.cyc and not return_level and p
          and (has[p.i] or has[p.j]) and vim.iter(gs):all(function(g) return CIRCLE_G[g] end)
        -- timing: A/B/C positions; a rotary-only rapid is a move of its own (no TCP: X Y Z stay)
        local rot, rot_start, rotary = 0, false, false
        if options and options.timing then
          for _, l in ipairs({ 'A', 'B', 'C' }) do
            local x, a = has[l], l:lower()
            if x then
              rotary = true
              local v, cur = num(x.v), st[a]
              if not v then unknown(i, 'rotary position operand'); st[a] = nil
              elseif st.abs == nil then st[a] = nil                 -- reported as unknown modal state
              elseif st.abs then
                if cur then rot = math.max(rot, math.abs(v - cur)) else rot_start = true end
                st[a] = v
              else
                rot = math.max(rot, math.abs(v)); st[a] = cur and cur + v
              end
            end
          end
          if rotary and (st.g ~= 0 or st.cyc) then unknown(i, 'rotary feed motion (not modeled)') end
        end
        if mx or my or mz or circle or (st.cyc and cycle_line) or (rotary and st.g == 0 and not st.cyc) then
          if options and options.timing and (st.g==nil or st.abs==nil or st.plane==nil or st.fpr==nil) then
            unknown(i, 'modal state after unsupported effect')
          end
          local to = { x = nx, y = ny, z = nz }
          local varz = (has.Z and has.Z.expr) and not st.cyc and not return_level
          if st.cyc then
            local timing = options and options.timing
            local ret = timing and st.return_level_line and (st.cret == 54 or st.cret == 53 and st.rl) and st.cret
            if not (to.x and to.y and st.cz) then unknown(i, 'cycle position/depth') end
            if st.cr_unknown or not (st.cr or to.z) then unknown(i, 'cycle return/R level') end
            if st.return_level_line and not ret then unknown(st.return_level_line, 'G71 return travel (not modeled)') end
            for _, key in ipairs({ 'P', 'Q' }) do
              if has[key] and not num(has[key].v) then unknown(i, 'cycle ' .. key) end
            end
            -- position (rapid), then drill to cz and back
            moves[#moves + 1] = { line = i, kind = 'rapid', from = from, to = to, tool = st.tool,
                                  axes = timing and { x = mx, y = my, z = false } or nil }
            if to.x and to.y and st.cz then
              local top = st.cr or to.z
              if ret and top then
                -- G71 + M53/M54: down to R first; after the hole Z is R (M54) or the G71 level (M53)
                moves[#moves + 1] = { line = i, kind = 'rapid', from = { x = to.x, y = to.y, z = to.z },
                  to = { x = to.x, y = to.y, z = top }, tool = st.tool, axes = { x = false, y = false, z = true } }
              end
              moves[#moves + 1] = { line = i, kind = 'cycle', from = { x = to.x, y = to.y, z = top },
                to = { x = to.x, y = to.y, z = st.cz }, feed = st.f, feed_expr = st.feed_expr, fpr = st.fpr, s = st.s, tool = st.tool,
                cyc = st.cyc }
              cut(i)
              if ret == 53 and top then
                moves[#moves + 1] = { line = i, kind = 'rapid', from = { x = to.x, y = to.y, z = top },
                  to = { x = to.x, y = to.y, z = st.rl }, tool = st.tool, axes = { x = false, y = false, z = true } }
              end
              if ret and top then to = { x = to.x, y = to.y, z = ret == 54 and top or st.rl } end
            end
          elseif not (options and options.generic) and nz and nz >= 50 and st.abs and mz and not mx and not my then
            moves[#moves + 1] = { line = i, kind = 'home', from = from, to = to, tool = st.tool }
            to.z = nil                                  -- Z100. = up to the limit
          elseif st.g == 2 or st.g == 3 then
            local m = { line = i, kind = 'arc', from = from, to = to, cw = st.g == 2, feed = st.f, feed_expr = st.feed_expr,
                        fpr = st.fpr, s = st.s, tool = st.tool,
                        axes = options and options.timing and { x = mx, y = my, z = mz } or nil }
            local tol = require('gcode.config').arc_tol or .0005
            if not p then m.why = 'arc plane unknown'
            else
              local a, b = p.a, p.b
              -- G18/G19: the center's third coordinate is the start's, so cx cy cz is a point
              if st.plane ~= 17 then m.plane = st.plane; m['c' .. p.n] = from[p.n] end
              if has[p.i] or has[p.j] then
                -- I/J/K: the center from the start; a missing one is 0, a variable one is unknown
                local function off(x) if not x then return 0 end return num(x.v) end
                local oi, oj = off(has[p.i]), off(has[p.j])
                if not (oi and oj) then m.why = 'center written with a variable'
                elseif not (from[a] and from[b]) then m.why = 'start point unknown'
                else
                  m['c' .. a], m['c' .. b] = from[a] + oi, from[b] + oj
                  if to[a] and to[b] then
                    local r1 = math.sqrt((from[a] - m['c' .. a]) ^ 2 + (from[b] - m['c' .. b]) ^ 2)
                    local r2 = math.sqrt((to[a] - m['c' .. a]) ^ 2 + (to[b] - m['c' .. b]) ^ 2)
                    m.r = r1
                    if math.abs(r1 - r2) > tol then
                      ev.arcbad[#ev.arcbad + 1] = { line = i, r1 = r1, r2 = r2 }
                    end
                  else m.why = 'end point unknown' end
                end
              elseif has.R then
                -- R: center on the perpendicular bisector, R>0 the short way round, R<0 the long way
                local r = num(has.R.v)
                if not r then m.why = 'R written with a variable'
                elseif not (from[a] and from[b] and to[a] and to[b]) then m.why = 'start or end point unknown'
                else
                  local da, db = to[a] - from[a], to[b] - from[b]
                  local d = math.sqrt(da * da + db * db)
                  if d < 1e-9 then m.why = 'R arc that ends where it starts (R cannot make a full circle)'
                  elseif d / 2 - math.abs(r) > tol then
                    ev.arcbad[#ev.arcbad + 1] = { line = i, r1 = math.abs(r), r2 = d / 2, R = true }
                    m.why = 'R is too small to reach the end point'
                  else
                    local h = math.sqrt(math.max(r * r - d * d / 4, 0))
                    local side = (m.cw == (r > 0)) and -1 or 1
                    m['c' .. a] = from[a] + da / 2 - side * h * db / d
                    m['c' .. b] = from[b] + db / 2 + side * h * da / d
                    m.r = math.abs(r)
                  end
                end
              else
                ev.noarc[#ev.noarc + 1] = i
                m.why = 'no ' .. p.i .. ' / ' .. p.j .. ' / R'
              end
            end
            if not st.f then ev.nofeed[#ev.nofeed + 1] = i else cut(i) end
            moves[#moves + 1] = m
          else
            local kind = st.g == 0 and 'rapid' or 'feed'
            if kind == 'feed' then if not st.f then ev.nofeed[#ev.nofeed + 1] = i else cut(i) end end
            moves[#moves + 1] = { line = i, kind = kind, from = from, to = to, feed = st.f, feed_expr = st.feed_expr,
                                  fpr = st.fpr, s = st.s, tool = st.tool,
                                  axes = options and options.timing and { x = mx, y = my, z = mz } or nil }
          end
          if varz and moves[#moves] then moves[#moves].varz = true end
          local last = moves[#moves]
          if rotary and last and last.line == i and (last.kind == 'rapid' or last.kind == 'home') then
            last.rot, last.rot_start = rot, rot_start
          end
          st.x, st.y, st.z = to.x, to.y, to.z
        end
      end
    end
  end
  return moves, ev, st
end

-- the tool each sub runs with: the tool active at its first CALL in the main program
function M.sub_tools(lines, masked)
  if not masked then lines=require('gcode.profile').mask(lines) end
  local secs = M.sections(lines, true)
  local tools = {}
  local _, ev = M.walk(lines, secs[1], nil, {masked=true})
  for _, c in ipairs(ev.calls) do
    if not tools[c.sub] then tools[c.sub] = c.tool end
  end
  return secs, tools
end

-- length of a move (arcs measured along the arc, helix included)
function M.length(m)
  local f, t = m.from, m.to
  if not (f.x and f.y and f.z and t.x and t.y and t.z) then
    -- partly unknown: use what we have
    local d2 = 0
    for _, a in ipairs({ 'x', 'y', 'z' }) do
      if f[a] and t[a] then d2 = d2 + (t[a] - f[a]) ^ 2 end
    end
    return math.sqrt(d2), false
  end
  local p = PLANES[m.plane or 17]
  local ca, cb = m['c' .. p.a], m['c' .. p.b]
  if m.kind == 'arc' and ca and cb and m.r then
    local a1 = math.atan2(f[p.b] - cb, f[p.a] - ca)
    local a2 = math.atan2(t[p.b] - cb, t[p.a] - ca)
    local sweep = m.cw and (a1 - a2) or (a2 - a1)
    while sweep <= 1e-9 do sweep = sweep + 2 * math.pi end
    local xy = m.r * sweep
    return math.sqrt(xy * xy + (t[p.n] - f[p.n]) ^ 2), true
  end
  return math.sqrt((t.x - f.x) ^ 2 + (t.y - f.y) ^ 2 + (t.z - f.z) ^ 2), true
end

-- points along a move (arcs broken into short pieces) for range / backplot.
-- Second value true: an arc only drawn as a straight line (center or an end unknown).
function M.points(m, seg)
  local f, t = m.from, m.to
  local p = PLANES[m.plane or 17]
  local ca, cb = m['c' .. p.a], m['c' .. p.b]
  if m.kind == 'arc' and ca and cb and m.r and f[p.a] and f[p.b] and t[p.a] and t[p.b] then
    local a1 = math.atan2(f[p.b] - cb, f[p.a] - ca)
    local a2 = math.atan2(t[p.b] - cb, t[p.a] - ca)
    local sweep = m.cw and (a1 - a2) or (a2 - a1)
    while sweep <= 1e-9 do sweep = sweep + 2 * math.pi end
    local n = math.max(2, math.ceil(sweep / (seg or 0.2)))
    local pts = {}
    local fn, tn = f[p.n], t[p.n]
    for k = 0, n do
      local a = a1 + (m.cw and -1 or 1) * sweep * k / n
      local pt = {}
      pt[p.a], pt[p.b] = ca + m.r * math.cos(a), cb + m.r * math.sin(a)
      pt[p.n] = (fn and tn) and (fn + (tn - fn) * k / n) or tn or fn
      pts[#pts + 1] = pt
    end
    return pts
  end
  return { f, t }, m.kind == 'arc'
end

-- open a read-only report split
function M.report(title, out)
  vim.cmd('botright new')
  local b = vim.api.nvim_get_current_buf()
  vim.bo[b].buftype = 'nofile'
  vim.bo[b].bufhidden = 'wipe'
  vim.bo[b].swapfile = false
  vim.api.nvim_buf_set_name(b, title .. ' ' .. b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, out)
  vim.bo[b].modifiable = false
  vim.keymap.set('n', 'q', '<cmd>close<CR>', { buffer = b, nowait = true })
  -- at most 25 rows and 2/5 of the screen, so the program above keeps the rest
  -- (a 25-row report would leave the program window 1 row tall)
  vim.cmd('resize ' .. math.min(#out + 1, 25, math.max(3, math.floor(vim.o.lines * 0.4))))
end

-- ponytail: LCS is O(n*m) per changed sub; use a linear-space diff if large subs become slow.
function M.diff(before, after)
  for _,lines in ipairs({before,after}) do
    local _,issues=require('gcode.profile').mask(lines)
    if #issues>0 then return {{kind='other',sub='MAIN',before_line=issues[1].line,after_line=issues[1].line,text=issues[1].text}} end
  end
  local cfg = require('gcode.config')
  local function approved_feed(old,new)
    return new == cfg.fast_feed and vim.tbl_contains(cfg.old_fast_feeds or {},old)
  end
  local before_codes=require('gcode.profile').mask(before)
  local protected=U.proven(before) ~= 'unproven'
  -- Independent, one-level evidence from BEFORE text; no transformer positioning model.
  local function guard_modes(lines)
    lines=require('gcode.profile').mask(lines)
    local secs=M.sections(lines)
    local function evidence(code)
      local mode
      local called=code:match('CALL%s+(O%w+)')
      local opaque=code:find('%f[%w]CALL%f[^%w]') ~= nil and not called
      for _,word in ipairs(M.words(code)) do
        local value=tonumber(word.v)
        if word.l=='G' then
          if value==90 and mode~=false and M.is_nc(code) and not code:find('/',1,true) then mode=true end
          if value==91 then mode=false end
          if value==65 or value==66 then opaque=true end
        elseif word.l=='M' and value==98 then opaque=true end
      end
      return mode,opaque,called
    end
    local clean={}
    local function is_clean(sec)
      if U.is_external_sub(sec.name) then return false end
      for i=sec.s,sec.e do
        local mode,opaque,called=evidence(U.code_of(lines[i]))
        if mode==false or opaque or called then return false end
      end
      return true
    end
    for _,sec in ipairs(secs) do
      if sec.name ~= 'MAIN' then clean[sec.name]=is_clean(sec) end
    end
    -- Scan a section from `known`; call lines keep the mode before the call, its effect starts next line.
    local function scan(sec,known)
      local modes,pend={},false
      for i=sec.s,sec.e do
        if pend then known=false; pend=false end
        local mode,opaque,called=evidence(U.code_of(lines[i]))
        if mode~=nil then known=mode end
        if opaque then known=false end
        modes[i]=known
        if called and not clean[called] then pend=true end
      end
      return modes
    end
    -- ponytail: jumps that cross a mode change refuse the whole program; port to positioning() if a real program hits it.
    local function fix_jumps(sec,modes)
      local defined,jumps,bad,at,g90={},{},false,{},{}
      for i=sec.s,sec.e do
        local c=U.tc(lines[i])
        local lab=c:match('^N(%w+)')
        if lab then defined[lab]=(defined[lab] or 0)+1; at[lab]=i end
        g90[i]=evidence(c)==true
        local n=0
        for t in c:gmatch('GOTO%s*N(%w+)') do jumps[#jumps+1]={t,i}; n=n+1 end
        local _,gotos=c:gsub('GOTO','')
        if gotos>n then bad=true end
        -- fail closed: any IF counts, even after N-words (N5 IF[...] NSK1); no parseable target means no proof
        if c:find('IF%s*%[') then
          local selector=c:match('^IF%[VC200 EQ %d+%]%s*N%w+$') ~= nil
          for t in c:gmatch('%]%s*N(%w+)') do jumps[#jumps+1]={t,i,selector}; n=n+1 end
          if n==0 then bad=true end
        end
      end
      -- a missing or duplicate target clears the section; only the MR selector's label is never added
      for _,j in ipairs(jumps) do
        if (defined[j[1]] or 0)>1 or not defined[j[1]] and not j[3] then bad=true end
      end
      if bad then
        for i=sec.s,sec.e do modes[i]=false end
        return
      end
      local changed=true
      while changed do
        changed=false
        for _,j in ipairs(jumps) do
          local from=at[j[1]]
          if from and modes[j[2]]~=true and modes[from]==true then
            for i=from,sec.e do
              if g90[i] then break end
              if modes[i] then modes[i]=false; changed=true end
            end
          end
        end
      end
    end
    -- ponytail: a non-clean callee ends evidence and may prompt the whole program; use flag-only if the owner hits this.
    local main_modes=scan(secs[1],false)
    fix_jumps(secs[1],main_modes)
    local calls={}
    for i=secs[1].s,secs[1].e do
      local _,_,called=evidence(U.code_of(lines[i]))
      if called then calls[called]=calls[called] ~= false and main_modes[i] end
    end
    -- ponytail: any sub caller vetoes inheritance, even unreachable/self calls; analyze callers only if real programs need it.
    for _,sec in ipairs(secs) do
      if sec.name~='MAIN' then
        for i=sec.s,sec.e do
          local _,_,called=evidence(U.code_of(lines[i]))
          if called then calls[called]=false end
        end
      end
    end
    local modes=main_modes
    for _,sec in ipairs(secs) do
      if sec.name~='MAIN' then
        local sub=scan(sec,calls[sec.name] == true)
        fix_jumps(sec,sub)
        for i=sec.s,sec.e do modes[i]=sub[i] end
      end
    end
    return modes
  end
  local guard=protected and guard_modes(before) or nil
  local function collect(lines)
    lines=require('gcode.profile').mask(lines)
    local result = {}
    local secs, tools = M.sub_tools(lines)
    local modes,contexts=positioning(lines)
    for _, sec in ipairs(secs) do
      local moves=M.walk(lines,sec,tools[sec.name])
      for _,move in ipairs(moves) do move.positioning_known=(protected and guard[move.line] or not protected and modes[move.line] == true) end
      -- ponytail: compare rotary words and mode; model rotary kinematics when full simulation is needed.
      local merged,index,first_rotary={},1,true
      for line=sec.s,sec.e do
        while moves[index] and moves[index].line <= line do
          merged[#merged+1]=moves[index]; index=index+1
        end
        local code=U.code_of(lines[line])
        if code:match("%f[%w]CALL%f[^%w]") then first_rotary=false end
        if M.is_nc(code) then
          local rotary={line=line,kind='rotary',to={}}
          for _,word in ipairs(M.words(code)) do
            if word.l == 'A' or word.l == 'C' then rotary[word.l:lower()]=word.expr or tonumber(word.v) end
          end
          if rotary.a or rotary.c then
            rotary.rotary_absolute=modes[line]
            rotary.dup_candidate=first_rotary
            first_rotary=false
            merged[#merged+1]=rotary
          end
        end
      end
      result[sec.name]=merged
    end
    return result,contexts
  end
  local function signature(m, ignore_feed, ignore_kind)
    local values = {}
    for _, value in ipairs({'kind','x','y','z','cx','cy','cz','cw','feed','feed_expr','fpr','s','tool','cyc','varz','a','c','rotary_absolute'}) do
      local v = (value == 'x' or value == 'y' or value == 'z') and m.to[value] or m[value]
      if (m.kind == 'rapid' or ignore_kind) and (value == 'feed' or value == 'feed_expr' or value == 'fpr') then v = nil end
      if not (ignore_feed and value == 'feed') and not (ignore_kind and value == 'kind') then
        values[#values+1] = tostring(v)
      end
    end
    return table.concat(values, '|')
  end
  local a, contexts = collect(before)
  local b, out, names = collect(after), {}, {}
  local function rotary_round(x,y)
    if protected and not guard[x.line] then return false end
    if x.kind ~= 'rotary' or y.kind ~= 'rotary' or x.rotary_absolute ~= true or y.rotary_absolute ~= true then return false end
    local changed=false
    for _,axis in ipairs({'a','c'}) do
      local old,new=x[axis],y[axis]
      if old ~= new then
        if type(old) ~= 'number' or old % 1 == 0 or new ~= math.floor(old+0.5) or math.abs(new-old) > 0.5 then return false end
        changed=true
      end
    end
    return changed
  end
  local preserves_rotary_words
  local function rotary_dup(x,name)
    if protected or x.kind ~= 'rotary' or not x.dup_candidate or x.rotary_absolute ~= true or not contexts[name] then return false end
    for _,at in ipairs(contexts[name]) do
      if not at.main or at.absolute ~= true or at.A == nil or at.C == nil then return false end
      for _,axis in ipairs({'a','c'}) do
        if x[axis] ~= nil and (type(x[axis]) ~= 'number' or math.floor(x[axis]+0.5) ~= at[axis:upper()]) then return false end
      end
    end
    return preserves_rotary_words(x.line)
  end
  local hunks, after_codes
  local function removed_anchor(line)
    hunks = hunks or vim.diff(table.concat(before,'\n') .. '\n',table.concat(after,'\n') .. '\n',{result_type='indices'})
    local shift = 0
    for _,h in ipairs(hunks) do
      if line < h[1] then break end
      if h[2] > 0 and line < h[1]+h[2] then return math.max(1,math.min(h[3],#after)) end
      shift = h[3]+h[4]-h[1]-h[2]
    end
    return math.max(1,math.min(line+shift,#after))
  end
  preserves_rotary_words=function(line)
    local expected=M.strip_rotary(before[line],before_codes[line])
    if expected == nil then return false end
    local function normalized(text) return U.trim(text:gsub('%s+',' ')) end
    expected=normalized(expected)
    hunks=hunks or vim.diff(table.concat(before,'\n') .. '\n',table.concat(after,'\n') .. '\n',{result_type='indices'})
    for _,h in ipairs(hunks) do
      if line >= h[1] and line < h[1]+h[2] then
        if expected == '' then
          -- removed, or swapped for lines with no rotary words (G56 HA before the first Z)
          if h[4] < h[2] then return true end
          after_codes = after_codes or require('gcode.profile').mask(after)
          for i=h[3],h[3]+h[4]-1 do if after_codes[i]:match('%f[%w][AC][%+%-%d%.=]') then return false end end
          return true
        end
        if h[2] == h[4] then return normalized(after[h[3]+line-h[1]]) == expected end
        local matches=0
        for i=h[3],h[3]+h[4]-1 do if normalized(after[i]) == expected then matches=matches+1 end end
        return matches == 1
      end
    end
    return false
  end
  for name in pairs(a) do names[name] = true end
  for name in pairs(b) do names[name] = true end
  for name in pairs(names) do
    local aa, bb = a[name] or {}, b[name] or {}
    local sa, sb = {}, {}
    for i,m in ipairs(aa) do sa[i] = signature(m) end
    for i,m in ipairs(bb) do sb[i] = signature(m) end
    local first, ae, be = 1, #aa, #bb
    while first <= ae and first <= be and sa[first] == sb[first] do first = first + 1 end
    while ae >= first and be >= first and sa[ae] == sb[be] do ae, be = ae - 1, be - 1 end
    local dp = {[ae+1]={}}
    for i=ae,first,-1 do
      dp[i] = {[be+1]=0}
      for j=be,first,-1 do
        dp[i][j] = sa[i] == sb[j] and (1 + (dp[i+1][j+1] or 0))
          or math.max(dp[i+1][j] or 0, dp[i][j+1] or 0)
      end
    end
    local function add(kind, old, new, last)
      out[#out+1] = {sub=name, before_line=old and old.line, after_line=new and new.line,
        after_end_line=last and last.line, kind=kind,
        before_feed=old and old.feed, after_feed=(last or new) and (last or new).feed,
        rotary_count=kind == 'rotary-round' and ((old.a ~= new.a and 1 or 0)+(old.c ~= new.c and 1 or 0)) or 0}
    end
    local function flush(old, new, anchor)
      local i,j=1,1
      while i <= #old or j <= #new do
        local x,y,z = old[i],new[j],new[j+1]
        if x and y and z and x.positioning_known and x.kind == 'rapid' and y.kind == 'rapid' and z.kind == 'feed' and not z.fpr
          and x.to.z and x.to.z < 0 and y.to.z and y.to.z >= 0
          and y.to.x == x.to.x and y.to.y == x.to.y
          and signature(x,true,true) == signature(z,true,true) then
          add('split',x,y,z); i,j=i+1,j+2
        elseif x and y then
          add(rotary_round(x,y) and 'rotary-round' or (signature(x,true) == signature(y,true) and approved_feed(x.feed,y.feed) and 'feed' or 'other'),x,y)
          i,j=i+1,j+1
        elseif x then
          add(rotary_dup(x,name) and 'rotary-dup' or 'removed',x); out[#out].after_line = anchor or removed_anchor(x.line); i=i+1
        else add('inserted',nil,y); j=j+1 end
      end
    end
    local i,j,old,new=first,first,{},{}
    while i <= ae or j <= be do
      if i <= ae and j <= be and sa[i] == sb[j] then
        flush(old,new,bb[j].line); old,new={},{}; i,j=i+1,j+1
      elseif i <= ae and (j > be or (dp[i+1][j] or 0) >= (dp[i][j+1] or 0)) then
        old[#old+1]=aa[i]; i=i+1
      else new[#new+1]=bb[j]; j=j+1 end
    end
    flush(old,new,bb[be+1] and bb[be+1].line or (bb[be] and bb[be].line))
  end
  table.sort(out,function(x,y) return (x.after_line or x.before_line) < (y.after_line or y.before_line) end)
  return out
end

return M
