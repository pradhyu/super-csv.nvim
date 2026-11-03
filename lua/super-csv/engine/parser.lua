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

--- Detect delimiter (',', '\t', '|', ';') from sample text
function M.detect_delimiter(sample)
  local first_line = sample:match("^([^\r\n]+)") or sample
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
    local non_empty = 0
    local max_len = math.max(#headers[c] + 4, config.min_col_width)

    for r = 1, math.min(#rows, 100) do
      local val = rows[r].cells and rows[r].cells[c] or rows[r][c] or ""
      if #val > max_len then
        max_len = #val
      end
      if val ~= "" and val ~= "NULL" and val ~= "null" then
        non_empty = non_empty + 1
        local lower = val:lower()
        if lower == "true" or lower == "false" then
          bool_count = bool_count + 1
        elseif val:match("^%d%d%d%d%-%d%d%-%d%d") then
          date_count = date_count + 1
        else
          local cleaned = val:gsub("^%$", ""):gsub(",", "")
          local n = tonumber(cleaned)
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
    elseif bool_count == non_empty then
      types[c] = "bool"
    elseif date_count >= non_empty * 0.8 then
      types[c] = "date"
    elseif num_count >= non_empty * 0.8 then
      types[c] = (int_count == num_count) and "i64" or "f64"
    else
      types[c] = "str"
    end

    col_widths[c] = math.min(math.max(max_len + 2, config.min_col_width), config.max_col_width)
  end

  return types, col_widths
end

--- Stage 1: Instant 128KB preview slice read via vim.uv (< 10ms even on 1GB files)
function M.read_initial_slice(filepath, max_preview_rows)
  max_preview_rows = max_preview_rows or 200
  local fd = uv.fs_open(filepath, "r", 438)
  if not fd then
    return nil, "Failed to open file: " .. tostring(filepath)
  end
  local stat = uv.fs_fstat(fd)
  local file_size = stat and stat.size or 0
  local mtime = stat and stat.mtime and stat.mtime.sec or 0
  local read_len = math.min(file_size, 262144) -- 256KB initial slice
  local chunk = read_len > 0 and uv.fs_read(fd, read_len, 0) or ""
  uv.fs_close(fd)

  local delim = M.detect_delimiter(chunk)
  local lines = {}
  for line in chunk:gmatch("([^\n]*)\n?") do
    if line ~= "" or #lines == 0 then
      table.insert(lines, line)
      if #lines > max_preview_rows + 1 then
        break
      end
    end
  end
  -- If file was not completely read, drop potentially truncated last line
  if file_size > read_len and #lines > 2 then
    table.remove(lines)
  end

  local headers = M.parse_line(lines[1] or "col_1", delim)
  local num_cols = #headers
  for c = 1, num_cols do
    if headers[c] == "" then
      headers[c] = "col_" .. c
    end
  end

  local rows = {}
  for i = 2, #lines do
    if lines[i] ~= "" then
      local parsed = M.parse_line(lines[i], delim)
      for c = 1, num_cols do
        if parsed[c] == nil then
          parsed[c] = ""
        end
      end
      table.insert(rows, {
        rowid = i - 1,
        cells = parsed,
      })
    end
  end

  local types, col_widths = M.infer_column_types(headers, rows)
  return {
    filepath = filepath,
    file_size = file_size,
    mtime = mtime,
    delim = delim,
    headers = headers,
    num_cols = num_cols,
    types = types,
    col_widths = col_widths,
    preview_rows = rows,
    is_complete_in_preview = (file_size <= read_len and #rows < max_preview_rows),
  }
end

return M
