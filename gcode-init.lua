-- =====================================================================
-- Swarf - a G-code editor setup for Neovim.
--   Load it from your own init.lua:  dofile('/path/to/swarf/gcode-init.lua')
-- Every command lives in its own file in lua/gcode/. To add a feature, drop a
-- new file there and add it to the list at the bottom. Settings: lua/gcode/config.lua
-- =====================================================================

-- find the lua/gcode files next to this file
local here = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/'):match('^(.*)/[^/]*$') or '.'
vim.opt.rtp:prepend(here)
vim.g.gcode_shared = here
vim.g.mapleader = ' '          -- Space is the leader key (Space w = save)

local opt = vim.opt
opt.number = true              -- line numbers
opt.wrap = false               -- long G-code lines don't wrap
opt.expandtab = false          -- leave tabs alone
opt.tabstop = 4
opt.shiftwidth = 4
opt.ignorecase = true          -- searches ignore case...
opt.smartcase = true           -- ...unless you type a capital
opt.incsearch = true
opt.hlsearch = true
opt.scrolloff = 5
opt.sidescrolloff = 10
opt.list = true
opt.listchars = { tab = '>-', trail = '.', extends = '>', precedes = '<' }
opt.colorcolumn = ''
opt.cursorline = true          -- shows which line you're on
opt.clipboard = 'unnamedplus'  -- copy/paste uses the system clipboard

-- no backup/swap clutter next to programs
opt.backup = false
opt.swapfile = false
opt.undofile = true
local data = vim.fn.stdpath('data') .. '/swarf'
opt.undodir = data .. '/undo'
vim.fn.mkdir(data .. '/undo', 'p')
opt.termguicolors = true

-- ---------------------------------------------------------------------
-- reposting from CAM: the open program reloads instead of a new copy
-- ---------------------------------------------------------------------
opt.autoread = true            -- file changed on disk and not edited here -> reload it
opt.title = true
opt.titlestring = 'Swarf - %t'
vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter', 'CursorHold' }, {
  callback = function()
    if vim.fn.mode() ~= 'c' and vim.fn.getcmdwintype() == '' then pcall(vim.cmd, 'checktime') end
  end,
})
vim.api.nvim_create_autocmd('FileChangedShellPost', {
  callback = function(a)
    vim.notify('Reloaded ' .. vim.fn.fnamemodify(a.file, ':t') .. ' - it changed on disk')
  end,
})

vim.keymap.set('n', '<leader>w', ':w<CR>', { desc = 'Save' })
vim.keymap.set('n', '<leader>q', ':q<CR>', { desc = 'Quit' })
vim.keymap.set('n', '<Esc>', ':nohlsearch<CR><Esc>', { silent = true, desc = 'Clear search highlight' })

-- each command file loads on its own - one broken file doesn't take out the rest
local modules = {
  'gcode.highlight',       -- colors
  'gcode.profile',         -- :Control okuma / haas / tosnuc / mazak-matrix / unknown / auto
  'gcode.machines',        -- :Machines (your machines: number, name, control)
  'gcode.nav',             -- ]n ]t ]s gd :Compare :Changes :FindAll :CopySub :CopyBlock
  'gcode.renumber',        -- :ORenumber
  'gcode.analysis',        -- :Range :CycleTime :ArcCheck
  'gcode.lint',            -- :Lint
  'gcode.transform',       -- :Shift :Mirror :Rotate :StripComments
  'gcode.hints',           -- K = what is this code?   :Speeds
  'gcode.backplot',        -- :Backplot
  'gcode.ui',                -- :Outline, the action bar
  'gcode.safety',          -- backups before save, :Backups :CompareBackup :GcodeHealth
}
local bad, badnames = {}, {}
for _, m in ipairs(modules) do
  local ok, err = pcall(require, m)
  if not ok then bad[#bad + 1] = m .. ': ' .. tostring(err); badnames[#badnames + 1] = m end
end
vim.g.gcode_bad = badnames
if #bad > 0 then
  vim.notify('Swarf - these did not load:\n' .. table.concat(bad, '\n'), vim.log.levels.WARN)
end

vim.cmd('filetype on')
vim.cmd('syntax on')
