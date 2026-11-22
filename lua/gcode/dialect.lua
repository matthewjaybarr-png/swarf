-- Controller language, never machine-edit authority. See CONTROLLERS.md for sources/limits.
local D = {}
local Mo = require('gcode.motion')
local U = require('gcode.util')
D.names = { okuma = 'Okuma OSP', ['mazak-matrix'] = 'Mazak Matrix G-code',
  tosnuc = 'Toshiba TOSNUC', haas = 'Haas milling' }
D.limits = 'Partial language interpretation, not simulation. Coordinates/reports use inches. Unsupported blocks stop dependent geometry; timing is report only.'

local common = { [0]='Positioning (schematic straight path; actual rapid trajectory is machine-dependent)',
  [1]='Linear interpolation', [2]='Clockwise arc', [3]='Counterclockwise arc',
  [17]='XY plane', [18]='ZX plane (linear only here)', [19]='YZ plane (linear only here)',
  [90]='Absolute positioning', [91]='Incremental positioning',
  [94]='Feed per minute', [95]='Feed per revolution' }
function D.hint(word, control)
  local n = tonumber(word:match('^G(%d+)$'))
  local text = common[n]
  if control == 'tosnuc' then
    if n == 70 then text = 'Inch units' elseif n == 71 then text = 'Metric units'
    elseif n == 72 then text = 'Subprogram call; argument/return interpretation unsupported'
    elseif n == 73 then text = 'Machine-coordinate positioning; geometry unsupported' end
  elseif control ~= 'okuma' then
    if n == 20 then text = 'Inch units' elseif n == 21 then text = 'Metric units' end
    if word == 'M98' then text = 'Subprogram call: simple M98 Pnumber supported'
    elseif word == 'M99' then text = 'Subprogram return; main-program loop unsupported' end
    local m = tonumber(word:match('^M(%d+)$'))   -- Haas coolant
    if control == 'haas' and m == 8 then text = 'Flood coolant ON'
    elseif control == 'haas' and m == 88 then text = 'Through-spindle coolant ON' end
  elseif n == 71 then text = 'OSP cycle return level (not metric selection)' end
  return { word .. ' - ' .. (text or 'Unsupported or controller-specific construct; consult the controller manual'),
    control=='okuma' and 'Existing partial OSP parser; not a controller simulation.' or D.limits }
end

local function id(s) return tostring(tonumber(s)) end
function D.header(code, control)
  local n=control=='tosnuc' and code:match('^%s*%$(%d+)%s*;?%s*$') or
    (control~='tosnuc' and code:match('^%s*O(%d+)%s*;?%s*$'))
  if n and #n<=8 then return n end
end
function D.call(code, control)
  code=code:gsub('^%s*N%d+%s*','')
  local n=control=='tosnuc' and code:match('^%s*G0*72%s*%$(%d+)%s*;?%s*$') or
    (control~='tosnuc' and code:match('^%s*M0*98%s*P(%d+)%s*;?%s*$'))
  if n and #n<=8 then return n end
end

-- Structural metadata is independent of geometry acceptance (including macros/cycles).
-- reader: the program reader profile.resolve picked ('haas' / 'tosnuc'), which adds
-- what those programs carry: Haas header rows, Toshiba T(...) lines, M06 and $name programs.
function D.structure(lines, control, reader)
  assert(D.names[control], 'An explicit supported controller is required')
  local source, issues, starts = require('gcode.profile').mask(lines)
  if reader then
    -- Haas/Toshiba comments close at the first ) or the end of the line (reader.mask)
    source, issues, starts = require('gcode.reader').mask(lines), {}, {}
    for i = 1, #lines do starts[i] = true end
  end
  local meta = { source={}, programs={}, labels={}, tools={}, issues=vim.tbl_map(U.issue,issues) }
  local in_tools, program, pending = false, nil, nil
  for i, line in ipairs(lines) do
    local code, top = source[i]:upper(), starts[i]
    if top and line:match('^%(T%-START%)') then in_tools=true end
    -- Mazak header rows (N6 - 1.0 FACE MILL  B90 P2 T10010001) declare the block's tool
    local row=control=='mazak-matrix' and top and require('gcode.mazak').header_row(line)
      or reader=='haas' and top and require('gcode.reader').header_row(line)
      or reader=='tosnuc' and require('gcode.reader').tool_line(line,source[i])
    if row and row.tool then meta.tools[#meta.tools+1]={kind='declaration',tool=row.tool,desc=row.name,line=i,text=line,program=program and program.line or 0} end
    if top and in_tools then
      local t,desc=line:match('^%((%d+)%s*;[^;]*;%s*(.-)%s*%)')
      if t then meta.tools[#meta.tools+1]={kind='declaration',tool=t,desc=desc,line=i,text=line,program=program and program.line or 0} end
      if line:match('^%(T%-END%)') then in_tools=false end
    end
    meta.source[i] = code
    local name = D.header(code, control)
    if control=='mazak-matrix' then name = name or code:match('^%s*(<[^<>]+>)%s*;?%s*$') end
    if control=='tosnuc' then name = name or code:match('^%s*%$(%d+Q)%s*;?%s*$') end
    if reader=='tosnuc' then name = name or code:match('^%s*%$(%w+)%s*;?%s*$') end
    if control=='okuma' then name = code:match('^%s*(O%w+)') or name end
    if name then
      if program then program.finish=i-1 end
      local display = code:match('^%s*([O%$][%w]+)') or name
      program = {name=display, line=i, finish=#lines, text=line}
      meta.programs[#meta.programs+1] = program
      pending = nil
    end
    local owner = program and program.line or 0
    local label = code:match(control=='okuma' and '^%s*N([%w]+)%f[^%w.]' or '^%s*N(%d+)%f[^%d.]')
    -- Haas copies saved back from the control write N01 for N1: one label either way
    if label and reader=='haas' then label=tostring(tonumber(label)) end
    if label then meta.labels[#meta.labels+1]={name='N'..label,line=i,text=line,program=owner} end
    local body=control=='okuma' and code or code:gsub('^%s*N%d+','')
    local words = Mo.is_nc(body) and Mo.words(body) or {}
    local t, q, change, first
    for _, w in ipairs(words) do
      if not w.expr and w.v:match('^%d+$') then
        if w.l=='T' then first=first or w.v; t=w.v elseif w.l=='Q' then q=w.v
        elseif (w.l=='M' and tonumber(w.v)==6 and (control~='tosnuc' or reader=='tosnuc'))
          or (w.l=='G' and tonumber(w.v)==116 and control=='okuma') then change=true end
      end
    end
    local function tool(kind, value)
      meta.tools[#meta.tools+1]={kind=kind,tool=value,line=i,text=line,program=owner}
    end
    if control=='mazak-matrix' and change and first then
      -- Mazak: T1 T11120001 M6 loads T1 and readies T11120001
      tool('select',first); tool('change',first); pending=nil
      if t~=first and tonumber(t)~=0 then pending=t; tool('select',t) end
      t, change=nil, nil
    end
    if t then pending=t; tool('select',t) end
    if change then tool('change',pending); pending=nil end
    if q and change and control=='okuma' then pending=q; tool('preload',q) end
  end
  return meta
end

-- Statefully masked source plus normalized, line-preserving input for the existing engine.
-- No changes to original text. Legacy OSP paths remain separate to preserve reviewed behavior.
function D.prepare(lines, control)
  assert(D.names[control] and control~='okuma','New-family interpretation requires an explicit supported control')
  local P = require('gcode.profile')
  local source, lexical = P.mask(lines)
  source=vim.tbl_map(string.upper,source)
  local out, issues, definitions, calls = {}, vim.tbl_map(U.issue,lexical), {}, {}
  local malformed,interpreted = {},{}
  local unit, absolute, plane, feedmode, motion, stopped, ended, first = nil,nil,nil,nil,nil,false,false,true
  local tool, main, labels, started = nil,true,{},false
  local lost, frame, cutter, length, rotation = false,nil,nil,nil,nil
  -- rotated: this program used G68. G69 only cancels rotation, so without G68 a fresh
  -- anchor does not need it (the usual Haas safe-start line has no G69).
  local rotated=false
  local strict=false
  local unit_assumed,feed_assumed=false,false
  local resets = {}
  local function flag(i, text, invalid)
    issues[#issues+1] = {line=i, text=(invalid and 'Invalid: ' or 'Unsupported: ')..text, invalid=invalid or false,kind=invalid and 'invalid' or 'unsupported',blocking=true}
  end
  for _,p in ipairs(lexical) do malformed[p.line]=true end
  for i, code in ipairs(source) do
    out[i] = ''
    if malformed[i] then stopped=true end
    local head = D.header(code,control)
    if head then
      if started and not ended and not stopped then flag(i,'program boundary before a recognized end/return') end
      local name = 'O'..id(head)
      if definitions[name] then flag(i,'duplicate program '..name,true) end
      definitions[name] = i
      main = first
      started=true
      out[i] = first and '' or name
      first, stopped, ended,labels = false,false,false,{}
      unit,absolute,plane,feedmode,motion,tool = nil,nil,nil,nil,nil,nil
      lost,frame,cutter,length,rotation = false,nil,nil,nil,nil
      rotated=false
      strict=false
      unit_assumed,feed_assumed=false,false
    elseif not ended and code:match('%S') and not code:match('^%s*%%%s*$') then
      interpreted[i]=true
      first=false
      started=true
      local label=code:match('^%s*N(%d+)')
      if label then
        label=id(label)
        if labels[label] then flag(i,'duplicate sequence N'..label,true) end
        labels[label]=true
      end
      -- Read structure even after geometry has stopped, for navigation/check diagnostics.
      local call = D.call(code,control)
      if call then calls[#calls+1] = {line=i, name='O'..id(call)} end
      if not stopped then
        local clean = code:gsub(';%s*$','')
        local parsed,bad=Mo.words(clean)
        local words,has,gs,ms={},{},{},{}
        if #bad>0 then flag(i,'block skip or unrecognized syntax'); stopped=true end
        for _,w in ipairs(parsed) do
          local l,n=w.l,tonumber(w.v)
          if not n or w.expr then flag(i,'expression or nonnumeric '..l..' operand'); stopped=true
          elseif n~=n or math.abs(n)==math.huge then flag(i,'nonfinite operand',true); stopped=true
          else
            if has[l] and l~='G' and l~='M' then flag(i,'duplicate address '..l,true); stopped=true end
            w.n=n; words[#words+1]=w; has[l]=n
            if l=='G' then gs[#gs+1]=n elseif l=='M' then ms[#ms+1]=n end
          end
        end
        local stop_after, dwell, returning = false,false,false
        if control=='tosnuc' and (vim.tbl_contains(gs,70) or vim.tbl_contains(gs,71)) then
          -- Manufacturer # restriction; starred G26/G27/G100 are exceptions, still unsupported here.
          for _,g in ipairs(gs) do
            if g~=70 and g~=71 and g~=26 and g~=27 and g~=100 then
              flag(i,'TOSNUC units cannot share a block with other non-starred G-codes',true)
              stopped=true; break
            end
          end
        end
        -- Haas-only verified state changes. Machine-coordinate motion is omitted.
        local machine_coords = control=='haas' and vim.tbl_contains(gs,53)
        if machine_coords then
          lost=true; strict=true
          unit,absolute,plane,feedmode,motion,frame,cutter,length,rotation=nil,nil,nil,nil,nil,nil,nil,nil,nil
          flag(i,'G53 machine-coordinate move omitted; fresh work-frame anchor required')
        end
        local groups = {}
        for _,g in ipairs(gs) do
          if math.floor(g)==68 then rotated=true end
          local group = (g<=3 and g>=0 and g%1==0) and 'motion'
            or ((g==90 or g==91) and 'distance') or ((g>=17 and g<=19) and 'plane')
            or ((g==94 or g==95) and 'feed')
          local inch, metric = control=='tosnuc' and 70 or 20, control=='tosnuc' and 71 or 21
          if g==inch or g==metric then group='units' end
          if group and groups[group] then flag(i,'multiple '..group..' selections',true); stopped=true end
          if group then groups[group]=true end
          if g==inch or g==metric then
            local next_unit=g==inch and 1 or 1/25.4
            if unit and unit~=next_unit then flag(i,'mid-program unit change'); stopped=true end
            unit=next_unit; unit_assumed=false
          elseif g==90 or g==91 then absolute=g
          elseif g==17 or g==18 or g==19 then plane=g
          elseif g==94 or g==95 then feedmode=g; feed_assumed=false
          elseif g>=0 and g<=3 and g%1==0 then motion=g
          elseif control=='haas' and (g==49 or g==69 or (g>=54 and g<=59 and g%1==0) or g==154 or g==53) then
            if g==49 then
              if not length then lost=true; strict=true; flag(i,'tool length cancellation; fresh anchor required') end
              length=true
            elseif g==69 then
              if not rotation then lost=true; strict=true; flag(i,'rotation cancellation; fresh anchor required') end
              rotation=true
            elseif g~=53 then
              local next_frame=g==154 and ('P'..tostring(has.P)) or tostring(g)
              if g==154 and (not has.P or has.P%1~=0 or has.P<1 or has.P>99) then
                flag(i,'G154 requires P1-P99'); stopped=true
              end
              if frame~=next_frame then
                lost=true; strict=true; flag(i,'work frame changed; fresh anchor required (offsets not modeled)')
              end
              frame=next_frame
            end
          elseif g==4 then dwell=true; flag(i,'dwell operand/time-base interpretation'); stopped=true
          elseif g==40 then cutter=true
          elseif g~=80 then flag(i,'G'..g..' interpretation'); stopped=true end
        end
        for _,m in ipairs(ms) do
          if m==98 and control~='tosnuc' then
            if not call or not has.P or has.P%1~=0 or has.P<0 or has.L or has.H or has.Q then
              flag(i,'M98 requires a plain P program number without repeat/entry arguments'); stopped=true
            elseif has.X or has.Y or has.Z or #gs>0 or #ms>1 then
              flag(i,'motion/modal words combined with M98'); stopped=true
            else
              -- ponytail: no cross-CALL modal propagation; stop the caller path after each call.
              flag(i,'state after M98 is not propagated; remaining caller geometry omitted')
              stop_after=true
            end
          elseif m==99 and control~='tosnuc' then
            if main then flag(i,'M99 in main program loops'); stopped=true end
            returning=true
            if has.P or has.L then flag(i,'M99 branch/repeat arguments'); stopped=true end
          elseif m==2 or m==30 then returning=true
          elseif m==6 and control~='tosnuc' then
            if not tool and not has.T then flag(i,'M06 without an identified tool'); stopped=true end
            if has.X or has.Y or has.Z or #gs>0 then flag(i,'motion/modal words combined with M06'); stopped=true end
          elseif m~=0 and m~=1 and m~=3 and m~=4 and m~=5 and m~=8 and m~=9 then
            flag(i,'M'..m..' machine-dependent behavior'); stopped=true
          end
        end
        for _,w in ipairs(words) do
          if not ('NGMXYZIJFSTP'):find(w.l,1,true) then flag(i,'address '..w.l); stopped=true end
          if w.l=='P' and not vim.tbl_contains(ms,98) and not (control=='haas' and vim.tbl_contains(gs,154)) and not dwell then flag(i,'P outside a supported call'); stopped=true end
          if (w.l=='S' or w.l=='T') and (w.n<0 or w.n%1~=0) then flag(i,w.l..' requires a nonnegative integer',true); stopped=true end
          if w.l=='F' and w.n<=0 then flag(i,'nonpositive feed',true); stopped=true end
          -- Decimal-less dimensional input is parameter/setting-dependent.
          if ('XYZIJF'):find(w.l,1,true) and not w.v:find('.',1,true) then
            flag(i,'decimal-less dimensional address '..w.l); stopped=true
          end
        end
        if returning and (has.X or has.Y or has.Z or #gs>0) then flag(i,'motion/modal words combined with program end'); stopped=true end
        if has.T then tool=tostring(has.T) end
        local axes=has.X or has.Y or has.Z
        if not strict then
          if not unit and (axes or has.F or has.I or has.J) then
            unit=1; unit_assumed=true; issues[#issues+1]={line=i,text='Assumed: inch units for explicit milling interpretation',assumed=true,invalid=false,kind='assumed',blocking=false}
          end
          if axes and motion and (motion~=0 or lost) and not feedmode then
            feedmode=94; feed_assumed=true; issues[#issues+1]={line=i,text='Assumed: G94 feed per minute for explicit milling interpretation',assumed=true,invalid=false,kind='assumed',blocking=false}
          end
        end
        if axes and not lost and (not unit or not absolute or not motion) then flag(i,'motion needs explicit units, G90/G91 and motion mode'); stopped=true end
        if axes and not lost and motion~=0 and not feedmode then flag(i,'cutting needs explicit G94/G95'); stopped=true end
        if axes and (motion==2 or motion==3) and (plane~=17 or not (has.I or has.J)) then
          flag(i,'only explicit G17 arcs with incremental I/J are modeled'); stopped=true
        end
        if (has.I or has.J) and not (axes and (motion==2 or motion==3)) then flag(i,'arc-only or center-only block'); stopped=true end
        local anchor = lost and not machine_coords and frame and cutter and length and (rotation or not rotated)
          and unit and absolute==90 and plane and feedmode and motion==0 and has.X and has.Y and has.Z
          and (not strict or not unit_assumed and not feed_assumed)
        if anchor then resets[i]=true; lost=false end
        if not stopped and not lost then
          if call then out[i]='CALL O'..id(call)
          elseif returning then out[i]='RTS'; ended=true
          else
            local normalized={}
            for _,w in ipairs(words) do
              if w.l=='G' and (common[w.n] or w.n==40 or w.n==80) then normalized[#normalized+1]='G'..w.n
              elseif ('XYZIJF'):find(w.l,1,true) then
                if not unit then flag(i,'dimensional value before units'); stopped=true
                else normalized[#normalized+1]=w.l..string.format('%.12f',w.n*unit) end
              elseif w.l=='S' or w.l=='N' then normalized[#normalized+1]=w.l..w.v end
            end
            if vim.tbl_contains(ms,6) then normalized[#normalized+1]='G116 T'..tool end
            if not stopped then out[i]=table.concat(normalized,' ') end
          end
          if stop_after then stopped=true end
        elseif not stopped and returning then
          -- The end is known even while the position is lost (waiting for a fresh anchor).
          out[i]='RTS'; ended=true
        end
      end
    end
  end
  if started and not ended and not stopped then flag(#lines,'program ends without a recognized end/return') end
  for _,call in ipairs(calls) do
    if not definitions[call.name] then flag(call.line,'external/missing subprogram '..call.name..' (not in this file)') end
  end
  local meta=D.structure(lines,control)
  meta.definitions,meta.calls,meta.resets=definitions,calls,resets
  meta.moves_omitted=false
  -- Only known motion discarded by preparation proves omission. Unknown constructs
  -- still block interpretation, without claiming that they would draw a move.
  -- Normalized headers supply family boundaries; source retains discarded motion.
  for _,sec in ipairs(Mo.sections(out,true)) do
    for _,move in ipairs(Mo.walk(source,sec,nil,{generic=true,masked=true,resets=resets})) do
      if interpreted[move.line] and out[move.line]=='' and move.kind~='home' then
        local words,bad=Mo.words(source[move.line])
        local known=#bad==0
        for _,w in ipairs(words) do
          local n=tonumber(w.v)
          if w.expr or not n or n~=n or math.abs(n)==math.huge then known=false end
          if w.l=='G' then
            local g=tonumber(w.v)
            if not (common[g] or Mo.CYCLES[g] or g==40 or g==49 or g==53 or g==80) then known=false end
          end
        end
        if known then meta.moves_omitted=true end
      end
    end
  end
  return out,vim.tbl_map(U.issue,issues),meta
end
return D
