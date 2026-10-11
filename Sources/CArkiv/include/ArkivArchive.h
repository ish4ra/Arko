#ifndef ARKIV_ARCHIVE_H
#define ARKIV_ARCHIVE_H
#include <stdint.h>
#include <stddef.h>

typedef struct arkiv_cancel arkiv_cancel;
arkiv_cancel *arkiv_cancel_new(void);
void arkiv_cancel_set(arkiv_cancel *token);
void arkiv_cancel_free(arkiv_cancel *token);

typedef struct {
    uint64_t max_entries;
    uint64_t max_bytes;
} arkiv_limits;
/* Callback strings are borrowed and valid only during the callback. */
typedef int (*arkiv_entry_callback)(void *, int64_t, const char *, int64_t, int);
typedef void (*arkiv_progress_callback)(void *, uint64_t, uint64_t);
/* Return 0 success, 1 error, 2 cancellation. Error buffer never contains archive data. */
int arkiv_list(const char *, arkiv_limits, arkiv_cancel *, arkiv_entry_callback, void *, char *, size_t);
/* Root must be a private, caller-owned directory. Never overwrites. IDs are sorted, unique archive ordinals;
   NULL IDs means all entries. Only regular files/directories; no links or special entries. */
int arkiv_extract(const char *, const char *, const int64_t *, size_t, arkiv_limits,
                 arkiv_cancel *, arkiv_progress_callback, void *, char *, size_t);
/* Test streams all payload into a discard sink. 0 OK, 2 cancelled, 4 password required,
   5 wrong password or encrypted damage, 6 corrupt, 7 CRC error, 8 unsupported method,
   9 warning: format has no payload checksum. 1 operational/security error. */
int arkiv_test(const char *, const char *, arkiv_limits, arkiv_cancel *, arkiv_progress_callback, void *, char *, size_t);
const char *arkiv_backend_version(void);

/* Publish validated output beside its private staging directory. Never replaces or
   merges existing items. 3 = conflict. On failure, published counts committed
   top-level items; remaining output stays in staging for recovery. */
int arkiv_publish_extracted(const char *parent, const char *staging, const char *name,
                           int here, arkiv_cancel *, size_t *published, char *, size_t);

/* Transactional ZIP creation. sources are absolute paths; stage/name are single components.
   3 means publication conflict. Compression: 0 Store, 1 Deflate. */
int arkiv_create_zip(const char *const *, size_t, const char *, const char *, const char *, char *, size_t, int,
                     arkiv_limits, arkiv_cancel *, arkiv_progress_callback, void *, char *, size_t);

int arkiv_create_archive(const char *const *, size_t, const char *, const char *, const char *, char *, size_t, int,
 arkiv_limits, arkiv_cancel *, arkiv_progress_callback, void *, char *, size_t, int, const char *, int);
const char *arkiv_seven_loaded_library(void);
int arkiv_is_seven(const char *);
int arkiv_unlock_seven(const char *, const char *, const char *, arkiv_cancel *);

/* Conservative ZIP32 mutation; transaction owns pinned source and parent descriptors. */
typedef struct arkiv_zip_transaction arkiv_zip_transaction;
arkiv_zip_transaction *arkiv_zip_begin(const char *, char *, size_t);
void arkiv_zip_end(arkiv_zip_transaction *);
int arkiv_zip_prepare(arkiv_zip_transaction *, const char *, const char *, arkiv_cancel *, arkiv_progress_callback, void *, char *, size_t);
int arkiv_zip_commit(arkiv_zip_transaction *, arkiv_cancel *, char *, size_t);

#endif
