local M = {}

local parser = require("super-csv.engine.parser")
local json_engine = require("super-csv.engine.json")

local is_list = vim.islist or vim.tbl_islist

local STYLES = {
  ascii = {
    top = { left = "+", mid = "+", right = "+", fill = "-" },
    header_sep = { left = "+", mid = "+", right = "+", fill = "-" },
    row_sep = nil,
    bot = { left = "+", mid = "+", right = "+", fill = "-" },
    vsep = "|",
    outer_vsep = true,
  },
  markdown = {
    top = nil,
    header_sep = nil, -- handled specially with alignment indicators
    row_sep = nil,
    bot = nil,
    vsep = "|",
    outer_vsep = true,
    is_markdown = true,
  },
  unicode = {
    top = { left = "┌", mid = "┬", right = "┐", fill = "─" },
    header_sep = { left = "├", mid = "┼", right = "┤", fill = "─" },
    row_sep = nil,
    bot = { left = "└", mid = "┴", right = "┘", fill = "─" },
    vsep = "│",
    outer_vsep = true,
  },
  rounded = {
    top = { left = "╭", mid = "┬", right = "╮", fill = "─" },
    header_sep = { left = "├", mid = "┼", right = "┤", fill = "─" },
    row_sep = nil,
    bot = { left = "╰", mid = "┴", right = "╯", fill = "─" },
    vsep = "│",
    outer_vsep = true,
  },
  grid = {
    top = { left = "+", mid = "+", right = "+", fill = "-" },
    header_sep = { left = "+", mid = "+", right = "+", fill = "=" },
    row_sep = { left = "+", mid = "+", right = "+", fill = "-" },
    bot = { left = "+", mid = "+", right = "+", fill = "-" },
    vsep = "|",
    outer_vsep = true,
  },
  simple = {
    top = nil,
    header_sep = nil, -- handled with spaced dashes
    row_sep = nil,
    bot = nil,
    vsep = "  ",
    outer_vsep = false,
    is_simple = true,
  },
}

--- Format cell value to clean single-line string
local function format_cell_value(val)
  if val == nil then
    return ""
  end
  if type(val) == "boolean" then
    return val and "true" or "false"
  end
  if type(val) == "table" then
    local ok, encoded = pcall(vim.fn.json_encode, val)
    if ok and encoded then
      return (encoded:gsub("[\r\n\t]", " "))
    end
    return "[table]"
  end
  local s = tostring(val)
  return (s:gsub("[\r\n\t]", " "))
end

--- Check if a column predominantly contains numbers
local function infer_column_numeric(rows, col_idx)
  local num_count = 0
  local sample_count = 0
  for r = 1, math.min(#rows, 100) do
    local v = rows[r] and rows[r][col_idx]
    if v ~= nil and v ~= "" then
      sample_count = sample_count + 1
      local clean = tostring(v):gsub("^[%$€£]", ""):gsub(",", "")
      if tonumber(clean) ~= nil then
        num_count = num_count + 1
      end
    end
  end
  return sample_count > 0 and (num_count / sample_count >= 0.7)
end

--- Build horizontal divider line given border spec and column widths
local function build_border_line(spec, widths, outer)
  local parts = {}
  if outer then
    table.insert(parts, spec.left)
  end
  for idx, w in ipairs(widths) do
    table.insert(parts, string.rep(spec.fill, w + 2))
    if idx < #widths then
      table.insert(parts, spec.mid)
    end
  end
  if outer then
    table.insert(parts, spec.right)
  end
  return table.concat(parts)
end

--- Fit string into column width with alignment and padding
local function pad_cell(str, width, align_right, max_w)
  str = tostring(str == nil and "" or str)
  local dw = vim.fn.strdisplaywidth(str)
  if max_w and dw > max_w then
    if max_w <= 1 then
      str = "…"
    else
      local cut = vim.fn.strcharpart(str, 0, max_w - 1)
      while vim.fn.strdisplaywidth(cut) > max_w - 1 and #cut > 0 do
        cut = vim.fn.strcharpart(cut, 0, vim.fn.strchars(cut) - 1)
      end
      str = cut .. "…"
    end
    dw = vim.fn.strdisplaywidth(str)
  end

  local pad = math.max(0, width - dw)
  if align_right then
    return string.rep(" ", pad) .. str
  else
    return str .. string.rep(" ", pad)
  end
end

--- Generate an ASCII/Markdown/Unicode table from normalized headers and rows
--- @param headers table List of header strings
--- @param rows table List of row arrays (each row is table of cell values)
--- @param opts table|nil Formatting options:
---   - style: "ascii"|"markdown"|"unicode"|"rounded"|"grid"|"simple" (default "ascii")
---   - max_col_width: number|nil Maximum width before cell truncation
---   - min_col_width: number|nil Minimum column width (default 3)
---   - max_rows: number|nil Maximum rows to include (nil = all)
---   - show_row_numbers: boolean Whether to include "#" line number column
---   - as_lines: boolean Return table of lines instead of joined string
function M.generate_table(headers, rows, opts)
  opts = opts or {}
  local style_key = (opts.style or "ascii"):lower()
  local style = STYLES[style_key] or STYLES.ascii
  headers = headers or {}
  rows = rows or {}

  local num_cols = #headers
  if num_cols == 0 and #rows > 0 and type(rows[1]) == "table" then
    num_cols = #rows[1]
    for c = 1, num_cols do
      headers[c] = "col_" .. c
    end
  end

  if num_cols == 0 then
    return opts.as_lines and { "(Empty Table)" } or "(Empty Table)"
  end

  -- Optionally inject row number column
  local eff_headers = vim.deepcopy(headers)
  local eff_rows = {}
  local show_row_num = opts.show_row_numbers == true

  if show_row_num then
    table.insert(eff_headers, 1, "#")
  end

  local max_rows = opts.max_rows or #rows
  local row_count = math.min(#rows, max_rows)

  for r = 1, row_count do
    local src_row = rows[r] or {}
    local r_copy = {}
    if show_row_num then
      table.insert(r_copy, tostring(r))
    end
    for c = 1, num_cols do
      local val = src_row[c]
      table.insert(r_copy, format_cell_value(val))
    end
    table.insert(eff_rows, r_copy)
  end

  local total_cols = #eff_headers
  local min_w = opts.min_col_width or 3
  local max_w = opts.max_col_width or nil

  -- Compute column widths & alignments
  local col_widths = {}
  local col_numeric = {}

  for c = 1, total_cols do
    local hw = vim.fn.strdisplaywidth(tostring(eff_headers[c] or ""))
    local mw = math.max(min_w, hw)
    local is_num = false
    if show_row_num and c == 1 then
      is_num = true
    else
      local data_col = show_row_num and (c - 1) or c
      is_num = infer_column_numeric(rows, data_col)
    end
    col_numeric[c] = is_num

    for r = 1, #eff_rows do
      local cv = tostring(eff_rows[r][c] or "")
      local dw = vim.fn.strdisplaywidth(cv)
      if dw > mw then
        mw = dw
      end
    end
    if max_w and mw > max_w then
      mw = max_w
    end
    col_widths[c] = mw
  end

  local lines = {}

  -- 1. Top border
  if style.top then
    table.insert(lines, build_border_line(style.top, col_widths, style.outer_vsep))
  end

  -- Helper to render a data row line
  local function render_row_line(cells, is_header)
    local parts = {}
    if style.outer_vsep then
      table.insert(parts, style.vsep)
    end
    for c = 1, total_cols do
      local val = tostring(cells[c] or "")
      if style.is_markdown then
        val = val:gsub("|", "\\|")
      end
      local align_right = not is_header and col_numeric[c]
      local formatted = pad_cell(val, col_widths[c], align_right, max_w)
      table.insert(parts, " " .. formatted .. " ")
      if c < total_cols or style.outer_vsep then
        table.insert(parts, style.vsep)
      end
    end
    return table.concat(parts)
  end

  -- 2. Header line
  table.insert(lines, render_row_line(eff_headers, true))

  -- 3. Header separator
  if style.is_markdown then
    local sep_parts = { "|" }
    for c = 1, total_cols do
      local w = col_widths[c]
      if col_numeric[c] then
        -- right aligned: " ---: |"
        local dashes = math.max(1, w - 1)
        table.insert(sep_parts, " " .. string.rep("-", dashes) .. ": |")
      else
        -- left aligned: " :--- |"
        local dashes = math.max(1, w - 1)
        table.insert(sep_parts, " :" .. string.rep("-", dashes) .. " |")
      end
    end
    table.insert(lines, table.concat(sep_parts))
  elseif style.is_simple then
    local sep_parts = {}
    for c = 1, total_cols do
      table.insert(sep_parts, string.rep("-", col_widths[c]))
    end
    table.insert(lines, table.concat(sep_parts, style.vsep))
  elseif style.header_sep then
    table.insert(lines, build_border_line(style.header_sep, col_widths, style.outer_vsep))
  end

  -- 4. Data rows
  for r = 1, #eff_rows do
    table.insert(lines, render_row_line(eff_rows[r], false))
    if style.row_sep and r < #eff_rows then
      table.insert(lines, build_border_line(style.row_sep, col_widths, style.outer_vsep))
    end
  end

  -- 5. Bottom border
  if style.bot then
    table.insert(lines, build_border_line(style.bot, col_widths, style.outer_vsep))
  end

  -- Optional Markdown fenced code block wrapper
  if opts.fence then
    local fence_lang = ""
    if type(opts.fence) == "string" and opts.fence ~= "" then
      fence_lang = opts.fence
    elseif style.is_markdown then
      fence_lang = "markdown"
    end
    table.insert(lines, 1, "```" .. fence_lang)
    table.insert(lines, "```")
  end

  if opts.as_lines then
    return lines
  end
  return table.concat(lines, "\n")
end

--- Generate ASCII table from CSV text or file path
--- @param csv_src string Path to CSV file or raw CSV string
--- @param opts table|nil Options passed to generate_table
function M.from_csv(csv_src, opts)
  opts = opts or {}
  local raw_lines = {}
  local is_file = (type(csv_src) == "string" and not csv_src:find("\n") and vim.fn.filereadable(csv_src) == 1)

  if is_file then
    local ok, file_lines = pcall(vim.fn.readfile, csv_src)
    if not ok or not file_lines then
      return nil, "Failed to read CSV file: " .. tostring(csv_src)
    end
    raw_lines = file_lines
  else
    for l in tostring(csv_src):gmatch("[^\r\n]+") do
      table.insert(raw_lines, l)
    end
  end

  if #raw_lines == 0 then
    return nil, "Empty CSV input"
  end

  -- Filter comments and find header line
  local cfg = require("super-csv.config")
  local comment_char = opts.comment_char or cfg.get_csv_comment_char()
  local data_lines = {}
  for _, line in ipairs(raw_lines) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not (comment_char ~= "" and trimmed:sub(1, #comment_char) == comment_char) then
      table.insert(data_lines, line)
    end
  end

  if #data_lines == 0 then
    return nil, "No tabular data found in CSV"
  end

  local sample_lines = {}
  for idx = 1, math.min(#data_lines, 10) do
    table.insert(sample_lines, data_lines[idx])
  end
  local delim = opts.delimiter or parser.detect_delimiter(table.concat(sample_lines, "\n"))
  local headers = parser.parse_line(data_lines[1], delim)
  local rows = {}
  local max_r = opts.max_rows or (#data_lines - 1)

  for i = 2, math.min(#data_lines, max_r + 1) do
    table.insert(rows, parser.parse_line(data_lines[i], delim))
  end

  return M.generate_table(headers, rows, opts)
end

--- Generate ASCII table from JSON / JSONC / JSONL / NDJSON text or file path
--- @param json_src string Path to JSON file or raw JSON string
--- @param opts table|nil Options passed to generate_table
function M.from_json(json_src, opts)
  opts = opts or {}
  local raw_text = ""
  local is_file = (type(json_src) == "string" and not json_src:find("\n") and vim.fn.filereadable(json_src) == 1)

  if is_file then
    local ok, file_lines = pcall(vim.fn.readfile, json_src)
    if not ok or not file_lines then
      return nil, "Failed to read JSON file: " .. tostring(json_src)
    end
    raw_text = table.concat(file_lines, "\n")
  else
    raw_text = tostring(json_src)
  end

  if vim.trim(raw_text) == "" then
    return nil, "Empty JSON input"
  end

  local parsed, err = json_engine.parse_json_text(raw_text, opts)
  if not parsed then
    return nil, err or "Failed to parse JSON into tabular format"
  end

  return M.generate_table(parsed.headers, parsed.rows, opts)
end

--- Generate ASCII table from an active SuperCsv session
--- @param session table SuperCsv session
--- @param opts table|nil Options
function M.from_session(session, opts)
  opts = opts or {}
  if not session or not session.headers then
    return nil, "Invalid session"
  end

  local scope = opts.scope or "all"
  local headers = {}
  local col_map = {}

  -- Determine which columns to include
  if scope == "visible" and session.vis_cols and #session.vis_cols > 0 then
    for _, vc in ipairs(session.vis_cols) do
      table.insert(headers, session.headers[vc.col] or ("col_" .. vc.col))
      table.insert(col_map, vc.col)
    end
  else
    for c = 1, session.num_cols do
      if not (session.hidden_cols and session.hidden_cols[c]) then
        table.insert(headers, session.headers[c] or ("col_" .. c))
        table.insert(col_map, c)
      end
    end
  end

  local rows = {}
  local sqlite = require("super-csv.engine.sqlite")

  if scope == "visible" and session.visible_rows then
    for _, ro in ipairs(session.visible_rows) do
      local r_cells = {}
      for _, c in ipairs(col_map) do
        table.insert(r_cells, ro.cells[c] or "")
      end
      table.insert(rows, r_cells)
    end
  elseif session.sqlite_ready and session.db then
    local limit = opts.max_rows or opts.limit or 200
    local where_clauses = {}
    if session.filters then
      for c, f in pairs(session.filters) do
        local col_name = string.format('"c%d"', c)
        if f.values then
          local vals = {}
          for v, _ in pairs(f.values) do
            table.insert(vals, string.format("'%s'", tostring(v):gsub("'", "''")))
          end
          if #vals > 0 then
            table.insert(where_clauses, string.format("%s IN (%s)", col_name, table.concat(vals, ", ")))
          end
        elseif f.op and f.val ~= nil then
          table.insert(where_clauses, string.format("%s %s '%s'", col_name, f.op, tostring(f.val):gsub("'", "''")))
        end
      end
    end
    if session.grep_pattern and session.grep_pattern ~= "" then
      local parts = {}
      for c = 1, session.num_cols do
        table.insert(parts, string.format('"c%d" LIKE \'%%%s%%\'', c, session.grep_pattern:gsub("'", "''")))
      end
      table.insert(where_clauses, "(" .. table.concat(parts, " OR ") .. ")")
    end

    local where_str = #where_clauses > 0 and (" WHERE " .. table.concat(where_clauses, " AND ")) or ""
    local order_str = ""
    if session.sort and session.sort.col_idx then
      order_str = string.format(' ORDER BY "c%d" %s', session.sort.col_idx, session.sort.dir or "ASC")
    else
      order_str = " ORDER BY rowid ASC"
    end

    local sql = string.format("SELECT * FROM csv_data%s%s LIMIT %d;", where_str, order_str, limit)
    local ok, res = pcall(sqlite.query, session.db, sql)
    if ok and type(res) == "table" then
      local res_rows = (res.rows and type(res.rows) == "table") and res.rows or res
      for _, ro in ipairs(res_rows) do
        local r_cells = {}
        for _, c in ipairs(col_map) do
          table.insert(r_cells, ro[c] or "")
        end
        table.insert(rows, r_cells)
      end
    end
  else
    -- Fall back to preview_rows
    local p_rows = session.preview_rows or {}
    local limit = opts.max_rows or opts.limit or #p_rows
    for r = 1, math.min(#p_rows, limit) do
      local r_cells = {}
      for _, c in ipairs(col_map) do
        table.insert(r_cells, p_rows[r][c] or "")
      end
      table.insert(rows, r_cells)
    end
  end

  return M.generate_table(headers, rows, opts)
end

--- Unified Dispatcher: Convert CSV, JSON, session, or Lua tables to ASCII table
--- @param source any Session table, file path, string (CSV or JSON), or { headers, rows }
--- @param opts table|nil Formatting options
function M.to_ascii(source, opts)
  opts = opts or {}

  -- 1. Active session or explicit session passed
  if type(source) == "table" and source.num_cols and source.headers then
    return M.from_session(source, opts)
  end

  -- 2. Lua table with headers and rows
  if type(source) == "table" and (source.headers or source.rows) then
    return M.generate_table(source.headers or {}, source.rows or {}, opts)
  end

  -- 3. Array of objects: [ { a = 1, b = 2 }, { a = 3, b = 4 } ]
  if type(source) == "table" and is_list(source) and type(source[1]) == "table" then
    local enc = vim.fn.json_encode(source)
    return M.from_json(enc, opts)
  end

  -- 3b. Buffer number passed
  if type(source) == "number" and vim.api.nvim_buf_is_valid(source) then
    local bname = vim.api.nvim_buf_get_name(source)
    local lines = vim.api.nvim_buf_get_lines(source, 0, -1, false)
    local text = table.concat(lines, "\n")
    local ft = vim.bo[source].filetype
    if json_engine.is_json_path(bname) or ft == "json" or ft == "jsonc" or ft == "jsonl" or ft == "ndjson" or text:match("^%s*[%[{]") then
      return M.from_json(text, opts)
    else
      return M.from_csv(text, opts)
    end
  end

  -- 4. String or file path
  if type(source) == "string" then
    local trimmed = vim.trim(source)
    -- Check if it's a JSON file path
    if json_engine.is_json_path(source) and vim.fn.filereadable(source) == 1 then
      return M.from_json(source, opts)
    end
    -- Check if it's a CSV file path
    if (source:match("%.csv$") or source:match("%.tsv$")) and vim.fn.filereadable(source) == 1 then
      return M.from_csv(source, opts)
    end
    -- Check if it's raw JSON content
    if trimmed:sub(1, 1) == "{" or trimmed:sub(1, 1) == "[" then
      return M.from_json(trimmed, opts)
    end
    -- Default to raw CSV content
    return M.from_csv(source, opts)
  end

  -- 5. No source provided: use currently active session
  local active = require("super-csv").get_active_session()
  if active then
    return M.from_session(active, opts)
  end

  return nil, "No valid source (session, file, or data) provided"
end

--- Save generated ASCII/Markdown/Unicode table directly to a file
--- @param source any Session, buffer number, file path, string, or table
--- @param filepath string Output destination path
--- @param opts table|nil Formatting options
function M.save_to_file(source, filepath, opts)
  opts = opts or {}
  if not filepath or vim.trim(filepath) == "" then
    return false, "Missing destination file path"
  end
  local text, err = M.to_ascii(source, opts)
  if not text then
    return false, err or "Failed to generate table"
  end
  local lines = vim.split(text, "\n")
  local full_path = vim.fn.fnamemodify(filepath, ":p")
  local ok, write_err = pcall(vim.fn.writefile, lines, full_path)
  if not ok then
    return false, "Failed to write file: " .. tostring(write_err)
  end
  return true, full_path, #lines
end

return M
