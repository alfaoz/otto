# otto

A password vault your coding agents can use. Through otto they log into websites and Mac apps, enter
2FA codes, fill cards at checkout and run sudo. The passwords stay on your Mac.

Download it at [otto.alfaoz.dev](https://otto.alfaoz.dev). It needs macOS 26 or later.

## Setup

1. Drag otto into Applications and open it.
2. Add [the extension](https://otto.alfaoz.dev/extension) to Chrome, Brave, Edge, Arc, Dia, Helium,
   Vivaldi, Opera, Comet or ChatGPT Atlas.
3. Connect your agents in Settings → Agents. Codex, Cursor, Gemini CLI, Windsurf, opencode, T3 Code and
   the Claude app each have a Connect button. In Claude Code, run:
   ```
   /plugin marketplace add alfaoz/otto
   /plugin install otto@otto
   ```
   Any other agent can run `otto mcp` as an MCP server, or use the `otto` command (`otto help`).
4. Import your logins with ⌘I. otto reads exports from Apple Passwords, Chrome, Firefox, 1Password,
   Bitwarden and KeePassXC, and from authenticator apps like Google Authenticator, Aegis and 2FAS.

## How it works

```
agent ── MCP or the otto CLI ──▶ otto service ──▶ Chrome extension: fills the tab
                                     │
                                     ├── vault.kdbx: a KeePass file, its key in your keychain
                                     └── Otto.app: Touch ID, windows, typing into Mac apps
```

The otto service runs on your Mac and holds the unlocked vault. When an agent asks for a login, otto
fills it into the tab on that login's site, and the agent only hears whether it worked. The only secret
an agent ever reads is a 2FA code, and it expires in 30 seconds.

Each entry has a rule. Auto lets agents use it without asking, ask needs your Touch ID each time, and
never hides it from agents. Bypass is for when you're away: agents use the entry without asking, on any
site, until you turn it off or it runs out. Turning bypass on takes Touch ID at the Mac.

- Logins fill only on their own sites. To use one on a new domain, you type the domain once to allow it.
- Cards can't be set to auto, and otto never presses pay.
- `otto sudo -- <command>` gives sudo your Mac password, for a command you've seen and allowed.
- `otto run --env VAR=entry -- <command>` hands an API key to a program as an environment variable. If
  the program prints it, the agent sees ••••. That catches accidents, not a program written to leak it.
- `otto approve --why <reason> -- <command>` is for a command only you should decide on. You see the
  command and the reason, and allow that one run with Touch ID.
- `otto approve --secret-blank password -- <command> {{password}}` leaves something for you to fill in,
  at the Mac or on your phone. otto runs the command itself, and the agent sees its output with what
  you typed as ••••. Tick remember to keep a value in your vault: a secret comes back only for that
  exact command, anything else by name. You can edit them under Remembered, or add your own.

With remote on (Settings → Remote), an agent can send you a link to answer from your phone instead of
waiting at the Mac. The page runs on your Mac and only answers your own devices on your Tailscale
network. You approve with a PIN.

The vault is at `~/Library/Application Support/otto/vault.kdbx`. KeePassXC, Strongbox and KeePassium
open it with your recovery key. otto keeps hourly and daily backups of it, and deleted entries stay in
the trash for 30 days.

otto can't protect you from a malicious program already running as you. It can read anything you can.

## Building

You need macOS 26, Xcode 26 and Rust.

```
./build.sh --open
```

This builds the app and the `otto` binary, installs `~/Applications/Otto.app`, links
`~/.local/bin/otto` and opens otto. It signs with an Apple Development certificate, so put your own
team ID in `tools/certs.sh`. For the extension, load `~/Library/Application Support/otto/extension`
unpacked; otto keeps that copy up to date.

`./release.sh <version> [notes file]` makes the notarized DMG and the signed update feed.

```
core/       Rust: the vault, service, CLI, MCP server, browser helper and importers
mac/        the SwiftUI app
extension/  the Chrome extension
plugin/     the Claude Code plugin
site/       otto.alfaoz.dev
store/      the Chrome Web Store listing and images
tests/      service and browser tests
testsite/   a fake login site with a password, 2FA and a setup QR code
tools/      signing, icons, the DMG, the update feed, UI previews
```

## Tests

- `cd core && cargo test`
- `python3 tests/<name>_flow.py <otto binary>` runs the service on a throwaway vault, with the script
  standing in for the app. Each one says at the top what it covers.
- `tests/e2e.sh` logs into the fake site in a throwaway Chrome for Testing. Its setup is at the top of
  the file.
- `tools/preview.sh <dir> main,settings,request` renders the app's windows against a demo vault.

## License

GPL-3.0-or-later (`LICENSE`). Copyright © 2026 alfaoz.

Report security problems privately with "Report a vulnerability" on this repository's Security tab.
