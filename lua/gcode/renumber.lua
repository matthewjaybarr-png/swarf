-- renumber.lua - :ORenumber: renumber the O programs defined in this file and their direct CALLs.
local U = require('gcode.util')
-- Build every replacement from original masked positions, then commit once.
local function refuse(reason)
  vim.notify(reason..' - nothing changed',vim.log.levels.WARN)
end

local function integer(n)
  return n and n==n and math.abs(n)<=9007199254740991 and n%1==0
end

local function candidate(lines, source, mapping, definitions, probe)
  local destinations={}
  for old,new in pairs(mapping) do
    if destinations[new] then return nil,'Duplicate destination '..new end
    destinations[new]=old
    if (definitions[old] or 0)>1 then return nil,'Ambiguous duplicate definition '..old end
  end
  local out={}
  for i,code in ipairs(source) do
    local supported={}
    local function allow(pattern)
      local pos=1
      while true do
        local a,b,at,word=code:find(pattern,pos)
        if not a then break end
        if lines[i]:sub(a,b)==code:sub(a,b) then supported[at]=word end
        pos=b+1
      end
    end
    local at,word=code:match('^%s*()([ON]%w+)')
    if at then supported[at]=word end
    allow('%f[%w]CALL%s+()(O%w+)%f[%W]')
    if probe then
      allow('%f[%w]GOTO%s*()(N%w+)%f[%W]')
      allow('%f[%w]IF%s*%b[]%s*()(N%w+)%f[%W]')
    end
    local problem
    out[i]=U.gsub(lines[i],code,'()%f[%w]([ON]%w+)%f[%W]',function(at,word)
      if mapping[word] then
        if supported[at]~=word then problem='unsupported occurrence of '..word end
        return mapping[word]
      elseif destinations[word] then problem='destination '..word..' collides with a retained definition/reference' end
    end)
    if problem then return nil,'Line '..i..': '..problem end
  end
  local ok,reason=U.editable(out)
  if not ok then return nil,reason end
  return out
end

-- :ORenumber [start] [step] [digits]: local definitions and direct CALLs only.
vim.api.nvim_create_user_command('ORenumber', function(o)
  local G=require('gcode.profile')
  if not G.interpret('ORenumber') then return end

  local args=o.fargs
  local start=tonumber(args[1] or '1')
  local step=tonumber(args[2] or '1')
  local digits=tonumber(args[3] or '4')
  if #args>3 or not integer(start) or start<0 or not integer(step) or step==0
    or not integer(digits) or digits<1 or digits>32 then return refuse('Invalid renumber arguments') end
  local lines=vim.api.nvim_buf_get_lines(0,0,-1,false)
  local source=G.mask(lines)
  local names,definitions,mapping={},{},{}
  for _,code in ipairs(source) do
    local name=code:match('^%s*(O%w+)')
    if name then
      definitions[name]=(definitions[name] or 0)+1
      if definitions[name]==1 then names[#names+1]=name end
    end
  end
  if #names==0 then return refuse('No eligible O-program headers found') end
  for i,old in ipairs(names) do
    local n=start+(i-1)*step
    if not integer(n) or n<0 then return refuse('Invalid destination number') end
    mapping[old]=string.format('O%0'..digits..'d',n)
  end
  local out,reason=candidate(lines,source,mapping,definitions,false)
  if not out then return refuse(reason) end
  if not vim.deep_equal(lines,out) then vim.api.nvim_buf_set_lines(0,0,-1,false,out) end
  local report={}
  for _,old in ipairs(names) do
    if old~=mapping[old] then report[#report+1]=old..' -> '..mapping[old] end
  end
  vim.notify(#report==0 and '(no changes)' or table.concat(report,'\n')..'\nComments/messages preserved; annotations may retain old names.')
end,{nargs='*',desc='Renumber local O definitions + direct CALLs: [start] [step] [digits]'})
