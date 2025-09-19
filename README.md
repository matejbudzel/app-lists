# app-lists

Declarative, scriptable management of macOS apps and developer tooling. Keep a set of plain‑text lists as the source of truth, dump your current machine state, and sync or update your system accordingly.

Default list directory: `~/.applists` (override via `OUTDIR` env or `--outdir DIR`).

## Quick start

- Make the umbrella script executable:
  - `chmod +x ./apps.sh`
- Export the current state to lists:
  - `./apps.sh dump-lists`
- Review and edit the lists in `~/.applists/`.
- Apply changes (install missing only):
  - `./apps.sh sync-from-lists`
- Optionally prune extras not in your lists:
  - `./apps.sh sync-from-lists --prune-extras`
- Update existing packages/apps by type (does not need or use app lists):
  - `./apps.sh update-all` or for example `./apps.sh update-all --types brew-casks,npm`
- See which GUI apps you used most recently (does not need or use app lists):
  - `./apps.sh list-last-used`
- Print Homebrew caveats for installed items (does not need or use app lists):
  - `./apps.sh caveats`

## Commands

- `apps dump-lists [--remove-existing] [--force] [--outdir DIR] [--types LIST]`
  - Export the current system into list files in `OUTDIR`.
  - Default keeps existing files. Use `--remove-existing` to clean `OUTDIR` first (will ask to confirm unless `--force`).
  - Supports `--types` for a comma‑separated subset (or positional CSV), e.g. `--types brew-casks,npm`.

- `apps sync-from-lists [--dry-run|-n] [--prune-extras] [--recreate-explicit] [--outdir DIR] [--types LIST] [--force]`
  - Sync machine state to match the lists. Default installs missing only.
  - `--prune-extras` additionally removes items not in the lists (where supported).
  - `--recreate-explicit` only for Brew formulae and pip user packages: uninstall current explicit set then install exactly from lists.
  - `--dry-run` prints planned actions; no changes are made.
  - Interactive confirmations are shown before batch (install/uninstall) actions; `--force` auto‑confirms.

- `apps update-all [--types LIST] [--force]`
  - Update/upgrade installed packages and apps across the selected types. Shows what types will run and asks for confirmation unless `--force`.

- `apps list-last-used`
  - List .app bundles from `/Applications` and `~/Applications` with last‑used time (relative and absolute), most recent first.
  - Uses Spotlight metadata `kMDItemLastUsedDate` (apps with no data show as “never”).

- `apps caveats`
  - Print caveats for installed Homebrew formulae and casks (headers highlighted). Requires `jq`.

Every underlying script supports `--help` and fails fast on unknown options.

## Types

Use `--types` to run a subset. The umbrella `brew` type enables all brew‑related sections.

- `brew` (umbrella)
- `brew-taps`
- `brew-formulae`
- `brew-casks`
- `appstore`
- `manual-apps` (report‑only in sync)
- `arc-extensions` (report‑only in sync)
- `npm`
- `yarn`
- `pnpm`
- `pip`

Examples:

- `--types brew-casks,npm`
- Positional CSV also works: `apps update-all brew-casks,npm`

## List file formats (in `OUTDIR`)

- `brew-taps.txt`: `owner/tap`
- `brew-formulae.txt`: `full/formula/name`
- `brew-casks.txt`: `full/cask/name` (e.g. `homebrew/cask/google-chrome`)
- `appstore-apps.txt`: `ID # App Name` (ID used for installs; name is informational)
- `manual-apps.txt`: App bundle names like `Some App.app` (report‑only in sync)
- `arc-extensions.txt`: one extension ID per line with optional `# Name`
- `npm-global.txt`: package names without versions (scopes preserved)
- `yarn-global.txt`: package names without versions (scopes preserved)
- `pnpm-global.txt`: package names (from `pnpm list -g --json`)
- `pip-user.txt`: user packages (names only; versions stripped)

## Configuration

- `OUTDIR` controls where lists live. Default is `~/.applists`.
  - Override by exporting `OUTDIR` or passing `--outdir DIR`.
  - If both `OUTDIR` and `--outdir` are set to different values, the scripts will error to avoid ambiguity.
- `--types` as noted above limits which sections run.
- `--force` auto‑confirms prompts (use with care).

## Safety and behavior

- Designed to be safe by default:
  - Sync defaults to “install missing only”.
  - Destructive ops (uninstalls, recreations) prompt for confirmation once per batch; `--force` auto‑confirms.
  - `--dry-run` for sync prints planned actions without changing the system.
- Brew bootstrap:
  - If Homebrew is missing, sync can ask to install it. Declining will skip all brew‑related tasks for that run.

## Requirements

- macOS with Bash
- Homebrew for all `brew-*` sections
- `mas` for Mac App Store installs (available in Brew)
- Node package managers as needed: `npm`, `yarn`, `pnpm`
- Python `pip` or `pip3`
- Optional: `jq` (improves accuracy/performance for certain operations)

## License

See `LICENSE`.
