# Developer setup

## Requirements

- macOS 26.
- Xcode Command Line Tools: `xcode-select --install`. Full Xcode is not needed.

`build.sh` runs `xcrun swiftc` with no `-target`, so it builds for the Mac you run it on and the SDK that the Command Line Tools provide.

Check your toolchain:

```sh
xcrun swiftc --version
xcrun swift-format --version
```

`swift-format` ships with the Command Line Tools. You do not need to install it separately.

## Get the code

```sh
git clone https://github.com/cmxau/ai-shelf.git
cd ai-shelf
```

## Build

```sh
./build.sh              # produces "AI Shelf.app" in the repo root
./build.sh --install    # also replaces /Applications/AI Shelf.app
```

The script:

1. Compiles `Sources/*.swift` into `AI Shelf.app/Contents/MacOS/ai-shelf` (`-parse-as-library -O`).
2. Copies `AppIcon.icns` into the bundle.
3. Writes `Info.plist` with the version from `VERSION`. The bundle id is `com.cmxau.ai-shelf`.
4. Prints `Built: <path>`.

It does not sign the app. `AI Shelf.app/` and `*.zip` are in `.gitignore`.

A successful `./build.sh` is the compile check. There is no separate `swift build` or Xcode project.

## Run

```sh
open "AI Shelf.app"
```

To see output from the process, run the binary directly:

```sh
"AI Shelf.app/Contents/MacOS/ai-shelf"
```

If a copy is already installed in `/Applications`, quit it first so the shortcut (Control-Option-S) and menu-bar item do not clash.

The self-updater only replaces a bundle whose id is `com.cmxau.ai-shelf` and that sits in a writable folder. If you run your build from the repo, leave "Install updates automatically" off in Settings, About, so a newer release never replaces your local build.

## Format and lint

The style config is `.swift-format` (4 spaces, 160 columns).

```sh
xcrun swift-format lint --strict --recursive Sources    # must print nothing
xcrun swift-format format --in-place --recursive Sources # fix formatting
```

Run lint before every commit. CI runs the same lint and the build (see [contributing.md](contributing.md)).

## Repo layout

| Path | What |
| --- | --- |
| `Sources/` | All app code. See [architecture.md](architecture.md). |
| `build.sh` | Builds the app bundle. |
| `VERSION` | The version, one line (for example `1.0.0`). |
| `AppIcon.icns` | App icon. |
| `make-icon.swift` | Script that generates the icon. Not part of the app. |
| `.swift-format` | Formatter and lint config. |
| `.github/ISSUE_TEMPLATE/` | Bug report and feature request forms. |
| `.github/workflows/` | `ci.yml` and `release.yml`. |
| `docs/` | This documentation. |

## Where the app keeps its data while you develop

- Preferences: `defaults read com.cmxau.ai-shelf`
- Caches: `~/Library/Caches/ai-shelf/`

Delete these to test a first launch. See [installation.md](installation.md#uninstall) for the commands.

## Using a different history folder

You can point each agent at a test folder in Settings, Paths. This is the safest way to try delete, undo and Fix Path without touching real history. Copy a few session files into a scratch folder with the same layout as the real one (see [api.md](api.md)).

## Conventions

- Keep the build working with only the Command Line Tools. That means `ObservableObject`, not the `@Observable` macro.
- Put every new `UserDefaults` key in `enum Pref`.
- Anything read from a session file, an imported file or a web page is untrusted. Read [security.md](security.md) before touching launching, deleting, stats import or updating.
