#!/bin/bash

# Sync machine state to match app-list files (source of truth)
# - Installs missing items from lists
# - Prunes extras (where supported)
# Options:
#   --dry-run | -n          Show planned actions only, do not change system
#   --recreate-explicit     For Brew formulae and pip user packages, fully
#                           recreate explicit set (uninstall then install list)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_common.sh"
. "$SCRIPT_DIR/_config.sh"

DRYRUN=0
RECREATE_EXPLICIT=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRYRUN=1 ;;
    --recreate-explicit) RECREATE_EXPLICIT=1 ;;
  esac
done

if [ "$DRYRUN" = "1" ]; then
  log_step "Starting sync (DRY-RUN) from $OUTDIR ..."
else
  log_step "Starting sync from $OUTDIR ..."
fi

_strip_list() {
  # strip comments, trim whitespace, drop empties, sort unique
  sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' | sort -u
}

# --- Homebrew ---------------------------------------------------------------
if ! command -v brew &> /dev/null; then
  log_step "Installing Homebrew..."
  if [ "$DRYRUN" = "1" ]; then
    log_info "Would run: Homebrew install script"
  else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
fi
[ "$DRYRUN" = "1" ] || brew update

# Taps: add missing (do not prune by default)
if [ -f "$OUTDIR/brew-taps.txt" ] && [ -s "$OUTDIR/brew-taps.txt" ]; then
  current_taps="$(brew tap 2>/dev/null || true)"
  tmp_want=$(mktemp); tmp_have=$(mktemp)
  _strip_list < "$OUTDIR/brew-taps.txt" > "$tmp_want"
  printf '%s\n' "$current_taps" | sort -u > "$tmp_have"
  while IFS= read -r tap; do
    [ -z "$tap" ] && continue
    if grep -Fxq "$tap" "$tmp_have"; then
      log_success "Tap already present: $tap"
    else
      if [ "$DRYRUN" = "1" ]; then
        log_info "Would tap: $tap"
      else
        log_step "Tapping: $tap"; brew tap "$tap" || log_warn "Failed to tap $tap (continuing)"
      fi
    fi
  done < "$tmp_want"
  rm -f "$tmp_want" "$tmp_have"
fi

# Formulae
if [ -f "$OUTDIR/brew-formulae.txt" ]; then
  if [ "$RECREATE_EXPLICIT" = "1" ]; then
    log_step "Syncing Brew formulae (recreate explicit set) ..."
    if [ "$DRYRUN" = "1" ]; then
      log_info "Would iteratively uninstall all brew formulae leaves until none remain"
      log_info "Would install from: $OUTDIR/brew-formulae.txt"
      log_info "Would run: brew autoremove"
    else
      # Iteratively remove leaves to avoid breaking deps
      while :; do
        leaves=$(brew leaves --full-name 2>/dev/null || brew leaves || true)
        [ -z "$leaves" ] && break
        echo "$leaves" | xargs -n1 brew uninstall || true
        # If nothing uninstalled in a round, break to avoid infinite loop
        new_leaves=$(brew leaves --full-name 2>/dev/null || brew leaves || true)
        [ "$new_leaves" = "$leaves" ] && break
      done
      xargs brew install < "$OUTDIR/brew-formulae.txt"
      brew autoremove || true
    fi
  else
    log_step "Syncing Brew formulae (prune extra leaves, install missing) ..."
    tmp_want=$(mktemp); tmp_leaves=$(mktemp); tmp_installed=$(mktemp)
    _strip_list < "$OUTDIR/brew-formulae.txt" > "$tmp_want"
    brew leaves --full-name 2>/dev/null | sort -u > "$tmp_leaves" || brew leaves | sort -u > "$tmp_leaves" || true
    brew list --formula --full-name 2>/dev/null | sort -u > "$tmp_installed" || true

    # Install missing
    if [ "$DRYRUN" = "1" ]; then
      log_info "Would install formulae:"; comm -23 "$tmp_want" "$tmp_installed" | sed 's/^/- /'
    else
      tmp_missing=$(mktemp)
      comm -23 "$tmp_want" "$tmp_installed" > "$tmp_missing"
      if [ -s "$tmp_missing" ]; then xargs brew install < "$tmp_missing"; fi
      rm -f "$tmp_missing"
    fi

    # Prune extra leaves not in wanted list
    if [ "$DRYRUN" = "1" ]; then
      log_info "Would uninstall extra leaf formulae:"; comm -23 "$tmp_leaves" "$tmp_want" | sed 's/^/- /'
      log_info "Would run: brew autoremove"
    else
      tmp_extra=$(mktemp)
      comm -23 "$tmp_leaves" "$tmp_want" > "$tmp_extra"
      if [ -s "$tmp_extra" ]; then xargs brew uninstall < "$tmp_extra" || true; fi
      rm -f "$tmp_extra"
      brew autoremove || true
    fi
    rm -f "$tmp_want" "$tmp_leaves" "$tmp_installed"
  fi
fi

# Casks: install missing, uninstall extras
if [ -f "$OUTDIR/brew-casks.txt" ]; then
  log_step "Syncing Brew casks ..."
  tmp_want=$(mktemp); tmp_have=$(mktemp)
  _strip_list < "$OUTDIR/brew-casks.txt" > "$tmp_want"
  brew list --cask --full-name | sort -u > "$tmp_have" || true

  # Install missing
  if [ "$DRYRUN" = "1" ]; then
    log_info "Would install casks:"; comm -23 "$tmp_want" "$tmp_have" | sed 's/^/- /'
  else
    tmp_missing=$(mktemp)
    comm -23 "$tmp_want" "$tmp_have" > "$tmp_missing"
    if [ -s "$tmp_missing" ]; then
      tmp_cask_log_dir="$(mktemp -d 2>/dev/null || mktemp -d -t casklogs)"
      while IFS= read -r cask; do
        [ -z "$cask" ] && continue
        token="${cask##*/}"
        log_step "Installing cask $cask (logs: $tmp_cask_log_dir/$token.log)"
        if ! brew install --cask "$cask" >"$tmp_cask_log_dir/$token.log" 2>&1; then
          log_warn "$cask: install failed (continuing)"
        else
          log_success "Installed $cask"
        fi
      done < "$tmp_missing"
    fi
    rm -f "$tmp_missing"
  fi

  # Uninstall extras
  if [ "$DRYRUN" = "1" ]; then
    log_info "Would uninstall extra casks:"; comm -23 "$tmp_have" "$tmp_want" | sed 's/^/- /'
  else
    tmp_extra=$(mktemp)
    comm -23 "$tmp_have" "$tmp_want" > "$tmp_extra"
    if [ -s "$tmp_extra" ]; then xargs -n1 brew uninstall --cask < "$tmp_extra" || true; fi
    rm -f "$tmp_extra"
  fi
  rm -f "$tmp_want" "$tmp_have"
fi

# --- Mac App Store ----------------------------------------------------------
if [ -f "$OUTDIR/appstore-apps.txt" ] && command -v mas &> /dev/null; then
  log_step "Syncing Mac App Store apps (install missing only) ..."
  tmp_want=$(mktemp); tmp_have=$(mktemp)
  awk -F'#' '{gsub(/^[ \t]+|[ \t]+$/,"",$1); if ($1 ~ /^[0-9]+$/) print $1}' "$OUTDIR/appstore-apps.txt" | sort -u > "$tmp_want"
  mas list | awk '{print $1}' | sort -u > "$tmp_have" || true
  if [ "$DRYRUN" = "1" ]; then
    log_info "Would install MAS app IDs:"; comm -23 "$tmp_want" "$tmp_have" | sed 's/^/- /'
  else
    tmp_missing=$(mktemp)
    comm -23 "$tmp_want" "$tmp_have" > "$tmp_missing"
    if [ -s "$tmp_missing" ]; then xargs mas install < "$tmp_missing"; fi
    rm -f "$tmp_missing"
  fi
  rm -f "$tmp_want" "$tmp_have"
fi

# --- npm --------------------------------------------------------------------
if [ -f "$OUTDIR/npm-global.txt" ] && command -v npm &> /dev/null; then
  log_step "Syncing global npm packages (install missing only) ..."
  tmp_want=$(mktemp); tmp_have=$(mktemp)
  _strip_list < "$OUTDIR/npm-global.txt" > "$tmp_want"
  npm list -g --depth=0 2>/dev/null | tail -n +2 | awk '{print $2}' | sed 's/@.*//' | sort -u > "$tmp_have" || true
  if [ "$DRYRUN" = "1" ]; then
    log_info "Would install npm globals:"; comm -23 "$tmp_want" "$tmp_have" | sed 's/^/- /'
  else
    tmp_missing=$(mktemp)
    comm -23 "$tmp_want" "$tmp_have" > "$tmp_missing"
    if [ -s "$tmp_missing" ]; then xargs npm install -g < "$tmp_missing"; fi
    rm -f "$tmp_missing"
  fi
  rm -f "$tmp_want" "$tmp_have"
fi

# --- Yarn -------------------------------------------------------------------
if [ -f "$OUTDIR/yarn-global.txt" ] && command -v yarn &> /dev/null; then
  log_step "Syncing global Yarn packages (install missing only) ..."
  tmp_want=$(mktemp); tmp_have=$(mktemp)
  _strip_list < "$OUTDIR/yarn-global.txt" > "$tmp_want"
  yarn global list --depth=0 2>/dev/null | awk '/info "[^"]+"/{gsub(/.*info \"/,"",$0); gsub(/\".*/,"",$0); print}' | sort -u > "$tmp_have" || true
  if [ "$DRYRUN" = "1" ]; then
    log_info "Would install Yarn globals:"; comm -23 "$tmp_want" "$tmp_have" | sed 's/^/- /'
  else
    tmp_missing=$(mktemp)
    comm -23 "$tmp_want" "$tmp_have" > "$tmp_missing"
    if [ -s "$tmp_missing" ]; then xargs yarn global add < "$tmp_missing"; fi
    rm -f "$tmp_missing"
  fi
  rm -f "$tmp_want" "$tmp_have"
fi

# --- pnpm -------------------------------------------------------------------
if [ -f "$OUTDIR/pnpm-global.txt" ] && command -v pnpm &> /dev/null; then
  log_step "Syncing global pnpm packages (install missing only) ..."
  tmp_want=$(mktemp); tmp_have=$(mktemp)
  _strip_list < "$OUTDIR/pnpm-global.txt" > "$tmp_want"
  if command -v jq &> /dev/null; then
    pnpm list -g --depth=0 --json 2>/dev/null | jq -r '.[].name? // empty' | sort -u > "$tmp_have" || true
  else
    # Without jq, skip detecting installed set (treat as install-missing only)
    : > "$tmp_have"
  fi
  if [ "$DRYRUN" = "1" ]; then
    log_info "Would install pnpm globals:"; comm -23 "$tmp_want" "$tmp_have" | sed 's/^/- /'
  else
    tmp_missing=$(mktemp)
    comm -23 "$tmp_want" "$tmp_have" > "$tmp_missing"
    if [ -s "$tmp_missing" ]; then xargs pnpm add -g < "$tmp_missing"; fi
    rm -f "$tmp_missing"
  fi
  rm -f "$tmp_want" "$tmp_have"
fi

# --- pip (user) -------------------------------------------------------------
if [ -f "$OUTDIR/pip-user.txt" ]; then
  PIP_CMD="$(detect_pip_cmd)"
  if [ -n "$PIP_CMD" ]; then
    if [ "$RECREATE_EXPLICIT" = "1" ]; then
      log_step "Syncing user pip packages (recreate explicit set) via $PIP_CMD ..."
      if [ "$DRYRUN" = "1" ]; then
        log_info "Would uninstall all user pip packages"
        log_info "Would install from: $OUTDIR/pip-user.txt"
      else
        # Uninstall all user packages
        $PIP_CMD freeze --user | sed -e 's/==.*$//' | xargs -n1 $PIP_CMD uninstall -y || true
        $PIP_CMD install --user -r "$OUTDIR/pip-user.txt"
      fi
    else
      log_step "Syncing user pip packages (prune extras, install missing) via $PIP_CMD ..."
      tmp_want=$(mktemp); tmp_have=$(mktemp)
      awk -F'==' 'NF{print $1}' "$OUTDIR/pip-user.txt" | _strip_list > "$tmp_want"
      # installed top-level user packages
      if $PIP_CMD list --user --not-required --format=json > "$tmp_have.json" 2>/dev/null && command -v jq &> /dev/null; then
        jq -r '.[].name' "$tmp_have.json" | _strip_list > "$tmp_have" && rm -f "$tmp_have.json"
      elif $PIP_CMD list --user --not-required --format=freeze > "$tmp_have" 2>/dev/null; then
        sed -e 's/==.*$//' "$tmp_have" | _strip_list > "$tmp_have.names" && mv "$tmp_have.names" "$tmp_have"
      else
        $PIP_CMD list --user --format=freeze 2>/dev/null | sed -e 's/==.*$//' | _strip_list > "$tmp_have"
      fi
      # Install missing
      if [ "$DRYRUN" = "1" ]; then
        log_info "Would install pip user packages:"; comm -23 "$tmp_want" "$tmp_have" | sed 's/^/- /'
      else
        tmp_missing=$(mktemp)
        comm -23 "$tmp_want" "$tmp_have" > "$tmp_missing"
        if [ -s "$tmp_missing" ]; then xargs -n1 $PIP_CMD install --user < "$tmp_missing"; fi
        rm -f "$tmp_missing"
      fi
      # Uninstall extras
      if [ "$DRYRUN" = "1" ]; then
        log_info "Would uninstall extra pip user packages:"; comm -23 "$tmp_have" "$tmp_want" | sed 's/^/- /'
      else
        tmp_extra=$(mktemp)
        comm -23 "$tmp_have" "$tmp_want" > "$tmp_extra"
        if [ -s "$tmp_extra" ]; then xargs -n1 $PIP_CMD uninstall -y < "$tmp_extra" || true; fi
        rm -f "$tmp_extra"
      fi
      rm -f "$tmp_want" "$tmp_have"
    fi
  fi
fi

log_success "Sync complete."
