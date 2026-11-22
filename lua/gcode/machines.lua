-- machines.lua - :Machines keeps your own machine list (nothing ships with Swarf).
--   :Machines                         list them (first run: asks for one)
--   :Machines add 101 haas VF-2 rapid_ipm=1000 tc_seconds=6 fast_feed=200
--   :Machines remove 101
-- The list is a Lua file (config.machines_file) you may also edit by hand.
local C = require('gcode.config')
local M = {}
local KEYS = { rapid_ipm = true, tc_seconds = true, fast_feed = true }

function M.serialize(list)
  local ids = vim.tbl_keys(list)
  table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)
  local out = { '-- Swarf machines (:Machines writes this file)', 'return {' }
  for _, id in ipairs(ids) do
    local e, parts = list[id], {}
    for _, k in ipairs({ 'control', 'name', 'rapid_ipm', 'tc_seconds', 'fast_feed' }) do
      if e[k] ~= nil then parts[#parts + 1] = k .. ' = ' .. (type(e[k]) == 'string' and ('%q'):format(e[k]) or tostring(e[k])) end
    end
    out[#out + 1] = ("  ['%s'] = { %s },"):format(id, table.concat(parts, ', '))
  end
  out[#out + 1] = '}'
  return out
end

-- write the whole list; a temp file then rename, so a failed write never empties the old one
function M.save(list, file)
  file = file or C.machines_file
  vim.fn.mkdir(vim.fs.dirname(file), 'p')
  local tmp = file .. '.tmp'
  if vim.fn.writefile(M.serialize(list), tmp) ~= 0 then return nil, 'could not write ' .. tmp end
  local ok, err = os.rename(tmp, file)
  if not ok then return nil, err end
  return true
end

-- args after "add": { '101', 'haas', 'VF-2', 'rapid_ipm=1000' } -> id, entry | nil, problem
function M.parse(args)
  local id, control = args[1], args[2] and args[2]:lower()
  local e, name = { control = control }, {}
  for k = 3, #args do
    local key, v = args[k]:match('^(%w+_%w+)=(.*)$')
    if key and KEYS[key] then
      e[key] = tonumber(v)
      if not e[key] then return nil, key .. ' must be a number (not "' .. v .. '")' end
    else name[#name + 1] = args[k] end
  end
  if #name > 0 then e.name = table.concat(name, ' ') end
  local problem = C.check_machine(id or '', e)
  if problem then return nil, problem end
  return id, e
end

function M.add(id, e)
  local list = vim.deepcopy(C.machine_controls)
  list[id] = e
  local ok, err = M.save(list)
  if not ok then return nil, err end
  C.machine_controls[id] = e
  return true
end

function M.remove(id)
  if not C.machine_controls[id] then return nil, 'no machine ' .. id end
  local list = vim.deepcopy(C.machine_controls)
  list[id] = nil
  local ok, err = M.save(list)
  if not ok then return nil, err end
  C.machine_controls[id] = nil
  return true
end

local function list_text()
  local ids = vim.tbl_keys(C.machine_controls)
  if #ids == 0 then return 'No machines yet. :Machines add <number> <okuma|haas|tosnuc|mazak-matrix> [name]' end
  table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)
  local out = { 'Machines (' .. C.machines_file .. '):' }
  for _, id in ipairs(ids) do
    local e = C.machine_controls[id]
    out[#out + 1] = ('  %s  %s  %s'):format(id, e.control, e.name or '')
  end
  return table.concat(out, '\n')
end

-- first run: ask for one machine with prompts instead of making people learn the arguments
local function ask()
  vim.ui.input({ prompt = 'Machine number (2-4 digits, empty to skip): ' }, function(id)
    if not id or id == '' then return end
    vim.ui.select({ 'okuma', 'haas', 'tosnuc', 'mazak-matrix' }, { prompt = 'Control for ' .. id .. ':' }, function(control)
      if not control then return end
      vim.ui.input({ prompt = 'Name (optional): ' }, function(name)
        local args = { id, control }
        if name and name ~= '' then args[3] = name end
        local pid, e = M.parse(args)
        if not pid then return vim.notify('Machines: ' .. e, vim.log.levels.WARN) end
        local ok, err = M.add(pid, e)
        vim.notify(ok and ('Machines: added ' .. pid) or ('Machines: ' .. err), ok and nil or vim.log.levels.ERROR)
      end)
    end)
  end)
end

vim.api.nvim_create_user_command('Machines', function(o)
  local args = o.fargs
  if #args == 0 then
    vim.notify(list_text())
    if vim.tbl_isempty(C.machine_controls) then ask() end
    return
  end
  local verb = table.remove(args, 1)
  local ok, err
  if verb == 'add' then
    local id, e = M.parse(args)
    if not id then return vim.notify('Machines: ' .. e .. '; nothing saved', vim.log.levels.WARN) end
    ok, err = M.add(id, e)
  elseif verb == 'remove' then ok, err = M.remove(args[1] or '')
  else return vim.notify(':Machines [add <number> <control> [name] [rapid_ipm=n] [tc_seconds=n] [fast_feed=n] | remove <number>]', vim.log.levels.WARN) end
  if not ok then return vim.notify('Machines: ' .. err, vim.log.levels.WARN) end
  vim.notify(list_text())
end, { nargs = '*', complete = function(_, line)
  local n = #vim.split(line, '%s+', { trimempty = true })
  if n <= 1 then return { 'add', 'remove' } end
  if n == 3 and line:match('add') then return { 'okuma', 'haas', 'tosnuc', 'mazak-matrix' } end
  return {}
end, desc = 'Your machines: list, add, remove' })

return M
