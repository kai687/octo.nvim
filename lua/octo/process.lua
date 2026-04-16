local uv = vim.uv or vim.loop

local M = {}

---@class octo.ProcessOpts
---@field cmd string
---@field args? string[]
---@field cwd? string
---@field env? table<string, string|integer>
---@field timeout? integer
---@field stream_cb? fun(stdout: string?, stderr: string?)
---@field cb? fun(stdout: string, stderr: string, status: integer)

local function normalize_env(env)
  if type(env) ~= "table" then
    return nil
  end

  local normalized = {}
  for key, value in pairs(env) do
    if value ~= nil then
      normalized[key] = tostring(value)
    end
  end

  return normalized
end

local function build_command(opts)
  return vim.list_extend({ opts.cmd }, opts.args or {})
end

local function split_complete_lines(buffer)
  local lines = {}
  local start = 1

  while true do
    local nl = buffer:find("\n", start, true)
    if not nl then
      break
    end

    local line = buffer:sub(start, nl - 1)
    if vim.endswith(line, "\r") then
      line = line:sub(1, -2)
    end
    table.insert(lines, line)
    start = nl + 1
  end

  return lines, buffer:sub(start)
end

local function emit_stream_line(cb, stdout, stderr)
  vim.schedule(function()
    cb(stdout, stderr)
  end)
end

local function create_stream_handlers(stream_cb)
  if not stream_cb then
    return nil, nil, nil
  end

  local stdout_buffer = ""
  local stderr_buffer = ""

  local function handle_chunk(chunk, is_stderr)
    if chunk == nil or chunk == "" then
      return
    end

    if is_stderr then
      stderr_buffer = stderr_buffer .. chunk
      local lines
      lines, stderr_buffer = split_complete_lines(stderr_buffer)
      for _, line in ipairs(lines) do
        emit_stream_line(stream_cb, nil, line)
      end
    else
      stdout_buffer = stdout_buffer .. chunk
      local lines
      lines, stdout_buffer = split_complete_lines(stdout_buffer)
      for _, line in ipairs(lines) do
        emit_stream_line(stream_cb, line, nil)
      end
    end
  end

  local function flush()
    if stdout_buffer ~= "" then
      local line = stdout_buffer
      if vim.endswith(line, "\r") then
        line = line:sub(1, -2)
      end
      emit_stream_line(stream_cb, line, nil)
      stdout_buffer = ""
    end

    if stderr_buffer ~= "" then
      local line = stderr_buffer
      if vim.endswith(line, "\r") then
        line = line:sub(1, -2)
      end
      emit_stream_line(stream_cb, nil, line)
      stderr_buffer = ""
    end
  end

  return function(err, chunk)
    if err then
      emit_stream_line(stream_cb, nil, err)
      return
    end
    handle_chunk(chunk, false)
  end, function(err, chunk)
    if err then
      emit_stream_line(stream_cb, nil, err)
      return
    end
    handle_chunk(chunk, true)
  end, flush
end

local function result_status(result, timed_out)
  if timed_out then
    return 124
  end

  return result.code or 0
end

---@param opts octo.ProcessOpts
---@return string stdout
---@return string stderr
---@return integer status
function M.run_sync(opts)
  local obj = vim.system(build_command(opts), {
    text = true,
    cwd = opts.cwd,
    env = normalize_env(opts.env),
  })

  local result, err = obj:wait(opts.timeout)
  if result == nil then
    obj:kill(15)
    local timeout_err = err
    if timeout_err == nil or timeout_err == "" then
      timeout_err = "Command timed out"
    end
    return "", timeout_err, 124
  end

  return result.stdout or "", result.stderr or "", result_status(result, false)
end

---@param opts octo.ProcessOpts
---@return vim.SystemObj
function M.run_async(opts)
  local on_stdout, on_stderr, flush_streams = create_stream_handlers(opts.stream_cb)
  local done = false
  local timed_out = false
  local timer

  local obj = vim.system(build_command(opts), {
    text = true,
    cwd = opts.cwd,
    env = normalize_env(opts.env),
    stdout = on_stdout,
    stderr = on_stderr,
  }, function(result)
    if done then
      return
    end
    done = true

    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end

    if flush_streams then
      flush_streams()
    end

    if opts.cb then
      vim.schedule(function()
        opts.cb(result.stdout or "", result.stderr or "", result_status(result, timed_out))
      end)
    end
  end)

  if opts.timeout and opts.timeout > 0 then
    timer = uv.new_timer()
    if timer then
      timer:start(opts.timeout, 0, function()
        timer:stop()
        timer:close()
        if done then
          return
        end
        timed_out = true
        pcall(obj.kill, obj, 15)
      end)
    end
  end

  return obj
end

return M
