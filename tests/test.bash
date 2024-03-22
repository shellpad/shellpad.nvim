#!/usr/bin/bash
set -e
set -o pipefail
set -x

nvim --version
nvim \
  +'set nowrap' \
  +'Shell find /work/src | grep -vw git' \
  +vs \
  +'Shell --no-follow ps aux --forest'
