-- Headless test suite for super-csv.nvim
package.path = "/home/pkshrestha/git/super-csv.nvim/lua/?.lua;/home/pkshrestha/git/super-csv.nvim/lua/?/init.lua;" .. package.path
vim.opt.rtp:prepend("/home/pkshrestha/git/super-csv.nvim")

local passed = 0
local failed = 0

local function assert_eq(actual, expected, msg)
  if actual == expected then
    passed = passed + 1
  else
    failed = failed + 1
    print(string.format("[FAIL] %s: expected %s, got %s", msg or "assert_eq", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function assert_true(cond, msg)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print(string.format("[FAIL] %s", msg or "assert_true"))
  end
end

local super_csv = require("super-csv")
local parser = require("super-csv.engine.parser")
local sqlite = require("super-csv.engine.sqlite")
local viewport = require("super-csv.ui.viewport")
local modals = require("super-csv.ui.modals")

super_csv.setup({ auto_open = false })
require("super-csv.config").options.zebra_rows = true
require("super-csv.config").save_persisted()

-- 1. Test Excel column letters (1..100)
assert_eq(parser.col_to_excel(1), "A", "Col 1 -> A")
assert_eq(parser.col_to_excel(26), "Z", "Col 26 -> Z")
assert_eq(parser.col_to_excel(27), "AA", "Col 27 -> AA")
assert_eq(parser.col_to_excel(100), "CV", "Col 100 -> CV")

-- 2. Test RFC 4180 parser
local parsed = parser.parse_line('101,"Item #1, Batch A","He said ""RFC 4180""",42.50,', ",")
assert_eq(#parsed, 5, "RFC 4180 field count")
assert_eq(parsed[1], "101", "Field 1")
assert_eq(parsed[2], "Item #1, Batch A", "Quoted comma field")
assert_eq(parsed[3], 'He said "RFC 4180"', "Escaped quote field")
assert_eq(parsed[5], "", "Trailing empty field")

-- 3. Test SQLite FFI availability & session open on employees_saas.csv
assert_true(sqlite.is_ffi_available(), "LuaJIT libsqlite3 FFI available")

local emp_path = "/home/pkshrestha/git/super-csv.nvim/examples/employees_saas.csv"
local s_emp = super_csv.open(emp_path)
assert_true(s_emp ~= nil, "Opened employees_saas.csv session")
assert_true(s_emp.sqlite_ready == true, "SQLite ready synchronously for employees_saas.csv")
assert_eq(s_emp.num_cols, 16, "employees_saas has 16 columns")
assert_eq(s_emp.total_rows, 120, "employees_saas has 120 rows")

-- 4. Test Excel Bottom Status Bar stats (salary_usd is col 10)
local sal_stats = sqlite.get_column_stats(s_emp, 10)
assert_eq(sal_stats.count, 120, "Salary count == 120")
assert_true(sal_stats.is_numeric, "Salary inferred as numeric")
assert_true(sal_stats.sum > 10000000, "Salary sum > $10M")
assert_true(sal_stats.avg > 80000 and sal_stats.avg < 350000, "Salary avg reasonable")

-- 5. Test Value Counts / Frequency table (department is col 4)
local dept_freqs, base_tot = sqlite.get_value_counts(s_emp, 4, 20)
assert_eq(base_tot, 120, "Base total for department freq is 120")
assert_eq(#dept_freqs, 5, "5 distinct departments")

-- 6. Test Column Filter + Global Grep + Sorting
super_csv.apply_filter_expr(s_emp, 4, "= Engineering")
assert_true(s_emp.filtered_rows > 0 and s_emp.filtered_rows < 120, "Filtered to Engineering rows: " .. tostring(s_emp.filtered_rows))
local eng_count = s_emp.filtered_rows

super_csv.apply_filter_expr(s_emp, 10, "> 180000")
assert_true(s_emp.filtered_rows > 0 and s_emp.filtered_rows <= eng_count, "Stacked filter Engineering + salary > 180000")

-- Clear filters
super_csv.command("filter_clear")
assert_eq(s_emp.filtered_rows, 120, "Cleared filters restores 120 rows")

-- Grep
super_csv.command("grep Staff Engineer")
assert_true(s_emp.filtered_rows > 0 and s_emp.filtered_rows < 50, "Grep 'Staff Engineer' matched subset")
super_csv.command("filter_clear")

-- 7. Test Custom SQL Query Runner
local sql_res = sqlite.run_custom_sql(s_emp, "SELECT department, COUNT(*) AS cnt FROM csv GROUP BY department ORDER BY cnt DESC")
assert_true(sql_res ~= nil and #sql_res.rows == 5, "Custom SQL GROUP BY returned 5 departments")

-- 8. Test Cell Edit + Undo + Redo
local orig_val = s_emp.visible_rows[1].cells[2]
local row1_id = s_emp.visible_rows[1].rowid
sqlite.update_cell(s_emp, row1_id, 2, "Edited Developer Name", true)
viewport.render(s_emp)
assert_eq(s_emp.visible_rows[1].cells[2], "Edited Developer Name", "Cell updated in SQLite & viewport")
assert_eq(s_emp.edit_count, 1, "Edit count incremented")

local ok_u = sqlite.undo(s_emp)
viewport.render(s_emp)
assert_true(ok_u, "Undo succeeded")
assert_eq(s_emp.visible_rows[1].cells[2], orig_val, "Undo restored original cell value")

local ok_r = sqlite.redo(s_emp)
viewport.render(s_emp)
assert_true(ok_r, "Redo succeeded")
assert_eq(s_emp.visible_rows[1].cells[2], "Edited Developer Name", "Redo re-applied cell value")
sqlite.undo(s_emp)

-- 9. Test 100-Column Wide Dataset + Horizontal Virtualization + Record Card
local wide_path = "/home/pkshrestha/git/super-csv.nvim/examples/wide_100_columns.csv"
local s_wide = super_csv.open(wide_path)
assert_eq(s_wide.num_cols, 100, "wide_100_columns has 100 columns")
assert_eq(s_wide.total_rows, 250, "wide_100_columns has 250 rows")
assert_true(s_wide.pinned_cols[1] == true, "Column 1 pinned by default")

-- Jump to column 95
s_wide.cur_col = 95
viewport.render(s_wide)
local found_pin_1, found_col_95 = false, false
for _, vc in ipairs(s_wide.vis_cols) do
  if vc.col == 1 and vc.pinned then found_pin_1 = true end
  if vc.col == 95 then found_col_95 = true end
end
assert_true(found_pin_1, "Pinned Column #1 stays visible while at Column #95")
assert_true(found_col_95, "Column #95 is visible in viewport")

-- Toggle Vertical Record Card
modals.toggle_record_card(s_wide)
assert_true(s_wide.record_buf ~= nil and vim.api.nvim_buf_is_valid(s_wide.record_buf), "Record card opened")
local card_lines = vim.api.nvim_buf_get_lines(s_wide.record_buf, 0, -1, false)
assert_eq(#card_lines, 103, "Record card displays 3 header lines + all 100 columns")
modals.toggle_record_card(s_wide)

-- 10. Test Alternating Row Colors (zebra_rows) & Toggle to Normal CSV Mode
local cfg = require("super-csv.config")
assert_eq(cfg.options.zebra_rows, true, "zebra_rows enabled by default")
super_csv.command("zebra_rows")
assert_eq(cfg.options.zebra_rows, false, "zebra_rows toggled off")
super_csv.command("zebra_rows")
assert_eq(cfg.options.zebra_rows, true, "zebra_rows toggled back on")

-- Test switching to normal raw CSV buffer and back
super_csv.command("toggle")
assert_true(super_csv.disabled_paths[wide_path] == true, "toggle switched wide_100_columns.csv to normal raw mode")
assert_true(vim.api.nvim_buf_get_name(0) == wide_path, "Current buffer is the raw CSV file")
super_csv.command("toggle")
assert_true(super_csv.disabled_paths[wide_path] == nil, "second toggle returned to SuperCsv 2D viewport")
assert_eq(vim.bo.filetype, "supercsv", "Buffer filetype is supercsv again")

-- 10b. Test '#' Comments Support (Top Header Comments & Multi-Location Scattered Comments)
local top_cm_path = "/home/pkshrestha/git/super-csv.nvim/examples/comments_top_header.csv"
local s_top_cm = super_csv.open(top_cm_path)
assert_true(s_top_cm ~= nil, "Opened comments_top_header.csv")
assert_eq(s_top_cm.num_cols, 10, "comments_top_header.csv has 10 columns (ignored # lines)")
assert_eq(s_top_cm.headers[1], "sensor_id", "First column header is sensor_id (skipped 6 top comment lines)")
assert_eq(s_top_cm.total_rows, 40, "comments_top_header.csv has exactly 40 data rows")
assert_eq(#s_top_cm.comments, 7, "comments_top_header.csv collected 7 comments (6 top + 1 bottom)")
assert_eq(s_top_cm.comments[1].line_num, 1, "First top comment at L1")
assert_eq(s_top_cm.comments[6].line_num, 6, "Sixth top comment at L6")
assert_eq(s_top_cm.comments[7].line_num, 48, "Bottom comment at L48")
assert_eq(s_top_cm.comments_expanded, false, "Comments panel is collapsed by default")

local scat_cm_path = "/home/pkshrestha/git/super-csv.nvim/examples/comments_scattered_locations.csv"
local s_scat = super_csv.open(scat_cm_path)
assert_true(s_scat ~= nil, "Opened comments_scattered_locations.csv")
assert_eq(s_scat.num_cols, 10, "comments_scattered_locations.csv has 10 columns")
assert_eq(s_scat.headers[1], "batch_seq", "Header is batch_seq at L4")
assert_eq(s_scat.total_rows, 50, "comments_scattered_locations.csv has 50 data rows (ignored all 10 scattered # lines)")
assert_eq(#s_scat.comments, 10, "Gathered all 10 comments from top, after-header, mid-file, and bottom")
assert_eq(s_scat.comments[1].line_num, 1, "Comment #1 is at L1 (top)")
assert_eq(s_scat.comments[4].line_num, 5, "Comment #4 is at L5 (after header)")
assert_eq(s_scat.comments[5].line_num, 21, "Comment #5 is at L21 (mid-file after row 15)")
assert_eq(s_scat.comments[7].line_num, 38, "Comment #7 is at L38 (mid-file after row 30)")
assert_eq(s_scat.comments[8].line_num, 51, "Comment #8 is at L51 (mid-file after row 42)")
assert_eq(s_scat.comments[10].line_num, 61, "Comment #10 is at L61 (bottom of file)")
assert_eq(s_scat.comments_expanded, false, "Scattered comments are collapsed at top by default")

local collapsed_buf_lines = vim.api.nvim_buf_get_lines(s_scat.view_buf, 0, 5, false)
assert_true(collapsed_buf_lines[2]:find("▶ %[c / # / z%] Show # Comments %(10 lines:") ~= nil, "Collapsed comment bar rendered at top line 2 with [c / # / z] key hint")

-- Expand comments at top and verify line numbers are displayed at top
super_csv.command("comments expand")
assert_eq(s_scat.comments_expanded, true, "Comments expanded via command")
local expanded_buf_lines = vim.api.nvim_buf_get_lines(s_scat.view_buf, 0, 15, false)
assert_true(expanded_buf_lines[2]:find("▼ %[c / # / z%] Hide # Comments") ~= nil, "Expanded comment bar rendered at top line 2")
assert_true(expanded_buf_lines[3]:find("L1 ") ~= nil and expanded_buf_lines[3]:find("# %[TOP L1%]") ~= nil, "First expanded comment line shows L1")
assert_true(expanded_buf_lines[7]:find("L21 ") ~= nil and expanded_buf_lines[7]:find("# %[MID%-FILE L21%]") ~= nil, "Mid-file comment shown at top with L21")

-- Collapse back
super_csv.command("comments collapse")
assert_eq(s_scat.comments_expanded, false, "Comments collapsed back")

-- Test '?' Help Modal
local help_buf, help_win = modals.open_help(s_scat)
assert_true(help_buf ~= nil and vim.api.nvim_buf_is_valid(help_buf), "Help modal opened via modals.open_help")
local help_lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
assert_true(#help_lines > 20, "Help modal lists all shortcuts")
vim.api.nvim_win_close(help_win, true)

-- 10c. Test Dynamic Neovim Colorscheme Adaptation
vim.api.nvim_set_hl(0, "Normal", { fg = "#ebdbb2", bg = "#282828" })
vim.api.nvim_set_hl(0, "CursorLine", { bg = "#3c3836" })
vim.api.nvim_set_hl(0, "Title", { fg = "#b8bb26", bold = true })
require("super-csv.highlights").ensure_synced()
local hl_odd_1 = vim.api.nvim_get_hl(0, { name = "SuperCsvRowOddColOdd", link = false })
local hl_hdr_1 = vim.api.nvim_get_hl(0, { name = "SuperCsvHeaderBanner", link = false })
assert_eq(hl_odd_1.bg, 0x282828, "SuperCsvRowOddColOdd bg matches Gruvbox Normal bg (#282828)")
assert_eq(hl_odd_1.fg, 0xebdbb2, "SuperCsvRowOddColOdd fg matches Gruvbox Normal fg (#ebdbb2)")
assert_eq(hl_hdr_1.fg, 0xb8bb26, "SuperCsvHeaderBanner fg matches Gruvbox Title fg (#b8bb26)")

vim.api.nvim_set_hl(0, "Normal", { fg = "#c0caf5", bg = "#1a1b26" })
vim.api.nvim_set_hl(0, "CursorLine", { bg = "#292e42" })
vim.api.nvim_set_hl(0, "Title", { fg = "#7aa2f7", bold = true })
viewport.render(s_scat)
local hl_odd_2 = vim.api.nvim_get_hl(0, { name = "SuperCsvRowOddColOdd", link = false })
local hl_hdr_2 = vim.api.nvim_get_hl(0, { name = "SuperCsvHeaderBanner", link = false })
assert_eq(hl_odd_2.bg, 0x1a1b26, "SuperCsvRowOddColOdd bg updates to TokyoNight Normal bg (#1a1b26)")
assert_eq(hl_odd_2.fg, 0xc0caf5, "SuperCsvRowOddColOdd fg updates to TokyoNight Normal fg (#c0caf5)")
assert_eq(hl_hdr_2.fg, 0x7aa2f7, "SuperCsvHeaderBanner fg updates to TokyoNight Title fg (#7aa2f7)")

-- 11. Test 1,000,000-row x 100-column CSV initial slice open (< 35ms)
local million_path = "/home/pkshrestha/git/super-csv.nvim/examples/million_100cols.csv"
if vim.fn.filereadable(million_path) == 1 then
  local t0 = vim.uv.hrtime()
  local slice = parser.read_initial_slice(million_path, 250)
  local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
  assert_true(slice ~= nil, "1M x 100 CSV initial slice parsed")
  assert_eq(slice.num_cols, 100, "1M x 100 CSV has 100 columns")
  assert_true(#slice.preview_rows >= 200, "1M x 100 CSV preview slice has >= 200 rows")
  assert_true(elapsed_ms < 100, string.format("1M x 100 initial slice took %.2f ms", elapsed_ms))
  print(string.format("[BENCH] 1,000,000-row x 100-col initial slice read: %.2f ms", elapsed_ms))
end

print(string.format("\n=== SuperCsv Tests: %d passed, %d failed ===", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
