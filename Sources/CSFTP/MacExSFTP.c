#include "MacExSFTP.h"
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <stdatomic.h>
#include <pthread.h>
#include <time.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

struct MXSSH {
    LIBSSH2_SESSION *session;
    LIBSSH2_SFTP *sftp;
    LIBSSH2_SFTP_HANDLE *active_handle;
    int socket;
    _Atomic int cancelled;
    int timeout;
    double deadline;
    int code;
    const char *error;
};
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void initialize(void) { libssh2_init(0); }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static int fail(MXSSH *s, int code, const char *text) { s->code = code; s->error = text; return -1; }
static void begin(MXSSH *s) { s->deadline = now() + s->timeout / 1000.0; s->code = 0; s->error = ""; }
static int check(MXSSH *s) {
    if(atomic_load(&s->cancelled)) return fail(s, -1001, "Cancelled. Reconnect before another operation. Partial transfer files may remain.");
    if(now() >= s->deadline) return fail(s, -1002, "The server timed out. Reconnect and check the network. Partial transfer files may remain.");
    return 0;
}
static int wait_socket(MXSSH *s) {
    if(check(s)) return -1;
    int direction = s->session ? libssh2_session_block_directions(s->session) : 0;
    struct pollfd p = { s->socket, (short)((direction & LIBSSH2_SESSION_BLOCK_OUTBOUND ? POLLOUT : 0) |
        (direction & LIBSSH2_SESSION_BLOCK_INBOUND ? POLLIN : 0)), 0 };
    if(!p.events) p.events = POLLIN | POLLOUT;
    int rc = poll(&p, 1, 100);
    if(rc < 0 && errno != EINTR) return fail(s, errno, "The connection could not be polled. Reconnect.");
    if(rc > 0 && (p.revents & (POLLERR | POLLNVAL | POLLHUP))) return fail(s, -1003, "The server disconnected. Partial transfer files may remain.");
    return check(s);
}
// libssh2's Unix-agent backend uses these same callbacks but a blocking socket.
// Bound agent reads/writes here without changing the process's SSH agent or forwarding it.
static ssize_t socket_io(MXSSH *s, int fd, void *buffer, size_t length, int flags, int sending) {
    int no_signal = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_signal, sizeof(no_signal));
    for(;;) {
        if(check(s)) return -EIO;
        ssize_t rc = sending ? send(fd, buffer, length, flags | MSG_DONTWAIT) : recv(fd, buffer, length, flags | MSG_DONTWAIT);
        if(rc >= 0) return rc;
        int error = errno;
        if(error == EINTR) continue;
        if(fd == s->socket || (error != EAGAIN && error != EWOULDBLOCK)) return -error;
        struct pollfd p = {fd, sending ? POLLOUT : POLLIN, 0};
        if(poll(&p, 1, 100) < 0 && errno != EINTR) return -errno;
    }
}
static ssize_t send_callback(libssh2_socket_t fd, const void *buffer, size_t length, int flags, void **abstract) {
    return socket_io(*abstract, fd, (void *)buffer, length, flags, 1);
}
static ssize_t recv_callback(libssh2_socket_t fd, void *buffer, size_t length, int flags, void **abstract) {
    return socket_io(*abstract, fd, buffer, length, flags, 0);
}
static int ssh_failure(MXSSH *s, int rc, const char *message) {
    if(s->code) return -1;
    if(rc == LIBSSH2_ERROR_SFTP_PROTOCOL && s->sftp) {
        unsigned long status = libssh2_sftp_last_error(s->sftp);
        if(status == LIBSSH2_FX_PERMISSION_DENIED) return fail(s, (int)status, "The server denied access to this path.");
        if(status == LIBSSH2_FX_NO_SUCH_FILE) return fail(s, (int)status, "The remote path no longer exists.");
        if(status == LIBSSH2_FX_FILE_ALREADY_EXISTS) return fail(s, (int)status, "The destination already exists. Choose a different name.");
    }
    return fail(s, rc, message);
}
#define RETRY(s, value, expression) do { do { if(check(s)) { value = -1; break; } value = (expression); } while(value == LIBSSH2_ERROR_EAGAIN && !wait_socket(s)); } while(0)

// DNS work is separately bounded: at most two outstanding system resolver calls.
// A timed-out call owns its result until the system resolver returns, then frees it.
typedef struct { char *host; char port[8]; struct addrinfo *addresses; int status; _Atomic int done; _Atomic int references; } Resolver;
static _Atomic int resolvers = 0;
static void release_resolver(Resolver *r) { if(atomic_fetch_sub(&r->references, 1) == 1) { if(r->addresses) freeaddrinfo(r->addresses); free(r->host); free(r); } }
static void *resolve_host(void *pointer) {
    Resolver *r = pointer;
    struct addrinfo hints = {0}; hints.ai_socktype = SOCK_STREAM; hints.ai_family = AF_UNSPEC;
    r->status = getaddrinfo(r->host, r->port, &hints, &r->addresses);
    atomic_store(&r->done, 1); atomic_fetch_sub(&resolvers, 1); release_resolver(r); return NULL;
}
MXSSH *mxssh_create(void) {
    pthread_once(&once, initialize);
    MXSSH *s = calloc(1, sizeof(*s)); if(s) { s->socket = -1; s->timeout = 15000; s->error = ""; } return s;
}
void mxssh_cancel(MXSSH *s) { if(s) atomic_store(&s->cancelled, 1); }
const char *mxssh_error(MXSSH *s) { return s && s->error ? s->error : "Could not allocate an SSH session."; }
int mxssh_error_code(MXSSH *s) { return s ? s->code : -1; }
const char *mxssh_library_version(void) { return libssh2_version(0); }
void mxssh_free(MXSSH *s) {
    if(!s) return;
    // Close transport before cleanup, so teardown cannot await a remote peer.
    if(s->socket >= 0) { shutdown(s->socket, SHUT_RDWR); close(s->socket); s->socket = -1; }
    if(s->session) {
        libssh2_session_set_blocking(s->session, 1); libssh2_session_set_timeout(s->session, 200);
        if(s->active_handle) libssh2_sftp_close_handle(s->active_handle);
        if(s->sftp) libssh2_sftp_shutdown(s->sftp);
        libssh2_session_free(s->session);
    }
    free(s);
}
int mxssh_connect(MXSSH *s, const char *host, uint16_t port, int timeout_ms) {
    if(s->session || s->socket >= 0) return fail(s, -1, "Create a new session before reconnecting.");
    s->timeout = timeout_ms > 0 ? timeout_ms : 15000; begin(s);
    if(atomic_fetch_add(&resolvers, 1) >= 2) { atomic_fetch_sub(&resolvers, 1); return fail(s, -1, "DNS resolution is busy. Wait and retry."); }
    Resolver *r = calloc(1, sizeof(*r));
    if(!r) { atomic_fetch_sub(&resolvers, 1); return fail(s, -1, "Could not allocate a resolver."); }
    r->host = strdup(host); snprintf(r->port, sizeof(r->port), "%u", port); atomic_store(&r->references, 2);
    pthread_t thread;
    if(!r->host || pthread_create(&thread, NULL, resolve_host, r)) { atomic_fetch_sub(&resolvers, 1); atomic_store(&r->references, 1); release_resolver(r); return fail(s, -1, "Could not start DNS resolution."); }
    pthread_detach(thread);
    while(!atomic_load(&r->done)) {
        if(check(s)) { release_resolver(r); return -1; }
        struct timespec pause = {0, 20000000}; nanosleep(&pause, NULL);
    }
    if(r->status) { release_resolver(r); return fail(s, -1, "The hostname could not be resolved. Check the server address."); }
    int connected = 0;
    for(struct addrinfo *a = r->addresses; a && !connected; a = a->ai_next) {
        if(check(s)) break;
        s->socket = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if(s->socket < 0) continue;
        fcntl(s->socket, F_SETFD, FD_CLOEXEC); fcntl(s->socket, F_SETFL, O_NONBLOCK);
        int no_signal = 1; setsockopt(s->socket, SOL_SOCKET, SO_NOSIGPIPE, &no_signal, sizeof(no_signal));
        int rc = connect(s->socket, a->ai_addr, a->ai_addrlen);
        while(rc < 0 && errno == EINPROGRESS && !check(s)) {
            struct pollfd p = {s->socket, POLLOUT, 0};
            int ready = poll(&p, 1, 100);
            if(ready > 0) { int error = 0; socklen_t n = sizeof(error); getsockopt(s->socket, SOL_SOCKET, SO_ERROR, &error, &n); if(!error) rc = 0; break; }
            if(ready < 0 && errno != EINTR) break;
            errno = EINPROGRESS;
        }
        if(rc == 0) connected = 1;
        else { close(s->socket); s->socket = -1; }
    }
    release_resolver(r);
    if(!connected) return s->code ? -1 : fail(s, -1, "Could not connect. Check the hostname, port, firewall, and server availability.");
    s->session = libssh2_session_init_ex(NULL, NULL, NULL, s);
    if(!s->session) return fail(s, -1, "Could not allocate an SSH session.");
    libssh2_session_set_blocking(s->session, 0);
    libssh2_session_callback_set2(s->session, LIBSSH2_CALLBACK_SEND, (libssh2_cb_generic *)send_callback);
    libssh2_session_callback_set2(s->session, LIBSSH2_CALLBACK_RECV, (libssh2_cb_generic *)recv_callback);
    // Exclude SHA-1 KEX/signatures, CBC, and weak MACs. No algorithm downgrade retry.
    if(libssh2_session_method_pref(s->session, LIBSSH2_METHOD_KEX, "curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group16-sha512,diffie-hellman-group14-sha256") ||
       libssh2_session_method_pref(s->session, LIBSSH2_METHOD_HOSTKEY, "ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-512,rsa-sha2-256"))
        return fail(s, -1, "This build could not enable its required SSH algorithms.");
    const char *ciphers = "aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr";
    const char *macs = "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256";
    if(libssh2_session_method_pref(s->session, LIBSSH2_METHOD_CRYPT_CS, ciphers) || libssh2_session_method_pref(s->session, LIBSSH2_METHOD_CRYPT_SC, ciphers) ||
       libssh2_session_method_pref(s->session, LIBSSH2_METHOD_MAC_CS, macs) || libssh2_session_method_pref(s->session, LIBSSH2_METHOD_MAC_SC, macs))
        return fail(s, -1, "This build could not enable its required SSH ciphers and MACs.");
    int rc; RETRY(s, rc, libssh2_session_handshake(s->session, s->socket));
    return rc ? ssh_failure(s, rc, "SSH handshake failed. The server may not support the required algorithms.") : 0;
}
int mxssh_hostkey(MXSSH *s, const unsigned char **bytes, size_t *length, int *type) {
    *bytes = (const unsigned char *)libssh2_session_hostkey(s->session, length, type);
    return *bytes && *length ? 0 : fail(s, -1, "The server did not provide a host key.");
}
int mxssh_auth_password(MXSSH *s, const char *user, const char *password) {
    begin(s); int rc; RETRY(s, rc, libssh2_userauth_password_ex(s->session, user, (unsigned)strlen(user), password, (unsigned)strlen(password), NULL));
    return rc ? ssh_failure(s, rc, "Password authentication failed. Check the account and the server's authentication policy.") : 0;
}
int mxssh_auth_key(MXSSH *s, const char *user, const char *private_path, const char *passphrase) {
    begin(s); int rc; RETRY(s, rc, libssh2_userauth_publickey_fromfile_ex(s->session, user, (unsigned)strlen(user), NULL, private_path, passphrase));
    return rc ? ssh_failure(s, rc, "Key authentication failed. Check the selected RSA/Ed25519 key, passphrase, and server policy.") : 0;
}
int mxssh_auth_agent(MXSSH *s, const char *user, const char *agent_socket) {
    begin(s); LIBSSH2_AGENT *agent = libssh2_agent_init(s->session);
    if(!agent) return fail(s, -1, "Could not initialize the SSH agent.");
    if(agent_socket && *agent_socket) libssh2_agent_set_identity_path(agent, agent_socket);
    int rc; RETRY(s, rc, libssh2_agent_connect(agent));
    if(!rc) RETRY(s, rc, libssh2_agent_list_identities(agent));
    struct libssh2_agent_publickey *identity = NULL, *previous = NULL;
    int authenticated = 0;
    if(!rc) for(int i = 0; i < 128 && !check(s); ++i) {
        RETRY(s, rc, libssh2_agent_get_identity(agent, &identity, previous));
        if(rc) break;
        RETRY(s, rc, libssh2_agent_userauth(agent, user, identity));
        if(!rc) { authenticated = 1; break; }
        previous = identity;
    }
    libssh2_agent_disconnect(agent); libssh2_agent_free(agent);
    return authenticated ? 0 : ssh_failure(s, rc ? rc : -1, "Agent authentication failed. Unlock the existing agent and load an allowed key. Agent forwarding is never enabled.");
}
int mxssh_sftp_start(MXSSH *s) {
    begin(s);
    do { if(check(s)) return -1; s->sftp = libssh2_sftp_init(s->session); }
    while(!s->sftp && libssh2_session_last_errno(s->session) == LIBSSH2_ERROR_EAGAIN && !wait_socket(s));
    return s->sftp ? 0 : ssh_failure(s, libssh2_session_last_errno(s->session), "The server could not start SFTP.");
}
static void attributes(const LIBSSH2_SFTP_ATTRIBUTES *a, MXSSHAttributes *out) {
    out->size = a->filesize; out->modified = a->mtime; out->permissions = (uint32_t)a->permissions; out->flags = (uint32_t)a->flags;
}
int mxssh_stat(MXSSH *s, const char *path, MXSSHAttributes *out) {
    begin(s); LIBSSH2_SFTP_ATTRIBUTES a = {0}; int rc;
    RETRY(s, rc, libssh2_sftp_stat_ex(s->sftp, path, (unsigned)strlen(path), LIBSSH2_SFTP_LSTAT, &a));
    if(rc) return ssh_failure(s, rc, "The remote item could not be inspected."); attributes(&a, out); return 0;
}
static LIBSSH2_SFTP_HANDLE *open_remote(MXSSH *s, const char *path, unsigned long flags, int kind) {
    LIBSSH2_SFTP_HANDLE *h;
    do { if(check(s)) return NULL; h = libssh2_sftp_open_ex(s->sftp, path, (unsigned)strlen(path), flags, 0600, kind); }
    while(!h && libssh2_session_last_errno(s->session) == LIBSSH2_ERROR_EAGAIN && !wait_socket(s));
    if(!h) ssh_failure(s, libssh2_session_last_errno(s->session), "The remote path could not be opened. An existing destination is never overwritten.");
    if(h) s->active_handle = h;
    return h;
}
static int close_remote(MXSSH *s, LIBSSH2_SFTP_HANDLE *h) {
    int rc;
    for(;;) {
        if(check(s)) return -1;
        rc = libssh2_sftp_close_handle(h);
        if(rc != LIBSSH2_ERROR_EAGAIN) { s->active_handle = NULL; break; }
        if(wait_socket(s)) return -1;
    }
    return rc ? ssh_failure(s, rc, "The remote file could not be closed cleanly. Verify the partial transfer before retrying.") : 0;
}
int mxssh_list(MXSSH *s, const char *path, MXSSHEntryCallback callback, void *context) {
    begin(s); LIBSSH2_SFTP_HANDLE *h = open_remote(s, path, 0, LIBSSH2_SFTP_OPENDIR); if(!h) return -1;
    int result = 0;
    for(int count = 0; ; ++count) {
        char name[32769]; LIBSSH2_SFTP_ATTRIBUTES a = {0}; int rc;
        RETRY(s, rc, libssh2_sftp_readdir_ex(h, name, sizeof(name) - 1, NULL, 0, &a));
        if(rc < 0) { result = ssh_failure(s, rc, "The directory could not be read completely."); break; }
        if(!rc) break;
        if(count >= 20000) { result = fail(s, -1, "The directory exceeds the 20000-entry limit. Choose a smaller directory."); break; }
        MXSSHAttributes out = {0}; attributes(&a, &out);
        if(callback(name, (size_t)rc, &out, context)) { result = fail(s, -1, "The server returned an unsupported filename."); break; }
    }
    if(result) return -1; return close_remote(s, h);
}
int mxssh_mkdir(MXSSH *s, const char *path) {
    begin(s); int rc; RETRY(s, rc, libssh2_sftp_mkdir_ex(s->sftp, path, (unsigned)strlen(path), 0700));
    return rc ? ssh_failure(s, rc, "Could not create the remote folder. Existing paths are never replaced.") : 0;
}
int mxssh_rename(MXSSH *s, const char *source, const char *destination) {
    begin(s); int rc; RETRY(s, rc, libssh2_sftp_rename_ex(s->sftp, source, (unsigned)strlen(source), destination, (unsigned)strlen(destination), 0));
    return rc ? ssh_failure(s, rc, "The server refused a non-overwriting rename. Choose another name or use a server supporting this operation.") : 0;
}
static int same_remote(const LIBSSH2_SFTP_ATTRIBUTES *a, const LIBSSH2_SFTP_ATTRIBUTES *b) {
    return a->flags == b->flags && a->filesize == b->filesize && a->mtime == b->mtime && a->permissions == b->permissions;
}
int mxssh_download(MXSSH *s, const char *remote, const char *local, uint64_t limit, MXSSHProgressCallback progress, void *context) {
    begin(s); MXSSHAttributes entry;
    if(mxssh_stat(s, remote, &entry)) return -1;
    if(!(entry.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) || (entry.permissions & 0170000) != 0100000)
        return fail(s, -1, "Download a regular file. Symbolic links and special files are not followed.");
    if(limit && (entry.flags & LIBSSH2_SFTP_ATTR_SIZE) && entry.size > limit) return fail(s, -1, "This file exceeds the preview/download size limit.");
    LIBSSH2_SFTP_HANDLE *h = open_remote(s, remote, LIBSSH2_FXF_READ, LIBSSH2_SFTP_OPENFILE); if(!h) return -1;
    LIBSSH2_SFTP_ATTRIBUTES before = {0}, after = {0}; int rc;
    RETRY(s, rc, libssh2_sftp_fstat_ex(h, &before, 0));
    if(rc || !(before.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) || (before.permissions & 0170000) != 0100000) return ssh_failure(s, rc ? rc : -1, "The remote file changed before download.");
    int fd = open(local, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if(fd < 0) return fail(s, errno, "The local destination already exists or is unavailable. Choose another name.");
    uint64_t bound = (before.flags & LIBSSH2_SFTP_ATTR_SIZE) ? before.filesize : 1099511627776ULL;
    if(limit && bound > limit) bound = limit;
    uint64_t total = 0; char buffer[65536]; int result = 0;
    while(!result) {
        ssize_t n; RETRY(s, n, libssh2_sftp_read(h, buffer, sizeof(buffer)));
        if(n < 0) { result = ssh_failure(s, (int)n, "Download interrupted. A partial local file remains at the chosen path."); break; }
        if(!n) break;
        if((uint64_t)n > bound - total) { result = fail(s, -1, "The download exceeded its size limit. The partial file was retained."); break; }
        ssize_t offset = 0;
        while(offset < n) { ssize_t written = write(fd, buffer + offset, (size_t)(n - offset)); if(written < 0 && errno == EINTR) continue; if(written <= 0) { result = fail(s, errno, "Could not write the local file. A partial download remains."); break; } offset += written; }
        total += (uint64_t)n; s->deadline = now() + s->timeout / 1000.0; if(progress) progress(total, context);
    }
    if(!result) {
        RETRY(s, rc, libssh2_sftp_fstat_ex(h, &after, 0));
        if(rc || !same_remote(&before, &after) || ((before.flags & LIBSSH2_SFTP_ATTR_SIZE) && before.filesize != total))
            result = fail(s, -1, "The remote file changed or was truncated during download. The local copy needs review.");
    }
    if(!result && fsync(fd)) result = fail(s, errno, "The local file could not be flushed to storage.");
    close(fd); if(result) return -1; return close_remote(s, h);
}
int mxssh_upload(MXSSH *s, const char *local, const char *remote, MXSSHProgressCallback progress, void *context) {
    begin(s); int fd = open(local, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if(fd < 0) return fail(s, errno, "The selected local file could not be opened.");
    struct stat before, after;
    if(fstat(fd, &before) || !S_ISREG(before.st_mode)) { close(fd); return fail(s, -1, "Upload a regular file. Links, folders, and special files are not followed."); }
    LIBSSH2_SFTP_HANDLE *h = open_remote(s, remote, LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_EXCL, LIBSSH2_SFTP_OPENFILE);
    if(!h) { close(fd); return -1; }
    char buffer[65536]; uint64_t total = 0; int result = 0;
    while(!result && total < (uint64_t)before.st_size) {
        if(check(s)) { result = -1; break; }
        size_t wanted = (uint64_t)before.st_size - total < sizeof(buffer) ? (size_t)((uint64_t)before.st_size - total) : sizeof(buffer);
        ssize_t n = read(fd, buffer, wanted);
        if(n < 0 && errno == EINTR) continue;
        if(n < 0) { result = fail(s, errno, "Could not read the source. A partial remote file remains."); break; }
        if(!n) break;
        ssize_t offset = 0;
        while(offset < n) {
            ssize_t written; RETRY(s, written, libssh2_sftp_write(h, buffer + offset, (size_t)(n - offset)));
            if(written <= 0) { result = ssh_failure(s, (int)written, "Upload interrupted. A partial remote file remains at the chosen path."); break; }
            offset += written; total += (uint64_t)written; s->deadline = now() + s->timeout / 1000.0; if(progress) progress(total, context);
        }
    }
    if(!result && (fstat(fd, &after) || before.st_dev != after.st_dev || before.st_ino != after.st_ino || before.st_size != after.st_size ||
        before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec ||
        before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec || total != (uint64_t)before.st_size))
        result = fail(s, -1, "The local source changed during upload. The remote copy needs review; the source was retained.");
    close(fd); if(result) return -1; return close_remote(s, h);
}
