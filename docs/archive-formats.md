# Format evidence

These are **fixture results on Linux with libarchive 3.7.4 and in [macOS CI](https://github.com/ish4ra/Arkiv/actions/runs/37608385235) with the system backend**, not blanket interoperability or release claims.

| Format | Browse/extract evidence | Create/modify | Encryption/multipart/comments/integrity command |
| --- | --- | --- | --- |
| ZIP | Stored and Deflate; nested Unicode paths, empty, corrupt CRC | Default creation: Store/Deflate; [ZIP32 root additions](zip-additions.md) | Test reads data and checks CRC; encryption/multipart/comments deferred |
| TAR | Regular file, nested paths, rejection of links/devices | Not implemented | Test checks structure/readability; warning: no payload checksum |
| 7z | LZMA/LZMA2; plain/encrypted fixtures and round trips | Create LZMA2; no modification | AES-256 content, optional filenames; full-data/CRC Test; no multipart |
| RAR5 | One stored upstream fixture, byte-for-byte extraction | Never create RAR | Not implemented |
| RAR4 | Decoder registered; no fixture validation yet | Not implemented | Not implemented |
| All other spec formats | Deferred, not advertised | Not implemented | Not implemented |

An accepted file extension does not prove a compression method is available. 7z encrypted extraction is supported through the bundled backend; encrypted ZIP remains rejected. ZIPX, compressed TAR filters, solid/multipart RAR and advanced 7z compatibility require dedicated fixtures before support claims. The app initially registers only ZIP/TAR document associations.

## Creation policy

ZIP is the primary/default creation format for normal macOS use. Store/Deflate
remain available. 7z is a secondary choice for LZMA2 compression or AES-256 with
optional filename encryption, and remains available in Finder and Create Archive.
Compress with Password uses 7z because ZIP AES has not passed interoperability
validation; Arkiv never silently falls back to ZipCrypto.

Read support does not imply write support. Only legally redistributable,
fixture-verified writers are exposed. RAR/RAR5 are read/browse/extract only within
the evidence above: Arkiv will not implement or depend on restricted RAR encoding.
No broad RAR codec or multipart claim is made.

## Backend research (2026-10-07)

- [libarchive](https://github.com/libarchive/libarchive): in-process streaming reader/writer with broad format support and permissive licensing. The inspected upstream master header declares 3.9.0 (development, not asserted to be the latest stable release); local runtime is 3.7.4. macOS ships its own version, recorded in Archive Info. Apple/system security updates therefore matter. Native backend integration avoids shipping a Homebrew dependency, but its codec/version variability limits compatibility guarantees.
- [7-Zip](https://github.com/ip7z/7zip): inspected upstream README identifies 26.04. Most code is LGPL 2.1-or-later, some BSD/public-domain, RAR code additionally has the unRAR restriction. A pinned RAR-free subset is now bundled for 7z/LZMA2 and AES/header encryption; source, patches, license and rebuild/replace instructions are in [sevenzip.md](sevenzip.md).
- LZMA SDK is narrower than a complete archive-manager backend; do not confuse its public-domain portions with the entire 7-Zip license. The full selected 7-Zip component retains LGPL obligations.
- UnRAR has a license restriction against using its sources to recreate the RAR compression algorithm. No UnRAR code or binary is bundled. RAR creation is a non-goal. Broader RAR support will require a specific version/license review.
- Apple's Compression framework provides codecs rather than a complete ZIP/7z/RAR archive manager; Apple Archive is not a replacement for the requested formats. Native APIs remain appropriate for UI, file access, security and future metadata work.

The 7-zip.org license endpoint was denied by this environment; research used the official ip7z GitHub source. This research is a foundation decision, not certification of every future backend or codec.

ZIP creation details and validation: [creation.md](creation.md).
