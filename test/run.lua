-- Swarf headless tests. Every program here is made up for the test.
local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then pass = pass + 1 else fail = fail + 1; print('FAIL ' .. name .. (detail and (': ' .. tostring(detail)) or '')) end
end
local notes = {}
vim.notify = function(msg) notes[#notes + 1] = tostring(msg) end

dofile(vim.fn.getcwd() .. '/gcode-init.lua')
check('every module loads', #vim.g.gcode_bad == 0, table.concat(vim.g.gcode_bad, ', '))
for _, c in ipairs({ 'Machines', 'Lint', 'Outline', 'Backplot', 'CycleTime', 'Control', 'ORenumber', 'Shift',
                     'Mirror', 'Rotate', 'StripComments', 'Compare', 'Range', 'ArcCheck', 'Speeds', 'GcodeHealth' }) do
  check(':' .. c .. ' exists', vim.fn.exists(':' .. c) == 2)
end

local C, Ma, P = require('gcode.config'), require('gcode.machines'), require('gcode.profile')
local O, B, L, A = require('gcode.outline'), require('gcode.backplot'), require('gcode.lint'), require('gcode.analysis')
check('no machines ship', vim.tbl_isempty(C.machine_controls))
check('machines file is in the test dir', C.machines_file:find(vim.env.XDG_CONFIG_HOME, 1, true) == 1, C.machines_file)

-- :Machines validation
check('bad number refused', not Ma.parse({ '1', 'haas' }))
check('bad control refused', not Ma.parse({ '101', 'fanuc' }))
check('bad value refused', not Ma.parse({ '101', 'haas', 'rapid_ipm=fast' }))
local id, e = Ma.parse({ '101', 'HAAS', 'VF', '2', 'rapid_ipm=1000', 'tc_seconds=6' })
check('good machine parses', id == '101' and e.control == 'haas' and e.name == 'VF 2' and e.rapid_ipm == 1000, vim.inspect(e))
check('add saves', Ma.add(id, e))
local back = dofile(C.machines_file)
check('file reads back', back['101'] and back['101'].tc_seconds == 6, vim.inspect(back))
check('file passes check_machine', C.check_machine('101', back['101']) == nil)

local haas = {
  '%', 'O01000 (TEST PART)', '(MACH #101)', '(T1 1/2 END MILL)',
  'N1 (FACE)', 'T1 M06', 'G00 G90 G54 X0. Y0. S2000 M03', 'G43 H01 Z1.',
  'G01 Z-.1 F20.', 'X2.', 'G02 X3. Y1. I0. J1.', 'G01 Y3.', 'G00 Z1.',
  'N2 (DRILL)', 'T2 M06', 'G00 G90 G54 X1. Y1. S1500 M03', 'G43 H02 Z1.',
  'G81 G98 Z-.5 R.1 F10.', 'X2.', 'G80', 'G00 Z1.', 'M30', '%',
}
local r = P.resolve(haas, nil, '/tmp/x.nc')
check('recognized by machine number', r.mode == 'generic' and r.control == 'haas', vim.inspect(r))
check('unknown machine is unresolved', P.resolve({ 'O1 (MACH #999)', 'G0 X1.', 'M30' }).mode == 'unresolved')
check('folder recognition', P.resolve({ 'G0 X1.', 'M30' }, nil, '/progs/101/O1.nc').control == 'haas')

local o = O.build(haas, 'haas')
check('outline finds 2 ops', #o.ops == 2, vim.inspect(o.ops))
local d = B.build(haas, nil, 'haas')
check('backplot draws', d and #d.secs > 0, d and vim.inspect(d.issues))
local lint = L.run(haas, 'haas')
check('lint runs', type(lint) == 'table')
local t = A.estimate(haas, nil, 'haas', '/progs/101/O1.nc')
check('cycle time has a run time', t and (t.run or 0) > 0, t and vim.inspect(t.issues))
local bad = vim.list_slice(haas); bad[11] = 'G02 X3. Y1. R.5'
local arcs = A.arc_problems(bad, 'haas')
check('arccheck flags a wrong R', type(arcs) == 'table' and #arcs > 0, vim.inspect(arcs))

check('remove machine', Ma.remove('101') and dofile(C.machines_file)['101'] == nil)

-- lint on an unclosed comment, no control
local l2 = L.run({ 'G0 X1. (OPEN', 'M30' })
check('lint flags an unclosed comment', #l2 > 0 and l2[1].text:find('not closed'), vim.inspect(l2))

-- edits: Okuma only, and never when nothing says which control
local okuma = { 'G15 H1', 'G0 X0 Y0 Z1.', 'G1 X1. Y2. F10.', 'G0 Z1.', 'M02' }
vim.api.nvim_buf_set_lines(0, 0, -1, false, okuma)
vim.b.gcode_control = nil
vim.cmd('%Shift X1.')
check('Shift refuses with no control', vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), okuma))
vim.b.gcode_control = 'okuma'
vim.cmd('%Shift X1.')
local after = vim.api.nvim_buf_get_lines(0, 0, -1, false)
check('Shift moves X', after[3]:find('X2%.') ~= nil, vim.inspect(after) .. notes[#notes])
vim.b.gcode_control = 'haas'
vim.api.nvim_buf_set_lines(0, 0, -1, false, okuma)
vim.cmd('%Shift X1.')
check('Shift refuses on haas', vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), okuma))

-- every command runs without a Lua error on a Haas and an Okuma buffer
local main = vim.api.nvim_get_current_buf()
vim.ui.input = function(_, cb) cb(nil) end
for _, setup in ipairs({ { 'haas', haas }, { 'okuma', okuma } }) do
  vim.api.nvim_set_current_buf(main)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, setup[2])
  vim.b.gcode_control = setup[1]
  for _, c in ipairs({ 'Control', 'Outline', 'Lint', 'CycleTime', 'Range', 'ArcCheck', 'Speeds', 'GcodeHealth',
                       'Machines', '%Mirror X', '%Rotate 90', '%StripComments', 'ORenumber' }) do
    local ok, err = pcall(vim.cmd, c)
    check(setup[1] .. ' :' .. c .. ' runs', ok, err)
    pcall(vim.cmd, 'cclose'); pcall(vim.cmd, 'silent! only'); vim.api.nvim_set_current_buf(main)
    vim.b.gcode_control = setup[1]
    vim.api.nvim_buf_set_lines(0, 0, -1, false, setup[2])
  end
end

print(('%d passed, %d failed'):format(pass, fail))
vim.cmd(fail == 0 and 'qa!' or 'cq!')
