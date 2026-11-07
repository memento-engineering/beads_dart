#!/bin/sh
# Checks what bdd-kxn added, from the repository root: CLAUDE.md is the one
# line @AGENTS.md, AGENTS.md states each convention a substation reads, and
# ci.yaml carries the merge-queue trigger and the ci-required job.
# Exits 0 printing nothing, or 1 naming each file and the text it lacks.
set -u
cd "$(dirname -- "$0")/.." || exit 2
status=0
need() {
  grep -qF -- "$2" "$1" || { echo "$1 lacks: $2" >&2; status=1; }
}
if [ "$(cat CLAUDE.md 2>/dev/null)" != '@AGENTS.md' ] ||
  [ "$(wc -l < CLAUDE.md)" -ne 1 ]; then
  echo 'CLAUDE.md is not the single line @AGENTS.md' >&2
  status=1
fi
for text in 'README.md' 'packages/bdp' 'packages/gc_api' 'packages/gc_client' \
  'dart pub get' 'dart analyze --fatal-infos' 'dart format --set-exit-if-changed .' \
  'dart run tool/test_entry.dart --check' 'dart test' 'tag_pattern' \
  '<name>-v<version>' 'Never move a tag' 'Unreleased' 'package:bdp/client.dart' \
  'dart:io' 'dart:ffi' 'sqlite3' 'shelf' 'packages/bdp/test/structure_test.dart' \
  'packages/gc_api/test/web_test.dart' 'gc 1.5.1' 'packages/gc_api/test/spec_test.dart' \
  'packages/gc_api/test/fixtures/openapi.json' 'demo' '/home/gc' \
  'tool/test_entry.dart' 'test/all_test.dart' 'docs/decisions'; do
  need AGENTS.md "$text"
done
for text in 'merge_group:' 'ci-required:' 'if: always()' 'needs: [dart]' \
  'needs.dart.result'; do
  need .github/workflows/ci.yaml "$text"
done
exit "$status"
