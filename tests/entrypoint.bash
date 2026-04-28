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

# Test a slow :Shell command. Use finite producers to avoid SIGPIPE noise
# from `yes | head` on newer coreutils where the signal is reported as
# "Aborted (core dumped)".
cmd='for i in 1 2 3 4 5; do echo ${i}A; done && sleep 0.5 && for i in 1 2 3 4 5; do echo ${i}B; done'
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

TESTS_DIR="src/nvim-plugins/shellpad.nvim/tests"

# Test :Shellpad notebook mode: running cell 1 produces its own ```output
# block while cell 2 is left untouched (no output block created for it).
cp "$TESTS_DIR/notebook_basic.md" got4
nvim \
  +'Shellpad got4' \
  +'lua vim.defer_fn(function() vim.cmd.normal("gg\r") end, 250)' \
  +'lua vim.defer_fn(function() vim.cmd("w | q") end, 1750)'
cat <<'EOF' > want4
```sh
echo hello_notebook
```

```output
hello_notebook
[Process exited with code 0]
```

```sh
echo second_cell
```
EOF
git diff --color=always --no-index want4 got4

# Test :Shellpad rerun + multiple cells: edit cell 1, run it twice, then run
# cell 2. The rerun must replace cell 1's output block body in place (not
# append a new one), and cell 2 must get its own independent output block.
cp "$TESTS_DIR/notebook_basic.md" got5
nvim \
  +'Shellpad got5' \
  +'lua vim.defer_fn(function() vim.cmd.normal("gg\r") end, 250)' \
  +'lua vim.defer_fn(function() vim.cmd("silent! 2s/hello_notebook/edited_notebook/") end, 1500)' \
  +'lua vim.defer_fn(function() vim.cmd.normal("gg\r") end, 1750)' \
  +'lua vim.defer_fn(function() vim.fn.search("^echo second_cell$"); vim.cmd.normal("\r") end, 3000)' \
  +'lua vim.defer_fn(function() vim.cmd("w | q") end, 4500)'
cat <<'EOF' > want5
```sh
echo edited_notebook
```

```output
edited_notebook
[Process exited with code 0]
```

```sh
echo second_cell
```

```output
second_cell
[Process exited with code 0]
```
EOF
git diff --color=always --no-index want5 got5
