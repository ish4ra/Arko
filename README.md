# Arkiv

A native macOS archive manager in early development. `ARKIV_SPEC.md` is the authoritative implementation specification.

The first foundation contains an AppKit archive table, folder navigation, search, multi-selection, selected/all extraction into a new directory, progress/cancellation, and a reusable Swift engine backed by system libarchive and a bundled in-process 7-Zip library. It does not require users to install an external compressor.

**Validation:** [macOS CI](https://github.com/ish4ra/Arkiv/actions/workflows/macos.yml) runs engine/security fixtures, Swift/AppKit tests, branding checks, arm64 and Universal app verification, and mounted DMG verification. Interactive Finder discovery, UI/accessibility, and Gatekeeper behavior still require a real Mac; this is not a production release.

Fixture-verified formats include ZIP Store/Deflate, TAR, 7z/LZMA2 and stored RAR5. Creation supports ZIP and 7z, including 7z AES-256 content and optional filename encryption. This is not blanket codec/multipart support. ZIP root additions are available for supported writable archives; other modification, preview/open, Quick Look, drag/drop and advanced tools remain deferred.

## Download for Mac testing

Open the [macOS foundation Actions page](https://github.com/ish4ra/Arkiv/actions/workflows/macos.yml?query=branch%3Amain), sign in, and choose a successful `main` run with DMG artifacts. Download **`Arkiv-arm64-development-dmg`** for Apple Silicon or **`Arkiv-universal-development-dmg`** for Intel/Apple Silicon. Unzip GitHub's artifact wrapper, open the enclosed **`Arkiv-…-development.dmg`**, and drag **Arkiv.app** to the **Applications** shortcut. Eject the **Arkiv** volume and launch the installed app from Applications.

These are **development builds**: the app is **ad-hoc signed**, the DMG is **unsigned**, and **neither is notarized**. Gatekeeper may block first launch with an Apple-could-not-verify/unidentified-developer warning. If you trust this build, attempt launch, then use **System Settings → Privacy & Security → Open Anyway** for Arkiv. See [exact artifact names, checksums, installation and Gatekeeper details](docs/release.md). Signed development updates are also published as prereleases through Sparkle.

## Develop on macOS

```sh
python3 scripts/build-sevenzip.py
swift test -Xlinker -L"$PWD/.build/sevenzip" -Xlinker -rpath -Xlinker "$PWD/.build/sevenzip"
scripts/test-engine.sh
scripts/build-app.sh
scripts/build-dmg.sh
open build/Arkiv-arm64-development.dmg
```

Xcode command-line tools with Swift 5.9+; macOS 13+. App bundle defaults to arm64. Python 3 is needed only for developer fixture tests. No runtime Homebrew dependencies. See [release/build details](docs/release.md).

The repository is already isolated in Codex cloud tasks; reuse its checkout and do not create a worktree unless requested. Linux can test ArkivCore/CArkiv with Swift plus the system libarchive library, but cannot validate AppKit or produce Arkiv.app.

- [Architecture](docs/architecture.md)
- [Format evidence and backend research](docs/archive-formats.md)
- [Feature matrix](docs/feature-matrix.md)
- [Security and known limits](docs/security.md)
- [Finder integration](docs/finder-integration.md)
- [Original icon direction](docs/branding.md)
- [Third-party notices](docs/third-party-licenses.md)

Next: confirm/fix macOS CI and real-Mac browser behavior, then implement owned preview workspaces, single-entry Open/Quick Look and TAR creation with round-trip tests. ZIP/7z creation and 7z AES-256 are implemented; ZIP Add Files/Add Folder are implemented; other modification remains deferred.

## Finder extraction

Right-click one ZIP or uncompressed TAR archive → **Services** for **Open in Arkiv**, **Extract Here with Arkiv**, **Extract to Folder with Arkiv**, or **Extract To… with Arkiv**. Enable these under **System Settings → Keyboard → Keyboard Shortcuts → Services** if needed. Extraction never overwrites or merges existing items. Services support single-archive extraction; creation is available through the direct Finder menu or File → Create Archive…. See [Finder setup, limitations, and test steps](docs/finder-integration.md).

### Development self-updates

Arkiv integrates Sparkle 2 with **Arkiv → Check for Updates…** and optional
background checks. One manual installation of a build containing your configured
public key is required. Subsequent development updates use a signed Universal ZIP
and signed GitHub prerelease feed. See [updater setup and testing](docs/updates.md)
for the one-time EdDSA key/Actions secret setup. Builds remain ad-hoc signed and
not notarized; keyless builds clearly report that updates are not configured.

### Direct Finder menu

Use the first-run Finder setup, or **Arkiv → Finder Integration…**, for a direct **Arkiv** submenu when
right-clicking one ZIP, 7z or uncompressed TAR in your home folder. Actions include
Open, Extract Here, Extract to an archive-named folder, Extract To, and Test Archive. Extraction
requests execute directly after validation; Extract To retains its destination chooser.
The custom-URL trust tradeoff is documented in [Finder integration](docs/finder-sync.md).
Services remain the fallback outside this scope.
See [Finder Sync setup and real-Mac tests](docs/finder-sync.md).

Finder setup shows the manual macOS Settings path and refreshes enabled status
when you return. **Not Now** is remembered; setup remains available from the menu.

### Archive creation

ZIP is the default creation format. Select files/folders in Finder for **Add to Archive…**,
**Compress to “Name.zip”**, or **Compress with Password…**. Direct **Compress to “Name.7z”**
and 7z in the format selector remain secondary options. Password compression uses 7z AES-256.
The File menu also offers **Create Archive…**. Store/Deflate, mixed selections,
nested/empty folders, Unicode, progress and cancellation are supported with
transactional no-overwrite publication. 7z offers LZMA2, AES-256 and optional encrypted filenames; ZIP AES remains unavailable. Passwords are not saved.
See [creation behavior and real-Mac tests](docs/creation.md) and [7z backend, temporary plaintext handling and licensing](docs/sevenzip.md).

### Test Archive

Use **Test Archive** in Finder’s Arkiv submenu or the app’s Test action to read and
verify archive data without publishing extracted files. ZIP and 7z verify decoded
data and available CRCs; TAR checks headers and payload readability but reports a
warning because TAR has no payload checksum. Encrypted 7z requests a password and
supports retry. Testing is cancellable and does not play the extraction sound.
See [integrity checks, limits, and real-Mac tests](docs/integrity.md).
