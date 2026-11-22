-- util.lua - small helpers shared by the commands
local U = {}

-- One conservative contract at result boundaries; wording never grants authority.
function U.issue(value)
  local p = type(value)=='table' and vim.tbl_extend('force',{},value) or {text=value}
  local classified = p.kind=='assumed' or p.kind=='unsupported' or p.kind=='invalid'
  if type(p.text)~='string' or p.text=='' then
    p.text, classified = 'Unclassified issue', false
  end
  if not classified then p.kind, p.blocking = 'unsupported', true end
  if type(p.blocking)~='boolean' or p.kind=='invalid' then p.blocking=true end
  if p.line~=nil and (type(p.line)~='number' or p.line~=p.line or p.line==math.huge or p.line<1 or p.line%1~=0) then
    p.line, p.blocking = nil, true
  end
  if p.kind=='assumed' and p.blocking then p.kind='unsupported' end
  return p
end

-- How Lint notes show at the end of a line: one '!' and how many
-- notes the line has, then the most serious one. A '!' per note pushed the text off
-- the screen on a line with dozens of notes.
function U.note_display()
  return {
    virtual_text = { spacing = 2, prefix = function(_, i, total)
      if i < total then return '' end
      return total > 1 and ('! [' .. total .. ' notes]') or '!'
    end },
    signs = true, underline = true, severity_sort = true,
  }
end

-- Stable location order, including program-wide findings, shared by every report.
function U.issues(values)
  local ordered={}
  for i,value in ipairs(values or {}) do ordered[i]={issue=U.issue(value),index=i} end
  table.sort(ordered,function(a,b)
    local x,y=a.issue.line or 0,b.issue.line or 0
    return x==y and a.index<b.index or x<y
  end)
  return vim.tbl_map(function(p) return p.issue end,ordered)
end

-- Legacy editors cannot reconstruct preceding-line delimiter state. Refuse before mutation.
function U.legacy_compatible(lines)
  local source,issues=require('gcode.profile').mask(lines)
  if #issues>0 then return false,'Line '..issues[1].line..': '..issues[1].text end
  for i,line in ipairs(lines) do
    if U.code_of(line):gsub('%s','')~=source[i]:gsub('%s','') then
      return false,'Line '..i..': comment/message syntax is not supported by this edit; source preserved'
    end
  end
  return true
end

-- Migrated editors require a complete, unambiguous source; closed messages are data.
function U.editable(lines)
  local _,issues=require('gcode.profile').mask(lines)
  if #issues>0 then return false,'Line '..issues[1].line..': '..issues[1].text end
  return true
end

-- Reading a closing-line suffix is not evidence that a control executes it.
function U.preparation_input(lines)
  local ok,reason=U.editable(lines)
  if not ok then return false,reason end
  local regions={}
  local source,_,starts=require('gcode.profile').mask(lines,regions)
  for i,spans in ipairs(regions) do
    if not starts[i] and spans[1] and spans[1].kind=='comment' and source[i]:find('%S') then
      return false,'Line '..i..': executable text on a multiline comment closing line is unverified; source preserved'
    end
  end
  return true
end

-- Check a retained block against its own original ignored tail, never another block.
-- Regions must come from the whole-source mask, including continuation state.
function U.preparation_line_preserved(line, regions, replacement)
  local first=regions[1]
  if not first or line==replacement then return true end
  local tail=line:sub(first.s)
  local prefix=replacement:sub(1,#replacement-#tail)
  return replacement:sub(-#tail)==tail and not prefix:find("[()'\"]")
end

-- Aggregate backstop; StockProbe also checks each rewritten source block.
-- ponytail: exact suffix comparison can refuse harmless formatting; relax only with controller evidence.
function U.preparation_suffixes_preserved(before, after)
  local function suffixes(lines)
    local regions,out={},{}
    local source=require('gcode.profile').mask(lines,regions)
    for i,spans in ipairs(regions) do
      local first=spans[1]
      if first and source[i]:sub(first.s):find('%S') then
        local tail=lines[i]:sub(first.s)
        out[tail]=(out[tail] or 0)+1
      end
    end
    return out
  end
  return vim.deep_equal(suffixes(before),suffixes(after))
end

-- Match in the position-preserving mask, replace only that executable source span.
-- Matches spanning ignored text are left alone, including whitespace inside payloads.
function U.gsub(line, code, pattern, replacement, limit)
  local out, pos, count = {}, 1, 0
  while not limit or count<limit do
    local match={code:find(pattern,pos)}
    local a,b=match[1],match[2]
    if not a then break end
    assert(b>=a,'Executable replacements must consume source')
    out[#out+1]=line:sub(pos,a-1)
    local raw=line:sub(a,b)
    if raw==code:sub(a,b) then
      local captures={unpack(match,3)}
      local value
      if type(replacement)=='function' then
        value=replacement(unpack(#captures>0 and captures or {raw}))
      else
        value=replacement:gsub('%%([%%0-9])',function(k)
          if k=='%' then return '%' end
          return k=='0' and raw or tostring(captures[tonumber(k)] or '')
        end)
      end
      out[#out+1]=(value==nil or value==false) and raw or tostring(value)
      count=count+1
    else out[#out+1]=raw end
    pos=b+1
  end
  out[#out+1]=line:sub(pos)
  return table.concat(out),count
end

-- Whole-block rewrites retain ignored spans in their original order.
function U.replace_code(line, code, replacement)
  local payload=U.gsub(line,code,'%S+','')
  return replacement .. (payload:find('%S') and (' '..payload) or '')
end

function U.code_of(l) return (l:match('^([^(]*)')) end
function U.trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end
function U.tc(l) return U.trim(U.code_of(l)) end

-- Match text as data: no Ex command parser sees patterns or file names.
-- nil files searches the current buffer, including unsaved edits.
function U.search_list(pattern, files, title)
  local items = {}
  local function scan(lines, file)
    for i, line in ipairs(lines) do
      local col = vim.fn.match(line, pattern)
      if col >= 0 then
        local item = {lnum=i, col=col+1, text=line}
        if file then item.filename=file else item.bufnr=vim.api.nvim_get_current_buf() end
        items[#items+1]=item
      end
    end
  end
  if files then
    for _, file in ipairs(files) do
      if vim.fn.filereadable(file)==1 then scan(vim.fn.readfile(file), file) end
    end
  else scan(vim.api.nvim_buf_get_lines(0,0,-1,false)) end
  vim.fn.setqflist({}, ' ', {title=title, items=items})
  if #items==0 then return vim.notify('Nothing found: '..title) end
  vim.cmd('copen')
end

-- index of the first subprogram header (O0001, OPB01...)
function U.first_sub(lines)
  for i, l in ipairs(lines) do if l:match('^%s*O%w') then return i end end
  return #lines + 1
end

-- your machines (config machine_controls, written by :Machines), sorted by number:
-- { id = '101', name = 'VF-2', control = 'haas', rapid_ipm = ..., tc_seconds = ..., fast_feed = ... }
function U.machines()
  local out = {}
  for id, e in pairs(require('gcode.config').machine_controls or {}) do
    out[#out + 1] = vim.tbl_extend('force', e, { id = id, name = e.name or id })
  end
  table.sort(out, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
  return out
end

-- the fast feed word from your settings: fast_feed = 200 -> 'F200.', or nil when none is set
function U.fastf()
  local v = tonumber(require('gcode.config').fast_feed)
  return v and ('F' .. (v == math.floor(v) and string.format('%d.', v) or tostring(v))) or nil
end

-- Okuma subs that live on the control, not in the file: OPB.., O7/O8/O9...
function U.is_external_sub(name)
  return name:match('^OPB') ~= nil or name:match('^O[789]') ~= nil
end

-- Posted numeric CALLs handled locally; subs on the control stay external.
function U.is_internal_sub(name)
  return name:match('^O%d+$') ~= nil and not U.is_external_sub(name)
end

-- rewrite the header (N... list after renumbering
-- queues[old] = list of new labels, used in order (handles duplicates)
function U.update_header(queues, lines)
  local buffer = lines == nil
  lines = lines or vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local compatible,reason=U.editable(lines)
  if not compatible then return 0,reason end
  local source,_,starts=require('gcode.profile').mask(lines)
  local changed = 0
  for i, line in ipairs(lines) do
    if source[i]:match('^%s*N%w') then break end
    local label,gap,rest
    if starts[i] then label,gap,rest=line:match('^%(N(%w+)(%s*)%-(.*)$') end
    if label and queues[label] and #queues[label] > 0 then
      local new=table.remove(queues[label],1)
      lines[i] = '(N' .. new .. string.rep(' ',math.max(1,#gap+#label-#new)) .. '-' .. rest
      changed = changed + 1
    end
  end
  if buffer then vim.api.nvim_buf_set_lines(0, 0, -1, false, lines) end
  return changed
end

function U.is_unproven_stop(line, code, regions)
  if not code then
    local spans={}
    code=require('gcode.profile').mask({line},spans)[1]
    regions=spans[1]
  end
  local stop=U.trim(code)
  if stop~='M0' and stop~='M00' then return false end
  for _,span in ipairs(regions or {}) do
    if span.kind=='comment' and line:sub(span.s,span.e):upper():find('UNPROVEN',1,true) then return true end
  end
  return false
end

-- Metadata may read comments, but quoted messages never supply annotations.
function U.annotations(lines)
  local regions={}
  local source=require('gcode.profile').mask(lines,regions)
  for i,spans in ipairs(regions) do
    for _,r in ipairs(spans) do
      if r.kind=='comment' then
        source[i]=source[i]:sub(1,r.s-1)..lines[i]:sub(r.s,r.e)..source[i]:sub(r.e+1)
      end
    end
  end
  return source
end

-- Independent final guard: edits must retain the exact ordered message fragments.
function U.messages_preserved(before, after)
  local function messages(lines)
    local regions,out={},{}
    require('gcode.profile').mask(lines,regions)
    for i,spans in ipairs(regions) do
      for _,r in ipairs(spans) do if r.kind=='message' then out[#out+1]=lines[i]:sub(r.s,r.e) end end
    end
    return out
  end
  return vim.deep_equal(messages(before),messages(after))
end

-- Preparation may edit single-line metadata; multiline comments must stay exact.
-- This also catches code prefixed/appended/inserted inside a continuation.
function U.multiline_comments_preserved(before, after)
  local function comments(lines)
    local regions,out,active={},{},nil
    require('gcode.profile').mask(lines,regions)
    for i,spans in ipairs(regions) do
      for _,r in ipairs(spans) do if r.kind=='comment' then
        local text=lines[i]:sub(r.s,r.e)
        active=active or {}
        active[#active+1]=text
        if text:sub(-1)==')' then
          if #active>1 then out[#out+1]=table.concat(active,'\n') end
          active=nil
        end
      end end
    end
    if active then out[#out+1]=table.concat(active,'\n') end
    return out
  end
  return vim.deep_equal(comments(before),comments(after))
end

function U.proven(lines)
  local regions={}
  local source,issues,starts=require('gcode.profile').mask(lines,regions)
  if #issues>0 then return 'unknown' end
  local date, stop
  for i, l in ipairs(lines) do
    local d = l:upper():match('^%s*%(PROVEN%s+(%d%d%-%d%d%-%d+)')
    if starts[i] and d and not d:match('^00%-00%-0+$') then date = d end
    if U.is_unproven_stop(l,source[i],regions[i]) then stop=true end
  end
  return stop and 'unproven' or (date and 'proven' or 'unmarked'), date
end

-- mask: how the program's comments are read (profile.mask for Okuma, family.mask)
function U.swap_feed(lines, old, new, first, last, mask)
  assert(type(old) == 'number' and old > 0 and type(new) == 'number' and new > 0, 'Feeds must be positive')
  local word = 'F' .. (new == math.floor(new) and string.format('%d.', new) or tostring(new))
  local source,issues=(mask or require('gcode.profile').mask)(lines)
  if #issues>0 then return 0,'Refused: Line '..issues[1].line..': '..issues[1].text end
  local n = 0
  for i=first or 1,last or #source do
    local code=source[i]
    local replacements={}
    for pos,v,last in code:gmatch('()%f[%w]F([%+%-]?%d*%.?%d*)()') do
      if tonumber(v)==old then replacements[#replacements+1]={pos,last} end
    end
    for j=#replacements,1,-1 do
      local r=replacements[j]
      lines[i]=lines[i]:sub(1,r[1]-1)..word..lines[i]:sub(r[2])
      n=n+1
    end
  end
  return n
end

return U
