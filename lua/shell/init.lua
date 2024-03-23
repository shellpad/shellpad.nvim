local M = {}

local StopShell = function(channel_id)
  if channel_id ~= nil then
    vim.fn.jobstop(channel_id)
  end
end

local StartShell = function(opts)
  local command = opts.command
  local buf = opts.buf
  local follow = opts.follow

  local output_prefix = ""
  local insert_output = function(bufnr, data)
    -- check if bufnr still exists
    if vim.api.nvim_buf_is_loaded(bufnr) == false then
      return
    end

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
    vim.api.nvim_buf_set_lines(bufnr, -2, -1, false, vim.list_extend(
      {first_line},
      vim.list_slice(data, 2, #data)
    ))

    vim.api.nvim_buf_set_option(bufnr, 'modified', false)

    -- make sure the end of the buffer is visible:
    if follow then
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd('normal! G')
      end)
    end
  end

  return vim.fn.jobstart(command, {
    pty = false,
    detach = false,
    stdout_buffered = false,
    stderr_buffered = false,

    on_stdout = function(_, data)
      insert_output(buf, data)
    end,

    on_stderr = function(_, data)
      insert_output(buf, data)
    end,

    on_exit = function(_, code)
      local exit_lines = {
        string.format("[Process exited with code %d]", code),
      }
      insert_output(buf, exit_lines)
    end
  })
end

M.setup = function()
  local buf_chan_map = {}
  vim.api.nvim_create_user_command("Shell", function(opts)
    local command = opts.fargs[1]
    local follow = true

    local words = vim.fn.split(command, " ")
    if words[1] == "--no-follow" then
      follow = false
      command = table.concat(vim.list_slice(words, 2, #words), " ")
    elseif words[1] == "--stop" then
      local buf = vim.api.nvim_get_current_buf()
      local channel_id = buf_chan_map[buf]
      StopShell(channel_id)
      return
    end

    local buf = vim.api.nvim_create_buf(false, false)
    vim.cmd.buffer(buf)

    local channel_id = StartShell({
      follow = follow,
      -- Sleep a little after the command, until https://github.com/neovim/neovim/issues/26543 is fixed
      command = string.format("%s ; EXIT_CODE=$? ; sleep 0.5s ; exit $EXIT_CODE", command),
      buf = buf,
    })

    buf_chan_map[buf] = channel_id
    vim.api.nvim_create_autocmd({"WinClosed"}, {
      buffer = buf,
      callback = function()
        StopShell(channel_id)
      end,
    })
  end, { nargs = 1 })
end

M.telescope_search = function(opts)
  local pickers = require "telescope.pickers"
  local finders = require "telescope.finders"
  local actions = require "telescope.actions"
  local conf = require("telescope.config").values

  -- This is copied from https://github.com/nvim-telescope/telescope.nvim/pull/2132
  local history_string = vim.fn.execute "history cmd"
  local history_list = vim.split(history_string, "\n")

  local results = {}
  local filter_fn = function(cmd)
    return string.match(cmd, "Shell .*")
  end

  for i = #history_list, 3, -1 do
    local item = history_list[i]
    local _, finish = string.find(item, "%d+ +")
    local cmd = string.sub(item, finish + 1)

    if filter_fn then
      if filter_fn(cmd) then
        table.insert(results, cmd)
      end
    else
      table.insert(results, cmd)
    end
  end

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

return M
