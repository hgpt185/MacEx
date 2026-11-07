#include "CFileOps.h"
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <stddef.h>
#include <string.h>

/* Darwin UF_DATALESS is not exposed by every public SDK. Same flag used by FileAvailability. */
#define MX_DATALESS_FLAG 0x40000000u

/* getattrlist buffers use four-byte field alignment, including off_t. */
#pragma pack(push, 4)
struct mx_size_attrs {
    uint32_t length;
    attribute_set_t returned;
    uint32_t error;
    attrreference_t name;
    fsobj_type_t type;
    uint32_t flags;
};
#pragma pack(pop)

struct mx_size_scan {
    uint32_t limit;
    mx_cancelled cancelled;
    void *context;
    mx_folder_size_result *result;
};

static int mx_size_cancelled(struct mx_size_scan *scan) {
    return scan->cancelled && scan->cancelled(scan->context);
}

/* Reserve descriptors and bounded stack/buffer memory even on maliciously deep trees. */
static int mx_size_directory(int fd, unsigned depth, struct mx_size_scan *scan) {
    if (mx_size_cancelled(scan)) return ECANCELED;
    if (depth >= 128) { scan->result->skipped++; return 0; }
    struct stat before;
    if (fstat(fd, &before) != 0 || (before.st_flags & MX_DATALESS_FLAG)) {
        scan->result->skipped++; return 0;
    }
    const size_t capacity = 65536;
    char *buffer = malloc(capacity);
    if (!buffer) return ENOMEM;
    struct attrlist attrs = {0};
    attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    attrs.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME |
                       ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS;
    attrs.fileattr = ATTR_FILE_DATALENGTH;
    int error = 0;
    for (;;) {
        if (mx_size_cancelled(scan)) { error = ECANCELED; break; }
        int count = getattrlistbulk(fd, &attrs, buffer, capacity, FSOPT_PACK_INVAL_ATTRS);
        if (count < 0) { scan->result->skipped++; break; }
        if (count == 0) break;
        size_t offset = 0;
        for (int index = 0; index < count; index++) {
            if (mx_size_cancelled(scan)) { error = ECANCELED; goto finish; }
            if (scan->result->items >= scan->limit) { scan->result->limited = 1; goto finish; }
            if (offset > capacity - sizeof(struct mx_size_attrs)) {
                scan->result->skipped++; goto finish;
            }
            struct mx_size_attrs value;
            memcpy(&value, buffer + offset, sizeof(value));
            if (value.length < sizeof(value) || value.length > capacity - offset) {
                scan->result->skipped++; goto finish;
            }
            char *record = buffer + offset;
            offset += value.length;
            scan->result->items++;
            if (value.error || !(value.returned.commonattr & ATTR_CMN_OBJTYPE) ||
                !(value.returned.commonattr & ATTR_CMN_FLAGS)) {
                scan->result->skipped++; continue;
            }
            if (value.type == VLNK) continue;
            if (value.flags & MX_DATALESS_FLAG) { scan->result->skipped++; continue; }
            if (value.type == VREG) {
                /* File-only attributes are omitted entirely for directories, even
                 * with FSOPT_PACK_INVAL_ATTRS. Read the data length only for files. */
                off_t bytes = 0;
                if (value.length >= sizeof(value) + sizeof(bytes)) memcpy(&bytes, record + sizeof(value), sizeof(bytes));
                if (!(value.returned.fileattr & ATTR_FILE_DATALENGTH) || value.length < sizeof(value) + sizeof(bytes) || bytes < 0 ||
                    INT64_MAX - scan->result->bytes < bytes) scan->result->skipped++;
                else scan->result->bytes += bytes;
            } else if (value.type == VDIR) {
                /* Validate the kernel's relative name before passing it to openat. */
                int64_t nameOffset = (int64_t)offsetof(struct mx_size_attrs, name) + value.name.attr_dataoffset;
                if (!(value.returned.commonattr & ATTR_CMN_NAME) || nameOffset < (int64_t)sizeof(value) ||
                    nameOffset >= value.length || value.name.attr_length < 2 ||
                    value.name.attr_length > value.length - nameOffset) {
                    scan->result->skipped++; continue;
                }
                char *name = record + nameOffset;
                size_t length = value.name.attr_length;
                if (name[length - 1] != 0 || memchr(name, '/', length) ||
                    !strcmp(name, ".") || !strcmp(name, "..")) {
                    scan->result->skipped++; continue;
                }
                /* Recheck flags without following links immediately before opening. */
                struct stat child;
                if (fstatat(fd, name, &child, AT_SYMLINK_NOFOLLOW) != 0 ||
                    !S_ISDIR(child.st_mode) || (child.st_flags & MX_DATALESS_FLAG)) {
                    scan->result->skipped++; continue;
                }
                int childFD = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
                if (childFD < 0) { scan->result->skipped++; continue; }
                error = mx_size_directory(childFD, depth + 1, scan);
                close(childFD);
                if (error || scan->result->limited) goto finish;
            }
        }
    }
finish:;
    /* A changing directory is a partial snapshot, even when all observed entries fit. */
    struct stat after;
    if (fstat(fd, &after) != 0 || before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
        before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec) scan->result->skipped++;
    free(buffer);
    return error;
}

int mx_folder_size(const char *path, uint32_t limit, mx_cancelled cancelled,
                   void *context, mx_folder_size_result *result) {
    memset(result, 0, sizeof(*result));
    struct mx_size_scan scan = {limit, cancelled, context, result};
    if (mx_size_cancelled(&scan)) return ECANCELED;
    struct stat root;
    if (lstat(path, &root) != 0) return errno;
    if (!S_ISDIR(root.st_mode)) return ENOTDIR;
    if (root.st_flags & MX_DATALESS_FLAG) { result->skipped = 1; return 0; }
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        if (errno == EACCES || errno == EPERM) { result->skipped = 1; return 0; }
        return errno;
    }
    int error = mx_size_directory(fd, 0, &scan);
    close(fd);
    return error;
}
