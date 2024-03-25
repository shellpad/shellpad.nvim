# shellpad.nvim

Adds the :Shell command for running a non-interactive shell command (no pty) in a temporary buffer.

[![asciicast](https://github.com/siadat/public/blob/main/648354.gif?raw=true)](https://asciinema.org/a/QOXhP4cC2XejW90rnWX6OvlHf)

## Usage
```
:Shell COMMAND
:Shell --no-follow COMMAND
:Shell --stop
:Shell --edit
```
* Press Ctrl-C to stop the process in the current buffer.

## Example
```
:Shell rg -n pattern .
:Shell ping -c 3 localhost
:Shell tail --lines=0 -F ~/.local/state/nvim/log
```

Hint: In the rg example, you can press gF to jump to the file under the cursor. See :help gF.

## Installation
```
require('lazy').setup({
  {
    "shellpad/shellpad.nvim",
    opts = {},
  },
})
```

If you use Telescope, you can search all your :Shell commands using the following function and mapping:

```
vim.keymap.set('n', '<leader>sc', require('shellpad').telescope_history_search(), { desc = '[S]earch [C]ommands' })
```

All combined:
```
require('lazy').setup({
  {
    "shellpad/shellpad.nvim",
    dependencies = { "nvim-telescope/telescope.nvim" },
    config = function(_)
      vim.keymap.set('n', '<leader>sc', require('shellpad').telescope_history_search(), { desc = '[S]earch [C]ommands' })
    end,
  },
})
```

## Motivation
I wrote this because while Tmux, :term and :r! commands are quite nice, I found myself working in a slightly different way.

### Differences with the Tmux:
- There is no builtin communication between a Tmux pane and NeoVim. It can be quite complicated to setup a way to a text (eg filename) that is outputed from a command in a Tmux pane to NeoVim.
- There is no way to further process the output of a command in a Tmux pane. You will have to either copy-paste or save the buffer and open it in NeoVim. With :Shell, you have access to all NeoVim features for further processing the output.
- In Tmux, the output of each command is appended to the previous one. This makes it hard to figure out if a search match belongs to a previous command or the last command. So, in effect you will have to either clear history of the Tmux pane, or exit the pane and create a new one. With :Shell, each command output has its own buffer.

### Differences with the :term command:
- :term has colors and gets user input. :Shell has no pty hence no colors and is only useful for non-interactive commands. (Pty is disabled to make sure lines are not wrapped as mentioned in the next item)
- :term output is wrapped and difficult to work with (see https://github.com/neovim/neovim/issues/2514). :Shell does not wrap lines in its output. 
- :Shell uses a normal buffer, with no special terminal mode. The :term buffers have a special terminal mode. With :term, if you enter the Insert mode on a completed process, and press any key, the whole buffer is closed and deleted. In :Shell, you can enter and leave the Insert mode like any other buffer. 
- By default, leaving insert mode from a :term buffer is done via thr special key sequence ctrl-\ ctrl-n. In :Shell, you just press the escape key, like any other buffer.
- :Shell process is stopped when the buffer window is closed. :term processes keep running even when the window is closed, because the buffer still exists. 
- :term and jobstart have a bug where the process output is truncated (see https://github.com/neovim/neovim/issues/26543). :Shell provides a workaround by simply sleeping for 0.5s. This is good enough for most usecases until the bug is resolved unpstream. 
- :term buffers are not modifiable by default. You can process :Shell buffers with other commands like :%!sort | uniq -c | sort. If you want to do that with :term, you will need to make the buffer modifiable, and remove the empty lines. Furthermore, the :term output is wrapped to the current window width, so the output is just unreliable.

The most important thing I need from :term to use it more is to allow setting the width of the pty, instead of getting the width from the current window.

### Differences with the :r! command:
- :r! blocks until the process is completed, but :Shell is async and appends the output to the buffer as it is happening
- :Shell creates a new scratch buffer, instead of using the current buffer

### Differences with the :! command:
-  :! opens a special buffer, you cannot move the cursor around inside it or do anything that you can do in normal buffers like yanking a line or gf or gF. The :! window is closed when you press any key. But :Shell buffers let you do those things.

## Another example: jump to file using gF

Using :Shell to run a compile command and jump to the line with error:
[![asciicast](https://asciinema.org/a/dj4r53MzhokWa2pD86Zi91eTt.svg)](https://asciinema.org/a/dj4r53MzhokWa2pD86Zi91eTt)
