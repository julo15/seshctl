# Cutting a release (Phase 1/2, manual)

This walks through producing a signed `.dmg`, regenerating the Sparkle appcast, and uploading it all to a GitHub Release. Each step is manual — `make dist` + `make appcast` on your Mac, `git push` for the appcast, `gh release create` for the DMG. CI automation is deferred to Phase 3.

For the bigger picture (why we're self-signed first, what later phases add), see the plan: [`.agents/plans/2026-05-08-1151-seshctl-real-app-phase1.md`](../.agents/plans/2026-05-08-1151-seshctl-real-app-phase1.md).

## Prerequisites (one-time)

Install the tools:

```bash
brew install create-dmg gh jq discount
```

- [`create-dmg`](https://github.com/create-dmg/create-dmg) — builds the styled `.dmg`.
- [`gh`](https://cli.github.com/) — GitHub CLI used to create the Release. Auth via `gh auth login`.
- `jq` — used by hook installer scripts; required for end-to-end smoke tests.
- `discount` — provides the `markdown` CLI that `make appcast` calls to render `docs/release-notes/<VERSION>.md` into the appcast `<description>`. Without it the script falls back to a `<pre>`-wrapped copy and Sparkle's update prompt shows raw Markdown.

`npm` (Node) must also be on PATH on the release build host. `make bundle` invokes it under the hood to build `vscode-extension/` and produce the bundled `.vsix`. Manage Node with `asdf` (per [`AGENTS.md`](../AGENTS.md) global guidance) rather than `brew install node`. The build drops two artifacts into the bundle automatically — `Contents/Resources/extensions/seshctl.vsix` and `Contents/Resources/extensions/seshctl.vsix.version` — via `scripts/build-app-bundle.sh`. No manual step.

Set up the self-signed code-signing identity (once per Mac):

```bash
make cert-setup
```

See [`docs/signing.md`](signing.md) for what this does, where the cert lives, and how to back it up. **Back up the `.p12`** to 1Password before continuing — losing it means a different code signature on the next Mac, which invalidates every TCC grant.

Authenticate the GitHub CLI (once per Mac):

```bash
gh auth login
```

See the [`gh` docs](https://cli.github.com/manual/gh_auth_login) for OAuth vs. token flow.

Set up Sparkle's EdDSA signing key (once per release host):

```bash
swift build   # fetches the Sparkle artifact if missing
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

See [`docs/signing.md`](signing.md#eddsa-key-for-sparkle-auto-updates) for what this does, how to back it up to 1Password, and the public-key-rotation procedure if the private key is ever lost.

## GitHub Pages dependency (one-time)

Sparkle's appcast is served from this repo's `docs/` folder via GitHub Pages. Enable once:

1. Repo Settings → Pages.
2. Source: **Deploy from a branch**, Branch: **main**, Folder: **/docs**. Save.
3. Wait ~60 seconds, then verify `https://julo15.github.io/seshctl/appcast.xml` returns the latest committed content.

This is one-time; subsequent appcast updates flow via `git push` to `main`.

## Pre-release checklist

Before tagging anything:

- [ ] **Tests pass.** Run `swift test` in a subagent (per [`AGENTS.md`](../AGENTS.md)). Don't proceed on red.
- [ ] **Bump `CFBundleShortVersionString`** in [`Resources/Info.plist`](../Resources/Info.plist). E.g. `0.3.0` → `0.4.0`. This is the human-facing version.
- [ ] **Bump `CFBundleVersion`** to a new monotonically increasing integer. E.g. `3` → `4`. Sparkle compares this for "is the appcast advertising something newer than what's running"; if it doesn't strictly increase, the auto-update won't fire. Note: `CFBundleVersion` is a string-typed plist value (`<string>` in `Resources/Info.plist`) containing a monotonically-increasing integer.
- [ ] **Write release notes** at `docs/release-notes/<VERSION>.md`. `make appcast` reads this file and embeds it into the appcast `<item>`'s `<description>` so Sparkle's update prompt shows the notes. Plain Markdown — `markdown` (Daring Fireball / `brew install discount`) renders it; without that on PATH the script falls back to a `<pre>`-wrapped copy.
- [ ] Working tree is clean: `git status` shows nothing uncommitted.

## Build & sign

```bash
make dist
```

This runs three steps in order:

1. `make bundle` — universal release build, assembles `dist/Seshctl.app`.
2. `make sign` — signs `seshctl-cli` (nested) then `Seshctl.app` (outer) with the `Seshctl Self-Signed` identity. Hardened runtime + `--timestamp=none`.
3. `make-dmg` — produces `dist/Seshctl-<VERSION>.dmg` via `create-dmg`.

Output: `dist/Seshctl-<VERSION>.dmg` ready to attach to a Release.

## Smoke test the DMG locally

Don't skip this. The `.dmg` is what users run, not the `.app` you just built.

```bash
open dist/Seshctl-<VERSION>.dmg
```

Confirm the bundled extension artifacts are present and non-empty before opening the DMG:

```bash
ls -l dist/Seshctl.app/Contents/Resources/extensions/seshctl.vsix \
      dist/Seshctl.app/Contents/Resources/extensions/seshctl.vsix.version
```

Both files must exist with non-zero size. If either is missing or empty, `make bundle` didn't run the extension build — most likely cause is `npm` not being on PATH.

In Finder:

1. Drag `Seshctl.app` to a temp folder (e.g. `~/Desktop/seshctl-smoke/`). **Do NOT drag to `/Applications`** — that's the manual end-to-end test in Step 7 of the Phase 1 plan.
2. Right-click the copied `Seshctl.app` → **Open**. Click **Open** again on the Gatekeeper warning. (Self-signed cert; this is expected until Phase 1B notarization.)
3. The welcome panel should appear (the dragged-to-temp install has no marker file at `~/Library/Application Support/Seshctl/installed-v1.json`, so `FirstLaunchInstaller` triggers).
4. **Cancel out without installing** — you don't want this temp build to overwrite your dev hooks/symlinks.
5. Quit Seshctl from the temp folder.

Detach the DMG:

```bash
hdiutil detach "/Volumes/Seshctl <VERSION>"
```

## Regenerate the Sparkle appcast

```bash
make appcast
```

This runs `scripts/make-appcast.sh`. Under the hood:

1. Copies `dist/Seshctl-<VERSION>.dmg` into `dist/releases/` (the local DMG mirror; gitignored).
2. If `docs/release-notes/<VERSION>.md` exists, renders it to `dist/releases/Seshctl-<VERSION>.html` so Sparkle picks it up as the entry's `<description>`.
3. Runs Sparkle's `generate_appcast` over `dist/releases/` — walks every DMG, signs each one with the EdDSA private key from the login Keychain, and emits a full `appcast.xml` listing all versions.
4. Moves the result into `docs/appcast.xml`.

Review the diff:

```bash
git diff docs/appcast.xml
```

Commit the appcast + release notes and push to publish on Pages:

```bash
git add docs/appcast.xml docs/release-notes/<VERSION>.md
git commit -m "appcast: <VERSION>"
git push
```

GitHub Pages rebuilds within ~60s. Verify:

```bash
curl -sI https://julo15.github.io/seshctl/appcast.xml | head -5
```

## Cut the release

> **Order matters.** Push the appcast/Info.plist/release-notes commit to `main` BEFORE running `gh release create`. Pages takes ~60s to rebuild after a push; once it does, Sparkle clients hitting `https://julo15.github.io/seshctl/appcast.xml` see the new `<item>` whose `<enclosure url>` points at the GitHub Release URL you're about to create. Reversing the order means the release is live but Pages still serves the old appcast (or 404 on the first release) — Sparkle in already-shipped builds 404s on the download and silently retries on the 24h timer. Verify Pages rebuilt with `curl -sI https://julo15.github.io/seshctl/appcast.xml | head -3` before tagging.

Tag and publish in one shot:

```bash
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)
gh release create "v${VERSION}" \
  "dist/Seshctl-${VERSION}.dmg" \
  --title "Seshctl ${VERSION}" \
  --notes-file "docs/release-notes/${VERSION}.md"
```

The `docs/release-notes/<VERSION>.md` file you wrote during the pre-release checklist drives both Sparkle's update prompt (via the appcast) and the GitHub Release body. Single source of truth.

This will:
- Create the `v${VERSION}` git tag locally (if not present) and push it.
- Create the GitHub Release with the DMG attached.
- Print the Release URL.

> **Stage 1A note:** include in the release notes that on first install users must **right-click → Open** to bypass Gatekeeper. This will go away in Phase 1B once we notarize. See [Troubleshooting](#troubleshooting) below.

## Distribute

Get the Release URL:

```bash
gh release view "v${VERSION}" --json url -q .url
```

Slack the link to anyone running Seshctl. Include in the message:

- "Drag to /Applications, replace if it's already there. TCC grants are preserved across replacements."
- "First install: right-click → Open to bypass Gatekeeper (self-signed cert; will go away in 1B)."
- A one-line "what changed" summary.

## After-release sanity check

The point of this step is to verify the release reproduces the user experience, not just yours.

- Download the DMG from the GitHub Release URL on a *different* Mac (or, if you only have one Mac, temporarily move `Seshctl Self-Signed` out of your login keychain — the code signature stays embedded but trust validation runs against a clean keychain).
- Drag to `/Applications`, right-click → Open.
- Confirm the welcome panel appears, click Install, confirm the symlink + hooks land.
- Trigger a remote Claude session focus, allow the Automation TCC prompt, and confirm focusing again does NOT re-prompt.

## Troubleshooting

### `create-dmg` failed with `hdiutil: create failed`

This usually means a stale `swift-build` / `swift-frontend` / `pkgbuild` process is holding a lock on something inside the bundle. Run:

```bash
make kill-build
make dist
```

If the second attempt also fails, there may be a leftover mounted DMG from a previous run — check with `mount | grep Seshctl` and detach it.

### `codesign` warns about timestamp

Expected with self-signed certs. We pass `--timestamp=none` because Apple's secure timestamping authority only signs Apple-issued certs. This warning will disappear in Phase 1B once we have a Developer ID and use plain `--timestamp`. Details in [`docs/signing.md`](signing.md).

### Sparkle / appcast — debugging an update that won't fire

Sparkle's update path is several moving parts:

- **`make appcast` failed with "Sparkle's sign_update / generate_appcast not found".** Run `swift build` to fetch the artifact, then retry.
- **Sparkle says "no update available" but the appcast clearly has a newer entry.** Check that `CFBundleVersion` (the integer build number) strictly increased — Sparkle compares this, not `CFBundleShortVersionString`. A version like `0.4.0` with a `CFBundleVersion` that stayed at `3` will be ignored.
- **Sparkle rejects with a signature error.** The DMG was modified after `make appcast` signed it (e.g., re-uploaded a different build with the same filename) or `SUPublicEDKey` in `Info.plist` doesn't match the private key in the Keychain. Re-run `make appcast`; if that doesn't help, check the keychain item matches the public key with `.build/artifacts/sparkle/Sparkle/bin/generate_keys -p`.
- **GitHub Pages serves stale appcast.** Pages caches aggressively. Wait ~60s after push; if still stale, check Actions tab for a failed Pages build.

### Releasing from a new Mac — re-hydrate `dist/releases/`

`dist/releases/` is gitignored — it's the local DMG mirror that `generate_appcast` walks to build the appcast. **Each Mac you release from has its own.** If you release from a different host than last time (laptop ↔ desktop, fresh machine, etc.), `make appcast` will walk an empty (or sparse) mirror and emit an appcast that drops every prior version. Users on intermediate versions still get the latest update advertised, but the appcast no longer carries the historical `<item>` entries.

Before the first `make appcast` on a new release host, re-hydrate the mirror by downloading every prior DMG from GitHub Releases:

```bash
mkdir -p dist/releases
gh release list --limit 50 --json tagName -q '.[].tagName' | while read tag; do
  gh release download "$tag" --pattern "Seshctl-*.dmg" --dir dist/releases/ 2>/dev/null || true
done
ls dist/releases/   # should list every shipped Seshctl-*.dmg
```

Then `make appcast` produces a complete appcast. Cross-check the resulting `docs/appcast.xml` against the current `main` to confirm no versions were lost (`git diff docs/appcast.xml` should show only the new entry, not deletions).

### macOS Gatekeeper says the app is "damaged or untrusted" / "cannot verify developer"

This is the normal Stage 1A experience. The fix until Phase 1B notarization ships:

1. Right-click `Seshctl.app` in Finder.
2. Click **Open** (not double-click).
3. Click **Open** in the dialog that says "macOS cannot verify the developer."

This stores a per-user override; subsequent launches work via double-click. Document this clearly in the release notes for every Stage 1A release. Phase 1B will replace this with a notarized signature, and the release notes for the 1A→1B version should call out the one-time TCC re-prompt that comes with the cert change.

If you see "damaged" *after* a successful first-run with right-click → Open, the bundle was probably modified after signing (e.g. xattr from the download). Try `xattr -cr /Applications/Seshctl.app` to strip quarantine, then right-click → Open again.
