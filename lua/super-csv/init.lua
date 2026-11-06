local M = {}

local config = require("super-csv.config")
local highlights = require("super-csv.highlights")
local parser = require("super-csv.engine.parser")
local json_engine = require("super-csv.engine.json")
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
  map("w", function() step_col(session, 1) end, "Next Column")
  map("e", function() step_col(session, 1) end, "Next Column")
  map("<Right>", function() step_col(session, 1) end, "Next Column")
  map("<Tab>", function() step_col(session, 1) end, "Next Column")
  map("h", function() step_col(session, -1) end, "Previous Column")
  map("b", function() step_col(session, -1) end, "Previous Column")
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

  -- Helper to advance rows and stream next file batch on demand if not yet in SQLite
  local function scroll_rows(delta_cur, delta_top)
    local target_cur = (session.cur_row or 1) + (delta_cur or 0)
    local target_top = (session.top_row or 1) + (delta_top or 0)
    if not session.sqlite_ready and not session.eof_reached then
      local needed = math.max(target_cur, target_top + (session.page_size or 30)) + 40
      if needed > #(session.preview_rows or {}) then
        parser.ensure_rows_loaded(session, needed)
      end
    end
    local max_r = session.filtered_rows or session.total_rows or 1
    if delta_cur then
      session.cur_row = math.max(1, math.min(max_r, target_cur))
    end
    if delta_top then
      session.top_row = math.max(1, math.min(math.max(1, max_r - (session.page_size or 30) + 1), target_top))
    end
    viewport.render(session)
  end

  -- 2. Vertical Row Navigation (across 1,000,000+ rows in batches)
  map("j", function()
    scroll_rows(vim.v.count1, nil)
  end, "Next Row")

  map("<Down>", function()
    scroll_rows(vim.v.count1, nil)
  end, "Next Row")

  map("k", function()
    scroll_rows(-vim.v.count1, nil)
  end, "Previous Row")

  map("<Up>", function()
    scroll_rows(-vim.v.count1, nil)
  end, "Previous Row")

  map("<C-d>", function()
    local half = math.max(5, math.floor((session.page_size or 30) / 2))
    scroll_rows(half, half)
  end, "Half-Page Down")

  map("<C-u>", function()
    local half = math.max(5, math.floor((session.page_size or 30) / 2))
    scroll_rows(-half, -half)
  end, "Half-Page Up")

  map("<PageDown>", function()
    local pg = session.page_size or 30
    scroll_rows(pg, pg)
  end, "Page Down")

  map("<PageUp>", function()
    local pg = session.page_size or 30
    scroll_rows(-pg, -pg)
  end, "Page Up")

  map("<C-f>", function()
    local pg = session.page_size or 30
    scroll_rows(pg, pg)
  end, "Page Down (<C-f>)")

  map("<C-b>", function()
    local pg = session.page_size or 30
    scroll_rows(-pg, -pg)
  end, "Page Up (<C-b>)")

  map("<C-e>", function()
    local step = vim.v.count1
    scroll_rows(nil, step)
    if session.cur_row < session.top_row then
      session.cur_row = session.top_row
      viewport.render(session)
    end
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
    if not session.sqlite_ready and not session.eof_reached and target > #(session.preview_rows or {}) then
      parser.ensure_rows_loaded(session, target + 40)
    end
    local max_r = session.filtered_rows or session.total_rows or 1
    session.cur_row = math.max(1, math.min(max_r, target))
    session.top_row = session.cur_row
    viewport.render(session)
  end, "First Row (or [count]gg)")

  map("G", function()
    if vim.v.count > 0 then
      local target = vim.v.count
      if not session.sqlite_ready and not session.eof_reached and target > #(session.preview_rows or {}) then
        parser.ensure_rows_loaded(session, target + 40)
      end
      local max_r = session.filtered_rows or session.total_rows or 1
      session.cur_row = math.max(1, math.min(max_r, target))
      viewport.render(session)
    elseif not session.sqlite_ready and not session.eof_reached and config.options.sqlite_backend then
      sqlite.ensure_indexed(session, function()
        local max_r = session.filtered_rows or session.total_rows or 1
        session.cur_row = max_r
        viewport.render(session)
      end)
    else
      local max_r = session.filtered_rows or session.total_rows or 1
      session.cur_row = max_r
      viewport.render(session)
    end
  end, "Last Row (or [count]G)")

  map("gG", function()
    vim.ui.input({ prompt = string.format("Go to Row (1 .. %d): ", session.filtered_rows or session.total_rows or 1) }, function(inp)
      local n = tonumber(inp)
      if n then
        local target = math.floor(n)
        if not session.sqlite_ready and not session.eof_reached and target > #(session.preview_rows or {}) then
          parser.ensure_rows_loaded(session, target + 40)
        end
        local max_r = session.filtered_rows or session.total_rows or 1
        session.cur_row = math.max(1, math.min(max_r, target))
        session.top_row = math.max(1, session.cur_row - 5)
        viewport.render(session)
      end
    end)
  end, "Prompt Go to Row Number")

  -- Mouse scroll support
  map("<ScrollWheelDown>", function()
    scroll_rows(3, 3)
  end, "Scroll Down")

  map("<ScrollWheelUp>", function()
    scroll_rows(-3, -3)
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
      if session.comment_bar_line and mp.line >= session.comment_bar_line and mp.line <= (session.comment_end_line or session.comment_bar_line) then
        session.comments_expanded = not session.comments_expanded
        viewport.render(session)
        return
      end
      local clicked_col = resolve_clicked_col(mp.wincol)
      if clicked_col then
        session.cur_col = clicked_col
      end
      local hdr_lines = session.header_lines_count or 5
      if mp.line >= (hdr_lines + 1) and session.visible_rows then
        local row_idx = mp.line - hdr_lines
        if row_idx >= 1 and row_idx <= #session.visible_rows then
          session.cur_row = session.top_row + row_idx - 1
        end
      end
      viewport.render(session)
    end
  end, "Select Cell / Column / Toggle Comments with Mouse")

  map("<2-LeftMouse>", function()
    local mp = vim.fn.getmousepos()
    if mp and mp.winid == session.view_win then
      if session.comment_bar_line and mp.line >= session.comment_bar_line and mp.line <= (session.comment_end_line or session.comment_bar_line) then
        session.comments_expanded = not session.comments_expanded
        viewport.render(session)
        return
      end
      local clicked_col = resolve_clicked_col(mp.wincol)
      if clicked_col then
        session.cur_col = clicked_col
      end
      local hdr_lines = session.header_lines_count or 5
      if mp.line == (hdr_lines - 2) or mp.line == (hdr_lines - 1) then
        sqlite.ensure_indexed(session, function()
          modals.open_autofilter(session, session.cur_col)
        end)
      elseif mp.line >= (hdr_lines + 1) and session.visible_rows then
        local row_idx = mp.line - hdr_lines
        if row_idx >= 1 and row_idx <= #session.visible_rows then
          session.cur_row = session.top_row + row_idx - 1
          viewport.render(session)
        end
      end
    end
  end, "Double-Click Header to Filter")

  -- 3. Excel AutoFilter, Quick Value Filter, Grep, Sort
  map("f", function()
    sqlite.ensure_indexed(session, function()
      modals.open_autofilter(session, session.cur_col)
    end)
  end, "Open Excel AutoFilter for Current Column")

  map("fv", function()
    local row_obj = session.visible_rows and session.visible_rows[session.cur_row - session.top_row + 1]
    if row_obj then
      local val = row_obj.cells[session.cur_col] or ""
      sqlite.ensure_indexed(session, function()
        session.filters[session.cur_col] = { values = { [val] = true } }
        session.cached_where_sig = nil
        session.batch_cache = nil
        session.cur_row = 1
        session.top_row = 1
        viewport.render(session)
        vim.notify(string.format("[SuperCsv] Filtered %s == %s", session.headers[session.cur_col], vim.inspect(val)))
      end)
    end
  end, "Filter Column == Active Cell Value")

  map("fx", function()
    local row_obj = session.visible_rows and session.visible_rows[session.cur_row - session.top_row + 1]
    if row_obj then
      local val = row_obj.cells[session.cur_col] or ""
      sqlite.ensure_indexed(session, function()
        session.filters[session.cur_col] = { op = "!=", val = val }
        session.cached_where_sig = nil
        session.batch_cache = nil
        session.cur_row = 1
        session.top_row = 1
        viewport.render(session)
        vim.notify(string.format("[SuperCsv] Excluded %s != %s", session.headers[session.cur_col], vim.inspect(val)))
      end)
    end
  end, "Exclude Active Cell Value")

  map("F", function()
    if session.filters[session.cur_col] then
      session.filters[session.cur_col] = nil
      session.cached_where_sig = nil
      session.batch_cache = nil
      session.cur_row = 1
      session.top_row = 1
      viewport.render(session)
      vim.notify(string.format("[SuperCsv] Cleared filter on %s", session.headers[session.cur_col]))
    else
      session.filters = {}
      session.grep_pattern = nil
      session.cached_where_sig = nil
      session.batch_cache = nil
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
    session.batch_cache = nil
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
        local pat = vim.trim(inp)
        local function apply_grep()
          session.grep_pattern = pat
          session.cached_where_sig = nil
          session.batch_cache = nil
          session.cur_row = 1
          session.top_row = 1
          viewport.render(session)
        end
        if pat ~= "" then
          sqlite.ensure_indexed(session, apply_grep)
        else
          apply_grep()
        end
      end
    end)
  end, "Grep Rows Across All Columns")

  map("/", function()
    local cname = session.headers[session.cur_col] or "col"
    vim.ui.input({
      prompt = string.format("Filter column '%s' (e.g. > 500, = US, contains prod): ", cname),
    }, function(inp)
      if inp and vim.trim(inp) ~= "" then
        local expr = vim.trim(inp)
        sqlite.ensure_indexed(session, function()
          M.apply_filter_expr(session, session.cur_col, expr)
        end)
      end
    end)
  end, "Filter Current Column by Expression")

  map("s", function()
    sqlite.ensure_indexed(session, function()
      session.sort = { col_idx = session.cur_col, dir = "ASC" }
      session.batch_cache = nil
      session.cur_row = 1
      session.top_row = 1
      viewport.render(session)
    end)
  end, "Sort Column Ascending ▲")

  map("S", function()
    sqlite.ensure_indexed(session, function()
      session.sort = { col_idx = session.cur_col, dir = "DESC" }
      session.batch_cache = nil
      session.cur_row = 1
      session.top_row = 1
      viewport.render(session)
    end)
  end, "Sort Column Descending ▼")

  -- 4. Counts, Value Frequencies, Column Analytics & SQL
  map("gv", function()
    sqlite.ensure_indexed(session, function()
      modals.open_value_counts(session, session.cur_col)
    end)
  end, "Value Counts / Frequency Breakdown")

  map("gs", function()
    sqlite.ensure_indexed(session, function()
      modals.open_column_stats(session, session.cur_col)
    end)
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
    sqlite.ensure_indexed(session, function()
      modals.open_sql_runner(session)
    end)
  end, "Run SQL Query on CSV")

  map("<leader>cq", function()
    sqlite.ensure_indexed(session, function()
      modals.open_sql_runner(session)
    end)
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

  map("gR", function()
    local cfg = require("super-csv.config")
    cfg.options.rainbow_columns = not cfg.options.rainbow_columns
    cfg.save_persisted()
    require("super-csv.ui.viewport").render(session)
    vim.notify("[SuperCsv] Rainbow CSV Columns: " .. (cfg.options.rainbow_columns and "ON (saved)" or "OFF (saved)"))
  end, "Toggle Rainbow CSV Column Colors")

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
  end, "Switch Back to Normal Raw CSV / JSON Buffer")

  map("<leader>cj", function()
    local src_json = session.source_json_path
    local default_out
    if src_json and src_json ~= "" then
      default_out = src_json:gsub("%.ndjson$", ""):gsub("%.jsonl$", ""):gsub("%.jsonc$", ""):gsub("%.json$", "") .. ".csv"
    else
      default_out = session.filepath:gsub("%.csv$", "") .. "_converted.csv"
    end
    local ok, err = sqlite.save_to_csv(session, default_out, false)
    if ok then
      vim.notify(string.format("[SuperCsv] Converted & saved CSV to %s", default_out))
    else
      vim.notify("[SuperCsv Convert Error] " .. tostring(err), vim.log.levels.ERROR)
    end
  end, "Save / Convert Current Table to .csv File")

  -- 5b. Collapsible Top CSV Comments (`c`, `#`, `z`, `za`, `zo`, `zc`, `C`, `<leader>cm`, `g#`, `<leader>c#`)
  local function toggle_comments(force_state)
    local cnt = #(session.comments or {})
    if cnt == 0 then
      vim.notify("[SuperCsv] No `#` comment lines in this CSV file", vim.log.levels.INFO)
      return
    end
    if force_state ~= nil then
      session.comments_expanded = force_state
    else
      session.comments_expanded = not session.comments_expanded
    end
    viewport.render(session)
  end

  map("c", function() toggle_comments(nil) end, "Toggle Top CSV Comments Panel")
  map("#", function() toggle_comments(nil) end, "Toggle Top CSV Comments Panel")
  map("z", function() toggle_comments(nil) end, "Toggle Top CSV Comments Panel")
  map("za", function() toggle_comments(nil) end, "Toggle Top CSV Comments Panel")
  map("zo", function() toggle_comments(true) end, "Expand Top CSV Comments Panel")
  map("zc", function() toggle_comments(false) end, "Collapse Top CSV Comments Panel")
  map("C", function() toggle_comments(nil) end, "Toggle Top CSV Comments Panel")
  map("<leader>cm", function() toggle_comments(nil) end, "Toggle Top CSV Comments Panel")
  map("g#", function() modals.open_comments_viewer(session) end, "Open Scrollable CSV Comments Inspector")
  map("<leader>c#", function() modals.open_comments_viewer(session) end, "Open Scrollable CSV Comments Inspector")

  -- 5c. Help & Shortcuts Reference (`?`, `g?`, `<F1>`, `<leader>ch`)
  map("?", function() modals.open_help(session) end, "Show Keyboard Shortcuts & Help")
  map("g?", function() modals.open_help(session) end, "Show Keyboard Shortcuts & Help")
  map("<F1>", function() modals.open_help(session) end, "Show Keyboard Shortcuts & Help")
  map("<leader>ch", function() modals.open_help(session) end, "Show Keyboard Shortcuts & Help")

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

  -- 6. Cell Editing, Subtable Drill-Down, Row Insert/Delete, Yank, Undo/Redo/Cancel, Save
  local function edit_active_cell()
    modals.open_cell_editor(session)
  end

  map("i", edit_active_cell, "Edit Active Cell")
  map("<F2>", edit_active_cell, "Edit Active Cell")
  map("<CR>", function()
    if M.open_subtable(session) then
      return
    end
    edit_active_cell()
  end, "Drill into Subtable Cell or Edit Active Cell")

  map("gd", function()
    if not M.open_subtable(session) then
      vim.notify("[SuperCsv] Current cell is not a nested Subtable ([tbl]/[arr])", vim.log.levels.INFO)
    end
  end, "Drill Down into Nested Subtable Cell")

  map("gt", function()
    session.inline_subtable = (session.inline_subtable == false) and true or false
    viewport.render(session)
    vim.notify("[SuperCsv] Inline Embedded Subtable: " .. (session.inline_subtable and "ON" or "OFF"))
  end, "Toggle Inline Embedded Subtable Preview")

  map("<BS>", function()
    if not M.close_subtable(session) then
      step_col(session, -1)
    end
  end, "Return from Subtable to Parent Table (or Previous Column)")

  map("<Esc>", function()
    if session._cell_edit_win and vim.api.nvim_win_is_valid(session._cell_edit_win) then
      pcall(vim.api.nvim_win_close, session._cell_edit_win, true)
      session._editing_cell = false
      session._cell_edit_win = nil
      return
    end
    if session.record_win and vim.api.nvim_win_is_valid(session.record_win) then
      modals.toggle_record_card(session)
      return
    end
    if session.undo_stack and #session.undo_stack > 0 then
      local ok, msg = sqlite.undo(session)
      viewport.render(session)
      vim.notify("[SuperCsv] " .. msg, ok and vim.log.levels.INFO or vim.log.levels.WARN)
      return
    end
    if session.parent_session then
      M.close_subtable(session)
    end
  end, "Cancel Open Editor / Record Split / Undo / Return to Parent Table")

  map("o", function()
    local new_id = sqlite.insert_row(session, {})
    session.cur_row = session.filtered_rows or session.total_rows or 1
    viewport.render(session)
    vim.notify(string.format("[SuperCsv] Appended new blank row #%d (press 'u' or '<Esc>' to cancel)", new_id))
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
  session.batch_cache = nil
  session.cur_row = 1
  session.top_row = 1
  viewport.render(session)
end

--- Switch from the SuperCsv 2D Excel Viewport back to the normal raw CSV or JSON buffer
function M.switch_to_normal_csv(session)
  session = session or M.get_active_session()
  if not session then
    return
  end
  local raw_target_path = session.source_json_path or session.filepath
  M.disabled_paths[session.filepath] = true
  if session.source_json_path then
    M.disabled_paths[session.source_json_path] = true
  end

  if session.record_win and vim.api.nvim_win_is_valid(session.record_win) then
    pcall(vim.api.nvim_win_close, session.record_win, true)
    session.record_win = nil
  end

  local win = vim.api.nvim_get_current_win()
  local raw_buf = -1

  if session.source_json_buf and vim.api.nvim_buf_is_valid(session.source_json_buf) and session.source_json_buf ~= session.view_buf then
    raw_buf = session.source_json_buf
    vim.api.nvim_win_set_buf(win, raw_buf)
  else
    raw_buf = vim.fn.bufnr(raw_target_path)
    if raw_buf == -1 or raw_buf == session.view_buf then
      vim.cmd("edit " .. vim.fn.fnameescape(raw_target_path))
      raw_buf = vim.api.nvim_get_current_buf()
    else
      vim.api.nvim_win_set_buf(win, raw_buf)
      if vim.api.nvim_buf_line_count(raw_buf) <= 1 and vim.api.nvim_buf_get_lines(raw_buf, 0, 1, false)[1] == "" then
        vim.cmd("edit! " .. vim.fn.fnameescape(raw_target_path))
      end
    end
  end

  vim.wo[win].number = true
  vim.wo[win].cursorline = true
  vim.wo[win].scrolloff = 4

  if not session.source_json_path and not session.source_json_buf then
    -- Jump to the current row in the normal raw CSV buffer (accounting for header + comment lines)
    local row_obj = session.visible_rows and session.visible_rows[(session.cur_row or 1) - (session.top_row or 1) + 1]
    local raw_line_num = (row_obj and row_obj.file_line) or ((session.cur_row or 1) + (session.header_line_num or 1))
    local target_line = math.min(vim.api.nvim_buf_line_count(raw_buf), raw_line_num)
    pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, target_line), 0 })
  end

  -- Bind <leader>cv in the raw buffer so pressing it again returns to SuperCsv!
  vim.keymap.set("n", "<leader>cv", function()
    M.disabled_paths[session.filepath] = nil
    if session.source_json_path then
      M.disabled_paths[session.source_json_path] = nil
      M.open_json(session.source_json_path)
    elseif session.source_json_buf then
      M.open_json( nil)
    else
      M.open(raw_target_path)
    end
  end, { buffer = raw_buf, silent = true, desc = "SuperCsv: Open 2D Excel Viewport" })

  local kind = (session.source_json_path or session.source_json_buf) and "JSON" or "CSV"
  vim.notify(string.format("[SuperCsv] Switched to normal raw %s view (press <leader>cv or :SuperCsv toggle to re-enable)", kind))
end

--- Convert a JSON/JSONL file or current buffer to a CSV file on disk
function M.json_to_csv(input_source, output_csv_path, opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  vim.fn.mkdir(config.options.cache_dir, "p")

  if not input_source or input_source == "" then
    local s = M.get_active_session()
    if s and s.source_json_path and vim.fn.filereadable(s.source_json_path) == 1 then
      input_source = s.source_json_path
    else
      local buf_name = vim.api.nvim_buf_get_name(0)
      if buf_name ~= "" and vim.fn.filereadable(buf_name) == 1 and json_engine.is_json_path(buf_name) and not vim.bo[0].modified then
        input_source = buf_name
      else
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        input_source = table.concat(lines, "\n")
        opts.is_raw_text = true
        if (not output_csv_path or output_csv_path == "") and buf_name ~= "" then
          output_csv_path = buf_name:gsub("%.ndjson$", ""):gsub("%.jsonl$", ""):gsub("%.jsonc$", ""):gsub("%.json$", "") .. ".csv"
        end
      end
    end
  end

  return json_engine.convert_json_to_csv(input_source, output_csv_path, opts)
end

--- Drill down into an active Subtable cell (`[tbl]` or `[arr]`) as a full interactive 2D SuperCsv Session
function M.open_subtable(session)
  session = session or M.get_active_session()
  if not session then
    return nil
  end
  local row_obj = session.visible_rows and session.visible_rows[(session.cur_row or 1) - (session.top_row or 1) + 1]
  if not row_obj then
    return nil
  end
  local raw_val = row_obj.cells[session.cur_col] or ""
  local sub = json_engine.parse_subtable_cell(raw_val)
  if not sub or not sub.rows or #sub.rows == 0 then
    return nil
  end

  vim.fn.mkdir(config.options.cache_dir, "p")
  local col_name = session.headers[session.cur_col] or ("col_" .. session.cur_col)
  local hash = vim.fn.sha256("subtable_v2|" .. col_name .. "|" .. raw_val):sub(1, 16)
  local safe_col = col_name:gsub("[^%w_%-]", "_")
  local cache_csv = string.format("%s/subtable_%s_%s.csv", config.options.cache_dir, safe_col, hash)

  local ok, out_or_err, info = json_engine.convert_json_to_csv(raw_val, cache_csv, { is_raw_text = true })
  if not ok then
    vim.notify("[SuperCsv Subtable Error] " .. tostring(out_or_err), vim.log.levels.ERROR)
    return nil
  end

  M.disabled_paths[cache_csv] = nil
  local child_session = M.open(cache_csv, { _skip_json_redirect = true })
  if child_session then
    child_session.parent_session = session
    child_session.parent_row = session.cur_row
    child_session.parent_col = session.cur_col
    child_session.source_json_path = session.source_json_path
    child_session.source_json_buf = session.source_json_buf
    local parent_label = session.display_filename or vim.fn.fnamemodify(session.filepath, ":t")
    parent_label = parent_label:gsub("%s*%[.*%]$", "")
    child_session.display_filename = string.format(
      "%s ❯ Row #%d.%s [Subtable %d×%d | <BS> Back]",
      parent_label,
      row_obj.rowid or session.cur_row,
      col_name,
      info.num_rows,
      info.num_cols
    )
    viewport.render(child_session)
  end
  return child_session
end

--- Pop back from a Subtable session to its Parent Table session
function M.close_subtable(session)
  session = session or M.get_active_session()
  if not session or not session.parent_session then
    return false
  end
  local parent = session.parent_session
  local win = (session.view_win and vim.api.nvim_win_is_valid(session.view_win))
    and session.view_win
    or vim.api.nvim_get_current_win()
  if parent.view_buf and vim.api.nvim_buf_is_valid(parent.view_buf) then
    vim.api.nvim_win_set_buf(win, parent.view_buf)
    parent.view_win = win
    viewport.render(parent)
    return true
  elseif parent.filepath and vim.fn.filereadable(parent.filepath) == 1 then
    local reopened = M.open(parent.filepath, { _skip_json_redirect = true })
    if reopened then
      reopened.cur_row = session.parent_row or 1
      reopened.cur_col = session.parent_col or 1
      reopened.display_filename = parent.display_filename
      reopened.source_json_path = parent.source_json_path
      reopened.parent_session = parent.parent_session
      viewport.render(reopened)
      return true
    end
  end
  return false
end

--- Visualize a JSON / JSONL file (or the current JSON buffer) as a 2D CSV Grid in SuperCsv
function M.open_json(filepath, output_csv_path)
  highlights.setup()
  vim.fn.mkdir(config.options.cache_dir, "p")

  local cur_buf = vim.api.nvim_get_current_buf()
  local is_file = filepath and filepath ~= "" and vim.fn.filereadable(filepath) == 1
  if not is_file then
    local buf_name = vim.api.nvim_buf_get_name(cur_buf)
    if (not filepath or filepath == "") and buf_name ~= "" and vim.fn.filereadable(buf_name) == 1 and not vim.bo[cur_buf].modified then
      filepath = vim.fn.fnamemodify(buf_name, ":p")
      is_file = true
    end
  else
    filepath = vim.fn.fnamemodify(filepath, ":p")
  end

  if is_file then
    local st = (vim.uv or vim.loop).fs_stat(filepath)
    local mtime = st and st.mtime and st.mtime.sec or 0
    local fsize = st and st.size or 0
    local cache_csv = output_csv_path
    local cchar_sig = vim.inspect(config.get_json_comment_char()) .. "|" .. vim.inspect(config.get_csv_comment_char())
    if not cache_csv or cache_csv == "" then
      local key = string.format("json2csv_v4|%s|%s|%d|%d", cchar_sig, filepath, fsize, mtime)
      local hash = vim.fn.sha256(key):sub(1, 16)
      local base = vim.fn.fnamemodify(filepath, ":t:r"):gsub("[^%w_%-]", "_")
      cache_csv = string.format("%s/%s_%s.csv", config.options.cache_dir, base, hash)
    else
      cache_csv = vim.fn.fnamemodify(cache_csv, ":p")
    end

    local ok, out_or_err, info = json_engine.convert_json_to_csv(filepath, cache_csv)
    if not ok then
      vim.notify("[SuperCsv JSON Error] " .. tostring(out_or_err), vim.log.levels.ERROR)
      return nil
    end

    M.disabled_paths[filepath] = nil
    M.disabled_paths[cache_csv] = nil
    local session = M.open(cache_csv, { _skip_json_redirect = true })
    if session then
      session.source_json_path = filepath
      if info.comment_items then
        session.comments = info.comment_items
      end
      session.display_filename = string.format("%s [JSON→CSV %d×%d]", vim.fn.fnamemodify(filepath, ":t"), info.num_rows, info.num_cols)
      M.sessions_by_path[filepath] = session
      viewport.render(session)
    end
    return session
  else
    -- Convert directly from in-memory buffer text
    local lines = vim.api.nvim_buf_get_lines(cur_buf, 0, -1, false)
    local raw_text = table.concat(lines, "\n")
    local cchar_sig = vim.inspect(config.get_json_comment_char()) .. "|" .. vim.inspect(config.get_csv_comment_char())
    local hash = vim.fn.sha256(cchar_sig .. "|" .. raw_text):sub(1, 16)
    local cache_csv = (output_csv_path and output_csv_path ~= "")
      and vim.fn.fnamemodify(output_csv_path, ":p")
      or string.format("%s/buffer_json_%s.csv", config.options.cache_dir, hash)

    local ok, out_or_err, info = json_engine.convert_json_to_csv(raw_text, cache_csv, { is_raw_text = true })
    if not ok then
      vim.notify("[SuperCsv JSON Error] " .. tostring(out_or_err), vim.log.levels.ERROR)
      return nil
    end

    M.disabled_paths[cache_csv] = nil
    local session = M.open(cache_csv, { _skip_json_redirect = true })
    if session then
      session.source_json_buf = cur_buf
      if info.comment_items then
        session.comments = info.comment_items
      end
      local buf_label = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(cur_buf), ":t")
      if buf_label == "" then buf_label = "Buffer" end
      session.display_filename = string.format("%s [JSON→CSV %d×%d]", buf_label, info.num_rows, info.num_cols)
      viewport.render(session)
    end
    return session
  end
end

--- Open a CSV (or JSON/JSONL) file in the 2D Excel Virtual Viewport
function M.open(filepath, open_opts)
  open_opts = open_opts or {}
  highlights.setup()
  filepath = filepath and filepath ~= "" and vim.fn.fnamemodify(filepath, ":p") or vim.api.nvim_buf_get_name(0)

  if not open_opts._skip_json_redirect then
    if json_engine.is_json_path(filepath) then
      return M.open_json(filepath)
    elseif filepath == "" or vim.fn.filereadable(filepath) == 0 then
      local ft = vim.bo[0].filetype
      local first_line = vim.trim((vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]) or "")
      if ft == "json" or ft == "jsonc" or ft == "jsonl" or ft == "ndjson" or first_line:match("^[%[{]") then
        return M.open_json(nil)
      end
    end
  end

  if filepath == "" or vim.fn.filereadable(filepath) == 0 then
    vim.notify("[SuperCsv] File is not readable: " .. tostring(filepath), vim.log.levels.WARN)
    return nil
  end
  M.disabled_paths[filepath] = nil

  -- Reuse existing session if already open AND file on disk has not changed
  local existing = M.sessions_by_path[filepath]
  local st = (vim.uv or vim.loop).fs_stat(filepath)
  local cur_mtime = st and st.mtime and st.mtime.sec or 0
  local cur_size = st and st.size or 0
  if existing and existing.view_buf and vim.api.nvim_buf_is_valid(existing.view_buf)
    and existing.mtime == cur_mtime and existing.file_size == cur_size and existing.comments ~= nil then
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

  local slice, err = parser.read_initial_slice(filepath, config.options.batch_size or 500)
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
    header_line_num = slice.header_line_num or 1,
    num_cols = slice.num_cols,
    types = slice.types,
    col_widths = slice.col_widths,
    preview_rows = slice.preview_rows,
    comments = slice.comments or {},
    seen_comment_lines = slice.seen_comment_lines or {},
    file_line_num = slice.file_line_num or 1,
    comments_expanded = (config.options.comments_collapsed == false),
    file_offset = slice.file_offset,
    eof_reached = slice.eof_reached,
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

  -- Open cached SQLite DB if present, or import synchronously only for small files (< 2MB)
  if config.options.sqlite_backend then
    sqlite.init_session_db(session, function()
      if vim.api.nvim_buf_is_valid(view_buf) then
        viewport.render(session)
      end
    end, false)
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
            if not session.sqlite_ready and not session.eof_reached then
              parser.ensure_rows_loaded(session, (session.top_row or 1) + delta + (session.page_size or 30) + 40)
            end
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

  if sub == "reload" then
    local prev_session = M.get_active_session()
    local saved_opts = vim.deepcopy(config.options or {})
    for k in pairs(package.loaded) do
      if k:match("^super%-csv") then
        package.loaded[k] = nil
      end
    end
    local fresh = require("super-csv")
    fresh.setup(saved_opts)
    pcall(vim.cmd, "runtime! plugin/super-csv.lua")
    if prev_session then
      if prev_session.source_json_path then
        fresh.open_json(prev_session.source_json_path)
      elseif prev_session.source_json_buf and vim.api.nvim_buf_is_valid(prev_session.source_json_buf) then
        vim.api.nvim_set_current_buf(prev_session.source_json_buf)
        fresh.open_json(nil)
      elseif prev_session.filepath then
        fresh.open(prev_session.filepath)
      end
    else
      local bname = vim.api.nvim_buf_get_name(0)
      local ft = vim.bo[0].filetype
      local first_line = vim.trim((vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]) or "")
      if json_engine.is_json_path(bname) or ft == "json" or ft == "jsonc" or ft == "jsonl" or ft == "ndjson" or first_line:match("^[%[{]") then
        fresh.open_json(bname ~= "" and bname or nil)
      elseif bname ~= "" and (bname:match("%.csv$") or bname:match("%.tsv$")) then
        fresh.open(bname)
      end
    end
    vim.notify("[SuperCsv] Reloaded plugin & opened buffer in 2D viewport")
    return
  elseif sub == "open" then
    config.options.enabled = true
    local target = (rest ~= "") and rest or vim.api.nvim_buf_get_name(0)
    M.open(target)
    return
  elseif sub == "json" or sub == "view_json" then
    config.options.enabled = true
    local target = (rest ~= "") and rest or nil
    M.open_json(target)
    return
  elseif sub == "json_to_csv" or sub == "convert" then
    config.options.enabled = true
    local arg1 = parts[2]
    local arg2 = parts[3]
    local in_src, out_csv
    if arg1 and arg2 then
      in_src, out_csv = arg1, arg2
    elseif arg1 and json_engine.is_json_path(arg1) and vim.fn.filereadable(arg1) == 1 then
      in_src, out_csv = arg1, nil
    else
      in_src, out_csv = nil, arg1
    end
    local ok, res_path, info = M.json_to_csv(in_src, out_csv)
    if ok then
      vim.notify(string.format("[SuperCsv] Converted JSON (%d rows × %d cols) -> %s", info.num_rows, info.num_cols, res_path))
      M.open(res_path)
    else
      vim.notify("[SuperCsv JSON→CSV Error] " .. tostring(res_path), vim.log.levels.ERROR)
    end
    return
  elseif sub == "comment_char" then
    if rest ~= "" then
      config.options.comment_char = rest
      config.options.comments = config.options.comments or {}
      config.options.comments.csv = rest
      vim.notify(string.format("[SuperCsv] CSV comment prefix set to %s", vim.inspect(rest)))
      local s = M.get_active_session()
      if s and s.filepath then
        M.sessions_by_path[s.filepath] = nil
        M.open(s.source_json_path or s.filepath)
      end
    else
      vim.notify(string.format("[SuperCsv] CSV comment_char = %s | JSON json_comment_char = %s", vim.inspect(config.get_csv_comment_char()), vim.inspect(config.get_json_comment_char())))
    end
    return
  elseif sub == "json_comment_char" then
    if rest ~= "" then
      config.options.json_comment_char = rest
      config.options.comments = config.options.comments or {}
      config.options.comments.json = rest
      vim.notify(string.format("[SuperCsv] JSON comment prefix set to %s", vim.inspect(rest)))
      local s = M.get_active_session()
      if s and (s.source_json_path or s.source_json_buf) then
        M.open_json(s.source_json_path)
      end
    else
      vim.notify(string.format("[SuperCsv] JSON json_comment_char = %s | CSV comment_char = %s", vim.inspect(config.get_json_comment_char()), vim.inspect(config.get_csv_comment_char())))
    end
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
  elseif sub == "rainbow" or sub == "rainbow_cols" then
    config.options.rainbow_columns = not config.options.rainbow_columns
    config.save_persisted()
    viewport.render(session)
    vim.notify("[SuperCsv] Rainbow CSV Columns: " .. (config.options.rainbow_columns and "ON (saved)" or "OFF (saved)"))
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
  elseif sub == "comments" or sub == "comment" then
    if rest == "popup" or rest == "modal" then
      modals.open_comments_viewer(session)
    elseif rest == "expand" or rest == "open" or rest == "show" then
      session.comments_expanded = true
      viewport.render(session)
    elseif rest == "collapse" or rest == "close" or rest == "hide" then
      session.comments_expanded = false
      viewport.render(session)
    else
      session.comments_expanded = not session.comments_expanded
      viewport.render(session)
    end
  elseif sub == "help" or sub == "?" then
    modals.open_help(session)
  elseif sub == "reload" then
    for k in pairs(package.loaded) do
      if k:match("^super%-csv") then
        package.loaded[k] = nil
      end
    end
    local fresh = require("super-csv")
    fresh.setup(config.options)
    if session and session.filepath then
      fresh.open(session.filepath)
    end
    vim.notify("[SuperCsv] Reloaded plugin modules")
  elseif sub == "save" then
    sqlite.save_to_csv(session, session.filepath, false)
    viewport.render(session)
  elseif sub == "export" and rest ~= "" then
    local out_path = vim.fn.fnamemodify(rest, ":p")
    local ok, err
    if json_engine.is_json_path(out_path) then
      ok, err = json_engine.export_session_to_json(session, out_path, true)
    else
      ok, err = sqlite.save_to_csv(session, out_path, true)
    end
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
      for _, s in pairs(M.sessions_by_buf) do
        if s.view_buf and vim.api.nvim_buf_is_valid(s.view_buf) then
          viewport.render(s)
        end
      end
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
          if not s.sqlite_ready and not s.eof_reached then
            parser.ensure_rows_loaded(s, (s.top_row or 1) + (s.page_size or 30) + 40)
          end
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
          vim.bo[ev.buf].buftype = "nofile"
          vim.bo[ev.buf].modifiable = false
          vim.bo[ev.buf].modified = false
          vim.bo[ev.buf].bufhidden = "wipe"
          vim.bo[ev.buf].buflisted = false
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

  -- Attach JSON-to-CSV visualization & conversion keymaps on .json / .jsonc / .jsonl / .ndjson buffers
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter", "FileType" }, {
    group = augroup,
    pattern = { "*.json", "*.jsonc", "*.jsonl", "*.ndjson", "json", "jsonc", "jsonl", "ndjson" },
    callback = function(ev)
      if not vim.api.nvim_buf_is_valid(ev.buf) then return end
      local bname = vim.api.nvim_buf_get_name(ev.buf)
      if bname:match("^supercsv://") then return end

      vim.keymap.set("n", "<leader>cv", function()
        M.open_json(nil)
      end, { buffer = ev.buf, silent = true, desc = "SuperCsv: Visualize JSON as 2D CSV Grid" })

      vim.keymap.set("n", "<leader>cj", function()
        M.command("json_to_csv")
      end, { buffer = ev.buf, silent = true, desc = "SuperCsv: Convert JSON to .csv File & Open" })

      if config.options.auto_open_json and config.options.enabled and bname ~= "" then
        local path = vim.fn.fnamemodify(bname, ":p")
        if not M.disabled_paths[path] then
          vim.schedule(function()
            if config.options.enabled and not M.disabled_paths[path] and vim.api.nvim_buf_is_valid(ev.buf) and vim.api.nvim_get_current_buf() == ev.buf then
              M.open_json(path)
            end
          end)
        end
      end
    end,
  })
end

return M
