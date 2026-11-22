-- =====================================================================
-- config.lua - Swarf settings. No machines are built in.
-- Your machines live in your own file (:Machines writes it), by default
--     ~/.config/nvim/swarf/machines.lua   (vim.g.swarf_machines changes the path)
-- Other settings: vim.g.gcode = { fast_feed = 200, arc_tol = .001 } in your init.lua.
-- =====================================================================
local C = {
  -- a "fast feed" your posts use for air moves; :Speeds leaves moves at this feed out.
  -- nil = none. A machine may set its own (machines.lua fast_feed).
  fast_feed = nil,
  old_fast_feeds = {},

  -- arc endpoint tolerance for Backplot / ArcCheck (inch or mm, whatever the program uses)
  arc_tol = .0005,

  -- :CycleTime fallbacks when a machine has no rapid_ipm / tc_seconds of its own
  rapid_ipm = nil,          -- estimated 1000 when nil
  tc_seconds = nil,         -- estimated 8 when nil
  approach_seconds = nil,   -- estimated 2 when nil; false leaves those rapids unknown

  -- :FindAll searches these files in the program's folder
  find_glob = '*',

  -- your machines, by number: { ['101'] = { control = 'haas', name = 'VF-2' } } (machines.lua)
  machine_controls = {},
}

C.controls = { okuma = true, haas = true, tosnuc = true, ['mazak-matrix'] = true }
C.machines_file = vim.g.swarf_machines or (vim.fn.stdpath('config') .. '/swarf/machines.lua')

local function merge(settings)
  for k, v in pairs(settings) do
    if k == 'machine_controls' then
      assert(type(v) == 'table', 'machine_controls must be a table')
      for id, entry in pairs(v) do C.machine_controls[tostring(id)] = entry or nil end
    else C[k] = v end
  end
end

-- check one machine entry -> nil, or the problem in words (:Machines uses this too)
function C.check_machine(id, e)
  if not tostring(id):match('^%d%d%d?%d?$') then return 'machine numbers are 2-4 digits (not "' .. tostring(id) .. '")' end
  if type(e) ~= 'table' or not C.controls[e.control] then return 'control must be okuma, haas, tosnuc or mazak-matrix' end
  if e.name ~= nil and type(e.name) ~= 'string' then return 'name must be text' end
  for _, key in ipairs({ 'rapid_ipm', 'fast_feed' }) do
    if e[key] ~= nil and not (type(e[key]) == 'number' and e[key] > 0) then return key .. ' must be a positive number' end
  end
  if e.tc_seconds ~= nil and not (type(e.tc_seconds) == 'number' and e.tc_seconds >= 0) then
    return 'tc_seconds must be 0 or more'
  end
end

if vim.fn.filereadable(C.machines_file) == 1 then
  local ok, list = pcall(dofile, C.machines_file)
  if ok and type(list) == 'table' then merge({ machine_controls = list })
  else vim.notify('Swarf: could not read ' .. C.machines_file .. ' (' .. tostring(list) .. ')', vim.log.levels.WARN) end
end
merge(vim.g.gcode or {})

for id, e in pairs(C.machine_controls) do
  if type(e) == 'string' then e = { control = e }; C.machine_controls[id] = e end
  local problem = C.check_machine(id, e)
  if problem then
    vim.notify('Swarf: machine ' .. id .. ' skipped: ' .. problem, vim.log.levels.WARN)
    C.machine_controls[id] = nil
  end
end
assert(C.fast_feed == nil or (type(C.fast_feed) == 'number' and C.fast_feed > 0), 'fast_feed must be positive')
return C
