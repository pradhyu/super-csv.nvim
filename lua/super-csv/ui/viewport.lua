local M = {}

local parser = require("super-csv.engine.parser")
local json_engine = require("super-csv.engine.json")
local sqlite = require("super-csv.engine.sqlite")
local config = require("super-csv.config")

local ns = vim.api.nvim_create_namespace("super_csv_viewport")

local BORDER_SETS = {
  heavy = {
    top = { "┏", "┳", "╦", "┓", "━" },
    mid = { "┣", "╋", "╬", "┫", "━" },
    bot = { "┗", "┻", "╩", "┛", "━" },
    v_outer = "┃",
    v_inner = "│",
    v_pin   = "║",
    sub_top_l = "  ┏━",
    sub_fill = "━",
    sub_top_r = "┓",
  },
  ascii = {
    top = { "+", "+", "+", "+", "-" },
    mid = { "+", "+", "+", "+", "=" },
    bot = { "+", "+", "+", "+", "-" },
    v_outer = "|",
    v_inner = "|",
    v_pin   = "|",
    sub_top_l = "  +-",
    sub_fill = "-",
    sub_top_r = "+",
  },
  single = {
    top = { "┌", "┬", "┬", "┐", "─" },
    mid = { "├", "┼", "┼", "┤", "─" },
    bot = { "└", "┴", "┴", "┘", "─" },
    v_outer = "│",
    v_inner = "│",
    v_pin   = "║",
    sub_top_l = "  ┌─",
    sub_fill = "─",
    sub_top_r = "┐",
  },
  rounded = {
    top = { "╭", "┬", "┬", "╮", "─" },
    mid = { "├", "┼", "┼", "┤", "─" },
    bot = { "╰", "┴", "┴", "╯", "─" },
    v_outer = "│",
    v_inner = "│",
    v_pin   = "║",
    sub_top_l = "  ╭─",
    sub_fill = "─",
    sub_top_r = "╮",
  },
}

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

  -- Backfill columns to the left of start_col if scrolled near the right edge and screen space remains
  local back_col = start_col - 1
  while back_col >= 1 and used < avail do
    if not session.pinned_cols[back_col] and not session.hidden_cols[back_col] then
      local w = session.col_widths[back_col] or 14
      if used + w + 3 <= avail then
        table.insert(scrollable, 1, back_col)
        used = used + w + 3
      else
        break
      end
    end
    back_col = back_col - 1
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
  require("super-csv.highlights").ensure_synced()
  config = require("super-csv.config")
  local win = session.view_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.fn.bufwinid(session.view_buf)
    session.view_win = win
  end
  local is_headless = (#vim.api.nvim_list_uis() == 0)
  local single_win = (#vim.api.nvim_tabpage_list_wins(0) <= 1)
  local win_width = (win and win ~= -1) and vim.api.nvim_win_get_width(win) or vim.o.columns
  local win_height = (win and win ~= -1) and vim.api.nvim_win_get_height(win) or (vim.o.lines - 4)
  if is_headless and single_win then
    local env_cols = tonumber(vim.env.COLUMNS) or 160
    win_width = math.max(win_width, vim.o.columns > 80 and vim.o.columns or env_cols)
    win_height = math.max(win_height, vim.o.lines > 24 and (vim.o.lines - 2) or 30)
  end
  local has_winbar = (win and win ~= -1) and ((vim.wo[win].winbar or "") ~= "") or false
  local usable_height = win_height - (has_winbar and 1 or 0)
  local footer_lines = config.options.show_footer_stats and 3 or 2

  local comments = session.comments or {}
  local num_comments = #comments
  local max_inline_comments = math.max(4, math.min(num_comments, math.floor(usable_height * 0.45)))
  if num_comments == max_inline_comments + 1 then
    max_inline_comments = num_comments
  end
  local comment_section_lines = 0
  if num_comments > 0 then
    if session.comments_expanded then
      comment_section_lines = 1 + max_inline_comments + (num_comments > max_inline_comments and 1 or 0)
    else
      comment_section_lines = 1
    end
  end
  local has_nested_headers = false
  for c = 1, (session.num_cols or 0) do
    local h = session.headers and session.headers[c] or ""
    if h:find(".", 1, true) then
      has_nested_headers = true
      break
    end
  end

  local header_lines_count = (has_nested_headers and 6 or 5) + comment_section_lines
  session.header_lines_count = header_lines_count

  local body_height = math.max(3, usable_height - header_lines_count - footer_lines)
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
  local hl_ops = {} -- { line_0, col_start_byte, col_end_byte, hl_group, priority }

  local function add_hl(l0, s_byte, e_byte, group, prio)
    if group and e_byte > s_byte then
      table.insert(hl_ops, { l0, s_byte, e_byte, group, prio or 200 })
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

  local last_vis_col = (#vis_cols > 0) and vis_cols[#vis_cols].col or session.cur_col
  local more_right = math.max(0, session.num_cols - last_vis_col)
  local col_range_hint = (more_right > 0) and string.format(" (+%d→ l/L)", more_right) or ""
  local col_summary = string.format("Col %s #%d/%d%s", parser.col_to_excel(session.cur_col), session.cur_col, session.num_cols, col_range_hint)
  local filter_str = (#filter_tags > 0) and (" │ 󰈲 " .. table.concat(filter_tags, ", ")) or ""
  local grep_str = (session.grep_pattern and session.grep_pattern ~= "") and (" │  /" .. session.grep_pattern .. "/") or ""
  local comment_badge_str = (num_comments > 0) and string.format(" │ 💬 %d [c/#]", num_comments) or ""
  local edit_str = ((session.edit_count or 0) > 0) and string.format(" │ ● %d unsaved", session.edit_count) or ""

  local banner = string.format(
    " 󰈛 %s │ %s │ %s │ %s%s │ [?]Help%s%s%s ",
    session.display_filename or vim.fn.fnamemodify(session.filepath, ":t"),
    engine_badge,
    row_summary,
    col_summary,
    comment_badge_str,
    filter_str,
    grep_str,
    edit_str
  )
  banner = fit_width(banner, win_width, false)
  table.insert(lines, banner)
  add_hl(0, 0, #banner, "SuperCsvHeaderBanner")

  local border_style = (session.border_style or config.options.border_style or "heavy"):lower()
  local bs = BORDER_SETS[border_style] or BORDER_SETS.heavy

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

  local top_border = build_border(bs.top[1], bs.top[2], bs.top[3], bs.top[4], bs.top[5])
  local grid_display_w = vim.fn.strdisplaywidth(top_border)

  -- 1b. Collapsible Top Comments Section (shows all `#` comments from anywhere in the CSV with their file line numbers)
  if num_comments > 0 then
    local lnums = {}
    for i = 1, math.min(num_comments, 6) do
      table.insert(lnums, "L" .. tostring(comments[i].line_num))
    end
    if num_comments > 6 then
      table.insert(lnums, "… L" .. tostring(comments[num_comments].line_num))
    end
    local lnum_summary = table.concat(lnums, ", ")

    session.comment_bar_line = #lines + 1
    if not session.comments_expanded then
      local first_preview = (comments[1].text or ""):gsub("^%s*#%s*", "# ")
      local collapsed_bar = string.format(
        " ▶ [c / # / z] Show # Comments (%d line%s: %s) — %s ",
        num_comments,
        num_comments == 1 and "" or "s",
        lnum_summary,
        first_preview
      )
      collapsed_bar = fit_width(collapsed_bar, win_width, false)
      table.insert(lines, collapsed_bar)
      add_hl(#lines - 1, 0, #collapsed_bar, "SuperCsvCommentBar")
      session.comment_end_line = #lines
    else
      local expanded_bar = string.format(
        " ▼ [c / # / z] Hide # Comments (%d line%s at top: %s) │ [g#] All Comments Popup ",
        num_comments,
        num_comments == 1 and "" or "s",
        lnum_summary
      )
      expanded_bar = fit_width(expanded_bar, win_width, false)
      table.insert(lines, expanded_bar)
      add_hl(#lines - 1, 0, #expanded_bar, "SuperCsvCommentBar")

      local box_w = math.max(grid_display_w, math.min(win_width, 90))
      local text_avail = math.max(20, box_w - row_gutter_w - 5)
      for i = 1, max_inline_comments do
        local cm = comments[i]
        local l_idx = #lines
        local b_left = bs.v_outer
        local lnr_str = fit_width(string.format(" L%-4d", cm.line_num), row_gutter_w, false)
        local b_mid = bs.v_inner
        local c_body = " " .. fit_width(cm.text or "", text_avail, false) .. " "
        local b_right = bs.v_outer
        local full_cm = b_left .. lnr_str .. b_mid .. c_body .. b_right
        table.insert(lines, full_cm)

        local p1 = #b_left
        local p2 = p1 + #lnr_str
        local p3 = p2 + #b_mid
        local p4 = p3 + #c_body
        add_hl(l_idx, 0, p1, "SuperCsvBorderPinned")
        add_hl(l_idx, p1, p2, "SuperCsvCommentLineNr")
        add_hl(l_idx, p2, p3, "SuperCsvBorder")
        add_hl(l_idx, p3, p4, "SuperCsvComment")
        add_hl(l_idx, p4, #full_cm, "SuperCsvBorderPinned")
      end

      if num_comments > max_inline_comments then
        local more_cnt = num_comments - max_inline_comments
        local l_idx = #lines
        local b_left = bs.v_outer
        local lnr_str = fit_width("  ...", row_gutter_w, false)
        local b_mid = bs.v_inner
        local more_txt = string.format(" ... +%d more comment lines (press g# to view all %d comments)", more_cnt, num_comments)
        local c_body = " " .. fit_width(more_txt, text_avail, false) .. " "
        local b_right = bs.v_outer
        local full_more = b_left .. lnr_str .. b_mid .. c_body .. b_right
        table.insert(lines, full_more)
        add_hl(l_idx, 0, #full_more, "SuperCsvCommentBar")
      end
      session.comment_end_line = #lines
    end
  else
    session.comment_bar_line = nil
    session.comment_end_line = nil
  end

  table.insert(lines, top_border)
  add_hl(#lines - 1, 0, #top_border, "SuperCsvBorderPinned")

  -- 2. Prominent Frozen Header Row 1 (Excel Letter + #Index + Lock/Sort/Filter icons),
  --    Optional Nested Parent Table Row (spans across sibling attributes of nested JSON tables),
  --    & Leaf Column Attribute Header Row
  local use_rainbow = (config.options.rainbow_columns ~= false)
  local function col_rainbow_idx(c)
    return ((c - 1) % 10) + 1
  end

  local function split_nested_header(h)
    h = tostring(h or "")
    local parent, leaf = h:match("^(.+)%.([^%.]+)$")
    if parent and leaf then
      if tonumber(leaf) then
        leaf = "#" .. leaf
      end
      return parent, leaf
    end
    return nil, h
  end

  local function build_nested_parent_header_line()
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

    push(bs.v_outer, "SuperCsvBorderPinned")
    push(fit_width("  TABLE", row_gutter_w, false), "SuperCsvHeaderPinned")

    local idx = 1
    local n_vis = #vis_cols
    while idx <= n_vis do
      local vc = vis_cols[idx]
      local c = vc.col
      local parent = split_nested_header(session.headers[c] or ("col_" .. c))
      local is_pin_sep = (idx > 1 and vis_cols[idx - 1].pinned and not vc.pinned)
      push(is_pin_sep and bs.v_pin or bs.v_outer, is_pin_sep and "SuperCsvBorderPinned" or "SuperCsvBorder")

      if parent then
        -- Find contiguous visible columns belonging to the same nested parent table and pin state
        local end_idx = idx
        local span_w = session.col_widths[c] or 14
        local has_active = (c == session.cur_col)
        local has_filter = (session.filters and session.filters[c] ~= nil)
        while end_idx + 1 <= n_vis do
          local next_vc = vis_cols[end_idx + 1]
          local next_parent = split_nested_header(session.headers[next_vc.col] or "")
          if next_parent == parent and next_vc.pinned == vc.pinned then
            end_idx = end_idx + 1
            span_w = span_w + (session.col_widths[next_vc.col] or 14) + 3
            if next_vc.col == session.cur_col then has_active = true end
            if session.filters and session.filters[next_vc.col] then has_filter = true end
          else
            break
          end
        end
        local group_cnt = end_idx - idx + 1
        local total_for_parent = 0
        for sc = 1, (session.num_cols or 0) do
          local sp = split_nested_header(session.headers[sc] or "")
          if sp == parent then
            total_for_parent = total_for_parent + 1
          end
        end
        local h_hl = use_rainbow and ("SuperCsvRainbowHeader" .. col_rainbow_idx(c)) or "SuperCsvHeaderPinned"
        if has_filter then h_hl = "SuperCsvHeaderFiltered" end
        if has_active then h_hl = "SuperCsvHeaderActive" end

        local group_label
        if total_for_parent > group_cnt then
          group_label = string.format("󰙅 %s (%d/%d cols)", parent, group_cnt, total_for_parent)
        elseif total_for_parent > 1 then
          group_label = string.format("󰙅 %s (%d cols)", parent, total_for_parent)
        else
          group_label = string.format("󰙅 %s", parent)
        end
        local cell_txt = " " .. fit_width(group_label, span_w, false) .. " "
        push(cell_txt, h_hl)
        idx = end_idx + 1
      else
        local w = session.col_widths[c] or 14
        local h_hl = "SuperCsvHeaderType"
        if c == session.cur_col then
          h_hl = "SuperCsvHeaderActive"
        end
        local cell_txt = " " .. fit_width("─", w, false) .. " "
        push(cell_txt, h_hl)
        idx = idx + 1
      end
    end

    push(bs.v_outer, "SuperCsvBorderPinned")
    local full = table.concat(segs)
    table.insert(lines, full)
    for _, h in ipairs(seg_hls) do
      add_hl(l_idx, h[1], h[2], h[3])
    end
  end

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

    push(bs.v_outer, "SuperCsvBorderPinned")
    local gutter_label = is_second_line and fit_width("  ROW #", row_gutter_w, false) or fit_width("  EXCEL", row_gutter_w, false)
    push(gutter_label, "SuperCsvHeaderPinned")

    for idx, vc in ipairs(vis_cols) do
      local c = vc.col
      local w = session.col_widths[c] or 14
      local is_pin_sep = (idx > 1 and vis_cols[idx - 1].pinned and not vc.pinned)
      push(is_pin_sep and bs.v_pin or bs.v_outer, is_pin_sep and "SuperCsvBorderPinned" or "SuperCsvBorder")

      local h_hl
      if use_rainbow then
        h_hl = "SuperCsvRainbowHeader" .. col_rainbow_idx(c)
      else
        h_hl = vc.pinned and "SuperCsvHeaderPinned" or "SuperCsvHeaderNormal"
      end
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
        local raw_hdr = session.headers[c] or ("col_" .. c)
        local _, leaf = split_nested_header(raw_hdr)
        cell_txt = " " .. fit_width(has_nested_headers and leaf or raw_hdr, w, false) .. " "
      end

      push(cell_txt, h_hl)
    end
    push(bs.v_outer, "SuperCsvBorderPinned")

    local full = table.concat(segs)
    table.insert(lines, full)
    for _, h in ipairs(seg_hls) do
      add_hl(l_idx, h[1], h[2], h[3])
    end
  end

  build_header_line(false)
  if has_nested_headers then
    build_nested_parent_header_line()
  end
  build_header_line(true)

  local mid_border = build_border(bs.mid[1], bs.mid[2], bs.mid[3], bs.mid[4], bs.mid[5])
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

  -- 3. Data Grid Rows (Alternating Column Shading + Crosshair Active Row & Active Cell + Inline Subtables)
  local active_cell_raw = ""
  local active_rowid = 0
  local active_row_buf_line = nil

  local function render_inline_subtable(st, col_name, parent_rowid)
    local max_sub_rows = math.min(st.num_rows, 6)
    local sub_cols = math.min(st.num_cols, 8)
    local sub_widths = {}
    for sc = 1, sub_cols do
      local sh = st.headers[sc] or ("col_" .. sc)
      local mw = math.max(#sh + 2, 10)
      for sr = 1, max_sub_rows do
        local sv = tostring((st.rows[sr] and st.rows[sr][sc]) or "")
        if sv:sub(1, 1) == "[" then
          sv = json_engine.format_subtable_preview(sv)
        end
        if #sv + 2 > mw then mw = #sv + 2 end
      end
      sub_widths[sc] = math.min(28, mw)
    end

    local inner_avail = math.max(30, grid_display_w - row_gutter_w - 3)
    local title_txt = string.format(
      " 󰙅 Subtable [%s] (Row #%d: %d row%s × %d col%s) │ [<CR>] Open Full Subtable  [gt] Hide Inline  [i] Edit JSON",
      col_name,
      parent_rowid,
      st.num_rows,
      st.num_rows == 1 and "" or "s",
      st.num_cols,
      st.num_cols == 1 and "" or "s"
    )
    local vi = bs.v_inner
    local title_line = vi .. fit_width("  ↳ SUB", row_gutter_w, false) .. vi .. fit_width(title_txt, inner_avail, false) .. vi
    local t_idx = #lines
    table.insert(lines, title_line)
    local p1 = #vi
    local p2 = p1 + #fit_width("  ↳ SUB", row_gutter_w, false)
    local p3 = p2 + #vi
    add_hl(t_idx, 0, p1, "SuperCsvBorderPinned")
    add_hl(t_idx, p1, p2, "SuperCsvHeaderPinned")
    add_hl(t_idx, p2, p3, "SuperCsvBorderPinned")
    add_hl(t_idx, p3, #title_line - #vi, "SuperCsvHeaderBanner")
    add_hl(t_idx, #title_line - #vi, #title_line, "SuperCsvBorderPinned")

    -- Build subtable column header line
    local hdr_parts = { "  #  " }
    for sc = 1, sub_cols do
      table.insert(hdr_parts, " " .. fit_width(st.headers[sc] or ("c" .. sc), sub_widths[sc], false) .. " ")
    end
    if st.num_cols > sub_cols then
      table.insert(hdr_parts, string.format(" (+%d cols) ", st.num_cols - sub_cols))
    end
    local sub_hdr_body = bs.sub_top_l .. string.rep(bs.sub_fill, math.min(inner_avail - 6, vim.fn.strdisplaywidth(table.concat(hdr_parts, vi)))) .. bs.sub_top_r
    local sh_line = vi .. string.rep(" ", row_gutter_w) .. vi .. " " .. fit_width(vi .. table.concat(hdr_parts, vi) .. vi, inner_avail - 1, false) .. vi
    local sh_idx = #lines
    table.insert(lines, sh_line)
    add_hl(sh_idx, 0, #sh_line, "SuperCsvHeaderPinned")
    local _ = sub_hdr_body

    -- Render subtable rows
    if st.num_rows == 0 then
      local emp_sub = vi .. string.rep(" ", row_gutter_w) .. vi .. " " .. fit_width("  (Empty array [])", inner_avail - 1, false) .. vi
      table.insert(lines, emp_sub)
      add_hl(#lines - 1, 0, #emp_sub, "SuperCsvTypeNull")
    else
      for sr = 1, max_sub_rows do
        local srow = st.rows[sr] or {}
        local r_parts = { string.format(" %3d ", sr) }
        for sc = 1, sub_cols do
          local sv = tostring(srow[sc] or "")
          if sv == "" then
            sv = "∅"
          elseif sv:sub(1, 1) == "[" then
            sv = json_engine.format_subtable_preview(sv)
          end
          table.insert(r_parts, " " .. fit_width(sv, sub_widths[sc], false) .. " ")
        end
        local sr_body = vi .. table.concat(r_parts, vi) .. vi
        local sr_line = vi .. string.rep(" ", row_gutter_w) .. vi .. " " .. fit_width(sr_body, inner_avail - 1, false) .. vi
        local sr_idx = #lines
        table.insert(lines, sr_line)
        add_hl(sr_idx, 0, #sr_line, (sr % 2 == 0) and "SuperCsvColPinnedEven" or "SuperCsvColPinnedOdd")
      end
      if st.num_rows > max_sub_rows then
        local more_sub = string.format("  … +%d more subtable rows (press <CR> on cell to open full %d-row subtable)", st.num_rows - max_sub_rows, st.num_rows)
        local m_line = vi .. string.rep(" ", row_gutter_w) .. vi .. " " .. fit_width(more_sub, inner_avail - 1, false) .. vi
        table.insert(lines, m_line)
        add_hl(#lines - 1, 0, #m_line, "SuperCsvCommentBar")
      end
    end
  end

  if #rows == 0 then
    local empty_line = bs.v_outer .. " " .. fit_width("No rows match the active filter / grep criteria. Press 'F' or '<leader>cF' to clear filters.", win_width - 4, false) .. " " .. bs.v_outer
    table.insert(lines, empty_line)
    add_hl(#lines - 1, 0, #empty_line, "SuperCsvTypeNull")
  else
    for r_offset, row_obj in ipairs(rows) do
      local abs_row = session.top_row + r_offset - 1
      local is_cur_row = (abs_row == session.cur_row)
      local l_idx = #lines
      if is_cur_row then
        active_row_buf_line = l_idx + 1
      end
      local segs = {}
      local seg_hls = {}
      local cur_byte = 0
      local row_subtable_to_render = nil
      local row_subtable_col_name = nil

      local function push(txt, hl, fg_hl)
        table.insert(segs, txt)
        if hl then
          table.insert(seg_hls, { cur_byte, cur_byte + #txt, hl, 200 })
        end
        if fg_hl then
          table.insert(seg_hls, { cur_byte, cur_byte + #txt, fg_hl, 210 })
        end
        cur_byte = cur_byte + #txt
      end

      push(bs.v_inner, "SuperCsvBorder")
      local r_num_txt = fit_width(tostring(row_obj.rowid or abs_row) .. " ", row_gutter_w, true)
      push(r_num_txt, is_cur_row and "SuperCsvHeaderActive" or "SuperCsvHeaderType")

      for idx, vc in ipairs(vis_cols) do
        local c = vc.col
        local w = session.col_widths[c] or 14
        local is_pin_sep = (idx > 1 and vis_cols[idx - 1].pinned and not vc.pinned)
        push(is_pin_sep and bs.v_pin or bs.v_inner, is_pin_sep and "SuperCsvBorderPinned" or "SuperCsvBorder")

        local raw_val = row_obj.cells[c] or ""
        local is_cur_cell = (is_cur_row and c == session.cur_col)
        if is_cur_cell then
          active_cell_raw = raw_val
          active_rowid = row_obj.rowid or abs_row
        end

        local ctype = session.types[c]
        local is_subtable_col = (ctype == "tbl" or ctype == "arr")
          or (raw_val:sub(1, 1) == "[" and raw_val:sub(-1) == "]")
        local align_right = (ctype == "i64" or ctype == "f64")
        local disp_val = raw_val
        if raw_val == "" then
          disp_val = "∅"
        elseif is_subtable_col then
          disp_val = json_engine.format_subtable_preview(raw_val)
          if is_cur_cell and session.inline_subtable ~= false then
            row_subtable_to_render = json_engine.parse_subtable_cell(raw_val)
            row_subtable_col_name = session.headers[c] or ("col_" .. c)
          elseif is_cur_row and session.inline_subtable == true and not row_subtable_to_render then
            row_subtable_to_render = json_engine.parse_subtable_cell(raw_val)
            row_subtable_col_name = session.headers[c] or ("col_" .. c)
          end
        end
        local cell_str = " " .. fit_width(disp_val, w, align_right) .. " "

        -- Determine highlight group with Excel priority:
        -- Active Cell > Modified Cell > Grep Match > Heatmap > Active Row > Pinned Col > Alternating Row/Col
        local cell_hl
        local fg_hl
        local is_mod = session.modified_cells and session.modified_cells[row_obj.rowid] and session.modified_cells[row_obj.rowid][c] ~= nil
        local is_grep_match = (session.grep_pattern and session.grep_pattern ~= "" and raw_val:lower():find(session.grep_pattern:lower(), 1, true) ~= nil)
        local is_even_row = (r_offset % 2 == 0)
        local is_even_col = (idx % 2 == 0)
        local is_special_bg = false

        if is_cur_cell then
          cell_hl = "SuperCsvCursorCell"
          is_special_bg = true
        elseif is_mod then
          cell_hl = "SuperCsvCellModified"
          is_special_bg = true
        elseif is_grep_match then
          cell_hl = "SuperCsvCellMatch"
          is_special_bg = true
        elseif col_minmax[c] and raw_val ~= "" then
          local nv = tonumber((raw_val:gsub("^%$", ""):gsub(",", "")))
          if nv then
            local ratio = (nv - col_minmax[c].min) / (col_minmax[c].max - col_minmax[c].min)
            cell_hl = (ratio >= 0.66) and "SuperCsvHeatHigh" or ((ratio >= 0.33) and "SuperCsvHeatMid" or "SuperCsvHeatLow")
            is_special_bg = true
          end
        end

        if not cell_hl then
          if is_cur_row then
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
        end

        if not is_special_bg then
          if raw_val == "" then
            fg_hl = "SuperCsvTypeNull"
          elseif use_rainbow then
            local r_idx = col_rainbow_idx(c)
            fg_hl = (vc.pinned or is_cur_row or is_subtable_col)
              and ("SuperCsvRainbowBold" .. r_idx)
              or ("SuperCsvRainbow" .. r_idx)
          elseif is_subtable_col then
            fg_hl = "SuperCsvSubtable"
          elseif not vc.pinned then
            local low = raw_val:lower()
            if low == "true" then
              fg_hl = "SuperCsvTypeBoolTrue"
            elseif low == "false" then
              fg_hl = "SuperCsvTypeBoolFalse"
            elseif ctype == "i64" or ctype == "f64" then
              fg_hl = "SuperCsvTypeNumber"
            end
          end
        end

        push(cell_str, cell_hl, fg_hl)
      end

      push(bs.v_inner, "SuperCsvBorder")
      local full_row = table.concat(segs)
      table.insert(lines, full_row)
      for _, h in ipairs(seg_hls) do
        add_hl(l_idx, h[1], h[2], h[3], h[4])
      end

      if row_subtable_to_render then
        render_inline_subtable(row_subtable_to_render, row_subtable_col_name, row_obj.rowid or abs_row)
      end
    end
  end

  local bot_border = build_border(bs.bot[1], bs.bot[2], bs.bot[3], bs.bot[4], bs.bot[5])
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
  local comment_key_hint = (num_comments > 0) and "[c/#]Comments " or ""
  local inspector_line = string.format(
    " [%s] %s = %s │ [?]Help %s[f]Filter [gv]Counts [g/]Grep [s/S]Sort [gc]Cols [gp]Pin [<leader>cv]RawCSV ",
    cell_coord,
    session.headers[session.cur_col] or "",
    active_cell_raw == "" and "NULL" or vim.inspect(active_cell_raw),
    comment_key_hint
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
      priority = op[5] or 200,
    })
  end

  -- Position Neovim cursor on the active row line and lock topline=1 so header NEVER scrolls out of view
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].scrolloff = 0
    vim.wo[win].sidescrolloff = 0
    local first_data_line = (session.header_lines_count or 5) + 1
    local target_buf_line = active_row_buf_line
      or math.max(first_data_line, math.min(#lines - footer_lines, first_data_line + (session.cur_row - session.top_row)))
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
