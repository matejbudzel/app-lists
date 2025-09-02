#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_common.sh"
. "$SCRIPT_DIR/_config.sh"

# Parse shared --types/positional CSV into global TYPES
types_parse_args "$@"

log_step "Starting environment install..."

# --- Homebrew ---
if has_type brew || has_type brew-taps || has_type brew-formulae || has_type brew-casks; then
  if ! command -v brew &> /dev/null; then
      log_step "Installing Homebrew..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  brew update

  if (has_type brew || has_type brew-taps) && [ -f "$OUTDIR/brew-taps.txt" ] && [ -s "$OUTDIR/brew-taps.txt" ]; then
      log_step "Processing Homebrew taps (skipping already tapped)..."
      current_taps="$(brew tap 2>/dev/null || true)"
      tmp_want_taps=$(mktemp)
      sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' "$OUTDIR/brew-taps.txt" | sort -u > "$tmp_want_taps"
      while IFS= read -r tap; do
          [ -z "$tap" ] && continue
          if printf '%s\n' "$current_taps" | grep -Fxq "$tap"; then
              log_success "$tap already tapped"
              continue
          fi
          log_step "Tapping $tap ..."
          brew tap "$tap" || log_warn "Failed to tap $tap (continuing)"
      done < "$tmp_want_taps"
      rm -f "$tmp_want_taps"
  fi

  if (has_type brew || has_type brew-formulae) && [ -f "$OUTDIR/brew-formulae.txt" ]; then
      log_step "Installing Homebrew formulae..."
      xargs brew install < "$OUTDIR/brew-formulae.txt"
  fi

  if (has_type brew || has_type brew-casks) && [ -f "$OUTDIR/brew-casks.txt" ]; then
      log_step "Installing Homebrew casks..."
      tmp_cask_log_dir="$(mktemp -d 2>/dev/null || mktemp -d -t casklogs)"
      while IFS= read -r cask; do
          token="${cask##*/}"
          if brew list --cask "$token" >/dev/null 2>&1; then
              log_success "$cask already installed (brew)"
              continue
          fi
          log_step "Installing cask $cask (logs: $tmp_cask_log_dir/$token.log)"
          if ! brew install --cask "$cask" >"$tmp_cask_log_dir/$token.log" 2>&1; then
              log_warn "$cask: install failed"
          else
              log_success "Installed $cask"
          fi
      done < <(sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' "$OUTDIR/brew-casks.txt")
  fi
fi

# --- Mac App Store ---
if has_type appstore && [ -f "$OUTDIR/appstore-apps.txt" ] && command -v mas &> /dev/null; then
    log_step "Installing Mac App Store apps..."
    awk -F'#' '{gsub(/^[ \t]+|[ \t]+$/,"",$1); if ($1 ~ /^[0-9]+$/) print $1}' "$OUTDIR/appstore-apps.txt" | xargs mas install
fi

# --- npm ---
if has_type npm && [ -f "$OUTDIR/npm-global.txt" ] && command -v npm &> /dev/null; then
    log_step "Installing global npm packages..."
    xargs npm install -g < "$OUTDIR/npm-global.txt"
fi

# --- Yarn ---
if has_type yarn && [ -f "$OUTDIR/yarn-global.txt" ] && command -v yarn &> /dev/null; then
    log_step "Installing global Yarn packages..."
    xargs yarn global add < "$OUTDIR/yarn-global.txt"
fi

# --- pnpm ---
if has_type pnpm && [ -f "$OUTDIR/pnpm-global.txt" ] && command -v pnpm &> /dev/null; then
    log_step "Installing global pnpm packages..."
    xargs pnpm add -g < "$OUTDIR/pnpm-global.txt"
fi

# --- pip ---
if has_type pip && [ -f "$OUTDIR/pip-user.txt" ]; then
    PIP_INSTALL_CMD=""
    if command -v pip3 &> /dev/null; then PIP_INSTALL_CMD=pip3; elif command -v pip &> /dev/null; then PIP_INSTALL_CMD=pip; fi
    if [ -n "$PIP_INSTALL_CMD" ]; then
        log_step "Installing user pip packages (via $PIP_INSTALL_CMD)..."
        $PIP_INSTALL_CMD install --user -r "$OUTDIR/pip-user.txt"
    fi
fi

# --- Manual Apps ---
if has_type manual-apps && [ -f "$OUTDIR/manual-apps.txt" ]; then
    log_warn "These apps need to be installed manually (not via Brew/MAS):"
    while IFS= read -r app || [ -n "$app" ]; do
        [ -z "$app" ] && continue
        case "$app" in \#*) continue;; esac
        if [ ! -e "/Applications/$app" ] && [ ! -e "$HOME/Applications/$app" ]; then
            log_info "$app"
        fi
    done < "$OUTDIR/manual-apps.txt"
fi

log_success "Install complete."

