#include "CFileOps.h"
#include <copyfile.h>
#include <errno.h>
#include <stdio.h>
#include <sys/stdio.h>

struct mx_context { mx_progress progress; void *context; };

static int mx_callback(int what, int stage, copyfile_state_t state,
                       const char *source, const char *destination, void *opaque) {
    (void)destination;
    struct mx_context *context = opaque;
    if (stage == COPYFILE_ERR) return COPYFILE_QUIT;
    off_t bytes = 0;
    if (what == COPYFILE_COPY_DATA) copyfile_state_get(state, COPYFILE_STATE_COPIED, &bytes);
    if (context->progress((int64_t)bytes, source, context->context)) {
        errno = ECANCELED;
        return COPYFILE_QUIT;
    }
    return COPYFILE_CONTINUE;
}

int mx_copy(const char *source, const char *destination, mx_progress progress, void *context) {
    copyfile_state_t state = copyfile_state_alloc();
    if (!state) return ENOMEM;
    struct mx_context callback = { progress, context };
    copyfile_state_set(state, COPYFILE_STATE_STATUS_CB, (const void *)mx_callback);
    copyfile_state_set(state, COPYFILE_STATE_STATUS_CTX, &callback);
    int result = copyfile(source, destination, state,
        COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW);
    int error = result == 0 ? 0 : (errno ? errno : EIO);
    copyfile_state_free(state);
    return error;
}

int mx_rename_exclusive(const char *source, const char *destination) {
    return renamex_np(source, destination, RENAME_EXCL) == 0 ? 0 : errno;
}
