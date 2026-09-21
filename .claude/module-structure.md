<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# Repository Structure

This repo is currently **scaffolding only** — the config and meta files are present; the Hugo site
itself has not been created yet. The layout below is the intended target once content lands. Create
directories as they are first needed rather than adding empty placeholders.

## Present today

- `docs/` — Non-site documentation assets. The canonical brand mark lives at `images/logo.svg`. The README and
  the future site reference this logo. `images/logo-mark.svg` is the SC mark alone (same paths, no
  wordmark or tagline) for square and small-format uses such as favicons and avatars.
- `docs/design/` — Numbered design documents (`NNNN-<slug>.md`), indexed by `design/README.md` and
  started from `design/TEMPLATE.md`.
- `.github/workflows/` — CI workflows. `200-flow-pull-request-formatting.yaml` validates PR titles
  against the conventional-commit grammar. Follow the numeric-prefix naming convention when adding
  workflows (200 = PR-triggered, 300 = main-branch push, 100 = operational/release, 800 = reusable).
  `200-flow-pull-request-checks.yaml` and `300-flow-main-branch-checks.yaml` run the SPDX license-header
  check in `800-call-license-headers.yaml`, which runs `task lint:license`.
- `.licenserc.yaml` — license-eye policy for SPDX license headers; ignores only files that cannot hold a
  comment.
- `Taskfile.yaml` — repository checks: `task lint:license` (run by CI) and `task license:fix`. The Hugo
  site is still driven by the Hugo CLI.
- `.github/dependabot.yml` — Weekly GitHub Actions version updates with `ci`-prefixed commits,
  grouped into minor/patch and major updates.
- `.github/CODEOWNERS` — Review routing.
- `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, `LICENSE` — Root community
  and policy documents.
- `.claude/` — Agent guidance (this file and its siblings) plus `settings.json`.
  `claude-session.zsh` is the shell integration that names each Claude Code session after its
  repository (`org/repo`) and gives it a color hashed from that name; install it by copying to
  `${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/claude-session.zsh`, which oh-my-zsh auto-sources.

## Intended Hugo layout (create as needed)

- `hugo.toml` (or `hugo.yaml`) — Site configuration: `baseURL`, title, params, menus.
- `content/` — Markdown pages and sections (the documentation and site copy).
- `layouts/` — Templates and partials that override or extend the theme.
- `assets/` — Pipeline-processed assets (SCSS, JS, images run through Hugo Pipes).
- `static/` — Files copied verbatim to the site root (favicons, robots.txt, `logo.svg`).
- `themes/` — Vendored or Hugo-Module theme(s).
- `archetypes/` — Front-matter templates for `hugo new content`.

## Generated (never committed)

- `public/`, `resources/_gen/`, `.hugo_build.lock`, `hugo_stats.json` — build output, gitignored.
