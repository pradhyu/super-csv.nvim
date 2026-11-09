# super-csv.nvim

High-performance 2D virtualized CSV/TSV/DSV & JSON viewer, streaming filter, analyzer, ASCII table generator, and Copy-on-Write editor for Neovim (`>= 0.10`), engineered for **1,000,000+ rows × 100+ columns**.

See [`SPEC.md`](./SPEC.md) for the full architecture, benchmarks, and specification.

---

## ✨ Features

* **⚡ Ultra-Fast 2D Viewport**: Zero lag with instant slice streaming (< 10ms initial render) backed by SQLite & LuaJIT FFI for millions of rows.
* **📊 Excel-Style Ergonomics**: Frozen headers, freeze panes (`gp`), 100-column fuzzy jumper (`gc`), alternating row/column zebra shading (`gr`/`gz`), and numeric heatmap (`gm`).
* **🌐 First-Class JSON & JSONL Support**: Flatten nested maps and JSON objects into 2D tables while keeping nested arrays as interactive subtable preview cells.
* **🔤 ASCII & Markdown Table Generator & Interactive Preview**:
  * Generate formatted text tables in multiple styles: **GitHub Markdown** (`| :--- | ---: |`), **Classic ASCII** (`+----+`), **Unicode Box** (`┌───┬───┐`), **Rounded** (`╭───┬───╮`), **Grid** (`+===+`), and **Simple**.
  * Works on active 2D sessions, raw CSV/TSV buffers, and JSON/JSONL files.
  * Direct clipboard export with `ya` (ASCII), `ym` (Markdown), `yu` (Unicode), or `:SuperCsv copy_markdown` / `:SuperCsv copy_ascii [style]`.
  * **Interactive Floating Preview Modal** with `<leader>ca` (ASCII) or `<leader>cmd` (Markdown) or `:SuperCsv markdown`:
    * Switch styles live on the fly: press `m` for **Markdown**, `a` for **ASCII**, `u` for **Unicode**, or `<Tab>` to cycle styles.
    * Full Neovim Markdown syntax highlighting (`filetype = "markdown"`).
    * Toggle Markdown code fences (` ```markdown ` / ` ``` `) with `f`.
    * **Save directly to disk** with `s`, `w`, `<C-s>`, or `:w <filename>` in the preview buffer.
    * Direct file export via `:SuperCsv save_markdown [path]` or `:SuperCsv save_ascii [path] [style]`.
* **🎨 Viewport Border Themes**:
  * Pure classic ASCII grid borders enabled by default (`border_style = "ascii"`).
  * Toggle between ASCII (`+---+`) and modern Heavy (`┏━━━┓`) borders on-the-fly with `gA`, `gB`, or `:SuperCsv toggle_ascii`.
  * Choose between `"ascii"` (default), `"heavy"`, `"single"`, and `"rounded"`.

---

## ⌨️ Quick Keybindings

### Inside the 2D Viewport

| Keybinding | Action |
| :--- | :--- |
| `h` / `j` / `k` / `l` | Navigate active cells / rows / columns |
| `f` / `fv` / `fx` / `F` | AutoFilter column / Filter == cell / Filter != cell / Clear filters |
| `s` / `S` | Sort ascending ▲ / descending ▼ |
| `g/` | Grep across all rows and columns |
| `gp` / `gh` / `gH` | Pin (freeze) column / Hide column / Restore all hidden columns |
| `ya` / `ym` / `yu` | **Yank table as ASCII / Markdown / Unicode Box to clipboard** |
| `gA` / `gB` | **Toggle Viewport ASCII (`+---+`) / Heavy (`┏━━━┓`) border style** |
| `<leader>ca` | **Preview ASCII table in interactive floating window** |
| `<leader>cmd` / `<leader>cM` | **Preview Markdown table in interactive floating window** |
| `<leader>cv` | Toggle back to normal raw CSV / JSON buffer |
| `<CR>` / `e` | Edit active cell value (with `u` undo / `<C-r>` redo) |
| `<leader>cw` | Atomically save edits to file |

### Inside ASCII / Markdown Preview Float

| Keybinding | Action |
| :--- | :--- |
| `m` / `a` / `u` / `r` / `g` | Switch live between **Markdown** (`m`), **ASCII** (`a`), **Unicode** (`u`), Rounded (`r`), Grid (`g`) |
| `<Tab>` / `<S-Tab>` | Cycle next / previous table formatting style |
| `f` | Toggle Markdown code fence block wrapper (` ```markdown ` / ` ``` `) |
| `s` / `w` / `<C-s>` | **Save previewed table directly to a file** (with path prompt and completion) |
| `:w [filename]` | Save table using standard Vim write command |
| `y` | Yank current table to clipboard (`+` and `"` registers) |
| `q` / `<Esc>` | Close preview window |

### In Raw CSV / JSON Buffers

| Keybinding | Action |
| :--- | :--- |
| `<leader>cv` | Open 2D Excel Virtual Viewport on current file |
| `<leader>ca` | Preview formatted ASCII table of current CSV / JSON |
| `<leader>cmd` / `<leader>cM` | Preview formatted Markdown table of current CSV / JSON |
| `<leader>cy` | Copy formatted ASCII table of current CSV / JSON to clipboard |
| `<leader>cym` | Copy formatted Markdown table of current CSV / JSON to clipboard |
| `<leader>cj` | Convert JSON to `.csv` file and open in 2D viewport |

---

## ⚙️ Configuration

```lua
require("super-csv").setup({
  border_style = "ascii",    -- Viewport border style: "ascii" (default), "heavy", "single", "rounded"
  rainbow_columns = true,    -- Rainbow CSV per-column foreground colors
  zebra_rows = true,         -- Alternating background colors for even/odd rows
  zebra_columns = false,     -- Alternating background colors for even/odd columns
  comment_char = "#",        -- Default comment prefix for CSV/TSV
  json_comment_char = "//",  -- Default comment prefix for JSON/JSONC/JSONL
  auto_open = true,          -- Automatically open Excel 2D viewport on .csv/.tsv
  auto_open_json = false,    -- Automatically open Excel 2D viewport on .json/.jsonl
})
```

---

## 🛠️ Ex-Commands

* `:SuperCsv` / `:SuperCsv toggle`: Toggle 2D viewport
* `:SuperCsv markdown [limit]` / `:SuperCsv md`: Open formatted Markdown table in preview float
* `:SuperCsv ascii [style] [limit]`: Open formatted table in preview float (interactive live style switching)
* `:SuperCsv copy_markdown [limit]`: Copy formatted Markdown table to clipboard
* `:SuperCsv copy_ascii [style] [limit]`: Copy formatted ASCII/Unicode table to clipboard
* `:SuperCsv save_markdown [filepath] [limit]`: Save Markdown table directly to file
* `:SuperCsv save_ascii [filepath] [style] [limit]`: Save ASCII/Unicode table directly to file
* `:SuperCsv style [heavy|ascii|single|rounded|toggle]`: Change viewport border style
* `:SuperCsv toggle_ascii`: Quick toggle between heavy and ascii borders
* `:SuperCsv json`: Open active JSON buffer in 2D viewport
* `:SuperCsv json_to_csv [input.json] [out.csv]`: Convert JSON to CSV
