# Milestone status

| Capability | State |
| --- | --- |
| Native archive browser | Implemented: AppKit table, resize/sort columns, multi-selection, search, folder/back/forward/up navigation, multiple windows |
| Selective/all extraction | Implemented: new destination folder, bounded streaming, cancellation, progress and cleanup |
| Extraction safety | Automated hostile-path/link/overwrite/CRC/limit regression suite |
| macOS application validation | Native compilation, tests, arm64 app/icon packaging and signature verification passed macOS CI; interactive validation outstanding |
| Create ZIP | Store/Deflate, native creation setup, direct Finder multi-selection compression; [details](creation.md) |
| Create/read 7z / AES-256 / filename encryption | LZMA2, content/header encryption, native password prompt/retry; [backend and limits](sevenzip.md) |
| Add to existing ZIP | Add Files/Add Folder at root; verified atomic rewrite of supported ZIP32; [limits](zip-additions.md) |
| Other modification / ZIP AES | Deferred; no enabled UI claims |
| Solid archives / multipart / comments | Deferred compatibility work |
| Integrity test command | ZIP/7z full-data/CRC checks; TAR structure/readability with explicit checksum warning; native progress/cancellation/password retry |
| Checksums / split-combine / benchmark / CLI | Deferred |
| Finder extraction | AppKit Services for one ZIP/uncompressed TAR: open, here, archive folder, destination chooser; real-Finder registration/invocation checks pending |
| Drag in-out | Deferred |
| ZIP/TAR associations | Viewer/alternate registration implemented; real-Mac validation pending |
| Open internal file / Quick Look / nested archives | Deferred to next Priority A increment |
| Icon / document icons | Original procedural app icon generated and packaged in macOS CI, visual validation pending; document family deferred |
| Recents / Settings / advanced columns / metadata preservation | Deferred |

See `archive-formats.md` for the narrower per-format evidence. This is an early development foundation, not a production-ready archive manager or completion of Priority A.
