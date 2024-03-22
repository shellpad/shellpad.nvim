#!/usr/bin/bash
set -e
set -o pipefail
set -x

# If you want to record using asciinema, just use these commands:
#   asciinema auth
#   asciinema rec nvim.cast
#   asciinema upload nvim.cast

nvim --version
nvim \
  +'set nowrap' \
  +'Shell find /work/src | grep -vw git' \
  +vs \
  +'Shell --no-follow ps aux --forest'
