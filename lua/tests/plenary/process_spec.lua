local process = require "octo.process"

describe("Process module", function()
  it("run_sync captures stdout, stderr and exit code", function()
    local stdout, stderr, status = process.run_sync {
      cmd = "sh",
      args = { "-c", "printf 'hello'; printf 'warn' >&2; exit 7" },
    }

    assert.equals("hello", stdout)
    assert.equals("warn", stderr)
    assert.equals(7, status)
  end)

  it("run_sync returns timeout status", function()
    local _, _, status = process.run_sync {
      cmd = "sh",
      args = { "-c", "sleep 1" },
      timeout = 10,
    }

    assert.equals(124, status)
  end)

  it("run_async buffers partial stdout and stderr lines", function()
    local stdout_lines = {}
    local stderr_lines = {}
    local done = false

    process.run_async {
      cmd = "sh",
      args = {
        "-c",
        "printf 'one'; sleep 0.05; printf '\\ntwo\\n'; printf 'err' >&2; sleep 0.05; printf '\\n' >&2",
      },
      stream_cb = function(stdout, stderr)
        if stdout then
          table.insert(stdout_lines, stdout)
        end
        if stderr then
          table.insert(stderr_lines, stderr)
        end
      end,
      cb = function(_, _, status)
        assert.equals(0, status)
        done = true
      end,
    }

    assert.True(vim.wait(1000, function()
      return done
    end))
    assert.are.same({ "one", "two" }, stdout_lines)
    assert.are.same({ "err" }, stderr_lines)
  end)
end)
