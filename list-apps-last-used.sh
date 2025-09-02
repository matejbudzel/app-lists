#!/bin/bash

# List apps in /Applications and ~/Applications with last used time (relative and absolute),
# sorted by most recently used first. Apps never launched (per Spotlight) are shown at the end.
# Note: Requires Spotlight metadata (mdls). If Spotlight is disabled, many apps will show as "never".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_common.sh"

# Help/usage
usage() {
  cat <<'EOF'
Usage: list-apps-last-used.sh [--help|-h]

List apps in /Applications and ~/Applications with last used time (relative and absolute),
sorted by most recently used first. Apps never launched are shown at the end.

Options:
  --help, -h   Show this help and exit
EOF
}

# Parse args (only --help supported)
for arg in "$@"; do
  case "$arg" in
    --help|-h) usage; exit 0 ;;
    -*) log_error "Unknown option: $arg"; usage; exit 2 ;;
    *) log_error "Unknown parameter: $arg"; usage; exit 2 ;;
  esac
done

log_step "Scanning Applications and computing last-used times..."

now_epoch=$(date +%s)

format_relative() {
  local diff=$1
  if (( diff < 0 )); then
    echo "never"
    return
  fi
  local y=$((diff/31536000))
  local mo=$(( (diff%31536000)/2592000 ))
  local w=$(( (diff%2592000)/604800 ))
  local d=$(( (diff%604800)/86400 ))
  local h=$(( (diff%86400)/3600 ))
  local m=$(( (diff%3600)/60 ))
  local s=$(( diff%60 ))
  if (( y > 0 )); then echo "${y}y"; return; fi
  if (( mo > 0 )); then echo "${mo}mo"; return; fi
  if (( w > 0 )); then echo "${w}w"; return; fi
  if (( d > 0 )); then echo "${d}d"; return; fi
  if (( h > 0 )); then echo "${h}h"; return; fi
  if (( m > 0 )); then echo "${m}m"; return; fi
  echo "${s}s"
}

# Collect app bundles (top-level only) from both locations
# Use -print0 to be safe with spaces and special chars
# Iterate using while-read with -print0 (portable to older Bash without mapfile)

# Build a temp file with "epoch<TAB>path" lines for sorting
out_index=$(mktemp)
trap 'rm -f "$out_index"' EXIT

while IFS= read -r -d '' app; do
  # Some find versions include a trailing null; skip empty entries
  [[ -z "$app" ]] && continue
  # Query last used date; mdls returns (null) if not known
  d=$(mdls -raw -name kMDItemLastUsedDate "$app" 2>/dev/null || true)
  if [[ -z "$d" || "$d" == "(null)" ]]; then
    ts=-1
  else
    # Convert to epoch; mdls format like: 2024-08-31 13:28:40 +0000
    ts=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$d" +%s 2>/dev/null || echo -1)
  fi
  printf "%s\t%s\n" "$ts" "$app" >>"$out_index"
done < <(find /Applications "$HOME/Applications" -maxdepth 1 -type d -name "*.app" -print0 2>/dev/null || true)

# Header
printf "%s\t%s\t%s\t%s\n" "REL" "LAST_USED" "NAME" "PATH"

# Sort by epoch desc; -1 (never) naturally goes to the bottom
while IFS=$'\t' read -r ts app; do
  if [[ "$ts" -ge 0 ]]; then
    diff=$(( now_epoch - ts ))
    rel=$(format_relative "$diff")
    abs=$(date -r "$ts" "+%Y-%m-%d %H:%M")
  else
    rel="never"
    abs="-"
  fi
  name=$(basename "$app")
  printf "%s\t%s\t%s\t%s\n" "$rel" "$abs" "$name" "$app"
# sort numerically on first field, reverse (newest first)
done < <(sort -t $'\t' -k1,1nr "$out_index")

log_success "Done."
