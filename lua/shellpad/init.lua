local M = {}

-- TODO: rename :Shell to :Shellpad
-- TODO: This doesn't seem to work `:Shell rg -l .` or any other rg command.

-- This is based on https://github.com/Robitx/gp.nvim/commit/5ccf0d28c6fbc206ebd853a9a2f1b1ab9878cdab
local undojoin = function(buf)
  if not buf or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  vim.api.nvim_buf_call(buf, function()
    local status, result = pcall(vim.cmd.undojoin)
    if not status then
      if result:match("E790") then
        return
      end
      M.error("Error running undojoin: " .. vim.inspect(result))
    end
  end)
end

local JumpDown = function(bufnr)
  local curr_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_call(bufnr, function()
    if bufnr ~= curr_buf or vim.api.nvim_get_mode().mode ~= 'i' then
      vim.cmd('keepjumps normal! G')
    end
  end)
end

local genericStart = function(opts)
  local shell_command = opts.shell_command
  local buf = opts.buf
  local follow = opts.follow
  local on_exit_cb = opts.on_exit

  local output_prefix = ""
  M.hl_clear_matchers(buf, "shellpad")
  -- NOTE: This is commented out because it slows down Neovim when output is very large
  -- M.hl_add_matcher(buf, "shellpad_modeline", 0, "^shellpad: .\\+", "#666666", "NONE")

  local modeline_counter = 0
  local insert_output = function(bufnr, fd, data)
    undojoin(bufnr)
    -- check if bufnr still exists
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
        modeline_counter = modeline_counter + 1
        local matcher_yaml_std = string.sub(captured_modeline, 11)
        local matcher_json_str = vim.fn.system("yq -o json", matcher_yaml_std)
        local m = vim.fn.json_decode(matcher_json_str)
        M.hl_add_matcher(bufnr, string.format("rule%s", modeline_counter), modeline_counter, m.re, m.fg, m.bg)
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

  -- TODO: add a flag for not showing the banner
  insert_output(buf, 1, {opts.banner, ""})

  return vim.fn.jobstart(shell_command, {
    pty = false,
    detach = false,
    stdout_buffered = false,
    stderr_buffered = false,

    on_stdout = function(_, data)
      insert_output(buf, 1, data)
    end,

    on_stderr = function(_, data)
      insert_output(buf, 2, data)
    end,

    on_exit = function(_, code)
      local exit_lines = {
        string.format("[Process exited with code %d]", code),
      }
      insert_output(buf, 1, exit_lines)
      on_exit_cb()
    end
  })
end

M.setup = function(_)
  local buf_info = {}
  local last_win = nil
  local last_buf = nil

  local StopShell = function(buf)
    local channel_id = buf_info[buf].channel_id
    if channel_id ~= nil then
      vim.fn.jobstop(channel_id)
      buf_info[buf].channel_id = nil
      JumpDown(buf)
    end
  end

  local StartShell = function(parsed_command)
      -- create new buffer
      local buf = vim.api.nvim_create_buf(false, true)
      vim.cmd.buffer(buf)
      vim.cmd.setlocal("number")
      last_win = vim.api.nvim_get_current_win()
      last_buf = buf

      local tmpfile = vim.fn.tempname()
      vim.fn.writefile({parsed_command.shell_command}, tmpfile)

      local channel_id = genericStart({
        follow = parsed_command.follow,
        -- Sleep a little after the command, until https://github.com/neovim/neovim/issues/26543 is fixed
        shell_command = string.format([[
        if [ -e "$HOME/.shellpad" ]; then
          . "$HOME/.shellpad"
        fi
        . %s
        EXIT_CODE=$?
        sleep 0.5s
        exit $EXIT_CODE
        ]], tmpfile),
        banner = parsed_command.full_command,
        on_exit = function()
          buf_info[buf].channel_id = nil
          parsed_command.on_exit()
        end,
        buf = buf,
      })

      buf_info[buf] = {
        channel_id = channel_id,
        full_command = parsed_command.full_command,
        shell_command = parsed_command.shell_command,
      }
      vim.api.nvim_create_autocmd({"BufHidden"}, {
        buffer = buf,
        callback = function()
          StopShell(buf)
        end,
      })

      local commandline_hl_ns = vim.api.nvim_create_namespace('shellpad_commandline')

      local highlight_basics = function(buf)
        vim.api.nvim_buf_clear_namespace(buf, commandline_hl_ns, 0, 1)
        vim.api.nvim_buf_add_highlight(buf, commandline_hl_ns, "shellpad_commandline", 0, 0, -1)
      end

      highlight_basics(buf)
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
        -- Start a new shell with the current line as the command
        local command = string.format("Shell %s", line)
        vim.cmd(command)
        vim.fn.histadd("cmd", command)
      end, { noremap = true, desc = "shellpad.nvim: Run command in current line", buffer = buf })
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
      StartShell(parsed_command)
    end
  end, { nargs = 1 }) -- NOTE: removed "file" because it was removing the backslashes

  vim.api.nvim_create_autocmd({"BufReadCmd"}, {
    pattern = "Shell://*",
    callback = function()
      -- Convert buffer to a scratch buffer
      vim.cmd("setlocal buftype=nofile")

      local filename = vim.fn.expand("<afile>")
      local prefix_length = string.len("Shell://")
      local full_command = string.sub(filename, prefix_length + 1)
      vim.cmd(string.format("Shell %s", full_command))
    end,
    group = vim.api.nvim_create_augroup('shellpad', { clear = true }),
  })
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
