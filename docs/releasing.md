# Releasing

For maintainers. A release is a version bump, a tag, and a zip attached to a GitHub release.

## How the app finds a release

The app asks GitHub for the latest release of `cmxau/ai-shelf`, strips a leading `v` from `tag_name`, and compares it with its own version (`CFBundleShortVersionString`, which `build.sh` copies from `VERSION`). If the tag is higher, it offers the first `.zip` asset. If GitHub gives that asset a SHA-256 digest, the app requires the download to match. Full contract: [api.md](api.md#what-the-updater-expects-from-a-release).

So:

- `VERSION` and the tag must agree (`VERSION` = `1.2.0`, tag = `v1.2.0`). If the tag is higher than the build's `VERSION`, every user is offered the same update forever.
- The zip must contain `AI Shelf.app` at its top level.
- Draft and pre-release releases are not returned by GitHub's "latest" endpoint, so they are never offered.

## Checklist

1. Start from an up-to-date `main` and create a branch, for example `chore/release-1.2.0`.
2. Edit `VERSION` to the new version (`X.Y.Z`, numbers and dots only).
3. Check the docs describe the release: any changed file format or preference key in [api.md](api.md), and a migration note for anything breaking.
4. Run the checks:

   ```sh
   xcrun swift-format lint --strict --recursive Sources
   ./build.sh
   ```

5. Open a pull request, get it merged into `main`.
6. Tag the merge commit and push the tag:

   ```sh
   git checkout main && git pull
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

7. Wait for the **Release** workflow (`.github/workflows/release.yml`). On a pushed tag matching `v*` it:
   - builds the app with `./build.sh`,
   - zips `AI Shelf.app` as `AI-Shelf-<version>.zip`,
   - creates the GitHub release for the tag with that zip attached.
8. Verify the release (below).

## Verify a release

1. Open the release page and check the zip `AI-Shelf-X.Y.Z.zip` is attached and the tag is `vX.Y.Z`.
2. Download it, unpack it, and run `AI Shelf.app` (see [installation.md](installation.md)). In Settings, About, check the version shows `X.Y.Z`.
3. From the previous version, choose Check for Updates, then Install Update. Check that it restarts into the new version.
4. The API shows what the updater sees:

   ```sh
   curl -s https://api.github.com/repos/cmxau/ai-shelf/releases/latest | grep -E '"tag_name"|"name"|"digest"'
   ```

## Fixing a bad release

- Do not move or reuse a tag users may have downloaded. Ship a higher version.
- If a release must be withdrawn, delete the release (or mark it as a draft) so the updater stops offering it. Users who already updated stay on that version until the next release.

## Versioning

Use `MAJOR.MINOR.PATCH`. The app compares versions as integers per component, so `1.10.0` is newer than `1.9.0`. Do not use suffixes such as `-beta`: a non-numeric component counts as 0.
