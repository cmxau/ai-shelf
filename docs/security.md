# Security

This page summarises what AI Shelf trusts, what it does not, and the protections in the code. It describes the code in `Sources/`, not a guarantee.

## What the app can do

AI Shelf runs as you, with your permissions. The build does not enable the App Sandbox and does not sign the app. It can read your agents' history folders, move or delete files inside them, start your terminal, and make the network requests listed in the [README](../README.md#privacy).

## Threat model

Input that AI Shelf must treat as hostile, because someone other than you may control it:

| Input | How it could be hostile |
| --- | --- |
| Session files (Claude, Codex, Gemini, Antigravity database) | A project folder name, session id or message crafted to inject commands, SQL or AppleScript when AI Shelf opens, deletes or exports. The files may come from a cloned repo, a shared machine or a malicious agent run. |
| Imported stats files and the sync file | A doctored file with huge numbers, huge sizes or odd keys, to crash the app or fill memory. The sync folder may be shared. |
| Vendor price pages | A changed or compromised page feeding absurd prices or a huge response. |
| The release feed and zip | A tampered download, a redirect to another host, or a zip that is not AI Shelf. |
| Settings text (custom agents, extra flags, prices) | Entered by you, so trusted, but still validated where it becomes a command name. |

Out of scope: an attacker who already controls your account or your Mac, a compromised GitHub account or repository for `cmxau/ai-shelf`, and a malicious agent CLI that you chose to install.

## Hardening in place

### Launching (`Launching.swift`)

- The folder path and session id come from files on disk. `openProject` refuses a path that is not absolute or contains control characters.
- The path and session id are single-quoted for the shell (`sh`). Control characters are replaced by spaces in AppleScript text (`osa`), so a newline cannot start a second command in the terminal.
- Agent command names must be ASCII letters, digits, `-`, `_` or `.`, at most 64 characters, and must not start with `-` or `.` (`isAgentName`). Custom agents that fail this are ignored. This also keeps names from being read as options.
- Agent detection passes only validated names into the login-shell script.
- Ghostty, WezTerm and Alacritty receive the path and command as separate arguments through `open --args`, not through a shell string.

Extra flags in Settings are inserted into the command as you typed them. They are your own configuration and are not sanitised; do not paste text you do not trust.

### Reading session data (`Core.swift`, `Loaders.swift`)

- File reads are capped (`read` returns at most 512 KiB from the start or end; `readCapped` refuses files larger than its limit, for example 256 MiB for export and 64 MiB for legacy Gemini files).
- Antigravity ids must be plain tokens (`isSafeID`) before they name a file or enter SQL.
- SQL strings are quoted with `sqlQuote` (quotes doubled, NUL removed) and the `sqlite3` tool runs with `-safe`.
- The conversation search runs `grep -ilF -- <query>` with the query as a separate argument and treats it as a literal string.

### Deleting and Fix Path (`Model.swift`, `Loaders.swift`)

- Delete works only on paths inside a configured history folder (`insideHistoryRoots`). The parent is resolved through symlinks, and a root of `/` or your home folder is rejected. The item itself is trashed or removed as a link, never followed. Anything refused is reported.
- Deleting asks for confirmation by default and moves to the Trash by default. Undo restores the files and the Antigravity rows.
- Fix Path works only on a Claude directory directly inside the Claude root, requires an absolute new folder without control characters, skips symlinked session files, escapes the new path for JSON, and refuses to overwrite another project's history directory.

### Stats and prices (`Stats.swift`, `Prices.swift`)

- Imports and the sync file are size-limited (128 MiB, 500,000 entries) and each entry is validated (`FileStats.checked`): bounded sizes, counters between 0 and 2^36, short strings, finite times. Invalid entries are dropped. Keys with a `/` or control characters are skipped.
- Cache files are written atomically. The cache folder is mode 0700 and the files 0600, since they contain project paths. The sync file is written with 0600.
- Price pages are limited to 8 MiB. Only finite prices from 0 to 10,000 USD per million tokens with short model names are kept. A vendor that fails keeps its previous prices.

### Updater (`Updater.swift`)

- The download URL must be `https`, with no custom port or user info, on `github.com`, `objects.githubusercontent.com` or `release-assets.githubusercontent.com`, and under `/cmxau/ai-shelf/releases/download/`. Every redirect hop is re-checked against the allowed hosts.
- The download must be HTTP 200 and between 1 KiB and 200 MiB.
- If the release asset has a SHA-256 digest, the file must match it.
- The archive is unpacked into a fresh directory (mode 0700) with `ditto`. The result must contain an app with `Contents/MacOS` and bundle id `com.cmxau.ai-shelf`.
- AI Shelf only replaces its own installed `.app` with that bundle id, and only if the folder is writable.
- The swap script gets all paths as arguments, never through string interpolation. It renames the old app aside, moves the new one in, and puts the old one back if that fails.
- Installing happens only when you click Install Update, or when you turned on automatic install.

### Notifications

Notification text is escaped before it is used in AppleScript, in the fallback path.

## Known limits

- **No code-signature check on updates.** The updater trusts GitHub's TLS, the host allowlist, the bundle id and, when GitHub provides one, the SHA-256 digest. The digest comes from the same API response as the asset, so it detects a corrupted or swapped download but does not protect against someone who controls the release itself.
- **The app is unsigned and not notarized.** Gatekeeper cannot vouch for it. Build from source if you want to audit what you run.
- **Settings text is trusted.** Extra flags and custom agent names are yours.
- **Agents run with your full permissions.** AI Shelf resumes them the same way you would from a terminal.
- **Login shell.** Agent detection and some launches run `zsh -lic`, which reads your shell startup files.
- **Deleting is real.** With "Move to Trash" off, deletion is permanent.
- **Codex and Gemini readers are not yet verified on real sessions.** Treat their parsing as best effort.

## Privacy

There is no telemetry. Session content is read locally and is not sent anywhere. Opening a bug report sends nothing until you submit the form on GitHub, and the prefilled values are only the app and macOS versions.

## Reporting a vulnerability

Do not open a public issue.

1. Go to the repository's **Security** tab: [github.com/cmxau/ai-shelf/security](https://github.com/cmxau/ai-shelf/security).
2. Choose **Report a vulnerability** to open a private security advisory.
3. Include the AI Shelf version, your macOS version, the steps to reproduce, and the impact. Remove private paths and prompts.

The advisory stays private between you and the maintainer until a fix is released.
