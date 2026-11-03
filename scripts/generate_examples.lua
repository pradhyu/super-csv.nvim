#!/usr/bin/env luajit
-- Deterministic generator for super-csv.nvim example datasets
-- Usage:
--   luajit scripts/generate_examples.lua            # Generates standard examples in examples/
--   luajit scripts/generate_examples.lua --million  # Also generates examples/million_100cols.csv (1,000,000 rows x 100 cols)

local root = debug.getinfo(1, "S").source:sub(2):match("^(.*)/scripts/generate_examples%.lua$") or "."
local examples_dir = root .. "/examples"
os.execute("mkdir -p " .. examples_dir)

math.randomseed(424242)

local function pick(list)
  return list[math.random(1, #list)]
end

local function csv_quote(val)
  local s = tostring(val == nil and "" or val)
  if s:find('[,"\r\n]') then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

local function write_csv(filepath, headers, rows_iter, total_rows)
  local f = assert(io.open(filepath, "wb"))
  f:write(table.concat(headers, ",") .. "\n")
  local buf = {}
  local buf_count = 0
  for r = 1, total_rows do
    local row = rows_iter(r)
    buf_count = buf_count + 1
    buf[buf_count] = row
    if buf_count >= 2000 then
      f:write(table.concat(buf, "\n") .. "\n")
      buf = {}
      buf_count = 0
    end
  end
  if buf_count > 0 then
    f:write(table.concat(buf, "\n") .. "\n")
  end
  f:close()
  print(string.format("[OK] Wrote %s (%d rows x %d cols)", filepath, total_rows, #headers))
end

-- 1. examples/employees_saas.csv (120 rows x 16 cols)
do
  local headers = {
    "emp_id", "full_name", "email", "department", "team", "role", "level",
    "location", "country", "salary_usd", "bonus_pct", "equity_shares",
    "is_remote", "hire_date", "perf_rating", "status"
  }
  local first_names = { "Aria", "Liam", "Noah", "Maya", "Zoe", "Ethan", "Chloe", "Lucas", "Elena", "Mateo", "Priya", "Kenji", "Sofia", "Omar", "Hannah", "Devon" }
  local last_names = { "Patel", "Chen", "Smith", "Garcia", "Kim", "Nguyen", "Kowalski", "Silva", "Okafor", "Jensen", "Rossi", "Muller", "Sato", "Berg", "hassan", "Vance" }
  local depts = {
    { dept = "Engineering", teams = { "Core DB", "Platform", "Frontend", "AI Systems", "Security" }, roles = { "Staff Engineer", "Senior SWE", "SWE II", "Principal Architect" } },
    { dept = "Product", teams = { "Growth", "Enterprise", "Developer Experience" }, roles = { "Senior PM", "Group PM", "Product Designer", "UX Researcher" } },
    { dept = "Sales", teams = { "Enterprise NA", "EMEA Mid-Market", "APAC Commercial" }, roles = { "Account Executive", "Solutions Architect", "Sales Director" } },
    { dept = "Data Science", teams = { "Analytics", "ML Ops", "Forecasting" }, roles = { "Data Scientist", "Analytics Engineer", "ML Engineer" } },
    { dept = "Operations", teams = { "Finance", "People Ops", "Legal" }, roles = { "FP&A Lead", "Recruiter", "Legal Counsel" } },
  }
  local locs = {
    { city = "San Francisco", country = "US" },
    { city = "New York", country = "US" },
    { city = "Austin", country = "US" },
    { city = "Seattle", country = "US" },
    { city = "London", country = "UK" },
    { city = "Berlin", country = "DE" },
    { city = "Toronto", country = "CA" },
    { city = "Tokyo", country = "JP" },
    { city = "Singapore", country = "SG" },
  }
  local levels = { "L3", "L4", "L5", "L6", "L7", "L8" }
  local ratings = { "Exceeds", "Strongly Exceeds", "Meets", "Meets", "Exceeds", "Needs Improvement", "New Hire" }
  local statuses = { "ACTIVE", "ACTIVE", "ACTIVE", "ACTIVE", "ON_LEAVE", "CONTRACTOR" }

  write_csv(examples_dir .. "/employees_saas.csv", headers, function(r)
    local fn = pick(first_names)
    local ln = pick(last_names)
    local d = pick(depts)
    local loc = pick(locs)
    local lvl_idx = math.random(1, #levels)
    local base_sal = 85000 + (lvl_idx * 28000) + math.random(-6000, 14000)
    local bonus = (lvl_idx >= 4) and (15 + (lvl_idx - 3) * 5) or 10
    local equity = lvl_idx * 2500 + math.random(0, 2000)
    local remote = (math.random() > 0.4) and "true" or "false"
    local year = math.random(2019, 2026)
    local month = math.random(1, 12)
    local day = math.random(1, 28)
    return table.concat({
      string.format("EMP-%04d", 1000 + r),
      csv_quote(fn .. " " .. ln),
      string.format("%s.%s.%d@acme-cloud.io", fn:lower(), ln:lower(), r),
      d.dept,
      pick(d.teams),
      pick(d.roles),
      levels[lvl_idx],
      csv_quote(loc.city),
      loc.country,
      tostring(base_sal),
      tostring(bonus),
      tostring(equity),
      remote,
      string.format("%04d-%02d-%02d", year, month, day),
      pick(ratings),
      pick(statuses),
    }, ",")
  end, 120)
end

-- 2. examples/ecommerce_orders.csv (500 rows x 24 cols)
do
  local headers = {
    "order_id", "order_date", "customer_id", "customer_tier", "country", "region",
    "warehouse_code", "category", "sku", "product_name", "quantity", "unit_price",
    "subtotal", "discount_pct", "discount_usd", "tax_usd", "shipping_usd", "total_amount",
    "currency", "payment_method", "order_status", "fulfillment_sla", "carrier", "notes"
  }
  local regions = {
    { country = "US", region = "US-EAST", wh = "WH-IAD-01" },
    { country = "US", region = "US-WEST", wh = "WH-SJC-02" },
    { country = "US", region = "US-CENTRAL", wh = "WH-DFW-01" },
    { country = "DE", region = "EU-CENTRAL", wh = "WH-FRA-01" },
    { country = "UK", region = "EU-WEST", wh = "WH-LHR-01" },
    { country = "JP", region = "APAC-EAST", wh = "WH-NRT-01" },
    { country = "AU", region = "APAC-SOUTH", wh = "WH-SYD-01" },
  }
  local products = {
    { cat = "Hardware", sku = "HW-NVME-4TB", name = "Pro NVMe Gen5 SSD 4TB", price = 349.99 },
    { cat = "Hardware", sku = "HW-KBD-MECH", name = "Split Ergonomic Mechanical Keyboard", price = 219.50 },
    { cat = "Monitors", sku = "MON-OLED-32", name = '32" 4K 240Hz OLED Developer Display', price = 999.00 },
    { cat = "Monitors", sku = "MON-ULT-40", name = '40" 5K2K Ultrawide Thunderbolt Hub', price = 1299.00 },
    { cat = "Networking", sku = "NET-SW-10G", name = "8-Port 10GbE Managed Switch, Fanless", price = 279.00 },
    { cat = "Networking", sku = "NET-AP-WIFI7", name = "Tri-Band Wi-Fi 7 PoE+ Access Point", price = 189.00 },
    { cat = "Audio", sku = "AUD-ANC-PRO", name = "Studio Wireless ANC Headphones", price = 329.00 },
    { cat = "Accessories", sku = "ACC-DOCK-TB5", name = "Thunderbolt 5 180W Workstation Dock", price = 310.00 },
  }
  local tiers = { "ENTERPRISE", "PRO", "STANDARD", "STANDARD", "PRO", "VIP" }
  local payments = { "STRIPE_CARD", "WIRE_ACH", "APPLE_PAY", "PAYPAL", "CORP_INVOICE" }
  local statuses = { "COMPLETED", "COMPLETED", "COMPLETED", "SHIPPED", "PENDING", "REFUNDED", "CANCELLED" }
  local carriers = { "FEDEX_PRI", "UPS_AIR", "DHL_EXPRESS", "USPS_GROUND" }
  local notes_pool = {
    "",
    "Leave at loading dock B, gate code #4491",
    "Priority enterprise hardware refresh",
    'Customer requested "signature required" on delivery',
    "Bundle discount applied; Net-30 terms",
    "",
  }

  write_csv(examples_dir .. "/ecommerce_orders.csv", headers, function(r)
    local reg = pick(regions)
    local prod = pick(products)
    local qty = math.random(1, 15)
    local sub = qty * prod.price
    local disc_pct = pick({ 0, 0, 5, 10, 15, 20 })
    local disc_usd = sub * (disc_pct / 100.0)
    local tax = (sub - disc_usd) * 0.0825
    local ship = (sub > 1000) and 0.00 or 24.99
    local total = (sub - disc_usd) + tax + ship
    return table.concat({
      string.format("ORD-%06d", 740000 + r),
      string.format("2026-%02d-%02d", math.random(1, 10), math.random(1, 28)),
      string.format("CUST-%05d", math.random(10000, 99999)),
      pick(tiers),
      reg.country,
      reg.region,
      reg.wh,
      prod.cat,
      prod.sku,
      csv_quote(prod.name),
      tostring(qty),
      string.format("%.2f", prod.price),
      string.format("%.2f", sub),
      tostring(disc_pct),
      string.format("%.2f", disc_usd),
      string.format("%.2f", tax),
      string.format("%.2f", ship),
      string.format("%.2f", total),
      "USD",
      pick(payments),
      pick(statuses),
      (total > 2000) and "SAME_DAY" or "STANDARD_2DAY",
      pick(carriers),
      csv_quote(pick(notes_pool)),
    }, ",")
  end, 500)
end

-- 3. examples/server_access_logs.csv (1,000 rows x 18 cols)
do
  local headers = {
    "row_id", "timestamp", "trace_id", "service", "env", "region", "pod_name",
    "http_method", "endpoint", "http_status", "latency_ms", "db_query_ms",
    "cache_hit", "bytes_sent", "client_ip", "user_id", "error_code", "error_message"
  }
  local endpoints = {
    { m = "GET", ep = "/api/v2/orders", svc = "order-service" },
    { m = "POST", ep = "/api/v2/checkout/charge", svc = "payment-gateway" },
    { m = "GET", ep = "/api/v2/users/profile", svc = "auth-service" },
    { m = "PUT", ep = "/api/v2/inventory/reserve", svc = "inventory-worker" },
    { m = "POST", ep = "/api/v2/search/query", svc = "search-indexer" },
    { m = "DELETE", ep = "/api/v2/sessions/revoke", svc = "auth-service" },
  }
  local regions = { "us-east-1", "us-west-2", "eu-central-1", "ap-northeast-1" }
  local status_profiles = {
    { code = 200, err = "", msg = "", weight = 75 },
    { code = 201, err = "", msg = "", weight = 10 },
    { code = 400, err = "ERR_INVALID_PAYLOAD", msg = "Missing required field: payment_token", weight = 4 },
    { code = 401, err = "ERR_JWT_EXPIRED", msg = "Bearer token expired at epoch", weight = 3 },
    { code = 429, err = "ERR_RATE_LIMIT", msg = "Tenant rate limit exceeded (1000 req/min)", weight = 3 },
    { code = 500, err = "ERR_DB_DEADLOCK", msg = "pq: deadlock detected on relation orders_pkey", weight = 2 },
    { code = 502, err = "ERR_UPSTREAM_RESET", msg = "upstream connect error or disconnect/reset before headers", weight = 2 },
    { code = 504, err = "ERR_GATEWAY_TIMEOUT", msg = "Context deadline exceeded after 5000ms", weight = 1 },
  }

  local weighted_statuses = {}
  for _, s in ipairs(status_profiles) do
    for _ = 1, s.weight do
      table.insert(weighted_statuses, s)
    end
  end

  write_csv(examples_dir .. "/server_access_logs.csv", headers, function(r)
    local ep = pick(endpoints)
    local st = pick(weighted_statuses)
    local reg = pick(regions)
    local is_slow = (st.code >= 500)
    local db_ms = is_slow and math.random(450, 4900) or math.random(1, 45)
    local lat_ms = db_ms + math.random(2, 65)
    local sec = r % 60
    local min = math.floor(r / 60) % 60
    return table.concat({
      tostring(r),
      string.format("2026-11-03T04:%02d:%02d.%03dZ", min, sec, math.random(0, 999)),
      string.format("tr-%08x%04x", r * 2654435761 % 0xffffffff, math.random(0, 0xffff)),
      ep.svc,
      "prod",
      reg,
      string.format("%s-%s-pod-%02d", ep.svc, reg:sub(1, 2), math.random(1, 16)),
      ep.m,
      ep.ep,
      tostring(st.code),
      string.format("%.2f", lat_ms + math.random() * 0.99),
      string.format("%.2f", db_ms + math.random() * 0.99),
      (math.random() > 0.35) and "true" or "false",
      tostring(math.random(256, 65536)),
      string.format("10.%d.%d.%d", math.random(10, 250), math.random(1, 254), math.random(1, 254)),
      string.format("usr_%06d", math.random(1, 50000)),
      st.err,
      csv_quote(st.msg),
    }, ",")
  end, 1000)
end

-- 4. examples/wide_100_columns.csv (250 rows x 100 columns!)
local function build_100_col_headers()
  local h = {
    "col_001_row_id",
    "col_002_account_id",
    "col_003_tenant_name",
    "col_004_region",
    "col_005_plan_tier",
    "col_006_is_active",
    "col_007_mrr_usd",
    "col_008_arr_usd",
    "col_009_health_score",
    "col_010_created_date",
  }
  local metric_names = {
    "cpu_pct", "mem_mb", "disk_iops", "net_in_mbps", "net_out_mbps",
    "req_count", "err_count", "p50_ms", "p95_ms", "p99_ms",
    "db_conns", "cache_ratio", "queue_depth", "worker_util", "gpu_util",
    "tokens_in", "tokens_out", "cost_usd", "credits_used", "sla_uptime",
  }
  for c = 11, 99 do
    local m = metric_names[((c - 11) % #metric_names) + 1]
    local window = math.floor((c - 11) / #metric_names) + 1
    table.insert(h, string.format("col_%03d_w%d_%s", c, window, m))
  end
  table.insert(h, "col_100_audit_checksum")
  return h
end

local wide_headers = build_100_col_headers()
local wide_regions = { "US-EAST", "US-WEST", "EU-CENTRAL", "EU-WEST", "APAC-TOKYO", "APAC-SYD" }
local wide_tiers = { "ENTERPRISE", "BUSINESS", "GROWTH", "STARTER" }
local wide_tenants = { "AcmeCorp", "NebulaAI", "QuantumFin", "VertexBio", "HyperionCloud", "OrbitLogistics", "PulseHealth", "ApexRetail" }

local function make_100_col_row(r)
  local cols = {}
  local mrr = math.random(250, 25000)
  cols[1] = tostring(r)
  cols[2] = string.format("ACC-%07d", r)
  cols[3] = string.format("%s-%03d", wide_tenants[(r % #wide_tenants) + 1], r % 100)
  cols[4] = wide_regions[(r % #wide_regions) + 1]
  cols[5] = wide_tiers[(r % #wide_tiers) + 1]
  cols[6] = (r % 7 ~= 0) and "true" or "false"
  cols[7] = string.format("%.2f", mrr)
  cols[8] = string.format("%.2f", mrr * 12)
  cols[9] = tostring(50 + (r * 17) % 50)
  cols[10] = string.format("2026-%02d-%02d", (r % 12) + 1, (r % 28) + 1)
  for c = 11, 99 do
    local v = ((r * 31 + c * 17) % 10000) / 10.0
    cols[c] = string.format("%.1f", v)
  end
  cols[100] = string.format("chk_%08x", (r * 1103515245 + 12345) % 0x7fffffff)
  return table.concat(cols, ",")
end

write_csv(examples_dir .. "/wide_100_columns.csv", wide_headers, make_100_col_row, 250)

-- 5. examples/edge_cases_rfc4180.csv (50 rows x 12 cols)
do
  local headers = {
    "id", "quoted_comma", "escaped_quotes", "unicode_text", "nullable_field",
    "boolean_flag", "integer_val", "float_val", "scientific_val", "currency_str",
    "iso_timestamp", "json_payload"
  }
  local unicode_samples = {
    "Tokyo 東京 🚀",
    "Zürich — Café & Crème",
    "São Paulo (Região Sul)",
    "München Straßendienst ✓",
    "Seoul 서울 데이터 ⚡",
  }
  write_csv(examples_dir .. "/edge_cases_rfc4180.csv", headers, function(r)
    local is_null = (r % 4 == 0)
    return table.concat({
      tostring(r),
      csv_quote(string.format("Item #%d, Batch %d, Warehouse A", r, r % 5)),
      csv_quote(string.format('The spec says "RFC 4180" for row "%d"', r)),
      csv_quote(unicode_samples[(r % #unicode_samples) + 1]),
      is_null and "" or string.format("VAL_%03d", r),
      (r % 2 == 0) and "true" or "false",
      tostring((r % 3 == 0) and (-r * 42) or (r * 42)),
      string.format("%.4f", (r - 25) * 3.14159),
      string.format("%.3e", r * 1.234e-5),
      csv_quote(string.format("$%d,%03d.50", math.floor(r / 2) + 1, (r * 137) % 1000)),
      string.format("2026-11-03T12:%02d:00Z", r % 60),
      csv_quote(string.format('{"row":%d,"tags":["csv","sqlite","nvim"]}', r)),
    }, ",")
  end, 50)
end

-- Optional: --million flag generates examples/million_100cols.csv (1,000,000 rows x 100 columns)
for _, a in ipairs(arg or {}) do
  if a == "--million" then
    local out_path = examples_dir .. "/million_100cols.csv"
    print("[INFO] Generating " .. out_path .. " (1,000,000 rows x 100 columns)...")
    local f = assert(io.open(out_path, "wb"))
    f:write(table.concat(wide_headers, ",") .. "\n")

    -- Precompute 64 distinct metric suffixes (cols 11..99) for fast assembly
    local suffixes = {}
    for s = 1, 64 do
      local m = {}
      for c = 11, 99 do
        local v = ((s * 31 + c * 17) % 10000) / 10.0
        m[#m + 1] = string.format("%.1f", v)
      end
      suffixes[s] = table.concat(m, ",")
    end

    local batch = {}
    local b_idx = 0
    for r = 1, 1000000 do
      local mrr = 250 + (r * 73) % 24750
      local tenant = wide_tenants[(r % #wide_tenants) + 1]
      local reg = wide_regions[(r % #wide_regions) + 1]
      local tier = wide_tiers[(r % #wide_tiers) + 1]
      local act = (r % 7 ~= 0) and "true" or "false"
      local hs = 50 + (r * 17) % 50
      local mo = (r % 12) + 1
      local dy = (r % 28) + 1
      local suf = suffixes[(r % 64) + 1]
      b_idx = b_idx + 1
      batch[b_idx] = string.format(
        "%d,ACC-%07d,%s-%03d,%s,%s,%s,%d.00,%d.00,%d,2026-%02d-%02d,%s,chk_%08x",
        r, r, tenant, r % 100, reg, tier, act, mrr, mrr * 12, hs, mo, dy, suf, (r * 1103515245 + 12345) % 0x7fffffff
      )
      if b_idx >= 5000 then
        f:write(table.concat(batch, "\n") .. "\n")
        batch = {}
        b_idx = 0
      end
    end
    if b_idx > 0 then
      f:write(table.concat(batch, "\n") .. "\n")
    end
    f:close()
    print("[OK] Wrote " .. out_path .. " (1,000,000 rows x 100 cols)")
  elseif a == "--10k" then
    write_csv(examples_dir .. "/large_10k_100cols.csv", wide_headers, make_100_col_row, 10000)
  end
end
