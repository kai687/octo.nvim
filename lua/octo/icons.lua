local config = require "octo.config"

local M = {}

local function get_mini_icons()
  if _G.MiniIcons == nil then
    return nil
  end

  return _G.MiniIcons
end

local function get_web_devicons()
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then
    return nil
  end

  return devicons
end

function M.get_file_icon_provider()
  local file_panel = config.values.file_panel
  if not file_panel.use_icons then
    return nil
  end

  local provider = file_panel.icon_provider
  if provider == "mini.icons" then
    return get_mini_icons() and "mini.icons" or nil
  end

  if provider == "nvim-web-devicons" then
    return get_web_devicons() and "nvim-web-devicons" or nil
  end

  if get_mini_icons() then
    return "mini.icons"
  end

  if get_web_devicons() then
    return "nvim-web-devicons"
  end

  return nil
end

---@param name string
---@param ext string
---@return string?, string?
function M.get_file_icon(name, ext)
  local provider = M.get_file_icon_provider()
  if provider == "mini.icons" then
    local icon, hl = get_mini_icons().get("file", name)
    return icon, hl
  end

  if provider == "nvim-web-devicons" then
    return get_web_devicons().get_icon(name, ext)
  end

  return nil, nil
end

return M
