#!/usr/bin/bash
set -e
set -o pipefail
set -x

# If you want to record using asciinema, just use these commands:
#   asciinema auth
#   asciinema rec nvim.cast
#   asciinema upload nvim.cast

trap 'echo "Test exited with code $?"' EXIT
nvim --version

# Test a slow :Shell command
cmd='yes A | nl -w1 -s "" | head -5 && sleep 0.5 && yes B | nl -w1 -s "" | head -5'
nvim \
  +"Shell ${cmd}" \
  +'lua vim.defer_fn(function() vim.cmd.normal("A # comment") end, 500)' \
  +'lua vim.defer_fn(function() vim.cmd("w got1 | q") end, 1250)'
echo "${cmd} # comment
1A
2A
3A
4A
5A
1B
2B
3B
4B
5B
[Process exited with code 0]" > want1
git diff --color=always --no-index want1 got1

# Test a Shell://COMMAND buffer
nvim -O \
  'Shell://echo test1' \
  +'lua vim.defer_fn(function() vim.cmd("w got2 | q") end, 750)'
echo "echo test1
test1
[Process exited with code 0]" > want2
git diff --color=always --no-index want2 got2

# Test running a command by pressing Enter (<CR>)
nvim -O \
  'Shell://echo old_value' \
  +'lua vim.defer_fn(function() vim.cmd.normal("Secho new_value") end, 500)' \
  +'lua vim.defer_fn(function() vim.cmd.normal("\r") end, 1000)' \
  +'lua vim.defer_fn(function() vim.cmd("w got3 | q") end, 1750)'
echo "echo new_value
new_value
[Process exited with code 0]" > want3
git diff --color=always --no-index want3 got3
