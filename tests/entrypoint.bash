#!/usr/bin/bash
set -e
set -o pipefail
set -x

# If you want to record using asciinema, just use these commands:
#   asciinema auth
#   asciinema rec nvim.cast
#   asciinema upload nvim.cast

cmd='yes | nl -w1 -s "" | head -5 && sleep 1 && yes | nl -w1 -s "" | head -5'
nvim --version
nvim \
  +"Shell ${cmd}" \
  +'lua vim.defer_fn(function() vim.cmd.normal("kOHello") end, 500)' \
  +'lua vim.defer_fn(function() vim.cmd.normal("A world!") end, 1500)' \
  +'lua vim.defer_fn(function() vim.cmd("w got1 | q") end, 2000)'
echo "${cmd}
1y
2y
3y
4y
Hello world!
5y
1y
2y
3y
4y
5y
[Process exited with code 0]" > want1
git diff --color=always --no-index want1 got1
echo $?
