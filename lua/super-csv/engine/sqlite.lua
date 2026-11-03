local M = {}

local ffi_ok, ffi = pcall(require, "ffi")
local sqlite_lib = nil

if ffi_ok then
  pcall(function()
    ffi.cdef([[
      typedef struct sqlite3 sqlite3;
      typedef struct sqlite3_stmt sqlite3_stmt;

      int sqlite3_open(const char *filename, sqlite3 **ppDb);
      int sqlite3_close(sqlite3 *db);
      int sqlite3_exec(sqlite3 *db, const char *sql, int (*callback)(void*,int,char**,char**), void *arg, char **errmsg);
      void sqlite3_free(void *ptr);
      const char *sqlite3_errmsg(sqlite3 *db);

      int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
      int sqlite3_step(sqlite3_stmt *pStmt);
      int sqlite3_finalize(sqlite3_stmt *pStmt);
      int sqlite3_reset(sqlite3_stmt *pStmt);

      int sqlite3_column_count(sqlite3_stmt *pStmt);
      const char *sqlite3_column_name(sqlite3_stmt *pStmt, int N);
      const unsigned char *sqlite3_column_text(sqlite3_stmt *pStmt, int iCol);
      long long sqlite3_column_int64(sqlite3_stmt *pStmt, int iCol);
      double sqlite3_column_double(sqlite3_stmt *pStmt, int iCol);
      int sqlite3_column_type(sqlite3_stmt *pStmt, int iCol);

      int sqlite3_bind_text(sqlite3_stmt *pStmt, int idx, const char *val, int nByte, void(*destructor)(void*));
      int sqlite3_bind_int64(sqlite3_stmt *pStmt, int idx, long long val);
    ]])
  end)
  local ok, lib = pcall(ffi.load, "sqlite3")
  if ok then
    sqlite_lib = lib
  end
end

local SQLITE_OK = 0
local SQLITE_ROW = 100
local SQLITE_DONE = 101
local SQLITE_TRANSIENT = ffi_ok and ffi.cast("void(*)(void*)", -1) or nil

function M.is_ffi_available()
  return sqlite_lib ~= nil
end

--- Open an FFI sqlite3 database handle
function M.open_db(db_path)
  if not sqlite_lib then
    return nil, "libsqlite3 FFI not available"
  end
  local ppDb = ffi.new("sqlite3*[1]")
  local rc = sqlite_lib.sqlite3_open(db_path, ppDb)
  if rc ~= SQLITE_OK then
    return nil, "sqlite3_open failed: " .. tostring(rc)
  end
  local db = ppDb[0]
  M.exec(db, [[
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    PRAGMA temp_store = MEMORY;
    PRAGMA cache_size = -128000;
    PRAGMA mmap_size = 1073741824;
  ]])
  return db
end

function M.close_db(db)
  if db and sqlite_lib then
    sqlite_lib.sqlite3_close(db)
  end
end

function M.exec(db, sql)
  if not db or not sqlite_lib then
    return false, "No DB"
  end
  local errmsg = ffi.new("char*[1]")
  local rc = sqlite_lib.sqlite3_exec(db, sql, nil, nil, errmsg)
  if rc ~= SQLITE_OK then
    local msg = errmsg[0] ~= nil and ffi.string(errmsg[0]) or ("Error " .. rc)
    if errmsg[0] ~= nil then
      sqlite_lib.sqlite3_free(errmsg[0])
    end
    return false, msg
  end
  return true
end

function M.query(db, sql, bind_params)
  if not db or not sqlite_lib then
    return nil, "No DB"
  end
  local ppStmt = ffi.new("sqlite3_stmt*[1]")
  local rc = sqlite_lib.sqlite3_prepare_v2(db, sql, #sql, ppStmt, nil)
  if rc ~= SQLITE_OK then
    return nil, ffi.string(sqlite_lib.sqlite3_errmsg(db))
  end
  local stmt = ppStmt[0]

  if bind_params then
    for idx, val in ipairs(bind_params) do
      if type(val) == "number" and math.floor(val) == val then
        sqlite_lib.sqlite3_bind_int64(stmt, idx, val)
      else
        local s = tostring(val)
        sqlite_lib.sqlite3_bind_text(stmt, idx, s, #s, SQLITE_TRANSIENT)
      end
    end
  end

  local col_count = sqlite_lib.sqlite3_column_count(stmt)
  local col_names = {}
  for c = 0, col_count - 1 do
    local cname = sqlite_lib.sqlite3_column_name(stmt, c)
    col_names[c + 1] = cname ~= nil and ffi.string(cname) or ("col_" .. (c + 1))
  end

  local rows = {}
  while true do
    local step_rc = sqlite_lib.sqlite3_step(stmt)
    if step_rc == SQLITE_ROW then
      local r = {}
      for c = 0, col_count - 1 do
        local txt = sqlite_lib.sqlite3_column_text(stmt, c)
        r[c + 1] = txt ~= nil and ffi.string(txt) or ""
      end
      table.insert(rows, r)
    elseif step_rc == SQLITE_DONE then
      break
    else
      local err = ffi.string(sqlite_lib.sqlite3_errmsg(db))
      sqlite_lib.sqlite3_finalize(stmt)
      return nil, err
    end
  end

  sqlite_lib.sqlite3_finalize(stmt)
  return rows, nil, col_names
end

--- Quote a SQL string literal safely
local function sql_str(s)
  return "'" .. tostring(s or ""):gsub("'", "''") .. "'"
end

--- Build deterministic SQLite cache path for a CSV file
function M.get_db_path(filepath, file_size, mtime)
  local config = require("super-csv.config").options
  local key = string.format("%s|%d|%d", filepath, file_size or 0, mtime or 0)
  local hash = vim.fn.sha256(key):sub(1, 20)
  local basename = vim.fn.fnamemodify(filepath, ":t:r"):gsub("[^%w_%-]", "_")
  return string.format("%s/%s_%s.sqlite", config.cache_dir, basename, hash)
end

--- Create schema and import CSV into SQLite (only when cached, small < 2MB, or explicitly requested)
function M.init_session_db(session, on_ready, force_import)
  local db_path = M.get_db_path(session.filepath, session.file_size, session.mtime)
  session.db_path = db_path

  local function finalize_open()
    local db, err = M.open_db(db_path)
    if not db then
      session.sqlite_error = err
      return
    end
    session.db = db
    -- Use O(1) B-Tree MAX(rowid) instead of full-table COUNT(*) scan!
    local cnt_rows = M.query(db, "SELECT MAX(rowid) FROM csv_data;")
    session.total_rows = (cnt_rows and cnt_rows[1] and tonumber(cnt_rows[1][1])) or #session.preview_rows
    session.filtered_rows = session.total_rows
    session.sqlite_ready = true
    session.batch_cache = nil
    session.stats_cache = {}
    session.fast_stats_cache = {}
    if on_ready then
      vim.schedule(on_ready)
    end
  end

  -- 1. If cached DB already exists and has csv_data table, open immediately in < 0.1ms!
  if vim.fn.filereadable(db_path) == 1 then
    local test_db = M.open_db(db_path)
    if test_db then
      local check = M.query(test_db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='csv_data';")
      if check and check[1] and tonumber(check[1][1]) == 1 then
        local cnt_rows = M.query(test_db, "SELECT MAX(rowid) FROM csv_data;")
        local max_id = (cnt_rows and cnt_rows[1] and tonumber(cnt_rows[1][1])) or 0
        if max_id > 0 then
          session.db = test_db
          session.total_rows = max_id
          session.filtered_rows = max_id
          session.sqlite_ready = true
          session.batch_cache = nil
          session.stats_cache = {}
          session.fast_stats_cache = {}
          if on_ready then
            vim.schedule(on_ready)
          end
          return
        end
      end
      M.close_db(test_db)
    end
  end

  local cfg = require("super-csv.config").options
  -- 2. For huge files (>= 2MB), do NOT start loading/indexing everything on open when lazy_sqlite is enabled!
  --    Instead, stream batches from disk on scroll, and only index into SQLite when force_import is true.
  if cfg.lazy_sqlite ~= false and not force_import and (session.file_size or 0) >= 2 * 1024 * 1024 then
    return
  end

  if session.sqlite_indexing then
    if on_ready then
      session._on_index_callbacks = session._on_index_callbacks or {}
      table.insert(session._on_index_callbacks, on_ready)
    end
    return
  end

  -- Build CREATE TABLE with c1..cN plus friendly view 'csv' with actual column names
  local col_defs = {}
  local view_cols = { "rowid AS _rowid_" }
  for c = 1, session.num_cols do
    table.insert(col_defs, string.format("c%d TEXT", c))
    local safe_name = session.headers[c]:gsub('"', '""')
    table.insert(view_cols, string.format('c%d AS "%s"', c, safe_name))
  end

  local sep_cmd = ".mode csv"
  if session.delim == "\t" then
    sep_cmd = '.mode ascii\n.separator "\\t" "\\n"'
  elseif session.delim ~= "," then
    sep_cmd = string.format('.mode csv\n.separator "%s"', session.delim)
  end

  local create_sql = string.format(
    [[
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;
PRAGMA temp_store = MEMORY;
PRAGMA cache_size = -256000;
DROP TABLE IF EXISTS csv_data;
CREATE TABLE csv_data (%s);
DROP VIEW IF EXISTS csv;
CREATE VIEW csv AS SELECT %s FROM csv_data;
]],
    table.concat(col_defs, ", "),
    table.concat(view_cols, ", ")
  )

  local import_script = create_sql .. "\n" .. sep_cmd .. "\n"
    .. string.format('.import --skip 1 %s csv_data\n', vim.fn.shellescape(session.filepath))

  -- For small files (< 2MB), import synchronously in ~15ms so SQLite is ready immediately on first frame!
  if (session.file_size or 0) < 2 * 1024 * 1024 then
    vim.fn.system({ "sqlite3", db_path }, import_script)
    finalize_open()
  else
    session.sqlite_indexing = true
    session._on_index_callbacks = session._on_index_callbacks or {}
    if on_ready then
      table.insert(session._on_index_callbacks, on_ready)
    end
    vim.notify("[SuperCsv] Indexing huge file into SQLite in background...", vim.log.levels.INFO)
    vim.system({ "sqlite3", db_path }, { stdin = import_script }, function(_res)
      vim.schedule(function()
        session.sqlite_indexing = false
        finalize_open()
        local cbs = session._on_index_callbacks or {}
        session._on_index_callbacks = {}
        for _, cb in ipairs(cbs) do
          pcall(cb)
        end
      end)
    end)
  end
end

--- Ensure SQLite DB is indexed (triggers background import if not yet indexed)
function M.ensure_indexed(session, on_ready)
  if session.sqlite_ready and session.db then
    if on_ready then on_ready() end
    return true
  end
  M.init_session_db(session, on_ready, true)
  return session.sqlite_ready == true
end

--- Build SQL WHERE clause from active session filters and global grep
function M.build_where_clause(session, exclude_col_idx)
  local clauses = {}

  -- 1. Deleted rows filter (if any deleted in memory before SQLite sync)
  if session.deleted_rowids and next(session.deleted_rowids) then
    local ids = {}
    for id in pairs(session.deleted_rowids) do
      table.insert(ids, tostring(id))
    end
    table.insert(clauses, "rowid NOT IN (" .. table.concat(ids, ",") .. ")")
  end

  -- 2. Per-column filters
  for col_idx, flt in pairs(session.filters or {}) do
    if col_idx ~= exclude_col_idx and flt then
      local col_expr = "c" .. col_idx
      local num_expr = string.format("CAST(REPLACE(REPLACE(%s, '$', ''), ',', '') AS REAL)", col_expr)

      if flt.values and next(flt.values) then
        local allowed = {}
        for val, enabled in pairs(flt.values) do
          if enabled then
            table.insert(allowed, sql_str(val))
          end
        end
        if #allowed > 0 then
          table.insert(clauses, string.format("%s IN (%s)", col_expr, table.concat(allowed, ",")))
        else
          table.insert(clauses, "1 = 0")
        end
      end

      if flt.op and flt. op ~= "" then
        local op = flt.op
        local val = flt.val or ""
        local num_val = tonumber((tostring(val):gsub("^%$", ""):gsub(",", "")))
        if op == "=" or op == "==" then
          if num_val and (session.types[col_idx] == "i64" or session.types[col_idx] == "f64") then
            table.insert(clauses, string.format("%s = %s", num_expr, tostring(num_val)))
          else
            table.insert(clauses, string.format("LOWER(%s) = LOWER(%s)", col_expr, sql_str(val)))
          end
        elseif op == "!=" or op == "<>" then
          if num_val and (session.types[col_idx] == "i64" or session.types[col_idx] == "f64") then
            table.insert(clauses, string.format("%s != %s", num_expr, tostring(num_val)))
          else
            table.insert(clauses, string.format("LOWER(%s) != LOWER(%s)", col_expr, sql_str(val)))
          end
        elseif (op == ">" or op == ">=" or op == "<" or op == "<=") and num_val then
          table.insert(clauses, string.format("(%s != '' AND %s %s %s)", col_expr, num_expr, op, tostring(num_val)))
        elseif op == "contains" or op == "~" then
          table.insert(clauses, string.format("%s LIKE %s", col_expr, sql_str("%" .. val .. "%")))
        elseif op == "!contains" then
          table.insert(clauses, string.format("%s NOT LIKE %s", col_expr, sql_str("%" .. val .. "%")))
        elseif op == "starts" or op == "^" then
          table.insert(clauses, string.format("%s LIKE %s", col_expr, sql_str(val .. "%")))
        elseif op == "ends" or op == "$" then
          table.insert(clauses, string.format("%s LIKE %s", col_expr, sql_str("%" .. val)))
        elseif op == "null" or op == "empty" then
          table.insert(clauses, string.format("(%s IS NULL OR %s = '' OR LOWER(%s) = 'null')", col_expr, col_expr, col_expr))
        elseif op == "notnull" or op == "!null" then
          table.insert(clauses, string.format("(%s IS NOT NULL AND %s != '' AND LOWER(%s) != 'null')", col_expr, col_expr, col_expr))
        end
      end
    end
  end

  -- 3. Global Grep across all columns
  if session.grep_pattern and session.grep_pattern ~= "" then
    local pat = sql_str("%" .. session.grep_pattern .. "%")
    local or_parts = {}
    for c = 1, session.num_cols do
      table.insert(or_parts, string.format("c%d LIKE %s", c, pat))
    end
    table.insert(clauses, "(" .. table.concat(or_parts, " OR ") .. ")")
  end

  if #clauses == 0 then
    return ""
  end
  return "WHERE " .. table.concat(clauses, " AND ")
end

--- Build SQL ORDER BY clause
function M.build_order_clause(session)
  if not session.sort or not session.sort.col_idx then
    return "ORDER BY rowid ASC"
  end
  local c = session.sort.col_idx
  local dir = (session.sort.dir == "DESC") and "DESC" or "ASC"
  local col_type = session.types[c]
  if col_type == "i64" or col_type == "f64" then
    return string.format("ORDER BY CAST(REPLACE(REPLACE(c%d, '$', ''), ',', '') AS REAL) %s, rowid ASC", c, dir)
  end
  return string.format("ORDER BY c%d COLLATE NOCASE %s, rowid ASC", c, dir)
end

--- Helper: execute a batch query for rows in [start_row_1 .. start_row_1 + batch_len - 1]
local function query_row_batch(session, where_sql, order_sql, start_row_1, batch_len)
  local cols = { "rowid" }
  for c = 1, session.num_cols do
    cols[c + 1] = "c" .. c
  end
  local col_list = table.concat(cols, ",")
  local is_unfiltered = (where_sql == "")
  local is_default_sort = (not session.sort or not session.sort.col_idx)
  local has_deletes = (session.deleted_rowids and next(session.deleted_rowids) ~= nil)

  local sql
  if is_unfiltered and is_default_sort and not has_deletes then
    -- O(log N) primary key B-Tree seek (0.1ms even at row 999,999, avoiding O(N) OFFSET scan!)
    local min_id = start_row_1
    local max_id = start_row_1 + batch_len - 1
    sql = string.format(
      "SELECT %s FROM csv_data WHERE rowid >= %d AND rowid <= %d ORDER BY rowid ASC LIMIT %d;",
      col_list,
      min_id,
      max_id,
      batch_len
    )
  else
    sql = string.format(
      "SELECT %s FROM csv_data %s %s LIMIT %d OFFSET %d;",
      col_list,
      where_sql,
      order_sql,
      batch_len,
      start_row_1 - 1
    )
  end

  local raw_rows = M.query(session.db, sql) or {}
  local result = {}
  local num_cols = session.num_cols
  for i, r in ipairs(raw_rows) do
    local rowid = tonumber(r[1]) or 0
    local cells = {}
    for c = 1, num_cols do
      cells[c] = r[c + 1] or ""
    end
    result[i] = {
      rowid = rowid,
      cells = cells,
    }
  end
  return result
end

--- Fetch visible slice of rows using an in-memory Batch Window Cache + Fast-Scroll Adaptive Fetch
function M.fetch_viewport_rows(session, offset, limit)
  offset = math.max(0, offset or 0)
  limit = math.max(1, limit or 40)

  if not session.sqlite_ready or not session.db then
    -- Stream batches from disk on demand as the user scrolls down!
    local parser = require("super-csv.engine.parser")
    if not session.eof_reached and (offset + limit + 50 > #(session.preview_rows or {})) then
      parser.ensure_rows_loaded(session, offset + limit + 50)
    end
    local all = session.preview_rows or {}
    local out = {}
    for i = offset + 1, math.min(#all, offset + limit) do
      table.insert(out, all[i])
    end
    session.total_rows = #all
    session.filtered_rows = #all
    return out, #all
  end

  local where_sql = M.build_where_clause(session)
  local order_sql = M.build_order_clause(session)

  -- Cache filtered count per filter signature (use O(1) MAX(rowid) when unfiltered!)
  local filter_sig = where_sql
  if session.cached_where_sig ~= filter_sig then
    if where_sql == "" then
      local cnt_res = M.query(session.db, "SELECT MAX(rowid) FROM csv_data;")
      session.filtered_rows = (cnt_res and cnt_res[1] and tonumber(cnt_res[1][1])) or session.total_rows or 0
    else
      local cnt_sql = "SELECT COUNT(*) FROM csv_data " .. where_sql .. ";"
      local cnt_res = M.query(session.db, cnt_sql)
      session.filtered_rows = (cnt_res and cnt_res[1] and tonumber(cnt_res[1][1])) or 0
    end
    session.cached_where_sig = filter_sig
    session.batch_cache = nil
    session.stats_cache = {}
    session.fast_stats_cache = {}
  end

  local total = session.filtered_rows or session.total_rows or 0
  if total == 0 then
    return {}, 0
  end

  local req_start = offset + 1
  local req_end = math.min(total, offset + limit)
  local cache_sig = where_sql .. "|" .. order_sql
  local bc = session.batch_cache

  -- 1. Check if requested viewport is completely inside the in-memory batch cache (0 SQLite calls!)
  if bc and bc.sig == cache_sig and req_start >= bc.start_row and req_end <= bc.end_row then
    local slice = {}
    local base = req_start - bc.start_row
    for i = 1, (req_end - req_start + 1) do
      local item = bc.rows[base + i]
      if item then
        slice[#slice + 1] = item
      end
    end
    return slice, total
  end

  -- 2. Viewport moved outside the current batch: adaptive batch size for fast vs normal scrolling
  local uv = vim.uv or vim.loop
  local now_hr = uv.hrtime and uv.hrtime() or 0
  local elapsed_ms = (now_hr - (session._last_fetch_hrtime or 0)) / 1e6
  session._last_fetch_hrtime = now_hr

  local cfg = require("super-csv.config").options
  local full_batch_size = cfg.batch_size or 500
  if (session.num_cols or 1) >= 50 and full_batch_size > 250 then
    full_batch_size = 250 -- Keep wide 100-col batch FFI allocation < 1ms
  end

  local is_fast_scrolling = (elapsed_ms > 0 and elapsed_ms < 75)
  local fetch_start, fetch_len

  if is_fast_scrolling then
    -- Fast scrolling: fetch only the immediate visible viewport + small margin so frame renders in < 0.3ms
    fetch_start = math.max(1, req_start - 5)
    fetch_len = limit + 15
  else
    -- Normal scrolling: load a full batch of rows around the current viewport
    local lead = math.min(60, math.floor(full_batch_size * 0.25))
    fetch_start = math.max(1, req_start - lead)
    fetch_len = full_batch_size
  end

  if fetch_start + fetch_len - 1 > total then
    fetch_len = math.max(limit, total - fetch_start + 1)
  end

  local batch_rows = query_row_batch(session, where_sql, order_sql, fetch_start, fetch_len)
  session.batch_cache = {
    sig = cache_sig,
    start_row = fetch_start,
    end_row = fetch_start + #batch_rows - 1,
    rows = batch_rows,
  }
  session.fast_stats_cache = {}

  -- If fast-scrolling, schedule a debounced background batch prefetch once scrolling settles
  if is_fast_scrolling and uv.new_timer then
    if not session._batch_timer then
      session._batch_timer = uv.new_timer()
    else
      session._batch_timer:stop()
    end
    session._batch_timer:start(85, 0, vim.schedule_wrap(function()
      if not session.sqlite_ready or not session.db then return end
      if not session.view_buf or not vim.api.nvim_buf_is_valid(session.view_buf) then return end
      local cur_top = math.max(1, session.top_row or 1)
      local lead = math.min(60, math.floor(full_batch_size * 0.25))
      local b_start = math.max(1, cur_top - lead)
      local b_len = math.min(full_batch_size, math.max(limit, total - b_start + 1))
      local cur_w = M.build_where_clause(session)
      local cur_o = M.build_order_clause(session)
      local rows_prefetched = query_row_batch(session, cur_w, cur_o, b_start, b_len)
      session.batch_cache = {
        sig = cur_w .. "|" .. cur_o,
        start_row = b_start,
        end_row = b_start + #rows_prefetched - 1,
        rows = rows_prefetched,
      }
      session.fast_stats_cache = {}
    end))
  end

  local out = {}
  local base = req_start - fetch_start
  for i = 1, (req_end - req_start + 1) do
    local item = batch_rows[base + i]
    if item then
      out[#out + 1] = item
    end
  end

  return out, total
end

--- Compute instant (< 0.1ms) column stats over the active batch for the viewport footer & heatmap
--- (Avoids running a 1.2s full 1,000,000-row table scan during scrolling!)
function M.get_fast_column_stats(session, col_idx)
  col_idx = col_idx or 1
  session.fast_stats_cache = session.fast_stats_cache or {}
  if session.fast_stats_cache[col_idx] then
    return session.fast_stats_cache[col_idx]
  end

  -- If full stats were already computed and cached, return them
  if session.stats_cache and session.stats_cache[col_idx] then
    return session.stats_cache[col_idx]
  end

  local rows = (session.batch_cache and session.batch_cache.rows)
    or session.visible_rows
    or session.preview_rows
    or {}

  local sample_count = #rows
  local nulls = 0
  local uniq = {}
  local uniq_cnt = 0
  local sum, min_v, max_v = 0, nil, nil
  local str_min, str_max = nil, nil
  local num_cnt = 0

  for _, r in ipairs(rows) do
    local v = (r.cells and r.cells[col_idx]) or ""
    if v == "" or v == "null" or v == "NULL" then
      nulls = nulls + 1
    else
      if not uniq[v] then
        uniq[v] = true
        uniq_cnt = uniq_cnt + 1
      end
      if not str_min or v < str_min then str_min = v end
      if not str_max or v > str_max then str_max = v end
      local n = tonumber((v:gsub("^%$", ""):gsub(",", "")))
      if n then
        num_cnt = num_cnt + 1
        sum = sum + n
        if not min_v or n < min_v then min_v = n end
        if not max_v or n > max_v then max_v = n end
      end
    end
  end

  local is_num = (session.types[col_idx] == "i64" or session.types[col_idx] == "f64")
    or (num_cnt > 0 and num_cnt >= math.max(1, (sample_count - nulls) * 0.6))

  local total_count = session.filtered_rows or session.total_rows or sample_count
  local st = {
    count = total_count,
    sample_count = sample_count,
    distinct = uniq_cnt,
    nulls = nulls,
    is_numeric = is_num,
    sum = sum,
    avg = num_cnt > 0 and (sum / num_cnt) or 0,
    min = is_num and (min_v or 0) or (str_min or ""),
    max = is_num and (max_v or 0) or (str_max or ""),
  }
  session.fast_stats_cache[col_idx] = st
  return st
end

--- Compute full-table Excel Statistics (COUNT, DISTINCT, NULLS, SUM, AVG, MIN, MAX) for `gs` modal
function M.get_column_stats(session, col_idx)
  col_idx = col_idx or 1
  if not session.sqlite_ready or not session.db then
    return M.get_fast_column_stats(session, col_idx)
  end

  session.stats_cache = session.stats_cache or {}
  if session.stats_cache[col_idx] then
    return session.stats_cache[col_idx]
  end

  local where_sql = M.build_where_clause(session)
  local c = "c" .. col_idx
  local is_num = (session.types[col_idx] == "i64" or session.types[col_idx] == "f64")
  local num_expr = string.format("CAST(REPLACE(REPLACE(%s, '$', ''), ',', '') AS REAL)", c)

  local sql
  if is_num then
    sql = string.format(
      [[
      SELECT
        COUNT(*),
        COUNT(DISTINCT CASE WHEN %s != '' THEN %s END),
        SUM(CASE WHEN %s IS NULL OR %s = '' OR LOWER(%s) = 'null' THEN 1 ELSE 0 END),
        SUM(CASE WHEN %s != '' THEN %s ELSE 0 END),
        AVG(CASE WHEN %s != '' THEN %s END),
        MIN(CASE WHEN %s != '' THEN %s END),
        MAX(CASE WHEN %s != '' THEN %s END)
      FROM csv_data %s;
      ]],
      c, c, c, c, c, c, num_expr, c, num_expr, c, num_expr, c, num_expr, where_sql
    )
  else
    sql = string.format(
      [[
      SELECT
        COUNT(*),
        COUNT(DISTINCT CASE WHEN %s != '' THEN %s END),
        SUM(CASE WHEN %s IS NULL OR %s = '' OR LOWER(%s) = 'null' THEN 1 ELSE 0 END),
        0, 0,
        MIN(CASE WHEN %s != '' THEN %s END),
        MAX(CASE WHEN %s != '' THEN %s END)
      FROM csv_data %s;
      ]],
      c, c, c, c, c, c, c, c, c, where_sql
    )
  end

  local res = M.query(session.db, sql)
  local row = (res and res[1]) or { "0", "0", "0", "0", "0", "", "" }
  local stats = {
    count = tonumber(row[1]) or 0,
    distinct = tonumber(row[2]) or 0,
    nulls = tonumber(row[3]) or 0,
    is_numeric = is_num,
    sum = tonumber(row[4]) or 0,
    avg = tonumber(row[5]) or 0,
    min = is_num and (tonumber(row[6]) or 0) or (row[6] or ""),
    max = is_num and (tonumber(row[7]) or 0) or (row[7] or ""),
  }
  session.stats_cache[col_idx] = stats
  return stats
end

--- Compute distinct Value Counts / Frequency table for a column (Excel AutoFilter & :SuperCsv freq)
function M.get_value_counts(session, col_idx, limit)
  limit = limit or 150
  col_idx = col_idx or 1

  if not session.sqlite_ready or not session.db then
    local counts = {}
    local rows = session.preview_rows or {}
    for _, r in ipairs(rows) do
      local v = r.cells[col_idx] or ""
      counts[v] = (counts[v] or 0) + 1
    end
    local list = {}
    for val, cnt in pairs(counts) do
      table.insert(list, {
        value = val,
        count = cnt,
        pct = (#rows > 0) and (cnt * 100.0 / #rows) or 0,
      })
    end
    table.sort(list, function(a, b)
      if a.count ~= b.count then return a.count > b.count end
      return a.value < b.value
    end)
    return list, #rows
  end

  local where_sql = M.build_where_clause(session, col_idx)
  local base_total
  if where_sql == "" and session.total_rows and session.total_rows > 0 then
    base_total = session.total_rows
  else
    local total_sql = "SELECT COUNT(*) FROM csv_data " .. where_sql .. ";"
    local tot_res = M.query(session.db, total_sql)
    base_total = (tot_res and tot_res[1] and tonumber(tot_res[1][1])) or 1
  end

  local sql = string.format(
    "SELECT c%d, COUNT(*) AS cnt FROM csv_data %s GROUP BY c%d ORDER BY cnt DESC, c%d ASC LIMIT %d;",
    col_idx, where_sql, col_idx, col_idx, limit
  )
  local rows = M.query(session.db, sql) or {}
  local out = {}
  for _, r in ipairs(rows) do
    local cnt = tonumber(r[2]) or 0
    table.insert(out, {
      value = r[1] or "",
      count = cnt,
      pct = (base_total > 0) and (cnt * 100.0 / base_total) or 0,
    })
  end
  return out, base_total
end

--- Edit a single cell with Undo/Redo history
function M.update_cell(session, rowid, col_idx, new_val, record_undo)
  new_val = tostring(new_val or "")
  local old_val = ""

  -- Update preview rows if present
  for _, r in ipairs(session.preview_rows or {}) do
    if r.rowid == rowid then
      old_val = r.cells[col_idx] or ""
      r.cells[col_idx] = new_val
      break
    end
  end

  -- Update in-memory batch cache if present
  if session.batch_cache and session.batch_cache.rows then
    for _, r in ipairs(session.batch_cache.rows) do
      if r.rowid == rowid then
        if old_val == "" then old_val = r.cells[col_idx] or "" end
        r.cells[col_idx] = new_val
        break
      end
    end
  end

  if session.sqlite_ready and session.db then
    local cur = M.query(session.db, string.format("SELECT c%d FROM csv_data WHERE rowid = %d;", col_idx, rowid))
    if cur and cur[1] then
      old_val = cur[1][1] or old_val
    end
    local sql = string.format("UPDATE csv_data SET c%d = ? WHERE rowid = ?;", col_idx)
    M.query(session.db, sql, { new_val, rowid })
    session.stats_cache = {}
  end
  session.fast_stats_cache = {}

  session.modified_cells = session.modified_cells or {}
  session.modified_cells[rowid] = session.modified_cells[rowid] or {}
  session.modified_cells[rowid][col_idx] = new_val
  session.edit_count = (session.edit_count or 0) + 1

  if record_undo ~= false then
    session.undo_stack = session.undo_stack or {}
    table.insert(session.undo_stack, {
      action = "cell",
      rowid = rowid,
      col_idx = col_idx,
      old_val = old_val,
      new_val = new_val,
    })
    session.redo_stack = {}
  end
end

--- Insert a new row after rowid
function M.insert_row(session, values)
  values = values or {}
  local prev_row = session.cur_row or 1
  local prev_top = session.top_row or 1
  local cols = {}
  local placeholders = {}
  local params = {}
  for c = 1, session.num_cols do
    cols[c] = "c" .. c
    placeholders[c] = "?"
    params[c] = tostring(values[c] or "")
  end

  local new_rowid = (session.total_rows or #session.preview_rows) + 1
  if session.sqlite_ready and session.db then
    local sql = string.format(
      "INSERT INTO csv_data (%s) VALUES (%s);",
      table.concat(cols, ","),
      table.concat(placeholders, ",")
    )
    M.query(session.db, sql, params)
    local id_res = M.query(session.db, "SELECT MAX(rowid) FROM csv_data;")
    if id_res and id_res[1] then
      new_rowid = tonumber(id_res[1][1]) or new_rowid
    end
    session.total_rows = (session.total_rows or 0) + 1
    session.cached_where_sig = nil
    session.batch_cache = nil
    session.stats_cache = {}
  end
  session.fast_stats_cache = {}

  table.insert(session.preview_rows, { rowid = new_rowid, cells = params })
  session.edit_count = (session.edit_count or 0) + 1
  session.undo_stack = session.undo_stack or {}
  table.insert(session.undo_stack, {
    action = "insert_row",
    rowid = new_rowid,
    prev_row = prev_row,
    prev_top = prev_top,
  })
  session.redo_stack = {}
  return new_rowid
end

--- Delete a row by rowid
function M.delete_row(session, rowid, record_undo)
  if session.sqlite_ready and session.db then
    M.query(session.db, "DELETE FROM csv_data WHERE rowid = ?;", { rowid })
    session.total_rows = math.max(0, (session.total_rows or 1) - 1)
    session.cached_where_sig = nil
    session.batch_cache = nil
    session.stats_cache = {}
  end
  session.fast_stats_cache = {}
  for i, r in ipairs(session.preview_rows or {}) do
    if r.rowid == rowid then
      table.remove(session.preview_rows, i)
      break
    end
  end
  if record_undo ~= false then
    session.edit_count = (session.edit_count or 0) + 1
  end
end

--- Undo last cell or row edit
function M.undo(session)
  local stack = session.undo_stack or {}
  if #stack == 0 then
    return false, "Already at oldest change"
  end
  local item = table.remove(stack)
  if item.action == "cell" then
    M.update_cell(session, item.rowid, item.col_idx, item.old_val, false)
    session.edit_count = math.max(0, (session.edit_count or 2) - 2)
    if session.modified_cells and session.modified_cells[item.rowid] then
      session.modified_cells[item.rowid][item.col_idx] = nil
    end
    session.redo_stack = session.redo_stack or {}
    table.insert(session.redo_stack, item)
    return true, string.format("Cancelled/undid edit on Row %d, %s", item.rowid, session.headers[item.col_idx])
  elseif item.action == "insert_row" then
    M.delete_row(session, item.rowid, false)
    session.edit_count = math.max(0, (session.edit_count or 1) - 1)
    if item.prev_row then session.cur_row = item.prev_row end
    if item.prev_top then session.top_row = item.prev_top end
    return true, string.format("Cancelled inserted row #%d and restored position", item.rowid)
  end
  return false, "Nothing to undo"
end

--- Redo last undone edit
function M.redo(session)
  local stack = session.redo_stack or {}
  if #stack == 0 then
    return false, "Already at newest change"
  end
  local item = table.remove(stack)
  if item.action == "cell" then
    M.update_cell(session, item.rowid, item.col_idx, item.new_val, false)
    session.undo_stack = session.undo_stack or {}
    table.insert(session.undo_stack, item)
    return true, string.format("Redid edit on Row %d, %s", item.rowid, session.headers[item.col_idx])
  end
  return false, "Nothing to redo"
end

--- Run custom SQL against `csv` (with friendly column names) or `csv_data` (c1..cN)
function M.run_custom_sql(session, sql_query)
  if not session.sqlite_ready or not session.db then
    return nil, "SQLite engine is still indexing; try again in a moment"
  end
  -- Allow users to write `FROM csv` or `FROM self` or `FROM data`
  local normalized = sql_query:gsub("%f[%w]self%f[%W]", "csv"):gsub("%f[%w]data%f[%W]", "csv")
  local rows, err, col_names = M.query(session.db, normalized)
  if not rows then
    return nil, err
  end
  return {
    headers = col_names,
    rows = rows,
  }
end

--- Atomically save/export to CSV file
function M.save_to_csv(session, target_path, only_filtered)
  target_path = target_path or session.filepath
  local parser = require("super-csv.engine.parser")
  local tmp_path = target_path .. ".supercsv.tmp"
  local f, err = io.open(tmp_path, "wb")
  if not f then
    return false, "Cannot open temp file: " .. tostring(err)
  end

  f:write(parser.encode_line(session.headers, session.delim) .. "\n")

  if session.sqlite_ready and session.db then
    local where_sql = only_filtered and M.build_where_clause(session) or ""
    local order_sql = only_filtered and M.build_order_clause(session) or "ORDER BY rowid ASC"
    local cols = {}
    for c = 1, session.num_cols do
      cols[c] = "c" .. c
    end
    local sql = string.format("SELECT %s FROM csv_data %s %s;", table.concat(cols, ","), where_sql, order_sql)
    local ppStmt = ffi.new("sqlite3_stmt*[1]")
    local rc = sqlite_lib.sqlite3_prepare_v2(session.db, sql, #sql, ppStmt, nil)
    if rc == SQLITE_OK then
      local stmt = ppStmt[0]
      local chunk = {}
      local count = 0
      while sqlite_lib.sqlite3_step(stmt) == SQLITE_ROW do
        local vals = {}
        for c = 0, session.num_cols - 1 do
          local txt = sqlite_lib.sqlite3_column_text(stmt, c)
          vals[c + 1] = txt ~= nil and ffi.string(txt) or ""
        end
        count = count + 1
        chunk[count] = parser.encode_line(vals, session.delim)
        if count >= 2000 then
          f:write(table.concat(chunk, "\n") .. "\n")
          chunk = {}
          count = 0
        end
      end
      if count > 0 then
        f:write(table.concat(chunk, "\n") .. "\n")
      end
      sqlite_lib.sqlite3_finalize(stmt)
    end
  else
    for _, r in ipairs(session.preview_rows or {}) do
      f:write(parser.encode_line(r.cells, session.delim) .. "\n")
    end
  end

  f:close()
  local ok_ren, ren_err = os.rename(tmp_path, target_path)
  if not ok_ren then
    os.remove(tmp_path)
    return false, "Rename failed: " .. tostring(ren_err)
  end

  if target_path == session.filepath then
    session.edit_count = 0
    session.modified_cells = {}
  end
  return true
end

return M
