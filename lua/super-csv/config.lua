local M = {}

M.defaults = {
  auto_open = true,          -- Automatically open Excel 2D viewport on .csv/.tsv files
  freeze_cols = 1,           -- Number of left-most columns frozen by default (like Excel Freeze Panes)
  min_col_width = 10,        -- Minimum column display width
  max_col_width = 28,        -- Maximum column display width before truncation with …
  zebra_columns = true,      -- Alternating background colors for even/odd columns
  zebra_rows = false,        -- Optional alternating row striping
  show_footer_stats = true,  -- Show Excel-style COUNT / SUM / AVG / MIN / MAX bar at bottom
  heatmap = false,           -- Conditional numeric heatmap coloring (toggle with gm)
  sqlite_backend = true,     -- Back CSV with SQLite + LuaJIT FFI for 1M-row speed
  cache_dir = string.format("/tmp/super-csv-%d", vim.uv.getuid and vim.uv.getuid() or 1000),
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  vim.fn.mkdir(M.options.cache_dir, "p")
end

return M
