local M = {}

M._last_theme_sig = nil

local function int_to_hex(n)
  if type(n) ~= "number" then
    return nil
  end
  return string.format("#%06x", bit.band(n, 0xffffff))
end

local function hex_to_rgb(hex)
  if type(hex) ~= "string" then
    return nil
  end
  hex = hex:gsub("^#", "")
  if #hex ~= 6 then
    return nil
  end
  local r = tonumber(hex:sub(1, 2), 16)
  local g = tonumber(hex:sub(3, 4), 16)
  local b = tonumber(hex:sub(5, 6), 16)
  if not r or not g or not b then
    return nil
  end
  return r, g, b
end

local function clamp_byte(v)
  return math.max(0, math.min(255, math.floor(v + 0.5)))
end

local function rgb_to_hex(r, g, b)
  return string.format("#%02x%02x%02x", clamp_byte(r), clamp_byte(g), clamp_byte(b))
end

local function blend(fg_hex, bg_hex, alpha)
  if not fg_hex then
    return bg_hex
  end
  if not bg_hex then
    return fg_hex
  end
  local r1, g1, b1 = hex_to_rgb(fg_hex)
  local r2, g2, b2 = hex_to_rgb(bg_hex)
  if not r1 or not r2 then
    return fg_hex or bg_hex
  end
  return rgb_to_hex(
    r1 * alpha + r2 * (1 - alpha),
    g1 * alpha + g2 * (1 - alpha),
    b1 * alpha + b2 * (1 - alpha)
  )
end

local function luminance(hex)
  local r, g, b = hex_to_rgb(hex)
  if not r then
    return nil
  end
  return 0.299 * r + 0.587 * g + 0.114 * b
end

local function color_distance(h1, h2)
  local r1, g1, b1 = hex_to_rgb(h1)
  local r2, g2, b2 = hex_to_rgb(h2)
  if not r1 or not r2 then
    return 0
  end
  return math.sqrt((r1 - r2) ^ 2 + (g1 - g2) ^ 2 + (b1 - b2) ^ 2)
end

local function get_hl(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or type(hl) ~= "table" then
    return {}
  end
  local fg = int_to_hex(hl.fg)
  local bg = int_to_hex(hl.bg)
  if hl.reverse or hl.standout then
    fg, bg = bg, fg
  end
  return {
    fg = fg,
    bg = bg,
    bold = hl.bold,
    italic = hl.italic,
    underline = hl.underline,
  }
end

local function pick_fg(...)
  for i = 1, select("#", ...) do
    local name = select(i, ...)
    local hl = get_hl(name)
    if hl.fg then
      return hl.fg
    end
  end
  return nil
end

local function pick_bg(...)
  for i = 1, select("#", ...) do
    local name = select(i, ...)
    local hl = get_hl(name)
    if hl.bg then
      return hl.bg
    end
  end
  return nil
end

local function current_theme_sig()
  local n = get_hl("Normal")
  local cl = get_hl("CursorLine")
  local t = get_hl("Title")
  return table.concat({
    tostring(vim.g.colors_name or ""),
    tostring(vim.o.background or ""),
    tostring(n.fg or ""),
    tostring(n.bg or ""),
    tostring(cl.bg or ""),
    tostring(t.fg or ""),
  }, ":")
end

function M.ensure_synced()
  local sig = current_theme_sig()
  if M._last_theme_sig ~= sig then
    M.setup()
  end
end

function M.setup()
  local normal = get_hl("Normal")
  local bg_lum = luminance(normal.bg)
  local is_light = (bg_lum ~= nil) and (bg_lum > 140) or (vim.o.background == "light")

  local normal_fg = normal.fg
    or pick_fg("NormalFloat", "ModeMsg", "Title")
    or (is_light and "#1e293b" or "#cdd6f4")

  local base_bg = normal.bg
    or pick_bg("NormalFloat", "NormalSB", "Pmenu", "SignColumn", "CursorLine")
    or (is_light and "#f8fafc" or "#1a1b26")

  local surface_bg = pick_bg("NormalFloat", "NormalSB", "Pmenu")
  if not surface_bg or color_distance(surface_bg, base_bg) > 85 then
    surface_bg = blend(normal_fg, base_bg, is_light and 0.04 or 0.04)
  end

  local cursorline_bg = pick_bg("CursorLine", "CursorColumn", "PmenuSel")
  if not cursorline_bg or color_distance(cursorline_bg, base_bg) < 8 or color_distance(cursorline_bg, base_bg) > 95 then
    cursorline_bg = blend(normal_fg, base_bg, is_light and 0.07 or 0.08)
  end

  local visual_bg = pick_bg("Visual", "PmenuSel", "CursorLine")
  if not visual_bg or color_distance(visual_bg, base_bg) < 12 then
    visual_bg = blend(normal_fg, base_bg, is_light and 0.16 or 0.18)
  end

  -- Extract semantic accents from the active Neovim colorscheme
  local title_fg = pick_fg("Title", "Directory", "Function", "Special") or normal_fg
  local special_fg = pick_fg("Special", "Type", "Identifier", "Constant") or title_fg
  local active_fg = pick_fg("CursorLineNr", "Statement", "Keyword", "Special") or title_fg
  local muted_fg = pick_fg("Comment", "NonText", "LineNr") or blend(normal_fg, base_bg, 0.45)
  local linenr_fg = pick_fg("LineNr", "Comment") or blend(normal_fg, base_bg, 0.38)
  local float_border_fg = pick_fg("FloatBorder", "Title", "Special") or title_fg

  local ok_fg = pick_fg("DiagnosticOk", "String", "Added") or (is_light and "#15803d" or "#9ece6a")
  local warn_fg = pick_fg("DiagnosticWarn", "WarningMsg", "Changed", "Number") or (is_light and "#b45309" or "#e0af68")
  local err_fg = pick_fg("DiagnosticError", "ErrorMsg", "Removed") or (is_light and "#b91c1c" or "#f7768e")
  local info_fg = pick_fg("DiagnosticInfo", "DiagnosticHint", "Special", "Title") or title_fg
  local num_fg = pick_fg("Number", "Constant", "Float") or warn_fg
  local func_fg = pick_fg("Function", "@function", "Directory", "Title") or (is_light and "#2563eb" or "#7aa2f7")
  local str_fg = pick_fg("String", "@string", "DiagnosticOk") or ok_fg
  local kw_fg = pick_fg("Keyword", "@keyword", "Statement", "Conditional") or (is_light and "#7c3aed" or "#bb9af7")
  local type_fg = pick_fg("Type", "@type", "Special", "StorageClass") or (is_light and "#0891b2" or "#2ac3de")
  local const_fg = pick_fg("Constant", "@constant", "Number", "Boolean") or (is_light and "#ea580c" or "#ff9e64")
  local op_fg = pick_fg("Operator", "@operator", "DiagnosticHint", "PreProc") or (is_light and "#0284c7" or "#89ddff")
  local ident_fg = pick_fg("@variable.member", "@property", "Identifier", "Special") or (is_light and "#4f46e5" or "#7dcfff")

  -- Build a 10-color Rainbow CSV palette adapted to the active Neovim colorscheme
  local raw_rainbow = {
    func_fg,                                           -- 1: Blue (Function)
    str_fg,                                            -- 2: Green (String)
    const_fg,                                          -- 3: Orange / Peach (Constant / Number)
    type_fg,                                           -- 4: Cyan / Teal (Type / Special)
    kw_fg,                                             -- 5: Purple / Magenta (Keyword)
    warn_fg,                                           -- 6: Yellow / Gold (DiagnosticWarn)
    err_fg,                                            -- 7: Coral / Rose (DiagnosticError)
    op_fg,                                             -- 8: Sky / Aqua (Operator / Hint)
    blend(kw_fg, err_fg, 0.50),                        -- 9: Orchid / Pink
    blend(str_fg, type_fg, 0.50) or ident_fg,          -- 10: Mint / Seafoam
  }
  local fallback_dark = { "#7aa2f7", "#9ece6a", "#ff9e64", "#2ac3de", "#bb9af7", "#e0af68", "#f7768e", "#7dcfff", "#f5c2e7", "#73daca" }
  local fallback_light = { "#2563eb", "#16a34a", "#ea580c", "#0891b2", "#7c3aed", "#ca8a04", "#dc2626", "#0284c7", "#db2777", "#0d9488" }
  local fallbacks = is_light and fallback_light or fallback_dark

  M.num_rainbow = 10
  local rainbow_fgs = {}
  for i = 1, M.num_rainbow do
    local cand = raw_rainbow[i] or fallbacks[i]
    -- Ensure distinctness from immediately preceding rainbow color
    if i > 1 and color_distance(cand, rainbow_fgs[i - 1]) < 32 then
      cand = fallbacks[i]
    end
    rainbow_fgs[i] = cand
  end

  -- Clean, calm row & header surfaces (no clashy multi-colored background boxes)
  local header_bg = blend(cursorline_bg, base_bg, 0.55)
  local row_odd_col_odd_bg = normal.bg -- nil when terminal background is transparent
  local row_odd_col_even_bg = blend(cursorline_bg, base_bg, 0.25)
  local row_even_col_odd_bg = blend(cursorline_bg, base_bg, 0.42)
  local row_even_col_even_bg = blend(cursorline_bg, base_bg, 0.58)

  local pinned_odd_bg = row_odd_col_odd_bg
  local pinned_even_bg = row_even_col_odd_bg
  local pinned_fg = rainbow_fgs[1]

  local cursor_row_bg = blend(title_fg, cursorline_bg, is_light and 0.10 or 0.12)
  local cursor_cell_bg = blend(active_fg, visual_bg, is_light and 0.26 or 0.24)
  local cursor_cell_fg = normal_fg
  if math.abs((luminance(cursor_cell_bg) or 0) - (luminance(normal_fg) or 255)) < 65 then
    cursor_cell_fg = base_bg
  end

  local search_hl = get_hl("Search")
  local match_bg = search_hl.bg or blend(warn_fg, base_bg, 0.28)
  local match_fg = search_hl.fg or normal_fg
  if math.abs((luminance(match_bg) or 0) - (luminance(match_fg) or 255)) < 60 then
    match_fg = warn_fg
  end

  local groups = {
    SuperCsvHeaderBanner   = { bg = surface_bg, fg = title_fg, bold = true },
    SuperCsvHeaderPinned   = { bg = header_bg, fg = special_fg, bold = true },
    SuperCsvHeaderNormal   = { bg = header_bg, fg = normal_fg, bold = true },
    SuperCsvHeaderActive   = { bg = blend(active_fg, cursorline_bg, 0.22), fg = active_fg, bold = true },
    SuperCsvHeaderFiltered = { bg = blend(ok_fg, cursorline_bg, 0.18), fg = ok_fg, bold = true },
    SuperCsvHeaderType     = { bg = header_bg, fg = linenr_fg },

    SuperCsvColOdd         = { bg = row_odd_col_odd_bg, fg = normal_fg },
    SuperCsvColEven        = { bg = row_odd_col_even_bg, fg = normal_fg },
    SuperCsvRowOddColOdd   = { bg = row_odd_col_odd_bg, fg = normal_fg },
    SuperCsvRowOddColEven  = { bg = row_odd_col_even_bg, fg = normal_fg },
    SuperCsvRowEvenColOdd  = { bg = row_even_col_odd_bg, fg = normal_fg },
    SuperCsvRowEvenColEven = { bg = row_even_col_even_bg, fg = normal_fg },

    SuperCsvColPinned      = { bg = pinned_odd_bg, fg = pinned_fg, bold = true },
    SuperCsvColPinnedOdd   = { bg = pinned_odd_bg, fg = pinned_fg, bold = true },
    SuperCsvColPinnedEven  = { bg = pinned_even_bg, fg = pinned_fg, bold = true },

    SuperCsvCursorRow      = { bg = cursor_row_bg, fg = normal_fg, bold = true },
    SuperCsvCursorCell     = { bg = cursor_cell_bg, fg = cursor_cell_fg, bold = true, underline = true, sp = active_fg },

    SuperCsvCellModified   = { bg = blend(warn_fg, base_bg, 0.20), fg = warn_fg, bold = true },
    SuperCsvCellMatch      = { bg = match_bg, fg = match_fg, bold = true },

    SuperCsvBorder         = { fg = blend(muted_fg, base_bg, 0.55) },
    SuperCsvBorderPinned   = { fg = blend(float_border_fg, muted_fg, 0.50), bold = true },

    SuperCsvFooterSummary  = { bg = surface_bg, fg = info_fg, bold = true },
    SuperCsvFooterCell     = { bg = header_bg, fg = blend(normal_fg, muted_fg, 0.30) },

    SuperCsvTypeNumber     = { fg = num_fg },
    SuperCsvTypeBoolTrue   = { fg = ok_fg, bold = true },
    SuperCsvTypeBoolFalse  = { fg = err_fg, bold = true },
    SuperCsvTypeNull       = { fg = muted_fg, italic = true },
    SuperCsvSubtable       = { fg = type_fg, bold = true },

    SuperCsvHeatLow        = { bg = blend(ok_fg, base_bg, 0.16), fg = ok_fg },
    SuperCsvHeatMid        = { bg = blend(warn_fg, base_bg, 0.18), fg = warn_fg },
    SuperCsvHeatHigh       = { bg = blend(err_fg, base_bg, 0.22), fg = err_fg, bold = true },

    SuperCsvCommentBar     = { bg = surface_bg, fg = warn_fg, bold = true },
    SuperCsvComment        = { bg = surface_bg, fg = muted_fg, italic = true },
    SuperCsvCommentLineNr  = { bg = surface_bg, fg = info_fg, bold = true },
  }

  for i = 1, M.num_rainbow do
    local rfg = rainbow_fgs[i]
    groups["SuperCsvRainbow" .. i] = { fg = rfg }
    groups["SuperCsvRainbowBold" .. i] = { fg = rfg, bold = true }
    groups["SuperCsvRainbowHeader" .. i] = { bg = header_bg, fg = rfg, bold = true }
  end

  for name, spec in pairs(groups) do
    vim.api.nvim_set_hl(0, name, spec)
  end

  M._last_theme_sig = current_theme_sig()

  if not M._autocmd_registered then
    M._autocmd_registered = true
    local grp = vim.api.nvim_create_augroup("SuperCsvHighlights", { clear = true })
    vim.api.nvim_create_autocmd({ "ColorScheme", "UIEnter" }, {
      group = grp,
      callback = function()
        M.setup()
      end,
    })
    vim.api.nvim_create_autocmd("OptionSet", {
      group = grp,
      pattern = "background",
      callback = function()
        M.setup()
      end,
    })
  end
end

return M
