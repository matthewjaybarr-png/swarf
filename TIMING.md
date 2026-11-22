# CycleTime

`:CycleTime` estimates run time from the moves Swarf can read. It is a **report only**:
it never writes into the program and never claims to be exact.

## Where the numbers come from

Each value comes from, in order:

1. the machine's entry in your machines file (`:Machines`): `rapid_ipm`, `tc_seconds`;
2. `vim.g.gcode` in your init.lua: `rapid_ipm`, `tc_seconds`, `approach_seconds`;
3. an estimate (rapid 1000 ipm, tool change 8 s, approach 2 s), named as an estimate in the report.

A program is timed as one of your machines when recognition finds exactly one. Otherwise the
fallbacks are used and the report says so.

## What is timed

- Feed moves at their programmed feed, rapids at `rapid_ipm`, arcs by length.
- Tool changes at `tc_seconds`; G04 dwells.
- Subs in the same file, called in order with the caller's position and modes.
- A rapid from an unknown position gets the `approach_seconds` allowance.

## What is not

- Subs and macros stored on the control (not in the file), probe cycles, variables and
  expressions: listed as unknown, so the total is marked INCOMPLETE.
- Acceleration, look-ahead and override settings: the estimate is path length over feed.
- Branches (IF/GOTO) are not followed in general; lines are walked once, in order.
