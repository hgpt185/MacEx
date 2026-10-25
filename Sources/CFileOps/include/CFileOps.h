#ifndef MACEX_FILE_OPS_H
#define MACEX_FILE_OPS_H
#include <stdint.h>
typedef int (*mx_progress)(int64_t bytes, const char *path, void *context);
int mx_copy(const char *source, const char *destination, mx_progress progress, void *context);
int mx_rename_exclusive(const char *source, const char *destination);
#endif
