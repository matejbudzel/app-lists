#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_common.sh"

# Help/usage
usage() {
  cat <<'EOF'
Usage: print-brew-caveats.sh [--help|-h]

Print caveats for all installed Homebrew formulae and casks.

Options:
  --help, -h    Show this help and exit
EOF
}

# Parse options
for arg in "$@"; do
  case "$arg" in
    --help|-h) usage; exit 0 ;;
    -*) log_error "Unknown option: $arg"; usage; exit 2 ;;
  esac
done

# Print caveats for all formulae and casks
log_info "=== Formulae Caveats ==="
brew info --json=v2 --installed \
| jq -r '.formulae[] | select(.caveats != null and .caveats != "") | "__APP_LISTS_HEADER__ \(.name)\n\(.caveats)\n"' \
| while IFS= read -r line; do
  if [[ "$line" == "__APP_LISTS_HEADER__ "* ]]; then
    name="${line#__APP_LISTS_HEADER__ }"
    log_step "--- $name ---"
  else
    echo "$line"
  fi
done

log_info "=== Cask Caveats ==="
brew info --cask --json=v2 --installed \
| jq -r '.casks[] | select(.caveats != null and .caveats != "") | "__APP_LISTS_HEADER__ \(.token)\n\(.caveats)\n"' \
| while IFS= read -r line; do
  if [[ "$line" == "__APP_LISTS_HEADER__ "* ]]; then
    name="${line#__APP_LISTS_HEADER__ }"
    log_step "--- $name ---"
  else
    echo "$line"
  fi
done
