# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a dotfiles repo for Collin Peterson's home directory, tracked at https://github.com/collinp2/dotfiles. It contains shell config, git config, and multiple web development projects under `~/Documents/Websites/`.

## Dotfiles

| File | Purpose |
|------|---------|
| `.zshrc` | Adds `~/.local/bin` and Homebrew (`/opt/homebrew`) to PATH |
| `.zprofile` | Initializes Homebrew for login shells |
| `.gitconfig` | Global git identity and settings |
| `lifekey.pub` | Public SSH key |

## Web Development Projects

Projects live under `~/Documents/Websites/`:

- **Life Path Site 2** — WordPress site hosted on Pantheon (PHP 7.4), git-based deployment
- **Life Path TEST** — Test/staging WordPress installation
- **WoodsonGilchrist** — Squarespace "Wells" template theme with LESS-based styling

## Project Locations

| Project | Path |
|---------|------|
| Life Path WordPress | `~/Documents/Websites/Life Path Site 2/code/` |
| Life Path Config | `~/Documents/Websites/Life Path Site 2/config/` |
| WoodsonGilchrist Theme | `~/Documents/Websites/WoodsonGilchrist/conch-scarlet-sf39/` |

## Life Path Site (WordPress/Pantheon)

**Deployment:** Git-based push to Pantheon. The `code/` directory is the git repo.

**Runtime:** PHP 7.4 (defined in `pantheon.yml`)

**Key ignored paths** (not tracked in git):
- `wp-content/uploads/`, `wp-content/cache/`, `wp-content/backups/`
- `wp-config-local.php` (local DB credentials live here, not in repo)

**WP-CLI:** Local config at `wp-cli.local.yml` in the project root.

## WoodsonGilchrist Theme (Squarespace)

**Template:** Squarespace "Wells" template, configured via `template.conf`.

**Styling:** LESS preprocessor. Source files are `global.less` and `mobile.less` in `styles/`; compiled output is `global.css` and `mobile.css`.

To compile LESS:
```bash
lessc styles/global.less styles/global.css
lessc styles/mobile.less styles/mobile.css
```

**Theme variables** (color, font, layout settings) are defined as LESS variables at the top of `global.less`.
