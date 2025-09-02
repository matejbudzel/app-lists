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


# --- Arc browser helpers -----------------------------------------------------
# List installed Arc extension IDs by scanning the Arc User Data profiles.
# Outputs one ID per line (deduplicated). Best-effort.
arc_extensions_list_ids() {
  local base1="$HOME/Library/Application Support/Arc/User Data"
  local base2="$HOME/Library/Application Support/Arc"
  local base=""
  if [ -d "$base1" ]; then
    base="$base1"
  elif [ -d "$base2" ]; then
    base="$base2"
  else
    return 0
  fi
  find "$base" -type d -name Extensions 2>/dev/null \
    | while IFS= read -r extdir; do
        find "$extdir" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null
      done \
    | awk -F'/' '{print $NF}' \
    | grep -E '^[a-z]{16,}$' \
    | sort -u || true
}

# --- Types filtering helpers -------------------------------------------------
# Usage in scripts:
#   types_parse_args "$@"   # sets global TYPES from --types or positional CSV
#   if has_type npm; then ...; fi

# Global TYPES variable (empty means all types enabled)
: "${TYPES:=}"

types_parse_args() {
  local NEXT_TYPES=0
  for arg in "$@"; do
    case "$arg" in
      --types=*) TYPES="${arg#*=}" ;;
      --types) NEXT_TYPES=1 ;;
      *)
        if [ "$NEXT_TYPES" = "1" ]; then TYPES="$arg"; NEXT_TYPES=0
        elif [ -z "${TYPES:-}" ] && [[ "$arg" != -* ]]; then TYPES="$arg"; fi ;;
    esac
  done
}

has_type() {
  local key="$1"
  if [ -z "${TYPES:-}" ]; then return 0; fi
  case ",${TYPES}," in
    *",${key}," ) return 0 ;;
    * ) return 1 ;;
  esac
}

