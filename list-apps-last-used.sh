#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_common.sh"

# Help/usage
usage() {
  cat <<'EOF'
Usage: list-apps-last-used.sh [--help|-h]

List apps in /Applications and ~/Applications with last used time (relative and absolute),
sorted by most recently used first. Apps never launched are shown at the end.

Determines last used time via Spotlight metadata (mdls kMDItemLastUsedDate).
If Spotlight is disabled or the value is missing, an app is shown as "never".

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

log_step "Scanning Applications and computing last-used times (via Spotlight metadata)..."

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

# Preprocess rows to compute widths and allow aligned printing
out_rows=$(mktemp)
max_rel=3   # len(REL)
max_name=4  # len(NAME)

# Sort by epoch desc; -1 (never) naturally goes to the bottom
while IFS=$'\t' read -r ts app; do
  if [[ "$ts" -ge 0 ]]; then
    diff=$(( now_epoch - ts ))
    rel=$(format_relative "$diff")
    abs=$(date -r "$ts" "+%Y-%m-%d %H:%M")
  else
    diff=$((315360000)) # large number
    rel="never"
    abs="-"
  fi
  name=$(basename "$app")
  # Track max widths (no color codes)
  (( ${#rel} > max_rel )) && max_rel=${#rel}
  (( ${#name} > max_name )) && max_name=${#name}
  printf "%s\t%s\t%s\t%s\t%s\n" "$rel" "$abs" "$name" "$app" "$ts" >>"$out_rows"
# sort numerically on first field, reverse (newest first)
done < <(sort -t $'\t' -k1,1nr "$out_index")

# Header (bold) with alignment
printf "%s%-*s  %-*s  %-*s  %s%s\n" "${_BOLD:-}" "$max_rel" "REL" 16 "LAST_USED" "$max_name" "NAME" "PATH" "${_RESET:-}"

# Print aligned rows with coloring
while IFS=$'\t' read -r rel abs name app ts; do
  prefix=""; suffix=""
  if [[ "$ts" -lt 0 ]]; then
    prefix="${_RED:-}"; suffix="${_RESET:-}"
  else
    diff=$(( now_epoch - ts ))
    if (( diff >= 2592000 )); then
      prefix="${_YELLOW:-}"; suffix="${_RESET:-}"
    fi
  fi
  printf "%s%-*s  %-*s  %-*s  %s%s\n" "$prefix" "$max_rel" "$rel" 16 "$abs" "$max_name" "$name" "$app" "$suffix"
done < "$out_rows"

rm -f "$out_rows"

log_success "Done."
