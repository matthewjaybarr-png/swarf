-- nav.lua - jumping around, comparing, searching other files, copying
local U = require('gcode.util')
local cfg = require('gcode.config')

local map = vim.keymap.set
local D = require('gcode.dialect')
local P = require('gcode.profile')
-- One outline per buffer and changedtick: ]n [n ]t [t ]s [s gd only read it, and a
-- rebuild per keypress took 165 ms on a 3,300-line program.
local built={}
vim.api.nvim_create_autocmd('BufWipeout',{callback=function(a) built[a.buf]=nil end})
local function family_source()
  local buf=vim.api.nvim_get_current_buf()
  local tick,explicit=vim.api.nvim_buf_get_changedtick(buf),vim.b[buf].gcode_control
  local hit=built[buf]
  if hit and hit.tick==tick and hit.explicit==explicit then return hit.meta,hit.control,hit.lines end
  local c=P.context(buf)
  local lines=vim.api.nvim_buf_get_lines(buf,0,-1,false)
  local meta,control
  if c.mode~='generic' then meta=require('gcode.outline').source(lines,c.reason)
  else meta,control=require('gcode.outline').build(lines,explicit,vim.api.nvim_buf_get_name(buf)),c.control end
  built[buf]={tick=tick,explicit=explicit,meta=meta,control=control,lines=lines}
  return meta,control,lines
end

-- the cached lines come back unchanged until an edit, so their mask can be kept with them
local masked=setmetatable({},{__mode='k'})
local function code_at(lines,row)
  masked[lines]=masked[lines] or P.mask(lines)
  return masked[lines][row]:upper()
end
local function target_line(meta,name)
  if not name then return end
  for _,p in ipairs(meta.programs) do
    if p.name:match('^[O%$]0*(%d+)$') and tonumber(p.name:sub(2))==tonumber(name) then return p.line end
    if p.name==name then return p.line end
  end
end

-- ]n [n  next/prev N block      ]t [t  next/prev tool change      ]s [s  next/prev sub
local function jump(back, kind)
  return function()
    local meta,_,lines=family_source()
    if not meta then return end
    local row=vim.api.nvim_win_get_cursor(0)[1]
    local candidates={}
    for _,p in ipairs(kind=='sub' and meta.programs or kind=='block' and meta.labels or meta.tools) do
      if kind~='tool' or p.event=='change' then candidates[p.line]=true end
    end
    for i=row+(back and -1 or 1),back and 1 or #lines,back and -1 or 1 do
      if candidates[i] then
        vim.cmd("normal! m'"); vim.api.nvim_win_set_cursor(0,{i,0}); return
      end
    end
  end
end
map('n', ']n', jump(false,'block'), {desc='Next N block'})
map('n', '[n', jump(true,'block'), {desc='Prev N block'})
map('n', ']t', jump(false,'tool'), {desc='Next tool change'})
map('n', '[t', jump(true,'tool'), {desc='Prev tool change'})
map('n', ']s', jump(false,'sub'), {desc='Next program/sub'})
map('n', '[s', jump(true,'sub'), {desc='Prev program/sub'})

-- gd  -> go to whatever is under the cursor:
--   on a CALL O0005 line / an O0005 word  -> that sub
--   on NALM2 / NEND / NWR3 / NST1 (a jump) -> that label
-- Ctrl-o comes back.
map('n', 'gd', function()
  local meta,control,lines=family_source()
  if not meta then return end
  if meta.source_only then return vim.notify(meta.reason..'; select a supported control for interpreted targets') end
  local row=vim.api.nvim_win_get_cursor(0)[1]
  local code=code_at(lines,row)
  local target
  if control=='okuma' then
    local word=vim.fn.expand('<cword>')
    -- NE/NOT/OR inside IF[...] are operators, not labels or subs
    local operator=word=='NE' or word=='NOT' or word=='OR'
    -- the target follows the whole balanced IF[...]: IF[ABS[PA] NE 1]NP04 jumps to NP04, not NE
    target=(word:match('^[ON]%w+$') and not operator and code:find(word,1,true) and word)
      or code:match('CALL%s+(O%w+)') or code:match('GOTO%s*(N%w+)') or code:match('IF%s*%b[]%s*(N%w+)')
  else target=D.call(code,control) or D.header(code,control) end
  local at=target_line(meta,target)
  if not at then
    -- OSP GOTO/IF jumps stay inside their own program/sub: its label wins over an earlier one.
    local here
    for i,p in ipairs(meta.programs) do if p.line<=row then here=i end end
    for _,l in ipairs(meta.labels) do if l.label==target and l.program==here then at=l.line; break end end
    if not at then for _,l in ipairs(meta.labels) do if l.label==target then at=l.line; break end end end
  end
  if at then
    vim.cmd("normal! m'"); vim.api.nvim_win_set_cursor(0,{at,0}); return
  end
  vim.notify('No resolved program/label target here (a sub stored on the control?)')
end, { desc = 'Go to the sub / label under the cursor' })

-- :Compare ../old/O1234.MIN  -> side-by-side differences (Tab completes the path)
--   ]c [c next/prev difference    do = take theirs    dp = give mine    :CompareOff to close
vim.api.nvim_create_user_command('Compare', function(o)
  vim.g.gc_home_win = vim.api.nvim_get_current_win()
  vim.cmd('vert diffsplit ' .. vim.fn.fnameescape(o.args))
end, { nargs = 1, complete = 'file', desc = 'Compare with another program' })

-- :Changes  -> what you changed since the last save, side by side
vim.api.nvim_create_user_command('Changes', function()
  local ft = vim.bo.filetype
  vim.g.gc_home_win = vim.api.nvim_get_current_win()
  vim.cmd('diffthis')
  vim.cmd('vert new')
  vim.bo.buftype, vim.bo.bufhidden, vim.bo.swapfile = 'nofile', 'wipe', false
  vim.cmd('read ++edit #')
  vim.cmd('0delete _')
  vim.bo.filetype = ft
  vim.bo.modifiable = false
  vim.cmd('diffthis')
  vim.cmd('wincmd p')
end, { desc = 'Compare with the saved file' })

vim.api.nvim_create_user_command('CompareOff', function()
  local w = vim.g.gc_home_win
  if w and vim.api.nvim_win_is_valid(w) then vim.api.nvim_set_current_win(w) end
  vim.cmd('diffoff!')
  vim.cmd('only')
end, { desc = 'Close the compare' })

-- :FindAll T321   :FindAll VC44 *.MIN  -> every program in this folder that uses it
--   Enter on a line opens that program at that spot.   :cnext / :cprev step through.
vim.api.nvim_create_user_command('FindAll', function(o)
  local pat = o.fargs[1]
  if not pat or #o.fargs>2 then return vim.notify('Usage: :FindAll T321  [*.MIN]') end
  local glob = o.fargs[2] or cfg.find_glob
  if type(glob)~='string' or glob=='' or not glob:match('^[%w_%.%*%?%[%]%-]*$') then
    return vim.notify('FindAll: use a nonempty filename glob containing only letters, digits, _, ., *, ?, [, ], -')
  end
  local dir = vim.fn.expand('%:p:h')
  local rx = pat:match('^[%w_]+$') and ('\\<' .. pat .. '\\>') or ('\\V' .. vim.fn.escape(pat, '\\'))
  U.search_list(rx, vim.fn.globpath(dir, glob, false, true), 'FindAll '..pat)
end, { nargs = '+', desc = 'Search every program in this folder' })

-- copy pieces to the Windows clipboard (paste anywhere with Ctrl-v, or p in Neovim)
local function copy(a, b, what)
  local lines = vim.api.nvim_buf_get_lines(0, a - 1, b, false)
  vim.fn.setreg('+', table.concat(lines, '\n') .. '\n', 'l')
  vim.fn.setreg('"', table.concat(lines, '\n') .. '\n', 'l')
  vim.notify('Copied ' .. what .. ' (' .. #lines .. ' lines)')
end

-- :CopySub  -> the sub the cursor is in (or the one on this CALL line), header to RTS
vim.api.nvim_create_user_command('CopySub', function(o)
  local meta,control,lines=family_source()
  if meta==false then return end
  if meta and meta.source_only then return vim.notify(meta.reason..'; select a supported control for CopySub') end
  if meta then
    local row=vim.api.nvim_win_get_cursor(0)[1]
    local argument=control=='okuma' and o.args:upper():match('^O%w+$') or o.args:upper():match(control=='tosnuc' and '^%$?(%d+)$' or '^O?(%d+)$')
    if o.args~='' and not argument then return vim.notify('Use a numeric local program name') end
    local code=code_at(lines,row)
    local target=argument or (control=='okuma' and code:match('CALL%s+(O%w+)') or D.call(code,control))
    local s=target_line(meta,target)
    if not target then
      for _,p in ipairs(meta.programs) do if p.line<=row then s=p.line end end
    end
    if not s then return vim.notify('No local program/subprogram selected') end
    local e=#lines
    for _,p in ipairs(meta.programs) do if p.line==s then e=p.end_line; break end end
    local source=P.mask(lines)
    for i=1,e do
      local code=source[i]:upper()
      if i>s and (control=='okuma' and code:match('^%s*RTS%s*$') or control~='tosnuc' and code:match('^%s*M0*99%s*;?%s*$')) then e=i; break end
    end
    return copy(s,e,'program/subprogram')
  end
end, { nargs = '?', desc = 'Copy a whole sub' })

-- :CopyBlock  -> the N block the cursor is in
vim.api.nvim_create_user_command('CopyBlock', function()
  local meta,_,lines=family_source()
  if not meta then return end
  if meta.source_only then return vim.notify(meta.reason..'; select a supported control for CopyBlock') end
  local row=vim.api.nvim_win_get_cursor(0)[1]
  local selected,finish
  for i,l in ipairs(meta.labels) do
    if l.line<=row then selected=l; finish=meta.labels[i+1] and meta.labels[i+1].line-1 or #lines end
  end
  if not selected then return vim.notify('Not in an N block') end
  local p=selected.program and meta.programs[selected.program]
  if p then finish=math.min(finish,p.end_line) end
  if row>finish then return vim.notify('Not in an N block') end
  while finish>selected.line and U.trim(lines[finish])=='' do finish=finish-1 end
  copy(selected.line,finish,selected.label)
end, { desc = 'Copy the N block' })
