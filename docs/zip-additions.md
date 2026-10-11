# Add files to an existing ZIP

Open a writable ZIP, then choose **File → Add Files…** (multiple files) or
**Add Folder…** (one folder). The same actions appear in the archive table's
context menu. Items are added at the archive root, including nested contents,
empty directories and Unicode names. The picker explains this destination.

This foundation supports ordinary single-disk ZIP32 archives using Store/Deflate.
Encrypted ZIP, ZIP64, unusual layouts or opaque extra fields are read-only for
addition. Known timestamp/ownership fields and NTFS extras are preserved. A file
extension alone never grants modification support. 7z, RAR and TAR remain
read-only for modification. Delete, rename and replacing existing entries are
not implemented.

A root name that already exists (including an implicit directory), or duplicate
names among selected sources, produces a native error. Comparison is Unicode
normalized and case insensitive. Rename the source outside Arkiv and try again;
Arkiv never silently replaces or merges an existing entry.

## Transaction and safety

`ArchiveZIPUpdater` pins the original file and parent directory, creates additions
with the existing ZIP creation engine, and assembles a complete replacement in a
private sibling directory. Original compressed records, entry metadata/comments
and the archive comment are copied unchanged. The complete replacement is tested
by reading/decompressing its data and validating CRC/structure within existing
entry/size limits. The original is not edited in place.

Immediately before commit, Arkiv rechecks original identity/timestamps/size,
parent identity, and the verified replacement. macOS file coordination surrounds
the atomic same-filesystem rename. Cancellation and any error before that commit
leave the original untouched; ordinary success/error/cancellation cleanup removes
the private directory. Cancellation after the atomic commit cannot undo success.
Permissions and macOS file metadata are copied to the replacement.

Existing source validation, symlink/special-file rejection and extraction safety
limits remain in force. The archive itself (or a source containing its staging
area) cannot be added. Sufficient disk space is needed for the additions and a
complete replacement. Another application's uncoordinated write cannot be fully
locked out by file coordination; avoid editing the archive simultaneously in
another tool. Abrupt process/system termination can leave private staging data;
this is not a crash-recovery or secure-erasure facility.

Progress and Cancel use the existing window controls. Successful commit refreshes
the browser and plays the existing completion sound once. Failure/cancellation
plays no completion sound. A later browser refresh failure is reported separately
from the already-completed transaction.

## Real-Mac checks

1. Create a ZIP with known files. Open it and use Add Files to add two new files,
   including a name with spaces/emoji. Confirm refreshed contents and one sound.
2. Add a folder containing nested files and an empty folder. Extract all and
   compare original and added file bytes; confirm the empty folder exists.
3. Try adding an existing root name (also test different case). Confirm a clear
   conflict error and unchanged archive.
4. Start a large addition and cancel before completion. Confirm the original
   archive still tests/extracts identically and no `.arkiv-add-*` directory remains.
5. Open 7z/TAR or a non-writable ZIP: Add actions must be disabled. Existing
   browsing, extraction, Test Archive and creation should continue to work.
