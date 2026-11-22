-- analysis.lua - :Range  :CycleTime  :ArcCheck   (report only - nothing changes,
-- except :CycleTime write, which fills in the RUN-TIME / CUTTING-TIME lines)
local U = require('gcode.util')
local Mo = require('gcode.motion')
local cfg = require('gcode.config')
local A = {}
local D = require('gcode.dialect')

local function f4(v) return v and string.format('%9.4f', v) or '        -' end

-- ---------------------------------------------------------------------
-- :Range  -> X / Y / Z min-max for every sub, grouped by tool
-- ---------------------------------------------------------------------
vim.api.nvim_create_user_command('Range', function()
  if not require('gcode.profile').interpret('Range') then return end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local control = require('gcode.profile').context(0).control
  local generic = control ~= 'okuma'
  local problems,meta = {},{}
  if generic then lines,problems,meta=D.prepare(lines,control)
  else lines,problems=require('gcode.profile').mask(lines) end
  local secs, subtool = Mo.sub_tools(lines,true)
  local out = {
    'RANGE - min / max of every move, in each sub\'s own work offset (q closes)',
    generic and D.limits or 'Rapids to Z100. are left out.  Cut Z = deepest FEED move (how deep the tool goes).',
    '',
    string.format('%-7s %-6s %19s %19s %19s %10s', 'SUB', 'TOOL', 'X min / max', 'Y min / max', 'Z min / max', 'CUT Z'),
  }
  for _, sec in ipairs(secs) do
    local moves = Mo.walk(lines, sec, subtool[sec.name],{generic=generic,resets=meta.resets,masked=true})
    local lo, hi, cutz, varz = {}, {}, nil, false
    for _, m in ipairs(moves) do
      if m.kind ~= 'home' then
        for _, p in ipairs(Mo.points(m)) do
          for _, a in ipairs({ 'x', 'y', 'z' }) do
            if p[a] then
              lo[a] = math.min(lo[a] or p[a], p[a]); hi[a] = math.max(hi[a] or p[a], p[a])
            end
          end
          if m.kind ~= 'rapid' and p.z then cutz = math.min(cutz or p.z, p.z) end
        end
        if m.varz then varz = true end
      end
    end
    if lo.x or lo.y or lo.z then
      local tool = subtool[sec.name] and ('T' .. subtool[sec.name]) or (sec.name == 'MAIN' and '' or '?')
      out[#out + 1] = string.format('%-7s %-6s %s %s %s %s %s', sec.name, tool,
        f4(lo.x) .. f4(hi.x), f4(lo.y) .. f4(hi.y), f4(lo.z) .. f4(hi.z), f4(cutz),
        varz and ' (Z uses variables)' or '')
    end
  end
  for _,p in ipairs(U.issues(problems)) do out[#out+1]=(p.line and ('Line '..p.line..': ') or 'Program: ')..p.text end
  Mo.report('Range', out)
end, { desc = 'Min/max X Y Z for every sub' })

-- ---------------------------------------------------------------------
-- :CycleTime  -> estimate per tool + total.  :CycleTime write fills the header.
-- ---------------------------------------------------------------------
local function hms(sec)
  sec = math.floor(sec + 0.5)
  return string.format('%02.0f-%02.0f-%02.0f', math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60)
end

-- How a canned cycle comes back out decides its retract time, not G94/G95.
-- Okuma OSP (and hints.lua): taps G74/G84 (G274/G284) and bores G85/G89 feed out;
-- drills G73/G81/G82/G83, fine bore G76 and G86 (spindle stopped) rapid out.
-- G87 back bore, G88 and the other G2xx are not known here: their timing is left incomplete.
local FEED_OUT = { [74] = true, [84] = true, [85] = true, [89] = true, [274] = true, [284] = true }
local RAPID_OUT = { [73] = true, [76] = true, [81] = true, [82] = true, [83] = true, [86] = true }

local function finite(v)
  return type(v) == 'number' and v == v and v > -math.huge and v < math.huge
end

-- selected is a machine name/id for timing; control is the explicit dialect choice;
-- path is the file's name (Haas/Toshiba programs known only by their machine folder).
local function estimate(lines, selected, control, path)
  local context = require('gcode.profile').resolve(lines, control, path)
  if context.mode ~= 'generic' then
    return nil, 'No timing: ' .. context.reason
  end
  local issues, seen, display_issues = {}, {}, {}
  local function issue(text, detail)
    local p=U.issue(detail and vim.tbl_extend('force',detail,{text=text}) or {text=text,kind='unsupported',blocking=true})
    local key=vim.json.encode({p.line or false,p.kind,p.blocking,p.text})
    if not seen[key] then
      issues[#issues + 1] = text; seen[key] = true
      if p.line then p.text=p.text:gsub(' at line '..p.line..'$', '') end
      display_issues[#display_issues+1]=p
    end
  end
  -- note 11-13 W4: what the estimate fills with a stated allowance (a control sub nobody timed,
  -- a loop counted once). Not a blocker: the result is an ESTIMATE, and write marks it so.
  -- sub_allowance = false: the old rule - anything not known is a blocker, nothing is filled.
  local strict = cfg.sub_allowance == false
  local allowances, allowed = {}, {}
  local function allow(text)
    if not allowed[text] then allowed[text] = true; allowances[#allowances + 1] = text end
  end
  local family = context.control ~= 'okuma'
  -- Haas / Toshiba programs are timed on the moves Backplot draws (reader.lua)
  local reader = family and (context.reader == 'haas' or context.reader == 'tosnuc') and context.reader or nil
  local meta, original = {}, lines
  if family then
    -- Okuma VC200 machine selection and probe-sub allowances do not apply to another controller.
    if not reader then
      local prepared, problems, structure = D.prepare(lines,context.control)
      lines,meta = prepared,structure
      for _,value in ipairs(problems) do
        local p=U.issue(value)
        issue(p.text,p)
      end
    end
  end
  local function seconds(v, what)
    -- ponytail: exact whole-second/count arithmetic ends at 2^53; reject larger estimates.
    if finite(v) and v >= 0 and v < 2^53 then return v end
    issue('Unknown timing: ' .. what .. ' is invalid or exceeds numeric precision')
    return 0
  end
  local function value(m, key, default)
    if family and not m then return default,'estimated default (no machine in your list)' end
    local v, source = m and m[key], m and ('machine ' .. m.name)
    if v == nil then
      v = cfg[key]
      source = 'vim.g.gcode settings'
    end
    if v == nil then return default, 'estimated default' end
    if not finite(v) or v < 0 or ((key == 'rapid_ipm' or key == 'rotary_rpm') and v == 0) then
      issue('Invalid ' .. key .. ' from ' .. source)
      return default, 'estimated default (invalid override)'
    end
    return v, source
  end
  -- sub_seconds = { O9811 = 6 } for every machine, or per machine group: { ['101/102'] = { O9811 = 6 } }
  local no_subs = {}
  local function subs_of(m)
    for k, v in pairs(cfg.sub_seconds or {}) do
      if type(v) == 'table' and m and ('/' .. k .. '/'):find('/' .. m.id .. '/', 1, true) then return v end
    end
    return cfg.sub_seconds or no_subs
  end
  local candidates, present, matches = {}, {}, {}
  -- Timing normalizes case without broadening the existing preparation scanner.
  local timing_source={}
  for i,line in ipairs(lines) do timing_source[i]=line:upper() end
  local ids, _, selector_issues = require('gcode.profile').selectors(timing_source)
  for _,p in ipairs(selector_issues) do issue(p.text,p) end
  for _, id in ipairs(ids) do present[id] = true end
  for _, m in ipairs(U.machines()) do
    if selected and (selected == m.name or selected == m.id) then matches[#matches + 1] = m end
    if present[m.id] then
      candidates[#candidates + 1] = m; present[m.id] = nil
      if m.control ~= 'okuma' then issue('Machine ' .. m.id .. ' is listed as ' .. m.control .. ', not okuma') end
    end
  end
  for id in pairs(present) do issue('Unknown machine selector VC200=' .. id) end
  local machine, group
  if selected then
    if #matches ~= 1 then issue('Select one known machine name or id: ' .. selected)
    else
      machine = matches[1]
      if #ids>0 and not vim.tbl_contains(ids,machine.id) then
        issue('Selected timing machine conflicts with executable selectors: '..machine.name)
        machine=nil
      end
      if machine and machine.control ~= context.control then issue('Machine ' .. machine.id .. ' is listed as ' .. machine.control .. ', not ' .. context.control) end
    end
  elseif #candidates == 1 then machine = candidates[1]
  elseif #candidates > 1 then
    local one = candidates[1].name
    -- note 11-13 W1: machines with the same timings are one timing group (A.estimate decides)
    if vim.iter(candidates):all(function(m)
      local c = candidates[1]
      return m.rapid_ipm == c.rapid_ipm and m.tc_seconds == c.tc_seconds and m.rotary_rpm == c.rotary_rpm
        and m.approach_seconds == c.approach_seconds and subs_of(m) == subs_of(c)
    end) then group = candidates end
    issue('Machine execution/timings differ or require dispatch; select one with :CycleTime ' .. one .. ' or :CycleTime write ' .. one)
  end
  -- Haas/Toshiba/Mazak: the one machine the header or folder names (your list) gives the timing values
  if family and not machine and context.group and #context.group == 1 then
    for _, m in ipairs(U.machines()) do if m.id == context.group[1] then machine = m end end
  end
  if family and not machine then issue('No machine timing values (add the machine with :Machines); rapid/tool-change defaults are estimates') end
  local rapid, rapid_source = value(machine, 'rapid_ipm', 1000)
  local tc_seconds, tc_source = value(machine, 'tc_seconds', 8)
  local rotary_rpm, rotary_source = value(machine, 'rotary_rpm', 20)
  -- a rapid from a position that is not known (after a tool change, Z100., G56) gets an allowance;
  -- approach_seconds = false keeps it an unknown distance
  local approach, approach_source
  local exact = machine and machine.approach_seconds == false
    or not (machine and machine.approach_seconds ~= nil) and cfg.approach_seconds == false
  if exact then approach, approach_source = nil, 'approach_seconds = false'
  else approach, approach_source = value(machine, 'approach_seconds', 2) end
  local function ext_time(name)
    if family then return 0,false end
    local subsec = subs_of(machine)
    if type(subsec[name]) == 'number' then return seconds(subsec[name], name), true, 'configured sub_seconds['..name..']' end
    if name:match('^O98%d%d$') and cfg.probe_seconds ~= nil then
      return seconds(cfg.probe_seconds, 'probe_seconds'), true, 'configured probe_seconds'
    end
    -- note 11-13 W3: no time known: O9810 is timed as its move (in the CALL below), any other
    -- sub gets a stated allowance. The subs' own code is never run to get a time.
    if strict then return 0, false end
    local a = type(cfg.sub_allowance) == 'number' and seconds(cfg.sub_allowance, 'sub_allowance') or 5
    if name == 'O9810' then return a, true, 'its move to PX/PY/PZ at PF', true, true end
    return a, true, 'allowance: not timed at the machine', true
  end
  -- Preserve line numbers while masking ignored text for BOTH discovery and walking.
  local masked=require('gcode.profile').mask(lines)
  lines = vim.tbl_map(string.upper,masked)
  local secs = reader and {} or Mo.sections(lines,true)
  local planned={}
  local byname, cache, active, path = {}, {}, {}, {}
  for _, sec in ipairs(secs) do
    if byname[sec.name] then issue('Duplicate section ' .. sec.name,{line=sec.s}) end
    byname[sec.name] = sec
  end
  local function empty()
    return { cut = 0, rap = 0, ntc = 0, loops = 0, approaches = 0, per = {}, order = {}, ext = {} }
  end
  local function add(t, tool, cut, rap)
    local k = tool or '?'
    if not t.per[k] then t.per[k] = { cut = 0, rap = 0 }; t.order[#t.order + 1] = k end
    t.per[k].cut = seconds(t.per[k].cut + cut, 'tool cutting total')
    t.per[k].rap = seconds(t.per[k].rap + rap, 'tool rapid total')
    t.cut, t.rap = seconds(t.cut + cut, 'cutting total'), seconds(t.rap + rap, 'rapid total')
  end
  local function merge(t, child)
    for _, k in ipairs(child.order) do add(t, k, child.per[k].cut, child.per[k].rap) end
    t.ntc, t.loops = seconds(t.ntc + child.ntc, 'tool changes'), seconds(t.loops + child.loops, 'loops')
    t.approaches = t.approaches + child.approaches
    t.allow = (t.allow or 0) + (child.allow or 0)
    for k, names in pairs(child.ext) do
      t.ext[k] = t.ext[k] or {}
      for name, n in pairs(names) do t.ext[k][name] = seconds((t.ext[k][name] or 0) + n, 'external CALL count') end
    end
  end
  local evaluations, facts = 0, {}
  -- Whose CUTTING time a problem can change, for each tool's (T-START) line: a feed move or an
  -- external sub's CALL is its tool's ('?' when the tool is not known); a rapid, a dwell, a G71
  -- return, a rotary position or a probe CALL is no tool's cutting ('-'), and so is an IF or GOTO
  -- whose label is in the section (the lines it can skip are timed as if they run, the most each
  -- run can take). A cycle or a rotary feed the walk cannot time is its tool's. Any other problem
  -- the walk meets (an IF with no label here) is its section's tool's, or every tool's ('*') when
  -- the section changes tools. used: the tools cutting on each line, for the loops below.
  local linetools, owners, looped = {}, {}, {}
  local function note(set, key, tool)
    if not key then return end
    set[key] = set[key] or {}
    set[key][tool or '?'] = true
  end
  -- distance of a move over the axes it moves; a rapid whose start is unknown on a moved axis
  -- is an approach (third value)
  local function travel(m)
    if not m.axes or m.kind == 'arc' and not m.r then return Mo.length(m) end
    local f, to, unknown_start = vim.deepcopy(m.from), vim.deepcopy(m.to), false
    for _, a in ipairs({ 'x', 'y', 'z' }) do
      if not m.axes[a] then f[a] = f[a] or 0; to[a] = f[a]
      elseif f[a] == nil and to[a] ~= nil and m.kind == 'rapid' then unknown_start = true; f[a] = to[a] end
    end
    local d, complete = Mo.length(vim.tbl_extend('force', m, { from = f, to = to }))
    return d, complete, unknown_start
  end
  -- seconds of each move, added to t by tool
  local function time_moves(t, moves)
    for _, m in ipairs(moves) do
      note(linetools, m.line, (m.kind == 'rapid' or m.kind == 'home') and '-' or m.tool)
      local distance, complete, unknown_start = travel(m)
      unknown_start = unknown_start or m.rot_start
      if unknown_start and not approach then complete = false end
      local pl = Mo.PLANES[m.plane or 17]
      if m.kind=='arc' and not (m['c'..pl.a] and m['c'..pl.b] and m.r) then issue('Unknown arc distance at line '..m.line,{line=m.line}) end
      -- a straight move to or from a place not known (Z=VC43, a feed right after G56): the
      -- approach allowance, stated (note 11-13 W4). An arc or cycle like that stays a blocker.
      local filled = not strict and not complete and approach and (m.kind == 'rapid' or m.kind == 'feed')
      if filled then
        allow('Line ' .. m.line .. ': move to or from a position not known: ' .. approach .. ' sec')
        t.allow = (t.allow or 0) + approach
      elseif not complete and m.kind ~= 'home' then issue('Unknown motion distance at line ' .. m.line,{line=m.line}) end
      local d = seconds(distance, 'motion length at line ' .. m.line)
      local cut, rap = 0, 0
      if m.kind == 'rapid' or m.kind == 'home' then
        -- linear and rotary axes move together: the slower one sets the time
        rap = m.kind == 'home' and 2 or d / rapid * 60
        if m.rot then rap = math.max(rap, m.rot / (rotary_rpm * 6)) end
        if unknown_start and approach then rap = math.max(rap, approach); t.approaches = t.approaches + 1 end
      else
        local ipm = m.feed
        if m.fpr then ipm = finite(ipm) and finite(m.s) and ipm * m.s or nil end
        if m.inverse and finite(ipm) and ipm > 0 then
          cut = 60 / ipm                                                -- G93: F is 1 / minutes for the move
        elseif finite(ipm) and ipm > 0 then
          cut = d / ipm * 60
          if m.kind == 'cycle' and FEED_OUT[m.cyc] then cut = cut * 2 end   -- in and out at feed
        elseif d > 0 or m.kind == 'cycle' then
          issue('Unknown feed/spindle timing at line ' .. m.line,{line=m.line})
        end
        if m.kind == 'cycle' and RAPID_OUT[m.cyc] then rap = d / rapid * 60
        elseif m.kind == 'cycle' and not FEED_OUT[m.cyc] then
          issue('Unknown G' .. tostring(m.cyc) .. ' cycle retract timing at line ' .. m.line,{line=m.line})
        end
      end
      if filled and m.kind == 'rapid' then rap = rap + approach elseif filled then cut = cut + approach end
      add(t, m.tool, seconds(cut, 'cutting at line ' .. m.line), seconds(rap, 'rapid at line ' .. m.line))
    end
  end
  local function total(name, state)
    if active[name] then error('Recursive CALL path: ' .. table.concat(path, ' -> ') .. ' -> ' .. name, 0) end
    local key = vim.inspect(state or {})
    if cache[name] and cache[name][key] then return cache[name][key] end
    evaluations=evaluations+1
    if evaluations>1024 then error('Timing state evaluation limit exceeds 1024 summaries; estimate incomplete',0) end
    -- Bound stack depth separately from distinct incoming-state expansion.
    if #path >= 256 then error('CALL nesting exceeds 256 sections; estimate incomplete', 0) end
    active[name] = true; path[#path + 1] = name
    local t = empty()
    -- for loops: the tools that cut on each line of this section (a feed move, a CALL) and the
    -- lines that change tools
    local used, changes = {}, {}
    if not planned[name] then
      planned[name]=family and lines or require('gcode.timing').path(lines,byname[name],machine,issue,facts)
    end
    local moves, ev, returned = Mo.walk(planned[name], byname[name], nil,{
      generic=family,resets=meta.resets,timing=not family,state=state,masked=true,
      call=function(sub, caller, line)
        if byname[sub] then
          local child=total(sub,caller)
          merge(t,child)
          for _, k in ipairs(child.order) do if child.per[k].cut > 0 then note(used, line, k) end end
          if child.ntc > 0 then changes[line] = true end
          return vim.deepcopy(child.state)
        end
        local duration,known,_,allowance,move=ext_time(sub)
        if move then
          -- O9810 (protected move): from where the caller is to PX/PY/PZ at PF
          local d2, feed = 0, tonumber(lines[line]:match('%f[%w]PF%s*=%s*([%d%.]+)'))
          for a, v in lines[line]:gmatch('%f[%w]P([XYZ])%s*=%s*([^%s]+)') do
            local to, from = tonumber(v), caller[a:lower()]
            d2 = to and from and d2 and d2 + (to - from) ^ 2 or nil
          end
          if d2 and feed and feed > 0 then duration, allowance = math.sqrt(d2) / feed * 60, false
          elseif approach then duration, allowance = approach, false; t.approaches = t.approaches + 1 end
        end
        if allowance then
          allow(sub .. ': ' .. duration .. ' sec per CALL (no time for it in vim.g.gcode sub_seconds)')
          t.allow = (t.allow or 0) + duration
        end
        note(linetools, line, sub:match('^O98') and '-' or caller.tool)
        if not sub:match('^O98') then note(used, line, caller.tool) end
        if not known then issue('Unknown external sub timing: '..sub..' at line '..line,{line=line}) end
        if move then t.moved = t.moved or {}; t.moved[#t.moved + 1] = duration end
        local probe=sub:match('^O98')
        add(t,caller.tool,probe and 0 or duration,probe and duration or 0)
        local k=caller.tool or '?'
        t.ext[k]=t.ext[k] or {}; t.ext[k][sub]=(t.ext[k][sub] or 0)+1
        if not known then
          issue('Unknown external return state: '..sub..' at line '..line,{line=line})
          return Mo.unknown_state()
        end
        -- A timed sub ends where it was called, with the caller's modes; O9810 (protected
        -- positioning) ends at its PX/PY/PZ. A probe that corrects a work offset (O9811 PS=)
        -- moves it by thousandths: kept. Any other sub that writes offsets (OSET1 PS=1 PF=17)
        -- leaves every offset, and the position, unknown.
        local back=vim.deepcopy(caller)
        if sub=='O9810' then
          for a,v in lines[line]:gmatch('P([XYZ])%s*=%s*([^%s]+)') do back[a:lower()]=tonumber(v) end
        end
        if not probe and lines[line]:find('%f[%w]PS%s*=') then
          back.frames={}
          for _,a in ipairs({'x','y','z','a','b','c'}) do back[a]=nil end
        end
        return back
      end,
    })
    t.ntc = seconds(t.ntc + (ev.tools and #ev.tools or 0),'tool changes')
    t.loops = seconds(t.loops + ev.loops,'loops')
    for _, unknown in ipairs(ev.timing_unknown) do
      -- an IF or GOTO whose label is in this section is timed (W4): the lines it can skip count
      -- as if they run, a loop counts once. One with no label here stays a blocker.
      if strict then issue('Unknown ' .. unknown.text .. ' timing at line ' .. unknown.line,{line=unknown.line})
      elseif unknown.back then allow('Line ' .. unknown.line .. ': loop back to line ' .. unknown.back .. ' counted once (the real time is longer by every extra pass)')
      elseif unknown.jump then allow('Line ' .. unknown.line .. ': the lines this IF / GOTO can skip are timed as if they run')
      else issue('Unknown ' .. unknown.text .. ' timing at line ' .. unknown.line,{line=unknown.line}) end
    end
    time_moves(t, moves)
    for _,d in ipairs(ev.dwells) do add(t,d.tool,0,seconds(d.seconds,'dwell in '..name)) end
    -- a problem on a line that is not a move or CALL here, and whose cutting it can change:
    --   no tool's: a dwell, a G71 return level or travel, a rotary index (rapid time); an IF or
    --     GOTO with its label further down (the lines it can skip count as if they run, and the
    --     walk takes the tool on past the label, or none when the two bring different tools);
    --     one with its label back up is a loop (the loop rule below)
    --   the tool in the spindle: a cycle or rotary feed it cannot time
    --   otherwise the tools this section times and the tool it was called with; every tool when
    --     it changes tools (a G operand, a tool selection, an IF with no label here)
    for _, u in ipairs(ev.timing_unknown) do
      if not linetools[u.line] then
        local key = u.line .. '|Unknown ' .. u.text .. ' timing'
        local x = u.text
        if x:match('^dwell') or x:match('^G71 return') or x:match('^rotary position') or u.jump then
          note(owners, key, '-')
        elseif x:match('^cycle') or x:match('^arc/cycle') or x:match('^rotary feed') then
          note(owners, key, u.tool)
        elseif t.ntc > 0 then note(owners, key, '*')
        else
          note(owners, key, state and state.tool)
          for _, k in ipairs(t.order) do note(owners, key, k) end
        end
      end
    end
    -- a loop is counted once: the tools that cut between its label and its IF or GOTO repeat
    -- (and the subs it CALLs there). One that changes tools leaves no tool's time known: the
    -- first lines run again with another tool. A loop the walk did not place: every tool here.
    for _, m in ipairs(moves) do
      if m.kind ~= 'rapid' and m.kind ~= 'home' then note(used, m.line, m.tool) end
    end
    for _, x in ipairs(ev.tools or {}) do changes[x.line] = true end
    local placed = 0
    for _, u in ipairs(ev.timing_unknown) do
      if u.back then
        placed = placed + 1
        local why = 'Line ' .. u.line .. ': a loop back to line ' .. u.back .. ' is counted once'
        for i = u.back, u.line do
          if changes[i] then looped['*'] = looped['*'] or (why .. ' and changes tools') end
          for k in pairs(used[i] or {}) do looped[k] = looped[k] or why end
        end
      end
    end
    if ev.loops > placed then
      for _, k in ipairs(t.order) do looped[k] = looped[k] or ('Program: a loop in ' .. name .. ' is counted once') end
    end
    t.state=returned
    path[#path] = nil; active[name] = nil
    cache[name] = cache[name] or {}; cache[name][key] = t
    return t
  end
  -- Haas / Toshiba: the whole program in one walk, past work offsets and faces; a rapid from a
  -- position it does not know gets the approach allowance. Reader notes say 'timed', not 'drawn'.
  local function walked()
    local t = empty()
    local rsecs, problems, _, stats = require('gcode.reader').walk(original, reader, { timing = true })
    for _, p in ipairs(problems) do
      local text = p.text:gsub('^Not drawn: ', 'Not timed: '):gsub('drawn', 'timed'):gsub('drawing', 'timing'):gsub('to draw', 'to time')
      issue(text, { line = p.line, kind = p.kind, blocking = p.kind ~= 'assumed' })
    end
    for _, sec in ipairs(rsecs) do time_moves(t, sec.moves) end
    t.ntc = seconds(stats.ntc, 'tool changes')
    for _, d in ipairs(stats.dwells) do
      if d.seconds then add(t, d.tool, 0, seconds(d.seconds, 'dwell at line ' .. d.line))
      else issue('Unknown dwell time at line ' .. d.line, { line = d.line }) end
    end
    for _, x in ipairs(stats.unknown) do issue('Unknown ' .. x.text .. ' timing at line ' .. x.line, { line = x.line }) end
    for _, p in ipairs(stats.probes) do
      note(linetools, p.line, '-')
      issue('Unknown probe cycle timing: ' .. p.name .. ' at line ' .. p.line, { line = p.line })
      local k = p.tool or '?'
      t.ext[k] = t.ext[k] or {}; t.ext[k][p.name] = (t.ext[k][p.name] or 0) + 1
    end
    return t
  end
  local ok, result
  if reader then ok, result = pcall(walked) else ok, result = pcall(total, 'MAIN') end
  local e = ok and result or empty()
  if not ok then issue(result) end
  -- Each tool's own time (for its (T-START) line): unknown when a blocker or assumption is on a
  -- line that tool moves or CALLs on, or when a loop repeats it (only the tools cutting between
  -- the loop's label and its jump back; every tool when the loop changes tools, or when the loop's
  -- label is not found). A problem on any other line (a selector, a section) or on no line leaves
  -- every tool's time unknown (tool_whole). So does cutting the estimate cannot give a tool while
  -- anything is unknown: after an untimed sub the tool is not known, and that cutting may be any
  -- tool's. (With everything known it is only the tool left in the spindle, before the first tool
  -- change.)
  e.tool_unknown, e.tool_whole = {}, nil
  local blocked = strict and next(looped) ~= nil
  for _, p in ipairs(display_issues) do
    if p.blocking or p.kind == 'assumed' then
      blocked = true
      local text = (p.line and ('Line ' .. p.line .. ': ') or 'Program: ') .. p.text
      local where = p.line and (owners[p.line .. '|' .. p.text] or linetools[p.line])
      if not where or where['*'] then e.tool_whole = e.tool_whole or text
      else
        for k in pairs(where) do if k ~= '-' then e.tool_unknown[k] = e.tool_unknown[k] or text end end
      end
    end
  end
  for k, why in pairs(strict and looped or {}) do
    if k == '*' then e.tool_whole = e.tool_whole or why else e.tool_unknown[k] = e.tool_unknown[k] or why end
  end
  if blocked and e.per['?'] and (e.per['?'].cut > 0 or e.tool_unknown['?']) then
    e.tool_whole = e.tool_whole or 'Program: cutting with no tool known'
  end
  if e.loops > 0 and strict then issue('Loop iteration counts unknown; loops counted once')
  elseif e.loops > 0 then allow(e.loops .. ' loop(s) counted once: how many passes is not in the code') end
  e.tc = seconds(e.ntc * tc_seconds, 'tool-change total')
  e.run = seconds(e.cut + e.rap + e.tc, 'run total')
  e.conditions = not family and require('gcode.timing').conditions(facts) or nil
  e.machine, e.group = machine and machine.name, group
  e.notes = {}
  for k, names in pairs(e.ext) do
    for name, n in pairs(names) do
      local duration, known, source, allowance, move = ext_time(name)
      e.notes[#e.notes + 1] = { tool = k, name = name, n = n, sec = duration, known = known, source = source,
        allowance = allowance and not move, move = move }
    end
  end
  table.sort(e.notes, function(a, b) return a.tool .. a.name < b.tool .. b.name end)
  e.rapid, e.rapid_source, e.tc_seconds, e.tc_source = rapid, rapid_source, tc_seconds, tc_source
  e.rotary_rpm, e.rotary_source, e.approach, e.approach_source = rotary_rpm, rotary_source, approach, approach_source
  e.mode, e.control, e.reader = context.mode, context.control, reader
  e.writable = require('gcode.profile').can_edit(context)
  e.prepare = require('gcode.profile').can_prepare(context)
  -- Timing assumptions still prevent header writes, independently of interpretation blockers.
  e.issues, e.incomplete = issues, vim.iter(display_issues):any(function(p) return p.blocking or p.kind=='assumed' end)
  e.display_issues = U.issues(display_issues)
  e.allowances, e.estimate = allowances, #allowances > 0 and not e.incomplete
  return e
end
-- note 11-13 W1: a program for machines with the same timings (101/102) needs no machine
-- named, as long as each machine's own lines (IF[VC200 EQ ..]) take the same time.
function A.estimate(lines, selected, control, path)
  local e, why = estimate(lines, selected, control, path)
  if not e or selected or not e.group then return e, why end
  local first
  local names = {}
  for _, m in ipairs(e.group) do
    -- by id: one machine name can be listed under two ids
    local x = estimate(lines, m.id, control, path)
    if not vim.tbl_contains(names, m.name) then names[#names + 1] = m.name end
    first = first or x
    if not x or x.incomplete ~= first.incomplete or math.abs(x.run - first.run) > .5 or math.abs(x.cut - first.cut) > .5 then return e end
  end
  first.machine = table.concat(names, '/') .. (#names > 1 and ' (same timings)' or '')
  return first
end

function A.report(e)
  local items=U.issues(e.display_issues or e.issues)
  local incomplete=e.incomplete or vim.iter(items):any(function(p) return p.blocking or p.kind=='assumed' end)
  local out = {
    (incomplete and 'INCOMPLETE' or e.estimate and 'ESTIMATE (with allowances)' or 'COMPLETE')..' — cycle time estimate (q closes)',
    (incomplete and 'Partial time: ' or 'Estimated cycle time: ')..hms(e.run),
    'Controller: '..e.control..' | Timing machine: '..(e.machine or 'not selected'),
    'Report only. ' .. require('gcode.profile').limits,
    string.format('Rapid %g IPM (%s)', e.rapid, e.rapid_source),
    string.format('Tool change %g sec (%s)', e.tc_seconds, e.tc_source),
    'Set rapid_ipm / tc_seconds per machine with :Machines; fallbacks go in vim.g.gcode.',
    e.reader and 'No acceleration. A G28 / G30 / G53 home move: 2 sec. A table or rotary index (A / B / C) is inside the approach allowance.'
      or string.format('Rotary %g rpm (%s). No acceleration. Home-to-Z100 allowance: 2 sec.', e.rotary_rpm or 20, e.rotary_source or 'estimated default'),
    e.approach and string.format('Rapid from a position not known (after a tool change, %s): %g sec each, %g moves (%s)',
      e.reader and 'work offset, G43 or index' or 'Z100., G56', e.approach, e.approaches or 0, e.approach_source)
      or 'approach_seconds = false: a rapid from a position not known is left unknown',
    e.reader and 'Probe cycles, macro calls and programs not in this file are not timed; a G04 dwell is. M-codes (coolant, M01) take no time.'
      or 'Timed subs end where they were called, with the caller\'s modes (O9810 at its PX/PY/PZ). A probe\'s PS= offset update is taken as a small correction; another sub\'s PS= leaves every offset unknown. M-codes (coolant, wash, conveyor, M01) take no time.',
    '',
    string.format('%-8s %10s %12s', 'TOOL', 'CUTTING', 'RAPID/PROBE'),
  }
  local assumptions,blockers={},{}
  for _,item in ipairs(items) do
    local text=(item.line and ('Line '..item.line..': ') or 'Program: ')..item.text
    if item.kind=='assumed' then assumptions[#assumptions+1]=text
    elseif item.blocking then blockers[#blockers+1]=text end
  end
  local summary={}
  if #assumptions>0 then
    summary[#summary+1]='Assumptions: '..table.concat(assumptions,'; ')
  end
  if #blockers>0 then
    summary[#summary+1]='First blocker: '..blockers[1]
    if #blockers>1 then summary[#summary+1]='Additional blockers: '..(#blockers-1)..' (all details below)' end
  end
  for i=#summary,1,-1 do table.insert(out,5,summary[i]) end
  if e.conditions then table.insert(out,#out-1,e.conditions) end -- above the tool table
  local own = e.tool_unknown or {}
  for _, k in ipairs(e.order) do
    out[#out + 1] = string.format('%-8s %10s %12s', 'T' .. k, hms(e.per[k].cut), hms(e.per[k].rap))
      .. (incomplete and not e.tool_whole and own[k] and ('   not known: ' .. own[k]) or '')
  end
  out[#out + 1] = ''
  out[#out + 1] = string.format('%-8s %10s   (%g tool changes)', 'CHANGES', hms(e.tc), e.ntc)
  out[#out + 1] = string.format('%-8s %10s', 'CUTTING', hms(e.cut))
  out[#out + 1] = (incomplete and 'Partial time: ' or 'Estimated cycle time: ')..hms(e.run)
  local unknown, probes = {}, {}
  for _, x in ipairs(e.notes) do
    if not x.known or x.allowance then unknown[#unknown + 1] = x
    elseif x.name:match('^O98') and x.name ~= 'O9832' and x.name ~= 'O9833' then probes[#probes + 1] = x end
  end
  if #probes > 0 then
    local n = 0
    for _, x in ipairs(probes) do n = n + x.n end
    out[#out + 1] = ''
    out[#out + 1] = string.format('Probe moves: %g CALLs (probe_seconds / sub_seconds in vim.g.gcode)', n)
  end
  if #unknown > 0 and e.reader then
    out[#out + 1] = ''
    out[#out + 1] = '! Probe cycles - NOT counted (their touch moves are not known here):'
    for _, x in ipairs(unknown) do
      out[#out + 1] = string.format('    T%-6s %s x%g', x.tool, x.name, x.n)
    end
  elseif #unknown > 0 then
    out[#out + 1] = ''
    out[#out + 1] = '! Subs on the control - counted with an ALLOWANCE (nobody timed them):'
    for _, x in ipairs(unknown) do
      out[#out + 1] = string.format('    T%-6s %s x%g at %g sec', x.tool, x.name, x.n, x.sec)
    end
    out[#out + 1] = '  Checked part (no allowances): ' .. hms(e.run - (e.allow or 0)) .. '   Allowances: ' .. hms(e.allow or 0)
    out[#out + 1] = '  Time one at the machine and add it to vim.g.gcode, for example:'
    out[#out + 1] = '    sub_seconds = { ' .. unknown[1].name .. ' = 45 },   (seconds per CALL)'
  end
  for _,x in ipairs(e.notes) do
    if x.move then out[#out+1]=string.format('%s: x%g, timed as %s', x.name, x.n, x.source)
    elseif x.known and not x.allowance then out[#out+1]=string.format('%s: %g sec/CALL x%g (%s)',x.name,x.sec,x.n,x.source) end
  end
  if e.loops > 0 then
    out[#out + 1] = ''
    out[#out + 1] = '! ' .. e.loops .. ' loop(s) (IF ... jump back, like NST1 step-downs) counted ONCE -'
    out[#out + 1] = '  the real time is longer by every extra pass.'
  end
  out[#out + 1] = ''
  if e.allowances and #e.allowances > 0 then
    out[#out + 1] = 'Allowances used (they make this an ESTIMATE):'
    for _, a in ipairs(e.allowances) do out[#out + 1] = '~ ' .. a end
    out[#out + 1] = ''
  end
  if #items>0 then
    out[#out+1]='All issues and assumptions:'
    for _,item in ipairs(items) do out[#out+1]='! '..(item.line and ('Line '..item.line..': ') or 'Program: ')..item.text end
  end
  local tools_line = not incomplete and ', and each tool\'s CUTTING time in its (T-START) line'
    or e.tool_whole and '; no tool time can be written either (' .. e.tool_whole .. ')'
    or '; it puts each tool\'s CUTTING time in its (T-START) line, except a tool marked "not known"'
  out[#out + 1] = e.writable and ((e.estimate and ':CycleTime write puts this ESTIMATE in the timing headers, marked (ESTIMATE)'
      or ':CycleTime write fills timing headers only when the estimate is complete') .. tools_line)
    or 'Timing is report only; timing headers cannot be written in this context'
  return out
end

-- The (T-START) tool list: (101 ;00-00-00; DESCRIPTION). The hh-mm-ss between the first two
-- semicolons gets that tool's CUTTING time when its own time is known (e.tool_unknown,
-- e.tool_whole); a tool whose time is not known, or that the program does not use, keeps what
-- it has. Changes lines in place; returns the tools filled and the tools left, for the message.
local function tool_times(lines, e)
  local source, _, starts = require('gcode.profile').mask(lines)
  local filled, left, in_t = {}, {}, false
  for i = 1, U.first_sub(source) - 1 do
    local l = lines[i]
    if starts[i] and l:match('^%(T%-START') then in_t = true end
    if in_t and starts[i] then
      local head, n, tail = l:match('^(%((%d+)%s*;%s*)%d%d+%-%d%d%-%d%d(%s*;.*)$')
      if n then
        -- T7 in the program and (07 ;...) in the list are the same tool
        local cut, why = nil, nil
        for k, v in pairs(e.per) do
          if tonumber(k) == tonumber(n) then cut = (cut or 0) + v.cut; why = why or e.tool_unknown[k] end
        end
        why = not cut and 'not used in this program' or e.tool_whole or why
        if why then left[#left + 1] = 'T' .. n .. ' (' .. why .. ')'
        else
          lines[i] = head .. hms(cut) .. tail
          filled[#filled + 1] = 'T' .. n .. ' ' .. hms(cut)
        end
      end
    end
    if starts[i] and l:match('^%(T%-END') then in_t = false end
  end
  return filled, left
end
A.tool_times = tool_times

vim.api.nvim_create_user_command('CycleTime', function(o)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local write, selected = false, nil
  for _, arg in ipairs(o.fargs) do
    if arg == 'write' and not write then write = true
    elseif not selected and (arg:match('^M%d+$') or arg:match('^%d+$')) then selected = arg
    else return vim.notify('Usage: CycleTime [write] [machine name or id]', vim.log.levels.ERROR) end
  end
  local context = require('gcode.profile').context(0)
  if write and not require('gcode.profile').can_edit(context) then
    return vim.notify('Header not updated. CycleTime write is not part of Swarf: timing is report only (:CycleTime)', vim.log.levels.WARN)
  end
  local e, reason = A.estimate(lines, selected, vim.b.gcode_control, vim.api.nvim_buf_get_name(0))
  if not e then return vim.notify(reason, vim.log.levels.WARN) end
  local run = e.run
  if write then
    -- each tool's own time goes in its (T-START) line even when another tool's is not known;
    -- the RUN-TIME / CUTTING-TIME / AUX-TIME totals only when the whole estimate is complete
    local filled, left = tool_times(lines, e)
    local tools = (#filled > 0 and ('\nTool times: ' .. table.concat(filled, ', ')) or '')
      .. (#left > 0 and ('\nTool times left as they were: ' .. table.concat(left, '; ')) or '')
    if e.incomplete then
      local details=vim.tbl_map(function(p) return (p.line and ('Line '..p.line..': ') or 'Program: ')..p.text end,U.issues(e.display_issues))
      if #filled == 0 then
        return vim.notify('Header not updated. CycleTime write refused: estimate incomplete\n' .. table.concat(details, '\n'), vim.log.levels.WARN)
      end
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      return vim.notify('RUN-TIME / CUTTING-TIME not updated: estimate incomplete' .. tools .. '\n'
        .. table.concat(details, '\n') .. '\n(u to undo)', vim.log.levels.WARN)
    end
    local n = 0
    for i, l in ipairs(lines) do
      if l:match('^%(RUN%-TIME=') then lines[i] = '(RUN-TIME=' .. hms(run) .. ')' .. (e.estimate and ' (ESTIMATE)' or ''); n = n + 1 end
      if l:match('^%(CUTTING%-TIME=') then lines[i] = '(CUTTING-TIME=' .. hms(e.cut) .. ')'; n = n + 1 end
      if l:match('^%(AUX%-TIME=') then lines[i] = '(AUX-TIME=' .. hms(e.rap + e.tc) .. ')'; n = n + 1 end
    end
    if n == 0 and #filled == 0 then return vim.notify('Header not updated: no (RUN-TIME= lines in the header') end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    return vim.notify((e.conditions and (e.conditions .. '\n') or '')
      .. (n > 0 and ('RUN-TIME=' .. hms(run) .. (e.estimate and ' (ESTIMATE, with allowances - see :CycleTime)' or '') .. '  CUTTING-TIME=' .. hms(e.cut)) or 'No (RUN-TIME= lines in the header')
      .. tools .. '  (u to undo)')
  end
  Mo.report('CycleTime', A.report(e))
  vim.wo.wrap=true; vim.wo.linebreak=true
end, { nargs = '*', complete = function()
  local items = { 'write' }
  for _, m in ipairs(U.machines()) do items[#items + 1] = m.name end
  return items
end, desc = 'Estimate cycle time' })

-- ---------------------------------------------------------------------
-- :ArcCheck  -> every G02/G03 whose start and end aren't the same distance from I/J
-- ---------------------------------------------------------------------
-- items, nil, unchecked (one line naming the part not checked, or nil)
-- nil, reason when the program's control is not known; path as for estimate()
function A.arc_problems(lines, control, path)
  local c = require('gcode.profile').resolve(lines, control, path)
  if c.mode ~= 'generic' then return nil, c.reason end
  local items, unchecked = {}, nil
  local function bad(a)
    items[#items + 1] = { line = a.line, kind='invalid', blocking=true, text = a.text or string.format(
      'arc does not close: start radius %.5f, end radius %.5f (off %.5f)', a.r1, a.r2, math.abs(a.r1 - a.r2)) }
  end
  local function noarc(l) items[#items + 1] = { line = l, kind='invalid', blocking=true, text = 'G02/G03 with no I/J/R' } end
  local function list()
    return vim.tbl_map(function(p)
      return {lnum=p.line,text=(p.line and '' or 'Program: ')..p.text}
    end,U.issues(items)), nil, unchecked
  end
  if c.reader == 'haas' or c.reader == 'tosnuc' then
    -- Haas and Toshiba programs: read the way Backplot draws them (work offsets,
    -- G49, block skip, IF/GOTO); only real arc faults are listed
    local _, _, arcs = require('gcode.reader').walk(lines, c.reader)
    vim.tbl_map(bad, arcs.bad); vim.tbl_map(noarc, arcs.noarc)
    local u = arcs.unchecked
    if #u > 0 then
      unchecked = (u[1].after and ('Arcs after line ' .. u[1].after) or ('Arcs from line ' .. u[1].line))
        .. ' not checked' .. (#u > 1 and (' (' .. #u .. ' arcs)') or '') .. ': ' .. u[1].why
    end
    return list()
  end
  local family = c.control ~= 'okuma'
  local problems,meta = {},{}
  if family then lines,problems,meta=D.prepare(lines,c.control)
  else lines,problems=require('gcode.profile').mask(lines) end
  local secs, subtool = Mo.sub_tools(lines,true)
  if family then
    -- what stops the reading is not an arc fault: name the first one, once
    local first = U.issues(problems)[1]
    if first then
      unchecked = (first.line and ('Arcs after line ' .. first.line) or 'Arcs') .. ' not checked: ' .. first.text:gsub('^%a+: ', '')
    end
  else
    for _,p in ipairs(problems) do items[#items+1]=U.issue(p) end
  end
  for _, sec in ipairs(secs) do
    local _, ev = Mo.walk(lines, sec, subtool[sec.name],{generic=family,resets=meta.resets,masked=true})
    vim.tbl_map(bad, ev.arcbad); vim.tbl_map(noarc, ev.noarc)
  end
  return list()
end

vim.api.nvim_create_user_command('ArcCheck', function()
  if not require('gcode.profile').interpret('ArcCheck') then return end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local items, reason, unchecked = A.arc_problems(lines, vim.b.gcode_control, vim.api.nvim_buf_get_name(0))
  if not items then return vim.notify('ArcCheck: nothing checked - ' .. reason, vim.log.levels.WARN) end
  local within = '(within ' .. (cfg.arc_tol or .0005) .. ')'
  if #items == 0 then
    return vim.notify(unchecked and ('The arcs it could read check out ' .. within .. '. ' .. unchecked)
      or ('All arcs check out ' .. within))
  end
  local buf = vim.api.nvim_get_current_buf()
  if unchecked then items[#items + 1] = { lnum = tonumber(unchecked:match('line (%d+)')), text = unchecked, type = 'I' } end
  for _, it in ipairs(items) do if it.lnum and it.lnum<=#lines then it.bufnr=buf else it.lnum,it.valid=0,0 end end
  vim.fn.setqflist({}, ' ', { title = 'Arc check', items = items })
  vim.cmd('copen')
end, { desc = 'Check every arc closes' })

return A
