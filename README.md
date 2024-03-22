# shell.nvim

Adds :Shell command to run a non-interactive shell command in a temporary buffer.

I wrote this because while the :term nor :r! commands are quite nice, I found myself working in a slightly different way.

Differences with the :term command:
- Lines are not wrapped
- It is a normal buffer, no special terminal mode
- No pty, hence no colors or interactive programs
- Process is stopped when buffer is closed

Differences with the :r! command:
- You can see the live output
- A new scratch buffer is created, instead of using the current buffer

## Quick Start

```
require('lazy').setup({
  {
    "siadat/shell.nvim",
    opts = {},
    dev = true,
  },
})
```

## Usage
```
:Shell COMMAND
:Shell --no-follow COMMAND
:Shell --stop
```

## Example
```
:Shell ping -c 3 localhost
```
