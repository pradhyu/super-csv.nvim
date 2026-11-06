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

  -- Harmonious row & column zebra surfaces stepped smoothly between Normal and CursorLine
  local row_odd_col_odd_bg = normal.bg -- nil when terminal background is transparent
  local row_odd_col_even_bg = blend(cursorline_bg, base_bg, 0.32)
  local row_even_col_odd_bg = blend(cursorline_bg, base_bg, 0.62)
  local row_even_col_even_bg = blend(cursorline_bg, base_bg, 0.85)

  local pinned_odd_bg = blend(special_fg, surface_bg, is_light and 0.08 or 0.07)
  local pinned_even_bg = blend(special_fg, row_even_col_odd_bg, is_light and 0.10 or 0.09)
  local pinned_fg = blend(special_fg, normal_fg, 0.30)

  local cursor_row_bg = blend(title_fg, cursorline_bg, is_light and 0.12 or 0.14)
  local cursor_cell_bg = blend(active_fg, visual_bg, is_light and 0.28 or 0.26)
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
    SuperCsvHeaderBanner   = { bg = blend(title_fg, surface_bg, 0.08), fg = title_fg, bold = true },
    SuperCsvHeaderPinned   = { bg = blend(special_fg, cursorline_bg, 0.16), fg = special_fg, bold = true },
    SuperCsvHeaderNormal   = { bg = blend(title_fg, cursorline_bg, 0.12), fg = normal_fg, bold = true },
    SuperCsvHeaderActive   = { bg = blend(active_fg, cursorline_bg, 0.24), fg = active_fg, bold = true },
    SuperCsvHeaderFiltered = { bg = blend(ok_fg, cursorline_bg, 0.20), fg = ok_fg, bold = true },
    SuperCsvHeaderType     = { bg = surface_bg, fg = linenr_fg },

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

    SuperCsvBorder         = { fg = blend(muted_fg, base_bg, 0.60) },
    SuperCsvBorderPinned   = { fg = blend(float_border_fg, muted_fg, 0.55), bold = true },

    SuperCsvFooterSummary  = { bg = surface_bg, fg = info_fg, bold = true },
    SuperCsvFooterCell     = { bg = blend(cursorline_bg, surface_bg, 0.45), fg = blend(normal_fg, muted_fg, 0.35) },

    SuperCsvTypeNumber     = { fg = blend(num_fg, normal_fg, 0.65) },
    SuperCsvTypeBoolTrue   = { fg = ok_fg, bold = true },
    SuperCsvTypeBoolFalse  = { fg = err_fg, bold = true },
    SuperCsvTypeNull       = { fg = muted_fg, italic = true },

    SuperCsvHeatLow        = { bg = blend(ok_fg, base_bg, 0.16), fg = ok_fg },
    SuperCsvHeatMid        = { bg = blend(warn_fg, base_bg, 0.18), fg = warn_fg },
    SuperCsvHeatHigh       = { bg = blend(err_fg, base_bg, 0.22), fg = err_fg, bold = true },

    SuperCsvCommentBar     = { bg = blend(warn_fg, surface_bg, 0.12), fg = warn_fg, bold = true },
    SuperCsvComment        = { bg = surface_bg, fg = muted_fg, italic = true },
    SuperCsvCommentLineNr  = { bg = blend(info_fg, surface_bg, 0.10), fg = info_fg, bold = true },
  }

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
