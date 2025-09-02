#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_common.sh"
. "$SCRIPT_DIR/_config.sh"

# Options:
#   --keep-existing | -k   Do not clean OUTDIR before exporting
#   --types LIST           Comma-separated list of sections to export
#                          e.g. "brew-casks,appstore,npm,yarn,pnpm,pip,manual-apps,brew-taps,brew-formulae"

# Default: clean OUTDIR before dumping
CLEAN_OUTDIR=1
for arg in "$@"; do
  case "$arg" in
    --keep-existing|-k) CLEAN_OUTDIR=0 ;;
  esac
done

# Parse shared --types/positional CSV into global TYPES (from _common.sh)
types_parse_args "$@"

# has_type() provided by _common.sh; empty TYPES => all enabled.

# Ensure output directory exists and is writable
mkdir -p "$OUTDIR" || { log_error "Unable to create $OUTDIR"; exit 1; }
# Verify write access
if ! touch "$OUTDIR/.write_test" 2>/dev/null; then
    log_error "$OUTDIR is not writable"
    exit 1
fi
rm -f "$OUTDIR/.write_test"

# Clean OUTDIR unless disabled
if [ "$CLEAN_OUTDIR" = "1" ]; then
    if [ -d "$OUTDIR" ] && [ "$OUTDIR" != "/" ]; then
        log_step "Cleaning $OUTDIR before export..."
        # Remove all items (including dotfiles) but not the directory itself
        find "$OUTDIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    fi
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
      | tail -n +2 | awk '{print $2}' | sed 's/@.*//g' > "$tmp_npm" || true
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
      | awk '/info "/{gsub(/info "/,""); gsub(/".*/,""); print}' > "$tmp_yarn" || true
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
log_info "brew-taps.txt: $(count_non_empty "$OUTDIR/brew-taps.txt")"
log_info "brew-formulae.txt: $(count_non_empty "$OUTDIR/brew-formulae.txt")"
log_info "brew-casks.txt: $(count_non_empty "$OUTDIR/brew-casks.txt")"
log_info "manual-apps.txt: $(count_non_empty "$OUTDIR/manual-apps.txt")"
log_info "appstore-apps.txt: $(count_non_empty "$OUTDIR/appstore-apps.txt")"
log_info "npm-global.txt: $(count_non_empty "$OUTDIR/npm-global.txt")"
log_info "yarn-global.txt: $(count_non_empty "$OUTDIR/yarn-global.txt")"
log_info "pnpm-global.txt: $(count_non_empty "$OUTDIR/pnpm-global.txt")"
log_info "pip-user.txt: $(count_non_empty "$OUTDIR/pip-user.txt")"
