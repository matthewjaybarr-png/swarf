-- safety.lua - automatic backups + :GcodeHealth
--
-- BACKUPS: the first time you save a program in a Neovim session, the copy that
-- was on disk BEFORE your save is kept in a backup folder on this computer.
-- The last 10 backups of each program are kept, per folder: Programs/O1234.MIN and
-- Finished/O1234.MIN each keep their own (the backup name carries a short code
-- for the full path). Backups made before that are named by file name only:
-- :Backups still lists them, marked, but nothing prunes or compares against them.
--   :Backups ........ list this program's backups (Enter opens one)
--   :CompareBackup .. side by side with the newest backup (:CompareOff closes)
--
-- :GcodeHealth ...... checks the setup on this computer (good first step if
--                     something isn't working for someone)
local U = require('gcode.util')
local cfg = require('gcode.config')

local function backup_dir()
  return cfg.backup_dir or (vim.fn.stdpath('data') .. '/swarf/backups')
end

-- O1234.MIN -> O1234.1a2b3c4d.2026-10-14_083000.MIN  (keeps the .MIN so it opens with colors)
local function stamped(name, stamp)
  local base, ext = name:match('^(.*)%.([^.]+)$')
  if not base then return name .. '.' .. stamp end
  return base .. '.' .. stamp .. '.' .. ext
end

-- 8 hex for the full path (Windows paths ignore case and slash direction)
local function key_of(path)
  local p = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  if vim.fn.has('win32') == 1 then p = p:lower() end
  return vim.fn.sha256(p):sub(1, 8)
end

-- backups of this path (key), or the old name-only ones (key nil)
local function backups_of(name, key)
  local dir = backup_dir()
  local list = {}
  if vim.fn.isdirectory(dir) == 0 then return list, dir end
  local want = stamped(name, (key and (key .. '.') or '') .. '\0'):gsub('[%-%.%[%]%(%)%%%+%*%?%^%$]', '%%%0')
    :gsub('%z', function() return '%d%d%d%d%-%d%d%-%d%d_%d%d%d%d%d%d' end)
  for f in vim.fs.dir(dir) do
    if f:match('^' .. want .. '$') then list[#list + 1] = f end
  end
  table.sort(list)                                  -- oldest first (the date sorts)
  return list, dir
end

local done = {}
vim.api.nvim_create_autocmd('BufWritePre', {
  callback = function(a)
    if vim.bo[a.buf].filetype ~= 'gcode' or done[a.buf] then return end
    local path = vim.api.nvim_buf_get_name(a.buf)
    if path == '' or vim.fn.filereadable(path) == 0 then return end
    done[a.buf] = true
    local ok = pcall(function()
      local dir = backup_dir()
      vim.fn.mkdir(dir, 'p')
      local name, key = vim.fn.fnamemodify(path, ':t'), key_of(path)
      local src = assert(io.open(path, 'rb'))
      local data = src:read('*a')
      src:close()
      local dst = assert(io.open(dir .. '/' .. stamped(name, key .. '.' .. os.date('%Y-%m-%d_%H%M%S')), 'wb'))
      dst:write(data)
      dst:close()
      local list = backups_of(name, key)
      for i = 1, #list - (cfg.backup_keep or 10) do os.remove(dir .. '/' .. list[i]) end
    end)
    if not ok then vim.notify('Backup before save did not work - the save still happens', vim.log.levels.WARN) end
  end,
})

vim.api.nvim_create_user_command('Backups', function()
  local path = vim.api.nvim_buf_get_name(0)
  local name = vim.fn.fnamemodify(path, ':t')
  local list, dir = backups_of(name, key_of(path))
  local old = backups_of(name)
  if #list + #old == 0 then return vim.notify('No backups of ' .. name .. ' yet (one is made the first time you save)') end
  local items = {}
  for _, set in ipairs({ { list, '' }, { old, '  (older backup by name only - may be another folder\'s ' .. name .. ')' } }) do
    for i = #set[1], 1, -1 do
      local f = set[1][i]
      local day, hh, mm = f:match('(%d%d%d%d%-%d%d%-%d%d)_(%d%d)(%d%d)%d%d')
      items[#items + 1] = { filename = dir .. '/' .. f, lnum = 1,
        text = 'saved over on ' .. day .. ' at ' .. hh .. ':' .. mm .. set[2] }
    end
  end
  vim.fn.setqflist({}, ' ', { title = 'Backups of ' .. name, items = items })
  vim.cmd('copen')
end, { desc = 'List backups of this program' })

vim.api.nvim_create_user_command('CompareBackup', function()
  local path = vim.api.nvim_buf_get_name(0)
  local name = vim.fn.fnamemodify(path, ':t')
  local list, dir = backups_of(name, key_of(path))
  if #list == 0 then
    return vim.notify('No backups of ' .. name .. ' from this folder yet'
      .. (#backups_of(name) > 0 and ' (older ones by name only: :Backups)' or ''))
  end
  vim.cmd('Compare ' .. vim.fn.fnameescape(dir .. '/' .. list[#list]))
end, { desc = 'Compare with the newest backup' })

-- ---------------------------------------------------------------------
vim.api.nvim_create_user_command('GcodeHealth', function()
  local out = { 'G-CODE SETUP CHECK (q closes)', '' }
  local function line(ok, what, detail)
    out[#out + 1] = string.format('  %s  %-22s %s', ok and 'OK ' or '!! ', what, detail or '')
  end
  local v = vim.version()
  line(v.major > 0 or v.minor >= 10, 'Neovim version', string.format('%d.%d.%d', v.major, v.minor, v.patch)
    .. ((v.major == 0 and v.minor < 10) and '  (0.10 or newer recommended)' or ''))
  local bad = vim.g.gcode_bad or {}
  line(#bad == 0, 'Command files', #bad == 0 and 'all loaded' or ('did not load: ' .. table.concat(bad, ', ')))
  line(vim.fn.filereadable(cfg.machines_file) == 1, 'Machines file', cfg.machines_file
    .. (vim.fn.filereadable(cfg.machines_file) == 1 and '' or '  (none yet - :Machines adds one)'))
  local ids = {}
  for _, m in ipairs(U.machines()) do ids[#ids + 1] = m.id .. '=' .. m.control end
  line(true, 'Machines', #ids > 0 and table.concat(ids, '  ') or 'none (use :Control per file, or :Machines)')
  local control = require('gcode.profile').context(0)
  line(control.mode == 'generic', 'Control (this file)', (control.label ~= '' and control.label or 'none selected')
    .. ' [' .. control.mode .. '] ' .. control.reason)
  line(true, 'Fast feed', U.fastf() or 'none')
  line(true, 'Backups', backup_dir())
  require('gcode.motion').report('GcodeHealth', out)
end, { desc = 'Check the G-code setup on this computer' })
