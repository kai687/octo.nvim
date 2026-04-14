---@diagnostic disable
local MiniPick = require "mini.pick"

local gh = require "octo.gh"
local queries = require "octo.gh.queries"
local notifications = require "octo.notifications"
local navigation = require "octo.navigation"
local octo_config = require "octo.config"
local utils = require "octo.utils"

local M = {}

local function get_github_host()
  local host = octo_config.values.github_hostname
  if utils.is_blank(host) then
    host = utils.get_remote_host()
  end
  if utils.is_blank(host) then
    host = "github.com"
  end
  return host
end

local function build_github_url(path)
  return string.format("https://%s/%s", get_github_host(), path)
end

local function get_target_window()
  local state = MiniPick.get_picker_state()
  local target = state and state.windows and state.windows.target or vim.api.nvim_get_current_win()
  if target and vim.api.nvim_win_is_valid(target) then
    return target
  end
  return vim.api.nvim_get_current_win()
end

local function in_target_window(fn)
  vim.api.nvim_win_call(get_target_window(), fn)
end

local function get_current_item()
  local matches = MiniPick.get_picker_matches()
  return matches and matches.current or nil
end

local function set_preview_lines(bufnr, lines, filetype)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  if filetype then
    vim.bo[bufnr].filetype = filetype
  end
end

local function add_mapping(mappings, name, lhs, fn)
  if utils.is_blank(lhs) then
    return
  end

  mappings[name] = {
    char = lhs,
    func = function()
      local item = get_current_item()
      if item == nil then
        return false
      end
      fn(item)
      return false
    end,
  }
end

local function start_picker(opts)
  local picker_opts = {
    source = {
      name = opts.name,
      items = opts.items,
      choose = opts.choose,
    },
    mappings = opts.mappings or {},
  }

  if opts.preview then
    picker_opts.source.preview = opts.preview
  end

  if opts.choose_marked then
    picker_opts.source.choose_marked = opts.choose_marked
  end

  MiniPick.start(picker_opts)
end

local function fetch_pr_head_sha(repo, number, cb)
  local owner, name = utils.split_repo(repo)
  gh.api.get {
    "/repos/{owner}/{repo}/pulls/{pull_number}",
    format = { owner = owner, repo = name, pull_number = number },
    opts = {
      cb = gh.create_callback {
        success = function(output)
          local pr_data = vim.json.decode(output)
          cb(pr_data.head.sha)
        end,
      },
    },
  }
end

local function open_notification_in_browser(notification)
  local subject = notification.subject
  local url = not utils.is_blank(subject.latest_comment_url) and subject.latest_comment_url or subject.url

  gh.api.get {
    url,
    jq = ".html_url",
    opts = {
      cb = gh.create_callback { success = navigation.open_in_browser_raw },
    },
  }
end

local function preview_issueish(bufnr, item)
  local repo = item.repository and item.repository.nameWithOwner
  if utils.is_blank(repo) then
    set_preview_lines(bufnr, { item.text or "No preview available" })
    return
  end

  local owner, name = utils.split_repo(repo)
  local preview = notifications.get_preview_fn(item.kind)
  if preview == nil then
    set_preview_lines(bufnr, { item.text or "No preview available" })
    return
  end

  set_preview_lines(bufnr, { "Loading..." })
  notifications.fetch_preview(owner, name, tostring(item.number), item.kind, function(obj)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    preview(obj, bufnr)
  end)
end

local function pick_action_list(name, items)
  for _, item in ipairs(items) do
    item.text = string.format("%s %s", item.object, item.name)
  end

  start_picker {
    name = name,
    items = items,
    choose = function(item)
      in_target_window(function()
        item.fun()
      end)
    end,
  }
end

local function pick_entity_list(name, items, opts)
  opts = opts or {}
  local cfg = octo_config.values
  local mappings = {}

  add_mapping(mappings, "open_in_browser", cfg.picker_config.mappings.open_in_browser.lhs, function(item)
    navigation.open_in_browser(item.kind, item.repository.nameWithOwner, item.number)
  end)

  add_mapping(mappings, "copy_url", cfg.picker_config.mappings.copy_url.lhs, function(item)
    utils.copy_url(item.url)
  end)

  add_mapping(mappings, "copy_sha", cfg.picker_config.mappings.copy_sha.lhs, function(item)
    if item.kind ~= "pull_request" then
      utils.info "Copy SHA not available for this item type"
      return
    end
    utils.info "Fetching PR details for SHA..."
    fetch_pr_head_sha(item.repository.nameWithOwner, item.number, utils.copy_sha)
  end)

  if opts.add_checkout then
    add_mapping(mappings, "checkout_pr", cfg.picker_config.mappings.checkout_pr.lhs, function(item)
      utils.checkout_pr(item.number)
    end)
  end

  if opts.add_merge then
    add_mapping(mappings, "merge_pr", cfg.picker_config.mappings.merge_pr.lhs, function(item)
      utils.merge_pr(item.number)
    end)
  end

  start_picker {
    name = name,
    items = items,
    preview = preview_issueish,
    mappings = mappings,
    choose = function(item)
      if opts.cb then
        opts.cb(item)
        return
      end
      in_target_window(function()
        utils.get(item.kind, item.number, item.repository.nameWithOwner)
      end)
    end,
  }
end

local function pick_repo_list(name, repos, cb)
  local cfg = octo_config.values
  local mappings = {}

  add_mapping(mappings, "open_in_browser", cfg.picker_config.mappings.open_in_browser.lhs, function(item)
    navigation.open_in_browser("repo", item.nameWithOwner)
  end)

  add_mapping(mappings, "copy_url", cfg.picker_config.mappings.copy_url.lhs, function(item)
    utils.copy_url(item.url)
  end)

  start_picker {
    name = name,
    items = repos,
    mappings = mappings,
    preview = function(bufnr, item)
      local lines = {
        item.nameWithOwner,
        "",
        item.description or "",
        "",
        string.format("Stars: %s", item.stargazerCount or 0),
        string.format("Forks: %s", item.forkCount or 0),
        string.format("Issues: %s", item.issues and item.issues.totalCount or 0),
        string.format("Pull requests: %s", item.pullRequests and item.pullRequests.totalCount or 0),
        string.format("URL: %s", item.url or ""),
      }
      set_preview_lines(bufnr, lines)
    end,
    choose = function(item)
      if cb then
        cb(item)
        return
      end
      in_target_window(function()
        utils.get_repo(nil, item.nameWithOwner)
      end)
    end,
  }
end

function M.actions(flattened_actions)
  pick_action_list("Octo Actions", flattened_actions)
end

---@param opts? { repo: string, cb: function }
function M.discussions(opts)
  opts = opts or {}
  if utils.is_blank(opts.repo) then
    opts.repo = utils.get_remote_name()
  end

  local owner, name = utils.split_repo(opts.repo)
  local order_by = octo_config.values.discussions.order_by
  local callback = opts.cb
    or function(selection)
      in_target_window(function()
        utils.get("discussion", selection.number, selection.repository.nameWithOwner)
      end)
    end

  gh.api.graphql {
    query = queries.discussions,
    F = {
      owner = owner,
      name = name,
      states = { "OPEN" },
      orderBy = order_by.field,
      direction = order_by.direction,
    },
    paginate = true,
    jq = ".data.repository.discussions.nodes",
    opts = {
      cb = gh.create_callback {
        success = function(output)
          local discussions = utils.get_flatten_pages(output)
          if #discussions == 0 then
            utils.error(string.format("There are no matching discussions in %s.", opts.repo))
            return
          end

          for _, discussion in ipairs(discussions) do
            local category = discussion.category and (" [" .. discussion.category.name .. "]") or ""
            discussion.kind = "discussion"
            discussion.text = string.format("#%d %s%s", discussion.number, discussion.title, category)
          end

          pick_entity_list("Discussions", discussions, { cb = callback })
        end,
      },
    },
  }
end

---@param opts? { repo: string, states: string[], cb: function }
function M.issues(opts)
  opts = opts or {}
  opts.states = opts.states or { "OPEN" }

  local repo = utils.pop_key(opts, "repo")
  if utils.is_blank(repo) then
    repo = utils.get_remote_name()
  end
  if not repo then
    utils.error "Cannot find repo"
    return
  end

  local callback = utils.pop_key(opts, "cb")
    or function(selection)
      in_target_window(function()
        utils.get("issue", selection.number, selection.repository.nameWithOwner)
      end)
    end

  local owner, name = utils.split_repo(repo)
  utils.info "Fetching issues (this may take a while) ..."
  gh.api.graphql {
    query = queries.issues,
    F = {
      owner = owner,
      name = name,
      filter_by = opts,
      order_by = octo_config.values.issues.order_by,
    },
    paginate = true,
    jq = ".",
    opts = {
      cb = gh.create_callback {
        success = function(data)
          local resp = utils.aggregate_pages(data, "data.repository.issues.nodes")
          local issues = resp.data.repository.issues.nodes

          if #issues == 0 then
            utils.error(string.format("There are no matching issues in %s.", repo))
            return
          end

          for _, issue in ipairs(issues) do
            issue.kind = "issue"
            issue.text = string.format("#%d %s [%s]", issue.number, issue.title, issue.state)
          end

          pick_entity_list("Issues", issues, { cb = callback })
        end,
      },
    },
  }
end

---@param opts? { repo: string, states: string[], baseRefName?: string, headRefName?: string, labels?: string[], cb?: function }
function M.pull_requests(opts)
  opts = opts or {}
  local repo = utils.pop_key(opts, "repo")
  if utils.is_blank(repo) then
    repo = utils.get_remote_name()
  end
  if not repo then
    utils.error "Cannot find repo"
    return
  end

  local callback = utils.pop_key(opts, "cb")
    or function(selection)
      in_target_window(function()
        utils.get("pull_request", selection.number, selection.repository.nameWithOwner)
      end)
    end

  local owner, name = utils.split_repo(repo)
  utils.info "Fetching pull requests (this may take a while) ..."
  gh.api.graphql {
    query = queries.pull_requests,
    F = {
      owner = owner,
      name = name,
      base_ref_name = opts.baseRefName,
      head_ref_name = opts.headRefName,
      labels = opts.labels,
      states = opts.states or { "OPEN" },
      order_by = octo_config.values.pull_requests.order_by,
    },
    jq = ".",
    paginate = true,
    opts = {
      cb = gh.create_callback {
        success = function(data)
          local resp = utils.aggregate_pages(data, "data.repository.pullRequests.nodes")
          local pulls = resp.data.repository.pullRequests.nodes

          if #pulls == 0 then
            utils.error(string.format("There are no matching pull requests in %s.", repo))
            return
          end

          for _, pull in ipairs(pulls) do
            pull.kind = "pull_request"
            pull.text = string.format("#%d %s [%s]", pull.number, pull.title, pull.state)
          end

          pick_entity_list("Pull Requests", pulls, {
            cb = callback,
            add_checkout = true,
            add_merge = true,
          })
        end,
      },
    },
  }
end

---@param opts? { repo?: string, cb?: function }
function M.releases(opts)
  opts = opts or {}
  opts.repo = opts.repo or utils.get_remote_name()

  local callback = opts.cb
    or function(release)
      in_target_window(function()
        utils.get("release", release.tagName, opts.repo)
      end)
    end

  gh.release.list {
    repo = opts.repo,
    json = "name,tagName,createdAt",
    opts = {
      cb = gh.create_callback {
        success = function(output)
          local releases = vim.json.decode(output)

          if #releases == 0 then
            utils.error "No releases found"
            return
          end

          for _, release in ipairs(releases) do
            release.text = string.format("%s (%s)", release.name or release.tagName, release.tagName)
          end

          start_picker {
            name = "Releases",
            items = releases,
            preview = function(bufnr, item)
              set_preview_lines(bufnr, {
                item.name or item.tagName,
                string.format("Tag: %s", item.tagName),
                string.format("Created: %s", item.createdAt or "unknown"),
              })
            end,
            choose = callback,
          }
        end,
      },
    },
  }
end

---@param edits octo.UserContentEdit[]
function M.comment_edits(edits)
  for _, edit in ipairs(edits) do
    local editor = edit.editor and edit.editor.login or "unknown"
    local utc_ts = utils.parse_utc_date(edit.editedAt)
    local tz_offset = os.difftime(os.time(), os.time(os.date "!*t"))
    local abs_time = os.date("%b %d %H:%M", utc_ts + tz_offset)
    edit.text = string.format("%s  %s (%s)", editor, abs_time, utils.format_date(edit.editedAt))
  end

  start_picker {
    name = "Comment Edit History",
    items = edits,
    preview = function(bufnr, item)
      local diff = item.diff
      if diff and diff ~= vim.NIL and diff ~= "" then
        set_preview_lines(bufnr, vim.split(diff:gsub("\r\n", "\n"):gsub("\r", "\n"), "\n"), "diff")
      else
        set_preview_lines(bufnr, { "No diff available for this edit" })
      end
    end,
    choose = function(item)
      if item.diff and item.diff ~= vim.NIL and item.diff ~= "" then
        in_target_window(function()
          local bufnr = vim.api.nvim_create_buf(false, true)
          vim.api.nvim_buf_set_lines(
            bufnr,
            0,
            -1,
            false,
            vim.split(item.diff:gsub("\r\n", "\n"):gsub("\r", "\n"), "\n")
          )
          vim.api.nvim_set_option_value("filetype", "diff", { scope = "local", buf = bufnr })
          vim.api.nvim_set_option_value("modifiable", false, { scope = "local", buf = bufnr })
          vim.cmd "split"
          vim.api.nvim_win_set_buf(0, bufnr)
        end)
      else
        utils.info "No diff available for this edit"
      end
    end,
  }
end

function M.issue_templates(templates, cb)
  local items = {}
  for name, template in pairs(templates or {}) do
    items[#items + 1] = {
      value = name,
      template = template,
      text = template.about and template.about ~= "" and string.format("%s - %s", name, template.about) or name,
    }
  end

  table.sort(items, function(left, right)
    return left.value < right.value
  end)

  start_picker {
    name = "Issue Templates",
    items = items,
    preview = function(bufnr, item)
      local body = item.template and item.template.body or ""
      local lines = body ~= "" and vim.split(body, "\n") or { "No template body available" }
      set_preview_lines(bufnr, lines, "markdown")
    end,
    choose = function(item)
      if type(cb) == "function" then
        cb(item.template)
      end
    end,
  }
end

---@param opts {repo: string, number: integer, title: string?}
function M.commits(opts)
  gh.api.get {
    "/repos/{repo}/pulls/{number}/commits",
    format = { repo = opts.repo, number = opts.number },
    opts = {
      paginate = true,
      cb = gh.create_callback {
        success = function(output)
          local results = vim.json.decode(output)
          if #results == 0 then
            utils.error "No commits found for this pull request"
            return
          end

          for _, commit in ipairs(results) do
            commit.text = string.format("%s %s", commit.sha:sub(1, 7), commit.commit.message:gsub("\n.*", ""))
          end

          local cfg = octo_config.values
          local mappings = {}
          add_mapping(mappings, "open_in_browser", cfg.picker_config.mappings.open_in_browser.lhs, function(item)
            navigation.open_in_browser_raw(build_github_url(string.format("%s/commit/%s", opts.repo, item.sha)))
          end)
          add_mapping(mappings, "copy_url", cfg.picker_config.mappings.copy_url.lhs, function(item)
            utils.copy_url(build_github_url(string.format("%s/commit/%s", opts.repo, item.sha)))
          end)

          start_picker {
            name = opts.title or "PR Commits",
            items = results,
            mappings = mappings,
            preview = function(bufnr, item)
              set_preview_lines(bufnr, {
                string.format("Commit: %s", item.sha),
                string.format("Author: %s <%s>", item.commit.author.name, item.commit.author.email),
                string.format("Date: %s", item.commit.author.date),
                "",
                "Message:",
                item.commit.message,
              }, "gitcommit")
            end,
            choose = function(item)
              navigation.open_in_browser_raw(build_github_url(string.format("%s/commit/%s", opts.repo, item.sha)))
            end,
          }
        end,
      },
    },
  }
end

---@param current_review Review
---@param callback fun(right: Rev, left: Rev): nil
function M.review_commits(current_review, callback)
  gh.api.get {
    "/repos/{repo}/pulls/{number}/commits",
    format = {
      repo = current_review.pull_request.repo,
      number = current_review.pull_request.number,
    },
    paginate = true,
    opts = {
      cb = gh.create_callback {
        success = function(output)
          local results = vim.json.decode(output)
          if #results == 0 then
            utils.error "No commits found for this pull request"
            return
          end

          table.insert(results, 1, {
            sha = current_review.pull_request.right.commit,
            commit = {
              message = "[[ENTIRE PULL REQUEST]]",
              author = { name = "", email = "", date = "" },
            },
            parents = {
              { sha = current_review.pull_request.left.commit },
            },
            is_full_pr = true,
          })

          for _, commit in ipairs(results) do
            if commit.is_full_pr then
              commit.text = commit.commit.message
            else
              commit.text = string.format("%s %s", commit.sha:sub(1, 7), commit.commit.message:gsub("\n.*", ""))
            end
          end

          local cfg = octo_config.values
          local mappings = {}
          add_mapping(mappings, "open_in_browser", cfg.picker_config.mappings.open_in_browser.lhs, function(item)
            if item.is_full_pr then
              navigation.open_in_browser(
                "pull_request",
                current_review.pull_request.repo,
                current_review.pull_request.number
              )
              return
            end
            navigation.open_in_browser_raw(
              build_github_url(string.format("%s/commit/%s", current_review.pull_request.repo, item.sha))
            )
          end)
          add_mapping(mappings, "copy_url", cfg.picker_config.mappings.copy_url.lhs, function(item)
            if item.is_full_pr then
              utils.copy_url(
                build_github_url(
                  string.format("%s/pull/%s", current_review.pull_request.repo, current_review.pull_request.number)
                )
              )
              return
            end
            utils.copy_url(build_github_url(string.format("%s/commit/%s", current_review.pull_request.repo, item.sha)))
          end)

          start_picker {
            name = "Review Commits",
            items = results,
            mappings = mappings,
            preview = function(bufnr, item)
              if item.is_full_pr then
                set_preview_lines(bufnr, {
                  "ENTIRE PULL REQUEST",
                  "",
                  string.format("Repository: %s", current_review.pull_request.repo),
                  string.format("PR Number: %s", current_review.pull_request.number),
                  string.format("Base: %s", current_review.pull_request.left.commit),
                  string.format("Head: %s", current_review.pull_request.right.commit),
                })
                return
              end

              set_preview_lines(bufnr, {
                string.format("Commit: %s", item.sha),
                string.format("Author: %s <%s>", item.commit.author.name, item.commit.author.email),
                string.format("Date: %s", item.commit.author.date),
                "",
                "Message:",
                item.commit.message,
              }, "gitcommit")
            end,
            choose = function(item)
              local right = item.sha
              local left = item.parents and item.parents[1] and item.parents[1].sha or nil
              callback(right, left)
            end,
          }
        end,
      },
    },
  }
end

function M.search(opts)
  opts = opts or {}
  opts.type = opts.type or "ISSUE"

  if type(opts.prompt) == "string" then
    opts.prompt = { opts.prompt }
  end
  if opts.prompt == nil or #opts.prompt == 0 then
    utils.info "No search query provided"
    return
  end

  local results = {}

  for _, prompt in ipairs(opts.prompt) do
    local output = gh.api.graphql {
      query = queries.search,
      fields = { prompt = prompt, type = opts.type },
      jq = ".data.search.nodes",
      opts = { mode = "sync" },
    }

    if not utils.is_blank(output) then
      local decoded = vim.json.decode(output)
      for _, item in ipairs(decoded) do
        if opts.type == "REPOSITORY" then
          item.text = string.format("%s  stars:%s forks:%s", item.nameWithOwner, item.stargazerCount, item.forkCount)
        else
          if item.__typename == "Issue" then
            item.kind = "issue"
          elseif item.__typename == "PullRequest" then
            item.kind = "pull_request"
          elseif item.__typename == "Discussion" then
            item.kind = "discussion"
          end

          local suffix = item.category and (" [" .. item.category.name .. "]") or ""
          item.text = string.format("#%d %s%s", item.number, item.title, suffix)
        end
        results[#results + 1] = item
      end
    end
  end

  if #results == 0 then
    utils.info "No search results found"
    return
  end

  if opts.type == "REPOSITORY" then
    pick_repo_list(opts.preview_title or "GitHub Repository Search", results)
    return
  end

  pick_entity_list(opts.preview_title or "GitHub Search Results", results, { cb = opts.cb })
end

function M.changed_files(buffer)
  if not buffer or not buffer:isPullRequest() then
    return
  end

  gh.api.get {
    "/repos/{repo}/pulls/{number}/files",
    format = { repo = buffer.repo, number = buffer.number },
    paginate = true,
    opts = {
      cb = gh.create_callback {
        success = function(output)
          local results = vim.json.decode(output)
          if #results == 0 then
            utils.error "No changed files found for this pull request"
            return
          end

          for _, file in ipairs(results) do
            local summary = string.format("%s %s", file.status:sub(1, 1):upper(), file.filename)
            if file.additions and file.deletions then
              summary = string.format("%s (+%d/-%d)", summary, file.additions, file.deletions)
            end
            file.text = summary
          end

          start_picker {
            name = buffer.title or "Changed Files",
            items = results,
            preview = function(bufnr, item)
              local lines = {
                string.format("File: %s", item.filename),
                string.format("Status: %s", item.status),
              }
              if item.additions and item.deletions then
                lines[#lines + 1] = string.format("Changes: +%d -%d", item.additions, item.deletions)
              end
              if item.patch then
                lines[#lines + 1] = ""
                lines[#lines + 1] = "Patch:"
                vim.list_extend(lines, vim.split(item.patch, "\n"))
                set_preview_lines(bufnr, lines, "diff")
                return
              end
              set_preview_lines(bufnr, lines)
            end,
            choose = function(item)
              in_target_window(function()
                vim.cmd("edit " .. vim.fn.fnameescape(item.filename))
              end)
            end,
          }
        end,
      },
    },
  }
end

---@param opts {login: string}
function M.repos(opts)
  opts = opts or {}
  utils.info "Fetching repositories (this may take a while) ..."
  gh.api.graphql {
    query = queries.repos,
    f = { login = opts.login },
    paginate = true,
    jq = ".data.repositoryOwner.repositories.nodes",
    opts = {
      cb = gh.create_callback {
        success = function(output)
          local repos = utils.get_flatten_pages(output)
          if #repos == 0 then
            utils.error(string.format("There are no matching repositories for %s.", opts.login))
            return
          end

          for _, repo in ipairs(repos) do
            repo.text = string.format("%s  stars:%s forks:%s", repo.nameWithOwner, repo.stargazerCount, repo.forkCount)
          end

          pick_repo_list("Repositories", repos)
        end,
      },
    },
  }
end

---@param opts {repo?: string, all?: boolean, since?: string}
function M.notifications(opts)
  opts = opts or {}
  local endpoint = "/notifications"
  if opts.repo then
    local owner, name = utils.split_repo(opts.repo)
    endpoint = string.format("/repos/%s/%s/notifications", owner, name)
  end

  gh.api.get {
    endpoint,
    paginate = true,
    F = {
      all = opts.all,
      since = opts.since,
    },
    opts = {
      cb = gh.create_callback {
        success = function(output)
          local notifications_list = vim.json.decode(output)
          if #notifications_list == 0 then
            utils.info "There are no notifications"
            return
          end

          local safe_notifications = {}
          for _, notification in ipairs(notifications_list) do
            notification.subject.number = notification.subject.url:match "%d+$"
            notification.kind = notification.subject.type:lower()
            if notification.kind == "pullrequest" then
              notification.kind = "pull_request"
            end

            if
              notification.kind == "issue"
              or notification.kind == "pull_request"
              or notification.kind == "discussion"
            then
              notification.text = string.format(
                "#%s %s [%s]",
                notification.subject.number,
                notification.subject.title,
                notification.unread and "unread" or "read"
              )
              safe_notifications[#safe_notifications + 1] = notification
            end
          end

          if #safe_notifications == 0 then
            utils.info "There are no supported notifications"
            return
          end

          local cfg = octo_config.values
          local mappings = {}
          add_mapping(mappings, "open_in_browser", cfg.picker_config.mappings.open_in_browser.lhs, function(item)
            open_notification_in_browser(item)
          end)
          add_mapping(mappings, "copy_url", cfg.picker_config.mappings.copy_url.lhs, function(item)
            notifications.copy_notification_url(item)
          end)

          start_picker {
            name = opts.repo and (opts.repo .. " Notifications") or "GitHub Notifications",
            items = safe_notifications,
            mappings = mappings,
            preview = function(bufnr, item)
              local owner, name = utils.split_repo(item.repository.full_name)
              local preview = notifications.get_preview_fn(item.kind)
              if preview == nil then
                set_preview_lines(bufnr, { item.text })
                return
              end
              set_preview_lines(bufnr, { "Loading..." })
              notifications.fetch_preview(owner, name, item.subject.number, item.kind, function(obj)
                if not vim.api.nvim_buf_is_valid(bufnr) then
                  return
                end
                preview(obj, bufnr)
              end)
            end,
            choose = function(item)
              in_target_window(function()
                utils.get(item.kind, tonumber(item.subject.number), item.repository.full_name)
              end)
            end,
          }
        end,
      },
    },
  }
end

function M.assignees(cb)
  local buffer = utils.get_current_buffer()
  if not buffer then
    utils.error "No buffer found"
    return
  end

  local query, key
  if buffer:isIssue() then
    query = queries.issue_assignees
    key = "issue"
  elseif buffer:isPullRequest() then
    query = queries.pull_request_assignees
    key = "pullRequest"
  else
    utils.error "Assignees picker only works in issue or pull request buffers"
    return
  end

  utils.info "Fetching assignees..."
  gh.api.graphql {
    query = query,
    F = { owner = buffer.owner, name = buffer.name, number = buffer.number },
    opts = {
      cb = gh.create_callback {
        success = function(output)
          local resp = vim.json.decode(output)
          local assignees = resp.data.repository[key].assignees.nodes
          if #assignees == 0 then
            utils.info("No assignees found for this " .. key)
            return
          end

          for _, assignee in ipairs(assignees) do
            assignee.text = assignee.isViewer and (assignee.login .. " (you)") or assignee.login
          end

          start_picker {
            name = "Assignees",
            items = assignees,
            preview = function(bufnr, item)
              set_preview_lines(bufnr, {
                "Assignee: " .. item.login,
                "User ID: " .. item.id,
              })
            end,
            choose = function(item)
              cb(item.id)
            end,
          }
        end,
      },
    },
  }
end

function M.users(cb)
  local cfg = octo_config.values
  local repo = utils.get_remote_name()
  local owner, name = nil, nil
  if not utils.is_blank(repo) then
    owner, name = utils.split_repo(repo)
  end

  local query = nil
  local fields = nil
  if cfg.users == "search" then
    vim.fn.inputsave()
    local prompt = vim.fn.input "Search GitHub users: "
    vim.fn.inputrestore()
    if utils.is_blank(prompt) then
      return
    end
    query = queries.users
    fields = { prompt = prompt }
  elseif cfg.users == "assignable" then
    if owner == nil or name == nil then
      utils.error "Cannot find repo"
      return
    end
    query = queries.assignable_users
    fields = { owner = owner, name = name }
  else
    if owner == nil or name == nil then
      utils.error "Cannot find repo"
      return
    end
    query = queries.mentionable_users
    fields = { owner = owner, name = name }
  end

  local output = gh.api.graphql {
    query = query,
    F = fields,
    paginate = true,
    jq = ".",
    opts = { mode = "sync" },
  }

  if utils.is_blank(output) then
    utils.info "No users found"
    return
  end

  local items = {}
  local responses = utils.get_pages(output)
  for _, resp in ipairs(responses) do
    local nodes = {}
    if cfg.users == "assignable" then
      nodes = resp.data.repository.assignableUsers.nodes
    elseif cfg.users == "mentionable" then
      nodes = resp.data.repository.mentionableUsers.nodes
    else
      nodes = resp.data.search.nodes
    end

    for _, user in ipairs(nodes) do
      if type(user) == "table" and not user.teams then
        user.kind = "user"
        user.text = user.login
        items[#items + 1] = user
      elseif type(user) == "table" and user.teams and user.teams.totalCount > 0 then
        for _, team in ipairs(user.teams.nodes) do
          items[#items + 1] = {
            id = team.id,
            kind = "team",
            org = user.login,
            name = team.name,
            text = string.format("%s (%s org)", team.name, user.login),
          }
        end
      end
    end
  end

  if #items == 0 then
    utils.info "No users found"
    return
  end

  start_picker {
    name = "Select Users",
    items = items,
    preview = function(bufnr, item)
      if item.kind == "team" then
        set_preview_lines(bufnr, {
          "Team: " .. item.name,
          "Org: " .. item.org,
          "ID: " .. item.id,
        })
        return
      end

      set_preview_lines(bufnr, {
        "User: " .. item.login,
        "ID: " .. item.id,
      })
    end,
    choose = function(item)
      cb(item.id)
    end,
  }
end

function M.labels(opts)
  opts = opts or {}
  local repo = opts.repo or utils.get_remote_name()
  local owner, name = utils.split_repo(repo)

  utils.info "Fetching labels..."
  gh.api.graphql {
    query = queries.labels,
    F = { owner = owner, name = name },
    opts = {
      cb = gh.create_callback {
        success = function(output)
          local resp = vim.json.decode(output)
          local labels = resp.data.repository.labels.nodes
          if #labels == 0 then
            utils.info "No labels found"
            return
          end

          for _, label in ipairs(labels) do
            local desc = utils.is_blank(label.description) and "" or (" - " .. label.description)
            label.text = label.name .. desc
          end

          start_picker {
            name = "Labels",
            items = labels,
            preview = function(bufnr, item)
              set_preview_lines(bufnr, {
                "Label: " .. item.name,
                "Color: #" .. item.color,
                "",
                item.description or "",
              })
            end,
            choose = function(item)
              if opts.cb then
                opts.cb { item }
              end
            end,
            choose_marked = function(items)
              if opts.cb and #items > 0 then
                opts.cb(items)
              end
            end,
          }
        end,
      },
    },
  }
end

function M.assigned_labels(opts)
  opts = opts or {}
  local buffer = utils.get_current_buffer()
  if not buffer then
    utils.error "No buffer found"
    return
  end

  local query, key
  if buffer:isIssue() then
    query = queries.issue_labels
    key = "issue"
  elseif buffer:isPullRequest() then
    query = queries.pull_request_labels
    key = "pullRequest"
  elseif buffer:isDiscussion() then
    query = queries.discussion_labels
    key = "discussion"
  else
    utils.error "Assigned labels picker only works in issue, PR, or discussion buffers"
    return
  end

  utils.info "Fetching assigned labels..."
  gh.api.graphql {
    query = query,
    F = { owner = buffer.owner, name = buffer.name, number = buffer.number },
    opts = {
      cb = gh.create_callback {
        success = function(output)
          local resp = vim.json.decode(output)
          local labels = resp.data.repository[key].labels.nodes
          if #labels == 0 then
            utils.info "No assigned labels found"
            return
          end

          for _, label in ipairs(labels) do
            local desc = utils.is_blank(label.description) and "" or (" - " .. label.description)
            label.text = label.name .. desc
          end

          start_picker {
            name = "Assigned Labels",
            items = labels,
            preview = function(bufnr, item)
              set_preview_lines(bufnr, {
                "Label: " .. item.name,
                "Color: #" .. item.color,
                "",
                item.description or "",
              })
            end,
            choose = function(item)
              if opts.cb then
                opts.cb { item }
              end
            end,
            choose_marked = function(items)
              if opts.cb and #items > 0 then
                opts.cb(items)
              end
            end,
          }
        end,
      },
    },
  }
end

function M.milestones(opts)
  opts = opts or {}
  if opts.cb == nil then
    utils.error "Callback action on milestone is required"
    return
  end

  local repo = opts.repo or utils.get_remote_name()
  local owner, name = utils.split_repo(repo)
  gh.api.graphql {
    query = queries.open_milestones,
    fields = {
      owner = owner,
      name = name,
      n_milestones = 25,
    },
    opts = {
      cb = gh.create_callback {
        success = function(output)
          local resp = vim.json.decode(output)
          local milestones = resp.data.repository.milestones.nodes
          if #milestones == 0 then
            utils.error(string.format("There are no open milestones in %s.", repo))
            return
          end

          for _, milestone in ipairs(milestones) do
            local desc = utils.is_blank(milestone.description) and "" or (" - " .. milestone.description)
            milestone.text = milestone.title .. desc
          end

          start_picker {
            name = "Milestones",
            items = milestones,
            preview = function(bufnr, item)
              set_preview_lines(bufnr, {
                item.title,
                "",
                item.description or "",
                "",
                item.url,
              })
            end,
            choose = opts.cb,
          }
        end,
      },
    },
  }
end

---@type octo.PickerModule
M.picker = {
  actions = M.actions,
  assigned_labels = M.assigned_labels,
  assignees = M.assignees,
  changed_files = M.changed_files,
  comment_edits = M.comment_edits,
  commits = M.commits,
  discussions = M.discussions,
  issue_templates = M.issue_templates,
  issues = M.issues,
  labels = M.labels,
  milestones = M.milestones,
  notifications = M.notifications,
  prs = M.pull_requests,
  releases = M.releases,
  repos = M.repos,
  review_commits = M.review_commits,
  search = M.search,
  users = M.users,
}

return M
