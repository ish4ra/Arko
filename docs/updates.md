# Development updates with Sparkle

Arkiv uses **Sparkle 2.10.0**, pinned through its official binary Swift Package
Manager package. macOS 13+, Intel and Apple Silicon remain supported. The app
embeds the complete Universal framework and its helpers, preserving symlinks,
signs nested code inside-out, and tests loading it from the actual packaged app.
The original icon, engine, Finder Services and DMG workflow are unchanged.

## Trust and behavior

**Arkiv → Check for Updates…** uses `SPUStandardUpdaterController`: native version
and release information, secure download, verification, installation and relaunch.
On second launch Sparkle asks permission for background checks. **Automatically
Check for Updates** changes that preference later. Download/install is always
user-confirmed for this development channel; unattended installation is disabled.
Finish or cancel archive operations before installing; Arkiv's existing termination
veto remains in place while operations are running.

Both ZIP and appcast are Ed25519/EdDSA-signed. The app requires verification before
extraction and signed feeds, with no timeout fallback to accepting unsigned feeds.
The feed and payload use HTTPS. No custom installer or downloader is implemented.
Builds without a configured public key do not start Sparkle; Check for Updates
explains the missing configuration instead of trusting an invented key.

These builds remain **ad-hoc signed and not notarized**. To load an embedded
framework without an Apple Team ID, the development app has the
`com.apple.security.cs.disable-library-validation` entitlement as documented by
Sparkle. This is a narrowly scoped development accommodation, not a Gatekeeper
bypass. Remove it when transitioning to properly Developer ID-signed distribution.
No Apple certificates or notarization secrets are required or fabricated.

## One-time key setup (on your Mac)

Do this **before the final manual installation**. A keyless build cannot later
learn a trusted public key from the internet.

1. Download the official [Sparkle 2.10.0 distribution](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0).
   Alternatively resolve this repository's macOS package with `swift package resolve`;
   the tools are under `.build/artifacts/sparkle/Sparkle/bin/` (locate `generate_keys`
   there if SwiftPM changes capitalization/layout).
2. In the distribution directory, generate one persistent identity in your Mac's
   login Keychain:

   ```sh
   ./bin/generate_keys --account Arkiv-development
   ```

   Save the printed **public** key (the base64 string for `SUPublicEDKey`). In
   GitHub → ish4ra/Arkiv → Settings → Secrets and variables → Actions → Variables,
   create repository variable **`SPARKLE_PUBLIC_ED_KEY`** with that exact string.
   CI embeds it in the built app's Info.plist; it is public and is not a secret.
3. Export the private key **outside any Git checkout**, using a private directory:

   ```sh
   mkdir -p "$HOME/.arkiv-signing"
   chmod 700 "$HOME/.arkiv-signing"
   umask 077
   ./bin/generate_keys --account Arkiv-development -x "$HOME/.arkiv-signing/arkiv.private-key"
   gh secret set SPARKLE_PRIVATE_ED_KEY --repo ish4ra/Arkiv < "$HOME/.arkiv-signing/arkiv.private-key"
   ```

   The required repository Actions secret is **`SPARKLE_PRIVATE_ED_KEY`**: the
   exact exported file contents, not its filename and not a second base64 encoding.
   You can also use GitHub's secret editor. Never paste it into issues, logs, Git,
   workflow YAML, or an app bundle. No PAT secret is needed: publishing uses the
   job-scoped `GITHUB_TOKEN` with `contents: write`.
4. Back up the export in an encrypted offline vault with a separate recovery copy.
   Keep the login Keychain copy. Remove the temporary export after verifying your
   backup. To restore on a replacement Mac, use `generate_keys --account
   Arkiv-development -f /secure/path/arkiv.private-key`. Do not regenerate/rotate
   the key casually: without Developer ID, losing this trust root may require
   another manual installation. Protect both the key and GitHub repository access.

The workflow skips publishing with a clear notice until **both** settings exist.
Ordinary build/test/DMG CI still runs. Never configure secrets on a fork for this
publisher; the public URLs intentionally identify ish4ra/Arkiv.

## Feed and build versions

The stable development feed URL embedded in Arkiv is:

```
https://raw.githubusercontent.com/ish4ra/Arkiv/updates/appcast.xml
```

After both matrix jobs pass on main, CI signs the exact verified Universal ZIP,
verifies its signature against the embedded public key, signs the appcast, then
creates a **prerelease** `dev-<build>` with `Arkiv-universal.zip` and `appcast.xml`.
Only after publicly downloading and verifying that immutable payload does CI
commit the byte-identical signed `appcast.xml` to the dedicated **updates** branch.
The branch contains only that file. A normal fast-forward push advances its ref
atomically: readers see either the old valid feed or the new valid feed. The live
feed is never deleted/reuploaded. GitHub's CDN may briefly serve an older valid
feed; publication does not create a missing-object/404 interval. This cannot
prevent independent GitHub/network outages.

The publisher verifies previous feed signatures and compares versions using the
Git branch contents, avoiding stale CDN monotonicity decisions. Unexpected
network/authentication errors, malformed metadata, non-increasing versions,
unavailable or mismatched payloads, signature failures, unrelated branch files,
and rejected Git pushes all fail closed. No force-push or branch deletion is
used. Publishing remains serialized. CI fetches the public new feed and verifies
its bytes, signature, version and immutable enclosure. Do not delete the updates
branch, releases a feed references, reuse tags, or overwrite payloads.

### Migration from the release-asset feed

Build 12801 and older read:

```
https://github.com/ish4ra/Arkiv/releases/download/development-updates/appcast.xml
```

The first migration publication updates **both** feeds with the same signed
appcast, after verifying the new branch feed and payload. That last legacy
replacement still uses GitHub's asset replacement API; it can have the old gap
**once during migration**, not during future publication. The signed channel
`link` identifies the new feed, allowing later publishers to leave the legacy
asset frozen indefinitely. It is not an HTTP redirect: old installations discover
the migration build, install it with their existing trusted key, then use the new
embedded `SUFeedURL` on relaunch. They can subsequently update to the latest build.
No key rotation or manual reinstall is needed. If migration upload fails after
the branch push, the next higher-numbered full build retries the legacy bridge;
never overwrite an immutable release or rerun a partial publish to recover.
No stable production release is created.

`CFBundleVersion = 10000 + github.run_number * 100 + github.run_attempt` for this
existing macos.yml workflow. Keep this workflow's run-number sequence; do not
reset it, and use fewer than 100 attempts per run. Local builds default to 3, or
accept an explicit `ARKIV_BUILD_VERSION`. The human version stays 0.1.0; the update
UI includes the numeric development build. A SHA is never used as the machine
version. Dispatch a **new full workflow run** for every new test update; do not
rerun only the publish job using older artifacts.

All four existing DMG/ZIP artifacts remain available. Updates always use the
Universal ZIP so an arm64 installation can transition safely to the same feed as
Intel. macOS CI verifies the built app, mounted DMG and copied installation,
framework architectures/signatures/loadability, metadata, and real ZIP signing
with a disposable test identity. It rejects corrupted signatures/feeds and a
wrong embedded key. Disposable test keys are never committed or published.
The tracked-file guard rejects conventional private-key files/blocks; publishing
also rejects the exact configured secret in any tracked file. No heuristic can
identify every arbitrary random seed, so never export one into the repository.

## Real-Mac test

1. On an existing build (12801 or older), choose **Arkiv → Check for Updates…**.
   Install the migration update and relaunch. The existing key/secret setup stays
   unchanged; no manual DMG replacement is required.
2. Confirm the installed build number increased and `SUFeedURL` in
   `/Applications/Arkiv.app/Contents/Info.plist` is the raw GitHub URL above.
3. Check for updates again. The new feed should report current status or offer a
   later build. The legacy feed remains available for Macs that migrate later.
4. During a subsequent full main workflow publication, repeatedly check updates
   (and fetch the stable URL in a browser). Responses may show the old or new
   version during CDN propagation, but publication must not remove the appcast.
5. Install a subsequent update. Verify Finder actions, Services, ZIP browsing and
   extraction, declining updates, background-check preferences, and offline
   recovery. Repeat on Intel with the Universal payload.

Fresh installations still need the development Gatekeeper approval described in
[release.md](release.md). Do not disable Gatekeeper. Existing Sparkle installations
should not need repeated DMG replacement or xattr commands.

CI cannot prove the full interactive install/relaunch or local macOS security
policy. Those remain real-Mac acceptance tests, especially for ad-hoc builds.
EdDSA establishes update authenticity; it does not confer Apple notarization.

## Research references

Official documentation inspected for this integration:
[setup and signing](https://sparkle-project.org/documentation/),
[programmatic AppKit controller](https://sparkle-project.org/documentation/programmatic-setup/),
[security and automatic-check settings](https://sparkle-project.org/documentation/customization/),
[helper signing](https://sparkle-project.org/documentation/sandboxing/).
The official documentation repository and Sparkle 2.10.0 package/source were read
via GitHub, including `sign_update` stdin handling and signed-feed verification.

### Atomic-feed compatibility research

Sparkle 2.10.0's pinned [`SUAppcastDriver.m`](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SUAppcastDriver.m)
downloads the configured URL, verifies the signed feed bytes, then passes XML to
[`SUAppcast.m`](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SUAppcast.m).
It does not require a GitHub Release endpoint or an XML-specific MIME type.
GitHub raw serves the committed bytes over HTTPS; the signed appcast retains its
absolute HTTPS release-enclosure URL. Thus changing the host path preserves
Sparkle's native verification and installation flow. CI additionally verifies
byte-for-byte public raw delivery with the pinned Sparkle signing tool.

## Recovery from a stale Check for Updates menu

Affected development builds can say “Updates are not configured in this build”
even when `SUPublicEDKey` is present: the application menu was created before
Sparkle started, and retained its initial fallback action. The fix retains and
refreshes both updater menu items after startup, including a quiet Finder launch
followed by an interactive reopen. It does not start Sparkle during quiet Finder
operations. Genuinely keyless builds still show the configuration message.

For an affected installation, make one manual replacement using the fixed build:

1. Download the Universal development DMG from the successful fix workflow's
   `Arkiv-universal-development-dmg` artifact, or its signed development release's
   `Arkiv-universal.zip` asset.
2. Quit Arkiv after archive operations finish. Open the DMG and drag Arkiv.app to
   Applications, confirming replacement. For the ZIP, unzip and replace the app
   in Applications. Eject the DMG and launch the installed app.
3. Apply the existing [development first-launch instructions](release.md#signing-notarization-and-gatekeeper)
   if macOS blocks the manual download. The build remains ad-hoc signed and not
   notarized; this fix does not change signing policy or update keys.
4. Choose **Arkiv → Check for Updates…**. Sparkle should show an update or “up to
   date”, rather than the configuration alert. **Automatically Check for Updates**
   should be enabled and reflect the stored Sparkle preference.
5. Quit, invoke Finder **Extract Here** on a test archive, then open Arkiv from
   Applications/Dock. The same updater menu must work after this delayed startup.

Future signed updates continue through the existing atomic feed. No EdDSA key
regeneration or GitHub secret changes are required for this fix.
