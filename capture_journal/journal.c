#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#ifndef _WIN32
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#endif

typedef struct { int fd, error, writer, ready, limit; int64_t offset; } dd_journal;
static void destroy(void *opaque) {
    dd_journal *j = opaque;
#ifndef _WIN32
    if (j->fd >= 0) {
        int fd = j->fd; j->fd = -1;
        if (close(fd) != 0 && !j->error) j->error = errno;
    }
#endif
}
#ifndef _WIN32
static int sync_fd(int fd) {
    int result;
    do { result = fsync(fd); } while (result < 0 && errno == EINTR);
    return result;
}
static int sync_parent(const char *path) {
    char *parent = strdup(path);
    if (!parent) return -1;
    char *slash = strrchr(parent, '/');
    if (slash) { if (slash == parent) slash[1] = 0; else *slash = 0; }
    else { free(parent); parent = strdup("."); if (!parent) return -1; }
    int fd = open(parent, O_RDONLY | O_CLOEXEC | O_DIRECTORY);
    free(parent);
    if (fd < 0) return -1;
    int result = sync_fd(fd), saved = errno;
    close(fd); errno = saved;
    return result;
}
static uint32_t checksum(const unsigned char *p, int n) {
    uint32_t h = 2166136261U;
    for (int i = 0; i < n; ++i) h = (h ^ p[i]) * 16777619U;
    return h;
}
static uint32_t load32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}
static void store32(unsigned char *p, uint32_t v) {
    for (int i = 0; i < 4; ++i) p[i] = (unsigned char)(v >> (8*i));
}
static int write_all(int fd, const unsigned char *p, size_t n) {
    while (n) {
        ssize_t count = write(fd, p, n);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { if (!count) errno = EIO; return -1; }
        p += count; n -= (size_t)count;
    }
    return 0;
}
static int read_at(dd_journal *j, unsigned char *p, size_t n, int64_t offset) {
    if ((int64_t)(off_t)offset != offset) { j->error = EOVERFLOW; return -1; }
    while (n) {
        ssize_t count = pread(j->fd, p, n, (off_t)offset);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { j->error = errno; return -1; }
        if (!count) return 0;
        p += count; n -= (size_t)count; offset += count;
    }
    return 1;
}
#endif
MOONBIT_FFI_EXPORT dd_journal *dd_journal_open(moonbit_bytes_t path, int32_t writer, int32_t limit) {
    dd_journal *j = moonbit_make_external_object(destroy, sizeof(dd_journal));
    j->fd = -1; j->error = 0; j->writer = writer; j->ready = 0; j->limit = limit; j->offset = 0;
#ifdef _WIN32
    j->error = ENOSYS;
#else
    if (limit <= 0 || Moonbit_array_length(path) == 0 || memchr(path, 0, Moonbit_array_length(path))) {
        j->error = EINVAL; return j;
    }
    j->fd = open((char *)path, (writer ? O_WRONLY | O_CREAT | O_EXCL : O_RDONLY | O_NONBLOCK) | O_CLOEXEC, 0600);
    if (j->fd < 0) { j->error = errno; return j; }
    struct stat st;
    if (fstat(j->fd, &st) < 0) { j->error = errno; destroy(j); return j; }
    if (!S_ISREG(st.st_mode)) { j->error = EINVAL; destroy(j); return j; }
    if (writer && (sync_fd(j->fd) < 0 || sync_parent((char *)path) < 0)) {
        j->error = errno; destroy(j);
    }
#endif
    return j;
}
MOONBIT_FFI_EXPORT void dd_journal_append(dd_journal *j, moonbit_bytes_t bytes) {
    if (j->error) return;
#ifndef _WIN32
    if (j->fd < 0 || !j->writer) { j->error = EBADF; return; }
    int32_t n = Moonbit_array_length(bytes);
    if (n < 0 || n > j->limit) { j->error = EMSGSIZE; return; }
    unsigned char header[12] = {'D','D','C','1'};
    store32(header+4, (uint32_t)n); store32(header+8, checksum(bytes,n));
    if (write_all(j->fd, header, sizeof(header)) || write_all(j->fd, bytes, (size_t)n) || sync_fd(j->fd)) {
        j->error = errno ? errno : EIO;
    }
#endif
}
MOONBIT_FFI_EXPORT moonbit_bytes_t dd_journal_next(dd_journal *j) {
    j->ready = 0;
    if (j->error) return moonbit_make_bytes(0,0);
#ifndef _WIN32
    if (j->fd < 0 || j->writer) { j->error = EBADF; return moonbit_make_bytes(0,0); }
    unsigned char header[12];
    if (j->offset > INT64_MAX - 12) { j->error = EOVERFLOW; return moonbit_make_bytes(0,0); }
    if (read_at(j, header, 12, j->offset) != 1) return moonbit_make_bytes(0,0);
    uint32_t n = load32(header+4);
    if (memcmp(header,"DDC1",4) || n > (uint32_t)j->limit) {
        j->error = EINVAL; return moonbit_make_bytes(0,0);
    }
    if (j->offset > INT64_MAX - 12 - n) { j->error = EOVERFLOW; return moonbit_make_bytes(0,0); }
    struct stat st;
    if (fstat(j->fd,&st) < 0) { j->error = errno; return moonbit_make_bytes(0,0); }
    if (st.st_size < j->offset + 12 + n) return moonbit_make_bytes(0,0);
    moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)n,0);
    if (read_at(j,bytes,n,j->offset+12) != 1) return bytes;
    if (checksum(bytes,(int)n) != load32(header+8)) { j->error = EINVAL; return bytes; }
    j->offset += 12 + n;
    j->ready = 1;
    return bytes;
#else
    return moonbit_make_bytes(0,0);
#endif
}
MOONBIT_FFI_EXPORT int32_t dd_journal_error(dd_journal *j) { return j->error; }
MOONBIT_FFI_EXPORT int32_t dd_journal_ready(dd_journal *j) { return j->ready; }
MOONBIT_FFI_EXPORT void dd_journal_close(dd_journal *j) { destroy(j); }
