#!/bin/bash

# Umbrella launcher for app-lists scripts
# Subcommands:
#   apps dump-lists [args...]       -> dump-app-lists.sh
#   apps sync-from-lists [args...]  -> sync-from-app-lists.sh
#   apps update-all [args...]       -> update-all-apps.sh
#   apps list-last-used [args...]   -> list-apps-last-used.sh
#   apps caveats [args...]          -> print-brew-caveats.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: apps <command> [args]

Commands:
  dump-lists        Export current system state into ~/.applists files
  sync-from-lists   Sync machine state to match lists in ~/.applists
  update-all        Update/upgrade system-wide packages and apps
  list-last-used    List apps by last-used time (via Spotlight metadata)
  caveats           Print Homebrew formulae and cask caveats

Run 'apps <command> --help' to see options for a command.
EOF
}

cmd="$1"; shift || true
case "$cmd" in
  -h|--help|help|"") usage; exit 0 ;;
  dump-lists)        exec "$SCRIPT_DIR/dump-app-lists.sh" "$@" ;;
  sync-from-lists)   exec "$SCRIPT_DIR/sync-from-app-lists.sh" "$@" ;;
  update-all)        exec "$SCRIPT_DIR/update-all-apps.sh" "$@" ;;
  list-last-used)    exec "$SCRIPT_DIR/list-apps-last-used.sh" "$@" ;;
  caveats)           exec "$SCRIPT_DIR/print-brew-caveats.sh" "$@" ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage
    exit 2
    ;;
 esac
