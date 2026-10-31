#!/bin/bash

failed_commit_matches() {
  local state_file="$1" commit="$2" recorded
  recorded="$(cat "$state_file" 2>/dev/null || true)"
  [ -n "$recorded" ] && [ "$recorded" = "$commit" ]
}

record_failed_commit() {
  local state_file="$1" commit="$2" temp_file
  temp_file="${state_file}.tmp.$$"
  printf '%s\n' "$commit" > "$temp_file"
  mv "$temp_file" "$state_file"
}

clear_failed_commit_for_new_revision() {
  local state_file="$1" commit="$2" recorded
  recorded="$(cat "$state_file" 2>/dev/null || true)"
  if [ -n "$recorded" ] && [ "$recorded" != "$commit" ]; then
    rm -f "$state_file"
  fi
}

clear_failed_commit() {
  rm -f "$1"
}
