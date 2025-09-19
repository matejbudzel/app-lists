#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_common.sh"
. "$SCRIPT_DIR/_config.sh"

# Help/usage
usage() {
  cat <<'EOF'
Usage: dump-app-lists.sh [--remove-existing] [--force] [--outdir DIR] [--types LIST|LIST]

Export the current system state into ~/.applists files.

Options:
  --remove-existing     Remove OUTDIR contents before exporting (default: keep)
  --force               Skip interactive confirmations
  --outdir DIR          Output directory (defaults to $HOME/.applists or OUTDIR env)
                        If both OUTDIR env and --outdir are set with different values, an error is raised
  --types LIST          Comma-separated types to export (or positional CSV)
                        Types: brew, brew-taps, brew-formulae, brew-casks,
                               appstore, manual-apps, arc-extensions,
                               npm, yarn, pnpm, pip
  --help, -h            Show this help and exit

Examples:
  dump-app-lists.sh
  dump-app-lists.sh --types npm,yarn,brew-casks
  dump-app-lists.sh --remove-existing --force manual-apps
  OUTDIR=~/.applists dump-app-lists.sh --outdir ~/.applists   # OUTDIR and --outdir must match or error
EOF
}

# Default: keep OUTDIR contents
CLEAN_OUTDIR=0
for arg in "$@"; do
  case "$arg" in
    --remove-existing) CLEAN_OUTDIR=1 ;;
    --force) FORCE=1 ;;
    --outdir|--outdir=*) : ;;
    --help|-h) usage; exit 0 ;;
    --types|--types=*) : ;;
    -*) log_error "Unknown option: $arg"; usage; exit 2 ;;
  esac
done

# Parse shared --types/positional CSV into global TYPES (from _common.sh)
types_parse_args "$@"

# has_type() provided by _common.sh; empty TYPES => all enabled.

# Resolve OUTDIR from CLI vs env/default and detect conflicts
outdir_handle_args "$@"

# Print selected types and ask for confirmation
SELECTED_TYPES=$(selected_types_label "brew, brew-taps, brew-formulae, brew-casks, appstore, manual-apps, arc-extensions, npm, yarn, pnpm, pip")
confirm_continue "$SELECTED_TYPES" "$FORCE" || exit 1

# Ensure output directory exists and is writable
mkdir -p "$OUTDIR" || { log_error "Unable to create $OUTDIR"; exit 1; }
# Verify write access
if ! touch "$OUTDIR/.write_test" 2>/dev/null; then
    log_error "$OUTDIR is not writable"
    exit 1
fi
rm -f "$OUTDIR/.write_test"

# Clean OUTDIR if requested (with confirmation unless --force)
if [ "$CLEAN_OUTDIR" = "1" ]; then
    if [ -d "$OUTDIR" ] && [ "$OUTDIR" != "/" ]; then
        confirm_delete_dir_contents "$OUTDIR" "$FORCE" || exit 1
        log_step "Cleaning $OUTDIR before export..."
        # Remove all items (including dotfiles) but not the directory itself
        find "$OUTDIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    fi
fi

log_step "Starting export for: ${SELECTED_TYPES}"

# --- Arc extensions ---
if has_type arc-extensions; then
  log_info "Exporting Arc extensions..."
  tmp_arc="$OUTDIR/.arc-extensions.tmp"
  : > "$tmp_arc"
  arc_extensions_list_ids | while IFS= read -r id; do
    [ -z "$id" ] && continue
    name=""
    # Try to resolve name from local manifest
    manifest_path=$(find "$HOME/Library/Application Support/Arc" -type f -path "*/Extensions/$id/*/manifest.json" -print -quit 2>/dev/null || true)
    if [ -n "$manifest_path" ] && command -v jq >/dev/null 2>&1; then
      raw_name=$(jq -r '.name // empty' "$manifest_path" 2>/dev/null || echo "")
      if [ -n "$raw_name" ]; then
        if [[ "$raw_name" == __MSG_* ]]; then
          key=${raw_name#__MSG_}; key=${key%%_*}
          # Prefer en locale if present, otherwise first messages.json
          msg_file="$(dirname "$manifest_path")/_locales/en/messages.json"
          if [ ! -f "$msg_file" ]; then
            msg_file=$(find "$(dirname "$manifest_path")/_locales" -name messages.json -print -quit 2>/dev/null || true)
          fi
          if [ -n "$msg_file" ] && [ -f "$msg_file" ] && command -v jq >/dev/null 2>&1; then
            name=$(jq -r --arg k "$key" '.[$k].message // empty' "$msg_file" 2>/dev/null || echo "")
          fi
        else
          name="$raw_name"
        fi
      fi
    fi
    # Optional: try fetching from Chrome Web Store if still unknown (best-effort)
    if [ -z "$name" ] && command -v curl >/dev/null 2>&1; then
      html=$(curl -fsL --max-time 3 "https://chromewebstore.google.com/detail/$id" 2>/dev/null || true)
      if [ -z "$html" ]; then
        html=$(curl -fsL --max-time 3 "https://chrome.google.com/webstore/detail/$id" 2>/dev/null || true)
      fi
      if [ -n "$html" ]; then
        name=$(printf "%s" "$html" | sed -n 's/.*<title>\([^<]*\)<\/title>.*/\1/p' | head -n1 | sed 's/ - Chrome Web Store$//')
      fi
    fi
    if [ -n "$name" ]; then
      printf "%s # %s\n" "$id" "$name" >> "$tmp_arc"
    else
      printf "%s\n" "$id" >> "$tmp_arc"
    fi
  done
  if [ -s "$tmp_arc" ]; then
    sort -u "$tmp_arc" > "$OUTDIR/arc-extensions.txt"
  else
    rm -f "$OUTDIR/arc-extensions.txt"
  fi
  rm -f "$tmp_arc"
fi

log_step "Exporting package and app lists to $OUTDIR"

# --- Homebrew ---
if has_type brew || has_type brew-taps || has_type brew-formulae || has_type brew-casks; then
  if command -v brew &> /dev/null; then
    if has_type brew || has_type brew-taps; then
      log_info "Exporting Homebrew taps..."
      brew tap > "$OUTDIR/brew-taps.txt"
    fi
    if has_type brew || has_type brew-formulae; then
      log_info "Exporting Homebrew formulae (explicit only)..."
      if command -v jq &> /dev/null; then
        brew info --json=v2 --installed \
          | jq -r '.formulae[] | select(any(.installed[]?; .installed_on_request)) | .full_name' \
          > "$OUTDIR/brew-formulae.txt"
      else
        log_warn "jq not found; falling back to 'brew leaves' (may differ from explicit installs)"
        brew leaves > "$OUTDIR/brew-formulae.txt"
      fi
    fi
    if has_type brew || has_type brew-casks; then
      log_info "Exporting Homebrew casks..."
      brew list --cask --full-name > "$OUTDIR/brew-casks.txt"
    fi
  else
    log_warn "Homebrew not found, skipping."
  fi
fi

# --- Mac App Store ---
if has_type appstore && command -v mas &> /dev/null; then
    log_info "Exporting Mac App Store apps..."
    mas list | awk '{id=$1; $1=""; sub(/^ /,"", $0); sub(/ *\([^)]+\).*$/,"", $0); printf "%s # %s\n", id, $0}' > "$OUTDIR/appstore-apps.txt"
fi

# --- Manual Apps (/Applications & ~/Applications not via Brew or MAS) ---
if has_type manual-apps; then
  apps_system=$(ls /Applications 2>/dev/null || echo "")
  apps_user=$(ls ~/Applications 2>/dev/null || echo "")
  brew_casks=$(brew list --cask 2>/dev/null)
  appstore_apps=$(awk -F'#' '{name=$2; gsub(/^[ \t]+|[ \t]+$/,"",name); if (name!="") print name ".app"}' "$OUTDIR/appstore-apps.txt" 2>/dev/null || echo "")
  other_apps=$(comm -23 <(echo -e "$apps_system\n$apps_user" | sort) <(echo -e "$brew_casks\n$appstore_apps" | sort))
  echo "$other_apps" > "$OUTDIR/manual-apps.txt"
fi

# --- npm ---
if has_type npm && command -v npm &> /dev/null; then
    log_info "Exporting global npm packages..."
    tmp_npm="$OUTDIR/.npm-global.tmp"
    npm list -g --depth=0 2>/dev/null \
      | tail -n +2 | awk '{print $2}' | sed -E 's/@[^@]+$//' > "$tmp_npm" || true
    if [ -s "$tmp_npm" ]; then
        mv "$tmp_npm" "$OUTDIR/npm-global.txt"
    else
        rm -f "$tmp_npm" "$OUTDIR/npm-global.txt"
        log_info "No global npm packages found; skipping."
    fi
fi

# --- Yarn ---
if has_type yarn && command -v yarn &> /dev/null; then
    log_info "Exporting global Yarn packages..."
    tmp_yarn="$OUTDIR/.yarn-global.tmp"
    yarn global list --depth=0 2>/dev/null \
      | awk '/info "/{gsub(/info "/,""); gsub(/".*/,""); print}' \
      | sed -E 's/@[^@]+$//' > "$tmp_yarn" || true
    if [ -s "$tmp_yarn" ]; then
        mv "$tmp_yarn" "$OUTDIR/yarn-global.txt"
    else
        rm -f "$tmp_yarn" "$OUTDIR/yarn-global.txt"
        log_info "No global Yarn packages found; skipping."
    fi
fi

# --- pnpm ---
if has_type pnpm && command -v pnpm &> /dev/null; then
    log_info "Exporting global pnpm packages..."
    tmp_pnpm="$OUTDIR/.pnpm-global.tmp"
    pnpm list -g --depth=0 --json 2>/dev/null \
        | jq -r '.[].name? // empty' > "$tmp_pnpm" || true
    if [ -s "$tmp_pnpm" ]; then
        mv "$tmp_pnpm" "$OUTDIR/pnpm-global.txt"
    else
        rm -f "$tmp_pnpm" "$OUTDIR/pnpm-global.txt"
        log_info "No global pnpm packages found; skipping."
    fi
fi

# --- pip (unified; explicit packages only) ---
PIP_CMD="$(detect_pip_cmd)"
if has_type pip && [ -n "$PIP_CMD" ]; then
    log_info "Exporting user pip packages (explicit only) using $PIP_CMD..."
    # Try direct freeze of not-required top-level packages
    if $PIP_CMD list --user --not-required --format=freeze 2>/dev/null | sed -e 's/==.*$//' > "$OUTDIR/pip-user.txt"; then
        :
    # Fallback: JSON + jq to produce name==version
    elif command -v jq &> /dev/null && $PIP_CMD list --user --not-required --format=json > "$OUTDIR/.pip-list.json" 2>/dev/null; then
        jq -r '.[].name' "$OUTDIR/.pip-list.json" > "$OUTDIR/pip-user.txt"
        rm -f "$OUTDIR/.pip-list.json"
    else
        log_warn "Falling back to full freeze (includes dependencies)"
        $PIP_CMD freeze --user | sed -e 's/==.*$//' > "$OUTDIR/pip-user.txt"
    fi
fi

log_success "Export complete. Counts in $OUTDIR:"
# Count non-empty lines in each list (0 if file missing)
count_non_empty() {
  if [ -f "$1" ]; then
    awk 'NF' "$1" | wc -l | tr -d ' '
  else
    echo 0
  fi
}
log_info "arc-extensions.txt: $(count_non_empty "$OUTDIR/arc-extensions.txt")"
log_info "brew-taps.txt: $(count_non_empty "$OUTDIR/brew-taps.txt")"
log_info "brew-formulae.txt: $(count_non_empty "$OUTDIR/brew-formulae.txt")"
log_info "brew-casks.txt: $(count_non_empty "$OUTDIR/brew-casks.txt")"
log_info "manual-apps.txt: $(count_non_empty "$OUTDIR/manual-apps.txt")"
log_info "appstore-apps.txt: $(count_non_empty "$OUTDIR/appstore-apps.txt")"
log_info "npm-global.txt: $(count_non_empty "$OUTDIR/npm-global.txt")"
log_info "yarn-global.txt: $(count_non_empty "$OUTDIR/yarn-global.txt")"
log_info "pnpm-global.txt: $(count_non_empty "$OUTDIR/pnpm-global.txt")"
log_info "pip-user.txt: $(count_non_empty "$OUTDIR/pip-user.txt")"
