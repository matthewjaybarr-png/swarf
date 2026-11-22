-- Normal-production path selection only. Input is statefully masked executable text.
-- Not a macro evaluator and never used for preparation or geometry consumers.
-- facts is shared by every section of one estimate: facts.pallet is the pallet the path assumes.
local P = require('gcode.profile')
local T = {}

-- IF[..] N10 / IF [..] GOTO N10 -> condition text, label
local function jump(c)
  local cond, rest = c:match('^IF%s*(%b[])%s*(.-)%s*$')
  if not cond then return nil end
  local label = rest:match('^N(%w+)$') or rest:match('^GOTO%s*N(%w+)$')
  if label then return vim.trim(cond:sub(2, -2)), label end
end

function T.path(lines, sec, machine, issue, facts)
  facts = facts or {}
  local out, labels, duplicate = {}, {}, {}
  for i=sec.s,sec.e do
    out[i]=''
    local label=lines[i]:match('^%s*N(%w+)%s*$')
    if label then duplicate[label]=labels[label]~=nil; labels[label]=i end
  end
  -- a unique label below line i, or nil
  local function find(label,i)
    local n=labels[label]
    if n and not duplicate[label] and n>i then return n end
  end
  local function target(label,i)
    local n=find(label,i)
    if not n then issue('Unknown production target N'..label..' at line '..i,{line=i}) end
    return n
  end
  local function alarm(label)
    local n=labels[label]
    if not n then return false end
    local found=false
    for j=n+1,sec.e do
      local c=vim.trim(lines[j])
      if c:match('^N%w+') then break end
      if c~='' then
        if not c:match('^VUACM%[1%]%s*=') and not c:match('^VDOUT%[992%]%s*=%s*2$') then return false end
        if c:match('^VDOUT') then found=true end
      end
    end
    return found
  end
  -- A forward IF changes no travel when the lines it skips are only labels, VC common-variable
  -- assignments and forward GOTOs (OPB01: IF [VC[VACOD] EQ 7] NSET / GOTO NSET1 / NSET / VC17=7 / NSET1).
  local function neutral(i,n)
    local last, j = n-1, i+1
    while j<=last do
      local b=vim.trim(lines[j])
      local to=b:match('^GOTO%s*N(%w+)$')
      if to then
        local m=find(to,j)
        if not m then return false end
        last=math.max(last,m-1)
      elseif b~='' and not b:match('^N%w+$') and not b:match('^VC%d+%s*=') and not b:match('^VC%b[]%s*=') then
        return false
      end
      j=j+1
    end
    return true
  end
  local i, returned, stopped = sec.s, false, false
  while i<=sec.e do
    local c=vim.trim(lines[i]); out[i]=lines[i]
    local id,label=P.selector(c)
    local cond,to=jump(c)
    if id then
      if machine then
        local n=target(label,i)
        if n then
          out[i]=''
          if id==machine.id then i=n-1 end
        end
      else issue('Machine execution differs; select one timing machine at line '..i,{line=i}) end
    elseif c:match('^VDOUT%[992%]%s*=%s*2') then
      issue('Alarm stop reached at line '..i..'; normal production does not run here',{line=i})
      stopped=true; break
    elseif cond and (cond:match('^VMLOK%s*NE%s*0$') or cond:match('^VRSTT%s*NE%s*0$')) then
      if target(to,i) then out[i]='' end -- lock/restart off: fall through
    elseif cond and cond:match('^VC%s*%[%s*VACOD%s*%]%s*EQ%s*0$') then
      if target(to,i) then out[i]='' end -- every programmed tool enabled
    elseif cond and cond:match('^VC100%s*EQ%s*%d+$') then
      -- the first posted pallet is the one loaded
      local n, pallet = target(to,i), cond:match('(%d+)$')
      if n then
        out[i]=''
        facts.pallet = facts.pallet or pallet
        if facts.pallet==pallet then i=n-1 end
      end
    elseif cond and cond:match('^VC100%s*NE%s*%d+$') and alarm(to) then
      local pallet = cond:match('(%d+)$')
      if target(to,i) then
        facts.pallet = facts.pallet or pallet
        if facts.pallet==pallet then out[i]='' -- posted pallet check satisfied
        else issue('Pallet check at line '..i..' sends pallet VC100='..facts.pallet..' to its alarm',{line=i}) end
      end
    elseif cond and find(to,i) and neutral(i,find(to,i)) then
      out[i]='' -- skips no travel either way
    elseif c:match('^GOTO%s*N%w+$') then
      local n=find(c:match('^GOTO%s*N(%w+)$'),i)
      if n then out[i]=''; i=n-1 end -- a jump back is a loop: left for the walk to report
    end
    -- M02 / M30 end the program; M03 is spindle on, not an end
    if c:match('^M0?2%s*$') or c:match('^M30%s*$') then
      if sec.name~='MAIN' then issue('Program end in local sub '..sec.name..' at line '..i..'; return not modeled',{line=i}) end
      break
    end
    if c=='RTS' then
      returned=true
      if sec.name=='MAIN' then issue('RTS without a caller at line '..i,{line=i}) end
      break
    end
    i=i+1
  end
  if sec.name~='MAIN' and not returned and not stopped then issue('Local sub '..sec.name..' has no supported RTS return',{line=sec.s}) end
  return out
end

function T.conditions(facts)
  local pallet = facts and facts.pallet and ('pallet VC100='..facts.pallet..' loaded; ') or ''
  return 'Normal production: machine lock off; restart off; '..pallet
    ..'all programmed tools enabled; all parts loaded; posted pallet check satisfied.'
end
return T
