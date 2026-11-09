# Installation

After this guide you have AI Shelf running and know what it will ask for.

## Requirements

- macOS 26.
- At least one supported agent installed and used at least once, so it has history. See the table in the [README](../README.md#supported-agents).

## Install from a release

1. Open the [latest release](https://github.com/cmxau/ai-shelf/releases/latest).
2. Download `AI-Shelf-X.Y.Z.zip`.
3. Double-click the zip to unpack it.
4. Move `AI Shelf.app` to `/Applications`.

Install in a folder you can write to (`/Applications` or `~/Applications`). The updater cannot replace an app in a folder you cannot write to.

If you have the Command Line Tools and prefer to build it yourself, see [setup.md](setup.md).

## First launch of an unsigned app

The app is not signed or notarized, so macOS blocks a plain double-click the first time.

1. Right-click (or Control-click) `AI Shelf.app` and choose **Open**.
2. In the dialog, click **Open**.

If macOS offers no Open button, open **System Settings, Privacy & Security**, scroll to the message about "AI Shelf", and click **Open Anyway**.

From a terminal you can instead remove the quarantine flag:

```sh
xattr -dr com.apple.quarantine "/Applications/AI Shelf.app"
```

You only need to do this once per downloaded copy.

## What you see

- A window listing projects and sessions for the agent chosen in the toolbar.
- A books icon in the menu bar with your most recent projects.
- A Dock icon. Turn it off in Settings, General, **Keep Dock icon when no window is open**.

If no agent shows up, AI Shelf did not find any supported command in your login shell, or you have not used them yet. Check with `zsh -lic 'command -v claude'`. History folders can be changed in Settings, Paths.

## Permissions

| Prompt | When | Why | If you decline |
| --- | --- | --- | --- |
| Automation: "AI Shelf wants to control Terminal" (or iTerm) | The first time you open a project in Terminal or iTerm | AI Shelf sends an AppleScript command to start the session. The usage text is "Open projects in your terminal." | Opening in Terminal and iTerm fails. Ghostty, WezTerm and Alacritty do not need this permission. You can grant it later in System Settings, Privacy & Security, Automation. |
| Notifications | The first time a notification is due (budget alert, new version) | Tell you about budget thresholds and updates. | AI Shelf falls back to a basic system notification. You can turn notifications off in Settings, General. |

AI Shelf asks for nothing else itself. If your history or projects live in a location that macOS protects, macOS may ask you to allow access when AI Shelf first reads or checks it.

The global shortcut (Control-Option-S) needs no permission. Turn it off in Settings, General if it clashes with another app.

## Update

- By default AI Shelf checks GitHub for a new release when it starts, at most once a day. If one exists, it notifies you.
- Open **Settings, About** and click **Install Update**. AI Shelf downloads the zip, checks it, quits, swaps the app bundle and reopens.
- To check by hand, use **AI Shelf, Check for Updates...** or the button in About.
- **Install updates automatically** installs without asking. It is off by default.
- Both options can be turned off in About. You can then update by downloading the zip yourself.

If the app is in a folder you cannot write to, or is not running as an installed `AI Shelf.app` bundle, the updater tells you to download the update manually.

## Uninstall

1. Quit AI Shelf (menu-bar item, **Quit**).
2. Delete the app:

   ```sh
   rm -rf "/Applications/AI Shelf.app"
   ```

3. Optionally remove its data:

   ```sh
   rm -rf ~/Library/Caches/ai-shelf
   defaults delete com.cmxau.ai-shelf
   ```

   The cache folder holds the stats ledger and fetched prices. Deleting it loses lifetime statistics for sessions that no longer exist on disk. Export your statistics first if you want to keep them (File, Export Statistics...).

4. If you granted Automation or Notifications, you can remove the entries in System Settings.

AI Shelf never changes your agents' own settings. Your session history is untouched by uninstalling, except for sessions you deleted with it (those are in the Trash unless you turned that off).
