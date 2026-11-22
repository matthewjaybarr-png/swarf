-- outline.lua - programs, N blocks, tool changes and operations for :Outline and the
-- ]n ]t ]s gd jumps. Built from dialect.structure; reads the program, never changes it.
-- Each label/tool/op names its program by index into programs (0 = before the first one).
local U = require('gcode.util')
local D = require('gcode.dialect')
local P = require('gcode.profile')
local O = {}

-- no control selected: every non-blank line is a place to jump to, nothing is interpreted
function O.source(lines, reason)
  local labels = {}
  for i, line in ipairs(lines) do
    if line:match('%S') then labels[#labels + 1] = { line = i, label = vim.trim(line), program = 0 } end
  end
  return { source_only = true, reason = reason, programs = {}, labels = labels, tools = {}, ops = {}, issues = {} }
end

-- the comment on a line, if any: N10 T5 M6 (5/8 END MILL) -> '5/8 END MILL'
local function comment(text)
  local c = text and text:match('%(([^()]*)%)')
  return c and c:match('%S') and vim.trim(c) or nil
end

function O.build(lines, explicit, path)
  local c = P.resolve(lines, explicit, path)
  assert(c.mode == 'generic', 'O.build needs a known control')
  local m = D.structure(lines, c.control, c.reader)
  local out = { control = c.control, mode = c.mode, mazak = c.mazak, reader = c.reader,
    programs = {}, labels = {}, tools = {}, ops = {}, issues = m.issues, incomplete = #m.issues > 0 }
  -- an Okuma main program often has no O line: what comes before the first O is MAIN
  local first = m.programs[1]
  if c.control == 'okuma' and (not first or first.line > 1) then
    local stop = first and first.line - 1 or #lines
    for i = 1, stop do
      if (m.source[i] or ''):match('%S') then
        out.programs[1] = { name = 'MAIN', line = i, end_line = stop, kind = 'main' }
        break
      end
    end
  end
  local index = {}
  for _, p in ipairs(m.programs) do
    out.programs[#out.programs + 1] = { name = p.name, line = p.line, end_line = p.finish,
      kind = #out.programs == 0 and 'main' or 'sub' }
  end
  local function owner(line)
    if index[line] then return index[line] end
    local k = 0
    for i, p in ipairs(out.programs) do if p.line <= line then k = i end end
    index[line] = k
    return k
  end
  for _, l in ipairs(m.labels) do
    out.labels[#out.labels + 1] = { line = l.line, label = l.name, program = owner(l.line) }
  end
  local declared = {}
  for _, t in ipairs(m.tools) do
    if t.kind == 'declaration' then declared[t.tool] = declared[t.tool] or t.desc end
  end
  for _, t in ipairs(m.tools) do
    out.tools[#out.tools + 1] = { t = t.tool, line = t.line, program = owner(t.line),
      desc = t.desc or declared[t.tool] or comment(t.text), event = t.kind }
  end
  -- one operation per N block that changes a tool or says what it does in a comment
  local claimed = {}
  for k, l in ipairs(out.labels) do
    local stop = (out.labels[k + 1] and out.labels[k + 1].line or #lines + 1) - 1
    local change
    for _, t in ipairs(out.tools) do
      if t.event == 'change' and t.line >= l.line and t.line <= stop and not change then change = t end
    end
    local desc = change and change.desc or comment(lines[l.line])
    if change or desc then
      if change then claimed[change] = true end
      out.ops[#out.ops + 1] = { line = l.line, label = l.label, desc = desc, tool = change and change.t,
        program = l.program, kind = change and 'tool' or 'block', hs = {} }
    end
  end
  for _, t in ipairs(out.tools) do
    if t.event == 'change' and not claimed[t] then
      out.ops[#out.ops + 1] = { line = t.line, desc = t.desc, tool = t.t, program = t.program, kind = 'Tool change', hs = {} }
    end
  end
  table.sort(out.ops, function(a, b) return a.line < b.line end)
  out.issues = U.issues(out.issues)
  return out
end

return O
