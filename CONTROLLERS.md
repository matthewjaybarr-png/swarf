# Controllers

Swarf reads a buffer as one controller language. Pick it per buffer with
`:Control okuma`, `:Control haas`, `:Control tosnuc` or `:Control mazak-matrix`;
`:Control unknown` turns language analysis off, `:Control auto` goes back to recognition.
The choice is not saved.

With nothing chosen, Swarf tries to recognize the program:

1. One of **your** machines (`:Machines`) named in the header comments
   (`MACH #101`, `#101-#102`) or by the folder the file is opened from (`.../101`, `.../101-102`).
2. Mazak signals: a `G109` head line, a `<name>` first line, `MAZAK`/`MZK` in the header.
3. `VC200` or `G116` only **suggest** Okuma; `:Control okuma` decides it.

No machine model, option set or software version is implied by any choice.

| Family | What is read | Deliberate limits |
| --- | --- | --- |
| Okuma OSP | CALL/RTS, O subs, G116 tool changes, G71 cycle return level, VC/VDIN/VACOD words for K. | A subset of OSP, not a complete simulator. |
| Mazak Matrix (EIA/ISO) | G20/G21, G17/18/19, numeric O programs, simple M98 P / M99, milling G94/G95, G72.1 circle milling. | No Mazatrol, turning, named calls or generation-specific options. Mill-turn is recognized and outlined, not drawn. |
| Toshiba TOSNUC | G70/G71 units, G90/G91, linear and I/J XY arcs, `$` program headers, G72 `$` subs in the file. | G72 arguments/returns are not modeled; probe cycles are listed, not drawn. |
| Haas mill | Numeric O programs, G20/G21, G90/G91, G17 I/J arcs, M98 P / M99, M97 local subs, T preload with M06, drilling cycles, G12/G13, G68/G69. | No lathe dialect, M99-in-main loops or repeat/branch arguments; settings are not inferred. |

## What works on every control

- Highlighting and `K` (what is this code?). The tables are Okuma meanings; add your own
  with `vim.g.gcode = { hints = { ['M123'] = 'my meaning' } }`.
- `:Outline`, `]n` `]t` `]s` `gd` navigation, `:Compare`, `:FindAll`.
- `:Lint`: comment/message problems and structure issues.
- `:Backplot`, `:Range`, `:ArcCheck`: draw and check the moves that can be read.
  What cannot be drawn (macros, variables, subs outside the file) is listed and skipped.
- `:CycleTime`: report only, never written into the program (see TIMING.md).

## Editing commands

`:ORenumber`, `:Shift`, `:Mirror`, `:Rotate` and `:StripComments` work on Okuma programs and
refuse when a comment or message is not closed (it could hide code). Other controls refuse
editing commands and say so; nothing is changed.

## Not included

Swarf ships with no machines, tool libraries or probe macros. Your own machines and
settings go in your config (`:Machines`, `vim.g.gcode`).
