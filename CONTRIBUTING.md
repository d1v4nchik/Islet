# Contributing to Islet

Thanks for taking the time to contribute! Islet is a small macOS app that puts your Google Calendar and Notion tasks
in the Mac's notch, and contributions of all sizes are welcome: bug reports, fixes, docs, and new features.

## Before you start

- Check [open issues](../../issues) and [pull requests](../../pulls) to avoid duplicating work.
- For anything beyond a small fix, open an issue first to discuss the change. It saves everyone time if the approach
  needs adjusting.
- By contributing, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Development setup

Islet builds with just the Xcode Command Line Tools (`xcode-select --install`), macOS 14 or newer.

```bash
git clone https://github.com/d1v4nchik/Islet.git
cd Islet
./build.sh              # build/Islet.app for this Mac
open build/Islet.app
```

To connect your own calendar while developing, follow the **Setup** section of the [README](README.md): Islet needs
your own Google Cloud OAuth client (Desktop app) and, optionally, a Notion integration.

You can work on the design without signing in to anything:

```bash
./build/Islet.app/Contents/MacOS/Islet --snapshot /tmp/islet-shots   # renders every panel with sample data
```

## Project layout

| File | Purpose |
|---|---|
| `Sources/main.swift` | Entry point and command-line modes (`--snapshot`, `--icon`, `--debug-colors`) |
| `Sources/IslandController.swift` | The notch panel window, the menu bar item, hover and click handling, the right-click menu |
| `Sources/Views.swift` | All SwiftUI views: the island shape, Today / Calendar / Tasks tabs, heads-up, menu bar label |
| `Sources/CalendarModel.swift` | App state: events, what's on now or next, heads-ups, tasks, formatting helpers |
| `Sources/GoogleAuth.swift` | Google sign-in (OAuth with PKCE and a loopback redirect) and token storage |
| `Sources/GoogleCalendarAPI.swift` | Google Calendar requests and turning them into events (including colors) |
| `Sources/NotionTasks.swift` | Notion tasks: finding the database, reading tasks, ticking them off |
| `Sources/Snapshot.swift` | Sample data, screenshots and the app icon |
| `build.sh` / `release.sh` | Build the app / build a universal `Islet.dmg` |
| `install.sh` | The one-line installer from the README |

Credentials and settings live in `~/Library/Application Support/Islet`, never in the repo.

## Making changes

1. Fork the repo and create a branch off `main`.
2. Keep changes focused: one logical change per pull request.
3. Verify your change:
   ```bash
   ./build.sh            # must build without errors
   ./release.sh          # if you touched packaging: builds the universal DMG
   ```
   There's no automated test suite yet. A PR that adds tests for the date and countdown logic in `CalendarModel` is very
   welcome.
4. If you touch the notch panel or the menu bar item, run the app and try it for real: hover the notch, click the menu
   bar item, switch tabs, and use **Preview Heads-up** from the right-click menu. Most bugs here only show up with real
   mouse movement.
5. If your change affects how things look, re-render the screenshots with `--snapshot docs` and include them.

## Submitting a pull request

- Describe *why* the change is needed, not just what it does.
- Reference the issue it closes, if any (`Closes #123`).
- Keep commit messages descriptive; squash noisy WIP commits before opening the PR.

## Reporting bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). Include steps to reproduce, what you expected,
what actually happened, and your Mac model (with or without a notch).

## Reporting security issues

Please do **not** open a public issue for security vulnerabilities. See [SECURITY.md](SECURITY.md) instead.
