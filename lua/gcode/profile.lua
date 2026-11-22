-- profile.lua - which controller language a buffer is read as. One answer for every command.
--   generic ..... :Control <name>, or the program is recognized (its own words, or one of
--                 your machines by number in the header comments or the folder name)
--   unknown ..... :Control unknown - no dialect analysis at all
--   unresolved .. nothing says which control: dialect commands refuse
-- Recognition may SUGGEST okuma (VC200, G116); only :Control or your machine list decides it.
local U = require('gcode.util')
local D = require('gcode.dialect')
local P = {}

P.names = { okuma = 'Okuma OSP', unknown = 'unknown control' }
for control,label in pairs(D.names) do P.names[control] = label end
P.limits = 'Supported controller subset only, not simulation. See CONTROLLERS.md for language, geometry and timing limits.'

-- Blank out (comments) and 'messages' instead of deleting them, so ignored text cannot join
-- tokens. Carry delimiter state across lines; unfinished text cannot authorize edits.
local function executable(line, depth, quote, lex)
  local out, unmatched = {}, false
  depth = depth or 0
  if depth==0 and not quote and not line:find("[()'\"]") then return line,0,nil,false end
  for i = 1, #line do
    local ch = line:sub(i, i)
    if lex and lex.regions then
      local kind=quote and 'message' or depth>0 and 'comment'
        or (ch=="'" or ch=='"') and 'message' or ch=='(' and 'comment'
      if kind then
        local last=lex.regions[#lex.regions]
        if last and last.kind==kind and last.e==i-1 then last.e=i
        else lex.regions[#lex.regions+1]={s=i,e=i,kind=kind} end
      end
    end
    if quote then
      if ch == quote then quote = nil end
      out[i] = ' '
    elseif depth > 0 then
      if ch == '(' then
        depth = depth + 1
        if lex then
          lex.issues[#lex.issues+1]=U.issue({line=lex.line,text='Invalid: "(" inside a comment',kind='invalid',blocking=true})
          if lex.nested then lex.nested[lex.issues[#lex.issues]]=lex.opening end
        end
      elseif ch == ')' then depth = depth - 1 end
      out[i] = ' '
    elseif ch == "'" or ch == '"' then
      quote, out[i] = ch, ' '
      if lex then lex.opening=lex.line end
    elseif ch == '(' then
      depth, out[i] = 1, ' '
      if lex then lex.opening=lex.line end
    else
      if ch == ')' then
        if lex and not unmatched then
          lex.issues[#lex.issues+1]=U.issue({line=lex.line,text='Invalid: unmatched closing comment',kind='invalid',blocking=true,invalid=true})
        end
        unmatched = true
      end
      out[i] = ch
    end
  end
  return table.concat(out), depth, quote, unmatched
end
P.executable = executable

-- Current editor subset for every supported family: carry ignored text across blocks.
-- starts marks lines beginning outside ignored text, for header annotations only.
function P.mask(lines, regions)
  local source, issues, starts, depth, quote = {}, {}, {}, 0, nil
  local lex={issues=issues,nested={}}
  for i,line in ipairs(lines) do
    if regions then regions[i]={}; lex.regions=regions[i] end
    lex.line=i; starts[i]=depth==0 and not quote
    source[i],depth,quote=executable(line,depth,quote,lex)
  end
  if quote then
    issues[#issues+1]=U.issue({line=lex.opening,text='Invalid: unclosed comment/message',kind='invalid',blocking=true,invalid=true})
  elseif depth>0 then
    -- a "(" never closed: every comment after it reads as nested in it. One note, on its line.
    local kept={}
    for _,p in ipairs(issues) do
      if not (lex.nested[p]==lex.opening and p.line>lex.opening) then kept[#kept+1]=p end
    end
    for i=#issues,1,-1 do issues[i]=nil end
    for i,p in ipairs(kept) do issues[i]=p end
    issues[#issues+1]=U.issue({line=lex.opening,text='Invalid: comment not closed - add )',kind='invalid',blocking=true,invalid=true})
  end
  return source, issues, starts
end

-- A single grammar is used by authorization and the timing path evaluator.
-- Input must already be masked with executable(). This grants no authority itself.

-- Okuma machine selectors (IF[VC200 EQ n] Nxxx). Read as generic Okuma syntax only.
function P.selector(code)
  return code:match('^%s*IF%s*%[%s*VC200%s*EQ%s*(%d+)%s*%]%s*N(%w+)%s*$')
end

function P.selectors(lines)
  local source, issues = P.mask(lines)
  local ids, problems = {}, {}
  for i, code in ipairs(source) do
    if code:find('%f[%w]VC200%f[^%w]') then
      local id = P.selector(code)
      if id then ids[#ids + 1] = id
      else issues[#issues+1]=U.issue({line=i,text='unsupported VC200 expression',kind='unsupported',blocking=true}) end
    end
  end
  for _,p in ipairs(issues) do problems[#problems+1]='Line '..p.line..': '..p.text end
  return ids, problems, issues
end

-- the folder a program is opened from, named for machine numbers (.../Machines/101-102)
-- -> { '101', '102' }, or nil. Nearest folder first; 2-4 digit numbers only (2026 is a year).
function P.folder(path)
  if not path or path == '' then return nil end
  local parts = vim.split((path:gsub('\\', '/')), '/', { plain = true })
  for k = #parts - 1, 1, -1 do
    local part = parts[k]:upper()
    if part:match('^[M#]?%d+[%s%-_,&/+M#%d]*$') then
      local nums = {}
      for n in part:gmatch('%d+') do
        if #n < 2 or #n > 4 then nums = nil break end
        nums[#nums + 1] = n
      end
      if nums and #nums > 0 then return nums end
    end
  end
end

-- lines + the explicit choice (nil / 'auto' / a control / 'unknown') + path (optional)
-- -> { mode, control, label, reason, reader, mazak, group, suggest }
-- reader = 'mazak' | 'haas' | 'tosnuc' picks that control's reader; Okuma has none.
-- Pure: never reads the current buffer.
function P.resolve(lines, explicit, path)
  local out = { machines = {}, problems = {}, control = 'unknown' }
  if explicit and explicit ~= 'auto' then
    if D.names[explicit] then
      out.control, out.mode = explicit, 'generic'
      out.label, out.reason = P.names[explicit], 'explicit :Control ' .. explicit
      if explicit == 'mazak-matrix' then out.reader, out.mazak = 'mazak', 'machining' end
      if explicit == 'haas' or explicit == 'tosnuc' then out.reader = explicit end
    else
      out.mode, out.label, out.reason = 'unknown', 'Unknown control', 'dialect analysis is off'
    end
    return out
  end
  out.mode, out.label, out.reason = 'unresolved', '', 'no control selected (:Control, or add the machine with :Machines)'
  local source = P.mask(lines)
  for _, code in ipairs(source) do
    if code:find('%f[%w]VC200%f[^%w]') or code:match('%f[%w]G116%f[%D]') then out.suggest = 'okuma' break end
  end
  local R = require('gcode.reader')
  local mazak = not out.suggest and require('gcode.mazak').identify(lines, source)
  local found = R.identify(lines, path)
  if found then
    out.control, out.mode, out.group = found.control, 'generic', found.machines
    out.reader = ({ ['mazak-matrix'] = 'mazak', haas = 'haas', tosnuc = 'tosnuc' })[found.control]
    if out.reader == 'mazak' then out.mazak = mazak and mazak.kind or 'machining' end
    out.label = R.label(found.control, found.machines)
    out.reason = 'recognized as ' .. P.names[found.control] .. ' by ' .. found.reason
  elseif mazak then
    out.control, out.mode, out.mazak, out.reader = 'mazak-matrix', 'generic', mazak.kind, 'mazak'
    out.label = mazak.kind == 'millturn' and 'Mazak mill-turn' or 'Mazak Matrix'
    out.reason = 'recognized as Mazak by ' .. mazak.reason
  end
  return out
end

-- cached on the buffer's changedtick: the statusline asks on every redraw
function P.context(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local explicit = vim.b[buf].gcode_control
  local c = vim.b[buf].gcode_ctx
  local tick, path = vim.api.nvim_buf_get_changedtick(buf), vim.api.nvim_buf_get_name(buf)
  if c and c.tick == tick and c.explicit == explicit and c.path == path then return c.value end
  local value = P.resolve(vim.api.nvim_buf_get_lines(buf, 0, -1, false), explicit, path)
  vim.b[buf].gcode_ctx = { tick = tick, explicit = explicit, path = path, value = value }
  return value
end

-- No preparation workflows ship with Swarf: nothing is "prepared" for a machine.
function P.can_edit(_) return false end
function P.can_prepare(_) return false end

-- Edits refuse when the program's comments/messages are not closed (they could hide code).
function P.edit(name)
  local compatible,reason=U.editable(vim.api.nvim_buf_get_lines(0,0,-1,false))
  if compatible then return true end
  vim.notify(':'..name..' refused: '..reason..'; nothing changed',vim.log.levels.WARN)
  return false
end

-- Okuma interpretation (motion, labels, edits) needs :Control okuma or a recognized program.
-- Backplot, Range, ArcCheck, K and navigation work on every supported control.
function P.interpret(name)
  local c = P.context(0)
  if c.mode == 'generic' then
    if c.control == 'okuma' or ({Backplot=true,Range=true,ArcCheck=true,K=true,Navigation=true})[name] then
      if ({Shift=true,Mirror=true,Rotate=true,StripComments=true,ORenumber=true})[name] then return P.edit(name) end
      return true
    end
    vim.notify(':'..name..' is not implemented for '..P.names[c.control]..'; nothing changed',vim.log.levels.WARN)
    return false
  end
  vim.notify(':' .. name .. ' needs to know the control (' .. c.reason
    .. ') - nothing done. :Control okuma (haas, tosnuc, mazak-matrix) sets it for this buffer.', vim.log.levels.WARN)
  return false
end

function P.describe(buf)
  local c = P.context(buf)
  local text = { c.label ~= '' and c.label or 'No control selected', c.reason }
  if c.mode == 'unresolved' and c.suggest then
    text[#text + 1] = 'looks like Okuma - suggestion only; :Control okuma to read it as Okuma'
  end
  for _, n in ipairs(require('gcode.reader').notes(c.group)) do text[#text + 1] = n end
  if c.mode == 'generic' then text[#text + 1] = P.limits end
  return table.concat(text, ' - ')
end

local choices = { 'okuma', 'haas', 'tosnuc', 'mazak-matrix', 'unknown', 'auto' }
vim.api.nvim_create_user_command('Control', function(o)
  local arg = o.args:lower()
  if arg == '' then return vim.notify('Control: ' .. P.describe(0)) end
  if arg == 'auto' then vim.b.gcode_control = nil
  elseif P.names[arg] then vim.b.gcode_control = arg
  else return vim.notify(':Control ' .. table.concat(choices, ' | ') .. '   (not "' .. o.args .. '")', vim.log.levels.WARN) end
  vim.api.nvim_exec_autocmds('User',{pattern='GcodeControlChanged',modeline=false})
  vim.notify('Control: ' .. P.describe(0))
end, { nargs = '?', complete = function() return choices end,
       desc = 'Select the controller language for this buffer' })

return P
