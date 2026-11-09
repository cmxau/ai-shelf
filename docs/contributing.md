# Contributing

Thanks for helping. This page covers the workflow and what a change must pass.

## Ground rules

- **Never commit to `main`.** Work on a branch and open a pull request.
- Keep a change focused. One fix or feature per pull request.
- The app must keep building with only the Command Line Tools (see [setup.md](setup.md)).
- Anything read from disk or the network is untrusted. Read [security.md](security.md) first if you touch launching, deleting, stats import, price parsing or updating.

## Branch names

Use a short prefix and a topic, lowercase with hyphens:

| Prefix | Use |
| --- | --- |
| `feat/` | New feature or agent support |
| `fix/` | Bug fix |
| `docs/` | Documentation only |
| `chore/` | Tooling, cleanup, CI |
| `security/` | Hardening |

Example: `fix/codex-token-reset`.

## Workflow

1. Create a branch from an up-to-date `main`.
2. Make the change. Add or update the docs in the same pull request (code without docs is incomplete). Update [api.md](api.md) if you change a file format, a preference key or what the updater expects.
3. Run the checks below.
4. Commit with a clear message that says what and why.
5. Push the branch and open a pull request. Describe what changed, how you tested it, and which agents you tried it on.

## Checks that must pass

CI (`.github/workflows/ci.yml`) runs the same two checks on every pull request.

```sh
xcrun swift-format lint --strict --recursive Sources   # no output means clean
./build.sh                                              # must end with "Built: ..."
```

To fix formatting automatically:

```sh
xcrun swift-format format --in-place --recursive Sources
```

Do not change `.swift-format` to make a lint error go away.

## Testing manually

There is no automated test suite. Run the app and check the paths your change can affect. Use a scratch history folder (Settings, Paths) for anything that deletes or rewrites files.

Always:

- The app starts, the list loads, and quitting and reopening keeps your settings.
- Switching the agent in the toolbar reloads the list.

Then, depending on the change:

| Area | Check |
| --- | --- |
| Loaders | Sessions appear under the right folder with the right title, count and size for each agent you can test. Empty and missing folders do not crash. |
| Preview and search | Selecting a session shows its first and last message. A search of three or more characters finds text inside a conversation. |
| Launching | Open a project and resume a session in each terminal you can. Try a folder name with spaces and a quote in it. |
| Delete | Delete with Trash on, then Undo. Delete with Trash off (use a scratch folder). Items outside the configured history folders are refused. |
| Fix Path | Move a Claude project, run Fix Path, and check the session still resumes and stats are not double counted. |
| Stats and prices | Token and cost numbers look right against a session you know. Fetch official prices and check each vendor reports a model count. |
| Export and import | Export a ledger, delete the cache, import it, and check the totals return. Import a file with `"version": 2` and check it is refused. |
| Sync | Set a sync folder, scan, and check `ai-shelf-stats.json` appears with mode 0600. |
| Updater | The check reports up to date or a new version. Test install only with a build in a writable folder, and only against a release you control. |
| Menu bar and shortcut | The menu-bar list opens projects. Control-Option-S brings the window forward with search open. |

Say in the pull request what you could not test. For Codex and Gemini, say whether you used real sessions.

## Code style

- Follow the surrounding code and the `.swift-format` config.
- Prefer the standard library and system tools over new code. There are no third-party dependencies, and a pull request that adds one needs a strong reason.
- Add new `UserDefaults` keys to `enum Pref`.
- Comments explain why, not what.

## Reporting bugs and requesting features

Use the issue forms: [New issue](https://github.com/cmxau/ai-shelf/issues/new/choose). From the app, Help, **Report a Bug...** or **Request a Feature...** opens the form with your app and macOS version filled in.

A good bug report has:

- What you did, what you expected, and what happened.
- The agent involved, the AI Shelf version (Settings, About), your macOS version and terminal.
- Screenshots or logs with private paths and prompts removed.

For new agent support, attach a small sample of the agent's session file (with content removed) so the format can be checked.

## Security issues

Do not open a public issue for a vulnerability. Follow [security.md](security.md#reporting-a-vulnerability).

## Releases

Maintainers only. See [releasing.md](releasing.md).
