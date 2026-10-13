#!/usr/bin/env bash
# Record per-table row counts of a Field Notes database copy as a JSON baseline
# for test/live_db_guard_test.dart.
#
#   tool/live_db_counts.sh <copy.sqlite> <counts.json>
#
# Take the copy with sqlite3's .backup (consistent snapshot), never cp of a
# live file:  sqlite3 -readonly live.sqlite ".backup 'copy.sqlite'"
set -euo pipefail
db="$1"; out="$2"
{
  echo "{"
  sqlite3 -readonly "$db" "select name from sqlite_master where type='table' and name not like 'sqlite_%' order by name" \
    | while read -r t; do printf '  "%s": %s,\n' "$t" "$(sqlite3 -readonly "$db" "select count(*) from \"$t\"")"; done \
    | sed '$ s/,$//'
  echo "}"
} > "$out"
echo "wrote $out"
