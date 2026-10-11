#include "ArkivArchive.h"
#include "../CArkivSeven/include/ArkivSeven.h"
#include "vendor/archive.h"
#include "vendor/archive_entry.h"
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

struct arkiv_cancel { atomic_int value; };
arkiv_cancel *arkiv_cancel_new(void) {
    arkiv_cancel *p = malloc(sizeof(*p));
    if (p) atomic_init(&p->value, 0);
    return p;
}
void arkiv_cancel_set(arkiv_cancel *p) { if (p) atomic_store(&p->value, 1); }
void arkiv_cancel_free(arkiv_cancel *p) { free(p); }
static int cancelled(arkiv_cancel *p) { return p && atomic_load(&p->value); }
const char *arkiv_backend_version(void) { return archive_version_string(); }
static int fail(char *error, size_t capacity, const char *message) {
    if (error && capacity) snprintf(error, capacity, "%s", message);
    return 1;
}

/* Deliberately register only in-process filters and the initial candidate formats.
   Never enable libarchive's external-program filter fallback. */
static struct archive *reader(const char *path) {
    struct archive *a = archive_read_new();
    if (!a) return NULL;
    archive_read_support_filter_none(a);
    archive_read_support_format_zip(a);
    archive_read_support_format_tar(a);
    archive_read_support_format_7zip(a);
    archive_read_support_format_rar(a);
    archive_read_support_format_rar5(a);
    if (archive_read_open_filename(a, path, 65536) != ARCHIVE_OK) {
        archive_read_free(a); return NULL;
    }
    return a;
}

/* Strict relative paths. Backslashes/colons also reject foreign absolute/device paths.
   No ambiguous normalization: reject dot components and empty interior components. */
static int safe_path(const char *path) {
    if (!path || !*path || *path == '/' || strlen(path) > 4096) return 0;
    const char *part = path;
    for (const char *p = path;; p++) {
        if (*p == '\\' || *p == ':' || ((unsigned char)*p < 32 && *p)) return 0;
        if (*p == '/' || !*p) {
            size_t n = (size_t)(p - part);
            if (!n || (n == 1 && part[0] == '.') ||
                (n == 2 && part[0] == '.' && part[1] == '.')) return 0;
            if (!*p || !p[1]) return 1;
            part = p + 1;
        }
    }
}
static int entry_kind(struct archive_entry *e) {
    if (archive_entry_symlink(e) || archive_entry_hardlink(e)) return 0;
    if (archive_entry_filetype(e) == AE_IFREG) return 1;
    if (archive_entry_filetype(e) == AE_IFDIR) return 2;
    return 0;
}
int arkiv_list(const char *path, arkiv_limits limits, arkiv_cancel *token,
              arkiv_entry_callback callback, void *context, char *error, size_t capacity) {
    if (cancelled(token)) return 2;
    struct archive *a = reader(path);
    if (!a) return fail(error, capacity, "Cannot read archive: unsupported, encrypted, corrupt, or inaccessible.");
    struct archive_entry *e;
    int status, result = 0;
    uint64_t count = 0;
    while ((status = archive_read_next_header(a, &e)) == ARCHIVE_OK) {
        if (cancelled(token)) { result = 2; break; }
        if (count >= limits.max_entries) { result = fail(error, capacity, "Archive entry limit exceeded."); break; }
        const char *name = archive_entry_pathname_utf8(e);
        if (!name || !safe_path(name)) { result = fail(error, capacity, "Unsafe or invalid archive path."); break; }
        if (callback && callback(context, (int64_t)count, name, archive_entry_size(e), entry_kind(e))) {
            result = fail(error, capacity, "Archive listing was rejected."); break;
        }
        count++;
        if (archive_read_data_skip(a) != ARCHIVE_OK) { result = fail(error, capacity, "Cannot skip damaged archive entry."); break; }
    }
    if (!result && cancelled(token)) result = 2;
    if (!result && status != ARCHIVE_EOF) result = fail(error, capacity, "Archive header is damaged or unsupported.");
    archive_read_free(a);
    return result;
}

/* Walk from an already-open root, refusing symlinks at EVERY component.
   The caller owns a private root; archive metadata can never create a link. */
static int open_output(int root, const char *name, int directory) {
    char *copy = strdup(name);
    if (!copy) return -1;
    size_t length = strlen(copy);
    if (length && copy[length - 1] == '/') copy[length - 1] = 0;
    int parent = dup(root), result = -1;
    if (parent < 0) { free(copy); return -1; }
    char *part = copy;
    for (;;) {
        char *slash = strchr(part, '/');
        if (slash) *slash = 0;
        if (slash || directory) {
            if (mkdirat(parent, part, 0700) != 0 && errno != EEXIST) break;
            int next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (next < 0) break;
            close(parent); parent = next;
            if (!slash) { result = parent; parent = -1; break; }
            part = slash + 1;
        } else {
            result = openat(parent, part, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            break;
        }
    }
    if (parent >= 0) close(parent);
    free(copy);
    return result;
}
static int selected(int64_t id, const int64_t *ids, size_t count) {
    if (!ids) return 1;
    size_t low = 0, high = count;
    while (low < high) {
        size_t mid = low + (high - low) / 2;
        if (ids[mid] == id) return 1;
        if (ids[mid] < id) low = mid + 1; else high = mid;
    }
    return 0;
}
int arkiv_extract(const char *path, const char *root_path, const int64_t *ids, size_t selected_count,
                 arkiv_limits limits, arkiv_cancel *token, arkiv_progress_callback progress,
                 void *context, char *error, size_t capacity) {
    if (cancelled(token)) return 2;
    for (size_t i = 0; i < selected_count; i++) {
        if (ids[i] < 0) return fail(error, capacity, "Invalid selection.");
        if (i && ids[i] <= ids[i - 1]) return fail(error, capacity, "Selection must be sorted and unique.");
    }
    int root = open(root_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0) return fail(error, capacity, "Output directory is unavailable or unsafe.");
    struct archive *a = reader(path);
    if (!a) { close(root); return fail(error, capacity, "Cannot read archive: unsupported, encrypted, corrupt, or inaccessible."); }
    struct archive_entry *e;
    int status, result = 0;
    uint64_t count = 0, total = 0, files = 0, found = 0;
    char buffer[65536];
    while ((status = archive_read_next_header(a, &e)) == ARCHIVE_OK) {
        if (cancelled(token)) { result = 2; break; }
        if (count >= limits.max_entries) { result = fail(error, capacity, "Archive entry limit exceeded."); break; }
        int wanted = selected((int64_t)count++, ids, selected_count);
        if (!wanted) {
            if (archive_read_data_skip(a) != ARCHIVE_OK) { result = fail(error, capacity, "Damaged archive data."); break; }
            continue;
        }
        found++;
        const char *name = archive_entry_pathname_utf8(e);
        int kind = entry_kind(e);
        if (!safe_path(name) || !kind) { result = fail(error, capacity, "Unsafe archive path, link, or special file."); break; }
        if (archive_entry_is_encrypted(e) > 0) { result = fail(error, capacity, "Encrypted extraction is not available yet."); break; }
        int64_t size = archive_entry_size(e);
        if (size < 0 || (uint64_t)size > limits.max_bytes - total) { result = fail(error, capacity, "Expanded size limit exceeded."); break; }
        int output = open_output(root, name, kind == 2);
        if (output < 0) { result = fail(error, capacity, "Output conflict, unsafe directory, or permission denied."); break; }
        if (kind == 1) {
            for (;;) {
                if (cancelled(token)) { result = 2; break; }
                la_ssize_t n = archive_read_data(a, buffer, sizeof(buffer));
                if (n < 0) { result = fail(error, capacity, "Archive data is corrupt, encrypted, or unsupported (including CRC failure)."); break; }
                if (!n) break;
                if ((uint64_t)n > limits.max_bytes - total) { result = fail(error, capacity, "Expanded size limit exceeded."); break; }
                size_t offset = 0;
                while (offset < (size_t)n) {
                    ssize_t written = write(output, buffer + offset, (size_t)n - offset);
                    if (written < 0 && errno == EINTR) continue;
                    if (written <= 0) { result = fail(error, capacity, "Cannot write output; check disk space and permissions."); break; }
                    offset += (size_t)written;
                }
                if (result) break;
                total += (uint64_t)n;
                if (progress) progress(context, files, total);
            }
        }
        if (close(output) != 0 && !result) result = fail(error, capacity, "Cannot finish writing output.");
        if (result) break;
        files++;
        if (progress) progress(context, files, total);
    }
    if (!result && cancelled(token)) result = 2;
    if (!result && status != ARCHIVE_EOF) result = fail(error, capacity, "Archive is truncated, damaged, or unsupported.");
    if (!result && ids && found != selected_count) result = fail(error, capacity, "Selected entries no longer exist in the archive.");
    archive_read_free(a);
    close(root);
    return result;
}

#include <dirent.h>
#include <locale.h>
#ifdef __APPLE__
#include <xlocale.h>
#endif
#ifdef __linux__
#include <sys/syscall.h>
#endif

/* Both platforms provide an atomic no-replace rename. Never substitute rename(),
   which could overwrite a file created after the conflict preflight. */
static int move_exclusive(int from, const char *source, int to, const char *destination) {
#ifdef __APPLE__
    return renameatx_np(from, source, to, destination, RENAME_EXCL);
#elif defined(__linux__) && defined(SYS_renameat2)
    return (int)syscall(SYS_renameat2, from, source, to, destination, 1 /* RENAME_NOREPLACE */);
#else
    errno = ENOTSUP;
    return -1;
#endif
}
static int component(const char *name) {
    return safe_path(name) && !strchr(name, '/');
}
int arkiv_publish_extracted(const char *parent_path, const char *staging, const char *name,
                           int here, arkiv_cancel *token, size_t *published, char *error, size_t capacity) {
    *published = 0;
    if (!component(staging) || !component(name) || !strcmp(staging, name))
        return fail(error, capacity, "Invalid output folder name.");
    if (cancelled(token)) return 2;
    int parent = open(parent_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (parent < 0) return fail(error, capacity, "Destination directory is unavailable or unsafe.");
    int source = openat(parent, staging, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (source < 0) { close(parent); return fail(error, capacity, "Extracted output is unavailable or unsafe."); }
    int result = 0;
    if (!here) {
        if (cancelled(token)) result = 2;
        else if (move_exclusive(parent, staging, parent, name) != 0) {
            result = errno == EEXIST ? 3 : 1;
            fail(error, capacity, "Cannot place the archive folder; check conflicts and permissions.");
        }
        close(source); close(parent); return result;
    }
    DIR *directory = fdopendir(source);
    if (!directory) { close(source); close(parent); return fail(error, capacity, "Cannot read extracted output."); }
    struct dirent *entry;
    /* A conflict known before publication leaves the destination completely untouched.
       Directories also conflict: never merge existing trees. Include hidden entries. */
    errno = 0;
    while ((entry = readdir(directory))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        if (cancelled(token)) { result = 2; break; }
        struct stat existing;
        if (!component(entry->d_name) || fstatat(parent, entry->d_name, &existing, AT_SYMLINK_NOFOLLOW) == 0) {
            result = 3; fail(error, capacity, "An output name already exists; folders are not merged."); break;
        }
        if (errno != ENOENT) { result = fail(error, capacity, "Cannot check destination conflicts."); break; }
        errno = 0;
    }
    if (!result && errno) result = fail(error, capacity, "Cannot enumerate extracted output.");
    if (!result) {
        rewinddir(directory);
        errno = 0;
        while ((entry = readdir(directory))) {
            if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
            if (cancelled(token)) { result = 2; break; }
            if (move_exclusive(source, entry->d_name, parent, entry->d_name) != 0) {
                result = fail(error, capacity, "Placement stopped because of a conflict or filesystem error."); break;
            }
            (*published)++;
            errno = 0;
        }
        if (!result && errno) result = fail(error, capacity, "Cannot enumerate extracted output.");
    }
    closedir(directory);
    if (!result && unlinkat(parent, staging, AT_REMOVEDIR) != 0)
        result = fail(error, capacity, "Files were placed, but the empty staging folder could not be removed.");
    close(parent);
    return result;
}

#include <dirent.h>
#include <locale.h>
#ifdef __APPLE__
#include <xlocale.h>
#endif
/* Walk every ancestor without following links, including the final component. */
static int create_open(const char *path) {
    if (!path || path[0] != '/') { errno = EINVAL; return -1; }
    char *copy = strdup(path); if (!copy) return -1;
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    char *save = NULL;
    for (char *p = strtok_r(copy, "/", &save); p && fd >= 0; p = strtok_r(NULL, "/", &save)) {
        if (!strcmp(p, ".") || !strcmp(p, "..")) { close(fd); fd = -1; errno = EINVAL; break; }
        int next = openat(fd, p, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        close(fd); fd = next;
    }
    free(copy); return fd;
}
static int create_same_stat(const struct stat *a, const struct stat *b) {
#ifdef __APPLE__
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_size == b->st_size &&
        a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec == b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec;
#else
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_size == b->st_size &&
        a->st_mtim.tv_sec == b->st_mtim.tv_sec && a->st_mtim.tv_nsec == b->st_mtim.tv_nsec &&
        a->st_ctim.tv_sec == b->st_ctim.tv_sec && a->st_ctim.tv_nsec == b->st_ctim.tv_nsec;
#endif
}
struct create_state {
    struct archive *writer; arkiv_limits limits; arkiv_cancel *token;
    arkiv_progress_callback progress; void *context;
    uint64_t entries, bytes; char *error; size_t capacity;
    dev_t stage_dev; ino_t stage_ino;
};
static int create_walk(struct create_state *s, int fd, const char *path, unsigned depth) {
    if (cancelled(s->token)) return 2;
    struct stat st;
    if (depth > 128 || !safe_path(path) || fstat(fd, &st) ||
        (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)) ||
        (st.st_dev == s->stage_dev && st.st_ino == s->stage_ino))
        return fail(s->error, s->capacity, "Source contains a link, special file, or unsafe path.");
    if (++s->entries > s->limits.max_entries || st.st_size < 0 ||
        (S_ISREG(st.st_mode) && (uint64_t)st.st_size > s->limits.max_bytes - s->bytes))
        return fail(s->error, s->capacity, "Creation safety limit exceeded.");
    struct archive_entry *entry = archive_entry_new();
    if (!entry) return fail(s->error, s->capacity, "Cannot allocate ZIP entry.");
    archive_entry_set_pathname_utf8(entry, path);
    archive_entry_set_filetype(entry, S_ISDIR(st.st_mode) ? AE_IFDIR : AE_IFREG);
    archive_entry_set_perm(entry, S_ISDIR(st.st_mode) ? 0755 : 0644);
    archive_entry_set_mtime(entry, st.st_mtime, 0);
    archive_entry_set_size(entry, S_ISDIR(st.st_mode) ? 0 : st.st_size);
    int result = archive_write_header(s->writer, entry); archive_entry_free(entry);
    if (result != ARCHIVE_OK) return fail(s->error, s->capacity, "Cannot write ZIP header.");
    if (S_ISDIR(st.st_mode)) {
        DIR *dir = fdopendir(dup(fd));
        if (!dir) return fail(s->error, s->capacity, "Cannot enumerate source folder.");
        struct dirent *item; int status = 0;
        for (;;) {
            errno = 0; item = readdir(dir);
            if (!item) { if (errno) status = fail(s->error, s->capacity, "Cannot read source folder."); break; }
            if (!strcmp(item->d_name, ".") || !strcmp(item->d_name, "..")) continue;
            char child[4097];
            if (snprintf(child, sizeof(child), "%s/%s", path, item->d_name) >= (int)sizeof(child)) {
                status = fail(s->error, s->capacity, "Source path is too long."); break;
            }
            int childfd = openat(fd, item->d_name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
            if (childfd < 0) { status = fail(s->error, s->capacity, "Cannot safely open source item."); break; }
            status = create_walk(s, childfd, child, depth + 1); close(childfd);
            if (status) break;
        }
        closedir(dir); if (status) return status;
    } else {
        char buffer[65536]; uint64_t count = 0;
        while (count < (uint64_t)st.st_size) {
            if (cancelled(s->token)) return 2;
            size_t wanted = (uint64_t)st.st_size - count < sizeof(buffer) ? (size_t)((uint64_t)st.st_size - count) : sizeof(buffer);
            ssize_t n = read(fd, buffer, wanted);
            if (n <= 0 || archive_write_data(s->writer, buffer, (size_t)n) != n)
                return fail(s->error, s->capacity, "Source changed or ZIP write failed.");
            count += (uint64_t)n; s->bytes += (uint64_t)n;
            if (s->progress) s->progress(s->context, s->entries, s->bytes);
        }
        struct stat after;
        if (fstat(fd, &after) || !create_same_stat(&after, &st))
            return fail(s->error, s->capacity, "Source changed during creation.");
    }
    struct stat final_stat;
    if (fstat(fd, &final_stat) || !create_same_stat(&final_stat, &st))
        return fail(s->error, s->capacity, "Source changed during creation.");
    if (archive_write_finish_entry(s->writer) != ARCHIVE_OK) return fail(s->error, s->capacity, "Cannot finish ZIP entry.");
    if (s->progress) s->progress(s->context, s->entries, s->bytes);
    return 0;
}
static int seven_cancel(void *token) { return cancelled(token); }
static int create_archive(const char *const *sources, size_t count, const char *parent,
                     const char *stage, const char *name, char *published_name, size_t published_capacity, int compression, arkiv_limits limits,
                     arkiv_cancel *token, arkiv_progress_callback progress, void *context,
                     char *error, size_t capacity, int seven, const char *password, int headers) {
    if (cancelled(token)) return 2;
    size_t extension = seven ? 3 : 4;
    const char *suffix = seven ? ".7z" : ".zip";
    const char *payload = seven ? "archive.7z" : "archive.zip";
    if (!published_name || published_capacity < 256 || !count || count > limits.max_entries || !safe_path(stage) || strchr(stage, '/') || !safe_path(name) || strchr(name, '/') || strlen(name) <= extension || strcmp(name + strlen(name) - extension, suffix))
        return fail(error, capacity, "Invalid creation request.");
    locale_t utf8 = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", NULL);
    if (!utf8) utf8 = newlocale(LC_CTYPE_MASK, "C.UTF-8", NULL);
    if (!utf8) return fail(error, capacity, "UTF-8 filename support is unavailable.");
    locale_t previous = uselocale(utf8);
    int parentfd = create_open(parent), stagefd = -1, output = -1, sevenfd = -1, checkfd = -1, status = 1;
    struct archive *writer = NULL, *verify = NULL;
    if (parentfd < 0) goto done;
    stagefd = openat(parentfd, stage, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (stagefd < 0) goto done;
    output = openat(stagefd, "archive.zip", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (output < 0) goto done;
    writer = archive_write_new();
    if (!writer || archive_write_set_format_zip(writer) != ARCHIVE_OK ||
        archive_write_set_format_option(writer, "zip", "compression", compression ? "deflate" : "store") != ARCHIVE_OK ||
        archive_write_set_format_option(writer, "zip", "hdrcharset", "UTF-8") != ARCHIVE_OK ||
        archive_write_open_fd(writer, output) != ARCHIVE_OK) goto done;
    struct stat stage_stat;
    if (fstat(stagefd, &stage_stat)) goto done;
    struct create_state state = { writer, limits, token, progress, context, 0, 0, error, capacity, stage_stat.st_dev, stage_stat.st_ino };
    for (size_t i = 0; i < count; i++) {
        /* Each new root begins in failure state until it is fully written. */
        status = 1;
        int fd = create_open(sources[i]);
        if (fd < 0) goto done;
        const char *base = strrchr(sources[i], '/');
        status = create_walk(&state, fd, base ? base + 1 : sources[i], 0); close(fd);
        if (status) goto done;
    }
    status = 1;
    if (archive_write_close(writer) != ARCHIVE_OK || fsync(output) || lseek(output, 0, SEEK_SET) < 0) goto done;
    archive_write_free(writer); writer = NULL;
    verify = archive_read_new();
    if (!verify || archive_read_support_filter_none(verify) != ARCHIVE_OK ||
        archive_read_support_format_zip(verify) != ARCHIVE_OK || archive_read_open_fd(verify, output, 65536) != ARCHIVE_OK) goto done;
    struct archive_entry *entry; int r; uint64_t entries = 0, bytes = 0; char buffer[65536];
    while ((r = archive_read_next_header(verify, &entry)) == ARCHIVE_OK) {
        if (++entries > limits.max_entries || !entry_kind(entry)) goto done;
        ssize_t n;
        while ((n = archive_read_data(verify, buffer, sizeof(buffer))) > 0) {
            if (cancelled(token)) { status = 2; goto done; }
            if ((uint64_t)n > limits.max_bytes - bytes) goto done;
            bytes += (uint64_t)n;
        }
        if (n < 0) goto done;
    }
    if (r != ARCHIVE_EOF || entries != state.entries || bytes != state.bytes) goto done;
    if (cancelled(token)) { status = 2; goto done; }
    if (seven) {
        archive_read_free(verify); verify = NULL;
        if (lseek(output, 0, SEEK_SET) < 0) goto done;
        sevenfd = openat(stagefd, "archive.7z", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        checkfd = openat(stagefd, "verify.zip", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (sevenfd < 0 || checkfd < 0) goto done;
        status = arkiv_seven_encode(output, sevenfd, password, headers, seven_cancel, token, progress, context);
        if (status) goto done;
        status = 1;
        if (fsync(sevenfd)) goto done;
        status = arkiv_seven_decode(sevenfd, checkfd, password, seven_cancel, token);
        if (status) goto done;
    }
    /* A same-filesystem hard link publishes atomically without replacing any item. */
    status = 3;
    for (unsigned attempt = 1; attempt <= 1000; attempt++) {
        if (cancelled(token)) { status = 2; goto done; }
        int length = attempt == 1 ? snprintf(published_name, published_capacity, "%s", name) :
            snprintf(published_name, published_capacity, "%.*s (%u)%s", (int)(strlen(name) - extension), name, attempt, suffix);
        if (length < 0 || (size_t)length >= published_capacity) { status = 1; goto done; }
        if (!linkat(stagefd, payload, parentfd, published_name, 0)) { status = 0; break; }
        if (errno != EEXIST) { status = 1; goto done; }
    }
done:
    if (verify) archive_read_free(verify);
    if (writer) archive_write_free(writer);
    if (sevenfd >= 0) close(sevenfd);
    if (checkfd >= 0) close(checkfd);
    if (output >= 0) close(output);
    if (stagefd >= 0) { unlinkat(stagefd, "archive.zip", 0); unlinkat(stagefd, "archive.7z", 0); unlinkat(stagefd, "verify.zip", 0); close(stagefd); }
    if (parentfd >= 0) close(parentfd);
    uselocale(previous); freelocale(utf8);
    if (status == 1 && error && capacity && !error[0]) fail(error, capacity, "Cannot safely create or verify archive.");
    return status;
}

int arkiv_create_archive(const char *const *sources, size_t count, const char *parent, const char *stage,
 const char *name, char *published, size_t published_capacity, int compression, arkiv_limits limits,
 arkiv_cancel *token, arkiv_progress_callback progress, void *context, char *error, size_t capacity,
 int seven, const char *password, int headers) {
 return create_archive(sources,count,parent,stage,name,published,published_capacity,compression,limits,token,progress,context,error,capacity,seven,password,headers);
}
int arkiv_create_zip(const char *const *sources, size_t count, const char *parent, const char *stage,
 const char *name, char *published, size_t published_capacity, int compression, arkiv_limits limits,
 arkiv_cancel *token, arkiv_progress_callback progress, void *context, char *error, size_t capacity) {
 return create_archive(sources,count,parent,stage,name,published,published_capacity,compression,limits,token,progress,context,error,capacity,0,NULL,0);
}
int arkiv_is_seven(const char *path) {
 int fd=create_open(path); if(fd<0)return 0;unsigned char b[6];ssize_t n=read(fd,b,6);close(fd);
 return n==6&&!memcmp(b,"7z\xbc\xaf\x27\x1c",6);
}
int arkiv_unlock_seven(const char *path, const char *output, const char *password, arkiv_cancel *token) {
 if(cancelled(token))return 2;
 int in=create_open(path);if(in<0)return 1;
 int out=open(output,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(out<0){close(in);return 1;}
 locale_t utf8=newlocale(LC_CTYPE_MASK,"en_US.UTF-8",NULL);
 if(!utf8)utf8=newlocale(LC_CTYPE_MASK,"C.UTF-8",NULL);
 int result=1;
 if(utf8){locale_t previous=uselocale(utf8);result=arkiv_seven_decode(in,out,password,seven_cancel,token);uselocale(previous);freelocale(utf8);}
 close(in);close(out);if(result)unlink(output);return result;
}

const char *arkiv_seven_loaded_library(void) { return arkiv_seven_library_path(); }

/* libarchive's seekable reader may recover a damaged central directory as empty.
   Check the directory envelope/count before letting the backend decode entries.
   This is not a codec/parser replacement; all payload/CRC work stays in libarchive. */
static uint16_t integrity_u16(const unsigned char *p) { return (uint16_t)(p[0] | ((uint16_t)p[1] << 8)); }
static uint32_t integrity_u32(const unsigned char *p) { return (uint32_t)integrity_u16(p) | ((uint32_t)integrity_u16(p+2) << 16); }
static uint64_t integrity_u64(const unsigned char *p) { return (uint64_t)integrity_u32(p) | ((uint64_t)integrity_u32(p+4) << 32); }
static int integrity_zip_directory(int fd, uint64_t size, arkiv_limits limits, arkiv_cancel *token,
                                   uint64_t *entries, char *error, size_t capacity) {
    unsigned char tail[65557];
    size_t length = size < sizeof(tail) ? (size_t)size : sizeof(tail);
    if (length < 22 || pread(fd, tail, length, (off_t)(size-length)) != (ssize_t)length) return 6;
    size_t position = length-22;
    for (;;) {
        if (!memcmp(tail+position, "PK\x05\x06", 4) && integrity_u16(tail+position+20) == length-position-22) break;
        if (!position) return 6;
        position--;
    }
    const unsigned char *end = tail+position;
    uint64_t end_offset = size-length+position;
    uint64_t count = integrity_u16(end+10), directory_size = integrity_u32(end+12), offset = integrity_u32(end+16);
    if (integrity_u16(end+4) || integrity_u16(end+6) || integrity_u16(end+8) != count) {
        fail(error, capacity, "Multipart ZIP testing is unsupported."); return 8;
    }
    if (count == 0xffff || directory_size == UINT32_MAX || offset == UINT32_MAX) {
        unsigned char locator[20], record[56];
        if (end_offset < 20 || pread(fd, locator, 20, (off_t)(end_offset-20)) != 20 || memcmp(locator,"PK\x06\x07",4)) return 6;
        uint64_t zip64 = integrity_u64(locator+8);
        if (integrity_u32(locator+4) || integrity_u32(locator+16) != 1) return 8;
        if (zip64 > end_offset-20 || end_offset-20-zip64 < 56 ||
            pread(fd,record,56,(off_t)zip64) != 56 || memcmp(record,"PK\x06\x06",4) ||
            integrity_u64(record+4) < 44 || integrity_u64(record+4) != end_offset-20-zip64-12) return 6;
        if (integrity_u32(record+16) || integrity_u32(record+20) || integrity_u64(record+24) != integrity_u64(record+32)) return 8;
        count = integrity_u64(record+32); directory_size = integrity_u64(record+40); offset = integrity_u64(record+48);
        end_offset = zip64;
    }
    if (count > limits.max_entries) return fail(error,capacity,"Archive entry limit exceeded.");
    if (offset > end_offset || directory_size != end_offset-offset || (!count && offset)) return 6;
    uint64_t cursor = offset;
    for (uint64_t i=0; i<count; i++) {
        if (cancelled(token)) return 2;
        unsigned char header[46];
        if (end_offset-cursor < sizeof(header) || pread(fd,header,sizeof(header),(off_t)cursor) != sizeof(header) || memcmp(header,"PK\x01\x02",4)) return 6;
        uint64_t length = 46u + integrity_u16(header+28) + integrity_u16(header+30) + integrity_u16(header+32);
        if (length > end_offset-cursor) return 6;
        cursor += length;
    }
    if (cursor != end_offset) return 6;
    *entries = count;
    return 0;
}

static int integrity_error(struct archive *a, char *error, size_t capacity) {
    const char *detail = archive_error_string(a);
    if (detail && (strstr(detail, "CRC") || strstr(detail, "crc"))) {
        fail(error, capacity, "Archive payload CRC does not match."); return 7;
    }
    if (detail && (strstr(detail, "Unsupported compression") || strstr(detail, "unsupported compression"))) {
        fail(error, capacity, "Archive compression method is unsupported."); return 8;
    }
    fail(error, capacity, "Archive structure or payload is damaged."); return 6;
}
int arkiv_test(const char *path, const char *password, arkiv_limits limits, arkiv_cancel *token,
               arkiv_progress_callback progress, void *context, char *error, size_t capacity) {
    if (cancelled(token)) return 2;
    int fd = create_open(path);
    struct stat before, after;
    if (fd < 0) return fail(error, capacity, "Cannot safely open archive.");
    if (fstat(fd, &before) || !S_ISREG(before.st_mode)) { close(fd); return fail(error, capacity, "Choose a regular archive file."); }
    unsigned char signature[6]; ssize_t n = pread(fd, signature, 6, 0);
    int result = 0;
    if (n == 6 && !memcmp(signature, "7z\xbc\xaf\x27\x1c", 6)) {
        locale_t utf8 = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", NULL);
        if (!utf8) utf8 = newlocale(LC_CTYPE_MASK, "C.UTF-8", NULL);
        if (!utf8) { close(fd); return fail(error, capacity, "UTF-8 support unavailable."); }
        locale_t previous = uselocale(utf8);
        result = arkiv_seven_test(fd, password, limits.max_entries, limits.max_bytes, seven_cancel, token, progress, context);
        uselocale(previous); freelocale(utf8);
        if (result == 1) result = 6;
    } else {
        uint64_t zip_entries = UINT64_MAX;
        int is_zip = n >= 4 && !memcmp(signature, "PK", 2);
        if (is_zip) result = integrity_zip_directory(fd, (uint64_t)before.st_size, limits, token, &zip_entries, error, capacity);
        if (result || (is_zip && zip_entries == 0)) goto integrity_done;
        struct archive *a = archive_read_new();
        if (!a) { result = fail(error,capacity,"Cannot allocate archive reader."); goto integrity_done; }
        archive_read_support_filter_none(a);
        archive_read_support_format_zip_seekable(a); archive_read_support_format_tar(a);
        if (archive_read_open_fd(a, fd, 65536) != ARCHIVE_OK) result = integrity_error(a, error, capacity);
        struct archive_entry *entry; int status = ARCHIVE_EOF; uint64_t files = 0, bytes = 0;
        char buffer[65536];
        while (!result && (status = archive_read_next_header(a, &entry)) == ARCHIVE_OK) {
            if (cancelled(token)) { result = 2; break; }
            if (files >= limits.max_entries || !safe_path(archive_entry_pathname_utf8(entry)) || !entry_kind(entry)) {
                result = fail(error, capacity, "Archive entry limit or safe path/type policy exceeded."); break;
            }
            if (archive_entry_is_encrypted(entry) > 0) { result = 8; fail(error, capacity, "Encrypted ZIP testing is unsupported."); break; }
            int64_t expected = archive_entry_size(entry); uint64_t read_bytes = 0;
            if (expected < 0 || (uint64_t)expected > limits.max_bytes - bytes) {
                result = fail(error, capacity, "Expanded size limit exceeded."); break;
            }
            for (;;) {
                if (cancelled(token)) { result = 2; break; }
                la_ssize_t amount = archive_read_data(a, buffer, sizeof(buffer));
                if (amount < 0) { result = integrity_error(a, error, capacity); break; }
                if (!amount) break;
                if ((uint64_t)amount > limits.max_bytes - bytes) { result = fail(error, capacity, "Expanded size limit exceeded."); break; }
                bytes += amount; read_bytes += amount;
                if (progress) progress(context, files, bytes);
            }
            if (!result && read_bytes != (uint64_t)expected) result = 6;
            if (!result) { files++; if (progress) progress(context, files, bytes); }
        }
        if (!result && status != ARCHIVE_EOF) result = integrity_error(a, error, capacity);
        if (!result && !is_zip && (archive_format(a) & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_ZIP) {
            result = integrity_zip_directory(fd, (uint64_t)before.st_size, limits, token, &zip_entries, error, capacity);
            is_zip = 1;
        }
        if (!result && is_zip && files != zip_entries) result = 6;
        if (!result && (archive_format(a) & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_TAR) result = 9;
        archive_read_free(a);
    }
integrity_done:
    if (cancelled(token)) result = 2;
    if (fstat(fd, &after) || !create_same_stat(&before, &after)) result = fail(error, capacity, "Archive changed during testing.");
    close(fd); return result;
}

#ifdef __APPLE__
#include <copyfile.h>
#endif
struct zip_envelope { uint32_t offset, size; uint16_t count, comment; unsigned char end[65557]; };
struct arkiv_zip_transaction {
    int source, parent, stage; char *name, *parent_path; struct stat stamp, replacement_stamp; int ready; struct zip_envelope zip;
};
static void zip_put16(unsigned char *p, uint16_t v) { p[0]=v; p[1]=v>>8; }
static void zip_put32(unsigned char *p, uint32_t v) { zip_put16(p,v);zip_put16(p+2,v>>16); }
/* Reject ambiguous/special layouts; copy every accepted local record and metadata byte unchanged. */
static int zip_envelope(int fd, struct zip_envelope *z) {
    struct stat st; unsigned char tail[65557];
    if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_size<22||st.st_size>=UINT32_MAX)return 0;
    size_t n=(uint64_t)st.st_size<sizeof(tail)?(size_t)st.st_size:sizeof(tail);
    if(pread(fd,tail,n,st.st_size-n)!=(ssize_t)n)return 0;
    size_t p=n-22;
    for(;;) { if(!memcmp(tail+p,"PK\005\006",4)&&integrity_u16(tail+p+20)==n-p-22)break;if(!p)return 0;p--; }
    unsigned char *e=tail+p;z->count=integrity_u16(e+10);z->offset=integrity_u32(e+16);z->size=integrity_u32(e+12);z->comment=integrity_u16(e+20);
    if(integrity_u16(e+4)||integrity_u16(e+6)||integrity_u16(e+8)!=z->count||z->count==65535||
       (uint64_t)z->offset+z->size!=(uint64_t)st.st_size-n+p)return 0;
    uint64_t cursor=z->offset, localEnd=0;
    for(unsigned i=0;i<z->count;i++) {
        unsigned char h[46],l[30];
        if(cursor+46>(uint64_t)z->offset+z->size||pread(fd,h,46,cursor)!=46||memcmp(h,"PK\001\002",4))return 0;
        uint16_t flags=integrity_u16(h+8), method=integrity_u16(h+10), name=integrity_u16(h+28), extra=integrity_u16(h+30);
        uint32_t off=integrity_u32(h+42), compressed=integrity_u32(h+20);
        uint64_t len=46u+name+extra+integrity_u16(h+32);
        if(!name||flags & ~0x080e || (method!=0&&method!=8)||integrity_u16(h+34)||compressed==UINT32_MAX||integrity_u32(h+24)==UINT32_MAX||
           cursor+len>(uint64_t)z->offset+z->size||off!=localEnd||pread(fd,l,30,off)!=30||memcmp(l,"PK\003\004",4)||
           integrity_u16(l+6)!=flags||integrity_u16(l+8)!=method||integrity_u16(l+26)!=name)return 0;
        unsigned char names[65535],localnames[65535];
        if(pread(fd,names,name,cursor+46)!=name||pread(fd,localnames,name,off+30)!=name||memcmp(names,localnames,name))return 0;
        /* ZIP64, encryption, Unicode path aliases and opaque extras are unsafe to reinterpret.
           Known timestamp/Unix ownership fields are preserved byte-for-byte. */
        uint16_t lengths[2]={extra,integrity_u16(l+28)};
        uint64_t starts[2]={cursor+46+name,(uint64_t)off+30+name};
        for(int side=0;side<2;side++) {
            unsigned char fields[65535];size_t q=0;
            if(pread(fd,fields,lengths[side],starts[side])!=lengths[side])return 0;
            while(q<lengths[side]) { if(lengths[side]-q<4)return 0;unsigned tag=integrity_u16(fields+q),s=integrity_u16(fields+q+2);
                if(tag!=0x5455&&tag!=0x7875&&tag!=0x7855&&tag!=0x000a)return 0;
                q+=4+s;if(q>lengths[side])return 0;
            }
        }
        localEnd=(uint64_t)off+30+name+integrity_u16(l+28)+compressed;
        if(flags&8) { unsigned char d[16];if(pread(fd,d,16,localEnd)!=16)return 0;
            unsigned shift=!memcmp(d,"PK\007\010",4)?4:0;
            if(integrity_u32(d+shift)!=integrity_u32(h+16)||integrity_u32(d+shift+4)!=compressed||integrity_u32(d+shift+8)!=integrity_u32(h+24))return 0;
            localEnd+=12+shift;
        } else if(memcmp(l+14,h+16,12))return 0;
        if(localEnd>z->offset)return 0;
        cursor+=len;
    }
    if(cursor!=(uint64_t)z->offset+z->size||localEnd!=z->offset)return 0;
    memcpy(z->end,e,22+z->comment);return 1;
}
arkiv_zip_transaction *arkiv_zip_begin(const char *path,char *error,size_t cap) {
    arkiv_zip_transaction *t=calloc(1,sizeof(*t));if(!t)return NULL;
    t->source=t->parent=t->stage=-1;
    char *parent=strdup(path);char *slash=parent?strrchr(parent,'/'):NULL;
    if(!slash||!slash[1])goto bad;
    t->name=strdup(slash+1);if(slash==parent)slash[1]=0;else *slash=0;
    t->parent=create_open(parent);t->parent_path=parent;parent=NULL;
    if(t->parent<0||!t->name)goto bad;
    t->source=openat(t->parent,t->name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(t->source<0||fstat(t->source,&t->stamp)||!zip_envelope(t->source,&t->zip)||faccessat(t->parent,t->name,W_OK,0)||faccessat(t->parent,".",W_OK|X_OK,0))goto bad;
    return t;
bad: free(parent);arkiv_zip_end(t);fail(error,cap,"This archive is read-only. Adding requires a writable, ordinary ZIP32 archive with supported metadata.");return NULL;
}
void arkiv_zip_end(arkiv_zip_transaction *t) { if(!t)return;if(t->source>=0)close(t->source);if(t->parent>=0)close(t->parent);if(t->stage>=0)close(t->stage);free(t->name);free(t->parent_path);free(t); }
static int zip_copy(int in,int out,uint64_t start,uint64_t length,arkiv_cancel *token) {
    unsigned char buffer[65536];while(length) { if(cancelled(token))return 2;size_t n=length<sizeof(buffer)?length:sizeof(buffer);
        if(pread(in,buffer,n,start)!=(ssize_t)n)return 1;
        size_t done=0;while(done<n){ssize_t w=write(out,buffer+done,n-done);if(w<=0)return 1;done+=w;}start+=n;length-=n;
    }return 0;
}
int arkiv_zip_prepare(arkiv_zip_transaction *t,const char *addition,const char *stage,arkiv_cancel *token,arkiv_progress_callback callback,void *context,char *error,size_t cap) {
    int in=create_open(addition),out=-1,result=1;struct zip_envelope z;struct stat st;
    if(in<0||!zip_envelope(in,&z)||t->zip.count+z.count>=65535||
       (uint64_t)t->zip.offset+z.offset+t->zip.size+z.size+22+t->zip.comment>=UINT32_MAX)goto done;
    t->stage=create_open(stage);if(t->stage<0)goto done;
    if(fstat(t->stage,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=geteuid()||(st.st_mode&077)!=0||st.st_dev!=t->stamp.st_dev)goto done;
    out=openat(t->stage,"replacement.zip",O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0600);if(out<0)goto done;
    result=zip_copy(t->source,out,0,t->zip.offset,token);if(result)goto done;
    result=zip_copy(in,out,0,z.offset,token);if(result)goto done;
    result=zip_copy(t->source,out,t->zip.offset,t->zip.size,token);if(result)goto done;
    uint64_t cursor=z.offset;
    for(unsigned i=0;i<z.count;i++) {
        unsigned char h[46];if(pread(in,h,46,cursor)!=46){result=1;goto done;}
        zip_put32(h+42,integrity_u32(h+42)+t->zip.offset);
        if(write(out,h,46)!=46){result=1;goto done;}
        uint64_t len=integrity_u16(h+28)+integrity_u16(h+30)+integrity_u16(h+32);
        result=zip_copy(in,out,cursor+46,len,token);if(result)goto done;cursor+=46+len;
    }
    unsigned char *e=t->zip.end;zip_put16(e+8,t->zip.count+z.count);zip_put16(e+10,t->zip.count+z.count);
    zip_put32(e+12,t->zip.size+z.size);zip_put32(e+16,t->zip.offset+z.offset);
    if(write(out,e,22+t->zip.comment)!=22+t->zip.comment){result=1;goto done;}
#ifdef __APPLE__
    if(fcopyfile(t->source,out,NULL,COPYFILE_METADATA)){result=1;goto done;}
#else
    if(fchmod(out,t->stamp.st_mode&07777)){result=1;goto done;}
#endif
    if(fsync(out)){result=1;goto done;}
    char *output=NULL;if(asprintf(&output,"%s/replacement.zip",stage)<0){result=1;goto done;}
    result=arkiv_test(output,NULL,(arkiv_limits){100000,20ULL*1024*1024*1024},token,callback,context,error,cap);free(output);
    if(result!=0&&result!=2)result=1;
    if(!result) { if(fstat(out,&t->replacement_stamp))result=1;else t->ready=1; }
done:if(in>=0)close(in);if(out>=0)close(out);if(result==1)fail(error,cap,"Cannot safely build and verify the updated ZIP. Original archive unchanged.");return result;
}
int arkiv_zip_commit(arkiv_zip_transaction *t,arkiv_cancel *token,char *error,size_t cap) {
    struct stat current,opened,pinned_parent,current_parent,replacement;
    if(cancelled(token))return 2;
    int parent_now=create_open(t->parent_path);
    int parent_matches=parent_now>=0&&!fstat(parent_now,&current_parent)&&!fstat(t->parent,&pinned_parent)&&
        current_parent.st_dev==pinned_parent.st_dev&&current_parent.st_ino==pinned_parent.st_ino;
    if(parent_now>=0)close(parent_now);
    if(!parent_matches)return fail(error,cap,"Archive parent changed during addition. Original archive was not replaced.");
    if(!t->ready||t->stage<0||fstatat(t->stage,"replacement.zip",&replacement,AT_SYMLINK_NOFOLLOW)||
       !create_same_stat(&t->replacement_stamp,&replacement)||fstat(t->source,&opened)||fstatat(t->parent,t->name,&current,AT_SYMLINK_NOFOLLOW)||
       !create_same_stat(&t->stamp,&opened)||!create_same_stat(&t->stamp,&current))return fail(error,cap,"Archive changed during addition. Original archive was not replaced.");
    if(cancelled(token))return 2;
    if(renameat(t->stage,"replacement.zip",t->parent,t->name))return fail(error,cap,"Cannot atomically replace the archive. Original archive unchanged.");
    return 0;
}
