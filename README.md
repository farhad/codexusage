# CodexUsage

A tiny native macOS menu bar app that shows your current Codex quota:

```
codex 7dW 24%  ⏳ 3d5h
```

- **Percentage color**: green < 50%, orange < 80%, red ≥ 80%.
- **Dropdown menu**: plan name, HTTP status, progress bars for both quota windows,
  reset ETAs, plus *Refresh Now* (⌘R), *Launch at Login*, and *Quit*.
- **Refresh cadence**: every 10 minutes, on wake from sleep, and when the menu opens.

## Data source

Runs the same CLI your `usagecodex` alias resolves to, in `--json` mode
(`opencode-codex-usage --json --opencode 1 --no-notify`). The binary is located
in this order:

1. `~/.local/share/fnm/aliases/default/bin/opencode-codex-usage` (stable across node switches)
2. Newest match under `~/.local/share/fnm/node-versions/*/installation/bin/`
3. `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`
4. Fallback: `/bin/zsh -ic 'usagecodex --json ...'` (resolves the alias)

`--no-notify` is used so background polling doesn't write trigger signal files.

## Build & install

```bash
./build.sh
cp -R CodexUsage.app /Applications/
open /Applications/CodexUsage.app
```

Source: `main.swift` (AppKit, single file). Requires Xcode command line tools (`swiftc`).
