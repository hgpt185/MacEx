#ifndef MACEX_SFTP_H
#define MACEX_SFTP_H
#include <stdint.h>
#include <stddef.h>

typedef struct MXSSH MXSSH;
typedef struct { uint64_t size; uint64_t modified; uint32_t permissions; uint32_t flags; } MXSSHAttributes;
typedef int (*MXSSHEntryCallback)(const char *, size_t, const MXSSHAttributes *, void *);
typedef void (*MXSSHProgressCallback)(uint64_t, void *);

MXSSH *mxssh_create(void);
void mxssh_cancel(MXSSH *);
void mxssh_free(MXSSH *);
int mxssh_connect(MXSSH *, const char *host, uint16_t port, int timeout_ms);
int mxssh_hostkey(MXSSH *, const unsigned char **bytes, size_t *length, int *type);
int mxssh_auth_password(MXSSH *, const char *user, const char *password);
int mxssh_auth_key(MXSSH *, const char *user, const char *private_path, const char *passphrase);
int mxssh_auth_agent(MXSSH *, const char *user, const char *agent_socket);
int mxssh_sftp_start(MXSSH *);
int mxssh_list(MXSSH *, const char *path, MXSSHEntryCallback, void *);
int mxssh_stat(MXSSH *, const char *path, MXSSHAttributes *);
int mxssh_mkdir(MXSSH *, const char *path);
int mxssh_rename(MXSSH *, const char *source, const char *destination);
int mxssh_download(MXSSH *, const char *remote, const char *local, uint64_t limit, MXSSHProgressCallback, void *);
int mxssh_upload(MXSSH *, const char *local, const char *remote, MXSSHProgressCallback, void *);
const char *mxssh_error(MXSSH *);
int mxssh_error_code(MXSSH *);
const char *mxssh_library_version(void);
#endif
