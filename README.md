# AI Shelf

> Browse, resume, search and clean up the session history of your AI coding agents on macOS, and see what the tokens cost.

AI Shelf is a native SwiftUI app for macOS 26. It reads the session files your agents already write, lists them by project, and opens any of them in your terminal with one click.

Designed and developed by cmxau.

## Why this exists

Coding agents leave a trail of sessions in hidden folders. Finding last week's session, resuming it in the right directory, working out what you spent, or clearing out old history means digging through dot-folders by hand. AI Shelf puts all of that in one window.

## Features

- **One list for several agents.** Sessions are grouped by project folder, with one row per session.
- **Resume.** Open a project, or resume one session, in Terminal, iTerm, Ghostty, WezTerm or Alacritty.
- **Preview.** See a session's first and last message without opening it.
- **Search.** Filter by project name, path or session title. A query of three or more characters also searches conversation text.
- **Clean up.** Delete sessions or projects (to the Trash by default) and undo. Delete empty sessions, or sessions older than 30, 90 or 180 days. Delete projects whose folder no longer exists.
- **Fix Path (Claude only).** Point a Claude project at its new folder after you moved it.
- **Pins and notes.** Keep projects on top and attach a short note to a project or session.
- **Export.** Save a session as Markdown.
- **Usage stats.** Tokens and estimated cost per session, project, day, week, agent and model. A lifetime ledger keeps totals after the agent expires old sessions.
- **Budget alerts.** A notification at 80% and 100% of a monthly budget you set.
- **Sync stats between Macs** through a shared folder, or export and import the ledger by hand.
- **Menu-bar item**, a global shortcut (Control-Option-S) that opens search, and a "running" indicator for projects with a live agent process.
- **Self-updater** that uses GitHub releases.

## Quick install

1. Download `AI-Shelf-X.Y.Z.zip` from the [latest release](https://github.com/cmxau/ai-shelf/releases/latest).
2. Unzip it and move `AI Shelf.app` to `/Applications`.
3. Right-click the app and choose **Open**. The app is unsigned, so macOS asks once.

Details, permissions and uninstall steps are in [docs/installation.md](docs/installation.md).

## Build from source

You need macOS 26 and the Xcode Command Line Tools. Full Xcode is not required.

```sh
./build.sh              # builds "AI Shelf.app" in the repo root
./build.sh --install    # also copies it to /Applications
```

The version comes from the `VERSION` file. See [docs/setup.md](docs/setup.md).

## Supported agents

| Agent | Command | Sessions, resume, preview, delete | Tokens and cost | Markdown export | Fix Path |
| --- | --- | --- | --- | --- | --- |
| Claude Code | `claude` | Yes | Yes | Yes | Yes |
| Antigravity | `agy` | Yes | No (no token counts recorded) | No | No |
| Codex | `codex` | Yes | Yes | Yes | No |
| Gemini CLI | `gemini` | Yes | Yes | Yes | No |
| OpenCode, Aider, Goose, Amp, Cursor Agent, Copilot | `opencode`, `aider`, `goose`, `amp`, `cursor-agent`, `copilot` | Launch and folder list only | No | No | No |

Notes:

- Only agents that your login shell can find (`command -v`) are shown. You can hide agents and add your own command names in Settings.
- The Claude and Antigravity readers were written against real data. The Codex and Gemini readers were written from the vendors' published source and have not yet been tried on real sessions. Report anything that looks wrong.
- Folder rows for launch-only agents come from the folders the four readable agents know about.

## Privacy

Everything stays on your Mac. AI Shelf has no account, analytics or telemetry. It reads your agents' session files in place and writes only to its own cache, its preferences, and files you choose to export.

The only network requests are:

| When | Host | Why |
| --- | --- | --- |
| Weekly, or when you click Fetch | `platform.claude.com`, `developers.openai.com`, `ai.google.dev` | Download each vendor's public pricing page to estimate cost. |
| At launch (at most once a day) or when you click Check for Updates | `api.github.com` | Ask for the latest release of `cmxau/ai-shelf`. |
| When you install an update | `github.com` and GitHub's release CDN | Download the release zip. |

Both checks can be turned off in Settings. Details: [docs/security.md](docs/security.md) and [docs/api.md](docs/api.md).

Token costs are estimates from public list prices. AI Shelf is not affiliated with Anthropic, OpenAI or Google.

## Documentation

| Document | For |
| --- | --- |
| [docs/installation.md](docs/installation.md) | Installing, first launch, permissions, uninstalling |
| [docs/setup.md](docs/setup.md) | Developer environment, build, lint, repo layout |
| [docs/architecture.md](docs/architecture.md) | Modules, data flow, caches, threading |
| [docs/api.md](docs/api.md) | Internal interfaces and on-disk formats |
| [docs/security.md](docs/security.md) | Threat model and hardening |
| [docs/contributing.md](docs/contributing.md) | Branches, pull requests, manual testing |
| [docs/releasing.md](docs/releasing.md) | Cutting a release |

## Contributing

Read [docs/contributing.md](docs/contributing.md). Report bugs and request features with the [issue forms](https://github.com/cmxau/ai-shelf/issues/new/choose).

## License

[MIT](LICENSE) (c) 2026 cmxau
