#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_common.sh"

log_step "Starting system-wide package updates..."

# homebrew packages and casks
if command -v brew &> /dev/null; then
  log_step "Updating Homebrew packages and casks..."
  brew update && brew upgrade && brew cleanup || log_warn "brew update/upgrade/cleanup failed"
else
  log_warn "brew not found, skipping Homebrew updates"
fi

# Mac App Store apps via mas
if command -v mas &> /dev/null; then
  log_step "Updating Mac App Store apps..."
  mas upgrade || log_warn "mas upgrade failed"
else
  log_warn "mas not found, skipping Mac App Store updates"
fi

# npm global packages
if command -v npm &> /dev/null; then
  log_step "Updating npm global packages..."
  npm update -g || log_warn "npm update failed"
else
  log_warn "npm not found, skipping npm updates"
fi

# yarn global packages
if command -v yarn &> /dev/null; then
  log_step "Updating yarn global packages..."
  yarn global upgrade || log_warn "yarn update failed"
else
  log_warn "yarn not found, skipping yarn updates"
fi

# pnpm global packages
if command -v pnpm &> /dev/null; then
  log_step "Updating pnpm global packages..."
  pnpm update -g || log_warn "pnpm update failed"
else
  log_warn "pnpm not found, skipping pnpm updates"
fi

# pip — update user packages
PIP_CMD="$(detect_pip_cmd)"

if [ -n "$PIP_CMD" ]; then
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