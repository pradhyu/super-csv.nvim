local M = {}

local parser = require("super-csv.engine.parser")
local sqlite = require("super-csv.engine.sqlite")
local config = require("super-csv.config")

local ns = vim.api.nvim_create_namespace("super_csv_viewport")

--- Pad or truncate a UTF-8 string to exact display width
local function fit_width(str, width, align_right)
  str = tostring(str == nil and "" or str):gsub("[\r\n\t]", " ")
  local dw = vim.fn.strdisplaywidth(str)
  if dw > width then
    if width <= 1 then
      return "…"
    end
    local cut = vim.fn.strcharpart(str, 0, width - 1)
    while vim.fn.strdisplaywidth(cut) > width - 1 and #cut > 0 do
      cut = vim.fn.strcharpart(cut, 0, vim.fn.strchars(cut) - 1)
    end
    local pad = width - 1 - vim.fn.strdisplaywidth(cut)
    return cut .. string.rep(" ", math.max(0, pad)) .. "…"
  end
  local pad = width - dw
  if align_right then
    return string.rep(" ", pad) .. str
  else
    return str .. string.rep(" ", pad)
  end
end

--- Compute which columns fit horizontally in the current window
function M.compute_visible_columns(session, win_width)
  local avail = math.max(40, (win_width or 100) - 9) -- reserve 8 chars for Row # gutter
  local pinned = {}
  local scrollable = {}
  local used = 0

  -- 1. Pinned columns first
  for c = 1, session.num_cols do
    if session.pinned_cols[c] and not session.hidden_cols[c] then
      local w = session.col_widths[c] or 14
      if used + w + 3 <= avail * 0.6 then
        table.insert(pinned, c)
        used = used + w + 3
      end
    end
  end

  -- Ensure left_col is valid and not hidden/pinned
  local start_col = math.max(1, math.min(session.left_col or 1, session.num_cols))
  for c = start_col, session.num_cols do
    if not session.pinned_cols[c] and not session.hidden_cols[c] then
      local w = session.col_widths[c] or 14
      if used + w + 3 > avail and #scrollable > 0 then
        break
      end
      table.insert(scrollable, c)
      used = used + w + 3
    end
  end

  -- If active cur_col is to the right of scrollable, advance left_col and recompute
  local cur = session.cur_col or 1
  if not session.pinned_cols[cur] and not session.hidden_cols[cur] then
    local found = false
    for _, c in ipairs(scrollable) do
      if c == cur then
        found = true
        break
      end
    end
    if not found then
      if cur < start_col then
        session.left_col = cur
        return M.compute_visible_columns(session, win_width)
      else
        -- Advance left_col until cur fits
        while session.left_col < cur do
          session.left_col = session.left_col + 1
          if not session.pinned_cols[session.left_col] and not session.hidden_cols[session.left_col] then
            local p2, s2 = M.compute_visible_columns_once(session, avail)
            for _, c in ipairs(s2) do
              if c == cur then
                return p2, s2
              end
            end
          end
        end
      end
    end
  end

  return pinned, scrollable
end

function M.compute_visible_columns_once(session, avail)
  local pinned = {}
  local scrollable = {}
  local used = 0
  for c = 1, session.num_cols do
    if session.pinned_cols[c] and not session.hidden_cols[c] then
      local w = session.col_widths[c] or 14
      if used + w + 3 <= avail * 0.6 then
        table.insert(pinned, c)
        used = used + w + 3
      end
    end
  end
  for c = session.left_col, session.num_cols do
    if not session.pinned_cols[c] and not session.hidden_cols[c] then
      local w = session.col_widths[c] or 14
      if used + w + 3 > avail and #scrollable > 0 then
        break
      end
      table.insert(scrollable, c)
      used = used + w + 3
    end
  end
  return pinned, scrollable
end

--- Format a number cleanly with commas
local function fmt_num(n, is_float)
  if type(n) ~= "number" then
    return tostring(n or "")
  end
  local s = is_float and string.format("%.2f", n) or tostring(math.floor(n + 0.5))
  local sign, int_part, dec_part = s:match("^([%-]?)(%d+)(%.?%d*)$")
  if not int_part then
    return s
  end
  int_part = int_part:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return sign .. int_part .. dec_part
end

--- Render the 2D Excel Virtual Viewport into session.view_buf
function M.render(session)
  if not session or not session.view_buf or not vim.api.nvim_buf_is_valid(session.view_buf) then
    return
  end
  config = require("super-csv.config")
  local win = session.view_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.fn.bufwinid(session.view_buf)
    session.view_win = win
  end
  local win_width = (win and win ~= -1) and vim.api.nvim_win_get_width(win) or vim.o.columns
  local win_height = (win and win ~= -1) and vim.api.nvim_win_get_height(win) or (vim.o.lines - 4)
  local has_winbar = (win and win ~= -1) and ((vim.wo[win].winbar or "") ~= "") or false
  local usable_height = win_height - (has_winbar and 1 or 0)
  local footer_lines = config.options.show_footer_stats and 3 or 2

  local body_height = math.max(3, usable_height - 5 - footer_lines)
  session.page_size = body_height

  -- If streaming batches directly from file (before SQLite is indexed), load the next batch as the user scrolls near the edge
  if not session.sqlite_ready and not session.eof_reached then
    local needed_row = math.max(session.cur_row or 1, (session.top_row or 1) + body_height) + 40
    if needed_row > #(session.preview_rows or {}) then
      parser.ensure_rows_loaded(session, needed_row)
    end
  end

  -- Clamp cur_row & top_row
  local total_before = session.filtered_rows or session.total_rows or #session.preview_rows
  if total_before > 0 then
    session.cur_row = math.max(1, math.min(session.cur_row or 1, total_before))
  else
    session.cur_row = 1
  end
  if session.cur_row < session.top_row then
    session.top_row = session.cur_row
  elseif session.cur_row >= session.top_row + body_height then
    session.top_row = session.cur_row - body_height + 1
  end
  session.top_row = math.max(1, session.top_row or 1)

  -- Fetch visible rows from Batch Cache / SQLite (or streamed file batches)
  local rows, total_filtered = sqlite.fetch_viewport_rows(session, session.top_row - 1, body_height)
  session.visible_rows = rows
  session.filtered_rows = total_filtered

  if total_filtered > 0 and session.cur_row > total_filtered then
    session.cur_row = total_filtered
    session.top_row = math.max(1, session.cur_row - body_height + 1)
    rows, total_filtered = sqlite.fetch_viewport_rows(session, session.top_row - 1, body_height)
    session.visible_rows = rows
  end

  local pinned_cols, scroll_cols = M.compute_visible_columns(session, win_width)
  local vis_cols = {}
  for _, c in ipairs(pinned_cols) do
    table.insert(vis_cols, { col = c, pinned = true })
  end
  for _, c in ipairs(scroll_cols) do
    table.insert(vis_cols, { col = c, pinned = false })
  end
  session.vis_cols = vis_cols

  local lines = {}
  local hl_ops = {} -- { line_0, col_start_byte, col_end_byte, hl_group }

  local function add_hl(l0, s_byte, e_byte, group)
    if group and e_byte > s_byte then
      table.insert(hl_ops, { l0, s_byte, e_byte, group })
    end
  end

  -- 1. Top Excel Status & Filter Banner
  local active_filters = 0
  local filter_tags = {}
  for c_idx, flt in pairs(session.filters or {}) do
    if flt then
      active_filters = active_filters + 1
      local cname = session.headers[c_idx] or ("#" .. c_idx)
      if flt.op and flt.op ~= "" then
        table.insert(filter_tags, string.format("%s %s %s", cname, flt.op, tostring(flt.val or "")))
      elseif flt.values then
        local cnt = 0
        for _, en in pairs(flt.values) do
          if en then cnt = cnt + 1 end
        end
        table.insert(filter_tags, string.format("%s (%d vals)", cname, cnt))
      end
    end
  end

  local engine_badge
  if session.sqlite_ready then
    local bc = session.batch_cache
    if bc then
      engine_badge = string.format("󰆼 Batch [%s..%s]", fmt_num(bc.start_row), fmt_num(bc.end_row))
    else
      engine_badge = "󰆼 SQLite Batch"
    end
  elseif session.sqlite_indexing then
    engine_badge = "󱥸 Indexing..."
  else
    engine_badge = session.eof_reached and "⚡ Memory Batch" or string.format("⚡ Batch Stream (%s loaded)", fmt_num(#(session.preview_rows or {})))
  end
  local total_suffix = (not session.sqlite_ready and not session.eof_reached) and "+" or ""
  local row_summary = (active_filters > 0 or (session.grep_pattern and session.grep_pattern ~= ""))
    and string.format("Rows: %s / %s%s (Filtered)", fmt_num(total_filtered), fmt_num(session.total_rows or total_filtered), total_suffix)
    or string.format("Row %s / %s%s", fmt_num(session.cur_row), fmt_num(total_filtered), total_suffix)
  local col_summary = string.format("Col %s #%d / %d", parser.col_to_excel(session.cur_col), session.cur_col, session.num_cols)
  local filter_str = (#filter_tags > 0) and (" │ 󰈲 " .. table.concat(filter_tags, ", ")) or ""
  local grep_str = (session.grep_pattern and session.grep_pattern ~= "") and (" │  /" .. session.grep_pattern .. "/") or ""
  local edit_str = ((session.edit_count or 0) > 0) and string.format(" │ ● %d unsaved", session.edit_count) or ""

  local banner = string.format(
    " 󰈛 %s │ %s │ %s │ %s%s%s%s ",
    vim.fn.fnamemodify(session.filepath, ":t"),
    engine_badge,
    row_summary,
    col_summary,
    filter_str,
    grep_str,
    edit_str
  )
  banner = fit_width(banner, win_width, false)
  table.insert(lines, banner)
  add_hl(0, 0, #banner, "SuperCsvHeaderBanner")

  -- Helper to build horizontal border lines
  local row_gutter_w = 7
  local function build_border(left_ch, mid_ch, pin_mid_ch, right_ch, fill_ch)
    local parts = { left_ch .. string.rep(fill_ch, row_gutter_w) }
    for idx, vc in ipairs(vis_cols) do
      local w = session.col_widths[vc.col] or 14
      local sep = mid_ch
      if idx > 1 and vis_cols[idx - 1].pinned and not vc.pinned then
        sep = pin_mid_ch
      end
      table.insert(parts, sep .. string.rep(fill_ch, w + 2))
    end
    table.insert(parts, right_ch)
    return table.concat(parts)
  end

  local top_border = build_border("┏", "┳", "╦", "┓", "━")
  table.insert(lines, top_border)
  add_hl(#lines - 1, 0, #top_border, "SuperCsvBorderPinned")

  -- 2. Prominent Frozen Header Row 1 (Excel Letter + #Index + Lock/Sort/Filter icons)
  --    & Header Row 2 (Column Name + [Type])
  local function build_header_line(is_second_line)
    local l_idx = #lines
    local segs = {}
    local seg_hls = {}
    local cur_byte = 0

    local function push(txt, hl)
      table.insert(segs, txt)
      if hl then
        table.insert(seg_hls, { cur_byte, cur_byte + #txt, hl })
      end
      cur_byte = cur_byte + #txt
    end

    push("┃", "SuperCsvBorderPinned")
    local gutter_label = is_second_line and fit_width("  ROW #", row_gutter_w, false) or fit_width("  EXCEL", row_gutter_w, false)
    push(gutter_label, "SuperCsvHeaderPinned")

    for idx, vc in ipairs(vis_cols) do
      local c = vc.col
      local w = session.col_widths[c] or 14
      local is_pin_sep = (idx > 1 and vis_cols[idx - 1].pinned and not vc.pinned)
      push(is_pin_sep and "║" or "┃", is_pin_sep and "SuperCsvBorderPinned" or "SuperCsvBorder")

      local h_hl = vc.pinned and "SuperCsvHeaderPinned" or "SuperCsvHeaderNormal"
      if session.filters and session.filters[c] then
        h_hl = "SuperCsvHeaderFiltered"
      end
      if c == session.cur_col then
        h_hl = "SuperCsvHeaderActive"
      end

      local cell_txt
      if not is_second_line then
        local letter = parser.col_to_excel(c)
        local badges = {}
        if vc.pinned then table.insert(badges, "🔒") end
        if session.filters and session.filters[c] then table.insert(badges, "󰈲") end
        if session.sort and session.sort.col_idx == c then
          table.insert(badges, session.sort.dir == "DESC" and "▼" or "▲")
        end
        local b_str = (#badges > 0) and (" " .. table.concat(badges, "")) or ""
        local t_badge = "[" .. (session.types[c] or "str") .. "]"
        local left_part = string.format("%s #%d%s", letter, c, b_str)
        local space = math.max(1, w - vim.fn.strdisplaywidth(left_part) - vim.fn.strdisplaywidth(t_badge))
        cell_txt = " " .. fit_width(left_part .. string.rep(" ", space) .. t_badge, w, false) .. " "
      else
        cell_txt = " " .. fit_width(session.headers[c] or ("col_" .. c), w, false) .. " "
      end

      push(cell_txt, h_hl)
    end
    push("┃", "SuperCsvBorderPinned")

    local full = table.concat(segs)
    table.insert(lines, full)
    for _, h in ipairs(seg_hls) do
      add_hl(l_idx, h[1], h[2], h[3])
    end
  end

  build_header_line(false)
  build_header_line(true)

  local mid_border = build_border("┣", "╋", "╬", "┫", "━")
  table.insert(lines, mid_border)
  add_hl(#lines - 1, 0, #mid_border, "SuperCsvBorderPinned")

  -- Precompute column min/max from current batch if heatmap is active (instant < 0.1ms)
  local col_minmax = {}
  if config.options.heatmap then
    for _, vc in ipairs(vis_cols) do
      local c = vc.col
      if session.types[c] == "i64" or session.types[c] == "f64" then
        local st = sqlite.get_fast_column_stats(session, c)
        if st and type(st.min) == "number" and type(st.max) == "number" and st.max > st.min then
          col_minmax[c] = { min = st.min, max = st.max }
        end
      end
    end
  end

  -- 3. Data Grid Rows (Alternating Column Shading + Crosshair Active Row & Active Cell)
  local active_cell_raw = ""
  local active_rowid = 0

  if #rows == 0 then
    local empty_line = "┃ " .. fit_width("No rows match the active filter / grep criteria. Press 'F' or '<leader>cF' to clear filters.", win_width - 4, false) .. " ┃"
    table.insert(lines, empty_line)
    add_hl(#lines - 1, 0, #empty_line, "SuperCsvTypeNull")
  else
    for r_offset, row_obj in ipairs(rows) do
      local abs_row = session.top_row + r_offset - 1
      local is_cur_row = (abs_row == session.cur_row)
      local l_idx = #lines
      local segs = {}
      local seg_hls = {}
      local cur_byte = 0

      local function push(txt, hl)
        table.insert(segs, txt)
        if hl then
          table.insert(seg_hls, { cur_byte, cur_byte + #txt, hl })
        end
        cur_byte = cur_byte + #txt
      end

      push("│", "SuperCsvBorder")
      local r_num_txt = fit_width(tostring(row_obj.rowid or abs_row) .. " ", row_gutter_w, true)
      push(r_num_txt, is_cur_row and "SuperCsvHeaderActive" or "SuperCsvHeaderType")

      for idx, vc in ipairs(vis_cols) do
        local c = vc.col
        local w = session.col_widths[c] or 14
        local is_pin_sep = (idx > 1 and vis_cols[idx - 1].pinned and not vc.pinned)
        push(is_pin_sep and "║" or "│", is_pin_sep and "SuperCsvBorderPinned" or "SuperCsvBorder")

        local raw_val = row_obj.cells[c] or ""
        local is_cur_cell = (is_cur_row and c == session.cur_col)
        if is_cur_cell then
          active_cell_raw = raw_val
          active_rowid = row_obj.rowid or abs_row
        end

        local ctype = session.types[c]
        local align_right = (ctype == "i64" or ctype == "f64")
        local disp_val = raw_val
        if raw_val == "" then
          disp_val = "∅"
        end
        local cell_str = " " .. fit_width(disp_val, w, align_right) .. " "

        -- Determine highlight group with Excel priority:
        -- Active Cell > Modified Cell > Grep Match > Heatmap > Active Row > Pinned Col > Alternating Row/Col
        local cell_hl
        local is_mod = session.modified_cells and session.modified_cells[row_obj.rowid] and session.modified_cells[row_obj.rowid][c] ~= nil
        local is_grep_match = (session.grep_pattern and session.grep_pattern ~= "" and raw_val:lower():find(session.grep_pattern:lower(), 1, true) ~= nil)
        local is_even_row = (r_offset % 2 == 0)
        local is_even_col = (idx % 2 == 0)

        if is_cur_cell then
          cell_hl = "SuperCsvCursorCell"
        elseif is_mod then
          cell_hl = "SuperCsvCellModified"
        elseif is_grep_match then
          cell_hl = "SuperCsvCellMatch"
        elseif col_minmax[c] and raw_val ~= "" then
          local nv = tonumber((raw_val:gsub("^%$", ""):gsub(",", "")))
          if nv then
            local ratio = (nv - col_minmax[c].min) / (col_minmax[c].max - col_minmax[c].min)
            cell_hl = (ratio >= 0.66) and "SuperCsvHeatHigh" or ((ratio >= 0.33) and "SuperCsvHeatMid" or "SuperCsvHeatLow")
          end
        elseif is_cur_row then
          cell_hl = "SuperCsvCursorRow"
        elseif vc.pinned then
          if config.options.zebra_rows then
            cell_hl = is_even_row and "SuperCsvColPinnedEven" or "SuperCsvColPinnedOdd"
          else
            cell_hl = "SuperCsvColPinned"
          end
        elseif config.options.zebra_rows and config.options.zebra_columns then
          if is_even_row then
            cell_hl = is_even_col and "SuperCsvRowEvenColEven" or "SuperCsvRowEvenColOdd"
          else
            cell_hl = is_even_col and "SuperCsvRowOddColEven" or "SuperCsvRowOddColOdd"
          end
        elseif config.options.zebra_rows then
          cell_hl = is_even_row and "SuperCsvRowEvenColOdd" or "SuperCsvRowOddColOdd"
        elseif config.options.zebra_columns then
          cell_hl = is_even_col and "SuperCsvColEven" or "SuperCsvColOdd"
        else
          cell_hl = "SuperCsvColOdd"
        end

        push(cell_str, cell_hl)
      end

      push("│", "SuperCsvBorder")
      local full_row = table.concat(segs)
      table.insert(lines, full_row)
      for _, h in ipairs(seg_hls) do
        add_hl(l_idx, h[1], h[2], h[3])
      end
    end
  end

  local bot_border = build_border("┗", "┻", "╩", "┛", "━")
  table.insert(lines, bot_border)
  add_hl(#lines - 1, 0, #bot_border, "SuperCsvBorderPinned")

  -- 4. Excel Bottom Summary Bar (COUNT, DISTINCT, NULLS, SUM, AVG, MIN, MAX over current batch)
  if config.options.show_footer_stats then
    local st = sqlite.get_fast_column_stats(session, session.cur_col)
    local cname = session.headers[session.cur_col] or ("col_" .. session.cur_col)
    local col_letter = parser.col_to_excel(session.cur_col)
    local stats_line
    if st.is_numeric then
      stats_line = string.format(
        " 📊 %s #%d (%s) │ COUNT: %s │ DISTINCT: %s │ NULL: %s │ SUM: %s │ AVG: %s │ MIN: %s │ MAX: %s ",
        col_letter,
        session.cur_col,
        cname,
        fmt_num(st.count),
        fmt_num(st.distinct),
        fmt_num(st.nulls),
        fmt_num(st.sum, true),
        fmt_num(st.avg, true),
        fmt_num(st.min, true),
        fmt_num(st.max, true)
      )
    else
      stats_line = string.format(
        " 📊 %s #%d (%s) │ COUNT: %s │ DISTINCT: %s │ NULL: %s │ MIN: %s │ MAX: %s ",
        col_letter,
        session.cur_col,
        cname,
        fmt_num(st.count),
        fmt_num(st.distinct),
        fmt_num(st.nulls),
        tostring(st.min),
        tostring(st.max)
      )
    end
    stats_line = fit_width(stats_line, win_width, false)
    table.insert(lines, stats_line)
    add_hl(#lines - 1, 0, #stats_line, "SuperCsvFooterSummary")
  end

  -- 5. Active Cell Inspector & Quick Keys Bar
  local cell_coord = string.format("%s%d", parser.col_to_excel(session.cur_col), active_rowid > 0 and active_rowid or session.cur_row)
  local inspector_line = string.format(
    " [%s] %s = %s │ [f]Filter [gv]Counts [g/]Grep [s/S]Sort [gp]Pin [gr]ZebraRows [<leader>cv]NormalCSV ",
    cell_coord,
    session.headers[session.cur_col] or "",
    active_cell_raw == "" and "NULL" or vim.inspect(active_cell_raw)
  )
  inspector_line = fit_width(inspector_line, win_width, false)
  table.insert(lines, inspector_line)
  add_hl(#lines - 1, 0, #inspector_line, "SuperCsvFooterCell")

  -- Write lines & apply extmarks atomically
  vim.bo[session.view_buf].modifiable = true
  vim.api.nvim_buf_set_lines(session.view_buf, 0, -1, false, lines)
  vim.bo[session.view_buf].modifiable = false
  vim.bo[session.view_buf].modified = false

  vim.api.nvim_buf_clear_namespace(session.view_buf, ns, 0, -1)
  for _, op in ipairs(hl_ops) do
    pcall(vim.api.nvim_buf_set_extmark, session.view_buf, ns, op[1], op[2], {
      end_col = op[3],
      hl_group = op[4],
      priority = 200,
    })
  end

  -- Position Neovim cursor on the active row line and lock topline=1 so header NEVER scrolls out of view
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].scrolloff = 0
    vim.wo[win].sidescrolloff = 0
    local target_buf_line = math.max(6, math.min(#lines - footer_lines, 6 + (session.cur_row - session.top_row)))
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview({
        topline = 1,
        leftcol = 0,
        lnum = math.min(#lines, target_buf_line),
        col = 0,
      })
    end)
  end

  -- If Vertical Record Card split is open, keep it synchronized!
  if session.record_win and vim.api.nvim_win_is_valid(session.record_win) then
    require("super-csv.ui.modals").refresh_record_card(session)
  end
end

return M
