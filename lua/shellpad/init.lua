local M = {}

-- TODO: rename :Shell to :Shellpad
-- TODO: Idea: allow defining custom key mappings in the buffer, e.g. pressing
--       `<cr>` or `k` in a line in the output of `ps` could kill the process.
--       But I wouldn't want to define that mapping each time. Maybe a global
--       command-to-mapping matcher? But `ps` may be run with different flags,
--       displaying different columns, so building a general purpose `ps`
--       matcher is not trivial. Perhaps one way to do that is to declare a
--       new command and pass the selected line(s) to it.

-- opts.is_command_abandoned (optional): function(channel_id) -> bool
--   Lets the caller disown a previously started command (identified by its
--   channel_id) after it has been stopped. The buffer and window are not
--   what gets abandoned, only the command running inside the buffer.
--
--   When the same buffer is reused for a new command, the previous command
--   is jobstop'd but its on_stdout / on_stderr / on_exit callbacks still
--   fire asynchronously on the main loop. Without this gate, those late
--   callbacks would write stale output (and a spurious "[Process exited]"
--   line) into the buffer that now belongs to the new command. Returning
--   true for the old channel_id tells genericStart to silently drop those
--   callbacks.
--
-- opts.output_sink (required): function(fd, data)
--   All output (banner if any, stdout, stderr, and the final
--   "[Process exited with code N]" line) is forwarded to this callback.
--   fd is 1 for stdout-style writes, 2 for stderr.
local genericStart = function(opts)
  local shell_command = opts.shell_command
  local on_exit_cb = opts.on_exit or function() end
  local is_command_abandoned = opts.is_command_abandoned or function() return false end
  local output_sink = opts.output_sink

  if opts.banner ~= nil then
    output_sink(1, {opts.banner, ""})
  end

  local channel_id
  channel_id = vim.fn.jobstart(shell_command, {
    pty = false,
    detach = false,
    stdout_buffered = false,
    stderr_buffered = false,

    on_stdout = function(_, data)
      if is_command_abandoned(channel_id) then return end
      output_sink(1, data)
    end,

    on_stderr = function(_, data)
      if is_command_abandoned(channel_id) then return end
      output_sink(2, data)
    end,

    on_exit = function(_, code)
      if is_command_abandoned(channel_id) then return end
      output_sink(1, { string.format("[Process exited with code %d]", code) })
      on_exit_cb()
    end
  })
  return channel_id
end

M.genericStart = genericStart

-- Returns the plugin's short git commit hash (e.g. "6481b37"), or "unknown"
-- if shellpad was not installed from a git checkout.
M.version = function()
  -- This file is at <plugin_root>/lua/shellpad/init.lua, so the plugin root
  -- is three filename components up.
  local source = debug.getinfo(1, 'S').source
  local path = source:sub(2)  -- strip leading "@"
  local plugin_dir = vim.fn.fnamemodify(path, ":h:h:h")

  local out = vim.fn.systemlist({ "git", "-C", plugin_dir, "rev-parse", "--short", "HEAD" })
  if vim.v.shell_error == 0 and out[1] and out[1] ~= "" then
    return out[1]
  end
  return "unknown"
end

M.setup = function(_)
  vim.api.nvim_create_user_command("Shell", function(opts)
    local command = opts.fargs[1]

    if command == "--version" then
      print("shellpad.nvim " .. M.version())
      return
    end

    local current_buf = vim.api.nvim_get_current_buf()
    local notebook = require("shellpad.notebook")
    local target_buf
    if vim.b[current_buf].shellpad_notebook == 1 then
      target_buf = current_buf
    else
      target_buf = notebook.open_new()
    end
    notebook.append_and_run(target_buf, command)
  end, { nargs = 1 })

  vim.api.nvim_create_autocmd({"BufReadCmd"}, {
    pattern = "Shell://*",
    callback = function(event)
      -- nvim's edit machinery creates a buffer for the Shell:// pattern. We
      -- delete it and route to :Shell, which creates a notebook or appends
      -- to the current one.
      vim.api.nvim_buf_delete(event.buf, { force = true })

      local filename = event.file
      local prefix_length = string.len("Shell://")
      local full_command = string.sub(filename, prefix_length + 1)

      vim.cmd(string.format("Shell %s", full_command))
    end,
    group = vim.api.nvim_create_augroup('shellpad', { clear = true }),
  })

  require("shellpad.notebook").setup()
end

M.command_history = function(opts)
  local history_count = vim.fn.histnr("cmd")
  local results = {}
  for i = history_count, 1, -1 do
    table.insert(results, vim.fn.histget("cmd", i))
  end

  local pickers = require "telescope.pickers"
  local finders = require "telescope.finders"
  local actions = require "telescope.actions"
  local conf = require("telescope.config").values

  -- The rest of this function is copied from Telescope's command_history function.
  -- The reason we are not using Telescope's command_history is because Telescope uses `:history cmd` which truncates items.
  -- https://sourcegraph.com/github.com/nvim-telescope/telescope.nvim@0.1.6/-/blob/lua/telescope/builtin/__internal.lua?L566-567
  pickers
    .new(opts, {
      prompt_title = "Command History",
      finder = finders.new_table(results),
      sorter = conf.generic_sorter(opts),

      attach_mappings = function(_, map)
        actions.select_default:replace(actions.set_command_line)
        map({ "i", "n" }, "<C-e>", actions.edit_command_line)

        -- TODO: Find a way to insert the text... it seems hard.
        -- map('i', '<C-i>', actions.insert_value, { expr = true })

        return true
      end,
    })
    :find()
end

-- This sorter/matcher will preserve the order of the results, while still
-- allowing for fuzzy matching. This is useful for the command history search,
-- where we want to show the most recent commands first, but still allow for
-- fuzzy matching.
M.telescope_history_search = function()
  local sorters = require "telescope.sorters"
  local FILTERED = -1
  local preserve_order_fuzzy_sorter = function(sorter_opts)
    sorter_opts = sorter_opts or {}
    sorter_opts.ngram_len = 2

    local fuzzy_sorter = sorters.get_fzy_sorter(sorter_opts)

    return sorters.new {
      scoring_function = function(_, prompt, line, entry, cb_add, cb_filter)
        -- Only match commands that start with "Shell"
        if not string.match(line, "^Shell") then
          return FILTERED
        end

        local base_score = fuzzy_sorter:scoring_function(prompt, line, cb_add, cb_filter)

        if base_score == FILTERED then
          return FILTERED
        else
          return entry.index
        end
      end,
      highlighter = fuzzy_sorter.highlighter,
    }
  end

  return function()
    M.command_history({sorter = preserve_order_fuzzy_sorter()})
  end
end

return M
