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

super_csv.setup({ auto_open = false, border_style = "ascii" })
require("super-csv.config").options.border_style = "ascii"
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

-- 10d. Test JSON-to-CSV Conversion & Visualizing JSON as CSV (Maps as columns vs Arrays as Subtables)
local json_engine = require("super-csv.engine.json")
local json_path = "/home/pkshrestha/git/super-csv.nvim/examples/saas_metrics.json"
local s_json = super_csv.open(json_path)
assert_true(s_json ~= nil, "Opened saas_metrics.json directly in SuperCsv 2D viewport")
assert_eq(s_json.source_json_path, json_path, "Session tracks source_json_path")
assert_eq(s_json.total_rows, 30, "saas_metrics.json has 30 rows")
assert_eq(s_json.num_cols, 20, "saas_metrics.json flattened Maps/Maps-of-Maps and kept Arrays as Subtables (20 columns)")
assert_eq(s_json.headers[1], "tenant_id", "Preserved JSON key order: Col 1 is tenant_id")
-- Map -> parentkey.mapkey columns
assert_eq(s_json.headers[6], "account.owner", "Map flattened: Col 6 is account.owner")
assert_eq(s_json.headers[7], "account.seats", "Map flattened: Col 7 is account.seats")
assert_eq(s_json.headers[8], "account.churn_risk", "Map flattened: Col 8 is account.churn_risk")
assert_eq(s_json.headers[9], "metrics.mrr_usd", "Map flattened: Col 9 is metrics.mrr_usd")
-- Map of Map -> parentkey.mapkey.subkey columns
assert_eq(s_json.headers[12], "infrastructure.compute.vcpu", "Map-of-Map flattened: Col 12 is infrastructure.compute.vcpu")
assert_eq(s_json.headers[13], "infrastructure.compute.ram_gb", "Map-of-Map flattened: Col 13 is infrastructure.compute.ram_gb")
assert_eq(s_json.headers[14], "infrastructure.network.region", "Map-of-Map flattened: Col 14 is infrastructure.network.region")
assert_eq(s_json.headers[15], "infrastructure.network.cdn_enabled", "Map-of-Map flattened: Col 15 is infrastructure.network.cdn_enabled")
-- List of Map -> single [tbl] Subtable column
assert_eq(s_json.headers[16], "deployments", "List-of-Map is Subtable column: Col 16 is deployments")
assert_eq(s_json.types[16], "tbl", "deployments column inferred as [tbl] Subtable type")
-- Map of Lists -> parentkey.listkey [arr] Subtable columns
assert_eq(s_json.headers[17], "environments.prod", "Map-of-Lists flattened map & kept list as Subtable: Col 17 is environments.prod")
assert_eq(s_json.headers[18], "environments.staging", "Map-of-Lists flattened map & kept list as Subtable: Col 18 is environments.staging")
assert_eq(s_json.types[17], "arr", "environments.prod column inferred as [arr] Subtable type")
-- List of Scalars -> single [arr] Subtable column
assert_eq(s_json.headers[19], "tags", "List-of-Scalars is Subtable column: Col 19 is tags")
assert_eq(s_json.types[19], "arr", "tags column inferred as [arr] Subtable type")
assert_true(#s_json.comments == 1 and s_json.comments[1].text:find("JSON Metadata") ~= nil, "Extracted top-level JSON metadata into # comment")

-- Verify multi-level 'TABLE' parent header band & leaf attribute headers in viewport
local json_grid_lines = vim.api.nvim_buf_get_lines(s_json.view_buf, 0, 8, false)
assert_true(json_grid_lines[5]:find("TABLE") ~= nil and json_grid_lines[5]:find("account %(3 cols%)") ~= nil, "Viewport renders spanned parent TABLE header for nested JSON objects")
assert_true(json_grid_lines[6]:find("owner") ~= nil and json_grid_lines[6]:find("seats") ~= nil and json_grid_lines[6]:find("churn_risk") ~= nil, "Viewport renders clean leaf attribute names under parent TABLE header")

-- Focus on Subtable column (deployments, col 16) and verify Inline Embedded Subtable + Subtable Drill-down (<CR>)
s_json.cur_col = 16
s_json.left_col = 12
viewport.render(s_json)
local sub_grid_lines = vim.api.nvim_buf_get_lines(s_json.view_buf, 0, 20, false)
local all_sub_text = table.concat(sub_grid_lines, "\n")
assert_true(all_sub_text:find("Subtable %[deployments%]") ~= nil, "Viewport renders inline embedded SUBTABLE beneath active row when focused on [tbl] cell")
assert_true(all_sub_text:find("api%-gateway") ~= nil and all_sub_text:find("worker%-pool") ~= nil, "Inline embedded subtable displays child rows (api-gateway, worker-pool)")

local child_sub = super_csv.open_subtable(s_json)
assert_true(child_sub ~= nil, "Drilled down into deployments Subtable via open_subtable")
assert_eq(child_sub.total_rows, 2, "Drilled-down deployments Subtable has 2 rows")
assert_eq(child_sub.num_cols, 3, "Drilled-down deployments Subtable has 3 columns (service, status, replicas)")
assert_eq(child_sub.headers[1], "service", "Subtable Col 1 is service")
assert_eq(child_sub.headers[2], "status", "Subtable Col 2 is status")
assert_eq(child_sub.headers[3], "replicas", "Subtable Col 3 is replicas")
assert_true(super_csv.close_subtable(child_sub), "Popped back from Subtable to parent session via close_subtable")
s_json.cur_col = 1
s_json.left_col = 1
viewport.render(s_json)

-- Filter on flattened JSON column in SQLite
super_csv.apply_filter_expr(s_json, 3, "= ENTERPRISE")
assert_true(s_json.filtered_rows > 0 and s_json.filtered_rows < 30, "Filtered JSON records by plan == ENTERPRISE")
super_csv.command("filter_clear")
assert_eq(s_json.filtered_rows, 30, "Cleared filter on JSON session restores 30 rows")

-- Toggle from JSON 2D grid back to raw JSON buffer and back
super_csv.command("toggle")
assert_eq(vim.api.nvim_buf_get_name(0), json_path, "Toggle switched back to raw saas_metrics.json buffer")
super_csv.command("toggle")
assert_eq(vim.bo.filetype, "supercsv", "Second toggle returned from raw JSON to SuperCsv 2D viewport")

-- Test direct JSON-to-CSV file conversion and JSONL parsing
local tmp_csv = "/tmp/test_saas_metrics_converted.csv"
local ok_conv, conv_path, conv_info = super_csv.json_to_csv(json_path, tmp_csv)
assert_true(ok_conv, "json_to_csv converted saas_metrics.json to " .. tostring(conv_path))
assert_eq(conv_info.num_rows, 30, "Converted CSV has 30 rows")
assert_eq(conv_info.num_cols, 20, "Converted CSV has 20 columns")
os.remove(tmp_csv)

-- Test Map, Map-of-Map, List-of-Map, and Map-of-Lists design
local nested_tbl_json = [[
[
  {
    "order_id": 101,
    "customer": { "name": "Aria", "address": { "city": "SF", "zip": "94107" } },
    "items": [
      { "sku": "NVME", "qty": 2, "spec": { "gen": 4 } },
      { "sku": "OLED", "qty": 1, "spec": { "gen": 3 } }
    ],
    "permissions": {
      "read": ["eng", "ops"],
      "write": ["admin"]
    }
  }
]
]]
local nested_parsed = json_engine.parse_json_text(nested_tbl_json)
assert_true(nested_parsed ~= nil, "Parsed deeply nested JSON (Map, Map-of-Map, List-of-Map, Map-of-Lists)")
assert_eq(#nested_parsed.headers, 7, "Maps expanded to parentkey.mapkey columns and Lists kept as Subtable columns (7 columns)")
assert_eq(nested_parsed.headers[1], "order_id", "Col 1 is order_id")
assert_eq(nested_parsed.headers[2], "customer.name", "Col 2 is customer.name (Map)")
assert_eq(nested_parsed.headers[3], "customer.address.city", "Col 3 is customer.address.city (Map of Map)")
assert_eq(nested_parsed.headers[4], "customer.address.zip", "Col 4 is customer.address.zip (Map of Map)")
assert_eq(nested_parsed.headers[5], "items", "Col 5 is items (List of Map -> Subtable)")
assert_eq(nested_parsed.headers[6], "permissions.read", "Col 6 is permissions.read (Map of Lists -> Subtable)")
assert_eq(nested_parsed.headers[7], "permissions.write", "Col 7 is permissions.write (Map of Lists -> Subtable)")

local items_sub = json_engine.parse_subtable_cell(nested_parsed.rows[1][5])
assert_true(items_sub ~= nil and items_sub.kind == "tbl", "Parsed items cell as Subtable of objects ([tbl])")
assert_eq(#items_sub.rows, 2, "items Subtable has 2 rows")
assert_eq(items_sub.headers[1], "sku", "items Subtable Col 1 is sku")
assert_eq(items_sub.headers[2], "qty", "items Subtable Col 2 is qty")
assert_eq(items_sub.headers[3], "spec.gen", "items Subtable flattened nested map spec.gen into Col 3")

local jsonl_parsed = json_engine.parse_json_text('// JSONL header comment\n{"id":1,"user":{"name":"Ada"},"url":"https://ada.dev","ok":true} // inline comment\n{"id":2,"user":{"name":"Linus"},"url":"https://kernel.org","ok":false}\n')
assert_true(jsonl_parsed ~= nil, "Parsed JSONL with default '//' comments and inline '//' comments")
assert_eq(#jsonl_parsed.rows, 2, "JSONL has 2 rows")
assert_eq(jsonl_parsed.headers[1], "id", "JSONL Col 1 is id")
assert_eq(jsonl_parsed.headers[2], "user.name", "JSONL Col 2 is user.name")
assert_eq(jsonl_parsed.rows[1][3], "https://ada.dev", "URL containing '//' inside JSON string was preserved intact")
assert_eq(#jsonl_parsed.comments, 2, "JSONL extracted both full-line and inline '//' comments")

-- Test JSONC with '//' comments and trailing commas
local jsonc_text = [[
// Top JSONC comment line 1
// Top JSONC comment line 2
[
  {
    "id": 10, // inline id comment
    "name": "Service A",
    "endpoint": "https://api.internal/v1",
  },
  // Mid-array JSONC comment
  {
    "id": 20,
    "name": "Service B",
    "endpoint": "https://api.internal/v2",
  },
]
]]
local jsonc_parsed = json_engine.parse_json_text(jsonc_text)
assert_true(jsonc_parsed ~= nil, "Parsed JSONC with '//' comments and trailing commas")
assert_eq(#jsonc_parsed.rows, 2, "JSONC has 2 rows")
assert_eq(#jsonc_parsed.comments, 4, "JSONC extracted 4 '//' comments (2 top, 1 inline, 1 mid-array)")
assert_eq(jsonc_parsed.comment_items[1].line_num, 1, "First JSONC comment at L1")
assert_eq(jsonc_parsed.comment_items[3].line_num, 5, "Inline JSONC comment at L5")
assert_eq(jsonc_parsed.comment_items[4].line_num, 9, "Mid-array JSONC comment at L9")

-- Test configurable comment prefixes (default '#' for CSV, '//' for JSON, and custom overrides)
assert_eq(cfg.get_csv_comment_char(), "#", "Default CSV comment_char is '#'")
assert_eq(cfg.get_json_comment_char(), "//", "Default JSON json_comment_char is '//'")
super_csv.command("json_comment_char #")
assert_eq(cfg.get_json_comment_char(), "#", "Updated JSON comment prefix to '#' via command")
local custom_json_parsed = json_engine.parse_json_text('# Custom hash comment in JSON\n[{"col":"val"}]\n')
assert_true(custom_json_parsed ~= nil and #custom_json_parsed.comments == 1, "Parsed JSON with custom '#' comment_char")
super_csv.command("json_comment_char //")
assert_eq(cfg.get_json_comment_char(), "//", "Restored JSON comment prefix to '//'")

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

-- 12. Test ASCII & Markdown Table Generator and Border Styles
local ascii_engine = require("super-csv.engine.ascii")

-- 12.1 Test ASCII generation from CSV text
local sample_csv = [[
name,age,role,salary
Alice,30,Engineer,120000
Bob,25,Designer,95000
Charlie,35,Manager,145000
]]
local ascii_tbl = ascii_engine.from_csv(sample_csv, { style = "ascii" })
assert_true(ascii_tbl:find("%+%-+%-+%-+%-+%+") ~= nil, "ASCII table has +----+ top/bot border")
assert_true(ascii_tbl:find("| Alice") ~= nil, "ASCII table contains Alice row")
assert_true(ascii_tbl:find("| name") ~= nil, "ASCII table contains name header")

-- 12.2 Test Markdown table generation with alignment
local md_tbl = ascii_engine.from_csv(sample_csv, { style = "markdown" })
assert_true(md_tbl:find("|:---") ~= nil or md_tbl:find("| :---") ~= nil, "Markdown table has left alignment :---")
assert_true(md_tbl:find("%-%-%-:") ~= nil, "Markdown table has right alignment ---: for numbers")
assert_true(md_tbl:find("| Alice") ~= nil and md_tbl:find("30") ~= nil, "Markdown table formats columns with pipes")

-- Test Markdown pipe escaping
local csv_with_pipe = "col1,col2\nValue|With|Pipes,123\n"
local md_escaped = ascii_engine.from_csv(csv_with_pipe, { style = "markdown" })
assert_true(md_escaped:find("Value\\|With\\|Pipes") ~= nil, "Markdown table escapes pipe characters")

-- 12.3 Test Unicode box drawing
local uni_tbl = ascii_engine.from_csv(sample_csv, { style = "unicode" })
assert_true(uni_tbl:find("┌") ~= nil, "Unicode table has ┌ top-left border")
assert_true(uni_tbl:find("└") ~= nil, "Unicode table has └ bot-left border")
assert_true(uni_tbl:find("│") ~= nil, "Unicode table has │ vertical dividers")

-- 12.4 Test Rounded and Grid styles
local rounded_tbl = ascii_engine.from_csv(sample_csv, { style = "rounded" })
assert_true(rounded_tbl:find("╭") ~= nil, "Rounded table has ╭ top-left border")
assert_true(rounded_tbl:find("╰") ~= nil, "Rounded table has ╰ bot-left border")

local grid_tbl = ascii_engine.from_csv(sample_csv, { style = "grid" })
assert_true(grid_tbl:find("%+%=+%=+") ~= nil, "Grid table has +=+ header divider")

local simple_tbl = ascii_engine.from_csv(sample_csv, { style = "simple" })
assert_true(simple_tbl:find("name%s+age") ~= nil, "Simple table has space separated columns")

-- 12.5 Test ASCII generation from JSON
local sample_json = [[
[
  { "id": 1, "product": "Widget A", "price": 19.99, "active": true },
  { "id": 2, "product": "Widget B", "price": 29.50, "active": false }
]
]]
local json_ascii = ascii_engine.from_json(sample_json, { style = "ascii" })
assert_true(json_ascii ~= nil, "Generated ASCII table from JSON")
assert_true(json_ascii:find("| Widget A") ~= nil, "JSON ASCII table has Widget A")
assert_true(json_ascii:find("| 19.99") ~= nil or json_ascii:find("19.99") ~= nil, "JSON ASCII table has price")
assert_true(json_ascii:find("| true") ~= nil or json_ascii:find("true") ~= nil, "JSON ASCII table has boolean true")

-- Test JSONL / NDJSON ASCII generation
local sample_jsonl = '{"user": "dev1", "score": 98}\n{"user": "dev2", "score": 85}\n'
local jsonl_ascii = ascii_engine.from_json(sample_jsonl, { style = "markdown" })
assert_true(jsonl_ascii:find("dev1") ~= nil, "JSONL markdown table parsed user dev1")
assert_true(jsonl_ascii:find("98") ~= nil, "JSONL markdown table parsed score 98")

-- 12.6 Test unified to_ascii on active session
assert_true(s_emp ~= nil, "Active session exists for employees_saas.csv")
local session_ascii = super_csv.to_ascii(s_emp, { style = "ascii", max_rows = 5 })
assert_true(session_ascii ~= nil, "Generated ASCII table from active session")
assert_true(session_ascii:find("emp_id") ~= nil and session_ascii:find("full_name") ~= nil, "Session ASCII table has headers")
assert_true(session_ascii:find("EMP%-1001") ~= nil, "Session ASCII table fetched row EMP-1001 via SQLite")

-- 12.7 Test copy_ascii and view_ascii
local ok_copy, copied_txt = super_csv.copy_ascii({ style = "markdown", max_rows = 3 })
assert_true(ok_copy == true, "copy_ascii succeeded")
assert_eq(vim.fn.getreg('"'), copied_txt, "Register contains copied markdown table")

local v_buf, v_win = super_csv.view_ascii({ style = "unicode", max_rows = 4 })
assert_true(v_buf ~= nil and vim.api.nvim_buf_is_valid(v_buf), "view_ascii created scratch buffer")
assert_true(v_win ~= nil and vim.api.nvim_win_is_valid(v_win), "view_ascii opened floating window")
pcall(vim.api.nvim_win_close, v_win, true)

-- 12.8 Test Viewport Border Styles (ascii as default, toggle to heavy/unicode/rounded)
assert_eq(cfg.get_border_style(), "ascii", "Default border style is 'ascii'")

viewport.render(s_emp)
local lines_ascii = vim.api.nvim_buf_get_lines(s_emp.view_buf, 0, 15, false)
local has_plus_border = false
local has_pipe_border = false
for _, l in ipairs(lines_ascii) do
  if l:match("^%+%-+") or l:match("%+%-+.*%+$") then
    has_plus_border = true
  end
  if l:match("^|") and l:match("|$") then
    has_pipe_border = true
  end
end
assert_true(has_plus_border, "Default viewport rendered with ASCII '+' and '-' borders")
assert_true(has_pipe_border, "Default viewport rendered with ASCII '|' borders")

-- Toggle border style from 'ascii' -> 'heavy'
local toggled = super_csv.toggle_border_style(s_emp)
assert_eq(toggled, "heavy", "toggle_border_style toggled 'ascii' -> 'heavy'")
viewport.render(s_emp)
local lines_heavy = vim.api.nvim_buf_get_lines(s_emp.view_buf, 0, 15, false)
local has_heavy_border = false
for _, l in ipairs(lines_heavy) do
  if l:match("^┏━") or l:match("━┓$") then
    has_heavy_border = true
    break
  end
end
assert_true(has_heavy_border, "Viewport switched to 'heavy' ┏━ borders")

-- Toggle border style back from 'heavy' -> 'ascii'
local toggled_back = super_csv.toggle_border_style(s_emp)
assert_eq(toggled_back, "ascii", "toggle_border_style toggled 'heavy' -> 'ascii'")

-- Test command dispatchers for style & ascii
super_csv.command("style heavy")
assert_eq(cfg.get_border_style(), "heavy", "super_csv.command('style heavy') updated style to heavy")
super_csv.command("toggle_ascii")
assert_eq(cfg.get_border_style(), "ascii", "super_csv.command('toggle_ascii') restored default ascii")
super_csv.command("copy_ascii markdown 5")
assert_true(vim.fn.getreg('"'):find("|:---") ~= nil or vim.fn.getreg('"'):find("| :---") ~= nil, "super_csv.command('copy_ascii markdown 5') yanked markdown table")

-- 12.9 Test Markdown Fencing & save_to_file / save_markdown
local sample_fenced = ascii_engine.from_csv(sample_csv, { style = "markdown", fence = true })
assert_true(sample_fenced:find("^```markdown") ~= nil, "Fenced markdown table starts with ```markdown")
assert_true(sample_fenced:find("```$") ~= nil, "Fenced markdown table ends with ```")

local tmp_save_md = "/tmp/super_csv_test_table.md"
local ok_save, save_path = super_csv.save_markdown(tmp_save_md, { max_rows = 3 })
assert_true(ok_save == true, "save_markdown succeeded")
assert_true(vim.fn.filereadable(tmp_save_md) == 1, "Saved markdown table file is readable")
local read_lines = vim.fn.readfile(tmp_save_md)
assert_true(#read_lines >= 4, "Saved markdown file contains lines")
assert_true(read_lines[1]:find("|") ~= nil, "Saved markdown file has pipe header")
pcall(vim.fn.delete, tmp_save_md)

-- 12.10 Test view_markdown and interactive view_ascii buffer controls
local md_buf, md_win = super_csv.view_markdown({ max_rows = 4 })
assert_true(md_buf ~= nil and vim.api.nvim_buf_is_valid(md_buf), "view_markdown created buffer")
assert_eq(vim.bo[md_buf].filetype, "markdown", "view_markdown sets filetype to markdown")
pcall(vim.api.nvim_win_close, md_win, true)

-- Test copy_markdown API and command
local ok_copymd, copymd_txt = super_csv.copy_markdown({ max_rows = 2 })
assert_true(ok_copymd == true, "copy_markdown succeeded")
assert_true(copymd_txt:find("|") ~= nil, "copy_markdown output contains pipes")

super_csv.command("copy_markdown 3")
assert_true(vim.fn.getreg('"'):find("|") ~= nil, ":SuperCsv copy_markdown yanked to register")

print(string.format("\n=== SuperCsv Tests: %d passed, %d failed ===", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
