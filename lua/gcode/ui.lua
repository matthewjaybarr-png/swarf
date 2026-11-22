local U = require('gcode.util')
local UI = {}
local actions = {'write', 'Lint', 'Outline', 'Backplot', 'CycleTime', 'Control', 'Settings'}
function _G.SwarfClick(index)
  local win=vim.fn.getmousepos().winid
  if not vim.api.nvim_win_is_valid(win) then return end
  vim.api.nvim_set_current_win(win)
  vim.cmd(actions[index])
end
-- per buffer: the last status and the changedtick/line it was read at (redraws outnumber both)
local shown = {}
function UI.status()
  local context=require('gcode.profile').context(0)
  if context.mode~='generic' then return ' '..context.label..' | '..context.reason..' ' end
  local buf, row = vim.api.nvim_get_current_buf(), vim.fn.line('.')
  local tick, control = vim.api.nvim_buf_get_changedtick(buf), context.label .. (context.why and (' - ' .. context.why) or '')
  local last = shown[buf]
  if last and last.tick == tick and last.row == row and last.control == control then return last.text end
  local tool, block, sub, h = '-', '-', 'MAIN', '-'
  -- Only the cursor's own program/sub, back to its O line: a sub does not run with
  -- MAIN's last tool and fixture, and the rest of the file need not be read.
  local lines = vim.api.nvim_buf_get_lines(0, 0, row, false)
  local codes = {}
  for i = row, 1, -1 do
    codes[#codes + 1] = U.tc(lines[i])
    if codes[#codes]:match('^O%w+') then break end
  end
  for k = #codes, 1, -1 do
    local c = codes[k]
    tool = c:match('G116%s+T(%d+)') or tool
    block = c:match('^N(%w+)') or block
    sub = c:match('^(O%w+)') or sub
    h = c:match('G15%s*H(%d+)') or h
  end
  local text = string.format(' T%s | N%s | %s | H%s ', tool, block, sub, h) .. (control ~= '' and ('| ' .. control .. ' ') or '')
  shown[buf] = { tick = tick, row = row, control = control, text = text }
  return text
end
_G.SwarfStatus = UI.status
-- Rendering uses source identities from the public metadata, never label-only lookup.
function UI.outline(meta, context)
  local text,rows={},{}
  local issues=U.issues(meta.issues)
  local function add(value,line) text[#text+1]=value; rows[#rows+1]=line or false end
  add('Outline — '..(context.label or meta.control or 'unidentified'))
  add(meta.source_only and ('Source navigation: '..(meta.reason or context.reason)) or 'Enter: source  q: close')
  if meta.incomplete or vim.iter(issues):any(function(p) return p.blocking end) then
    add('Partial navigation: source issues limit interpretation.')
  end
  for _,issue in ipairs(issues) do
    if not issue.line then add('  ! Program: '..issue.text) end
  end
  local entries,claimed={},{}
  local function entry(line,rank,render)
    entries[#entries+1]={line=line,rank=rank,render=render,index=#entries+1}
  end
  for _,p in ipairs(meta.programs) do
    entry(p.line,1,function() add(p.name..' ['..p.kind..']',p.line) end)
  end
  local function operation(op)
    local unresolved=op.probe_unresolved or false
    for _,call in ipairs(op.probe_calls or {}) do unresolved=unresolved or call.unresolved end
    for _,issue in ipairs(issues) do
      if issue.line==op.line then unresolved=true end
    end
    entry(op.line,2,function() add('  '..(op.label or op.kind or 'Operation')..' '..(op.tool and 'T'..op.tool or '[tool unknown]')
      ..(op.desc and (' '..op.desc) or ' [description unknown]')
      ..(unresolved and (#(op.probe_calls or {})>0 and ' [targets unverified]' or ' [unresolved]') or ''),op.line) end)
    local function detail(value,line,anchor)
      entry(anchor or line,4,function() add(value,line) end)
    end
    if #(op.hs or {})>0 then detail('    Fixtures: '..table.concat(op.hs,', '),op.line) end
    for _,call in ipairs(op.probe_calls or {}) do
      detail('    '..call.call..' — line '..call.line,call.line)
      local active=call.active
      detail('      Active fixture: '..(active and active.h or 'unknown')
        ..(active and (' ('..active.provenance..', line '..active.line..')') or ''),active and active.line or call.line,call.line)
      for _,a in ipairs(call.annotations or {}) do
        local value=a.valid and table.concat(a.values,', ') or (a.text=='' and 'not supplied' or 'unresolved: '..a.text)
        detail('      Annotated targets: '..value..' ('..a.provenance..', line '..a.line..')',a.line,call.line)
      end
    end
    for _,a in ipairs(op.probe_annotations or {}) do
      detail('    Annotated targets: '..(a.valid and table.concat(a.values,', ') or 'unknown')..' [unverified]',a.line,op.line)
    end
  end
  for _,l in ipairs(meta.labels) do
    local match
    for i,op in ipairs(meta.ops) do
      if not claimed[i] and op.line==l.line and op.program==l.program and op.label==l.label then match=i; break end
    end
    if match then
      claimed[match]=true; local op=meta.ops[match]
      operation(op)
    else entry(l.line,2,function() add('  '..l.label..(meta.source_only and '' or ' [navigation]'),l.line) end) end
  end
  for i,op in ipairs(meta.ops) do if not claimed[i] then operation(op) end end
  for _,t in ipairs(meta.tools) do
    if t.event=='change' then entry(t.line,3,function()
      add('    Tool change '..(t.t and 'T'..t.t or '[unknown]')..(t.desc and (' '..t.desc) or ''),t.line)
    end) end
  end
  for _,issue in ipairs(issues) do
    if issue.line then entry(issue.line,4,function()
      add('  ! Line '..issue.line..': '..issue.text,issue.line)
    end) end
  end
  table.sort(entries,function(a,b)
    if a.line~=b.line then return a.line<b.line end
    return a.rank==b.rank and a.index<b.index or a.rank<b.rank
  end)
  for _,e in ipairs(entries) do e.render() end
  return text,rows
end

vim.api.nvim_create_user_command('Outline', function()
  local source = vim.api.nvim_get_current_buf()
  local source_win = vim.api.nvim_get_current_win()
  local lines = vim.api.nvim_buf_get_lines(source, 0, -1, false)
  local context=require('gcode.profile').context(source)
  local O=require('gcode.outline')
  local meta=context.mode=='generic'
    and O.build(lines,vim.b[source].gcode_control,vim.api.nvim_buf_get_name(source)) or O.source(lines,context.reason)
  local text,rows=UI.outline(meta,context)
  vim.cmd('topleft vnew')
  local b = vim.api.nvim_get_current_buf()
  vim.bo[b].buftype = 'nofile'; vim.bo[b].bufhidden = 'wipe'; vim.bo[b].swapfile = false
  vim.api.nvim_buf_set_lines(b, 0, -1, false, text)
  vim.bo[b].modifiable = false
  vim.wo.wrap=true; vim.wo.linebreak=true
  vim.cmd('vertical resize 44')
  vim.keymap.set('n', '<CR>', function()
    local row = rows[vim.fn.line('.')]
    if not row then return end
    if not vim.api.nvim_buf_is_valid(source) or not vim.api.nvim_buf_is_loaded(source) then
      return vim.notify('Outline source is closed; reopen the source and run Outline again',vim.log.levels.WARN)
    end
    if not vim.api.nvim_win_is_valid(source_win) then
      return vim.notify('Outline source window is closed',vim.log.levels.WARN)
    end
    if row<1 or row>vim.api.nvim_buf_line_count(source) then
      return vim.notify('Outline source location is out of bounds; run Outline again',vim.log.levels.WARN)
    end
    vim.api.nvim_set_current_win(source_win)
    vim.api.nvim_win_set_buf(source_win, source)
    vim.api.nvim_win_set_cursor(source_win, {row, 0})
  end, {buffer=b})
  vim.keymap.set('n', 'q', function()
    if #vim.api.nvim_tabpage_list_wins(0)>1 then vim.cmd.close() else vim.cmd.enew() end
  end, {buffer=b,nowait=true})
end, {})
vim.api.nvim_create_user_command('Settings', function()
  vim.cmd.edit(vim.fn.fnameescape(vim.fn.stdpath('config') .. '/init.lua'))
end, {})
local bar = {}
for i, action in ipairs(actions) do
  bar[#bar + 1] = '%' .. i .. '@v:lua.SwarfClick@ ' .. (action == 'write' and 'Save' or action) .. ' %T'
end
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'gcode', callback = function()
    vim.wo.winbar = table.concat(bar, '|')
    vim.wo.statusline = '%f %m%=%{v:lua.SwarfStatus()} %l:%c '
  end,
})
vim.opt.mouse = 'a'
vim.opt.mousemodel = 'popup_setpos'
vim.cmd('silent! aunmenu PopUp')
for _, action in ipairs(actions) do
  vim.cmd('amenu PopUp.' .. (action == 'write' and 'Save' or action) .. ' <Cmd>' .. action .. '<CR>')
end
return UI
