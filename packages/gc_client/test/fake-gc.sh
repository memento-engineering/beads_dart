#!/usr/bin/env bash
# fake gc — a test double for the one Dart transport test (test/transport_test.dart),
# placed first on PATH as `gc`. NOT for production. It implements exactly the seven verbs of the
# bash seat's `gc` command lines that SubprocessGcClient (packages/gc_client) runs:
#
#   bd show <id> --json   -> prints $GC_FIXTURES/<id>.json (exit 1 if absent)
#   bd update <id> ...     -> records the invocation to $FAKE_GC_LOG, exit 0
#                             (exit 1 when <id> is $FAKE_GC_FAIL_UPDATE: a store refusing the write)
#   mail send <...>        -> records the invocation to $FAKE_GC_LOG, exit 0
#   bd search <q> ...      -> records it; prints $GC_FIXTURES/search-<q>.json, or `[]`
#                             when absent; with search-<q>.fail present, prints that
#                             file to stderr and exits 1 (a store that cannot answer)
#   bd list ... --metadata-field gc.root_bead_id=<id> ...
#                          -> records it; prints $GC_FIXTURES/list-<id>.json, or
#                             {"issues":[]} when absent; with list-<id>.fail present,
#                             prints that file to stderr and exits 1
#   convoy status <id> --json
#                          -> records `convoy status <id>`; prints $GC_FIXTURES/convoy-<id>.json
#                             (exit 1 with a message if absent)
#   sling <args...>        -> records `sling <args>`, exits ${FAKE_GC_SLING_RC:-0}
#
# Every other subcommand is a silent success, so an unrelated `gc` call never
# derails a test. Written for bash 3.2.
set -u

_log() { [ -n "${FAKE_GC_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_GC_LOG"; return 0; }

sub="${1:-}"; verb="${2:-}"
if [ "$sub" = sling ]; then
  shift
  _log "sling $*"
  exit "${FAKE_GC_SLING_RC:-0}"
fi
case "$sub $verb" in
  "bd show")
    id="${3:-}"
    f="${GC_FIXTURES:-.}/$id.json"
    if [ -f "$f" ]; then cat "$f"; exit 0; fi
    printf 'fake-gc: no fixture for bead %s (looked in %s)\n' "$id" "$f" >&2
    exit 1
    ;;
  "bd update")
    shift 2
    _log "bd update $*"
    [ -n "${FAKE_GC_FAIL_UPDATE:-}" ] && [ "${1:-}" = "$FAKE_GC_FAIL_UPDATE" ] && exit 1
    exit 0
    ;;
  "mail send")
    shift 2
    _log "mail send $*"
    exit 0
    ;;
  "bd search")
    q="${3:-}"
    _log "bd search $q"
    if [ -f "${GC_FIXTURES:-.}/search-$q.fail" ]; then cat "${GC_FIXTURES:-.}/search-$q.fail" >&2; exit 1; fi
    if [ -f "${GC_FIXTURES:-.}/search-$q.json" ]; then cat "${GC_FIXTURES:-.}/search-$q.json"; exit 0; fi
    printf '[]\n'
    exit 0
    ;;
  "bd list")
    shift 2
    _log "bd list $*"
    root=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --metadata-field) shift; case "${1:-}" in gc.root_bead_id=*) root="${1#gc.root_bead_id=}";; esac ;;
        --metadata-field=gc.root_bead_id=*) root="${1#--metadata-field=gc.root_bead_id=}" ;;
      esac
      shift
    done
    if [ -n "$root" ] && [ -f "${GC_FIXTURES:-.}/list-$root.fail" ]; then cat "${GC_FIXTURES:-.}/list-$root.fail" >&2; exit 1; fi
    if [ -n "$root" ] && [ -f "${GC_FIXTURES:-.}/list-$root.json" ]; then cat "${GC_FIXTURES:-.}/list-$root.json"; exit 0; fi
    printf '{"issues":[]}\n'
    exit 0
    ;;
  "convoy status")
    id="${3:-}"
    _log "convoy status $id"
    f="${GC_FIXTURES:-.}/convoy-$id.json"
    if [ -f "$f" ]; then cat "$f"; exit 0; fi
    printf 'fake-gc: no fixture for convoy %s (looked in %s)\n' "$id" "$f" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
