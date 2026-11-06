if vim.g.loaded_super_csv then
  return
end
vim.g.loaded_super_csv = true

local subcommands = {
  "open",
  "toggle",
  "json",
  "json_to_csv",
  "convert",
  "disable",
  "enable",
  "zebra_rows",
  "zebra_cols",
  "filter",
  "filter_val",
  "filter_clear",
  "grep",
  "freq",
  "stats",
  "count",
  "sum",
  "columns",
  "record",
  "sql",
  "sort",
  "freeze",
  "heatmap",
  "comments",
  "comment_char",
  "json_comment_char",
  "help",
  "save",
  "export",
}

vim.api.nvim_create_user_command("SuperCsv", function(opts)
  require("super-csv").command(opts.args)
end, {
  nargs = "*",
  complete = function(arg_lead)
    return vim.tbl_filter(function(item)
      return item:find("^" .. vim.pesc(arg_lead)) ~= nil
    end, subcommands)
  end,
  desc = "SuperCsv: Excel-grade 2D Virtual CSV Viewer, Filter, Grep & SQLite Engine",
})
