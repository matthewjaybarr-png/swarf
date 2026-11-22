-- highlight.lua - extra colors so things stand out while scrolling
-- Sits on top of syntax/gcode.vim (does not replace it). Change any color here.
local C = {
  GcBlock  = { fg = '#ffffff', bg = '#1f3a5f', bold = true },  -- N1 (T119 ...)  block start bar
  GcSub    = { fg = '#ffffff', bg = '#2e5a2e', bold = true },  -- O0001 (...)     sub start bar
  GcTool   = { fg = '#ffd75f', bold = true },                  -- G116 T119       tool change
  GcStop   = { fg = '#ffffff', bg = '#8b0000', bold = true },  -- M0 / M00        operator stop
  GcJump   = { fg = '#d787ff', bold = true },                  -- GOTO NALM1 / ] NFX1 / labels
  GcVar    = { fg = '#5fd7d7' },                               -- VC43  VC[VACOD]
  GcDanger = { fg = '#ffffff', bg = '#af0000', bold = true },  -- G00 ... Z-  rapid below zero
  GcEnd    = { fg = '#bcbcbc', bold = true },                  -- RTS  M02  M30
  GcXY     = { fg = '#b5dcb5' },                               -- X Y I J K  (soft green)
  GcZ      = { fg = '#7ccd7c' },                               -- Z          (deeper green)
}
for name, spec in pairs(C) do vim.api.nvim_set_hl(0, name, spec) end

-- Okuma file types -> gcode (so syntax/gcode.vim and these colors apply)
vim.filetype.add({ extension = {
  MIN = 'gcode', min = 'gcode', SSB = 'gcode', ssb = 'gcode',
  SDF = 'gcode', sdf = 'gcode', SUB = 'gcode', sub = 'gcode',
  LIB = 'gcode', lib = 'gcode',
} })

-- Every machine family shows the same kinds of things in its own words: block and
-- program bars, tool changes, stops, jumps and labels, variables, rapids below Z0,
-- ends, X Y / Z values; canned cycles, sub calls and IF/WHILE are syntax (below).
-- Okuma's set is the original one.
local okuma = {
  { 'GcBlock',  [=[^N\(\d\+\|PRB\?\d\+\)\>.*]=],                      5 },
  { 'GcSub',    [=[^O\w\+.*]=],                                        5 },
  { 'GcTool',   [=[\<G116\s*T\d\+]=],                                  10 },
  { 'GcStop',   [=[^\s*M0\{1,2}\>.*]=],                                10 },
  { 'GcJump',   [=[\<GOTO\s*N\w\+\|\]\s*N\w\+\|^N\(ALM\|END\|FX\|PCHK\|STRT\|WR\|ST\|PRB\d\)\w*\s*$]=], 10 },
  { 'GcVar',    [=[\<VC\d\+\>\|\<VC\[\w\+\]]=],                        10 },
  { 'GcDanger', [=[\<G0\?0\>[^(]*\<Z-]=],                              20 },
  { 'GcEnd',    [=[^\s*\(RTS\|M0\?2\|M30\)\>]=],                       10 },
  { 'GcXY',     [=[\%(^\|[^A-Z]\)\@<=[XYIJK]\%(-\?[0-9.]\+\|=[^ (]\+\)]=], 4 },
  { 'GcZ',      [=[\%(^\|[^A-Z]\)\@<=Z\%(-\?[0-9.]\+\|=[^ (]\+\)]=],       4 },
}

-- Mazak, Haas and Toshiba words can be packed (G0G28G91Z0.M9): a word starts
-- wherever no letter is right before it. Nothing inside a (comment) is colored.
local code = [=[\%(([^)]*\)\@<!\a\@<!]=]
local value = [=[\%(-\?[0-9.]\+\|-\?#\d\+\|-\?\[[^]]*\]\)]=]
local line = [=[^\s*\%(N\d\+\s*\)\?]=] -- start of a line, after its sequence number
local onum = [=[^\s*O\d\{1,8}\s*;\?\s*\%((.*)\s*\)\=$]=] -- O1234 (NAME)
local function words(f)
  local out = {
    { 'GcBlock',  [=[^\s*N\d\+\s*(.*]=],                    5 },  -- N1 (FACE MILL)
    { 'GcSub',    f.header,                                 5 },
    { 'GcStop',   line .. [=[M0\{1,2}\d\@!.*]=],            10 },
    { 'GcJump',   code .. [=[GOTO\s*\d\+\|^\s*N\d\+\s*$]=], 10 },  -- GOTO1000, a bare N label
    { 'GcVar',    code .. f.units .. [=[\d\@!]=],           10 },  -- inch/metric
    { 'GcDanger', code .. [=[G0\?0\d\@![^(]*\a\@<!Z-]=],    20 },
    { 'GcEnd',    line .. f.ends .. [=[\d\@!]=],            10 },
    { 'GcXY',     code .. '[XYIJK]' .. value,               4 },
    { 'GcZ',      code .. 'Z' .. value,                     4 },
  }
  -- T1 T11120001 M6, T8.1T45M6, M06 (Toshiba tool changes are not verified)
  if f.tool then out[#out + 1] = { 'GcTool', code .. [=[\%(T[0-9.]\+\s*\)\{0,2}M0\?6\d\@!]=], 10 } end
  if f.vars then out[#out + 1] = { 'GcVar', code .. [=[#\%(\d\+\|\ze\[\)]=], 10 } end -- #790, #[#1+2]
  return out
end
local fanuc = { units = 'G2[01]', ends = [=[\%(M0\?2\|M30\|M99\)]=], tool = true, vars = true }
local F = {
  okuma = { matches = okuma, syntax = [[
syntax match gcodeDrillCycle "\<G73\>\|\<G8[123]\>"
syntax match gcodeTapCycle "\<G74\%(\.\d\+\)\?\>\|\<G84\%(\.\d\+\)\?\>\|\<G284\%(\.\d\+\)\?\>"
syntax match gcodeBoreCycle "\<G76\%(\.\d\+\)\?\>\|\<G8[56789]\>"
syntax match gcodeSubCall "\<CALL\>\|\<RTS\>"
syntax match gcodeConditional "\<IF\>\|\<THEN\>\|\<ELSE\>\|\<ENDIF\>"
]] },
  ['mazak-matrix'] = { matches = words(vim.tbl_extend('force', fanuc, { header = onum .. [=[\|^\s*<[^<>]\+>.*]=] })), syntax = [[
syntax match gcodeDrillCycle "\a\@<!G\%(73\|8[123]\)\d\@!"
syntax match gcodeTapCycle "\a\@<!G[78]4\%(\.\d\+\)\?\d\@!"
syntax match gcodeBoreCycle "\a\@<!G\%(76\|8[5-9]\)\d\@!"
syntax match gcodeSubCall "\a\@<!\%(M9[89]\|G6[56]\)\d\@!"
syntax match gcodeConditional "\<IF\>\|\<THEN\>\|\<WHILE\>\|\<DO\d\>\|\<END\d\>"
]] },
  haas = { matches = words(vim.tbl_extend('force', fanuc, { header = onum })), syntax = [[
syntax match gcodeDrillCycle "\a\@<!G\%(73\|8[123]\)\d\@!"
syntax match gcodeTapCycle "\a\@<!G[78]4\%(\.\d\+\)\?\d\@!"
syntax match gcodeBoreCycle "\a\@<!G\%(7[67]\|8[5-9]\)\d\@!"
syntax match gcodeSubCall "\a\@<!\%(M9[789]\|G65\)\d\@!"
syntax match gcodeConditional "\<IF\>\|\<THEN\>\|\<WHILE\>\|\<DO\d\>\|\<END\d\>"
]] },
  -- TOSNUC: $1234 programs, G72 $ calls, G70/G71 units; G73 is positioning, not a cycle
  tosnuc = { matches = words({ units = 'G7[01]', ends = [=[\%(M0\?2\|M30\)]=],
    header = [=[^\s*\$\d\+Q\?\s*;\?\s*\%((.*)\s*\)\=$]=] }), syntax = [[
syntax match gcodeDrillCycle "\a\@<!G8[123]\d\@!"
syntax match gcodeTapCycle "\a\@<!G84\d\@!"
syntax match gcodeBoreCycle "\a\@<!G8[5-9]\d\@!"
syntax match gcodeSubCall "\a\@<!G72\d\@!"
]] },
}
local styles = [[
highlight default gcodeDrillCycle guifg=#CE9178 gui=bold
highlight default gcodeTapCycle guifg=#4FC1FF gui=bold
highlight default gcodeBoreCycle guifg=#C792EA gui=bold
highlight default gcodeSubCall guifg=#FFCB6B gui=bold
highlight default gcodeConditional guifg=#F92672 gui=bold
]]

-- An Okuma sub or library (a sub or library file) names no machine, so it is not read as Okuma;
-- it still gets Okuma's colors when its words are plainly Okuma's. Colors only.
local function okuma_words(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = vim.b[buf].gc_okuma_words
  if c and c[1] == tick then return c[2] end
  local found = false
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, math.min(3000, vim.api.nvim_buf_line_count(buf)), false)) do
    l = l:gsub('%b()', ''):upper()
    if l:find('%f[%w]VC%[?%w') or l:find('%f[%w]CALL%s*O%w') or l:find('^%s*RTS%f[%W]')
      or l:find('%f[%w]G116%f[%D]') or l:find('^%s*O%u[%u%d]*%f[%W]') then found = true break end
  end
  vim.b[buf].gc_okuma_words = { tick, found }
  return found
end

local function family(buf)
  local c = require('gcode.profile').context(buf)
  if F[c.control] then return c.control end
  if c.mode == 'unresolved' and (c.suggest == 'okuma' or okuma_words(buf)) then return 'okuma' end
  return 'unknown'
end

local function apply()
  for _, id in ipairs(vim.w.gc_ids or {}) do pcall(vim.fn.matchdelete, id) end
  local ids = {}
  if vim.bo.filetype == 'gcode' then
    local fam = family(0)
    if vim.b.gc_syntax_control ~= fam then
      vim.cmd('silent! syntax clear gcodeDrillCycle gcodeTapCycle gcodeBoreCycle gcodeSubCall gcodeConditional')
      if F[fam] then vim.cmd(F[fam].syntax .. styles) end
      vim.b.gc_syntax_control = fam
    end
    for _, m in ipairs(F[fam] and F[fam].matches or {}) do ids[#ids + 1] = vim.fn.matchadd(m[1], m[2], m[3]) end
  end
  vim.w.gc_ids = ids
end

-- typing: the family is read again once the typing stops (it reads the whole program)
local timer
local function later()
  local win = vim.api.nvim_get_current_win()
  timer = timer or vim.uv.new_timer()
  timer:stop()
  timer:start(300, 0, vim.schedule_wrap(function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_call(win, apply) end
  end))
end

vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter', 'FileType' }, { callback = apply })
vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { callback = later })
vim.api.nvim_create_autocmd('User',{pattern='GcodeControlChanged',callback=apply})
-- colorschemes reset highlight groups - put ours back
vim.api.nvim_create_autocmd('ColorScheme', {
  callback = function() for name, spec in pairs(C) do vim.api.nvim_set_hl(0, name, spec) end end,
})

return { apply = apply }
