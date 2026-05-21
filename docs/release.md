# Cutting a release

Three make commands ship a new Seshctl version end-to-end:

```bash
make dist      # build + sign DMG
make appcast   # regenerate Sparkle appcast (EdDSA-signed)
make publish   # commit + push metadata, wait for Pages, gh release create
```

Phase 1 of the manual release pipeline. CI automation is deferred to Phase 3.

## How it works

Sparkle auto-updates use **two parallel channels** that travel together:

| Channel | What it carries | Where it lives |
|---|---|---|
| **Metadata** (text, version-controlled) | `Resources/Info.plist` (version bump), `docs/release-notes/<VERSION>.md`, `docs/appcast.xml` (EdDSA signature + download URL) | Committed to `main`; served by **GitHub Pages** from the `/docs` folder at `https://julo15.github.io/seshctl/appcast.xml` |
| **Artifact** (binary, NOT in git) | `Seshctl-<VERSION>.dmg` (signed by self-signed code-signing cert + EdDSA over the DMG bytes) | Uploaded as a **GitHub Release asset** at `github.com/julo15/seshctl/releases/download/v<VERSION>/Seshctl-<VERSION>.dmg` |

A user's Sparkle client does these four steps in order:

1. **Fetch metadata** — on launch and every 24h, HTTP GET to the Pages appcast URL.
2. **Version-compare** — `<sparkle:version>` in the appcast vs the bundled `CFBundleVersion`. If the appcast's is higher, show the update prompt.
3. **Download artifact** — pull the DMG from the URL the appcast advertises (the GitHub Releases path).
4. **Verify + swap** — check the bytes against the EdDSA signature in the appcast (public key bundled in the app's Info.plist), strip quarantine, replace `/Applications/Seshctl.app`, relaunch.

**The order of `make publish` matters.** It pushes the metadata first, polls Pages until the new appcast is live, *then* creates the GitHub Release. Reversed, the release tag exists but the appcast still advertises the old version — Sparkle in already-shipped builds doesn't see anything to update to until Pages catches up. `make publish-docs` and `make publish-release` are separable so you can re-run only the second if `gh release create` fails midway.

## One-time setup

```bash
brew install create-dmg gh jq discount
make cert-setup                # self-signed code-signing identity, login keychain
gh auth login
swift build                    # fetches Sparkle artifact under .build/
.build/artifacts/sparkle/Sparkle/bin/generate_keys
# back up the printed private key per docs/signing.md (1Password)
```

Then enable GitHub Pages once: **repo Settings → Pages → Source: `main` / Folder: `/docs`**. Within 60s `https://julo15.github.io/seshctl/` should serve.

Tools needed:

- `create-dmg` — styled DMG builder.
- `gh` — GitHub CLI; creates the Release.
- `jq` — required by hook installer scripts (smoke-test paths).
- `discount` — provides the `markdown` CLI used to render release notes into the appcast `<description>`.
- `node` / `npm` — bundled VS Code/Cursor extension build (managed via `asdf`).

Back up the EdDSA private key (one-line base64) and the `.p12` code-signing key to 1Password. See [`docs/signing.md`](signing.md) for details.

## Cutting a release

1. **Bump version** in [`Resources/Info.plist`](../Resources/Info.plist):
   - `CFBundleShortVersionString`: human-facing (e.g., `0.3.0` → `0.4.0`).
   - `CFBundleVersion`: monotonically-increasing integer that Sparkle compares (`3` → `4`). **Sparkle ignores releases that don't strictly bump this.**
2. **Write release notes** at `docs/release-notes/<VERSION>.md`. Used as both Sparkle's update prompt body and the GitHub Release body — single source of truth.
3. **Verify tests pass**: `swift test` (via a subagent per [`AGENTS.md`](../AGENTS.md)).
4. **Build**:

   ```bash
   make dist        # → dist/Seshctl-<VERSION>.dmg
   ```
5. **Smoke test the DMG** (don't skip — the `.dmg` is what users run, not your local build):

   ```bash
   open dist/Seshctl-<VERSION>.dmg
   ```

   Drag `Seshctl.app` to a temp folder (NOT `/Applications`), right-click → Open, confirm the welcome panel appears, then **Cancel** out — you don't want this build to overwrite your dev install. Quit. Detach: `hdiutil detach "/Volumes/Seshctl <VERSION>"`.
6. **Regenerate the appcast**:

   ```bash
   make appcast     # → docs/appcast.xml
   git diff docs/appcast.xml   # review
   ```
7. **Publish** (commits metadata, waits for Pages, creates GitHub Release):

   ```bash
   make publish
   ```

   `make publish` chains `publish-docs` (commit + push + poll Pages with 5min timeout) then `publish-release` (`gh release create` with DMG + notes). Pre-flight checks refuse if you're not on `main`, the working tree has unexpected changes, the DMG is missing, the tag already exists, etc.

8. **Verify**: `gh release view "v$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)"`.

### Distribute

Users on **v0.4.0+** auto-update through Sparkle within 24h of launch (or on-demand via Settings → About → Check for Updates…). No Slack message needed for ordinary upgrades.

Slack only when:

- **v0.4.0 cutover.** Existing v0.3.0 installs don't bundle Sparkle; they need the link once.
- **Public-key rotation.** Sparkle in shipped builds will fail signature verification on the new DMG; users have to manually download. See [`docs/signing.md`](signing.md#public-key-rotation-if-the-private-key-is-lost).

Include in the Slack message:

- "Drag to `/Applications`, replace if it's already there. TCC grants are preserved across replacements."
- "First install: right-click → Open to bypass Gatekeeper (self-signed; goes away in Phase 1B)."
- A one-line "what changed" summary.

## If something fails

| Symptom | Recovery |
|---|---|
| `publish-docs` failed during pre-flight | Fix the underlying issue (drift, missing file, wrong branch). Re-run `make publish` — pre-flight is fully idempotent. |
| `publish-docs` failed during Pages poll (>5min) | Check the repo's Actions tab for a failed Pages build. Once Pages recovers, re-run `make publish` — the idempotency check skips past the already-pushed commit. |
| `publish-release` failed during DMG upload | Re-run `make publish-release` directly. If the release exists but is missing the asset: `gh release upload v<VERSION> dist/Seshctl-<VERSION>.dmg`. To delete + retry: `gh release delete v<VERSION> --cleanup-tag --yes && make publish-release`. |
| Released from a new Mac, prior versions dropped from appcast | `dist/releases/` is local mirror state. Re-hydrate before the first `make appcast` on a new host: `gh release list --limit 50 --json tagName -q '.[].tagName' \| while read t; do gh release download "$t" --pattern "Seshctl-*.dmg" --dir dist/releases/ \|\| true; done`. |

## Troubleshooting

### `create-dmg` failed with `hdiutil: create failed`

A stale `swift-build` / `pkgbuild` process holds a lock on the bundle. Run `make kill-build && make dist`. If the second attempt also fails, check `mount | grep Seshctl` for a leftover mounted DMG and detach it.

### `codesign` warns about timestamp

Expected with self-signed certs. We pass `--timestamp=none` because Apple's TSA only signs Apple-issued certs. Phase 1B drops this when we have a Developer ID.

### Sparkle says "no update available" but the appcast has a newer entry

Check that `CFBundleVersion` (the integer) strictly increased — Sparkle compares this, not `CFBundleShortVersionString`. A bump from `0.3.0` → `0.4.0` with `CFBundleVersion` stuck at `3` is ignored.

### Sparkle rejects with a signature error

Either the DMG was modified after `make appcast` signed it (e.g., a re-uploaded build with the same filename), or `SUPublicEDKey` in Info.plist doesn't match the private key in the Keychain. Re-run `make appcast`; if still failing, compare the in-bundle public key against the Keychain:

```bash
plutil -extract SUPublicEDKey raw -o - Resources/Info.plist
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p
```

Both should print the same base64 string.

### GitHub Pages serves stale appcast

Pages caches aggressively. Wait ~60s after push; if still stale, check the Actions tab for a failed Pages build.

### macOS Gatekeeper says "damaged or untrusted" / "cannot verify developer"

Normal Stage 1A first-install experience until Phase 1B notarization. Right-click `Seshctl.app` → **Open** → **Open** in the dialog. This stores a per-user override; subsequent launches and Sparkle-driven updates skip the prompt automatically.

If you see "damaged" *after* a successful first-run, the bundle was modified after signing (e.g., quarantine xattr). Try `xattr -cr /Applications/Seshctl.app`, then right-click → Open.

## After-release sanity check

Verify the release reproduces the user experience, not just yours:

1. Download the DMG from the GitHub Release on a different Mac (or temporarily move `Seshctl Self-Signed` out of your login keychain to simulate).
2. Drag to `/Applications`, right-click → Open.
3. Confirm the welcome panel, click Install, confirm the symlink + hooks land.
4. Trigger a remote Claude session focus, allow the Automation prompt once, confirm the second focus does NOT re-prompt.

For Sparkle specifically: bump a test version locally, run through `make publish`, and confirm a previously-installed copy at the older version shows the update prompt within ~5 minutes of relaunch.
