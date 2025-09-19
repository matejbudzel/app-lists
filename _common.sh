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

# Strip helper: remove comments and blank lines, trim whitespace, sort unique
_strip_list() {
  sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' | sort -u
}


# --- OUTDIR helpers ----------------------------------------------------------
# Parse --outdir/--outdir= and resolve against OUTDIR env/default.
# On conflict (both set and differ), prints error and exits 2.
# Usage in scripts:
#   outdir_handle_args "$@"   # sets global OUTDIR appropriately or exits on conflict
outdir_handle_args() {
  local OUTDIR_CLI="" NEXT_OUTDIR=0 arg
  for arg in "$@"; do
    case "$arg" in
      --outdir=*) OUTDIR_CLI="${arg#*=}" ;;
      --outdir) NEXT_OUTDIR=1 ;;
      *)
        if [ "$NEXT_OUTDIR" = "1" ]; then
          OUTDIR_CLI="$arg"; NEXT_OUTDIR=0
        fi
        ;;
    esac
  done
  if [ -n "$OUTDIR_CLI" ]; then
    if [ -n "${OUTDIR:-}" ] && [ "${OUTDIR}" != "${OUTDIR_CLI}" ]; then
      log_error "Conflicting OUTDIR: env/default OUTDIR='${OUTDIR}' vs --outdir='${OUTDIR_CLI}'. Use only one."
      exit 2
    fi
    OUTDIR="$OUTDIR_CLI"
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

# Global FORCE flag to bypass confirmations (scripts can set via --force)
: "${FORCE:=0}"

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

# Return a human-friendly label of selected types. Pass the full list string for the script.
# Usage: label=$(selected_types_label "brew, brew-formulae, ...")
selected_types_label() {
  local all_list="$1"
  if [ -z "${TYPES:-}" ]; then
    printf "all types (%s)" "$all_list"
  else
    printf "%s" "$TYPES"
  fi
}

# Generic confirmation that shows selected types. Returns 0 to proceed, 1 to abort.
# Usage: confirm_continue "$label" "$FORCE" || exit 1
confirm_continue() {
  local selected_label="$1"
  local force_flag="${2:-0}"
  if [ "$force_flag" = "1" ]; then
    return 0
  fi
  if [ -t 0 ]; then
    printf "This will run for: %s\n" "$selected_label"
    read -r -p "Do you want to continue? [y/N]: " _ans
    case "$_ans" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      *) log_error "Aborted by user."; return 1 ;;
    esac
  else
    log_info "Non-interactive session; proceeding without confirmation."
    return 0
  fi
}

# Confirm removal of directory contents if non-empty. Returns 0 to proceed, 1 to abort.
# Usage: confirm_delete_dir_contents "$DIR" "$FORCE" || exit 1
confirm_delete_dir_contents() {
  local dir="$1"
  local force_flag="${2:-0}"
  if [ "$force_flag" = "1" ]; then
    return 0
  fi
  [ -d "$dir" ] || return 0
  if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    return 0
  fi
  if [ -t 0 ]; then
    read -r -p "Directory '$dir' is not empty. Remove its contents before proceeding? [y/N]: " _ans
    case "$_ans" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      *) log_error "Aborted by user."; return 1 ;;
    esac
  else
    log_error "Directory '$dir' is not empty and confirmation is required. Re-run with --force to proceed."
    return 1
  fi
}

