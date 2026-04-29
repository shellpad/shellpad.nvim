local M = {}

local namespace = vim.api.nvim_create_namespace('shellpad_notebook')

-- Per-buffer state. Only set for buffers where setup_buffer() ran.
--
-- notebook_buf_info[buf] = {
--   cells = {                              -- keyed by stable cell_id (monotonic int)
--     [cell_id] = {
--       fence_open_extmark    = id,        -- on the opening ```sh line, anchors identity
--       output_open_extmark   = id_or_nil, -- on the ```output line of the sibling block
--       output_close_extmark  = id_or_nil, -- on the closing ``` of the output block
--       channel_id            = job_or_nil,
--       abandoned_commands    = { [job] = true }, -- see is_command_abandoned in init.lua
--       command_text          = "...",
--       output_lines          = { ... },   -- streaming buffer rendered as the body
--                                          -- of the output block
--       output_render_pending = bool,      -- debounce flag
--     },
--   },
--   fence_extmark_to_cell = { [extmark_id] = cell_id },
--   next_cell_id = N,
-- }
local notebook_buf_info = {}

local supported_lang = function(lang)
  return lang == "" or lang == "sh" or lang == "bash" or lang == "shell"
end

-- Find every supported fenced code block. Each cell entry also carries the
-- 1-indexed line numbers of its sibling ```output block when one already
-- exists in the buffer (e.g. after reopening a saved notebook). Output
-- block is detected if it appears immediately after the cell's closing
-- fence with at most blank lines in between.
local scan_cells = function(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cells = {}
  local i = 1
  while i <= #lines do
    local lang = lines[i]:match("^```(%w*)$")
    if lang ~= nil and supported_lang(lang) then
      local open_lnum = i
      local j = i + 1
      while j <= #lines and lines[j] ~= "```" do
        j = j + 1
      end
      if j > #lines then
        i = open_lnum + 1
      else
        local close_lnum = j
        local cmd_lines = {}
        for k = open_lnum + 1, close_lnum - 1 do
          table.insert(cmd_lines, lines[k])
        end

        local out_open, out_close
        local k = close_lnum + 1
        while k <= #lines and lines[k] == "" do
          k = k + 1
        end
        if k <= #lines and lines[k] == "```output" then
          out_open = k
          local m = k + 1
          while m <= #lines and lines[m] ~= "```" do
            m = m + 1
          end
          if m <= #lines then
            out_close = m
          else
            out_open = nil
          end
        end

        table.insert(cells, {
          open_lnum = open_lnum,
          close_lnum = close_lnum,
          command = table.concat(cmd_lines, "\n"),
          output_open_lnum = out_open,
          output_close_lnum = out_close,
        })
        i = (out_close or close_lnum) + 1
      end
    elseif lang ~= nil then
      -- Unsupported language fence (e.g. ```output, ```python). Skip past
      -- its closing ``` so we do not mis-detect it as a supported cell.
      local j = i + 1
      while j <= #lines and lines[j] ~= "```" do
        j = j + 1
      end
      i = j + 1
    else
      i = i + 1
    end
  end
  return cells
end

-- include_output controls whether cells "claim" their output block too. Enter
-- uses include_output=false so it only fires when the cursor is on the input
-- fence (running a cell from inside its output region would be surprising).
-- Ctrl-C uses include_output=true so users can stop a long-running command
-- without first jumping back up to its input fence.
local cell_at_cursor = function(buf, include_output)
  local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
  for _, cell in ipairs(scan_cells(buf)) do
    if cursor_lnum >= cell.open_lnum and cursor_lnum <= cell.close_lnum then
      return cell
    end
    if include_output
        and cell.output_open_lnum and cell.output_close_lnum
        and cursor_lnum >= cell.output_open_lnum
        and cursor_lnum <= cell.output_close_lnum then
      return cell
    end
  end
  return nil
end

local find_cell_by_open_lnum = function(buf, open_lnum)
  local state = notebook_buf_info[buf]
  if not state then return nil end
  local extmarks = vim.api.nvim_buf_get_extmarks(
    buf, namespace, { open_lnum - 1, 0 }, { open_lnum - 1, -1 }, {}
  )
  for _, em in ipairs(extmarks) do
    local em_id = em[1]
    local cell_id = state.fence_extmark_to_cell[em_id]
    if cell_id and state.cells[cell_id] then
      return cell_id, state.cells[cell_id]
    end
  end
  return nil
end

local get_or_create_cell = function(buf, cell_info)
  local existing_id, existing_cell = find_cell_by_open_lnum(buf, cell_info.open_lnum)
  if existing_id then
    return existing_id, existing_cell
  end

  local state = notebook_buf_info[buf]
  local cell_id = state.next_cell_id
  state.next_cell_id = cell_id + 1

  local fence_open_extmark = vim.api.nvim_buf_set_extmark(
    buf, namespace, cell_info.open_lnum - 1, 0, {}
  )

  -- Adopt an existing ```output block if one is already present in the buffer
  -- (saved notebook reopened). Otherwise leave the output extmarks nil and
  -- let ensure_output_block create them on the first run.
  local output_open_extmark, output_close_extmark
  if cell_info.output_open_lnum and cell_info.output_close_lnum then
    output_open_extmark = vim.api.nvim_buf_set_extmark(
      buf, namespace, cell_info.output_open_lnum - 1, 0, {}
    )
    output_close_extmark = vim.api.nvim_buf_set_extmark(
      buf, namespace, cell_info.output_close_lnum - 1, 0, {}
    )
  end

  state.cells[cell_id] = {
    fence_open_extmark = fence_open_extmark,
    output_open_extmark = output_open_extmark,
    output_close_extmark = output_close_extmark,
    channel_id = nil,
    abandoned_commands = {},
    command_text = cell_info.command,
    output_lines = {},
    output_render_pending = false,
  }
  state.fence_extmark_to_cell[fence_open_extmark] = cell_id
  return cell_id, state.cells[cell_id]
end

local output_block_is_valid = function(buf, cell)
  if not cell.output_open_extmark or not cell.output_close_extmark then
    return false
  end
  local open_pos = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, cell.output_open_extmark, {})
  local close_pos = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, cell.output_close_extmark, {})
  if not open_pos[1] or not close_pos[1] then return false end
  if close_pos[1] <= open_pos[1] then return false end
  local open_line = vim.api.nvim_buf_get_lines(buf, open_pos[1], open_pos[1] + 1, false)[1]
  local close_line = vim.api.nvim_buf_get_lines(buf, close_pos[1], close_pos[1] + 1, false)[1]
  return open_line == "```output" and close_line == "```"
end

-- If the cell does not have a sibling ```output block (or it has been
-- deleted by the user), insert one immediately after the cell's closing
-- fence. The output block is empty until render_output writes into it.
local ensure_output_block = function(buf, cell_id)
  local state = notebook_buf_info[buf]
  local cell = state.cells[cell_id]
  if output_block_is_valid(buf, cell) then return end

  local fence_open_pos = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, cell.fence_open_extmark, {})
  if not fence_open_pos[1] then return end

  -- The cell's closing fence is not extmark-anchored (commands are user text).
  -- Find it by scanning forward from the opening fence.
  local lines_from_open = vim.api.nvim_buf_get_lines(buf, fence_open_pos[1], -1, false)
  local close_offset
  for k = 2, #lines_from_open do
    if lines_from_open[k] == "```" then
      close_offset = k
      break
    end
  end
  if not close_offset then return end
  local close_row_0 = fence_open_pos[1] + close_offset - 1

  vim.api.nvim_buf_set_lines(buf, close_row_0 + 1, close_row_0 + 1, false, {
    "",
    "```output",
    "```",
  })

  cell.output_open_extmark = vim.api.nvim_buf_set_extmark(
    buf, namespace, close_row_0 + 2, 0, {}
  )
  cell.output_close_extmark = vim.api.nvim_buf_set_extmark(
    buf, namespace, close_row_0 + 3, 0, {}
  )
end

-- Replace the body of the cell's output block with the current output_lines.
-- We replace the entire body each render rather than appending so that a
-- partial last line (typical of streaming chunks) is updated in place.
local render_output = function(buf, cell_id)
  local state = notebook_buf_info[buf]
  if not state or not state.cells[cell_id] then return end
  local cell = state.cells[cell_id]
  if not cell.output_open_extmark or not cell.output_close_extmark then return end

  local open_pos = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, cell.output_open_extmark, {})
  local close_pos = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, cell.output_close_extmark, {})
  if not open_pos[1] or not close_pos[1] then return end

  local body_start = open_pos[1] + 1
  local body_end = close_pos[1]
  if body_end < body_start then return end

  vim.api.nvim_buf_set_lines(buf, body_start, body_end, false, cell.output_lines)
  cell.output_render_pending = false
end

-- Coalesce a flood of on_stdout chunks into one render per ~16 ms frame.
-- Without this, the body lines are rebuilt and re-set on every chunk.
local schedule_render = function(buf, cell_id)
  local state = notebook_buf_info[buf]
  if not state or not state.cells[cell_id] then return end
  local cell = state.cells[cell_id]
  if cell.output_render_pending then return end
  cell.output_render_pending = true
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(buf)
        and notebook_buf_info[buf]
        and notebook_buf_info[buf].cells[cell_id] then
      render_output(buf, cell_id)
    end
  end, 16)
end

-- Append a streamed chunk to the cell's output. Joins data[1] onto the
-- previous last line because the previous chunk may have ended mid-line
-- (see :h channel-callback). Embedded \n bytes are escaped the same way
-- the legacy buffer-text writer does, so they do not corrupt buffer lines.
local append_output = function(cell, data)
  if #data == 0 then return end
  for i, line in ipairs(data) do
    data[i] = string.gsub(line, "\n", "\\n")
  end
  if #cell.output_lines == 0 then
    for _, line in ipairs(data) do
      table.insert(cell.output_lines, line)
    end
  else
    local last = #cell.output_lines
    cell.output_lines[last] = cell.output_lines[last] .. data[1]
    for i = 2, #data do
      table.insert(cell.output_lines, data[i])
    end
  end
end

local run_cell = function(buf, cell_id)
  local state = notebook_buf_info[buf]
  if not state or not state.cells[cell_id] then return end
  local cell = state.cells[cell_id]

  -- Abandon the previous job if any. is_command_abandoned (see init.lua)
  -- gates late stdout/stderr/exit callbacks from the stopped job so they
  -- do not leak into the new run's output_lines.
  if cell.channel_id ~= nil then
    cell.abandoned_commands[cell.channel_id] = true
    vim.fn.jobstop(cell.channel_id)
    cell.channel_id = nil
  end

  ensure_output_block(buf, cell_id)
  cell.output_lines = {}
  render_output(buf, cell_id)

  local tmpfile = vim.fn.tempname()
  local cmd_lines = vim.split(cell.command_text, "\n", { plain = true })

  -- Read $HOME/shellpad.lua and prepend its shellrc, mirroring the legacy flow.
  local shellpad_config_path = vim.fn.expand("$HOME") .. "/shellpad.lua"
  if vim.fn.filereadable(shellpad_config_path) == 1 then
    local shellpad_lua_config = dofile(shellpad_config_path)
    local shellrc = shellpad_lua_config.shellrc or ""
    local shellrc_lines = vim.split(shellrc, "\n", { plain = true })
    vim.fn.writefile(shellrc_lines, tmpfile)
    vim.fn.writefile(cmd_lines, tmpfile, "a")
  else
    vim.fn.writefile(cmd_lines, tmpfile)
  end

  local genericStart = require("shellpad").genericStart
  local channel_id = genericStart({
    shell_command = string.format([[
    . %s
    EXIT_CODE=$?
    sleep 0.5s
    exit $EXIT_CODE
    ]], tmpfile),
    on_exit = function()
      if state.cells[cell_id] ~= nil then
        state.cells[cell_id].channel_id = nil
      end
    end,
    is_command_abandoned = function(cid)
      return state.cells[cell_id] ~= nil
          and state.cells[cell_id].abandoned_commands[cid] == true
    end,
    output_sink = function(_, data)
      local current = state.cells[cell_id]
      if not current then return end
      append_output(current, data)
      schedule_render(buf, cell_id)
    end,
  })

  cell.channel_id = channel_id
end

local stop_cell = function(buf, cell_id)
  local state = notebook_buf_info[buf]
  if not state or not state.cells[cell_id] then return end
  local cell = state.cells[cell_id]
  if cell.channel_id ~= nil then
    -- Do NOT mark abandoned. We want the on_exit message to render, the
    -- same way Ctrl-C in legacy mode shows "[Process exited]".
    vim.fn.jobstop(cell.channel_id)
    cell.channel_id = nil
  end
end

local stop_all_cells = function(buf, abandon)
  local state = notebook_buf_info[buf]
  if not state then return end
  for _, cell in pairs(state.cells) do
    if cell.channel_id then
      if abandon then
        cell.abandoned_commands[cell.channel_id] = true
      end
      vim.fn.jobstop(cell.channel_id)
      cell.channel_id = nil
    end
  end
end

local setup_buffer = function(buf)
  if notebook_buf_info[buf] then return end

  notebook_buf_info[buf] = {
    cells = {},
    fence_extmark_to_cell = {},
    next_cell_id = 1,
  }

  vim.keymap.set('n', '<CR>', function()
    local cell_info = cell_at_cursor(buf, false)
    if cell_info == nil then
      local keys = vim.api.nvim_replace_termcodes('<CR>', true, false, true)
      vim.api.nvim_feedkeys(keys, 'n', false)
      return
    end
    local cell_id, cell = get_or_create_cell(buf, cell_info)
    cell.command_text = cell_info.command
    run_cell(buf, cell_id)
  end, { buffer = buf, desc = "shellpad.nvim: Run cell at cursor" })

  vim.keymap.set('n', '<C-c>', function()
    local cell_info = cell_at_cursor(buf, true)
    if cell_info == nil then return end
    local cell_id = find_cell_by_open_lnum(buf, cell_info.open_lnum)
    if cell_id == nil then return end
    stop_cell(buf, cell_id)
  end, { buffer = buf, desc = "shellpad.nvim: Stop cell at cursor" })

  vim.api.nvim_create_autocmd({"BufWipeout"}, {
    buffer = buf,
    callback = function()
      stop_all_cells(buf, true)
      notebook_buf_info[buf] = nil
    end,
  })

  vim.api.nvim_create_autocmd({"BufHidden"}, {
    buffer = buf,
    callback = function()
      stop_all_cells(buf, true)
    end,
  })
end

-- Create a fresh notebook buffer (no associated file) and switch to it. If
-- starter_lines is given, prefill the buffer with them. Returns the buffer
-- handle. Used by :Shellpad with no path and by :Shell when invoked from a
-- non-notebook buffer.
M.open_new = function(starter_lines)
  local buf = vim.api.nvim_create_buf(true, false)
  if starter_lines and #starter_lines > 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, starter_lines)
  end
  vim.cmd.buffer(buf)
  vim.api.nvim_buf_set_var(buf, 'shellpad_notebook', 1)
  vim.api.nvim_buf_set_option(buf, 'filetype', 'markdown')
  setup_buffer(buf)
  return buf
end

-- Append a ```sh cell containing `command` at the end of `buf`, position the
-- cursor on the new cell's command line, and run the cell. The buffer must
-- be (or become) a notebook; setup_buffer is idempotent so it is safe to
-- call repeatedly. Used by the :Shell user command.
M.append_and_run = function(buf, command)
  setup_buffer(buf)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local command_body = vim.split(command, "\n", { plain = true })

  local cell_lines = { "```sh" }
  for _, l in ipairs(command_body) do table.insert(cell_lines, l) end
  table.insert(cell_lines, "```")

  local command_lnum
  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    -- A freshly created buffer has a single empty line. Replace it so the
    -- notebook does not start with a leading blank row.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, cell_lines)
    command_lnum = 2
  else
    -- Append after the last line. Insert a blank separator first if the
    -- buffer ends in non-blank content so successive cells do not butt up
    -- against each other or against a preceding output block.
    local prefix_blank = lines[#lines] ~= ""
    local prefix = prefix_blank and { "" } or {}
    local payload = {}
    for _, l in ipairs(prefix) do table.insert(payload, l) end
    for _, l in ipairs(cell_lines) do table.insert(payload, l) end
    vim.api.nvim_buf_set_lines(buf, #lines, #lines, false, payload)
    -- Layout from #lines (0-indexed) is: prefix... ```sh, body..., ```
    -- so the first body line is at row #lines + #prefix + 1 (0-indexed)
    -- which is line #lines + #prefix + 2 (1-indexed).
    command_lnum = #lines + #prefix + 2
  end

  vim.api.nvim_win_set_cursor(0, { command_lnum, 0 })

  local cell_info = cell_at_cursor(buf, false)
  if cell_info == nil then return end
  local cell_id, cell = get_or_create_cell(buf, cell_info)
  cell.command_text = cell_info.command
  run_cell(buf, cell_id)
end

M.setup = function()
  vim.api.nvim_create_user_command("Shellpad", function(opts)
    local path = opts.fargs[1]
    if path and path ~= "" then
      vim.cmd.edit(vim.fn.fnameescape(path))
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_var(buf, 'shellpad_notebook', 1)
      vim.api.nvim_buf_set_option(buf, 'filetype', 'markdown')
      setup_buffer(buf)
    else
      M.open_new({
        "```sh",
        "date",
        "```",
        "",
      })
    end
  end, { nargs = '?', complete = 'file' })
end

return M
