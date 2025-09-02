#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_common.sh"

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
