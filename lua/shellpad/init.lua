local M = {}

-- TODO: rename :Shell to :Shellpad
-- TODO: This doesn't seem to work `:Shell rg -l .` or any other rg command.
-- TODO: Idea: allow defining custom key mappings in the buffer, e.g. pressing `<cr>` or `k` in a line in the output of `ps` could kill the process.
--       But I wouldn't want to define than mapping each time. Maybe a global command-to-mapping matcher? But `ps` may be run with different flags,
--       displaying different columns, so building a general purpose `ps` matcher is not trivial.
--       Perhaps one way to do that is to declare a new command and pass the selected line(s) to it.

local JumpDown = function(bufnr)
  local curr_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_call(bufnr, function()
    if bufnr ~= curr_buf or vim.api.nvim_get_mode().mode ~= 'i' then
      vim.cmd('keepjumps normal! G')
    end
  end)
end

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
--   StopShell (Ctrl-C, BufHidden) deliberately does NOT mark the command
--   as abandoned, so the "[Process exited]" message still appears when the
--   user stops a command manually.
-- opts.output_sink (optional): function(fd, data)
--   When provided, all output (banner if any, stdout, stderr, and the final
--   "[Process exited with code N]" line) is forwarded to this callback
--   instead of being written into opts.buf as buffer text. fd is 1 for
--   stdout-style writes, 2 for stderr. The notebook flow uses this to
--   render output into extmark virt_lines, leaving the buffer text alone.
--
--   When omitted, the legacy behavior runs: output is appended to opts.buf
--   as real text, the "shellpad: highlight {...}" modeline rules are
--   honored, and the cursor follows the tail when at end-of-buffer.
local genericStart = function(opts)
  local shell_command = opts.shell_command
  local buf = opts.buf
  local follow = opts.follow
  local on_exit_cb = opts.on_exit
  local is_command_abandoned = opts.is_command_abandoned or function() return false end
  local output_sink = opts.output_sink

  if output_sink == nil then
    local output_prefix = ""
    M.hl_clear_matchers(buf, "shellpad")
    -- NOTE: This is commented out because it slows down Neovim when output is very large
    -- M.hl_add_matcher(buf, "shellpad_modeline", 0, "^shellpad: .\\+", "#666666", "NONE")

    local modeline_counter = 0
    local insert_output = function(bufnr, fd, data)
      if vim.api.nvim_buf_is_loaded(bufnr) == false then
        return
      end

      local at_last_line = false
      -- NOTE: if we don't use nvim_buf_call(), we
      -- get the current position of the cursor in
      -- the current buffer, which might be different
      -- from the buffer we are writing to.
      vim.api.nvim_buf_call(bufnr, function()
        at_last_line = vim.fn.line('.') == vim.fn.line('$')
      end)

      for i,line in ipairs(data) do
        -- when printing binary bytes, the stderr or stdout might
        -- include \n, which is not splitted by vim. This might be
        -- a NeoVim bug, but to be fair, nothing was printed for
        -- those strange bytes when the command was run in the
        -- terminal outside NeoVim.
        data[i] = output_prefix .. string.gsub(line, "\n", "\\n")
      end

      local last_lines = vim.api.nvim_buf_get_lines(bufnr, -2, -1, false)
      -- complete the previous line (see channel.txt)
      local first_line = last_lines[1] .. data[1]

      -- append (last item may be a partial line, until EOF)
      local lines = vim.list_extend(
        {first_line},
        vim.list_slice(data, 2, #data)
      )
      vim.api.nvim_buf_set_lines(bufnr, -2, -1, false, lines)

      local number_of_lines = vim.api.nvim_buf_line_count(bufnr)
      for i,_ in ipairs(lines) do
        if fd == 2 then
          vim.api.nvim_buf_add_highlight(bufnr, -1, "shellpad_stderr", number_of_lines - #lines + i - 1, 0, -1)
        elseif string.match(lines[i], "^shellpad: ") then
          vim.api.nvim_buf_add_highlight(bufnr, -1, "shellpad_modeline", number_of_lines - #lines + i - 1, 0, -1)
        end
      end

      -- check for lines matching "^shellpad: "
      -- TODO: move this to vim.api.nvim_create_autocmd? But I guess this is more efficient
      for _,line in ipairs(lines) do
        local captured_modeline = string.match(line, "^shellpad: (.+)")
        if captured_modeline then
          if string.sub(captured_modeline, 1, #"highlight {") == "highlight {" then
            modeline_counter = modeline_counter + 1
            local matcher_yaml_std = string.sub(captured_modeline, #"highlight {")
            local matcher_json_str = vim.fn.system("yq -o json", matcher_yaml_std)
            local m = vim.fn.json_decode(matcher_json_str)
            M.hl_add_matcher(bufnr, string.format("rule%s", modeline_counter), modeline_counter, m.re, m.fg, m.bg)
          end
        end
      end

      vim.api.nvim_buf_set_option(bufnr, 'modified', false)

      if at_last_line and (follow or number_of_lines > 2) then
        -- Only follow the output if the cursor is at the end of the buffer
        -- this allows users to navigate the buffer without being interrupted
        -- and follow the output again by going to the last line.
        --
        -- Also, only follow if the buffer has more than 2 lines, to avoid
        -- following the output at the start by default.
        JumpDown(bufnr)
      end
    end

    output_sink = function(fd, data)
      insert_output(buf, fd, data)
    end
  end

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

M.setup = function(_)
  local buf_info = {}
  local last_win = nil
  local last_buf = nil

  local commandline_hl_ns = vim.api.nvim_create_namespace('shellpad_commandline')

  local highlight_basics = function(bfr)
    vim.api.nvim_buf_clear_namespace(bfr, commandline_hl_ns, 0, 1)
    vim.api.nvim_buf_add_highlight(bfr, commandline_hl_ns, "shellpad_commandline", 0, 0, -1)
  end

  local StopShell = function(buf)
    local channel_id = buf_info[buf].channel_id
    if channel_id ~= nil then
      vim.fn.jobstop(channel_id)
      buf_info[buf].channel_id = nil
      JumpDown(buf)
    end
  end

  local StartShell = function(parsed_command)
      local current_buf = vim.api.nvim_get_current_buf()
      local reuse = buf_info[current_buf] ~= nil
      local buf

      if reuse then
        buf = current_buf
        -- We are about to overwrite this buffer with a new command. The
        -- previous command's callbacks may still fire after jobstop (they
        -- run on the main loop, not synchronously), so we record its
        -- channel_id in abandoned_commands. genericStart's
        -- is_command_abandoned check then drops any late
        -- stdout/stderr/exit from that command instead of letting it
        -- pollute the new buffer state.
        if buf_info[buf].channel_id ~= nil then
          buf_info[buf].abandoned_commands[buf_info[buf].channel_id] = true
          vim.fn.jobstop(buf_info[buf].channel_id)
          buf_info[buf].channel_id = nil
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
      else
        buf = vim.api.nvim_create_buf(false, true)
        vim.cmd.buffer(buf)
        vim.cmd.setlocal("number")
      end
      last_win = vim.api.nvim_get_current_win()
      last_buf = buf

      local tmpfile = vim.fn.tempname()

      -- Read $HOME/shellpad.lua and save it to a temporary file
      local shellpad_config_path = vim.fn.expand("$HOME") .. "/shellpad.lua"

      if vim.fn.filereadable(shellpad_config_path) == 1 then
        local shellpad_lua_config = dofile(shellpad_config_path)
        local shellrc = shellpad_lua_config.shellrc
        local shellrc_lines = vim.split(shellrc, "\n", { plain = true })
        vim.fn.writefile(shellrc_lines , tmpfile)
      end

      vim.fn.writefile({parsed_command.shell_command}, tmpfile, "a")

      if not reuse then
        buf_info[buf] = {
          abandoned_commands = {},
        }
      end

      local channel_id = genericStart({
        follow = parsed_command.follow,
        shell_command = string.format([[
        # Run the command:
        . %s
        EXIT_CODE=$?

        # Sleep a little after the command, until https://github.com/neovim/neovim/issues/26543 is fixed
        sleep 0.5s
        exit $EXIT_CODE
        ]], tmpfile),
        banner = parsed_command.full_command,
        on_exit = function()
          if buf_info[buf] ~= nil then
            buf_info[buf].channel_id = nil
          end
          parsed_command.on_exit()
        end,
        is_command_abandoned = function(cid)
          return buf_info[buf] ~= nil and buf_info[buf].abandoned_commands[cid] == true
        end,
        buf = buf,
      })

      buf_info[buf].channel_id = channel_id
      buf_info[buf].full_command = parsed_command.full_command
      buf_info[buf].shell_command = parsed_command.shell_command

      highlight_basics(buf)

      if not reuse then
        vim.api.nvim_create_autocmd({"BufHidden"}, {
          buffer = buf,
          callback = function()
            StopShell(buf)
          end,
        })

        vim.api.nvim_create_autocmd({"BufWipeout"}, {
          buffer = buf,
          callback = function()
            buf_info[buf] = nil
          end,
        })

        vim.api.nvim_create_autocmd({"TextChanged", "TextChangedI"}, {
          buffer = buf,
          callback = function()
            highlight_basics(buf)
          end,
        })

        vim.keymap.set('n', '<C-c>', function() StopShell(buf) end, { noremap = true, desc = "shellpad.nvim: Stop process", buffer = buf })
        vim.keymap.set('n', '<CR>', function()
          -- get current line:
          local line = vim.api.nvim_get_current_line()
          if line == "" then
            return
          end
          -- if it is not the first line, return
          if vim.fn.line('.') ~= 1 then
            return
          end
          -- Start a new shell with the current line as the command
          local command = string.format("Shell %s", line)
          vim.cmd(command)
          vim.fn.histadd("cmd", command)
        end, { noremap = true, desc = "shellpad.nvim: Run command in current line", buffer = buf })

        vim.keymap.set('v', '<CR>', function()
          vim.cmd('normal! "vy') -- Yank selection into the "v register
          local full_command = vim.fn.getreg('v')
          full_command = string.gsub(full_command, "\n", " ")

          local command = string.format("Shell %s", full_command)
          vim.cmd(command)
          vim.fn.histadd("cmd", command)
        end, { noremap = true, desc = "shellpad.nvim: Run command visually selected", buffer = buf })
      end
  end

  local ParseCommand = function(full_command)
    -- This is very basic parsing, but it should be enough for now.
    local parsed_command = {
      full_command = full_command,
      shell_command = full_command,
      on_exit = function() end,
      follow = false,
      action = "ACTION_START",
    }
    local words = vim.fn.split(parsed_command.full_command, " ")
    if words[1] == "--no-follow" then
      parsed_command.follow = false
      parsed_command.shell_command = table.concat(vim.list_slice(words, 2, #words), " ")
    elseif words[1] == "--follow" then
      parsed_command.follow = true
      parsed_command.shell_command = table.concat(vim.list_slice(words, 2, #words), " ")
    elseif words[1] == "--stop" then
      parsed_command.action = "ACTION_STOP"
    elseif words[1] == "--edit" then
      parsed_command.action = "ACTION_EDIT"
    elseif words[1] == "--last" then
      parsed_command.action = "ACTION_RERUN_LAST"
    elseif words[1] == "--lua" then
      local lua_command = table.concat(vim.list_slice(words, 2, #words), " ")
      local config = vim.fn.luaeval(lua_command) or {}
      parsed_command.shell_command = config.command or ""
      parsed_command.on_exit = config.on_exit or function() end
    end
    return parsed_command
  end

  vim.api.nvim_create_user_command("Shell", function(opts)
    local parsed_command = ParseCommand(opts.fargs[1])

    if parsed_command.action == "ACTION_STOP" then
      StopShell(parsed_command.buf)
    elseif parsed_command.action == "ACTION_EDIT" then
      vim.api.nvim_feedkeys(':Shell ' .. buf_info[parsed_command.buf].full_command, "n", true)
    elseif parsed_command.action == "ACTION_RERUN_LAST" then
      if last_win == nil then
        return
      end
      local curr_win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_is_valid(last_win) == false then
        -- if win does not exist, create a new one
        vim.cmd.vsplit()
      else
        vim.api.nvim_set_current_win(last_win)
      end
      parsed_command.full_command = buf_info[last_buf].full_command
      parsed_command.shell_command = buf_info[last_buf].shell_command
      StartShell(parsed_command)

      -- back to the current win
      vim.api.nvim_set_current_win(curr_win)
    elseif parsed_command.action == "ACTION_START" then
      -- :Shell <cmd> always produces notebook output. If the current buffer
      -- is a notebook, append a new cell to it; otherwise create a fresh
      -- notebook and run the command there.
      local current_buf = vim.api.nvim_get_current_buf()
      local notebook = require("shellpad.notebook")
      local target_buf
      if vim.b[current_buf].shellpad_notebook == 1 then
        target_buf = current_buf
      else
        target_buf = notebook.open_new()
      end
      notebook.append_and_run(target_buf, parsed_command.shell_command)
    end
  end, { nargs = 1 }) -- NOTE: removed "file" because it was removing the backslashes

  vim.api.nvim_create_autocmd({"BufReadCmd"}, {
    pattern = "Shell://*",
    callback = function(event)
      -- a buffer is created later by StartShell(), so delete event.buf
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

-- Function to clear syntax groups and matches with a specific prefix
M.hl_clear_matchers = function(bufnr, prefix)
  -- Get all current syntax groups
  local syntax_groups = vim.fn.getcompletion(prefix, 'highlight')
  vim.api.nvim_buf_call(bufnr, function()
    for _, group in ipairs(syntax_groups) do
      vim.cmd('syntax clear ' .. group)
    end
    -- Clear matches added with `matchadd` (no specific prefix tracking, so reset all)
    vim.cmd('call clearmatches()')
  end)

  -- Add the default highlights
  vim.api.nvim_buf_call(bufnr, function()
    vim.api.nvim_set_hl(0, "shellpad_stderr", { bg = "#382828" })
    vim.api.nvim_set_hl(0, "shellpad_modeline", { bg = "NONE", fg = "#666666" })
    vim.api.nvim_set_hl(0, 'shellpad_commandline', { bg = "#282c34", fg = "#61afef", bold = true })
  end)
end

M.hl_add_matcher = function(bufnr, name, priority, re, fg, bg)
  local syntaxName = string.format('shellpad_%sSyntax', name)
  local highlightName = string.format('shellpad_%sHighlight', name)
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd(string.format('highlight %s guifg=%s guibg=%s', highlightName, fg, bg))
    vim.cmd(string.format([[
      syntax match %s /%s/
      highlight link %s %s
    ]], syntaxName, re, syntaxName, highlightName))
    vim.fn.matchadd(highlightName, re, priority)
  end)
end

return M
