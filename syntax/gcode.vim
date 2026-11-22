" Minimal G-code syntax highlighting for Neovim.
" Loaded automatically for files whose filetype is "gcode"
" (see ftdetect/gcode.lua).

if exists("b:current_syntax")
  finish
endif

syntax case ignore

" Comments in parentheses, e.g. (ROUGH MILL - 1/2 EM)
syntax region gcodeComment start="(" end=")"
syntax region gcodeMessage start="\"" end="\""
syntax region gcodeMessage start="'" end="'"
highlight default link gcodeMessage gcodeComment

" Line numbers, e.g. N100
syntax match gcodeLineNumber "^N\d\+"

" G and M codes, e.g. G01, G43.4, M08. Words may be packed together
" (Mazak: G0G28G91Z0.M9), so a word starts wherever no letter is right before it.
syntax match gcodeGCode "\a\@<!G\d\+\(\.\d\+\)\?"
syntax match gcodeMCode "\a\@<!M\d\+"

" Letter-addressed words, e.g. X1.25 Y-.75 F150. S8000 T12
syntax match gcodeAddress "\a\@<![XYZABCIJKFSTHDPQR]-\?\(\d\+\.\?\d*\|\.\d\+\)"

" Program start/end markers
syntax match gcodePercent "^%$"
syntax match gcodeProgramNumber "^O\d\+"

highlight default gcodeComment guifg=#6A9955
highlight default gcodeLineNumber guifg=#569CD6 gui=bold
highlight default gcodeGCode guifg=#C586C0 gui=bold
highlight default gcodeMCode guifg=#DCDCAA
highlight default gcodeAddress guifg=#B5CEA8
highlight default gcodePercent guifg=#D7BA7D gui=bold
highlight default gcodeProgramNumber guifg=#D7BA7D gui=bold

" --- G-code category overrides ---
" These are matched AFTER the generic gcodeGCode/gcodeMCode rules above,
" so Vim gives them priority for the specific codes they cover. Any G-code
" not listed here (G90, G94, G17, G56, etc.) still falls back to the
" general purple gcodeGCode color.

" Rapid moves: G0 / G00
syntax match gcodeRapid "\a\@<!G0\{1,2}\d\@!"
highlight default gcodeRapid guifg=#FFFFAA gui=bold

" Linear feed moves: G1 / G01
syntax match gcodeLinear "\a\@<!G0\?1\d\@!"
highlight default gcodeLinear guifg=#C586C0 gui=bold

" Arc moves: G2/G02 (CW), G3/G03 (CCW) - same color, distinct from linear
syntax match gcodeArc "\a\@<!G0\?[23]\d\@!"
highlight default gcodeArc guifg=#4EC9B0 gui=bold

" Family-specific meanings are highlighted from masked executable text in highlight.lua.

let b:current_syntax = "gcode"

" FileType may have run before these generic rules. Reapply family overrides last,
" including after :set syntax=gcode reloads the same controller's syntax.
lua vim.b.gc_syntax_control = nil; require('gcode.highlight').apply()
