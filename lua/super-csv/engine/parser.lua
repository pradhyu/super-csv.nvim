local M = {}

local uv = vim.uv or vim.loop

--- Convert 1-based column index to Excel column letters (1 -> A, 26 -> Z, 27 -> AA, 100 -> CV)
function M.col_to_excel(idx)
  local s = ""
  local n = idx
  while n > 0 do
    local rem = (n - 1) % 26
    s = string.char(65 + rem) .. s
    n = math.floor((n - 1) / 26)
  end
  return s
end

--- Check if a CSV line is a comment line (starts with configured `comment_char`, default `#`, after optional whitespace)
function M.is_comment_line(line)
  if not line or line == "" then
    return false
  end
  local cfg = require("super-csv.config")
  local cchar = cfg.get_csv_comment_char()
  if type(cchar) == "table" then
    for _, p in ipairs(cchar) do
      if type(p) == "string" and p ~= "" and line:match("^%s*" .. vim.pesc(p)) ~= nil then
        return true
      end
    end
    return false
  end
  if not cchar or cchar == "" then
    return false
  end
  return line:match("^%s*" .. vim.pesc(tostring(cchar))) ~= nil
end

--- Detect delimiter (',', '\t', '|', ';') from sample text (skipping leading `#` comment lines)
function M.detect_delimiter(sample)
  local first_line = nil
  for l in (sample or ""):gmatch("[^\r\n]+") do
    if l ~= "" and not M.is_comment_line(l) then
      first_line = l
      break
    end
  end
  first_line = first_line or sample:match("^([^\r\n]+)") or sample
  local candidates = { ",", "\t", "|", ";" }
  local best_delim = ","
  local best_count = -1
  for _, d in ipairs(candidates) do
    local cnt = 0
    local in_quote = false
    for i = 1, #first_line do
      local ch = first_line:sub(i, i)
      if ch == '"' then
        in_quote = not in_quote
      elseif not in_quote and ch == d then
        cnt = cnt + 1
      end
    end
    if cnt > best_count then
      best_count = cnt
      best_delim = d
    end
  end
  return best_delim
end

--- Parse a single RFC 4180 CSV line into an array of field strings
function M.parse_line(line, delim)
  delim = delim or ","
  local fields = {}
  local len = #line
  if len > 0 and line:sub(len, len) == "\r" then
    line = line:sub(1, len - 1)
    len = len - 1
  end

  local i = 1
  local field_idx = 1
  local delim_byte = string.byte(delim, 1)
  local quote_byte = 34 -- '"'

  while i <= len do
    local b = string.byte(line, i)
    if b == quote_byte then
      -- Quoted field
      local chars = {}
      i = i + 1
      while i <= len do
        local cb = string.byte(line, i)
        if cb == quote_byte then
          if i + 1 <= len and string.byte(line, i + 1) == quote_byte then
            table.insert(chars, '"')
            i = i + 2
          else
            i = i + 1
            break
          end
        else
          table.insert(chars, string.char(cb))
          i = i + 1
        end
      end
      fields[field_idx] = table.concat(chars)
      field_idx = field_idx + 1
      -- Skip to next delimiter
      while i <= len and string.byte(line, i) ~= delim_byte do
        i = i + 1
      end
      if i <= len and string.byte(line, i) == delim_byte then
        i = i + 1
        if i > len then
          fields[field_idx] = ""
          field_idx = field_idx + 1
        end
      end
    else
      -- Unquoted field
      local start = i
      while i <= len and string.byte(line, i) ~= delim_byte do
        i = i + 1
      end
      fields[field_idx] = line:sub(start, i - 1)
      field_idx = field_idx + 1
      if i <= len and string.byte(line, i) == delim_byte then
        i = i + 1
        if i > len then
          fields[field_idx] = ""
          field_idx = field_idx + 1
        end
      end
    end
  end

  if len == 0 then
    return { "" }
  end
  return fields
end

--- Encode an array of values into an RFC 4180 CSV line
function M.encode_line(values, delim)
  delim = delim or ","
  local out = {}
  for i = 1, #values do
    local s = tostring(values[i] == nil and "" or values[i])
    if s:find('["\r\n' .. vim.pesc(delim) .. "]") then
      out[i] = '"' .. s:gsub('"', '""') .. '"'
    else
      out[i] = s
    end
  end
  return table.concat(out, delim)
end

--- Infer column data type from sample rows
function M.infer_column_types(headers, rows)
  local types = {}
  local col_widths = {}
  local num_cols = #headers
  local config = require("super-csv.config").options

  for c = 1, num_cols do
    local num_count = 0
    local int_count = 0
    local bool_count = 0
    local date_count = 0
    local arr_count = 0
    local tbl_count = 0
    local non_empty = 0
    local hdr_str = headers[c] or ""
    local parent_part, leaf_part = hdr_str:match("^(.+)%.([^%.]+)$")
    local effective_hdr_len = leaf_part and math.max(#leaf_part + 2, math.min(16, #parent_part + 3)) or #hdr_str
    local max_len = math.max(effective_hdr_len, config.min_col_width or 10)

    for r = 1, math.min(#rows, 100) do
      local val = rows[r].cells and rows[r].cells[c] or rows[r][c] or ""
      if #val > max_len then
        max_len = #val
      end
      if val ~= "" and val ~= "NULL" and val ~= "null" then
        non_empty = non_empty + 1
        local lower = val:lower()
        if val:sub(1, 1) == "[" and val:sub(-1) == "]" then
          arr_count = arr_count + 1
          if val:find("{", 1, true) then
            tbl_count = tbl_count + 1
          end
        elseif lower == "true" or lower == "false" then
          bool_count = bool_count + 1
        elseif val:match("^%d%d%d%d%-%d%d%-%d%d") then
          date_count = date_count + 1
        else
          local cleaned = val:gsub("^%$", ""):gsub(",", "")
          local n = (not cleaned:match("^0[xX]")) and tonumber(cleaned) or nil
          if n ~= nil then
            num_count = num_count + 1
            if not cleaned:find("%.") and not cleaned:lower():find("e") then
              int_count = int_count + 1
            end
          end
        end
      end
    end

    if non_empty == 0 then
      types[c] = "null"
    elseif arr_count >= non_empty * 0.8 then
      types[c] = (tbl_count > 0) and "tbl" or "arr"
      max_len = math.min(max_len, 24)
    elseif bool_count == non_empty then
      types[c] = "bool"
    elseif date_count >= non_empty * 0.8 then
      types[c] = "date"
    elseif num_count >= non_empty * 0.8 then
      types[c] = (int_count == num_count) and "i64" or "f64"
    else
      types[c] = "str"
    end

    local min_hdr_w = (c == 1) and 13 or 11
    col_widths[c] = math.min(math.max(max_len, min_hdr_w, config.min_col_width or 10), config.max_col_width or 28)
  end

  return types, col_widths
end

--- Stage 1: Instant initial batch read via vim.uv (< 10ms even on 1GB files)
function M.read_initial_slice(filepath, max_preview_rows)
  local cfg = require("super-csv.config").options
  max_preview_rows = max_preview_rows or cfg.batch_size or 500
  local fd = uv.fs_open(filepath, "r", 438)
  if not fd then
    return nil, "Failed to open file: " .. tostring(filepath)
  end
  local stat = uv.fs_fstat(fd)
  local file_size = stat and stat.size or 0
  local mtime = stat and stat.mtime and stat.mtime.sec or 0
  -- Read full file if <= 2MB so all top/middle/bottom comments are gathered immediately; 512KB slice for huge files
  local max_slice = (file_size <= 2 * 1024 * 1024) and file_size or 524288
  local read_len = math.min(file_size, max_slice)
  local chunk = read_len > 0 and uv.fs_read(fd, read_len, 0) or ""
  uv.fs_close(fd)

  local delim = M.detect_delimiter(chunk)
  local pos = 1
  local chunk_len = #chunk
  local bytes_consumed = 0
  local file_line_num = 0
  local stream_line_num = 0
  local header_line = nil
  local header_line_num = 1
  local raw_rows = {}
  local comments = {}
  local seen_comment_lines = {}
  local total_data_rows_seen = 0
  local stopped_early = false

  local function handle_line(raw_line, line_end_byte)
    file_line_num = file_line_num + 1
    local clean = raw_line
    if #clean > 0 and clean:sub(#clean, #clean) == "\r" then
      clean = clean:sub(1, #clean - 1)
    end

    if M.is_comment_line(clean) then
      seen_comment_lines[file_line_num] = true
      table.insert(comments, {
        line_num = file_line_num,
        text = clean,
        before_header = (header_line == nil),
        after_rowid = total_data_rows_seen,
      })
      if not stopped_early then
        bytes_consumed = line_end_byte
        stream_line_num = file_line_num
      end
      return true
    elseif clean ~= "" then
      if not header_line then
        header_line = clean
        header_line_num = file_line_num
        bytes_consumed = line_end_byte
        stream_line_num = file_line_num
        return true
      else
        total_data_rows_seen = total_data_rows_seen + 1
        if not stopped_early then
          if #raw_rows < max_preview_rows then
            table.insert(raw_rows, {
              line = clean,
              file_line = file_line_num,
            })
            bytes_consumed = line_end_byte
            stream_line_num = file_line_num
          else
            stopped_early = true
            if read_len < file_size then
              return false -- Huge file: stop scanning now to keep open < 10ms
            end
          end
        end
        return true
      end
    else
      if not stopped_early then
        bytes_consumed = line_end_byte
        stream_line_num = file_line_num
      end
      return true
    end
  end

  while pos <= chunk_len do
    local nl = chunk:find("\n", pos, true)
    if nl then
      local line = chunk:sub(pos, nl - 1)
      pos = nl + 1
      if not handle_line(line, nl) then
        break
      end
    else
      if read_len >= file_size then
        local line = chunk:sub(pos)
        handle_line(line, chunk_len)
      end
      break
    end
  end

  local eof_reached = (not stopped_early) and (bytes_consumed >= file_size)

  local headers = M.parse_line(header_line or "col_1", delim)
  local num_cols = #headers
  for c = 1, num_cols do
    if headers[c] == "" then
      headers[c] = "col_" .. c
    end
  end

  local rows = {}
  for i, item in ipairs(raw_rows) do
    local parsed = M.parse_line(item.line, delim)
    for c = 1, num_cols do
      if parsed[c] == nil then
        parsed[c] = ""
      end
    end
    table.insert(rows, {
      rowid = i,
      file_line = item.file_line,
      cells = parsed,
    })
  end

  local types, col_widths = M.infer_column_types(headers, rows)
  return {
    filepath = filepath,
    file_size = file_size,
    mtime = mtime,
    delim = delim,
    headers = headers,
    header_line_num = header_line_num,
    num_cols = num_cols,
    types = types,
    col_widths = col_widths,
    preview_rows = rows,
    comments = comments,
    seen_comment_lines = seen_comment_lines,
    file_line_num = stream_line_num,
    file_offset = bytes_consumed,
    eof_reached = eof_reached,
    is_complete_in_preview = eof_reached,
  }
end

--- Stream the next batch of rows from disk on demand as the user scrolls
function M.load_next_batch(session, batch_rows)
  if not session or session.eof_reached then
    return 0
  end
  local cfg = require("super-csv.config").options
  batch_rows = batch_rows or cfg.batch_size or 500
  local offset = session.file_offset or 0
  local file_size = session.file_size or 0
  if offset >= file_size then
    session.eof_reached = true
    return 0
  end

  local fd = uv.fs_open(session.filepath, "r", 438)
  if not fd then
    session.eof_reached = true
    return 0
  end

  local added = 0
  local num_cols = session.num_cols
  local delim = session.delim
  local rows = session.preview_rows
  local next_rowid = (#rows > 0 and rows[#rows].rowid or 0) + 1
  local file_line_num = session.file_line_num or 1
  session.comments = session.comments or {}
  session.seen_comment_lines = session.seen_comment_lines or {}

  local function process_stream_line(raw_line)
    file_line_num = file_line_num + 1
    local clean = raw_line
    if #clean > 0 and clean:sub(#clean, #clean) == "\r" then
      clean = clean:sub(1, #clean - 1)
    end
    if clean == "" then
      return
    end
    if M.is_comment_line(clean) then
      if not session.seen_comment_lines[file_line_num] then
        session.seen_comment_lines[file_line_num] = true
        table.insert(session.comments, {
          line_num = file_line_num,
          text = clean,
          before_header = false,
          after_rowid = next_rowid - 1,
        })
      end
      return
    end
    local parsed = M.parse_line(clean, delim)
    for c = 1, num_cols do
      if parsed[c] == nil then
        parsed[c] = ""
      end
    end
    rows[#rows + 1] = {
      rowid = next_rowid,
      file_line = file_line_num,
      cells = parsed,
    }
    next_rowid = next_rowid + 1
    added = added + 1
  end

  while added < batch_rows and offset < file_size do
    local read_len = math.min(file_size - offset, 524288) -- 512KB per read
    local chunk = uv.fs_read(fd, read_len, offset)
    if not chunk or #chunk == 0 then
      offset = file_size
      session.eof_reached = true
      break
    end

    local pos = 1
    local chunk_len = #chunk
    local consumed_in_chunk = 0

    while pos <= chunk_len and added < batch_rows do
      local nl = chunk:find("\n", pos, true)
      if nl then
        local line = chunk:sub(pos, nl - 1)
        consumed_in_chunk = nl
        pos = nl + 1
        process_stream_line(line)
      else
        if offset + chunk_len >= file_size then
          local line = chunk:sub(pos)
          consumed_in_chunk = chunk_len
          process_stream_line(line)
        end
        break
      end
    end

    if consumed_in_chunk == 0 then
      -- Single line longer than 512KB fallback
      consumed_in_chunk = chunk_len
    end
    offset = offset + consumed_in_chunk
    if offset >= file_size then
      session.eof_reached = true
      break
    end
  end

  uv.fs_close(fd)
  session.file_offset = offset
  session.file_line_num = file_line_num
  if not session.sqlite_ready then
    session.total_rows = #rows
    session.filtered_rows = #rows
  end
  return added
end

--- Ensure at least `target_row` rows are loaded in `session.preview_rows` (up to a safety cap per scroll step)
function M.ensure_rows_loaded(session, target_row)
  if not session or session.eof_reached then
    return
  end
  local cfg = require("super-csv.config").options
  local batch_sz = cfg.batch_size or 500
  local needed = target_row - #session.preview_rows
  if needed <= 0 then
    return
  end
  -- Cap synchronous streaming per scroll action to at most 2 batches so fast scrolling never stalls
  local to_load = math.min(math.max(batch_sz, needed + math.floor(batch_sz / 2)), batch_sz * 2)
  M.load_next_batch(session, to_load)
end

return M
