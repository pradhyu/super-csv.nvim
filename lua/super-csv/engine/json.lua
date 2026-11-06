local M = {}

local parser = require("super-csv.engine.parser")

local is_list = vim.islist or vim.tbl_islist

local PRIORITY_ARRAY_KEYS = {
  "data", "items", "rows", "results", "records", "entries",
  "list", "values", "nodes", "hits", "events", "logs",
  "users", "orders", "employees", "metrics", "products",
}

-- Cache decoded subtable cells by raw JSON string
local subtable_cache = {}
local subtable_cache_count = 0

local function normalize_prefixes(prefix_cfg)
  if type(prefix_cfg) == "table" then
    local out = {}
    for _, p in ipairs(prefix_cfg) do
      if type(p) == "string" and p ~= "" then
        table.insert(out, p)
      end
    end
    return out
  elseif type(prefix_cfg) == "string" and prefix_cfg ~= "" then
    return { prefix_cfg }
  end
  return {}
end

--- Strip and extract comments from JSON / JSONC / JSONL text using configured `json_comment_char` (default `//`).
--- Safely ignores comment sequences inside double-quoted JSON strings (e.g. `"https://example.com"`).
function M.strip_and_extract_json_comments(raw_text, comment_prefix)
  local cfg = require("super-csv.config")
  local prefixes = normalize_prefixes(comment_prefix ~= nil and comment_prefix or cfg.get_json_comment_char())
  if #prefixes == 0 then
    return raw_text, {}
  end

  local cleaned_lines = {}
  local extracted = {}
  local seen_data_content = false
  local approx_records_seen = 0
  local line_num = 0

  local pos = 1
  local text_len = #raw_text
  while pos <= text_len do
    local nl = raw_text:find("\n", pos, true)
    local line
    if nl then
      line = raw_text:sub(pos, nl - 1)
      pos = nl + 1
    else
      line = raw_text:sub(pos)
      pos = text_len + 1
    end
    if #line > 0 and line:sub(#line, #line) == "\r" then
      line = line:sub(1, #line - 1)
    end
    line_num = line_num + 1

    local trimmed = vim.trim(line)
    local matched_full = false
    for _, p in ipairs(prefixes) do
      if trimmed:sub(1, #p) == p then
        table.insert(extracted, {
          line_num = line_num,
          text = trimmed,
          before_header = not seen_data_content,
          after_rowid = approx_records_seen,
        })
        cleaned_lines[line_num] = ""
        matched_full = true
        break
      end
    end

    if not matched_full then
      local in_str = false
      local escaped = false
      local comment_start = nil
      local len = #line
      local i = 1
      while i <= len do
        local ch = line:sub(i, i)
        if in_str then
          if escaped then
            escaped = false
          elseif ch == "\\" then
            escaped = true
          elseif ch == '"' then
            in_str = false
          end
          i = i + 1
        else
          if ch == '"' then
            in_str = true
            i = i + 1
          else
            local found_p = nil
            for _, p in ipairs(prefixes) do
              if line:sub(i, i + #p - 1) == p then
                found_p = p
                break
              end
            end
            if found_p then
              comment_start = i
              break
            end
            i = i + 1
          end
        end
      end

      local code_part = comment_start and line:sub(1, comment_start - 1) or line
      if vim.trim(code_part) ~= "" then
        seen_data_content = true
        if code_part:find("}", 1, true) then
          approx_records_seen = approx_records_seen + 1
        end
      end
      if comment_start then
        local ctext = vim.trim(line:sub(comment_start))
        table.insert(extracted, {
          line_num = line_num,
          text = ctext,
          before_header = not seen_data_content,
          after_rowid = approx_records_seen,
        })
      end
      cleaned_lines[line_num] = code_part
    end
  end

  local joined = table.concat(cleaned_lines, "\n")
  joined = joined:gsub(",(%s*[}%]])", "%1")
  return joined, extracted
end

--- Scan raw JSON text to record the order in which keys first appear
local function extract_key_order(raw_text)
  local order = {}
  local rank = 0
  local sample = (raw_text or ""):sub(1, 262144)
  for k in sample:gmatch('"([^"\\]+)"%s*:') do
    if not order[k] then
      rank = rank + 1
      order[k] = rank
    end
  end
  return order
end

--- Compare two flattened column names using source appearance order and keeping nested map siblings grouped
local function make_col_comparator(key_order, seen_order)
  return function(a, b)
    if a == b then
      return false
    end
    if a == "_key" then return true end
    if b == "_key" then return false end

    local a_parts = vim.split(a, ".", { plain = true })
    local b_parts = vim.split(b, ".", { plain = true })
    local min_len = math.min(#a_parts, #b_parts)

    for i = 1, min_len do
      local pa, pb = a_parts[i], b_parts[i]
      if pa ~= pb then
        local na, nb = tonumber(pa), tonumber(pb)
        if na and nb then
          return na < nb
        end
        local ra = key_order[pa] or (1000000 + (seen_order[a] or 999999))
        local rb = key_order[pb] or (1000000 + (seen_order[b] or 999999))
        if ra ~= rb then
          return ra < rb
        end
        return pa < pb
      end
    end

    if #a_parts ~= #b_parts then
      return #a_parts < #b_parts
    end
    local sa = seen_order[a] or 999999
    local sb = seen_order[b] or 999999
    if sa ~= sb then
      return sa < sb
    end
    return a < b
  end
end

--- Encode a Lua value as JSON while preserving `key_order` for object keys inside arrays/maps
local function encode_json_ordered(val, key_order)
  if val == vim.NIL or val == nil then
    return "null"
  elseif type(val) == "boolean" or type(val) == "number" then
    return tostring(val)
  elseif type(val) == "string" then
    local ok, s = pcall(vim.fn.json_encode, val)
    return ok and s or ('"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"')
  elseif type(val) == "table" then
    if next(val) == nil then
      return "[]"
    elseif is_list(val) then
      local items = {}
      for i = 1, #val do
        items[i] = encode_json_ordered(val[i], key_order)
      end
      return "[" .. table.concat(items, ",") .. "]"
    else
      local keys = {}
      for k in pairs(val) do
        table.insert(keys, k)
      end
      table.sort(keys, function(a, b)
        local ra = key_order and key_order[tostring(a)] or 999999
        local rb = key_order and key_order[tostring(b)] or 999999
        if ra ~= rb then
          return ra < rb
        end
        return tostring(a) < tostring(b)
      end)
      local pairs_out = {}
      for _, k in ipairs(keys) do
        local ks = encode_json_ordered(tostring(k), key_order)
        local vs = encode_json_ordered(val[k], key_order)
        table.insert(pairs_out, ks .. ":" .. vs)
      end
      return "{" .. table.concat(pairs_out, ",") .. "}"
    end
  end
  return "null"
end

--- Flatten a JSON object:
--- - Maps / Nested Maps (`{ k: v }`) expand horizontally into `parentkey.mapkey` columns (at any depth).
--- - Arrays / Lists (`[ ... ]`, including Lists of Maps or Maps of Lists) become a single Subtable column!
local function flatten_object(obj, prefix, out, seen_cols, seen_order, counter_ref, key_order)
  local keys = {}
  for k in pairs(obj) do
    table.insert(keys, k)
  end
  table.sort(keys, function(a, b)
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then
      return na < nb
    end
    local ra = key_order and key_order[tostring(a)] or 999999
    local rb = key_order and key_order[tostring(b)] or 999999
    if ra ~= rb then
      return ra < rb
    end
    return tostring(a) < tostring(b)
  end)

  for _, k in ipairs(keys) do
    local v = obj[k]
    local full_key = prefix ~= "" and (prefix .. "." .. tostring(k)) or tostring(k)
    if v == vim.NIL or v == nil then
      if not seen_cols[full_key] then
        counter_ref[1] = counter_ref[1] + 1
        seen_cols[full_key] = true
        seen_order[full_key] = counter_ref[1]
      end
      out[full_key] = ""
    elseif type(v) == "table" then
      if next(v) == nil then
        if not seen_cols[full_key] then
          counter_ref[1] = counter_ref[1] + 1
          seen_cols[full_key] = true
          seen_order[full_key] = counter_ref[1]
        end
        out[full_key] = ""
      elseif is_list(v) then
        -- Array / List -> Subtable column (e.g. `tags`, `deployments`, or `clusters.prod` for Map of Lists!)
        if not seen_cols[full_key] then
          counter_ref[1] = counter_ref[1] + 1
          seen_cols[full_key] = true
          seen_order[full_key] = counter_ref[1]
        end
        out[full_key] = encode_json_ordered(v, key_order)
      else
        -- Map / Nested Map -> `parentkey.mapkey` columns
        flatten_object(v, full_key, out, seen_cols, seen_order, counter_ref, key_order)
      end
    else
      if not seen_cols[full_key] then
        counter_ref[1] = counter_ref[1] + 1
        seen_cols[full_key] = true
        seen_order[full_key] = counter_ref[1]
      end
      out[full_key] = tostring(v)
    end
  end
end

--- Parse a cell's raw JSON array value into a structured Subtable `{ kind = "tbl"|"arr", headers = {...}, rows = {...} }`
function M.parse_subtable_cell(raw_val)
  if type(raw_val) ~= "string" or raw_val == "" then
    return nil
  end
  local trimmed = vim.trim(raw_val)
  if trimmed:sub(1, 1) ~= "[" or trimmed:sub(-1) ~= "]" then
    return nil
  end
  local cached = subtable_cache[trimmed]
  if cached ~= nil then
    return cached or nil
  end

  local ok, arr = pcall(vim.json.decode, trimmed)
  if not ok or type(arr) ~= "table" or not is_list(arr) then
    subtable_cache[trimmed] = false
    return nil
  end

  if subtable_cache_count > 2000 then
    subtable_cache = {}
    subtable_cache_count = 0
  end
  subtable_cache_count = subtable_cache_count + 1

  if #arr == 0 then
    local empty_res = {
      kind = "arr",
      headers = { "value" },
      rows = {},
      num_rows = 0,
      num_cols = 1,
      raw_json = trimmed,
    }
    subtable_cache[trimmed] = empty_res
    return empty_res
  end

  local has_map = false
  for i = 1, #arr do
    if type(arr[i]) == "table" and not is_list(arr[i]) then
      has_map = true
      break
    end
  end

  local parsed = M.parse_json_text(trimmed, { comment_char = "" })
  if not parsed then
    subtable_cache[trimmed] = false
    return nil
  end

  local res = {
    kind = has_map and "tbl" or "arr",
    headers = parsed.headers,
    rows = parsed.rows,
    num_rows = #parsed.rows,
    num_cols = #parsed.headers,
    raw_json = trimmed,
  }
  subtable_cache[trimmed] = res
  return res
end

--- Format a Subtable cell value as a compact badge + preview for the parent grid cell
function M.format_subtable_preview(raw_val)
  local st = M.parse_subtable_cell(raw_val)
  if not st then
    return raw_val
  end
  if st.num_rows == 0 then
    return "⊞ [0]"
  end
  if st.kind == "arr" and st.num_cols == 1 then
    local items = {}
    for i = 1, math.min(st.num_rows, 4) do
      table.insert(items, tostring(st.rows[i][1] or ""))
    end
    local suffix = (st.num_rows > 4) and ", …" or ""
    return string.format("⊞ [%d] %s%s", st.num_rows, table.concat(items, ", "), suffix)
  else
    -- List of Maps (`[tbl]`): show `⊞ [R×C] first_row_summary`
    local first_row = st.rows[1] or {}
    local preview_parts = {}
    for c = 1, math.min(st.num_cols, 3) do
      local v = tostring(first_row[c] or "")
      if v:sub(1, 1) == "[" then
        v = "[…]"
      end
      if v ~= "" then
        table.insert(preview_parts, string.format("%s=%s", st.headers[c], v))
      end
    end
    return string.format("⊞ [%d×%d] %s", st.num_rows, st.num_cols, table.concat(preview_parts, ", "))
  end
end

--- Recursively unwrap outer wrapper objects to find the primary record array or map of objects
local function extract_records_from_table(tbl, key_order, meta_acc, path_prefix)
  path_prefix = path_prefix or ""

  -- 1. Check priority array keys at this level
  for _, pk in ipairs(PRIORITY_ARRAY_KEYS) do
    local v = tbl[pk]
    if type(v) == "table" and is_list(v) and #v > 0 then
      for k, sv in pairs(tbl) do
        if k ~= pk and type(sv) ~= "table" and sv ~= vim.NIL then
          local mk = path_prefix ~= "" and (path_prefix .. "." .. tostring(k)) or tostring(k)
          table.insert(meta_acc, string.format("%s=%s", mk, tostring(sv)))
        end
      end
      local full_p = path_prefix ~= "" and (path_prefix .. "." .. pk) or pk
      return v, full_p
    end
  end

  -- 2. Check if this table is a single record vs a pure wrapper around 1 array
  local total_entries = 0
  local obj_entries = 0
  local list_entries = 0
  local scalar_entries = 0
  local single_table_key = nil
  local single_list_key = nil

  for k, v in pairs(tbl) do
    total_entries = total_entries + 1
    if type(v) == "table" and is_list(v) then
      list_entries = list_entries + 1
      single_list_key = k
    elseif type(v) == "table" and next(v) ~= nil then
      obj_entries = obj_entries + 1
      single_table_key = k
    else
      scalar_entries = scalar_entries + 1
    end
  end

  -- Only unwrap a non-priority array if the object looks like a pure envelope (1 list + at most 3 scalar meta fields, 0 nested maps)
  if list_entries == 1 and obj_entries == 0 and scalar_entries <= 3 then
    local arr = tbl[single_list_key]
    if #arr > 0 and type(arr[1]) == "table" then
      for k, sv in pairs(tbl) do
        if k ~= single_list_key and type(sv) ~= "table" and sv ~= vim.NIL then
          local mk = path_prefix ~= "" and (path_prefix .. "." .. tostring(k)) or tostring(k)
          table.insert(meta_acc, string.format("%s=%s", mk, tostring(sv)))
        end
      end
      local full_p = path_prefix ~= "" and (path_prefix .. "." .. tostring(single_list_key)) or tostring(single_list_key)
      return arr, full_p
    end
  end

  -- If there is only 1 nested object key and 0 lists/scalars (pure nested envelope), unwrap into it
  if obj_entries == 1 and list_entries == 0 and scalar_entries <= 2 and single_table_key ~= nil then
    local sub_tbl = tbl[single_table_key]
    local sub_tables = 0
    for _, sv in pairs(sub_tbl) do
      if type(sv) == "table" then
        sub_tables = sub_tables + 1
      end
    end
    if sub_tables >= 1 then
      for k, sv in pairs(tbl) do
        if k ~= single_table_key and type(sv) ~= "table" and sv ~= vim.NIL then
          local mk = path_prefix ~= "" and (path_prefix .. "." .. tostring(k)) or tostring(k)
          table.insert(meta_acc, string.format("%s=%s", mk, tostring(sv)))
        end
      end
      local next_prefix = path_prefix ~= "" and (path_prefix .. "." .. tostring(single_table_key)) or tostring(single_table_key)
      return extract_records_from_table(sub_tbl, key_order, meta_acc, next_prefix)
    end
  end

  return { tbl }, path_prefix
end

--- Parse JSON, JSONC, or JSONL/NDJSON text into `{ headers = {...}, rows = {...}, comments = {...}, comment_items = {...} }`
function M.parse_json_text(raw_text, opts)
  opts = opts or {}
  if not raw_text or vim.trim(raw_text) == "" then
    return nil, "Empty JSON input"
  end

  local cfg = require("super-csv.config")
  local json_cchar = opts.comment_char ~= nil and opts.comment_char or cfg.get_json_comment_char()
  local stripped_text, comment_items = M.strip_and_extract_json_comments(raw_text, json_cchar)
  local comments = {}
  for _, item in ipairs(comment_items) do
    table.insert(comments, item.text)
  end

  local key_order = extract_key_order(stripped_text)
  local decoded = nil
  local ok_dec, res = pcall(vim.json.decode, stripped_text)
  if ok_dec and res ~= nil and res ~= vim.NIL then
    decoded = res
  else
    local jsonl_records = {}
    local line_num = 0
    for line in stripped_text:gmatch("[^\r\n]+") do
      line_num = line_num + 1
      local trimmed = vim.trim(line)
      if trimmed ~= "" then
        local ok_l, obj = pcall(vim.json.decode, trimmed)
        if ok_l and obj ~= nil and obj ~= vim.NIL then
          table.insert(jsonl_records, obj)
        else
          return nil, string.format("Invalid JSON / JSONL at line %d: %s", line_num, trimmed:sub(1, 60))
        end
      end
    end
    if #jsonl_records == 0 then
      return nil, "Failed to parse JSON or JSONL content"
    end
    decoded = jsonl_records
  end

  local record_list = nil

  if type(decoded) == "table" and is_list(decoded) then
    if #decoded == 0 then
      return { headers = { "value" }, rows = {}, comments = comments, comment_items = comment_items }
    end
    if type(decoded[1]) == "table" and is_list(decoded[1]) then
      local first_row = decoded[1]
      local num_cols = #first_row
      local first_is_header = (#decoded > 1)
      for i = 1, num_cols do
        if type(first_row[i]) ~= "string" or tonumber(first_row[i]) ~= nil then
          first_is_header = false
          break
        end
      end
      local headers = {}
      local start_idx = 1
      if first_is_header then
        for c = 1, num_cols do
          headers[c] = (first_row[c] ~= "" and tostring(first_row[c])) or ("col_" .. c)
        end
        start_idx = 2
      else
        for c = 1, math.max(1, num_cols) do
          headers[c] = "col_" .. c
        end
      end
      local rows = {}
      for r = start_idx, #decoded do
        local arr = decoded[r]
        if type(arr) == "table" then
          local cells = {}
          for c = 1, #headers do
            local v = arr[c]
            if v == vim.NIL or v == nil then
              cells[c] = ""
            elseif type(v) == "table" then
              local ok_e, enc = pcall(vim.fn.json_encode, v)
              cells[c] = ok_e and enc or tostring(v)
            else
              cells[c] = tostring(v)
            end
          end
          table.insert(rows, cells)
        end
      end
      return { headers = headers, rows = rows, comments = comments, comment_items = comment_items }
    end

    record_list = decoded
  elseif type(decoded) == "table" then
    local meta_parts = {}
    local chosen_path
    record_list, chosen_path = extract_records_from_table(decoded, key_order, meta_parts, "")
    table.sort(meta_parts)
    if #meta_parts > 0 then
      local pfx = type(json_cchar) == "table" and (json_cchar[1] or "//") or tostring(json_cchar or "//")
      if pfx == "" then pfx = "#" end
      local label = (chosen_path and chosen_path ~= "") and chosen_path or "root"
      local meta_text = string.format("%s [JSON Metadata (%s)] %s", pfx, label, table.concat(meta_parts, " | "))
      table.insert(comments, 1, meta_text)
      table.insert(comment_items, 1, {
        line_num = 1,
        text = meta_text,
        before_header = true,
        after_rowid = 0,
      })
    end
  else
    return {
      headers = { "value" },
      rows = { { tostring(decoded) } },
      comments = comments,
      comment_items = comment_items,
    }
  end

  local seen_cols = {}
  local seen_order = {}
  local counter_ref = { 0 }
  local flat_records = {}

  for i, rec in ipairs(record_list) do
    local flat = {}
    if type(rec) == "table" and not is_list(rec) then
      flatten_object(rec, "", flat, seen_cols, seen_order, counter_ref, key_order)
    elseif type(rec) == "table" and is_list(rec) then
      local ok_e, enc = pcall(vim.fn.json_encode, rec)
      if not seen_cols["value"] then
        counter_ref[1] = counter_ref[1] + 1
        seen_cols["value"] = true
        seen_order["value"] = counter_ref[1]
      end
      flat["value"] = ok_e and enc or tostring(rec)
    else
      if not seen_cols["value"] then
        counter_ref[1] = counter_ref[1] + 1
        seen_cols["value"] = true
        seen_order["value"] = counter_ref[1]
      end
      flat["value"] = (rec == vim.NIL or rec == nil) and "" or tostring(rec)
    end
    flat_records[i] = flat
  end

  local headers = {}
  for col_name in pairs(seen_cols) do
    table.insert(headers, col_name)
  end
  table.sort(headers, make_col_comparator(key_order, seen_order))

  if #headers == 0 then
    headers = { "value" }
  end

  local rows = {}
  local num_cols = #headers
  for i, flat in ipairs(flat_records) do
    local row = {}
    for c = 1, num_cols do
      row[c] = flat[headers[c]] or ""
    end
    rows[i] = row
  end

  return {
    headers = headers,
    rows = rows,
    comments = comments,
    comment_items = comment_items,
  }
end

--- Convert a JSON comment string (e.g. `// foo`) into a CSV comment line using configured `comment_char` (default `#`)
local function to_csv_comment_line(text)
  local cfg = require("super-csv.config")
  local csv_cchar = cfg.get_csv_comment_char()
  if type(csv_cchar) == "table" then
    csv_cchar = csv_cchar[1] or "#"
  end
  csv_cchar = tostring(csv_cchar or "#")
  if csv_cchar == "" then
    csv_cchar = "#"
  end

  local json_prefixes = normalize_prefixes(cfg.get_json_comment_char())
  local trimmed = vim.trim(text or "")
  if trimmed:sub(1, #csv_cchar) == csv_cchar then
    return trimmed
  end
  for _, jp in ipairs(json_prefixes) do
    if trimmed:sub(1, #jp) == jp then
      local body = vim.trim(trimmed:sub(#jp + 1))
      return csv_cchar .. (body ~= "" and (" " .. body) or "")
    end
  end
  return csv_cchar .. " " .. trimmed
end

--- Write parsed `{ headers, rows, comments }` to a target CSV file atomically
function M.write_csv_file(parsed, output_csv_path, delim)
  delim = delim or ","
  local tmp_path = output_csv_path .. ".supercsv.tmp"
  local f, err = io.open(tmp_path, "wb")
  if not f then
    return false, "Failed to open output CSV for writing: " .. tostring(err)
  end

  for _, cm in ipairs(parsed.comments or {}) do
    f:write(to_csv_comment_line(cm) .. "\n")
  end

  f:write(parser.encode_line(parsed.headers, delim) .. "\n")

  local chunk = {}
  local count = 0
  for _, r in ipairs(parsed.rows or {}) do
    count = count + 1
    chunk[count] = parser.encode_line(r, delim)
    if count >= 2000 then
      f:write(table.concat(chunk, "\n") .. "\n")
      chunk = {}
      count = 0
    end
  end
  if count > 0 then
    f:write(table.concat(chunk, "\n") .. "\n")
  end

  f:close()
  local ok_ren, ren_err = os.rename(tmp_path, output_csv_path)
  if not ok_ren then
    os.remove(tmp_path)
    return false, "Failed to finalize CSV file: " .. tostring(ren_err)
  end
  return true, output_csv_path
end

--- Convert a JSON/JSONC/JSONL file on disk (or raw JSON string) to a CSV file on disk
function M.convert_json_to_csv(input_source, output_csv_path, opts)
  opts = opts or {}
  local raw_text
  local source_label = "buffer"

  if opts.is_raw_text then
    raw_text = input_source
  else
    local path = vim.fn.fnamemodify(input_source, ":p")
    source_label = path
    local f, err = io.open(path, "rb")
    if not f then
      return false, "Cannot read JSON file: " .. tostring(err)
    end
    raw_text = f:read("*a")
    f:close()
  end

  local parsed, parse_err = M.parse_json_text(raw_text, opts)
  if not parsed then
    return false, parse_err
  end

  if not output_csv_path or output_csv_path == "" then
    if not opts.is_raw_text then
      output_csv_path = input_source:gsub("%.ndjson$", ""):gsub("%.jsonl$", ""):gsub("%.jsonc$", ""):gsub("%.json$", "") .. ".csv"
    else
      local cfg = require("super-csv.config").options
      output_csv_path = string.format("%s/converted_%s.csv", cfg.cache_dir, vim.fn.sha256(raw_text):sub(1, 12))
    end
  else
    output_csv_path = vim.fn.fnamemodify(output_csv_path, ":p")
  end

  local ok, write_err = M.write_csv_file(parsed, output_csv_path, opts.delim or ",")
  if not ok then
    return false, write_err
  end

  return true, output_csv_path, {
    source = source_label,
    num_rows = #parsed.rows,
    num_cols = #parsed.headers,
    headers = parsed.headers,
    comments = parsed.comments,
    comment_items = parsed.comment_items,
  }
end

--- Export a SuperCsv session's rows (filtered or full) to a JSON or JSONL file
function M.export_session_to_json(session, target_path, only_filtered)
  local sqlite = require("super-csv.engine.sqlite")
  local is_jsonl = target_path:match("%.jsonl$") or target_path:match("%.ndjson$")
  local headers = session.headers or {}
  local types = session.types or {}
  local num_cols = session.num_cols or #headers

  local raw_rows = {}
  if session.sqlite_ready and session.db then
    local where_sql = only_filtered and sqlite.build_where_clause(session) or ""
    local order_sql = only_filtered and sqlite.build_order_clause(session) or "ORDER BY rowid ASC"
    local cols = {}
    for c = 1, num_cols do
      cols[c] = "c" .. c
    end
    local sql = string.format("SELECT %s FROM csv_data %s %s;", table.concat(cols, ","), where_sql, order_sql)
    local q_rows = sqlite.query(session.db, sql) or {}
    raw_rows = q_rows
  else
    for _, r in ipairs(session.preview_rows or {}) do
      table.insert(raw_rows, r.cells)
    end
  end

  local function coerce_val(val, ctype)
    if val == nil or val == "" then
      return vim.NIL
    end
    if ctype == "tbl" or ctype == "arr" then
      local ok, decoded = pcall(vim.json.decode, val)
      if ok then return decoded end
    elseif ctype == "bool" then
      local low = val:lower()
      if low == "true" then return true end
      if low == "false" then return false end
    elseif ctype == "i64" or ctype == "f64" then
      local n = tonumber((val:gsub("^%$", ""):gsub(",", "")))
      if n ~= nil then return n end
    end
    return val
  end

  local f, err = io.open(target_path, "wb")
  if not f then
    return false, "Cannot open JSON file for writing: " .. tostring(err)
  end

  if is_jsonl then
    for _, cells in ipairs(raw_rows) do
      local obj = {}
      for c = 1, num_cols do
        obj[headers[c]] = coerce_val(cells[c], types[c])
      end
      f:write(vim.fn.json_encode(obj) .. "\n")
    end
  else
    f:write("[\n")
    for idx, cells in ipairs(raw_rows) do
      local obj = {}
      for c = 1, num_cols do
        obj[headers[c]] = coerce_val(cells[c], types[c])
      end
      local comma = (idx < #raw_rows) and "," or ""
      f:write("  " .. vim.fn.json_encode(obj) .. comma .. "\n")
    end
    f:write("]\n")
  end

  f:close()
  return true, target_path
end

--- Check if a file path or buffer looks like JSON / JSONC / JSONL / NDJSON
function M.is_json_path(path)
  if not path or path == "" then
    return false
  end
  local low = path:lower()
  return low:match("%.json$") ~= nil
    or low:match("%.jsonc$") ~= nil
    or low:match("%.jsonl$") ~= nil
    or low:match("%.ndjson$") ~= nil
end

return M
