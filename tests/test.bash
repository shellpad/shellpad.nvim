#!/usr/bin/bash
set -e
set -o pipefail
set -x

nvim --version
nvim \
  +'set nowrap' \
  +'Shell ls -lash' \
  +vs \
  +'Shell --no-follow ps aux --forest'
