#!/bin/bash

# Common helper functions for shell scripts in this directory

# detect_pip_cmd prints the preferred pip command (pip3, then pip) or an empty string if neither exists.
detect_pip_cmd() {
  if command -v pip3 >/dev/null 2>&1; then
    echo pip3
  elif command -v pip >/dev/null 2>&1; then
    echo pip
  else
    echo ""
  fi
}

# --- Pretty output helpers ----------------------------------------------------
# Use tput for colors when stdout is a TTY; otherwise, no color.
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  _colors=$(tput colors 2>/dev/null || echo 0)
else
  _colors=0
fi

if [ "${_colors:-0}" -ge 8 ]; then
  _BOLD=$(tput bold); _DIM=$(tput dim); _RESET=$(tput sgr0)
  _RED=$(tput setaf 1); _GREEN=$(tput setaf 2); _YELLOW=$(tput setaf 3)
  # Prefer a lighter/brighter blue when available
  if [ "${_colors:-0}" -ge 16 ]; then
    _BLUE=$(tput setaf 12)  # bright blue
  else
    _BLUE="${_BOLD}$(tput setaf 4)"  # bold standard blue for better contrast
  fi
else
  _BOLD=""; _DIM=""; _RESET=""; _RED=""; _GREEN=""; _YELLOW=""; _BLUE=""
fi
unset _colors

log_info()    { printf "%sℹ️  %s%s\n" "${_BLUE}"   "$*" "${_RESET}"; }
log_warn()    { printf "%s⚠️  %s%s\n" "${_YELLOW}" "$*" "${_RESET}"; }
log_success() { printf "%s✅ %s%s\n"  "${_GREEN}"  "$*" "${_RESET}"; }
log_error()   { printf "%s❌ %s%s\n"  "${_RED}"    "$*" "${_RESET}" >&2; }
log_step()    { printf "%s➡️  %s%s\n"  "${_BOLD}"   "$*" "${_RESET}"; }

