# app-lists

Declarative, scriptable management of macOS apps and developer tooling. Keep a set of plain-text lists as the source of truth, dump your current machine state, and sync or update your system accordingly.

Default list directory: `~/.applists` (override by exporting `OUTDIR`)

## Scripts

- dump-app-lists.sh
  - Export your current machine state into `OUTDIR`.
  - Flags: `--keep-existing|-k`, `--types LIST` (or positional CSV), `--help`.
- sync-from-app-lists.sh
  - Apply the lists to your machine.
  - Default: install missing only; safe by default, continues on errors.
  - `--prune-extras`: also uninstall items not in the lists (where supported).
  - `--recreate-explicit`: only for Brew formulae and pip user packages, uninstall everything for that type and install exactly from lists.
  - `--types LIST` (or positional CSV); `--dry-run|-n`; `--help`.
  - Manual apps are report-only: prints names of apps from the list that are not installed.
  - Arc extensions are report-only: prints missing/extraneous extension IDs with Chrome Web Store links.
- update-all-apps.sh
  - Update/upgrade installed packages/apps by type.
  - Flags: `--types LIST` (or positional CSV), `--help`.
- list-apps-last-used.sh
  - Show Applications with last-used times (relative and absolute), sorted most recent first.
  - Flags: `--help`.
- print-brew-caveats.sh
  - Print caveats for all installed Homebrew formulae and casks. Headers are highlighted; bodies are plain text.
  - Requires `jq`.

All scripts support `--help` and fail fast on unknown options.

## Types (sections)

- brew (umbrella for all Brew sections)
- brew-taps
- brew-formulae
- brew-casks
- appstore
- manual-apps
- arc-extensions
- npm
- yarn
- pnpm
- pip

Use `--types` to select a subset, e.g. `--types brew-casks,npm`. You can also pass a single positional CSV without `--types`.

## List file formats (in `OUTDIR`)

- brew-taps.txt: `owner/tap`
- brew-formulae.txt: `full/formula/name`
- brew-casks.txt: `full/cask/name` (e.g. `homebrew/cask/google-chrome`)
- appstore-apps.txt: `ID # App Name` (ID used for installs; name is informational)
- manual-apps.txt: App bundle names like `Some App.app` (report-only in sync)
- arc-extensions.txt: one extension ID per line with optional `# Name`
- npm-global.txt: package names without versions (scopes preserved)
- yarn-global.txt: package names without versions (scopes preserved)
- pnpm-global.txt: package names (from `pnpm list -g --json`)
- pip-user.txt: user packages (names only; versions stripped)

## Typical workflows

- First export your current state:
  - `./dump-app-lists.sh`
- Edit lists as desired (add/remove entries).
- Apply changes safely (install missing only):
  - `./sync-from-app-lists.sh`
- Also prune extras (uninstall things not in the lists):
  - `./sync-from-app-lists.sh --prune-extras`
- Arc extensions require manual action; sync will show links to install/uninstall.
- Recreate explicit sets (Brew formulae, pip only):
  - `./sync-from-app-lists.sh --recreate-explicit --types pip,brew-formulae`
- Update existing packages/apps:
  - `./update-all-apps.sh` or `./update-all-apps.sh --types brew-casks,npm`
- See which GUI apps you use most recently:
  - `./list-apps-last-used.sh`

## Safety and behavior

- Fail-safe by default: operations log warnings and continue on per-item failures.
- `--dry-run` for sync shows planned actions without changing the system.
- `--prune-extras` is opt-in; use with care.
- `--recreate-explicit` is intentionally limited to Brew formulae and pip user packages (where dependency handling matters). Casks and global JS package managers are handled via install-missing and optional prune.

## Requirements

- macOS with Bash
- Homebrew for `brew-*` sections
- `mas` for App Store installs (run with sudo for install/uninstall)
- Node managers as needed: `npm`, `yarn`, `pnpm`
- Python `pip` or `pip3`
- Optional: `jq` (improves accuracy/performance for a few operations)

## Configuration

- `_config.sh` defines `OUTDIR` (defaults to `~/.applists`). Set `OUTDIR` env var to change.
- `_common.sh` includes shared helpers for logging and type parsing:
  - `types_parse_args "$@"` populates a global `TYPES` from `--types`/positional CSV.
  - `has_type key` checks if a section is enabled. Empty means “all”.

## License

See `LICENSE`.
