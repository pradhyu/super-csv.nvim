local M = {}

local parser = require("super-csv.engine.parser")
local sqlite = require("super-csv.engine.sqlite")
local viewport = require("super-csv.ui.viewport")

local modal_ns = vim.api.nvim_create_namespace("super_csv_modals")

local function create_float(title, width, height, enter)
  width = math.min(width, vim.o.columns - 6)
  height = math.min(height, vim.o.lines - 6)
  local row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(1, math.floor((vim.o.columns - width) / 2))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  local win = vim.api.nvim_open_win(buf, enter ~= false, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  return buf, win
end

--- 0. Single-Instance Cancellable Cell Editor Modal (`i`, `ce`, `<CR>`)
--- Prevents stacked/queued `vim.ui.input` popups and cancels immediately on a single `<Esc>`, `<C-c>`, or `q`!
function M.open_cell_editor(session, row_obj, col_idx)
  if not session then return end
  if session._editing_cell or (session._cell_edit_win and vim.api.nvim_win_is_valid(session._cell_edit_win)) then
    return
  end

  row_obj = row_obj or (session.visible_rows and session.visible_rows[session.cur_row - session.top_row + 1])
  if not row_obj then return end
  col_idx = col_idx or session.cur_col
  local old_val = tostring(row_obj.cells[col_idx] or "")
  local cname = session.headers[col_idx] or ("col_" .. col_idx)
  local coord = string.format("%s%d", parser.col_to_excel(col_idx), row_obj.rowid or session.cur_row)

  session._editing_cell = true

  local width = math.min(math.max(54, #old_val + 16, #cname + 28), vim.o.columns - 8)
  local row = math.max(1, math.floor((vim.o.lines - 3) / 2) - 1)
  local col = math.max(1, math.floor((vim.o.columns - width) / 2))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { old_val })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = string.format(" ✏️ Edit Cell [%s] %s ", coord, cname),
    title_pos = "left",
    footer = " [<CR>] Save   [<Esc> / <C-c> / q] Cancel ",
    footer_pos = "right",
  })
  vim.wo[win].wrap = false
  session._cell_edit_win = win
  session._cell_edit_buf = buf

  local closed = false
  local function close_editor(cancelled)
    if closed then return end
    closed = true
    session._editing_cell = false
    session._cell_edit_win = nil
    session._cell_edit_buf = nil
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if session.view_win and vim.api.nvim_win_is_valid(session.view_win) then
      pcall(vim.api.nvim_set_current_win, session.view_win)
    end
    if cancelled then
      vim.notify(string.format("[SuperCsv] Cancelled edit on [%s]", coord), vim.log.levels.INFO)
    end
  end

  local function save_and_close()
    if closed then return end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
    local new_val = lines[1] or ""
    close_editor(false)
    if new_val ~= old_val then
      sqlite.update_cell(session, row_obj.rowid, col_idx, new_val, true)
      viewport.render(session)
      vim.notify(string.format("[SuperCsv] Updated [%s] = %s (press 'u' to undo)", coord, vim.inspect(new_val)))
    end
  end

  -- Instant single-key cancel in BOTH Insert and Normal mode!
  for _, m in ipairs({ "i", "n", "v" }) do
    vim.keymap.set(m, "<Esc>", function() close_editor(true) end, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set(m, "<C-c>", function() close_editor(true) end, { buffer = buf, nowait = true, silent = true })
    vim.keymap.set(m, "<CR>", save_and_close, { buffer = buf, nowait = true, silent = true })
  end
  vim.keymap.set("n", "q", function() close_editor(true) end, { buffer = buf, nowait = true, silent = true })

  vim.api.nvim_create_autocmd({ "BufLeave", "WinClosed" }, {
    buffer = buf,
    once = true,
    callback = function()
      close_editor(false)
    end,
  })

  -- Place cursor at end of current value in Insert mode
  pcall(vim.api.nvim_win_set_cursor, win, { 1, #old_val })
  vim.cmd("startinsert!")
end

--- 1. Excel AutoFilter Modal (`f` on any column)
function M.open_autofilter(session, col_idx)
  col_idx = col_idx or session.cur_col
  local cname = session.headers[col_idx] or ("col_" .. col_idx)
  local letter = parser.col_to_excel(col_idx)
  local freq_list, base_total = sqlite.get_value_counts(session, col_idx, 120)

  local existing = (session.filters and session.filters[col_idx]) or {}
  local selected = {}
  local has_existing_vals = (existing.values and next(existing.values) ~= nil)
  for _, item in ipairs(freq_list) do
    if has_existing_vals then
      selected[item.value] = existing.values[item.value] == true
    else
      selected[item.value] = true
    end
  end

  local cond_op = existing.op or ""
  local cond_val = existing.val or ""

  local buf, win = create_float(
    string.format("󰈲 Excel AutoFilter: %s #%d (%s)", letter, col_idx, cname),
    74,
    math.min(26, #freq_list + 9),
    true
  )

  local function render_list()
    local lines = {
      string.format(" Column: %s (%s) │ Distinct Checked Values (%d shown of %d rows)", cname, session.types[col_idx] or "str", #freq_list, base_total),
      string.format(" Condition Filter: %s", (cond_op ~= "") and (cond_op .. " " .. cond_val) or "(None — press '/' to set >, <, =, !=, contains, null)"),
      " [Space] Toggle  [a] All  [n] None  [/] Condition  [c] Clear Filter  [<CR>] Apply  [q] Cancel",
      string.rep("─", 72),
    }

    for i, item in ipairs(freq_list) do
      local mark = selected[item.value] and "[x]" or "[ ]"
      local disp = item.value == "" and "<EMPTY / NULL>" or item.value
      if #disp > 36 then
        disp = disp:sub(1, 35) .. "…"
      end
      local bar_w = math.max(1, math.floor((item.pct / 100.0) * 12))
      local bar = string.rep("█", bar_w)
      lines[i + 4] = string.format(" %s %-36s │ %7d (%5.1f%%) %s", mark, disp, item.count, item.pct, bar)
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, modal_ns, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvHeaderBanner", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvHeaderFiltered", 1, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvFooterCell", 2, 0, -1)
  end

  render_list()
  if #freq_list > 0 then
    pcall(vim.api.nvim_win_set_cursor, win, { 5, 1 })
  end

  local function close_modal()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- Toggle value at cursor with <Space>
  vim.keymap.set("n", "<Space>", function()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local idx = line - 4
    if freq_list[idx] then
      local v = freq_list[idx].value
      selected[v] = not selected[v]
      render_list()
      pcall(vim.api.nvim_win_set_cursor, win, { math.min(4 + #freq_list, line + 1), 1 })
    end
  end, { buffer = buf, nowait = true })

  -- Select All / None
  vim.keymap.set("n", "a", function()
    for _, item in ipairs(freq_list) do selected[item.value] = true end
    render_list()
  end, { buffer = buf, nowait = true })

  vim.keymap.set("n", "n", function()
    for _, item in ipairs(freq_list) do selected[item.value] = false end
    render_list()
  end, { buffer = buf, nowait = true })

  -- Condition prompt (`/`)
  vim.keymap.set("n", "/", function()
    vim.ui.input({
      prompt = string.format("Filter %s (e.g. > 1000, <= 50, = US, != PENDING, contains err, null, notnull): ", cname),
      default = (cond_op ~= "") and (cond_op .. " " .. cond_val) or "",
    }, function(input)
      if input == nil then return end
      input = vim.trim(input)
      if input == "" then
        cond_op, cond_val = "", ""
      elseif input == "null" or input == "notnull" or input == "empty" then
        cond_op, cond_val = input, ""
      else
        local op, val = input:match("^([><=!~]+)%s*(.*)$")
        if not op then
          op, val = input:match("^(%w+)%s+(.+)$")
        end
        if op then
          cond_op, cond_val = op, val
        else
          cond_op, cond_val = "contains", input
        end
      end
      render_list()
    end)
  end, { buffer = buf, nowait = true })

  -- Clear filter on this column (`c`)
  vim.keymap.set("n", "c", function()
    session.filters[col_idx] = nil
    session.cached_where_sig = nil
    session.batch_cache = nil
    session.cur_row = 1
    session.top_row = 1
    close_modal()
    viewport.render(session)
  end, { buffer = buf, nowait = true })

  -- Apply filter (`<CR>`)
  vim.keymap.set("n", "<CR>", function()
    local all_checked = true
    local checked_map = {}
    for _, item in ipairs(freq_list) do
      if selected[item.value] then
        checked_map[item.value] = true
      else
        all_checked = false
      end
    end

    if all_checked and cond_op == "" then
      session.filters[col_idx] = nil
    else
      session.filters[col_idx] = {
        values = (not all_checked) and checked_map or nil,
        op = cond_op ~= "" and cond_op or nil,
        val = cond_val,
      }
    end
    session.cached_where_sig = nil
    session.batch_cache = nil
    session.cur_row = 1
    session.top_row = 1
    close_modal()
    viewport.render(session)
  end, { buffer = buf, nowait = true })

  vim.keymap.set("n", "q", close_modal, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close_modal, { buffer = buf, nowait = true })
end

--- 2. Value Counts / Group-By Frequency Breakdown (`gv` / `:SuperCsv freq`)
function M.open_value_counts(session, col_idx)
  col_idx = col_idx or session.cur_col
  local cname = session.headers[col_idx] or ("col_" .. col_idx)
  local letter = parser.col_to_excel(col_idx)
  local freq_list, total = sqlite.get_value_counts(session, col_idx, 200)

  local buf, win = create_float(
    string.format("📊 Value Frequency & Group-By: %s #%d (%s)", letter, col_idx, cname),
    78,
    math.min(28, #freq_list + 6),
    true
  )

  local lines = {
    string.format(" Column: %s #%d (%s) │ Total Rows: %d │ Unique Displayed: %d", letter, col_idx, cname, total, #freq_list),
    " Press <CR> on any value to filter the spreadsheet to that value │ [q] Close",
    string.rep("─", 76),
    string.format(" %-4s │ %-34s │ %9s │ %7s │ %-12s", "Rank", "Value", "Count", "Share %", "Distribution"),
    string.rep("─", 76),
  }

  for i, item in ipairs(freq_list) do
    local disp = item.value == "" and "<EMPTY / NULL>" or item.value
    if #disp > 34 then disp = disp:sub(1, 33) .. "…" end
    local bar = string.rep("▇", math.max(1, math.floor((item.pct / 100.0) * 12)))
    table.insert(lines, string.format(" #%-3d │ %-34s │ %9d │ %6.2f%% │ %-12s", i, disp, item.count, item.pct, bar))
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvHeaderBanner", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvFooterCell", 1, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvHeaderNormal", 3, 0, -1)

  if #freq_list > 0 then
    pcall(vim.api.nvim_win_set_cursor, win, { 6, 1 })
  end

  local function close_modal()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "<CR>", function()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local idx = line - 5
    if freq_list[idx] then
      local val = freq_list[idx].value
      session.filters[col_idx] = { values = { [val] = true } }
      session.cached_where_sig = nil
      session.batch_cache = nil
      session.cur_row = 1
      session.top_row = 1
      close_modal()
      viewport.render(session)
    end
  end, { buffer = buf, nowait = true })

  vim.keymap.set("n", "q", close_modal, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close_modal, { buffer = buf, nowait = true })
end

--- 3. Column Analytics & Histogram Popup (`gs` / `:SuperCsv stats`)
function M.open_column_stats(session, col_idx)
  col_idx = col_idx or session.cur_col
  local cname = session.headers[col_idx] or ("col_" .. col_idx)
  local letter = parser.col_to_excel(col_idx)
  local st = sqlite.get_column_stats(session, col_idx)
  local freq_list = sqlite.get_value_counts(session, col_idx, 10)

  local lines = {
    string.format(" 📈 Column Summary: %s #%d — %s [%s]", letter, col_idx, cname, session.types[col_idx] or "str"),
    string.rep("─", 66),
    string.format("   Total Rows (Filtered) : %d", st.count),
    string.format("   Distinct Values       : %d", st.distinct),
    string.format("   Null / Empty Count    : %d (%.1f%%)", st.nulls, st.count > 0 and (st.nulls * 100.0 / st.count) or 0),
  }

  if st.is_numeric then
    table.insert(lines, string.format("   SUM                   : %.2f", st.sum))
    table.insert(lines, string.format("   AVERAGE (MEAN)        : %.4f", st.avg))
    table.insert(lines, string.format("   MINIMUM               : %s", tostring(st.min)))
    table.insert(lines, string.format("   MAXIMUM               : %s", tostring(st.max)))
  else
    table.insert(lines, string.format("   Min (Lexicographical) : %s", tostring(st.min)))
    table.insert(lines, string.format("   Max (Lexicographical) : %s", tostring(st.max)))
  end

  table.insert(lines, string.rep("─", 66))
  table.insert(lines, " Top 10 Most Frequent Values:")
  for i, item in ipairs(freq_list) do
    local disp = item.value == "" and "<EMPTY / NULL>" or item.value
    if #disp > 28 then disp = disp:sub(1, 27) .. "…" end
    local bar = string.rep("█", math.max(1, math.floor((item.pct / 100.0) * 16)))
    table.insert(lines, string.format("   %2d. %-28s │ %7d (%5.1f%%) %s", i, disp, item.count, item.pct, bar))
  end

  local buf, win = create_float("Column Statistics & Distribution", 68, #lines + 2, true)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvHeaderBanner", 0, 0, -1)

  local function close_modal()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q", close_modal, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close_modal, { buffer = buf, nowait = true })
end

--- 4. 100-Column Fuzzy Jumper & Column Manager (`<leader>cc` / `:SuperCsv columns`)
function M.open_column_jumper(session)
  local cur_row_obj = (session.visible_rows and session.visible_rows[session.cur_row - session.top_row + 1])
    or (session.preview_rows and session.preview_rows[1])
  local sample_cells = (cur_row_obj and cur_row_obj.cells) or {}
  local search_query = ""
  local filtered_cols = {}

  local buf, win = create_float("🧭 100-Column Jumper & Pin/Hide Manager", 84, 26, true)

  local function rebuild()
    filtered_cols = {}
    local q = search_query:lower()
    for c = 1, session.num_cols do
      local cname = session.headers[c] or ("col_" .. c)
      local letter = parser.col_to_excel(c)
      local sample = sample_cells[c] or ""
      if q == "" or cname:lower():find(q, 1, true) or letter:lower() == q or tostring(c) == q or sample:lower():find(q, 1, true) then
        table.insert(filtered_cols, c)
      end
    end

    local lines = {
      string.format(" Search Filter: %s   (%d / %d columns shown)", search_query == "" and "<All — press / to filter>" or search_query, #filtered_cols, session.num_cols),
      " [<CR>] Jump to Col   [p] Toggle Pin 🔒   [h] Toggle Hide   [/] Search   [q] Close",
      string.rep("─", 82),
      string.format(" %-7s │ %-6s │ %-28s │ %-6s │ %-22s", "Excel", "State", "Column Name", "Type", "Current Row Sample"),
      string.rep("─", 82),
    }

    for _, c in ipairs(filtered_cols) do
      local letter = parser.col_to_excel(c)
      local state = (session.pinned_cols[c] and "🔒Pin" or "") .. (session.hidden_cols[c] and "🚫Hid" or "")
      if state == "" then state = "  —" end
      local cname = session.headers[c] or ("col_" .. c)
      if #cname > 28 then cname = cname:sub(1, 27) .. "…" end
      local sample = tostring(sample_cells[c] or "")
      if #sample > 22 then sample = sample:sub(1, 21) .. "…" end
      table.insert(lines, string.format(" %-3s #%-2d │ %-6s │ %-28s │ %-6s │ %-22s", letter, c, state, cname, session.types[c] or "str", sample))
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, modal_ns, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvHeaderBanner", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvFooterCell", 1, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvHeaderNormal", 3, 0, -1)
  end

  rebuild()
  for idx, c in ipairs(filtered_cols) do
    if c == session.cur_col then
      pcall(vim.api.nvim_win_set_cursor, win, { 5 + idx, 1 })
      break
    end
  end

  local function close_modal()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "<CR>", function()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local c = filtered_cols[line - 5]
    if c then
      session.hidden_cols[c] = nil
      session.cur_col = c
      if not session.pinned_cols[c] then
        session.left_col = c
      end
      close_modal()
      viewport.render(session)
    end
  end, { buffer = buf, nowait = true })

  vim.keymap.set("n", "p", function()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local c = filtered_cols[line - 5]
    if c then
      session.pinned_cols[c] = not session.pinned_cols[c]
      rebuild()
      pcall(vim.api.nvim_win_set_cursor, win, { line, 1 })
      viewport.render(session)
    end
  end, { buffer = buf, nowait = true })

  vim.keymap.set("n", "h", function()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local c = filtered_cols[line - 5]
    if c then
      session.hidden_cols[c] = not session.hidden_cols[c]
      rebuild()
      pcall(vim.api.nvim_win_set_cursor, win, { line, 1 })
      viewport.render(session)
    end
  end, { buffer = buf, nowait = true })

  vim.keymap.set("n", "/", function()
    vim.ui.input({ prompt = "Filter columns by name/index/sample: ", default = search_query }, function(inp)
      if inp ~= nil then
        search_query = vim.trim(inp)
        rebuild()
        if #filtered_cols > 0 then
          pcall(vim.api.nvim_win_set_cursor, win, { 6, 1 })
        end
      end
    end)
  end, { buffer = buf, nowait = true })

  vim.keymap.set("n", "q", close_modal, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close_modal, { buffer = buf, nowait = true })
end

--- 5. Synchronized 100-Column Vertical Record Card (`K` / `<leader>cr`)
function M.toggle_record_card(session)
  if session.record_win and vim.api.nvim_win_is_valid(session.record_win) then
    vim.api.nvim_win_close(session.record_win, true)
    session.record_win = nil
    session.record_buf = nil
    return
  end

  local main_win = session.view_win
  vim.cmd("botright vsplit")
  local rwin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(rwin, math.min(58, math.floor(vim.o.columns * 0.4)))

  local rbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[rbuf].buftype = "nofile"
  vim.bo[rbuf].bufhidden = "wipe"
  vim.bo[rbuf].swapfile = false
  vim.api.nvim_win_set_buf(rwin, rbuf)
  vim.wo[rwin].wrap = false
  vim.wo[rwin].number = false
  vim.wo[rwin].relativenumber = false
  vim.wo[rwin].cursorline = true

  session.record_win = rwin
  session.record_buf = rbuf

  M.refresh_record_card(session)

  -- Keymaps inside Vertical Record Card: <CR>/i edits that column's value, <Esc>/q/K closes split!
  local function edit_from_card()
    local line = vim.api.nvim_win_get_cursor(rwin)[1]
    local col_idx = line - 3
    if col_idx >= 1 and col_idx <= session.num_cols then
      session.cur_col = col_idx
      local row_obj = session.visible_rows and session.visible_rows[session.cur_row - session.top_row + 1]
      if row_obj then
        M.open_cell_editor(session, row_obj, col_idx)
      end
    end
  end

  vim.keymap.set("n", "<CR>", edit_from_card, { buffer = rbuf, nowait = true })
  vim.keymap.set("n", "i", edit_from_card, { buffer = rbuf, nowait = true })
  vim.keymap.set("n", "q", function()
    M.toggle_record_card(session)
  end, { buffer = rbuf, nowait = true })
  vim.keymap.set("n", "<Esc>", function()
    M.toggle_record_card(session)
  end, { buffer = rbuf, nowait = true })
  vim.keymap.set("n", "K", function()
    M.toggle_record_card(session)
  end, { buffer = rbuf, nowait = true })

  -- Return focus to main grid window
  if main_win and vim.api.nvim_win_is_valid(main_win) then
    vim.api.nvim_set_current_win(main_win)
  end
end

function M.refresh_record_card(session)
  if not session.record_buf or not vim.api.nvim_buf_is_valid(session.record_buf) then
    return
  end
  local row_obj = session.visible_rows and session.visible_rows[session.cur_row - session.top_row + 1]
  local rowid = row_obj and row_obj.rowid or session.cur_row
  local cells = (row_obj and row_obj.cells) or {}

  local lines = {
    string.format(" 🗂 Vertical Record Card — Row #%d (%d Columns)", rowid, session.num_cols),
    " [<CR>/e] Edit Field   [/] Search Field Name   [q/K] Close Split",
    string.rep("─", 56),
  }

  for c = 1, session.num_cols do
    local letter = parser.col_to_excel(c)
    local cname = session.headers[c] or ("col_" .. c)
    if #cname > 20 then cname = cname:sub(1, 19) .. "…" end
    local val = cells[c] or ""
    table.insert(lines, string.format(" %-3s #%-3d │ %-20s │ %s", letter, c, cname, val == "" and "∅" or val))
  end

  vim.bo[session.record_buf].modifiable = true
  vim.api.nvim_buf_set_lines(session.record_buf, 0, -1, false, lines)
  vim.bo[session.record_buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(session.record_buf, modal_ns, 0, -1)
  vim.api.nvim_buf_add_highlight(session.record_buf, modal_ns, "SuperCsvHeaderBanner", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(session.record_buf, modal_ns, "SuperCsvFooterCell", 1, 0, -1)
  if session.cur_col and session.cur_col + 2 <= #lines then
    vim.api.nvim_buf_add_highlight(session.record_buf, modal_ns, "SuperCsvCursorRow", session.cur_col + 2, 0, -1)
  end
end

--- 6. Ad-Hoc SQL Query Runner (`gq` / `:SuperCsv sql`)
function M.open_sql_runner(session, initial_sql)
  local function execute_and_show(sql_str)
    if not sql_str or vim.trim(sql_str) == "" then return end
    local res, err = sqlite.run_custom_sql(session, sql_str)
    if not res then
      vim.notify("[SuperCsv SQL Error] " .. tostring(err), vim.log.levels.ERROR)
      return
    end

    local headers = res.headers or {}
    local rows = res.rows or {}
    local widths = {}
    for c = 1, #headers do
      widths[c] = math.max(#headers[c] + 2, 10)
      for r = 1, math.min(#rows, 100) do
        local v = tostring(rows[r][c] or "")
        if #v + 2 > widths[c] then
          widths[c] = math.min(32, #v + 2)
        end
      end
    end

    local lines = {
      string.format(" 󰆼 SQL Query Result (%d rows) │ %s", #rows, sql_str),
      string.rep("─", 90),
    }

    local h_parts = {}
    for c = 1, #headers do
      table.insert(h_parts, string.format("%-" .. widths[c] .. "s", headers[c]:sub(1, widths[c])))
    end
    table.insert(lines, " " .. table.concat(h_parts, " │ "))
    table.insert(lines, string.rep("─", 90))

    for _, r in ipairs(rows) do
      local r_parts = {}
      for c = 1, #headers do
        local v = tostring(r[c] or "")
        if #v > widths[c] then v = v:sub(1, widths[c] - 1) .. "…" end
        table.insert(r_parts, string.format("%-" .. widths[c] .. "s", v))
      end
      table.insert(lines, " " .. table.concat(r_parts, " │ "))
    end

    local buf, win = create_float("SQL Query Results (Press q to close)", 96, math.min(28, #lines + 2), true)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvHeaderBanner", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvHeaderNormal", 2, 0, -1)

    local function close_modal()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
    vim.keymap.set("n", "q", close_modal, { buffer = buf, nowait = true })
    vim.keymap.set("n", "<Esc>", close_modal, { buffer = buf, nowait = true })
  end

  if initial_sql and initial_sql ~= "" then
    execute_and_show(initial_sql)
  else
    local cname = session.headers[session.cur_col] or "c1"
    local default_q = string.format('SELECT "%s", COUNT(*) AS count FROM csv GROUP BY 1 ORDER BY 2 DESC LIMIT 25', cname)
    vim.ui.input({
      prompt = "SuperCsv SQL (table name: `csv` or `csv_data` with c1..cN): ",
      default = default_q,
    }, function(inp)
      if inp and inp ~= "" then
        execute_and_show(inp)
      end
    end)
  end
end

--- 7. CSV Comments Inspector Popup (`g#` / `:SuperCsv comments_popup`)
function M.open_comments_viewer(session)
  local comments = session.comments or {}
  if #comments == 0 then
    vim.notify("[SuperCsv] No `#` comment lines in this CSV file", vim.log.levels.INFO)
    return
  end

  local lines = {
    string.format(" 💬 CSV Comments (%d lines gathered across file)", #comments),
    " [<CR>] Jump to Nearby Data Row   [z / #] Toggle Top Inline Panel   [q] Close",
    string.rep("─", 88),
    string.format(" %-7s │ %-14s │ %s", "Line #", "Location", "Comment Text"),
    string.rep("─", 88),
  }

  for _, cm in ipairs(comments) do
    local loc
    if cm.before_header then
      loc = "Top Header"
    elseif (cm.after_rowid or 0) == 0 then
      loc = "After Header"
    elseif session.total_rows and (cm.after_rowid or 0) >= session.total_rows then
      loc = "Bottom Footer"
    else
      loc = string.format("After Row #%d", cm.after_rowid or 0)
    end
    table.insert(lines, string.format(" L%-6d │ %-14s │ %s", cm.line_num, loc, cm.text or ""))
  end

  local buf, win = create_float("CSV Comments Inspector", 92, math.min(28, #lines + 2), true)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvHeaderBanner", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvFooterCell", 1, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvHeaderNormal", 3, 0, -1)
  for i = 1, #comments do
    vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvCommentLineNr", 4 + i, 0, 9)
    vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvComment", 4 + i, 28, -1)
  end

  pcall(vim.api.nvim_win_set_cursor, win, { 6, 1 })

  local function close_modal()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "<CR>", function()
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local cm = comments[lnum - 5]
    if cm then
      local target_row = math.max(1, math.min(session.filtered_rows or session.total_rows or 1, (cm.after_rowid or 0) + 1))
      session.cur_row = target_row
      session.top_row = math.max(1, target_row - 3)
      close_modal()
      viewport.render(session)
    end
  end, { buffer = buf, nowait = true })

  for _, k in ipairs({ "c", "z", "#" }) do
    vim.keymap.set("n", k, function()
      session.comments_expanded = not session.comments_expanded
      close_modal()
      viewport.render(session)
    end, { buffer = buf, nowait = true })
  end

  vim.keymap.set("n", "q", close_modal, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close_modal, { buffer = buf, nowait = true })
end

--- 8. Keyboard Shortcuts & Commands Help Modal (`?` / `g?` / `<F1>` / `:SuperCsv help`)
function M.open_help(_session)
  local lines = {
    " 󰈛 SuperCsv.nvim — Keyboard Shortcuts & Commands Reference",
    " Press [q], [?], or [<Esc>] to close this window",
    string.rep("─", 86),
    " 💬 CSV COMMENTS (#)",
    "   c / # / z / za     │ Toggle (Show / Hide) collapsible # comments panel at top",
    "   zo / zc            │ Explicitly Expand (zo) or Collapse (zc) top # comments panel",
    "   g# / <leader>c#    │ Open scrollable CSV Comments Inspector popup (with row jump)",
    "   <LeftMouse>        │ Click the top comment bar to expand / collapse comments",
    string.rep("─", 86),
    " 🧭 2D GRID NAVIGATION",
    "   l / w / <Tab>      │ Next column right       h / b / <S-Tab> │ Previous column left",
    "   L / H              │ Page right / left cols  0 / $           │ First / Last column",
    "   j / k / <Up>/<Dn>  │ Next / Previous row     gg / G / [n]G   │ First / Last / Row N",
    "   <C-d> / <C-u>      │ Half-page down / up     <C-f> / <C-b>   │ Full-page down / up",
    "   gG                 │ Prompt to jump to row # gc / <leader>cc │ 100-Col Fuzzy Jumper",
    string.rep("─", 86),
    " 󰈲 FILTERING, GREP & SORTING",
    "   f                  │ Open Excel AutoFilter modal (check/uncheck distinct values)",
    "   /                  │ Filter current column by expression (> 100, = US, contains x)",
    "   fv / fx            │ Quick filter column == active cell (fv) or != active cell (fx)",
    "   F / <leader>cF     │ Clear filter on current column (F) or clear all filters/grep",
    "   g/                 │ Global grep search across all columns simultaneously",
    "   s / S              │ Sort current column Ascending ▲ (s) or Descending ▼ (S)",
    string.rep("─", 86),
    " 📊 ANALYTICS, RECORD CARD & SQL",
    "   gv                 │ Value Counts & Group-By frequency distribution modal",
    "   gs                 │ Column Summary Statistics (COUNT, DISTINCT, SUM, AVG, MIN, MAX)",
    "   K / <leader>cr     │ Toggle synchronized 100-Column Vertical Record Card split",
    "   gq / <leader>cq    │ Run custom SQL query against table `csv` (or `csv_data`)",
    string.rep("─", 86),
    " 🔒 FREEZE PANES, COLUMN WIDTHS & VIEW",
    "   gp                 │ Toggle Pin / Freeze 🔒 on current column",
    "   gh / gH            │ Hide current column (gh) / Restore all hidden columns (gH)",
    "   + / - / =          │ Widen (+) / Narrow (-) / Auto-fit (=) current column width",
    "   gm                 │ Toggle conditional numeric Heatmap coloring",
    "   gr / gz            │ Toggle alternating Row (gr) / Column (gz) zebra striping",
    "   <leader>cv         │ Switch back and forth between SuperCsv 2D grid & raw CSV text",
    string.rep("─", 86),
    " ✏️ EDITING, UNDO/REDO & SAVING",
    "   i / <CR> / <F2>    │ Edit active cell        o / dd          │ Insert / Delete row",
    "   yy / Y             │ Yank cell / Row as JSON u / <C-r>       │ Undo / Redo edit",
    "   <leader>cw / :w    │ Save edits to CSV file  ? / :SuperCsv ? │ Show this Help modal",
  }

  local buf, win = create_float("SuperCsv Shortcuts & Help (?)", 88, math.min(vim.o.lines - 4, #lines), true)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvHeaderBanner", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvFooterCell", 1, 0, -1)
  for idx, l in ipairs(lines) do
    if l:match("^ 💬") or l:match("^ 🧭") or l:match("^ 󰈲") or l:match("^ 📊") or l:match("^ 🔒") or l:match("^ ✏️") then
      vim.api.nvim_buf_add_highlight(buf, modal_ns, "SuperCsvHeaderNormal", idx - 1, 0, -1)
    end
  end

  local function close_modal()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, k in ipairs({ "q", "?", "<Esc>" }) do
    vim.keymap.set("n", k, close_modal, { buffer = buf, nowait = true, silent = true })
  end
  return buf, win
end

return M
