# Architecture

AI Shelf is one Swift module compiled from `Sources/*.swift` with `swiftc`. There is no Xcode project and no package manager. The app is a SwiftUI app with a single shared model object.

## Modules

| File | Responsibility |
| --- | --- |
| `Sources/App.swift` | `@main` app. Declares the main window, usage-stats window, Settings scene, menu-bar item, and all menu commands. |
| `Sources/Core.swift` | `Project` (the row type), `RowSort` (one comparator for every sortable column), `Pref` (every `UserDefaults` key), the history-folder roots, cache directory, and shared safety helpers (`readCapped`, `privateWrite`, `isSafeID`, `sqlQuote`, `insideHistoryRoots`, `msg`, `sqlite`). |
| `Sources/Loaders.swift` | One loader per agent (`loadClaude`, `loadAgy`, `loadCodex`, `loadGemini`), the cross-agent `loadAll` and `loadFolders`, `sessionPreview`, and `relocate` (Fix Path). |
| `Sources/Model.swift` | `Model`, the single `ObservableObject`: projects, selection, search, pins, notes, running-session detection, delete, undo and clean-up. |
| `Sources/Launching.swift` | Agent detection, building and running the terminal command, Markdown export, notifications, and the global shortcut. |
| `Sources/Stats.swift` | Per-agent token scanners, the ledger (`StatsStore`), the export format (`StatsExport`), budget alerts, and the optional sync file. |
| `Sources/Prices.swift` | Price lookup, cost calculation, and the three vendor price-page parsers (`PriceBook`). |
| `Sources/Updater.swift` | Release check, download, verification, install, and the GitHub issue-link helper. |
| `Sources/ContentView.swift` | Main window: project table, toolbar, context menu, search, delete confirmation, and the menu-bar list. |
| `Sources/StatsViews.swift` | Statistics cards and the Usage Stats window. |
| `Sources/Settings.swift` | Settings window (General, Agents, Usage, Paths, About) and the export/import panels. |

`build.sh` compiles every file in `Sources/` into one binary, writes `Info.plist` from `VERSION`, and copies `AppIcon.icns`. `make-icon.swift` generates the icon and is not part of the app.

## Data flow

```
history files on disk
   │  Loaders.swift: loadClaude / loadAgy / loadCodex / loadGemini
   ▼
[Project] folder rows, each with session rows in `children`
   │  Model.reload() → Model.projects
   ▼
Model (ObservableObject, @Published)
   │  ContentView sorts and filters; StatsStore.refresh(projects) starts a scan
   ▼
Views: table, preview, menu-bar list, stats cards
```

1. **Detect agents.** `activeAgents()` runs one login-shell call (`zsh -lic`, `command -v`) for every name in the catalog. The catalog is the built-in list plus the custom names from Settings. Results are cached in `checkedAgents` for the life of the process.
2. **Load.** `Model.reload()` calls `loadProjects(agent)` for the agent chosen in the toolbar. `all` merges every enabled, readable agent by folder. Any other agent name (a launch-only agent) lists the folders the readable agents know about.
3. **Model.** Each loader returns `Project` values. A folder row has `children` (the sessions). A session row has a `sessionID`. `Project.trash` holds the files that belong to the row, which is what delete moves and what stats and preview read.
4. **Views.** `ContentView` filters by the search text, sorts with `RowSort`, and puts pinned folders first.
5. **Stats.** After each reload, `StatsStore.refresh` scans the session files in the background and publishes totals per session (`bySession`) and for the whole ledger (`ledger`, `lifetime`).

### Row identity

Row ids are what pins and the selection use.

| Row | `Project.id` |
| --- | --- |
| Claude folder | the directory name under the Claude root |
| Claude session | `<directory name>/<session id>` |
| Antigravity folder / session | `agy:<path>` / `agy:<conversation id>` |
| Codex, Gemini folder | `codex:<path>` / `gemini:<path>` |
| Codex, Gemini session | `codex:<file name>` / `gemini:<file name>` |
| `all` view folder | `all:<path>` |
| Launch-only folder | `dir:<path>` |

Pins and notes are keyed by `Model.markKey`: the row id for a session, the folder path for a folder.

## Stats ledger and caches

All caches live in `~/Library/Caches/ai-shelf/`. The folder is mode 0700 and files are 0600. A folder left by the app's old name (`SessionShelf`) is moved over on first use.

| File | Content | Written by |
| --- | --- | --- |
| `stats-v2.json` | The stats ledger: one `FileStats` per session file ever scanned. | `StatsStore.save` |
| `prices.json` | Fetched prices and the fetch time. | `PriceBook.refresh` |

How the ledger works:

- **Key.** The session file's own name, not its path. Claude keys are bare (`<uuid>.jsonl`). Other agents are prefixed (`codex:rollout-....jsonl`). Moving a project (Fix Path) therefore never counts a session twice.
- **Cache validity.** An entry is reused while the file's size and modification time are unchanged. Otherwise the file is scanned again.
- **Lifetime.** The ledger is never pruned. If an agent expires a session file or you delete it, its totals stay. `Lifetime` aggregates the whole ledger for the cards and the Usage Stats window.
- **Subagents.** For Claude, the logs in `<session>/subagents/*.jsonl` are scanned and added to their parent session. Ledger keys that start with `agent-` are not counted as sessions.
- **Merge.** Import and sync add unknown keys; where both sides have a key, the entry with the larger `mtime` wins. Every imported entry is validated first (see [security.md](security.md)).
- **Cost.** Cost is computed on demand from token counts and the price table. It is never stored in the ledger. Your own price lines (Settings, Usage) win over fetched prices, and the longest matching model-name fragment wins.

Each scanner turns one agent's file into `FileStats`:

| Agent | How tokens are counted |
| --- | --- |
| Claude | Assistant lines with `message.usage`. Lines are de-duplicated by message id, keeping the largest output count. |
| Codex | `token_count` events carry a cumulative total. The difference from the previous event is attributed to that event's day and the model from the latest `turn_context`. A drop in the counter is treated as a restart. |
| Gemini | `gemini` messages with `tokens`. The last record per message id wins. |

The headline "tokens" number is `input + output + cacheWrite`. Cache reads are shown separately.

## Threading

| Work | Where it runs |
| --- | --- |
| Agent detection, `Model.reload()`, loading, preview, delete, undo, Fix Path | Main thread, synchronous. |
| Stats scanning, ledger save, sync file | A serial utility queue named `stats`. The `cache` dictionary is only touched there. Results are published to the main thread in batches of 12 sessions. |
| Conversation-text search | `grep -ilF` on a global queue, in batches of 300 files. A generation counter drops results from an older query. |
| Running-session detection | A global utility queue, every 20 seconds and after each reload: `ps` finds agent processes, `lsof` reads their working directories. |
| Price and update requests | `URLSession` callbacks. Results are applied on the main thread. |

`Model` and `StatsStore` are `ObservableObject` classes, not `@Observable`, because the build must work with only the Command Line Tools, which lack the SwiftUI macro plugin.

## Process boundaries

AI Shelf starts these system tools: `/bin/zsh` (agent detection, terminal commands), `/usr/bin/osascript` (Terminal and iTerm), `/usr/bin/open` (Ghostty, WezTerm, Alacritty), `/usr/bin/sqlite3` (Antigravity's database), `/usr/bin/grep`, `/bin/ps`, `/usr/sbin/lsof`, `/usr/bin/ditto` and `/bin/sh` (updates).
