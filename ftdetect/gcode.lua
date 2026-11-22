-- Filetype detection for CNC programs.
-- Location: %LOCALAPPDATA%\nvim\ftdetect\gcode.lua
--
-- This MUST live in the ftdetect\ subfolder. Neovim only auto-loads detection
-- scripts from there; a copy sitting loose in the config root is never read.

vim.filetype.add({
  extension = {
    nc = 'gcode',   NC = 'gcode',
    tap = 'gcode',  TAP = 'gcode',
    cnc = 'gcode',  CNC = 'gcode',
    eia = 'gcode',  EIA = 'gcode',
    ngc = 'gcode',  NGC = 'gcode',
    min = 'gcode',  MIN = 'gcode',
    mpf = 'gcode',  MPF = 'gcode',
    ssb = 'gcode',  SSB = 'gcode',  -- Okuma subs and libraries
    lib = 'gcode',  LIB = 'gcode',
    -- Deliberately NOT mapping .h here: Heidenhain uses it, but so does every
    -- C header on the planet, and you'd break those. Add it only if you
    -- actually run Heidenhain posts.
  },

  -- Fallback for files a control spat out with no extension at all, or with
  -- an odd one (Mazak's 38218319.1K, 31144002.2S). Checks whether the first
  -- line that is not blank looks like a program header: a bare "%", an
  -- O-number, an Okuma named sub (OSET1 (...)) or a Mazak name (<38218319-1K>).
  -- Priority is set low so real extension matches above always win.
  pattern = {
    ['.*'] = {
      priority = -math.huge,
      function(_, bufnr)
        -- Read line 1 through the buffer API. (vim.filetype.getlines exists in
        -- Neovim's internals but is NOT public -- calling it throws, and the
        -- error aborts filetype detection for the whole buffer, including the
        -- extension matches above.)
        local first = ''
        for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, 20, false)) do
          if l:match('%S') then first = l break end
        end
        if first:match('^%%') or first:match('^[Oo]%d') or first:match('^O%u[%u%d]*%s*%(')
          or first:match('^<[%w%-_. ]+>') then
          return 'gcode'
        end
      end,
    },
  },
})
