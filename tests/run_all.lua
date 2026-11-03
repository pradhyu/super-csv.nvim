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

print(string.format("\n=== SuperCsv Tests: %d passed, %d failed ===", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
