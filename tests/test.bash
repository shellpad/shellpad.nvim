#!/usr/bin/bash
set -e
set -o pipefail
set -x

nvim --version
mkdir -p ~/.config/nvim
nvim \
  +'set nowrap' \
  +'Shell ls -lash' \
  +vs \
  +'Shell --no-follow ps aux --forest'
