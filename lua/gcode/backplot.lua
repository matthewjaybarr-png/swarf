-- backplot.lua - :Backplot  draws the toolpath in your web browser
--   :Backplot ........ the whole program        :Backplot O0002 ... one sub
-- Each sub is drawn in its own work offset (like the control runs it).
-- Z written as a variable (Z=VC43) is drawn at the last plain Z, or Z0.
-- Nothing in the program changes. The picture is a file in Neovim's cache folder.
local Mo = require('gcode.motion')
local U = require('gcode.util')
local B = {}

local PAGE = [==[<!doctype html>
<html><head><meta charset="utf-8"><title>Backplot - __NAME__</title>
<style>
:root{--bg:#15181d;--panel:#1d2128;--line:#2c323b;--text:#d7dce3;--dim:#8a93a0;--rapid:#c8cdd4}
@media (prefers-color-scheme: light){:root:not([data-theme="dark"]){--bg:#f4f5f7;--panel:#ffffff;--line:#d9dde3;--text:#1d2128;--dim:#5b6470;--rapid:#5b6470}}
*{box-sizing:border-box}html,body{margin:0;height:100%;background:var(--bg);color:var(--text);font:13px/1.4 "JetBrains Mono NL","JetBrainsMonoNL Nerd Font",system-ui,"Segoe UI",sans-serif}
#wrap{display:flex;height:100%}#side{width:270px;background:var(--panel);border-right:1px solid var(--line);overflow:auto;padding:12px}
#side h1{font-size:15px;margin:0 0 2px}#side .sub{color:var(--dim);font-size:12px;margin-bottom:10px}
.btns{display:flex;flex-wrap:wrap;gap:6px;margin:8px 0 12px}
button{background:var(--bg);color:var(--text);border:1px solid var(--line);border-radius:6px;padding:5px 9px;cursor:pointer;font:inherit}
button:hover{border-color:var(--dim)}
.tool{margin:8px 0 2px;font-weight:600;display:flex;align-items:center;gap:6px}
.sw{width:12px;height:12px;border-radius:3px;display:inline-block}
label{display:flex;gap:6px;align-items:center;padding:1px 0 1px 18px;cursor:pointer;color:var(--text)}
label.t{padding-left:0;font-weight:600}
#main{flex:1;min-width:0;min-height:0;position:relative}canvas{display:block;width:100%;height:100%}
#tip{position:absolute;left:12px;bottom:12px;right:12px;background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:6px 10px;font-family:"JetBrains Mono NL","JetBrainsMonoNL Nerd Font",Consolas,monospace;font-size:12px;min-height:28px;white-space:pre;overflow:hidden}
#plot-status{position:sticky;top:0;background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:8px;overflow-wrap:anywhere;z-index:1}
#plot-status strong{display:block}#blocker,#assumptions{display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}details{margin:10px 0;overflow-wrap:anywhere}#issues p{margin:6px 0}
.note{color:var(--dim);font-size:12px;margin-top:12px}
@media (max-width:700px){#wrap{flex-direction:column}#side{width:auto;max-height:40%;flex-shrink:0}}
</style></head><body><div id="wrap"><div id="side">
<h1>__NAME__</h1><div class="sub">Drag = turn &nbsp; Wheel = zoom &nbsp; Right-drag = move</div>
<div id="plot-status" role="status"><strong id="outcome"></strong><div id="blocker-count"></div><div id="blocker"></div><div id="assumptions"></div></div>
<details><summary id="issue-count">All issues</summary><div id="issues"></div></details>
<div class="btns"><button data-v="top">Top</button><button data-v="front">Front</button><button data-v="side">Side</button><button data-v="iso">Iso</button><button id="fit">Fit</button></div>
<label class="t"><input type="checkbox" id="rap" checked> Rapids (dashed)</label>
<div id="list"></div>
<div class="note">__NOTE__</div>
</div><div id="main"><canvas id="c"></canvas><div id="tip">Hover a line to see the block.</div></div></div>
<script>
const D=__DATA__;
document.getElementById('outcome').textContent=D.presentation.headline;
document.getElementById('blocker-count').textContent=D.presentation.remaining===null?'':'Additional blockers: '+D.presentation.remaining;
document.getElementById('blocker').textContent=D.presentation.blocker;
document.getElementById('assumptions').textContent=D.presentation.assumptions.length?'Assumptions: '+D.presentation.assumptions.join(' | '):'';
document.getElementById('issue-count').textContent='All issues and assumptions ('+D.issues.length+')';
D.issues.forEach(p=>{const row=document.createElement('p');row.textContent=(p.kind==='assumed'?'Assumption — ':'')+(p.line?'Line '+p.line+': ':'Program: ')+p.text;document.getElementById('issues').appendChild(row)});
const pal=['#4e9af1','#f2994a','#27ae60','#eb5757','#9b51e0','#2ec4b6','#f2c94c','#e056a0','#56ccf2','#bb6bd9','#6fcf97','#ff8a65'];
const tools=[...new Set(D.secs.map(s=>s.tool))];const col=t=>pal[tools.indexOf(t)%pal.length];
const on={};D.secs.forEach(s=>on[s.name]=true);
const list=document.getElementById('list');
tools.forEach(t=>{const h=document.createElement('div');h.className='tool';
 const sw=document.createElement('span');sw.className='sw';sw.style.background=col(t);h.appendChild(sw);h.appendChild(document.createTextNode(t?'T'+t:'(no tool)'));list.appendChild(h);
 D.secs.filter(s=>s.tool===t).forEach(s=>{const l=document.createElement('label'),input=document.createElement('input');input.type='checkbox';input.checked=true;l.appendChild(input);
 l.appendChild(document.createTextNode(' '+s.name+(s.desc?' '+s.desc:'')));
 input.onchange=e=>{on[s.name]=e.target.checked;draw()};list.appendChild(l)})});
const rap=document.getElementById('rap');rap.onchange=()=>draw();
const cv=document.getElementById('c'),cx=cv.getContext('2d'),tip=document.getElementById('tip');
let yaw=-Math.PI/4,pitch=-1.0,scale=50,ox=0,oy=0,ctr=[0,0,0];
function proj(x,y,z){x-=ctr[0];y-=ctr[1];z-=ctr[2];const c=Math.cos(yaw),s=Math.sin(yaw);const x1=x*c-y*s,y1=x*s+y*c;
 const cp=Math.cos(pitch),sp=Math.sin(pitch);const y2=y1*cp-z*sp;return[x1*scale+ox,-y2*scale+oy]}
function vis(){return D.secs.filter(s=>on[s.name])}
function fit(){let lo=[1e9,1e9,1e9],hi=[-1e9,-1e9,-1e9];vis().forEach(s=>s.segs.forEach(g=>{for(let k=0;k<3;k++){lo[k]=Math.min(lo[k],g[k],g[k+3]);hi[k]=Math.max(hi[k],g[k],g[k+3])}}));
 if(lo[0]>hi[0]){lo=[0,0,0];hi=[1,1,1]}ctr=[0,1,2].map(k=>(lo[k]+hi[k])/2);scale=1;ox=0;oy=0;
 let a=[1e9,1e9],b=[-1e9,-1e9];vis().forEach(s=>s.segs.forEach(g=>{[proj(g[0],g[1],g[2]),proj(g[3],g[4],g[5])].forEach(p=>{a[0]=Math.min(a[0],p[0]);a[1]=Math.min(a[1],p[1]);b[0]=Math.max(b[0],p[0]);b[1]=Math.max(b[1],p[1])})}));
 const w=cv.clientWidth,h=cv.clientHeight-50;scale=Math.min(w/Math.max(b[0]-a[0],1e-3),h/Math.max(b[1]-a[1],1e-3))*0.9;
 ox=w/2-(a[0]+b[0])/2*scale;oy=h/2-(a[1]+b[1])/2*scale;draw()}
function size(){cv.width=cv.clientWidth*devicePixelRatio;cv.height=cv.clientHeight*devicePixelRatio;cx.setTransform(devicePixelRatio,0,0,devicePixelRatio,0,0)}
function axes(){const base=[40,cv.clientHeight-80];cx.setLineDash([]);cx.font='12px "JetBrains Mono NL","JetBrainsMonoNL Nerd Font",system-ui';
 [[1,0,0,'X','#eb5757'],[0,1,0,'Y','#27ae60'],[0,0,1,'Z','#4e9af1']].forEach(a=>{const c=Math.cos(yaw),s=Math.sin(yaw);
 const x1=a[0]*c-a[1]*s,y1=a[0]*s+a[1]*c,y2=y1*Math.cos(pitch)-a[2]*Math.sin(pitch);cx.strokeStyle=a[4];cx.lineWidth=2;cx.beginPath();
 cx.moveTo(base[0],base[1]);cx.lineTo(base[0]+x1*28,base[1]-y2*28);cx.stroke();cx.fillStyle=a[4];cx.fillText(a[3],base[0]+x1*36-3,base[1]-y2*36+4)})}
function draw(){const w=cv.clientWidth,h=cv.clientHeight;cx.clearRect(0,0,w,h);const rc=getComputedStyle(document.documentElement).getPropertyValue('--rapid');
 vis().forEach(s=>{const c=col(s.tool);s.segs.forEach(g=>{if(g[6]===0&&!rap.checked)return;const a=proj(g[0],g[1],g[2]),b=proj(g[3],g[4],g[5]);
 cx.beginPath();cx.moveTo(a[0],a[1]);cx.lineTo(b[0],b[1]);if(g[6]===0){cx.strokeStyle=rc;cx.globalAlpha=.55;cx.lineWidth=1;cx.setLineDash([4,4])}
 else{cx.strokeStyle=c;cx.globalAlpha=1;cx.lineWidth=1.6;cx.setLineDash([])}cx.stroke()})});cx.globalAlpha=1;cx.setLineDash([]);axes()}
let drag=null;cv.addEventListener('contextmenu',e=>e.preventDefault());
cv.addEventListener('mousedown',e=>{drag={x:e.clientX,y:e.clientY,b:e.button||(e.shiftKey?2:0)}});
addEventListener('mouseup',()=>drag=null);
cv.addEventListener('mousemove',e=>{if(drag){const dx=e.clientX-drag.x,dy=e.clientY-drag.y;drag.x=e.clientX;drag.y=e.clientY;
 if(drag.b===2){ox+=dx;oy+=dy}else{yaw+=dx*.01;pitch=Math.max(-Math.PI,Math.min(0,pitch+dy*.01))}draw();return}hover(e)});
cv.addEventListener('wheel',e=>{e.preventDefault();const r=cv.getBoundingClientRect(),mx=e.clientX-r.left,my=e.clientY-r.top,f=e.deltaY<0?1.15:1/1.15;
 ox=mx-(mx-ox)*f;oy=my-(my-oy)*f;scale*=f;draw()},{passive:false});
function hover(e){const r=cv.getBoundingClientRect(),mx=e.clientX-r.left,my=e.clientY-r.top;let best=null,bd=8;
 vis().forEach(s=>s.segs.forEach(g=>{if(g[6]===0&&!rap.checked)return;const a=proj(g[0],g[1],g[2]),b=proj(g[3],g[4],g[5]);const vx=b[0]-a[0],vy=b[1]-a[1];
 const L=vx*vx+vy*vy;let t=L?((mx-a[0])*vx+(my-a[1])*vy)/L:0;t=Math.max(0,Math.min(1,t));const d=Math.hypot(a[0]+t*vx-mx,a[1]+t*vy-my);if(d<bd){bd=d;best=[s,g]}}));
 tip.textContent=best?(best[0].name+'  line '+best[1][7]+':  '+(D.lines[best[1][7]]||'')+'   ->  X'+best[1][3].toFixed(4)+' Y'+best[1][4].toFixed(4)+' Z'+best[1][5].toFixed(4)):'Hover a line to see the block.'}
const V={top:[0,0],front:[0,-Math.PI/2],side:[-Math.PI/2,-Math.PI/2],iso:[-Math.PI/4,-1.0]};
document.querySelectorAll('[data-v]').forEach(b=>b.onclick=()=>{[yaw,pitch]=V[b.dataset.v];fit()});
document.getElementById('fit').onclick=fit;addEventListener('resize',()=>{size();fit()});size();fit();
</script></body></html>]==]

-- path (optional): the file's name, so a machine folder can identify the control
function B.build(lines, only, control, path)
  local c = require('gcode.profile').resolve(lines, control, path)
  if c.mode ~= 'generic' then return nil, c.reason end
  if c.mazak then return B.mazak(lines, only, c) end
  if c.reader then return B.reader(lines, only, c) end
  local original, problems, meta = lines,{},{}
  local family = c.control ~= 'okuma'
  if family then lines,problems,meta=require('gcode.dialect').prepare(lines,c.control)
  else lines,problems=require('gcode.profile').mask(lines) end
  problems=U.issues(problems)
  local secs, subtool = Mo.sub_tools(lines,true)
  local data = { secs = {}, lines = {}, issues = problems, control=c.control, mode=c.mode, moves_omitted=meta.moves_omitted or false, incomplete=vim.iter(problems):any(function(p) return p.blocking end) }
  for _, sec in ipairs(secs) do
    if (not only or sec.name == only) then
      local moves, ev = Mo.walk(lines, sec, subtool[sec.name],{generic=family,resets=meta.resets,masked=true})
      local invalid = {}
      for _,a in ipairs(ev.arcbad) do invalid[a.line]=true end
      for _,l in ipairs(ev.noarc) do invalid[l]=true end
      local segs = {}
      local lx, ly, lz = nil, nil, 0
      for _, m in ipairs(moves) do
        local complete = m.from.x and m.from.y and m.from.z and m.to.x and m.to.y and m.to.z
          and (m.kind~='arc' or m.cx and m.cy and m.r and not invalid[m.line])
        if family and m.kind~='home' and not complete then
          data.incomplete=true; data.moves_omitted=true
          data.issues[#data.issues+1]={line=m.line,text='Unsupported: unknown starting position or invalid arc; move omitted',invalid=invalid[m.line] or false,kind=invalid[m.line] and 'invalid' or 'unsupported',blocking=true}
        end
        if m.kind ~= 'home' and (not family or complete) then
          local pts, chord = Mo.points(m, 0.08)
          local prev, drawn = nil, #segs
          for _, p in ipairs(pts) do
            local x, y, z = p.x or lx, p.y or ly, p.z or lz
            if x and y then
              if prev then
                segs[#segs + 1] = { prev[1], prev[2], prev[3], x, y, z, m.kind == 'rapid' and 0 or 1, m.line }
                data.lines[m.line] = vim.trim(original[m.line])
              end
              prev = { x, y, z }
              lx, ly, lz = x, y, z
            end
          end
          -- never a silent chord: say when an arc's picture is not the path the control runs
          -- (an arc from an unknown start draws nothing, like any move from an unknown start)
          if m.kind=='arc' and (chord and #segs>drawn or invalid[m.line]) then
            data.incomplete=true
            data.issues[#data.issues+1]={line=m.line,invalid=invalid[m.line] or false,kind=invalid[m.line] and 'invalid' or 'unsupported',blocking=true,
              text=chord and ('Arc drawn as a straight line: '..(m.why or 'center unknown'))
                or 'Arc does not close (start and end radii differ): drawn on its start radius'}
          end
        end
      end
      if #segs > 0 then
        local desc = original[sec.s]:match('^O%w+%s*%((.-)%)') or ''
        data.secs[#data.secs + 1] = { name = sec.name, tool = subtool[sec.name] or '', desc = desc, segs = segs }
      end
    end
  end
  return data
end

-- sections of motion.walk-shaped moves (mazak.walk, reader.walk) -> drawn entries
local function draw(data, secs, issues, lines, only)
  data.issues = vim.tbl_map(U.issue, issues)
  data.moves_omitted = vim.iter(issues):any(function(p) return p.kind ~= 'assumed' end)
  for _, sec in ipairs(secs) do
    if not only or sec.name == only then
      local segs = {}
      for _, m in ipairs(sec.moves) do
        local pts, prev = Mo.points(m, 0.08), nil
        for _, p in ipairs(pts) do
          local pt = { p.x or (prev and prev[1]), p.y or (prev and prev[2]), p.z or (prev and prev[3]) }
          if prev and pt[1] and pt[2] and pt[3] then
            segs[#segs + 1] = { prev[1], prev[2], prev[3], pt[1], pt[2], pt[3], m.kind == 'rapid' and 0 or 1, m.line }
            data.lines[m.line] = vim.trim(lines[m.line])
          end
          prev = pt
        end
      end
      if #segs > 0 then
        data.secs[#data.secs + 1] = { name = sec.name, tool = sec.tool or '', desc = sec.desc, segs = segs }
      end
    end
  end
  return data
end

-- Mazak Matrix programs: one entry per N block, each in its own work offset.
function B.mazak(lines, only, c)
  local data = { secs = {}, lines = {}, issues = {}, control = c.control, mode = c.mode, mazak = c.mazak,
    moves_omitted = false, incomplete = false }
  if c.mazak == 'millturn' then
    data.issues[1] = U.issue({ text = 'Unsupported: mill-turn (G109) programs are not drawn yet', kind = 'unsupported', blocking = true })
    data.incomplete = true
    return data
  end
  local secs, issues = require('gcode.mazak').walk(lines)
  return draw(data, secs, issues, lines, only)
end

-- Haas and Toshiba programs: one entry per operation, each in its own work offset;
-- subs in the file are drawn where they are called.
function B.reader(lines, only, c)
  local data = { secs = {}, lines = {}, issues = {}, control = c.control, mode = c.mode, reader = c.reader,
    moves_omitted = false, incomplete = false }
  local secs, issues = require('gcode.reader').walk(lines, c.reader)
  return draw(data, secs, issues, lines, only)
end

function B.status(data)
  local blockers,assumptions={},{}
  local ordered=U.issues(data.issues)
  for _,issue in ipairs(ordered) do
    local text=(issue.line and ('Line '..issue.line..': ') or 'Program: ')..issue.text
    if issue.kind=='assumed' then assumptions[#assumptions+1]=text
    elseif issue.blocking then blockers[#blockers+1]=text end
  end
  local headline
  if #data.secs==0 then headline='Nothing drawn.'
  elseif data.moves_omitted then headline='Partial path: some moves omitted.'
  elseif data.incomplete or #blockers>0 then headline='Partial path: source issues limit interpretation.'
  else headline='Path available.' end
  local blocker=#blockers>0 and ('First blocker: '..blockers[1])
    or (data.incomplete and 'Interpretation incomplete; blocker details were not supplied.' or '')
  return {headline=headline,blocker=blocker,remaining=#blockers>1 and (#blockers-1) or vim.NIL,assumptions=assumptions}
end

local function note(data)
  local text=data.control=='okuma' and 'Each sub is drawn in its own work offset. Moves with variable Z (Z=VC43) are drawn at the last plain Z.'
    or data.mazak and 'Each N block is drawn in its own work offset (G54.1 P, B face). Moves after a frame change start at the next fully known position.'
    or data.reader=='haas' and 'Each N block is drawn in its own work offset (G154 P, G54-G59, A index); M97/M98 subs in this file are drawn where they are called. Moves after a frame change start at the next fully known position.'
    or data.reader=='tosnuc' and 'Each tool is drawn in its own work offset (G57 H, B face). Moves after a frame change or a G73 retract start at the next fully known position.' or ''
  if data.mode=='generic' or data.control~='okuma' then text=text..(text~='' and ' ' or '')..require('gcode.profile').limits end
  return text
end

function B.report(data,name)
  local status=B.status(data)
  local out={status.headline,'Program: '..(name or 'program'),'Controller: '..data.control,note(data)}
  if status.blocker~='' then out[#out+1]=status.blocker end
  if status.remaining~=vim.NIL then out[#out+1]='Additional blockers: '..status.remaining end
  if #status.assumptions>0 then out[#out+1]='Assumptions: '..table.concat(status.assumptions,'; ') end
  out[#out+1]='All issues and assumptions:'
  for _,issue in ipairs(U.issues(data.issues)) do
    out[#out+1]=(issue.line and ('Line '..issue.line..': ') or 'Program: ')..issue.text
  end
  return out
end

function B.html(data,name)
  local display=vim.deepcopy(data)
  display.issues=U.issues(data.issues)
  display.presentation=B.status(data)
  local lt={}
  for k,v in pairs(data.lines) do lt[tostring(k)]=v end
  display.lines=lt
  local esc=name:gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;')
  -- Source wording is data, including a literal closing script tag.
  local json=vim.json.encode(display):gsub('<','\\u003c')
  return PAGE:gsub('__%u+__',{__NAME__=esc,__DATA__=json,__NOTE__=note(data)})
end

vim.api.nvim_create_user_command('Backplot', function(o)
  if not require('gcode.profile').interpret('Backplot') then return end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local only = o.args ~= '' and o.args:upper() or nil
  local data = B.build(lines, only, vim.b.gcode_control, vim.api.nvim_buf_get_name(0))
  local name = vim.fn.expand('%:t') ~= '' and vim.fn.expand('%:t') or 'program'
  local title=name..(only and (' - '..only) or '')
  if #data.secs==0 then
    Mo.report('Backplot',B.report(data,title))
    vim.wo.wrap=true; vim.wo.linebreak=true
    return
  end
  local html=B.html(data,title)
  vim.fn.mkdir(vim.fn.stdpath('cache'), 'p')
  local path = vim.fn.stdpath('cache') .. '/backplot-' .. name:gsub('[^%w%-_%.]', '_') .. '.html'
  local f = assert(io.open(path, 'w'))
  f:write(html)
  f:close()
  if vim.ui.open then
    vim.ui.open(path)
  elseif vim.fn.has('win32') == 1 then
    vim.fn.jobstart({ 'cmd', '/c', 'start', '', path }, { detach = true })
  else
    vim.fn.jobstart({ 'xdg-open', path }, { detach = true })
  end
  local status=B.status(data)
  vim.notify(status.headline..' Backplot opened in your browser ('..path..')'
    ..(status.blocker~='' and ('\n'..status.blocker) or '')
    ..(status.remaining~=vim.NIL and ('\nAdditional blockers: '..status.remaining) or '')
    ..((data.mode=='generic' or data.control~='okuma') and ('\n'..require('gcode.profile').limits) or ''))
end, { nargs = '?', desc = 'Draw the toolpath in the browser' })

return B
