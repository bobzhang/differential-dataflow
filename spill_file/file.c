#include <moonbit.h>
#include <stdio.h>
#include <stdint.h>
#include <errno.h>
#include <limits.h>
#include <sys/types.h>

typedef struct { FILE *file; int error; int64_t length; } dd_spill_file;
static void dd_spill_destroy(void *opaque) {
    dd_spill_file *self = opaque;
    if (self->file) { fclose(self->file); self->file = NULL; }
}
MOONBIT_FFI_EXPORT dd_spill_file *dd_spill_open(void) {
    dd_spill_file *self = moonbit_make_external_object(dd_spill_destroy, sizeof(dd_spill_file));
    self->length = 0;
    self->file = tmpfile();
    self->error = self->file ? 0 : (errno ? errno : EIO);
    return self;
}
static int dd_spill_seek(dd_spill_file *self, int64_t offset) {
    if (!self->file) { self->error = EBADF; return -1; }
#ifdef _WIN32
    if (_fseeki64(self->file, offset, SEEK_SET) != 0) {
#else
    if ((int64_t)(off_t)offset != offset) { self->error = EOVERFLOW; return -1; }
    if (fseeko(self->file, (off_t)offset, SEEK_SET) != 0) {
#endif
        self->error = errno ? errno : EIO; return -1;
    }
    return 0;
}
MOONBIT_FFI_EXPORT int64_t dd_spill_append(dd_spill_file *self, moonbit_bytes_t bytes) {
    if (self->error) return -1;
    int32_t length = Moonbit_array_length(bytes);
    if (length < 0 || self->length > INT64_MAX - length) { self->error = EOVERFLOW; return -1; }
    int64_t offset = self->length;
    if (dd_spill_seek(self, offset)) return -1;
    if (fwrite(bytes, 1, (size_t)length, self->file) != (size_t)length || fflush(self->file) != 0) {
        self->error = errno ? errno : EIO; return -1;
    }
    self->length += length;
    return offset;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t dd_spill_read(dd_spill_file *self, int64_t offset, int32_t length) {
    if (self->error || offset < 0 || length < 0 || offset > self->length || length > self->length - offset) {
        if (!self->error) self->error = EINVAL;
        return moonbit_make_bytes(0, 0);
    }
    if (dd_spill_seek(self, offset)) return moonbit_make_bytes(0, 0);
    moonbit_bytes_t bytes = moonbit_make_bytes(length, 0);
    if (fread(bytes, 1, (size_t)length, self->file) != (size_t)length) self->error = errno ? errno : EIO;
    return bytes;
}
MOONBIT_FFI_EXPORT int32_t dd_spill_error(dd_spill_file *self) { return self->error; }
MOONBIT_FFI_EXPORT void dd_spill_close(dd_spill_file *self) { dd_spill_destroy(self); }
