#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_common.sh"
. "$SCRIPT_DIR/_config.sh"

# Help/usage
usage() {
  cat <<'EOF'
Usage: sync-from-app-lists.sh [options] [--outdir DIR] [--types LIST]

Sync machine state against lists in ~/.applists. By default installs missing
items only. Use --prune-extras to also uninstall extras. Use --recreate-explicit
only for Brew formulae and pip user packages to rebuild exactly from lists.

Options:
  --dry-run, -n           Show planned actions only; do not change system
  --prune-extras          Also uninstall items not listed for supported types
                          (brew taps/formulae/casks, appstore, npm, yarn, pnpm, pip).
                          The arc-extensions and manual-apps types are report-only.
  --recreate-explicit     Only for Brew formulae and pip user packages
  --force                 Auto-confirm all prompts (potentially dangerous; be sure before using)
  --outdir DIR            Lists directory (defaults to $HOME/.applists or OUTDIR env)
                          If both OUTDIR env and --outdir are set with different values, an error is raised
  --types LIST            Comma-separated types, or positional CSV
                          Types: brew, brew-taps, brew-formulae, brew-casks,
                                 appstore, manual-apps, arc-extensions,
                                 npm, yarn, pnpm, pip
  --help, -h              Show this help and exit

Examples:
  sync-from-app-lists.sh
  sync-from-app-lists.sh --types brew-casks,npm
  sync-from-app-lists.sh --prune-extras --types brew
  sync-from-app-lists.sh --recreate-explicit --types pip,brew-formulae
EOF
}

DRYRUN=0
RECREATE_EXPLICIT=0
PRUNE_EXTRAS=0
SKIP_BREW=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRYRUN=1 ;;
    --recreate-explicit) RECREATE_EXPLICIT=1 ;;
    --prune-extras) PRUNE_EXTRAS=1 ;;
    --force) FORCE=1 ;;
    --help|-h) usage; exit 0 ;;
    --types|--types=*) : ;;
    --outdir|--outdir=*) : ;;
    -*) log_error "Unknown option: $arg"; usage; exit 2 ;;
  esac
done

# Parse shared --types/positional CSV into global TYPES
types_parse_args "$@"

# has_type() provided by _common.sh; empty TYPES => all enabled.

# Resolve OUTDIR from CLI vs env/default and detect conflicts
outdir_handle_args "$@"

if [ "$DRYRUN" = "1" ]; then
  log_step "Starting sync (DRY-RUN) from $OUTDIR ..."
else
  log_step "Starting sync from $OUTDIR ..."
fi

# --- Homebrew ---------------------------------------------------------------
if has_type brew || has_type brew-taps || has_type brew-formulae || has_type brew-casks; then
  if ! command -v brew &> /dev/null; then
    # Ask for confirmation before installing Homebrew; if declined, skip all brew tasks
    if confirm_continue "Install Homebrew (official install script)" "$FORCE"; then
      log_step "Installing Homebrew..."
      if [ "$DRYRUN" = "1" ]; then
        log_info "Would run: Homebrew install script"
      else
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      fi
    else
      SKIP_BREW=1
      log_warn "User declined Homebrew install; skipping all Homebrew-related sync tasks."
    fi
  fi
  if [ "$SKIP_BREW" != "1" ]; then
    if [ "$DRYRUN" = "1" ]; then
      log_info "Would run: brew update"
    else
      brew update || log_warn "brew update failed (continuing)"
    fi
  fi
fi

# Taps: add missing (do not prune by default)
if [ "$SKIP_BREW" != "1" ] && (has_type brew || has_type brew-taps) && [ -f "$OUTDIR/brew-taps.txt" ] && [ -s "$OUTDIR/brew-taps.txt" ]; then
  current_taps="$(brew tap 2>/dev/null || true)"
  tmp_want=$(mktemp); tmp_have=$(mktemp)
  _strip_list < "$OUTDIR/brew-taps.txt" > "$tmp_want"
  printf '%s\n' "$current_taps" | sort -u > "$tmp_have"
  tmp_missing=$(mktemp)
  comm -23 "$tmp_want" "$tmp_have" > "$tmp_missing"
  # Install missing taps
  if [ -s "$tmp_missing" ]; then
    if [ "$DRYRUN" = "1" ]; then
      log_info "Would tap:"; sed 's/^/- /' "$tmp_missing"
    else
      count=$(wc -l < "$tmp_missing" | tr -d ' ')
      if confirm_continue "Tap $count Homebrew tap(s)" "$FORCE"; then
        while IFS= read -r tap; do
          [ -z "$tap" ] && continue
          log_step "Tapping: $tap"; brew tap "$tap" || log_warn "Failed to tap $tap (continuing)"
        done < "$tmp_missing"
      else
        log_warn "Skipped tapping Homebrew taps by user choice."
      fi
    fi
  fi
  if [ "$PRUNE_EXTRAS" = "1" ]; then
    if [ "$DRYRUN" = "1" ]; then
      log_info "Would untap extra taps:"; comm -23 "$tmp_have" "$tmp_want" | sed 's/^/- /'
    else
      tmp_extra=$(mktemp)
      comm -23 "$tmp_have" "$tmp_want" > "$tmp_extra"
      if [ -s "$tmp_extra" ]; then
        count=$(wc -l < "$tmp_extra" | tr -d ' ')
        if confirm_continue "Untap $count extra Homebrew tap(s)" "$FORCE"; then
          while IFS= read -r etap; do
            [ -z "$etap" ] && continue
            log_step "Untapping $etap"
            brew untap "$etap" || log_warn "Failed to untap $etap (continuing)"
          done < "$tmp_extra"
        else
          log_warn "Skipped untapping extra Homebrew taps by user choice."
        fi
      fi
      rm -f "$tmp_extra"
    fi
  fi
  rm -f "$tmp_want" "$tmp_have"
  rm -f "$tmp_missing"
fi

# Formulae
if [ "$SKIP_BREW" != "1" ] && (has_type brew || has_type brew-formulae) && [ -f "$OUTDIR/brew-formulae.txt" ]; then
  if [ "$RECREATE_EXPLICIT" = "1" ]; then
    log_step "Syncing Brew formulae (recreate explicit set) ..."
    if [ "$DRYRUN" = "1" ]; then
      log_info "Would iteratively uninstall all brew formulae leaves until none remain"
      log_info "Would install from: $OUTDIR/brew-formulae.txt"
      log_info "Would run: brew autoremove"
    else
      if ! confirm_continue "Uninstall all current Homebrew formulae leaves" "$FORCE"; then
        log_warn "Skipped recreating explicit Homebrew formulae set by user choice."
        : > /dev/null
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
      # Install each formula from list with per-item logging
      if confirm_continue "Install Homebrew formulae from list" "$FORCE"; then
        while IFS= read -r formula; do
          [ -z "$formula" ] && continue
          log_step "Installing formula $formula"
          brew install "$formula" || log_warn "$formula: install failed (continuing)"
        done < "$OUTDIR/brew-formulae.txt"
        if confirm_continue "Run 'brew autoremove' to prune unused dependencies" "$FORCE"; then
          brew autoremove || true
        else
          log_warn "Skipped 'brew autoremove' by user choice."
        fi
      else
        log_warn "Skipped installing Homebrew formulae from list by user choice."
      fi
      fi
    fi
  else
    if [ "$PRUNE_EXTRAS" = "1" ]; then
      log_step "Syncing Brew formulae (prune extra leaves, install missing) ..."
    else
      log_step "Syncing Brew formulae (install missing only) ..."
    fi
    tmp_want=$(mktemp); tmp_leaves=$(mktemp); tmp_installed=$(mktemp)
    _strip_list < "$OUTDIR/brew-formulae.txt" > "$tmp_want"
    brew leaves --full-name 2>/dev/null | sort -u > "$tmp_leaves" || brew leaves | sort -u > "$tmp_leaves" || true
    brew list --formula --full-name 2>/dev/null | sort -u > "$tmp_installed" || true

    # Install missing
    if [ "$DRYRUN" = "1" ]; then
      log_info "Would install formulae:"; comm -23 "$tmp_want" "$tmp_installed" | sed 's/^/- /'
    else
      tmp_missing=$(mktemp)
      comm -23 "$tmp_want" "$tmp_leaves" > "$tmp_missing"
      if [ -s "$tmp_missing" ]; then
        count=$(wc -l < "$tmp_missing" | tr -d ' ')
        if confirm_continue "Install/reinstall $count Homebrew formula(e) to match list" "$FORCE"; then
          while IFS= read -r formula; do
            [ -z "$formula" ] && continue
            if grep -Fxq "$formula" "$tmp_installed"; then
              log_step "Reinstalling formula $formula to mark as explicit"
              brew reinstall "$formula" || log_warn "$formula: reinstall failed (continuing)"
            else
              log_step "Installing formula $formula"
              brew install "$formula" || log_warn "$formula: install failed (continuing)"
            fi
          done < "$tmp_missing"
        else
          log_warn "Skipped installing/reinstalling Homebrew formulae by user choice."
        fi
      fi
      rm -f "$tmp_missing"
    fi

    # Prune extra leaves not in wanted list (only if requested)
    if [ "$PRUNE_EXTRAS" = "1" ]; then
      if [ "$DRYRUN" = "1" ]; then
        log_info "Would uninstall extra leaf formulae:"; comm -23 "$tmp_leaves" "$tmp_want" | sed 's/^/- /'
        log_info "Would run: brew autoremove"
      else
        tmp_extra=$(mktemp)
        comm -23 "$tmp_leaves" "$tmp_want" > "$tmp_extra"
        if [ -s "$tmp_extra" ]; then
          count=$(wc -l < "$tmp_extra" | tr -d ' ')
          if confirm_continue "Uninstall $count extra Homebrew formula(e)" "$FORCE"; then
            xargs brew uninstall < "$tmp_extra" || true
          else
            log_warn "Skipped uninstalling extra Homebrew formulae by user choice."
          fi
        fi
        rm -f "$tmp_extra"
        if confirm_continue "Run 'brew autoremove' to prune unused dependencies" "$FORCE"; then
          brew autoremove || true
        else
          log_warn "Skipped 'brew autoremove' by user choice."
        fi
      fi
    fi
    rm -f "$tmp_want" "$tmp_leaves" "$tmp_installed"
  fi
fi

# Casks: install missing by default; support prune extras
if [ "$SKIP_BREW" != "1" ] && (has_type brew || has_type brew-casks) && [ -f "$OUTDIR/brew-casks.txt" ]; then
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
      count=$(wc -l < "$tmp_missing" | tr -d ' ')
      if confirm_continue "Install $count Homebrew cask(s)" "$FORCE"; then
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
      else
        log_warn "Skipped installing Homebrew casks by user choice."
      fi
    fi
    rm -f "$tmp_missing"
  fi
  # Uninstall extras only when requested
  if [ "$PRUNE_EXTRAS" = "1" ]; then
    if [ "$DRYRUN" = "1" ]; then
      log_info "Would uninstall extra casks:"; comm -23 "$tmp_have" "$tmp_want" | sed 's/^/- /'
    else
      tmp_extra=$(mktemp)
      comm -23 "$tmp_have" "$tmp_want" > "$tmp_extra"
      if [ -s "$tmp_extra" ]; then
        count=$(wc -l < "$tmp_extra" | tr -d ' ')
        if confirm_continue "Uninstall $count extra Homebrew cask(s)" "$FORCE"; then
          xargs -n1 brew uninstall --cask < "$tmp_extra" || true
        else
          log_warn "Skipped uninstalling extra Homebrew casks by user choice."
        fi
      fi
      rm -f "$tmp_extra"
    fi
  fi
  rm -f "$tmp_want" "$tmp_have"
fi

# --- Mac App Store ----------------------------------------------------------
if has_type appstore && [ -f "$OUTDIR/appstore-apps.txt" ] && command -v mas &> /dev/null; then
  log_step "Syncing Mac App Store apps (install missing only) ..."
  tmp_want=$(mktemp); tmp_have=$(mktemp)
  awk -F'#' '{gsub(/^[ \t]+|[ \t]+$/,"",$1); if ($1 ~ /^[0-9]+$/) print $1}' "$OUTDIR/appstore-apps.txt" | sort -u > "$tmp_want"
  mas list | awk '{print $1}' | sort -u > "$tmp_have" || true
  if [ "$DRYRUN" = "1" ]; then
    log_info "Would install MAS app IDs:"; comm -23 "$tmp_want" "$tmp_have" | sed 's/^/- /'
  else
    tmp_missing=$(mktemp)
    comm -23 "$tmp_want" "$tmp_have" > "$tmp_missing"
    if [ -s "$tmp_missing" ]; then
      count=$(wc -l < "$tmp_missing" | tr -d ' ')
      if confirm_continue "Install $count Mac App Store app(s)" "$FORCE"; then
        xargs -n1 mas install < "$tmp_missing" || true
      else
        log_warn "Skipped installing Mac App Store apps by user choice."
      fi
    fi
    rm -f "$tmp_missing"
  fi
  if [ "$PRUNE_EXTRAS" = "1" ]; then
    if [ "$DRYRUN" = "1" ]; then
      log_info "Would uninstall extra MAS apps:"; comm -23 "$tmp_have" "$tmp_want" | sed 's/^/- /'
    else
      tmp_extra=$(mktemp)
      comm -23 "$tmp_have" "$tmp_want" > "$tmp_extra"
      if [ -s "$tmp_extra" ]; then
        count=$(wc -l < "$tmp_extra" | tr -d ' ')
        if confirm_continue "Uninstall $count Mac App Store app(s)" "$FORCE"; then
          while IFS= read -r appid; do
            [ -z "$appid" ] && continue
            log_step "Uninstalling MAS app $appid"
            mas uninstall "$appid" || log_warn "$appid: uninstall failed (continuing)"
          done < "$tmp_extra"
        else
          log_warn "Skipped uninstalling Mac App Store apps by user choice."
        fi
      fi
      rm -f "$tmp_extra"
    fi
  fi
  rm -f "$tmp_want" "$tmp_have"
fi

# --- npm --------------------------------------------------------------------
if has_type npm && [ -f "$OUTDIR/npm-global.txt" ] && command -v npm &> /dev/null; then
  log_step "Syncing global npm packages (install missing only) ..."
  tmp_want=$(mktemp); tmp_have=$(mktemp)
  _strip_list < "$OUTDIR/npm-global.txt" > "$tmp_want"
  npm list -g --depth=0 2>/dev/null | tail -n +2 | awk '{print $2}' | sed -E 's/@[^@]+$//' | sort -u > "$tmp_have" || true
  if [ "$DRYRUN" = "1" ]; then
    log_info "Would install npm globals:"; comm -23 "$tmp_want" "$tmp_have" | sed 's/^/- /'
  else
    tmp_missing=$(mktemp)
    comm -23 "$tmp_want" "$tmp_have" > "$tmp_missing"
    if [ -s "$tmp_missing" ]; then
      count=$(wc -l < "$tmp_missing" | tr -d ' ')
      if confirm_continue "Install $count global npm package(s)" "$FORCE"; then
        xargs npm install -g < "$tmp_missing" || true
      else
        log_warn "Skipped installing global npm packages by user choice."
      fi
    fi
    rm -f "$tmp_missing"
  fi
  if [ "$PRUNE_EXTRAS" = "1" ]; then
    if [ "$DRYRUN" = "1" ]; then
      log_info "Would uninstall extra npm globals:"; comm -23 "$tmp_have" "$tmp_want" | sed 's/^/- /'
    else
      tmp_extra=$(mktemp)
      comm -23 "$tmp_have" "$tmp_want" > "$tmp_extra"
      if [ -s "$tmp_extra" ]; then
        count=$(wc -l < "$tmp_extra" | tr -d ' ')
        if confirm_continue "Uninstall $count extra global npm package(s)" "$FORCE"; then
          xargs -n1 npm uninstall -g < "$tmp_extra" || true
        else
          log_warn "Skipped uninstalling extra global npm packages by user choice."
        fi
      fi
      rm -f "$tmp_extra"
    fi
  fi
  rm -f "$tmp_want" "$tmp_have"
fi

# --- Yarn -------------------------------------------------------------------
if has_type yarn && [ -f "$OUTDIR/yarn-global.txt" ] && command -v yarn &> /dev/null; then
  log_step "Syncing global Yarn packages (install missing only) ..."
  tmp_want=$(mktemp); tmp_have=$(mktemp)
  _strip_list < "$OUTDIR/yarn-global.txt" > "$tmp_want"
  yarn global list --depth=0 2>/dev/null | awk '/info "[^"]+"/{gsub(/.*info \"/,"",$0); gsub(/\".*/,"",$0); print}' | sed -E 's/@[^@]+$//' | sort -u > "$tmp_have" || true
  if [ "$DRYRUN" = "1" ]; then
    log_info "Would install Yarn globals:"; comm -23 "$tmp_want" "$tmp_have" | sed 's/^/- /'
  else
    tmp_missing=$(mktemp)
    comm -23 "$tmp_want" "$tmp_have" > "$tmp_missing"
    if [ -s "$tmp_missing" ]; then
      count=$(wc -l < "$tmp_missing" | tr -d ' ')
      if confirm_continue "Install $count global Yarn package(s)" "$FORCE"; then
        xargs yarn global add < "$tmp_missing" || true
      else
        log_warn "Skipped installing global Yarn packages by user choice."
      fi
    fi
    rm -f "$tmp_missing"
  fi
  if [ "$PRUNE_EXTRAS" = "1" ]; then
    if [ "$DRYRUN" = "1" ]; then
      log_info "Would uninstall extra Yarn globals:"; comm -23 "$tmp_have" "$tmp_want" | sed 's/^/- /'
    else
      tmp_extra=$(mktemp)
      comm -23 "$tmp_have" "$tmp_want" > "$tmp_extra"
      if [ -s "$tmp_extra" ]; then
        count=$(wc -l < "$tmp_extra" | tr -d ' ')
        if confirm_continue "Uninstall $count extra global Yarn package(s)" "$FORCE"; then
          xargs -n1 yarn global remove < "$tmp_extra" || true
        else
          log_warn "Skipped uninstalling extra global Yarn packages by user choice."
        fi
      fi
      rm -f "$tmp_extra"
    fi
  fi
  rm -f "$tmp_want" "$tmp_have"
fi

# --- pnpm -------------------------------------------------------------------
if has_type pnpm && [ -f "$OUTDIR/pnpm-global.txt" ] && command -v pnpm &> /dev/null; then
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
    if [ -s "$tmp_missing" ]; then
      count=$(wc -l < "$tmp_missing" | tr -d ' ')
      if confirm_continue "Install $count global pnpm package(s)" "$FORCE"; then
        xargs pnpm add -g < "$tmp_missing" || true
      else
        log_warn "Skipped installing global pnpm packages by user choice."
      fi
    fi
    rm -f "$tmp_missing"
  fi
  if [ "$PRUNE_EXTRAS" = "1" ]; then
    if [ "$DRYRUN" = "1" ]; then
      log_info "Would uninstall extra pnpm globals:"; comm -23 "$tmp_have" "$tmp_want" | sed 's/^/- /'
    else
      tmp_extra=$(mktemp)
      comm -23 "$tmp_have" "$tmp_want" > "$tmp_extra"
      if [ -s "$tmp_extra" ]; then
        count=$(wc -l < "$tmp_extra" | tr -d ' ')
        if confirm_continue "Uninstall $count extra global pnpm package(s)" "$FORCE"; then
          xargs -n1 pnpm remove -g < "$tmp_extra" || true
        else
          log_warn "Skipped uninstalling extra global pnpm packages by user choice."
        fi
      fi
      rm -f "$tmp_extra"
    fi
  fi
  rm -f "$tmp_want" "$tmp_have"
fi

# --- pip (user) -------------------------------------------------------------
if has_type pip && [ -f "$OUTDIR/pip-user.txt" ]; then
  PIP_CMD="$(detect_pip_cmd)"
  if [ -n "$PIP_CMD" ]; then
    if [ "$RECREATE_EXPLICIT" = "1" ]; then
      log_step "Syncing user pip packages (recreate explicit set) via $PIP_CMD ..."
      if [ "$DRYRUN" = "1" ]; then
        log_info "Would uninstall all user pip packages"
        log_info "Would install from: $OUTDIR/pip-user.txt"
      else
        if confirm_continue "Uninstall all user pip packages" "$FORCE"; then
          # Uninstall all user packages
          $PIP_CMD freeze --user | sed -e 's/==.*$//' | xargs -n1 $PIP_CMD uninstall -y || true
        else
          log_warn "Skipped uninstalling all user pip packages by user choice."
        fi
        if confirm_continue "Install user pip packages from list" "$FORCE"; then
          $PIP_CMD install --user -r "$OUTDIR/pip-user.txt" || true
        else
          log_warn "Skipped installing user pip packages from list by user choice."
        fi
      fi
    else
      log_step "Syncing user pip packages (prune extras, install missing) via $PIP_CMD ..."
      tmp_want=$(mktemp); tmp_have_top=$(mktemp); tmp_have_all=$(mktemp)
      awk -F'==' 'NF{print $1}' "$OUTDIR/pip-user.txt" | _strip_list > "$tmp_want"
      # installed top-level user packages (not-required)
      if $PIP_CMD list --user --not-required --format=json > "$tmp_have_top.json" 2>/dev/null && command -v jq &> /dev/null; then
        jq -r '.[].name' "$tmp_have_top.json" | _strip_list > "$tmp_have_top" && rm -f "$tmp_have_top.json"
      elif $PIP_CMD list --user --not-required --format=freeze > "$tmp_have_top" 2>/dev/null; then
        sed -e 's/==.*$//' "$tmp_have_top" | _strip_list > "$tmp_have_top.names" && mv "$tmp_have_top.names" "$tmp_have_top"
      else
        # Fallback if --not-required unsupported: approximate using full list below
        : > "$tmp_have_top"
      fi
      # installed user packages (all)
      $PIP_CMD list --user --format=freeze 2>/dev/null | sed -e 's/==.*$//' | _strip_list > "$tmp_have_all"
      # Install missing (relative to all user-installed)
      if [ "$DRYRUN" = "1" ]; then
        log_info "Would install pip user packages:"; comm -23 "$tmp_want" "$tmp_have_all" | sed 's/^/- /'
      else
        tmp_missing=$(mktemp)
        comm -23 "$tmp_want" "$tmp_have_all" > "$tmp_missing"
        if [ -s "$tmp_missing" ]; then
          count=$(wc -l < "$tmp_missing" | tr -d ' ')
          if confirm_continue "Install $count user pip package(s)" "$FORCE"; then
            xargs -n1 $PIP_CMD install --user --force-reinstall < "$tmp_missing" || true
          else
            log_warn "Skipped installing user pip packages by user choice."
          fi
        fi
        rm -f "$tmp_missing"
      fi
      # Uninstall extras (only when requested), considering only top-level user pkgs
      if [ "$PRUNE_EXTRAS" = "1" ]; then
        if [ "$DRYRUN" = "1" ]; then
          log_info "Would uninstall extra pip user packages:"; comm -23 "$tmp_have_top" "$tmp_want" | sed 's/^/- /'
        else
          tmp_extra=$(mktemp)
          comm -23 "$tmp_have_top" "$tmp_want" > "$tmp_extra"
          if [ -s "$tmp_extra" ]; then
            count=$(wc -l < "$tmp_extra" | tr -d ' ')
            if confirm_continue "Uninstall $count extra user pip package(s)" "$FORCE"; then
              xargs -n1 $PIP_CMD uninstall -y < "$tmp_extra" || true
            else
              log_warn "Skipped uninstalling extra user pip packages by user choice."
            fi
          fi
          rm -f "$tmp_extra"
        fi
      fi
      rm -f "$tmp_want" "$tmp_have_top" "$tmp_have_all"
    fi
  fi
fi

# --- Manual Apps (report-only) ----------------------------------------------
if has_type manual-apps && [ -f "$OUTDIR/manual-apps.txt" ]; then
  log_step "Checking manual apps (not managed by Brew/MAS) ..."
  tmp_want=$(mktemp)
  _strip_list < "$OUTDIR/manual-apps.txt" > "$tmp_want"
  tmp_missing=$(mktemp)
  while IFS= read -r app; do
    [ -z "$app" ] && continue
    case "$app" in \#*) continue;; esac
    if [ -e "/Applications/$app" ] || [ -e "$HOME/Applications/$app" ]; then
      :
    else
      echo "$app" >> "$tmp_missing"
    fi
  done < "$tmp_want"
  if [ -s "$tmp_missing" ]; then
    # Print just the app names (no prefixes), one per line
    cat "$tmp_missing"
  else
    log_success "All manual apps from list are already installed."
  fi
  rm -f "$tmp_want" "$tmp_missing"
fi


# --- Arc extensions (report-only) --------------------------------------------
if has_type arc-extensions; then
  log_step "Checking Arc extensions (report-only) ..."
  tmp_want=$(mktemp); tmp_have=$(mktemp)
  if [ -f "$OUTDIR/arc-extensions.txt" ]; then
    awk -F'#' '{gsub(/^[ \t]+|[ \t]+$/,"",$1); if ($1 ~ /^[a-z]{16,}$/) print $1}' "$OUTDIR/arc-extensions.txt" | sort -u > "$tmp_want"
  else
    : > "$tmp_want"
  fi
  arc_extensions_list_ids | sort -u > "$tmp_have" || :
  # Compute sets
  missing=$(comm -23 "$tmp_want" "$tmp_have" || true)
  extra=$(comm -23 "$tmp_have" "$tmp_want" || true)
  # Report missing
  if [ -n "$missing" ]; then
    log_info "Extensions to install (manual):"
    printf '%s\n' "$missing" | awk '{printf("- %s => https://chrome.google.com/webstore/detail/%s\n", $0, $0)}'
  else
    log_success "No missing Arc extensions"
  fi
  # Report extras when pruning
  if [ "$PRUNE_EXTRAS" = "1" ]; then
    if [ -n "$extra" ]; then
      log_info "Extensions to remove (manual):"
      printf '%s\n' "$extra" | awk '{printf("- %s => https://chrome.google.com/webstore/detail/%s\n", $0, $0)}'
    else
      log_success "No extra Arc extensions"
    fi
  fi
  rm -f "$tmp_want" "$tmp_have"
fi

log_success "Sync complete."
