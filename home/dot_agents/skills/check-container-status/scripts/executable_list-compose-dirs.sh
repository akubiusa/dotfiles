#!/usr/bin/env bash
set -euo pipefail

target_dir="${1:-.}"
if [[ ! -d "$target_dir" ]]; then
  printf 'ERROR: not a directory: %s\n' "$target_dir" >&2
  exit 1
fi

target_dir="$(cd "$target_dir" && pwd)"
for dir in "$target_dir"/*/; do
  [[ -d "$dir" ]] || continue
  dir="${dir%/}"
  for filename in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    if [[ -f "$dir/$filename" ]]; then
      printf '%s\n' "$dir"
      break
    fi
  done
done
