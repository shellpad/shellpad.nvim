# shell.nvim

Adds the :Shell command for running a non-interactive shell command in a temporary buffer.

[![asciicast](https://asciinema.org/a/QOXhP4cC2XejW90rnWX6OvlHf.svg)](https://asciinema.org/a/QOXhP4cC2XejW90rnWX6OvlHf)
[![asciicast](https://asciinema.org/a/dj4r53MzhokWa2pD86Zi91eTt.svg)](https://asciinema.org/a/dj4r53MzhokWa2pD86Zi91eTt)

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

## Installation
```
require('lazy').setup({
  {
    "siadat/shell.nvim",
    opts = {},
  },
})
```

## Motivation
I wrote this because while the :term nor :r! commands are quite nice, I found myself working in a slightly different way.

### Differences with the :term command:
- Lines are not wrapped
- It is a normal buffer, no special terminal mode
- No pty, hence no colors or interactive programs
- Process is stopped when buffer is closed

### Differences with the :r! command:
- You can see the live output
- A new scratch buffer is created, instead of using the current buffer

