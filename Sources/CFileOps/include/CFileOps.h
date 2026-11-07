#ifndef MACEX_FILE_OPS_H
#define MACEX_FILE_OPS_H
#include <stdint.h>
typedef int (*mx_progress)(int64_t bytes, const char *path, void *context);
int mx_copy(const char *source, const char *destination, mx_progress progress, void *context);
int mx_rename_exclusive(const char *source, const char *destination);
typedef int (*mx_cancelled)(void *context);
typedef struct {
    int64_t bytes;
    uint32_t items;
    uint32_t skipped;
    int limited;
} mx_folder_size_result;
/* Metadata only. Counts entries excluding the root; link targets are never visited.
 * A successful partial scan records skipped entries. ECANCELED never returns a usable total. */
int mx_folder_size(const char *path, uint32_t limit, mx_cancelled cancelled,
                   void *context, mx_folder_size_result *result);
#endif
