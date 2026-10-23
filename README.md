# Punchlist

*Your repos' to-dos, beside your code.*

Punchlist is a small macOS companion for when you're coding: it shows the open issues across your GitHub repositories as one list you can keep next to your editor, lets you jot down a new one in a second, and gives you a quick look at pull requests when you need it. It has no GitHub code of its own: everything goes through the [`gh` CLI](https://cli.github.com) you already have installed and signed in, so it never sees or stores a token.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/main-dark.png">
  <img alt="Punchlist with a list of open issues across several repositories and one issue's detail with its comments" src="docs/screenshots/main-light.png">
</picture>

## Features

- One list of the open issues or pull requests across every repository you own, optionally including your organizations.
- Filters for repository, status (open, closed, merged, all) and labels, plus search by title, repository, number or author.
- Issue and pull request detail with GitHub-style Markdown and the conversation's comments.
- Create an issue from the first row of the list: type a title, pick the repository, press Return.
- A native macOS 27 layout: a resizable glass sidebar beside the detail. Below 640 points wide, the window switches to a single list, and the detail slides in over it:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/compact-dark.png">
  <img alt="The narrow layout: the list on its own, and an issue's detail slid in over it with a back button" src="docs/screenshots/compact-light.png" width="600">
</picture>

## Requirements

- macOS 27 or later
- Xcode 27 or later (for the Swift 6.4 toolchain and `actool`, which compiles the app icon)
- The GitHub CLI, signed in:

  ```bash
  brew install gh
  gh auth login
  ```

## Build and run

```bash
./bundle.sh
open build/Punchlist.app
```

`bundle.sh` builds a release binary with Swift Package Manager, compiles the Icon Composer icon in `Resources/AppIcon.icon`, and wraps both into an ad-hoc signed app bundle in `build/`.

### Demo mode

Launch with `--demo` to show made-up repositories, issues and comments instead of your own; it never calls `gh`. The screenshots above were taken this way. Add `--demo-window-size 440x820` to open at a given size, e.g. for the narrow layout:

```bash
open -n build/Punchlist.app --args --demo --demo-window-size 440x820
```

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘N | New issue |
| ⌘F | Search |
| ⌘1 / ⌘2 | Show issues / pull requests |
| ⌘R | Refresh |
| ⌘[ | Back to the list (narrow windows) |
| ⌃⌘S | Show or hide the sidebar |

Double-click an item to open it in your browser; right-click for more actions.

## How it works

The app runs `gh search issues` / `gh search prs` with `--owner` for your account (and your organizations, if included), so results are capped at GitHub search's 1,000 items per query and archived repositories are left out. Comments come from `gh api`, and new issues are created with `gh issue create`.

Markdown is rendered with [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui).

## License

Copyright © 2026 Francesco Papagno

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. It is distributed in the hope that it will be useful, but without any warranty; see the [GNU General Public License](LICENSE) for details.
