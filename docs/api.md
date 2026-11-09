# Interfaces and formats

AI Shelf has no public network API and no plugin interface. This page documents what it reads and writes: session files per agent, the stats ledger and export format, the sync file, preferences, the links it opens, and what the updater expects from a release.

All paths use the default locations. Each history folder can be changed in Settings, Paths.

## Session files it reads

| Agent | Default root (Settings key) | Layout |
| --- | --- | --- |
| Claude | `~/.claude/projects` (`claudeRoot`) | `<dir>/<session id>.jsonl`, optional `<dir>/<session id>/` folder, and `<dir>/<session id>/subagents/*.jsonl` |
| Antigravity | `~/.gemini/antigravity-cli` (`agyRoot`) | `conversation_summaries.db`, `conversations/<id>.db`, `brain/<id>/` |
| Codex | `~/.codex/sessions` (`codexRoot`) | `**/rollout-*.jsonl` (normally `YYYY/MM/DD/`) |
| Gemini | `~/.gemini` (`geminiRoot`) | `tmp/<project>/chats/session-*.jsonl` or `.json`, and `tmp/<project>/.project_root` |

Files are read in place. The only history files AI Shelf modifies are Claude `*.jsonl` files (Fix Path rewrites `cwd`) and Antigravity's `conversation_summaries` table (delete removes rows, undo restores them). Delete also moves or removes the session files themselves.

### Claude

- `<dir>` is derived from the project path by Claude Code, and the mapping is lossy (`/` and `_` both become `-`). AI Shelf reads the real folder from the first `"cwd":"..."` in the session files, and only if none is found decodes the directory name by turning `-` back into `/`. Fix Path names the new directory by replacing every character that is not an ASCII letter or digit with `-`.
- Each line is one JSON object. Chat lines have `type` of `user` or `assistant`, `isMeta` not true, and `message.content` as a string or a list of blocks. Text blocks (`type: "text"`) are used.
- The title is the first user message whose text does not start with `<`, cut to its first line and 120 characters. If there is none, the title is `(no prompt)`.
- Token usage comes from assistant lines: `message.model`, `message.id`, and `message.usage` with `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`. The model `<synthetic>` is skipped. Time comes from `timestamp` (ISO 8601).
- Resume command: `claude --resume <session id>`.

### Antigravity

- `conversation_summaries.db` is SQLite, read through `/usr/bin/sqlite3 -safe`. The table `conversation_summaries` is used with the columns `conversation_id`, `title`, `preview`, `workspace_uris` and `last_modified_time`.
- `workspace_uris` is a JSON array of file URLs. The first one is the project folder.
- Conversation ids must pass `isSafeID` (letters, digits, `-`, `_`, `.`, at most 128 bytes, no leading dot). Rows with other ids are skipped.
- A session's files are `conversations/<id>.db` and `brain/<id>` when they exist. They are binary and not parsed. There is no transcript, token or Markdown export for Antigravity.
- Resume command: `agy --conversation <id>`.

### Codex

- Line 1 is `session_meta` with `payload.id` and `payload.cwd`. Rows without a `cwd` are skipped.
- The title is the first `event_msg` whose `payload.type` is `user_message` and whose `payload.message` does not start with `<`.
- Preview and export use `user_message` and `agent_message` payloads.
- Tokens: `event_msg` with `payload.type` `token_count` and `payload.info.total_token_usage` (`input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`). The model is `payload.model` of the latest `turn_context`.
- Resume command: `codex resume <session id>`.

### Gemini

- `<project>/.project_root` holds the project folder. Projects without it are skipped.
- A `.jsonl` file is a header record followed by message records. A legacy `.json` file is one object with a `messages` array (read up to 64 MiB).
- Messages have `type` of `user` or `gemini`, and `content` as a string, one `{text}` part, or a list of parts. The session id is the first `sessionId` found.
- Tokens: `gemini` records with `tokens` (`input` including cached, `output`, `cached`, `thoughts`, `tool`) and an `id`, `model`, `timestamp`.
- Resume command: `gemini --resume <session id>`.

### Launch-only agents

OpenCode, Aider, Goose, Amp, Cursor Agent and Copilot, plus any custom name, are started as `<command> <extra flags>` in the project folder. No history is read.

## Commands it runs

`openProject` builds `cd '<path>' && <agent> <flags> [resume args]`.

| Terminal | Mechanism |
| --- | --- |
| Terminal | AppleScript `do script` through `osascript` |
| iTerm | AppleScript: new window, or new tab if "Open in a new tab" is on and a window exists |
| Ghostty | `open -na Ghostty --args --working-directory=<path> -e zsh -lic "<command>"` |
| WezTerm | `open -na WezTerm --args start --cwd <path> -- zsh -lic "<command>"` |
| Alacritty | `open -na Alacritty --args --working-directory <path> -e zsh -lic "<command>"` |

## Stats ledger

The ledger is a JSON object that maps a session-file key to a `FileStats` record. It is saved as `~/Library/Caches/ai-shelf/stats-v2.json`.

Keys: a Claude file name such as `0f3c...e1.jsonl`, or `<agent>:<file name>` for other agents, for example `codex:rollout-2026-01-02T10-00-00-<id>.jsonl`.

### `FileStats`

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `size` | integer | yes | Size of the scanned file in bytes. |
| `mtime` | number | yes | Modification time of the scanned file, Unix seconds. Used to pick the newer record on merge. |
| `first`, `last` | number | no | First and last timestamp in the session, Unix seconds. |
| `days` | object | yes | Local day (`yyyy-MM-dd`) → model name → `Usage`. |
| `models` | object | yes | Model name → `Usage`, over the whole file. |
| `total` | `Usage` | yes | Sum over all models. |
| `project` | string | no | Working folder of the session. |
| `agent` | string | no | `claude`, `codex` or `gemini`. Missing means `claude`. |

### `Usage`

| Field | Type | Meaning |
| --- | --- | --- |
| `input` | integer | Fresh input tokens (cache reads and cache writes excluded). |
| `output` | integer | Output tokens. For Codex, reasoning tokens are already included. For Gemini, thought tokens are added. |
| `cacheWrite` | integer | Tokens written to the prompt cache. |
| `cacheRead` | integer | Tokens read from the prompt cache. |

All four are required when decoding.

## Export format (`StatsExport`)

Settings, Usage, Export (and File, Export Statistics) writes this file. Import reads it.

```json
{
  "app": "ai-shelf",
  "version": 1,
  "exported": 1767225600.0,
  "ledger": {
    "0f3c0000-0000-0000-0000-000000000000.jsonl": {
      "size": 48213,
      "mtime": 1767225000.0,
      "first": 1767221000.0,
      "last": 1767224900.0,
      "days": {
        "2026-01-01": {
          "claude-sonnet-4-5": { "input": 1200, "output": 3400, "cacheWrite": 15000, "cacheRead": 90000 }
        }
      },
      "models": {
        "claude-sonnet-4-5": { "input": 1200, "output": 3400, "cacheWrite": 15000, "cacheRead": 90000 }
      },
      "total": { "input": 1200, "output": 3400, "cacheWrite": 15000, "cacheRead": 90000 },
      "project": "/Users/me/code/demo",
      "agent": "claude"
    }
  }
}
```

The default file name is `ai-shelf-stats-<yyyy-MM-dd>.json`. `exported` is Unix seconds. The model name above is an example.

### Import rules

Import accepts a file only if all of these hold, and otherwise reports "That file isn't an AI Shelf statistics export":

- The file is at most 128 MiB and decodes as `StatsExport`.
- `app` is `ai-shelf`, `AI Shelf` or `Session Shelf` (the older names).
- `version` is `1`.
- The ledger has at most 500,000 entries.

Each entry is then checked individually and silently dropped if it fails:

- The key is at most 256 characters, has no control characters, and contains no `/`.
- `days` has at most 20,000 entries, `models` at most 1,000, each day at most 1,000 models. Day keys are at most 10 characters, model names at most 200.
- Every counter is between 0 and 2^36.
- `project` is at most 4,096 characters, `agent` at most 32, `size` is not negative, `mtime` is finite.

Entries that pass are merged: new keys are added; for existing keys, the entry with the larger `mtime` replaces the old one.

## Sync file

If **Sync between Macs** has a folder (`syncFolder`), then after every scan AI Shelf:

1. Reads `<folder>/ai-shelf-stats.json` if it exists (same size, version and entry limits and per-entry checks as import; the `app` field is not checked).
2. Merges it into the local ledger.
3. Writes the merged ledger back to the same file in the `StatsExport` format, atomically, with mode 0600.

The file is meant to sit in iCloud Drive, Dropbox or similar. There is no locking: two Macs that scan at the same moment can overwrite each other's write, and the next scan on either Mac merges again.

## Preferences (`UserDefaults`)

The defaults domain is the bundle id, `com.cmxau.ai-shelf`. Every key is declared once in `enum Pref` in `Sources/Core.swift`.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `cli` | string | `claude` | Agent chosen in the toolbar. Reset from `defaultAgent` at every launch. |
| `terminal` | string | `Terminal` | Terminal chosen in the toolbar. Reset from `defaultTerminal` at every launch. |
| `defaultAgent` | string | `claude` | Agent selected at launch. `all` is allowed. |
| `defaultTerminal` | string | `Terminal` | Terminal selected at launch. |
| `openInTab` | bool | false | iTerm only: open a tab instead of a window. |
| `confirmDelete` | bool | true | Ask before deleting. |
| `trashDelete` | bool | true | Move to the Trash. When off, delete permanently and offer no undo. |
| `autoReload` | bool | false | Reload when the app becomes active. |
| `columns` | data | none | Table column order and visibility. |
| `columnsVersion` | integer | 0 | Resets `columns` when it is below the current layout version (3). |
| `menuCount` | integer | 10 | Recent projects in the menu-bar list (3 to 25). |
| `showDock` | bool | true | Keep the Dock icon when no window is open. |
| `disabledAgents` | string | empty | Comma-separated agent names to hide. |
| `customAgents` | string | empty | One command name per line. |
| `agentFlags` | string | empty | One line per agent: `<agent> <flags>`. |
| `claudeRoot`, `agyRoot`, `codexRoot`, `geminiRoot` | string | empty | Override of the history folder. `~` is expanded. Empty means the default. |
| `calcStats` | bool | true | Scan sessions for token usage. |
| `showCards` | bool | true | Show the statistics cards above the table. |
| `prices` | string | empty | Your own prices, one line per model: `name input output cacheWrite cacheRead`, USD per million tokens. |
| `autoPrices` | bool | true | Refresh official prices weekly. |
| `hotkey` | bool | true | Register Control-Option-S. |
| `notify` | bool | true | Allow notifications from the app. |
| `monthlyBudget` | string | empty | Monthly budget in USD. Empty or 0 turns alerts off. |
| `syncFolder` | string | empty | Folder for the sync file. |
| `statsGroup` | string | `day` | Grouping in the Usage Stats window: `day`, `week`, `project`, `agent` or `model`. |
| `autoCheckUpdates` | bool | true | Check for updates at launch, at most once a day. |
| `autoInstallUpdates` | bool | false | Install a found update without asking. |
| `lastUpdateCheck` | number | 0 | Unix time of the last check. |
| `pins` | string array | empty | Pinned keys (see `Model.markKey` in [architecture.md](architecture.md)). |
| `notes` | dictionary | empty | Note text by the same keys. |
| `budgetAlert-<yyyy-MM>` | integer | 0 | Highest alert level already sent for that month (80 or 100). |

To read them: `defaults read com.cmxau.ai-shelf`.

## Links it opens

**Issue forms.** Help, Report a Bug and Request a Feature (plus the buttons in Settings, About and the menu-bar item's Report a Bug) open `https://github.com/cmxau/ai-shelf/issues/new` in your browser with these query parameters:

| Parameter | Value |
| --- | --- |
| `template` | `bug_report.yml` or `feature_request.yml` |
| `version` | The app version (`CFBundleShortVersionString`) |
| `macos` | `ProcessInfo.operatingSystemVersionString` |

`version` and `macos` fill the form fields with those ids (see `.github/ISSUE_TEMPLATE/bug_report.yml`). The feature form has no such fields, so the values are ignored there. Nothing is sent until you submit the form on GitHub.

**Repository.** "AI Shelf on GitHub" opens `https://github.com/cmxau/ai-shelf`.

## Price pages it fetches

| Vendor | URL | Parsed |
| --- | --- | --- |
| Anthropic | `https://platform.claude.com/docs/en/about-claude/pricing.md` | The "Model pricing" table. Uses the 5-minute cache-write price. |
| OpenAI | `https://developers.openai.com/api/docs/pricing.md` | The "Standard pricing data" tables (short context) and the Codex rows. |
| Google | `https://ai.google.dev/gemini-api/docs/pricing.md.txt` | One section per model, the Standard tab, paid tier. Prices with an effective date use the one in effect today. |

The parsers depend on the pages' Markdown layout. If a vendor changes it, that vendor shows "failed" or "page format not recognised" in Settings and keeps its previous prices. Responses over 8 MiB are rejected. Prices are USD per million tokens as `[input, output, cacheWrite, cacheRead]`. The result is cached in `prices.json` as `{ "fetched": <unix seconds>, "items": { "<model id>": { "p": [4 numbers], "src": "Anthropic" } } }`.

## What the updater expects from a release

AI Shelf calls `GET https://api.github.com/repos/cmxau/ai-shelf/releases/latest` with `Accept: application/vnd.github+json` and reads:

| Field | Use |
| --- | --- |
| `tag_name` | The version. A leading `v` is removed. It is compared with the running version component by component as integers (`1.2.10` is newer than `1.2.9`; a non-numeric component counts as 0). |
| `assets[]` | The first asset whose `name` ends in `.zip` and whose `browser_download_url` is `https` on `github.com`, `objects.githubusercontent.com` or `release-assets.githubusercontent.com`, with a path starting `/cmxau/ai-shelf/releases/download/`. |
| `assets[].digest` | Optional. If it is `sha256:` followed by 64 hex digits, the download must match it. |
| `html_url` | The release page, used only if it is an `https://github.com/...` URL. |

The zip must:

- Be between 1 KiB and 200 MiB, and download with HTTP 200. Every redirect must stay on the hosts above over `https`.
- Contain, at its top level, a `.app` bundle with `Contents/MacOS` and an `Info.plist` whose `CFBundleIdentifier` is `com.cmxau.ai-shelf`.
- Be unpackable by `ditto -x -k`.

How the release workflow produces that is in [releasing.md](releasing.md).

## Other files it writes

| File | When |
| --- | --- |
| Markdown export | You choose the location in the save panel. Format: `# <title>`, a line with the folder, agent and time, then `## You` / `## Assistant` sections. |
| Stats export | You choose the location. See above. |
| Trash | Deleted sessions are moved there unless "Move to Trash" is off. |
| `$TMPDIR/ai-shelf-update-<uuid>/` | During an update. Removed after the swap. |
