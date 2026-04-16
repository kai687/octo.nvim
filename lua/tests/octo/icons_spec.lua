---@diagnostic disable
local config = require "octo.config"
local eq = assert.are.same

describe("Octo icons", function()
  local original_mini_icons
  local original_preload

  before_each(function()
    original_mini_icons = _G.MiniIcons
    original_preload = package.preload["nvim-web-devicons"]
    package.loaded["nvim-web-devicons"] = nil
    _G.MiniIcons = nil
    config.values = config.get_default_values()
  end)

  after_each(function()
    _G.MiniIcons = original_mini_icons
    package.preload["nvim-web-devicons"] = original_preload
    package.loaded["nvim-web-devicons"] = nil
  end)

  it("returns no provider when file panel icons are disabled", function()
    local icons = require "octo.icons"

    config.values.file_panel.use_icons = false

    eq(nil, icons.get_file_icon_provider())
    eq(nil, select(1, icons.get_file_icon("test.lua", "lua")))
  end)

  it("uses mini.icons when explicitly configured", function()
    local icons = require "octo.icons"

    config.values.file_panel.icon_provider = "mini.icons"
    _G.MiniIcons = {
      get = function(category, name)
        eq("file", category)
        eq("test.lua", name)
        return "M", "MiniIconsAzure"
      end,
    }

    eq("mini.icons", icons.get_file_icon_provider())
    eq({ "M", "MiniIconsAzure" }, { icons.get_file_icon("test.lua", "lua") })
  end)

  it("uses nvim-web-devicons when explicitly configured", function()
    local icons = require "octo.icons"

    config.values.file_panel.icon_provider = "nvim-web-devicons"
    package.preload["nvim-web-devicons"] = function()
      return {
        get_icon = function(name, ext)
          eq("test.lua", name)
          eq("lua", ext)
          return "N", "DevIconLua"
        end,
      }
    end

    eq("nvim-web-devicons", icons.get_file_icon_provider())
    eq({ "N", "DevIconLua" }, { icons.get_file_icon("test.lua", "lua") })
  end)

  it("prefers mini.icons in auto mode", function()
    local icons = require "octo.icons"

    _G.MiniIcons = {
      get = function()
        return "M", "MiniIconsAzure"
      end,
    }
    package.preload["nvim-web-devicons"] = function()
      return {
        get_icon = function()
          return "N", "DevIconLua"
        end,
      }
    end

    eq("mini.icons", icons.get_file_icon_provider())
    eq({ "M", "MiniIconsAzure" }, { icons.get_file_icon("test.lua", "lua") })
  end)

  it("falls back to nvim-web-devicons in auto mode", function()
    local icons = require "octo.icons"

    package.preload["nvim-web-devicons"] = function()
      return {
        get_icon = function()
          return "N", "DevIconLua"
        end,
      }
    end

    eq("nvim-web-devicons", icons.get_file_icon_provider())
    eq({ "N", "DevIconLua" }, { icons.get_file_icon("test.lua", "lua") })
  end)

  it("returns no icon when no provider is available", function()
    local icons = require "octo.icons"

    eq(nil, icons.get_file_icon_provider())
    eq({ nil, nil }, { icons.get_file_icon("test.lua", "lua") })
  end)
end)
