---@diagnostic disable: undefined-field
local enabled = _G.__is_log ~= nil
local level = (_G.__is_log == true and "debug") or "warn"
local levels = { debug = 1, info = 2, warn = 3, error = 4 }
local logfile = vim.fs.joinpath(vim.fn.stdpath "cache", "octo.log")

local function write_log(kind, msg)
  if not enabled or levels[kind] < levels[level] then
    return
  end

  local line = string.format("%s [%s] %s", os.date("%Y-%m-%d %H:%M:%S"), kind, tostring(msg))
  pcall(vim.fn.writefile, { line }, logfile, "a")
end

return {
  debug = function(msg)
    write_log("debug", msg)
  end,
  info = function(msg)
    write_log("info", msg)
  end,
  warn = function(msg)
    write_log("warn", msg)
  end,
  error = function(msg)
    write_log("error", msg)
  end,
}
