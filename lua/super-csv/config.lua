local M = {}

local state_file = vim.fn.stdpath("state") .. "/super-csv-prefs.json"

M.defaults = {
  enabled = true,            -- Master switch for super-csv
  auto_open = true,          -- Automatically open Excel 2D viewport on .csv/.tsv files
  auto_open_json = false,    -- Automatically open Excel 2D viewport on .json/.jsonc/.jsonl/.ndjson files
  freeze_cols = 1,           -- Number of left-most columns frozen by default (like Excel Freeze Panes)
  min_col_width = 10,        -- Minimum column display width
  max_col_width = 28,        -- Maximum column display width before truncation with …
  rainbow_columns = true,    -- Rainbow CSV per-column foreground colors from active Neovim theme (toggle with gr)
  zebra_columns = false,     -- Alternating background colors for even/odd columns
  zebra_rows = true,         -- Subtle alternating background colors for even/odd rows (Excel banded rows)
  border_style = "heavy",    -- Viewport grid border style: "heavy" (default), "ascii", "single", "rounded"
  show_footer_stats = true,  -- Show Excel-style COUNT / SUM / AVG / MIN / MAX bar at bottom
  heatmap = false,           -- Conditional numeric heatmap coloring (toggle with gm)
  comment_char = "#",        -- Default comment prefix for CSV/TSV files (e.g. "#", "//", ";")
  json_comment_char = "//",  -- Default comment prefix for JSON/JSONC/JSONL files (e.g. "//", "#")
  comments = {               -- Structured comment prefix config (synced with comment_char & json_comment_char)
    csv = "#",
    json = "//",
  },
  comments_collapsed = true, -- Collapse comments at the top of the viewport by default
  sqlite_backend = true,     -- Back CSV with SQLite + LuaJIT FFI for 1M-row speed
  batch_size = 500,          -- Number of rows loaded per batch when scrolling
  lazy_sqlite = true,        -- Don't index huge files upfront; load in batches and index on demand
  cache_dir = string.format("/tmp/super-csv-%d", vim.uv.getuid and vim.uv.getuid() or 1000),
}

M.options = vim.deepcopy(M.defaults)

function M.get_csv_comment_char()
  if M.options.comment_char ~= nil then
    return M.options.comment_char
  end
  if type(M.options.comments) == "table" and M.options.comments.csv ~= nil then
    return M.options.comments.csv
  end
  return "#"
end

function M.get_json_comment_char()
  if M.options.json_comment_char ~= nil then
    return M.options.json_comment_char
  end
  if type(M.options.comments) == "table" and M.options.comments.json ~= nil then
    return M.options.comments.json
  end
  return "//"
end

function M.get_border_style()
  return M.options.border_style or "heavy"
end

function M.load_persisted()
  if vim.fn.filereadable(state_file) == 1 then
    local ok, lines = pcall(vim.fn.readfile, state_file)
    if ok and lines and #lines > 0 then
      local ok_j, data = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
      if ok_j and type(data) == "table" and data.rainbow_columns ~= nil then
        M.options.rainbow_columns = data.rainbow_columns
        if data.zebra_rows ~= nil then M.options.zebra_rows = data.zebra_rows end
        if data.zebra_columns ~= nil then M.options.zebra_columns = data.zebra_columns end
        if data.heatmap ~= nil then M.options.heatmap = data.heatmap end
        if data.border_style ~= nil then M.options.border_style = data.border_style end
      end
    end
  end
end

function M.save_persisted()
  local data = {
    rainbow_columns = M.options.rainbow_columns,
    zebra_rows = M.options.zebra_rows,
    zebra_columns = M.options.zebra_columns,
    heatmap = M.options.heatmap,
    border_style = M.options.border_style,
  }
  pcall(vim.fn.writefile, { vim.fn.json_encode(data) }, state_file)
end

function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- Synchronize `comments = { csv = ..., json = ... }` and `comment_char` / `json_comment_char`
  if type(opts.comments) == "table" then
    if opts.comments.csv ~= nil and opts.comment_char == nil then
      M.options.comment_char = opts.comments.csv
    end
    if opts.comments.json ~= nil and opts.json_comment_char == nil then
      M.options.json_comment_char = opts.comments.json
    end
  end
  M.options.comments = M.options.comments or {}
  M.options.comments.csv = M.options.comment_char
  M.options.comments.json = M.options.json_comment_char

  M.load_persisted()
  vim.fn.mkdir(M.options.cache_dir, "p")
end

return M
