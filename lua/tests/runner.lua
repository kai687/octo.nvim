local M = {}

local tests = {}
local stack = {}

local function full_name(name)
  local names = {}
  for _, scope in ipairs(stack) do
    table.insert(names, scope.name)
  end
  table.insert(names, name)
  return table.concat(names, " ")
end

local function collect_hooks(kind)
  local hooks = {}
  for _, scope in ipairs(stack) do
    local scope_hooks = scope[kind]
    if scope_hooks then
      for _, hook in ipairs(scope_hooks) do
        table.insert(hooks, hook)
      end
    end
  end
  return hooks
end

function _G.describe(name, fn)
  table.insert(stack, { name = name, before_each = {}, after_each = {} })
  fn()
  table.remove(stack)
end

function _G.it(name, fn)
  table.insert(tests, {
    name = full_name(name),
    fn = fn,
    before_each = collect_hooks("before_each"),
    after_each = collect_hooks("after_each"),
  })
end

function _G.before_each(fn)
  table.insert(stack[#stack].before_each, fn)
end

function _G.after_each(fn)
  table.insert(stack[#stack].after_each, 1, fn)
end

local function run_test(test)
  for _, hook in ipairs(test.before_each) do
    hook()
  end

  if debug.getinfo(test.fn, "u").nparams > 0 then
    test.fn(function() end)
  else
    test.fn()
  end

  for _, hook in ipairs(test.after_each) do
    hook()
  end
end

local function load_spec(path)
  package.loaded[path:gsub("/", "."):gsub("%.lua$", "")] = nil
  dofile(vim.fs.joinpath(vim.fn.getcwd(), path))
end

function M.run()
  require("tests.helpers").install_assertions()

  local spec_paths = vim.fn.sort(vim.fn.glob("lua/tests/**/*_spec.lua", false, true))
  for _, path in ipairs(spec_paths) do
    load_spec(path)
  end

  local failures = {}
  for _, test in ipairs(tests) do
    local ok, err = xpcall(function()
      run_test(test)
    end, debug.traceback)

    if ok then
      print("PASS " .. test.name)
    else
      table.insert(failures, { name = test.name, err = err })
      io.stderr:write("FAIL " .. test.name .. "\n" .. err .. "\n")
    end
  end

  print(string.format("Ran %d tests", #tests))

  if #failures > 0 then
    error(string.format("%d tests failed", #failures))
  end
end

return M
