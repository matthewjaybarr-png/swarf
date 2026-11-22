#!/bin/sh
# Runs every Swarf test headless in a throwaway config/data dir (your own config is never read).
set -e
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sh test/scan.sh
XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_STATE_HOME="$tmp/state" \
  nvim --headless -u NONE -i NONE -l test/run.lua
