# GitHub Issues

A lightweight macOS client for the issues and pull requests across your GitHub repositories. It has no GitHub code of its own: everything goes through the [`gh` CLI](https://cli.github.com) you already have installed and signed in, so it never sees or stores a token.

## Features

- One list of the open issues or pull requests across every repository you own, optionally including your organizations.
- Filters for repository, status (open, closed, merged, all) and labels, plus search by title, repository, number or author.
- Issue and pull request detail with GitHub-style Markdown and the conversation's comments.
- Create an issue from the first row of the list: type a title, pick the repository, press Return.
- A native macOS 26+ layout: a resizable glass sidebar beside the detail. Below 640 points wide, the window switches to a single list, and the detail slides in over it.

## Requirements

- macOS 26 or later
- Xcode 26 or later (for the Swift 6.2 toolchain and `actool`, which compiles the app icon)
- The GitHub CLI, signed in:

  ```bash
  brew install gh
  gh auth login
  ```

## Build and run

```bash
./bundle.sh
open "build/GitHub Issues.app"
```

`bundle.sh` builds a release binary with Swift Package Manager, compiles the Icon Composer icon in `Resources/AppIcon.icon`, and wraps both into an ad-hoc signed app bundle in `build/`.

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

## Notes

The app icon uses the GitHub mark, which is a GitHub trademark. That's fine for building the app for yourself, but replace the icon if you distribute builds; see GitHub's [logo usage guidelines](https://github.com/logos).

## License

Copyright © 2026 Francesco Papagno

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. It is distributed in the hope that it will be useful, but without any warranty; see the [GNU General Public License](LICENSE) for details.
