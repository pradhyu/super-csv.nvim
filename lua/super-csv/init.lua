local M = {}

local config = require("super-csv.config")
local highlights = require("super-csv.highlights")
local parser = require("super-csv.engine.parser")
local sqlite = require("super-csv.engine.sqlite")
local viewport = require("super-csv.ui.viewport")
local modals = require("super-csv.ui.modals")

-- Map of view_buf -> session and filepath -> session
M.sessions_by_buf = {}
M.sessions_by_path = {}
M.disabled_paths = {} -- Tracks files toggled back to normal raw CSV mode

function M.get_active_session()
  local cur_buf = vim.api.nvim_get_current_buf()
  if M.sessions_by_buf[cur_buf] then
    return M.sessions_by_buf[cur_buf]
  end
  local path = vim.api.nvim_buf_get_name(cur_buf)
  if path ~= "" and M.sessions_by_path[path] then
    return M.sessions_by_path[path]
  end
  return nil
end

--- Move active column left or right, skipping hidden columns
local function step_col(session, delta)
  local c = session.cur_col
  local target = c + delta
  while target >= 1 and target <= session.num_cols and session.hidden_cols[target] do
    target = target + (delta > 0 and 1 or -1)
  end
  if target >= 1 and target <= session.num_cols then
    session.cur_col = target
  end
  viewport.render(session)
end

--- Bind all spreadsheet navigation, filter, grep, analytics, and editor keymaps on view_buf
local function attach_keymaps(session)
  local buf = session.view_buf
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = "SuperCsv: " .. desc })
  end

  -- 1. Horizontal Column Navigation (across 100+ columns)
  map("l", function() step_col(session, 1) end, "Next Column")
  map("<Right>", function() step_col(session, 1) end, "Next Column")
  map("<Tab>", function() step_col(session, 1) end, "Next Column")
  map("h", function() step_col(session, -1) end, "Previous Column")
  map("<Left>", function() step_col(session, -1) end, "Previous Column")
  map("<S-Tab>", function() step_col(session, -1) end, "Previous Column")

  map("L", function()
    local jump = math.max(3, #(session.vis_cols or {}) - 2)
    session.cur_col = math.min(session.num_cols, session.cur_col + jump)
    session.left_col = math.min(session.num_cols, session.left_col + jump)
    viewport.render(session)
  end, "Page Right Columns")

  map("H", function()
    local jump = math.max(3, #(session.vis_cols or {}) - 2)
    session.cur_col = math.max(1, session.cur_col - jump)
    session.left_col = math.max(1, session.left_col - jump)
    viewport.render(session)
  end, "Page Left Columns")

  map("0", function()
    session.cur_col = 1
    session.left_col = 1
    viewport.render(session)
  end, "First Column (A #1)")

  map("$", function()
    session.cur_col = session.num_cols
    viewport.render(session)
  end, "Last Column")

  -- 2. Vertical Row Navigation (across 1,000,000+ rows)
  map("j", function()
    local count = vim.v.count1
    local max_r = session.filtered_rows or session.total_rows or 1
    session.cur_row = math.min(max_r, session.cur_row + count)
    viewport.render(session)
  end, "Next Row")

  map("<Down>", function()
    local max_r = session.filtered_rows or session.total_rows or 1
    session.cur_row = math.min(max_r, session.cur_row + vim.v.count1)
    viewport.render(session)
  end, "Next Row")

  map("k", function()
    session.cur_row = math.max(1, session.cur_row - vim.v.count1)
    viewport.render(session)
  end, "Previous Row")

  map("<Up>", function()
    session.cur_row = math.max(1, session.cur_row - vim.v.count1)
    viewport.render(session)
  end, "Previous Row")

  map("<C-d>", function()
    local half = math.max(5, math.floor((session.page_size or 30) / 2))
    local max_r = session.filtered_rows or session.total_rows or 1
    session.cur_row = math.min(max_r, session.cur_row + half)
    session.top_row = math.min(math.max(1, max_r - (session.page_size or 30) + 1), session.top_row + half)
    viewport.render(session)
  end, "Half-Page Down")

  map("<C-u>", function()
    local half = math.max(5, math.floor((session.page_size or 30) / 2))
    session.cur_row = math.max(1, session.cur_row - half)
    session.top_row = math.max(1, session.top_row - half)
    viewport.render(session)
  end, "Half-Page Up")

  map("<PageDown>", function()
    local pg = session.page_size or 30
    local max_r = session.filtered_rows or session.total_rows or 1
    session.cur_row = math.min(max_r, session.cur_row + pg)
    session.top_row = math.min(math.max(1, max_r - pg + 1), session.top_row + pg)
    viewport.render(session)
  end, "Page Down")

  map("<PageUp>", function()
    local pg = session.page_size or 30
    session.cur_row = math.max(1, session.cur_row - pg)
    session.top_row = math.max(1, session.top_row - pg)
    viewport.render(session)
  end, "Page Up")

  map("<C-f>", function()
    local pg = session.page_size or 30
    local max_r = session.filtered_rows or session.total_rows or 1
    session.cur_row = math.min(max_r, session.cur_row + pg)
    session.top_row = math.min(math.max(1, max_r - pg + 1), session.top_row + pg)
    viewport.render(session)
  end, "Page Down (<C-f>)")

  map("<C-b>", function()
    local pg = session.page_size or 30
    session.cur_row = math.max(1, session.cur_row - pg)
    session.top_row = math.max(1, session.top_row - pg)
    viewport.render(session)
  end, "Page Up (<C-b>)")

  map("<C-e>", function()
    local max_r = session.filtered_rows or session.total_rows or 1
    local step = vim.v.count1
    session.top_row = math.min(math.max(1, max_r - (session.page_size or 30) + 1), session.top_row + step)
    if session.cur_row < session.top_row then
      session.cur_row = session.top_row
    end
    viewport.render(session)
  end, "Scroll Viewport Down (<C-e>)")

  map("<C-y>", function()
    local step = vim.v.count1
    session.top_row = math.max(1, session.top_row - step)
    local bot_row = session.top_row + (session.page_size or 30) - 1
    if session.cur_row > bot_row then
      session.cur_row = bot_row
    end
    viewport.render(session)
  end, "Scroll Viewport Up (<C-y>)")

  map("gg", function()
    local target = (vim.v.count > 0) and vim.v.count or 1
    local max_r = session.filtered_rows or session.total_rows or 1
    session.cur_row = math.max(1, math.min(max_r, target))
    session.top_row = session.cur_row
    viewport.render(session)
  end, "First Row (or [count]gg)")

  map("G", function()
    local max_r = session.filtered_rows or session.total_rows or 1
    if vim.v.count > 0 then
      session.cur_row = math.max(1, math.min(max_r, vim.v.count))
    else
      session.cur_row = max_r
    end
    viewport.render(session)
  end, "Last Row (or [count]G)")

  map("gG", function()
    vim.ui.input({ prompt = string.format("Go to Row (1 .. %d): ", session.filtered_rows or session.total_rows or 1) }, function(inp)
      local n = tonumber(inp)
      if n then
        local max_r = session.filtered_rows or session.total_rows or 1
        session.cur_row = math.max(1, math.min(max_r, math.floor(n)))
        session.top_row = math.max(1, session.cur_row - 5)
        viewport.render(session)
      end
    end)
  end, "Prompt Go to Row Number")

  -- Mouse scroll support
  map("<ScrollWheelDown>", function()
    local max_r = session.filtered_rows or session.total_rows or 1
    session.cur_row = math.min(max_r, session.cur_row + 3)
    session.top_row = math.min(math.max(1, max_r - (session.page_size or 30) + 1), session.top_row + 3)
    viewport.render(session)
  end, "Scroll Down")

  map("<ScrollWheelUp>", function()
    session.cur_row = math.max(1, session.cur_row - 3)
    session.top_row = math.max(1, session.top_row - 3)
    viewport.render(session)
  end, "Scroll Up")

  map("<ScrollWheelRight>", function()
    step_col(session, 2)
  end, "Scroll Right Columns")

  map("<ScrollWheelLeft>", function()
    step_col(session, -2)
  end, "Scroll Left Columns")

  -- Mouse click to select cell or header column without moving topline
  local function resolve_clicked_col(screen_col)
    local x = 8 -- After "│  ROW #│"
    for _, vc in ipairs(session.vis_cols or {}) do
      local w = (session.col_widths[vc.col] or 14) + 3
      if screen_col <= x + w then
        return vc.col
      end
      x = x + w
    end
    if session.vis_cols and #session.vis_cols > 0 then
      return session.vis_cols[#session.vis_cols].col
    end
    return session.cur_col
  end

  map("<LeftMouse>", function()
    local mp = vim.fn.getmousepos()
    if mp and mp.winid == session.view_win then
      local clicked_col = resolve_clicked_col(mp.wincol)
      if clicked_col then
        session.cur_col = clicked_col
      end
      if mp.line >= 6 and session.visible_rows then
        local row_idx = mp.line - 5
        if row_idx >= 1 and row_idx <= #session.visible_rows then
          session.cur_row = session.top_row + row_idx - 1
        end
      end
      viewport.render(session)
    end
  end, "Select Cell / Column with Mouse")

  map("<2-LeftMouse>", function()
    local mp = vim.fn.getmousepos()
    if mp and mp.winid == session.view_win then
      local clicked_col = resolve_clicked_col(mp.wincol)
      if clicked_col then
        session.cur_col = clicked_col
      end
      if mp.line == 3 or mp.line == 4 then
        modals.open_autofilter(session, session.cur_col)
      elseif mp.line >= 6 and session.visible_rows then
        local row_idx = mp.line - 5
        if row_idx >= 1 and row_idx <= #session.visible_rows then
          session.cur_row = session.top_row + row_idx - 1
          viewport.render(session)
          local row_obj = session.visible_rows[row_idx]
          if row_obj then
            local c = session.cur_col
            local old_val = row_obj.cells[c] or ""
            vim.ui.input({
              prompt = string.format("Edit Cell [%s%d] (%s): ", parser.col_to_excel(c), row_obj.rowid, session.headers[c]),
              default = old_val,
            }, function(new_val)
              if new_val ~= nil and new_val ~= old_val then
                sqlite.update_cell(session, row_obj.rowid, c, new_val, true)
                viewport.render(session)
              end
            end)
          end
        end
      end
    end
  end, "Double-Click Header to Filter or Cell to Edit")

  -- 3. Excel AutoFilter, Quick Value Filter, Grep, Sort
  map("f", function()
    modals.open_autofilter(session, session.cur_col)
  end, "Open Excel AutoFilter for Current Column")

  map("fv", function()
    local row_obj = session.visible_rows and session.visible_rows[session.cur_row - session.top_row + 1]
    if row_obj then
      local val = row_obj.cells[session.cur_col] or ""
      session.filters[session.cur_col] = { values = { [val] = true } }
      session.cached_where_sig = nil
      session.cur_row = 1
      session.top_row = 1
      viewport.render(session)
      vim.notify(string.format("[SuperCsv] Filtered %s == %s", session.headers[session.cur_col], vim.inspect(val)))
    end
  end, "Filter Column == Active Cell Value")

  map("fx", function()
    local row_obj = session.visible_rows and session.visible_rows[session.cur_row - session.top_row + 1]
    if row_obj then
      local val = row_obj.cells[session.cur_col] or ""
      session.filters[session.cur_col] = { op = "!=", val = val }
      session.cached_where_sig = nil
      session.cur_row = 1
      session.top_row = 1
      viewport.render(session)
      vim.notify(string.format("[SuperCsv] Excluded %s != %s", session.headers[session.cur_col], vim.inspect(val)))
    end
  end, "Exclude Active Cell Value")

  map("F", function()
    if session.filters[session.cur_col] then
      session.filters[session.cur_col] = nil
      session.cached_where_sig = nil
      session.cur_row = 1
      session.top_row = 1
      viewport.render(session)
      vim.notify(string.format("[SuperCsv] Cleared filter on %s", session.headers[session.cur_col]))
    else
      session.filters = {}
      session.grep_pattern = nil
      session.cached_where_sig = nil
      session.cur_row = 1
      session.top_row = 1
      viewport.render(session)
      vim.notify("[SuperCsv] Cleared all filters and grep")
    end
  end, "Clear Column Filter (or All Filters)")

  map("<leader>cF", function()
    session.filters = {}
    session.grep_pattern = nil
    session.cached_where_sig = nil
    session.cur_row = 1
    session.top_row = 1
    viewport.render(session)
    vim.notify("[SuperCsv] All filters and grep cleared")
  end, "Clear All Filters")

  map("g/", function()
    vim.ui.input({
      prompt = "SuperCsv Grep Across All Columns (empty to clear): ",
      default = session.grep_pattern or "",
    }, function(inp)
      if inp ~= nil then
        session.grep_pattern = vim.trim(inp)
        session.cached_where_sig = nil
        session.cur_row = 1
        session.top_row = 1
        viewport.render(session)
      end
    end)
  end, "Grep Rows Across All Columns")

  map("/", function()
    local cname = session.headers[session.cur_col] or "col"
    vim.ui.input({
      prompt = string.format("Filter column '%s' (e.g. > 500, = US, contains prod): ", cname),
    }, function(inp)
      if inp and vim.trim(inp) ~= "" then
        M.apply_filter_expr(session, session.cur_col, vim.trim(inp))
      end
    end)
  end, "Filter Current Column by Expression")

  map("s", function()
    session.sort = { col_idx = session.cur_col, dir = "ASC" }
    session.cur_row = 1
    session.top_row = 1
    viewport.render(session)
  end, "Sort Column Ascending ▲")

  map("S", function()
    session.sort = { col_idx = session.cur_col, dir = "DESC" }
    session.cur_row = 1
    session.top_row = 1
    viewport.render(session)
  end, "Sort Column Descending ▼")

  -- 4. Counts, Value Frequencies, Column Analytics & SQL
  map("gv", function()
    modals.open_value_counts(session, session.cur_col)
  end, "Value Counts / Frequency Breakdown")

  map("gs", function()
    modals.open_column_stats(session, session.cur_col)
  end, "Column Summary Statistics & Distribution")

  map("gc", function()
    modals.open_column_jumper(session)
  end, "100-Column Fuzzy Jumper & Manager")

  map("<leader>cc", function()
    modals.open_column_jumper(session)
  end, "100-Column Fuzzy Jumper & Manager")

  map("K", function()
    modals.toggle_record_card(session)
  end, "Toggle 100-Column Vertical Record Card")

  map("<leader>cr", function()
    modals.toggle_record_card(session)
  end, "Toggle 100-Column Vertical Record Card")

  map("gq", function()
    modals.open_sql_runner(session)
  end, "Run SQL Query on CSV")

  map("<leader>cq", function()
    modals.open_sql_runner(session)
  end, "Run SQL Query on CSV")

  -- 5. Pinning (Freeze Panes), Hiding, Width & Heatmap
  map("gp", function()
    local c = session.cur_col
    session.pinned_cols[c] = not session.pinned_cols[c]
    viewport.render(session)
    vim.notify(string.format("[SuperCsv] Column %s #%d (%s) %s",
      parser.col_to_excel(c), c, session.headers[c],
      session.pinned_cols[c] and "Pinned 🔒" or "Unpinned"))
  end, "Toggle Pin/Freeze Current Column")

  map("gh", function()
    if session.num_cols > 1 then
      session.hidden_cols[session.cur_col] = true
      step_col(session, 1)
    end
  end, "Hide Current Column")

  map("gH", function()
    session.hidden_cols = {}
    viewport.render(session)
    vim.notify("[SuperCsv] All hidden columns restored")
  end, "Restore All Hidden Columns")

  map("gm", function()
    local cfg = require("super-csv.config")
    cfg.options.heatmap = not cfg.options.heatmap
    cfg.save_persisted()
    require("super-csv.ui.viewport").render(session)
    vim.notify("[SuperCsv] Numeric Heatmap: " .. (cfg.options.heatmap and "ON" or "OFF"))
  end, "Toggle Numeric Heatmap")

  map("gr", function()
    local cfg = require("super-csv.config")
    cfg.options.zebra_rows = not cfg.options.zebra_rows
    cfg.save_persisted()
    require("super-csv.ui.viewport").render(session)
    vim.notify("[SuperCsv] Alternating Row Colors (Zebra Rows): " .. (cfg.options.zebra_rows and "ON (saved)" or "OFF (saved)"))
  end, "Toggle Alternating Row Colors")

  map("gz", function()
    local cfg = require("super-csv.config")
    cfg.options.zebra_columns = not cfg.options.zebra_columns
    cfg.save_persisted()
    require("super-csv.ui.viewport").render(session)
    vim.notify("[SuperCsv] Alternating Column Colors (Zebra Cols): " .. (cfg.options.zebra_columns and "ON (saved)" or "OFF (saved)"))
  end, "Toggle Alternating Column Colors")

  map("<leader>cv", function()
    M.switch_to_normal_csv(session)
  end, "Switch Back to Normal Raw CSV Buffer")

  map("+", function()
    local c = session.cur_col
    session.col_widths[c] = math.min(80, (session.col_widths[c] or 14) + 4)
    viewport.render(session)
  end, "Widen Current Column")

  map("-", function()
    local c = session.cur_col
    session.col_widths[c] = math.max(6, (session.col_widths[c] or 14) - 4)
    viewport.render(session)
  end, "Narrow Current Column")

  map("=", function()
    local c = session.cur_col
    local max_w = #session.headers[c] + 4
    for _, r in ipairs(session.visible_rows or {}) do
      local v = r.cells[c] or ""
      if #v + 2 > max_w then max_w = #v + 2 end
    end
    session.col_widths[c] = math.min(60, math.max(8, max_w))
    viewport.render(session)
  end, "Auto-Fit Current Column Width")

  -- 6. Cell Editing, Row Insert/Delete, Yank, Undo/Redo, Save
  local function edit_active_cell()
    local row_obj = session.visible_rows and session.visible_rows[session.cur_row - session.top_row + 1]
    if not row_obj then return end
    local c = session.cur_col
    local old_val = row_obj.cells[c] or ""
    vim.ui.input({
      prompt = string.format("Edit Cell [%s%d] (%s): ", parser.col_to_excel(c), row_obj.rowid, session.headers[c]),
      default = old_val,
    }, function(new_val)
      if new_val ~= nil and new_val ~= old_val then
        sqlite.update_cell(session, row_obj.rowid, c, new_val, true)
        viewport.render(session)
      end
    end)
  end

  map("<CR>", edit_active_cell, "Edit Active Cell")
  map("e", edit_active_cell, "Edit Active Cell")

  map("o", function()
    local new_id = sqlite.insert_row(session, {})
    session.cur_row = session.filtered_rows or session.total_rows or 1
    viewport.render(session)
    vim.notify(string.format("[SuperCsv] Appended new blank row #%d", new_id))
  end, "Insert New Row")

  map("dd", function()
    local row_obj = session.visible_rows and session.visible_rows[session.cur_row - session.top_row + 1]
    if row_obj then
      sqlite.delete_row(session, row_obj.rowid)
      viewport.render(session)
      vim.notify(string.format("[SuperCsv] Deleted row #%d", row_obj.rowid))
    end
  end, "Delete Current Row")

  map("yy", function()
    local row_obj = session.visible_rows and session.visible_rows[session.cur_row - session.top_row + 1]
    if row_obj then
      local val = row_obj.cells[session.cur_col] or ""
      vim.fn.setreg('"', val)
      pcall(vim.fn.setreg, "+", val)
      vim.notify(string.format("[SuperCsv] Yanked cell [%s%d]: %s", parser.col_to_excel(session.cur_col), row_obj.rowid, vim.inspect(val)))
    end
  end, "Yank Active Cell Value")

  map("Y", function()
    local row_obj = session.visible_rows and session.visible_rows[session.cur_row - session.top_row + 1]
    if row_obj then
      local obj = {}
      for c = 1, session.num_cols do
        obj[session.headers[c]] = row_obj.cells[c]
      end
      local json = vim.fn.json_encode(obj)
      vim.fn.setreg('"', json)
      pcall(vim.fn.setreg, "+", json)
      vim.notify(string.format("[SuperCsv] Yanked Row #%d as JSON to clipboard", row_obj.rowid))
    end
  end, "Yank Entire Row as JSON")

  map("u", function()
    local ok, msg = sqlite.undo(session)
    viewport.render(session)
    vim.notify("[SuperCsv] " .. msg, ok and vim.log.levels.INFO or vim.log.levels.WARN)
  end, "Undo Cell Edit")

  map("<C-r>", function()
    local ok, msg = sqlite.redo(session)
    viewport.render(session)
    vim.notify("[SuperCsv] " .. msg, ok and vim.log.levels.INFO or vim.log.levels.WARN)
  end, "Redo Cell Edit")

  map("<leader>cw", function()
    local ok, err = sqlite.save_to_csv(session, session.filepath, false)
    viewport.render(session)
    if ok then
      vim.notify(string.format("[SuperCsv] Saved %s successfully!", vim.fn.fnamemodify(session.filepath, ":t")))
    else
      vim.notify("[SuperCsv Save Error] " .. tostring(err), vim.log.levels.ERROR)
    end
  end, "Save Edits to CSV File")
end

--- Apply a text filter expression to a column
function M.apply_filter_expr(session, col_idx, expr)
  expr = vim.trim(expr or "")
  if expr == "" or expr == "clear" then
    session.filters[col_idx] = nil
  elseif expr == "null" or expr == "notnull" or expr == "empty" then
    session.filters[col_idx] = { op = expr, val = "" }
  else
    local op, val = expr:match("^([><=!~]+)%s*(.*)$")
    if not op then
      op, val = expr:match("^(%w+)%s+(.+)$")
    end
    if op then
      session.filters[col_idx] = { op = op, val = val }
    else
      session.filters[col_idx] = { op = "contains", val = expr }
    end
  end
  session.cached_where_sig = nil
  session.cur_row = 1
  session.top_row = 1
  viewport.render(session)
end

--- Switch from the SuperCsv 2D Excel Viewport back to the normal raw CSV buffer
function M.switch_to_normal_csv(session)
  session = session or M.get_active_session()
  if not session then
    return
  end
  local filepath = session.filepath
  M.disabled_paths[filepath] = true

  if session.record_win and vim.api.nvim_win_is_valid(session.record_win) then
    pcall(vim.api.nvim_win_close, session.record_win, true)
    session.record_win = nil
  end

  local win = vim.api.nvim_get_current_win()
  -- Find or load the raw file buffer
  local raw_buf = vim.fn.bufnr(filepath)
  if raw_buf == -1 or raw_buf == session.view_buf then
    vim.cmd("edit " .. vim.fn.fnameescape(filepath))
    raw_buf = vim.api.nvim_get_current_buf()
  else
    vim.api.nvim_win_set_buf(win, raw_buf)
    if vim.api.nvim_buf_line_count(raw_buf) <= 1 and vim.api.nvim_buf_get_lines(raw_buf, 0, 1, false)[1] == "" then
      vim.cmd("edit! " .. vim.fn.fnameescape(filepath))
    end
  end

  vim.wo[win].number = true
  vim.wo[win].cursorline = true
  vim.wo[win].scrolloff = 4

  -- Jump to the current row in the normal raw CSV buffer (+1 for header line)
  local target_line = math.min(vim.api.nvim_buf_line_count(raw_buf), (session.cur_row or 1) + 1)
  pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, target_line), 0 })

  -- Bind <leader>cv in the raw buffer so pressing it again returns to SuperCsv!
  vim.keymap.set("n", "<leader>cv", function()
    M.disabled_paths[filepath] = nil
    M.open(filepath)
  end, { buffer = raw_buf, silent = true, desc = "SuperCsv: Open 2D Excel Viewport" })

  vim.notify("[SuperCsv] Switched to normal raw CSV view (press <leader>cv or :SuperCsv toggle to re-enable)")
end

--- Open a CSV file in the 2D Excel Virtual Viewport
function M.open(filepath)
  highlights.setup()
  filepath = filepath and filepath ~= "" and vim.fn.fnamemodify(filepath, ":p") or vim.api.nvim_buf_get_name(0)
  if filepath == "" or vim.fn.filereadable(filepath) == 0 then
    vim.notify("[SuperCsv] File is not readable: " .. tostring(filepath), vim.log.levels.WARN)
    return nil
  end
  M.disabled_paths[filepath] = nil

  -- Reuse existing session if already open
  local existing = M.sessions_by_path[filepath]
  if existing and existing.view_buf and vim.api.nvim_buf_is_valid(existing.view_buf) then
    vim.api.nvim_win_set_buf(0, existing.view_buf)
    existing.view_win = vim.api.nvim_get_current_win()
    vim.b[existing.view_buf].snacks_scroll = false
    vim.wo[existing.view_win].scrolloff = 0
    vim.wo[existing.view_win].sidescrolloff = 0
    attach_keymaps(existing)
    M.attach_buf_autocmds(existing)
    viewport.render(existing)
    return existing
  end

  local slice, err = parser.read_initial_slice(filepath, 250)
  if not slice then
    vim.notify("[SuperCsv] " .. tostring(err), vim.log.levels.ERROR)
    return nil
  end

  local view_buf = vim.api.nvim_create_buf(true, true)
  local short_name = vim.fn.fnamemodify(filepath, ":t")
  pcall(vim.api.nvim_buf_set_name, view_buf, "supercsv://" .. short_name .. " (" .. vim.fn.sha256(filepath):sub(1, 6) .. ")")
  vim.bo[view_buf].buftype = "acwrite"
  vim.bo[view_buf].swapfile = false
  vim.bo[view_buf].modifiable = false
  vim.bo[view_buf].filetype = "supercsv"
  vim.b[view_buf].snacks_scroll = false

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, view_buf)
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].cursorline = false
  vim.wo[win].scrolloff = 0
  vim.wo[win].sidescrolloff = 0

  local pinned_cols = {}
  for c = 1, math.min(config.options.freeze_cols or 1, slice.num_cols) do
    pinned_cols[c] = true
  end

  local session = {
    filepath = filepath,
    file_size = slice.file_size,
    mtime = slice.mtime,
    delim = slice.delim,
    headers = slice.headers,
    num_cols = slice.num_cols,
    types = slice.types,
    col_widths = slice.col_widths,
    preview_rows = slice.preview_rows,
    total_rows = #slice.preview_rows,
    filtered_rows = #slice.preview_rows,
    view_buf = view_buf,
    view_win = win,
    cur_row = 1,
    top_row = 1,
    cur_col = 1,
    left_col = (slice.num_cols > (config.options.freeze_cols or 1)) and ((config.options.freeze_cols or 1) + 1) or 1,
    pinned_cols = pinned_cols,
    hidden_cols = {},
    filters = {},
    sort = nil,
    grep_pattern = nil,
    modified_cells = {},
    edit_count = 0,
    undo_stack = {},
    redo_stack = {},
  }

  M.sessions_by_buf[view_buf] = session
  M.sessions_by_path[filepath] = session

  attach_keymaps(session)
  M.attach_buf_autocmds(session)

  -- Render Stage 1 immediately (< 15ms)
  viewport.render(session)

  -- Start Stage 2 SQLite engine
  if config.options.sqlite_backend then
    sqlite.init_session_db(session, function()
      if vim.api.nvim_buf_is_valid(view_buf) then
        viewport.render(session)
      end
    end)
  end

  return session
end

function M.attach_buf_autocmds(session)
  local view_buf = session.view_buf
  local short_name = vim.fn.fnamemodify(session.filepath, ":t")
  local grp = vim.api.nvim_create_augroup("SuperCsvBuf_" .. view_buf, { clear = true })

  -- Support `:w` on the virtual viewport buffer
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = grp,
    buffer = view_buf,
    callback = function()
      local ok, save_err = sqlite.save_to_csv(session, session.filepath, false)
      viewport.render(session)
      if ok then
        vim.notify(string.format("[SuperCsv] Saved %s", short_name))
      else
        vim.notify("[SuperCsv Save Error] " .. tostring(save_err), vim.log.levels.ERROR)
      end
    end,
  })

  -- Re-render automatically on window resize, and clamp topline=1 on any WinScrolled
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "BufWinEnter" }, {
    group = grp,
    buffer = view_buf,
    callback = function()
      session.view_win = vim.fn.bufwinid(view_buf)
      viewport.render(session)
    end,
  })

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = grp,
    buffer = view_buf,
    callback = function()
      if session._rendering then return end
      local w = session.view_win
      if w and vim.api.nvim_win_is_valid(w) then
        vim.api.nvim_win_call(w, function()
          local v = vim.fn.winsaveview()
          if v.topline and v.topline > 1 then
            local delta = v.topline - 1
            local max_r = session.filtered_rows or session.total_rows or 1
            session.top_row = math.min(math.max(1, max_r - (session.page_size or 30) + 1), session.top_row + delta)
            session.cur_row = math.max(session.top_row, math.min(max_r, session.cur_row + delta))
            session._rendering = true
            viewport.render(session)
            session._rendering = false
          elseif v.leftcol and v.leftcol > 0 then
            vim.fn.winrestview({ topline = 1, leftcol = 0 })
          end
        end)
      end
    end,
  })
end

--- Dispatch `:SuperCsv <subcommand>`
function M.command(args)
  local parts = vim.split(vim.trim(args or ""), "%s+", { trimempty = true })
  local sub = parts[1] or "open"
  local rest = table.concat(parts, " ", 2)

  if sub == "open" then
    config.options.enabled = true
    local target = (rest ~= "") and rest or vim.api.nvim_buf_get_name(0)
    M.open(target)
    return
  elseif sub == "toggle" then
    local cur_buf = vim.api.nvim_get_current_buf()
    local s_by_buf = M.sessions_by_buf[cur_buf]
    if s_by_buf then
      M.switch_to_normal_csv(s_by_buf)
    else
      config.options.enabled = true
      local target = (rest ~= "") and rest or vim.api.nvim_buf_get_name(0)
      M.open(target)
    end
    return
  elseif sub == "disable" or sub == "off" then
    config.options.enabled = false
    local s = M.get_active_session()
    if s then
      M.switch_to_normal_csv(s)
    else
      vim.notify("[SuperCsv] Disabled")
    end
    return
  elseif sub == "enable" or sub == "on" then
    config.options.enabled = true
    M.disabled_paths = {}
    local target = (rest ~= "") and rest or vim.api.nvim_buf_get_name(0)
    if target ~= "" and (target:match("%.csv$") or target:match("%.tsv$")) then
      M.open(target)
    else
      vim.notify("[SuperCsv] Enabled")
    end
    return
  end

  local session = M.get_active_session()
  if not session then
    session = M.open(vim.api.nvim_buf_get_name(0))
    if not session then return end
  end

  if sub == "filter" then
    if rest == "" then
      modals.open_autofilter(session, session.cur_col)
    else
      M.apply_filter_expr(session, session.cur_col, rest)
    end
  elseif sub == "filter_val" then
    local row_obj = session.visible_rows and session.visible_rows[session.cur_row - session.top_row + 1]
    if row_obj then
      local val = row_obj.cells[session.cur_col] or ""
      session.filters[session.cur_col] = { values = { [val] = true } }
      session.cached_where_sig = nil
      session.cur_row = 1
      session.top_row = 1
      viewport.render(session)
    end
  elseif sub == "filter_clear" or sub == "clear" then
    session.filters = {}
    session.grep_pattern = nil
    session.cached_where_sig = nil
    session.cur_row = 1
    session.top_row = 1
    viewport.render(session)
  elseif sub == "grep" then
    session.grep_pattern = rest
    session.cached_where_sig = nil
    session.cur_row = 1
    session.top_row = 1
    viewport.render(session)
  elseif sub == "freq" or sub == "value_counts" then
    modals.open_value_counts(session, session.cur_col)
  elseif sub == "stats" or sub == "count" or sub == "sum" then
    modals.open_column_stats(session, session.cur_col)
  elseif sub == "columns" or sub == "cols" then
    modals.open_column_jumper(session)
  elseif sub == "record" or sub == "card" then
    modals.toggle_record_card(session)
  elseif sub == "sql" or sub == "query" then
    modals.open_sql_runner(session, rest)
  elseif sub == "sort" then
    local dir = (rest:upper() == "DESC") and "DESC" or "ASC"
    session.sort = { col_idx = session.cur_col, dir = dir }
    session.cur_row = 1
    session.top_row = 1
    viewport.render(session)
  elseif sub == "freeze" or sub == "pin" then
    local n = tonumber(rest)
    if n then
      session.pinned_cols = {}
      for c = 1, math.min(n, session.num_cols) do
        session.pinned_cols[c] = true
      end
    else
      session.pinned_cols[session.cur_col] = not session.pinned_cols[session.cur_col]
    end
    viewport.render(session)
  elseif sub == "heatmap" then
    config.options.heatmap = not config.options.heatmap
    config.save_persisted()
    viewport.render(session)
  elseif sub == "zebra_rows" or sub == "zebra" then
    config.options.zebra_rows = not config.options.zebra_rows
    config.save_persisted()
    viewport.render(session)
    vim.notify("[SuperCsv] Alternating Row Colors: " .. (config.options.zebra_rows and "ON (saved)" or "OFF (saved)"))
  elseif sub == "zebra_cols" then
    config.options.zebra_columns = not config.options.zebra_columns
    config.save_persisted()
    viewport.render(session)
    vim.notify("[SuperCsv] Alternating Column Colors: " .. (config.options.zebra_columns and "ON (saved)" or "OFF (saved)"))
  elseif sub == "save" then
    sqlite.save_to_csv(session, session.filepath, false)
    viewport.render(session)
  elseif sub == "export" and rest ~= "" then
    local ok, err = sqlite.save_to_csv(session, vim.fn.fnamemodify(rest, ":p"), true)
    if ok then
      vim.notify("[SuperCsv] Exported filtered view to " .. rest)
    else
      vim.notify("[SuperCsv Export Error] " .. tostring(err), vim.log.levels.ERROR)
    end
  else
    vim.notify("[SuperCsv] Unknown subcommand: " .. sub, vim.log.levels.WARN)
  end
end

function M.setup(opts)
  config.setup(opts)
  highlights.setup()

  local augroup = vim.api.nvim_create_augroup("SuperCsvAuto", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = function()
      highlights.setup()
    end,
  })

  -- Global mouse-wheel hover support: scrolling over a SuperCsv window (even when another split/terminal is focused)
  -- scrolls the virtual rows while keeping the Excel header frozen at topline=1
  for _, mode in ipairs({ "n", "i", "v", "t" }) do
    vim.keymap.set(mode, "<ScrollWheelDown>", function()
      local mp = vim.fn.getmousepos()
      if mp and mp.winid and mp.winid > 0 and vim.api.nvim_win_is_valid(mp.winid) then
        local b = vim.api.nvim_win_get_buf(mp.winid)
        local s = M.sessions_by_buf[b]
        if s then
          s.view_win = mp.winid
          local max_r = s.filtered_rows or s.total_rows or 1
          s.cur_row = math.min(max_r, s.cur_row + 3)
          s.top_row = math.min(math.max(1, max_r - (s.page_size or 30) + 1), s.top_row + 3)
          viewport.render(s)
          return
        end
      end
      local key = vim.api.nvim_replace_termcodes("<ScrollWheelDown>", true, false, true)
      vim.api.nvim_feedkeys(key, "n", false)
    end, { silent = true, desc = "SuperCsv: Hover Scroll Down" })

    vim.keymap.set(mode, "<ScrollWheelUp>", function()
      local mp = vim.fn.getmousepos()
      if mp and mp.winid and mp.winid > 0 and vim.api.nvim_win_is_valid(mp.winid) then
        local b = vim.api.nvim_win_get_buf(mp.winid)
        local s = M.sessions_by_buf[b]
        if s then
          s.view_win = mp.winid
          s.cur_row = math.max(1, s.cur_row - 3)
          s.top_row = math.max(1, s.top_row - 3)
          viewport.render(s)
          return
        end
      end
      local key = vim.api.nvim_replace_termcodes("<ScrollWheelUp>", true, false, true)
      vim.api.nvim_feedkeys(key, "n", false)
    end, { silent = true, desc = "SuperCsv: Hover Scroll Up" })
  end

  if config.options.auto_open then
    -- Intercept huge CSVs (> 20MB, e.g. 598MB 1,000,000-row million_100cols.csv) via BufReadCmd
    -- so Neovim NEVER blocks trying to load 600MB into a raw text buffer!
    vim.api.nvim_create_autocmd("BufReadCmd", {
      group = augroup,
      pattern = { "*million*.csv", "*large*.csv" },
      callback = function(ev)
        local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ev.buf), ":p")
        if config.options.enabled and path ~= "" and not M.disabled_paths[path] then
          M.open(path)
        else
          vim.cmd("noautocmd edit " .. vim.fn.fnameescape(path))
        end
      end,
    })

    vim.api.nvim_create_autocmd("BufReadPre", {
      group = augroup,
      pattern = { "*.csv", "*.tsv" },
      callback = function(ev)
        if not config.options.enabled then return end
        local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ev.buf), ":p")
        if path ~= "" and not M.disabled_paths[path] then
          local st = (vim.uv or vim.loop).fs_stat(path)
          if st and st.size > 10 * 1024 * 1024 then
            vim.bo[ev.buf].swapfile = false
            vim.bo[ev.buf].undofile = false
            vim.bo[ev.buf].bufhidden = "wipe"
          end
        end
      end,
    })

    vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
      group = augroup,
      pattern = { "*.csv", "*.tsv" },
      callback = function(ev)
        if not config.options.enabled then return end
        local raw_name = vim.api.nvim_buf_get_name(ev.buf)
        if raw_name == "" or raw_name:match("^supercsv://") then return end
        local path = vim.fn.fnamemodify(raw_name, ":p")
        if M.disabled_paths[path] then
          return
        end
        vim.schedule(function()
          if config.options.enabled and not M.disabled_paths[path] and vim.api.nvim_buf_is_valid(ev.buf) and vim.api.nvim_get_current_buf() == ev.buf then
            M.open(path)
          end
        end)
      end,
    })
  end
end

return M
