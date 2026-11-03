local M = {}

function M.setup()
  local is_light = (vim.o.background == "light")
  local groups = is_light and {
    SuperCsvHeaderBanner   = { bg = "#0f172a", fg = "#f8fafc", bold = true },
    SuperCsvHeaderPinned   = { bg = "#1e3a8a", fg = "#ffffff", bold = true },
    SuperCsvHeaderNormal   = { bg = "#1d4ed8", fg = "#f8fafc", bold = true },
    SuperCsvHeaderActive   = { bg = "#ea580c", fg = "#ffffff", bold = true, underline = true },
    SuperCsvHeaderFiltered = { bg = "#047857", fg = "#ecfdf5", bold = true },
    SuperCsvHeaderType     = { bg = "#dbeafe", fg = "#1e40af", italic = true },
    SuperCsvColOdd         = { bg = "#ffffff", fg = "#0f172a" },
    SuperCsvColEven        = { bg = "#f1f5f9", fg = "#0f172a" },
    SuperCsvColPinned      = { bg = "#e0e7ff", fg = "#1e1b4b", bold = true },
    SuperCsvCursorRow      = { bg = "#fef3c7", fg = "#0f172a" },
    SuperCsvCursorCell     = { bg = "#f59e0b", fg = "#0f172a", bold = true },
    SuperCsvCellModified   = { bg = "#fce7f3", fg = "#9d174d", bold = true },
    SuperCsvCellMatch      = { bg = "#fef08a", fg = "#713f12", bold = true },
    SuperCsvBorder         = { fg = "#94a3b8" },
    SuperCsvBorderPinned   = { fg = "#2563eb", bold = true },
    SuperCsvFooterSummary  = { bg = "#0f172a", fg = "#38bdf8", bold = true },
    SuperCsvFooterCell     = { bg = "#1e293b", fg = "#e2e8f0" },
    SuperCsvTypeNumber     = { fg = "#b45309" },
    SuperCsvTypeBoolTrue   = { fg = "#15803d", bold = true },
    SuperCsvTypeBoolFalse  = { fg = "#b91c1c", bold = true },
    SuperCsvTypeNull       = { fg = "#94a3b8", italic = true },
    SuperCsvHeatLow        = { bg = "#dcfce7", fg = "#14532d" },
    SuperCsvHeatMid        = { bg = "#fef9c3", fg = "#713f12" },
    SuperCsvHeatHigh       = { bg = "#fee2e2", fg = "#7f1d1d", bold = true },
  } or {
    SuperCsvHeaderBanner   = { bg = "#0f172a", fg = "#38bdf8", bold = true },
    SuperCsvHeaderPinned   = { bg = "#172554", fg = "#93c5fd", bold = true },
    SuperCsvHeaderNormal   = { bg = "#1e3a5f", fg = "#f8fafc", bold = true },
    SuperCsvHeaderActive   = { bg = "#2563eb", fg = "#ffffff", bold = true, underline = true },
    SuperCsvHeaderFiltered = { bg = "#065f46", fg = "#6ee7b7", bold = true },
    SuperCsvHeaderType     = { bg = "#172033", fg = "#94a3b8", italic = true },
    SuperCsvColOdd         = { bg = "#111827", fg = "#e2e8f0" },
    SuperCsvColEven        = { bg = "#1a2436", fg = "#e2e8f0" },
    SuperCsvColPinned      = { bg = "#162038", fg = "#bae6fd", bold = true },
    SuperCsvCursorRow      = { bg = "#26334d", fg = "#ffffff" },
    SuperCsvCursorCell     = { bg = "#f59e0b", fg = "#090d16", bold = true },
    SuperCsvCellModified   = { bg = "#4c1d3d", fg = "#f9a8d4", bold = true },
    SuperCsvCellMatch      = { bg = "#713f12", fg = "#fde047", bold = true },
    SuperCsvBorder         = { fg = "#334155" },
    SuperCsvBorderPinned   = { fg = "#38bdf8", bold = true },
    SuperCsvFooterSummary  = { bg = "#0b1324", fg = "#38bdf8", bold = true },
    SuperCsvFooterCell     = { bg = "#151f32", fg = "#cbd5e1" },
    SuperCsvTypeNumber     = { fg = "#fbbf24" },
    SuperCsvTypeBoolTrue   = { fg = "#34d399", bold = true },
    SuperCsvTypeBoolFalse  = { fg = "#f87171", bold = true },
    SuperCsvTypeNull       = { fg = "#64748b", italic = true },
    SuperCsvHeatLow        = { bg = "#132a1e", fg = "#86efac" },
    SuperCsvHeatMid        = { bg = "#3b2f13", fg = "#fde047" },
    SuperCsvHeatHigh       = { bg = "#451a1a", fg = "#fca5a5", bold = true },
  }

  for name, spec in pairs(groups) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

return M
