# Swarf

A G-code editor setup for [Neovim](https://neovim.io) (0.10 or newer). It reads Okuma OSP,
Haas mill, Toshiba TOSNUC and Mazak Matrix (EIA/ISO) programs. No machines, tools or
site settings are built in: you add your own.

## Install

```sh
git clone <this repo> ~/swarf
```

Then add one line to your Neovim config (`~/.config/nvim/init.lua`), or use it as the whole config:

```lua
dofile(vim.fn.expand('~/swarf/gcode-init.lua'))
```

Open a program (`.nc`, `.min`, `.mpf`, `.eia`, ... see `ftdetect/gcode.lua`).

## First run

1. `:Machines` asks for your first machine: its number, its control, and a name.
   Or in one go: `:Machines add 101 haas VF-2 rapid_ipm=1000 tc_seconds=6`.
   The list is saved to `~/.config/nvim/swarf/machines.lua` (a plain Lua file you can edit).
2. A program that names one of your machines (`(MACH #101)`) or sits in a folder named for it
   (`.../101/`) is read as that machine's control. Anything else: `:Control haas` (or
   `okuma`, `tosnuc`, `mazak-matrix`) for that buffer.

## Commands

| Command | What it does |
| --- | --- |
| `K` | What is this code? (add your own: `vim.g.gcode = { hints = { M123 = '...' } }`) |
| `:Outline` | Programs, operations and tool changes; jump with `]n` `]t` `]s` `gd` |
| `:Lint` | Problems Swarf finds or cannot read, in the quickfix list |
| `:Backplot` | Draw the toolpath (HTML view) |
| `:CycleTime` | Run-time estimate, report only (TIMING.md) |
| `:Range` / `:ArcCheck` | Axis travel; arc radius/endpoint faults |
| `:Speeds` | SFM / IPR per tool |
| `:ORenumber` `:Shift` `:Mirror` `:Rotate` `:StripComments` | Edits, Okuma programs only; `u` undoes |
| `:Compare` | Diff against another program |
| `:Control` | Show or set the control for this buffer |
| `:GcodeHealth` | Setup check |

Every edit keeps a backup (`:Backups`, `:CompareBackup`). What each control supports, and
what it deliberately does not: CONTROLLERS.md.

## Settings

In your init.lua, before the `dofile` line:

```lua
vim.g.gcode = { fast_feed = 200, arc_tol = .0005, rapid_ipm = 1000, tc_seconds = 8 }
vim.g.swarf_machines = '/somewhere/else/machines.lua'   -- optional
```

## Tests

```sh
sh test/run.sh            # headless tests + the data scan
sh test/install-hook.sh   # run the scan before every commit
```

Swarf is an editor aid, not a simulator or a verified post. Prove programs on the machine.

## License

GPL-3.0-or-later, see LICENSE. Copyright (C) 2026 the Swarf contributors.
