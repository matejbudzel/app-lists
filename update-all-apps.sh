#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_common.sh"

# Accept optional type filtering
# --types LIST or positional LIST (comma-separated), e.g. "npm,yarn,brew-casks"
types_parse_args "$@"

log_step "Starting system-wide package updates..."

# homebrew packages and casks
if has_type brew || has_type brew-formulae || has_type brew-casks; then
  if command -v brew &> /dev/null; then
    log_step "Updating Homebrew..."
    brew update || log_warn "brew update failed"
    if has_type brew || has_type brew-formulae; then
      log_step "Upgrading Homebrew formulae..."
      brew upgrade --formula || log_warn "brew formulae upgrade failed"
    fi
    if has_type brew || has_type brew-casks; then
      log_step "Upgrading Homebrew casks..."
      brew upgrade --cask || log_warn "brew cask upgrade failed"
    fi
    if has_type brew; then
      log_step "Cleaning up Homebrew..."
      brew cleanup || log_warn "brew cleanup failed"
    fi
  else
    log_warn "brew not found, skipping Homebrew updates"
  fi
fi

# Mac App Store apps via mas
if has_type appstore && command -v mas &> /dev/null; then
  log_step "Updating Mac App Store apps..."
  mas upgrade || log_warn "mas upgrade failed"
else
  log_warn "mas not found, skipping Mac App Store updates"
fi

# npm global packages
if has_type npm && command -v npm &> /dev/null; then
  log_step "Updating npm global packages..."
  npm update -g || log_warn "npm update failed"
else
  log_warn "npm not found, skipping npm updates"
fi

# yarn global packages
if has_type yarn && command -v yarn &> /dev/null; then
  log_step "Updating yarn global packages..."
  yarn global upgrade || log_warn "yarn update failed"
else
  log_warn "yarn not found, skipping yarn updates"
fi

# pnpm global packages
if has_type pnpm && command -v pnpm &> /dev/null; then
  log_step "Updating pnpm global packages..."
  pnpm update -g || log_warn "pnpm update failed"
else
  log_warn "pnpm not found, skipping pnpm updates"
fi

# pip — update user packages
PIP_CMD="$(detect_pip_cmd)"

if has_type pip && [ -n "$PIP_CMD" ]; then
  log_step "Updating user Python packages with $PIP_CMD..."
  outdated_pkgs=$($PIP_CMD list --user --outdated 2>/dev/null | awk 'NR>2 {print $1}')
  if [ -n "$outdated_pkgs" ]; then
    echo "$outdated_pkgs" | xargs -n1 -I{} $PIP_CMD install -U --user "{}" || log_warn "pip update failed"
  else
    log_success "No outdated user Python packages found."
  fi
else
  log_warn "pip/pip3 not found, skipping Python package updates"
fi

log_success "System-wide package update completed!"