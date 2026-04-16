local M = {}

local function format_message(default_message, message)
  if message and message ~= "" then
    return tostring(message)
  end
  return default_message
end

local function fail(default_message, message)
  error(format_message(default_message, message), 2)
end

local function is_list(tbl)
  return type(tbl) == "table" and vim.islist(tbl)
end

local function deep_equal(actual, expected)
  if type(actual) ~= type(expected) then
    return false
  end

  if type(actual) ~= "table" then
    return actual == expected
  end

  if is_list(actual) or is_list(expected) then
    if not (is_list(actual) and is_list(expected)) or #actual ~= #expected then
      return false
    end

    for idx, value in ipairs(actual) do
      if not deep_equal(value, expected[idx]) then
        return false
      end
    end

    return true
  end

  for key, value in pairs(actual) do
    if not deep_equal(value, expected[key]) then
      return false
    end
  end

  for key in pairs(expected) do
    if actual[key] == nil then
      return false
    end
  end

  return true
end

function M.install_assertions()
  _G.assert = setmetatable({}, {
    __call = function(_, value, message)
      if not value then
        fail("assertion failed", message)
      end
      return value
    end,
  })

  assert.are = {}

  function assert.are.same(expected, actual, message)
    if not deep_equal(actual, expected) then
      fail(string.format("expected %s, got %s", vim.inspect(expected), vim.inspect(actual)), message)
    end
  end

  function assert.equals(expected, actual, message)
    if actual ~= expected then
      fail(string.format("expected %s, got %s", vim.inspect(expected), vim.inspect(actual)), message)
    end
  end

  function assert.True(value, message)
    if value ~= true then
      fail(string.format("expected true, got %s", vim.inspect(value)), message)
    end
  end

  function assert.is_true(value, message)
    if value ~= true then
      fail(string.format("expected true, got %s", vim.inspect(value)), message)
    end
  end

  function assert.is_false(value, message)
    if value ~= false then
      fail(string.format("expected false, got %s", vim.inspect(value)), message)
    end
  end

  function assert.is_string(value, message)
    if type(value) ~= "string" then
      fail(string.format("expected string, got %s", type(value)), message)
    end
  end

  function assert.is_table(value, message)
    if type(value) ~= "table" then
      fail(string.format("expected table, got %s", type(value)), message)
    end
  end

  function assert.is_function(value, message)
    if type(value) ~= "function" then
      fail(string.format("expected function, got %s", type(value)), message)
    end
  end

  function assert.is_nil(value, message)
    if value ~= nil then
      fail(string.format("expected nil, got %s", vim.inspect(value)), message)
    end
  end

  function assert.is_not_nil(value, message)
    if value == nil then
      fail("expected non-nil value", message)
    end
  end

  function assert.matches(pattern, value, message)
    if type(value) ~= "string" or not value:match(pattern) then
      fail(string.format("expected %s to match %s", vim.inspect(value), vim.inspect(pattern)), message)
    end
  end
end

return M
