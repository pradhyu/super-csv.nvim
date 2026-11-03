local M = {}

local state_file = vim.fn.stdpath("state") .. "/super-csv-prefs.json"

M.defaults = {
  enabled = true,            -- Master switch for super-csv
  auto_open = true,          -- Automatically open Excel 2D viewport on .csv/.tsv files
  freeze_cols = 1,           -- Number of left-most columns frozen by default (like Excel Freeze Panes)
  min_col_width = 10,        -- Minimum column display width
  max_col_width = 28,        -- Maximum column display width before truncation with …
  zebra_columns = true,      -- Alternating background colors for even/odd columns
  zebra_rows = true,         -- Alternating background colors for even/odd rows (Excel banded rows)
  show_footer_stats = true,  -- Show Excel-style COUNT / SUM / AVG / MIN / MAX bar at bottom
  heatmap = false,           -- Conditional numeric heatmap coloring (toggle with gm)
  sqlite_backend = true,     -- Back CSV with SQLite + LuaJIT FFI for 1M-row speed
  batch_size = 500,          -- Number of rows loaded per batch when scrolling
  lazy_sqlite = true,        -- Don't index huge files upfront; load in batches and index on demand
  cache_dir = string.format("/tmp/super-csv-%d", vim.uv.getuid and vim.uv.getuid() or 1000),
}

M.options = vim.deepcopy(M.defaults)

function M.load_persisted()
  if vim.fn.filereadable(state_file) == 1 then
    local ok, lines = pcall(vim.fn.readfile, state_file)
    if ok and lines and #lines > 0 then
      local ok_j, data = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
      if ok_j and type(data) == "table" then
        if data.zebra_rows ~= nil then M.options.zebra_rows = data.zebra_rows end
        if data.zebra_columns ~= nil then M.options.zebra_columns = data.zebra_columns end
        if data.heatmap ~= nil then M.options.heatmap = data.heatmap end
      end
    end
  end
end

function M.save_persisted()
  local data = {
    zebra_rows = M.options.zebra_rows,
    zebra_columns = M.options.zebra_columns,
    heatmap = M.options.heatmap,
  }
  pcall(vim.fn.writefile, { vim.fn.json_encode(data) }, state_file)
end

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  M.load_persisted()
  vim.fn.mkdir(M.options.cache_dir, "p")
end

return M
