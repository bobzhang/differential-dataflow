#define _POSIX_C_SOURCE 200809L
#include <moonbit.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#if !defined(_WIN32)
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <time.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#endif

typedef struct { int fd; int error; int timeout; int limit; } dd_socket;
static void dd_destroy(void *ptr) {
  dd_socket *s = ptr;
#if !defined(_WIN32)
  if (s->fd >= 0) close(s->fd);
#endif
  s->fd = -1;
}
static dd_socket *dd_alloc(int timeout, int limit) {
  dd_socket *s = moonbit_make_external_object(dd_destroy, sizeof(dd_socket));
  s->fd = -1; s->error = 0; s->timeout = timeout; s->limit = limit;
  return s;
}
static void dd_fail(dd_socket *s, int error) {
  dd_destroy(s); s->error = error ? error : EIO;
}
#if !defined(_WIN32)
static int64_t dd_now(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts)) return 0;
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static int dd_wait(int fd, short events, int64_t deadline) {
  for (;;) {
    int64_t left = deadline - dd_now();
    if (left <= 0) { errno = ETIMEDOUT; return -1; }
    struct pollfd p = {fd, events, 0};
    int result = poll(&p, 1, left > INT32_MAX ? INT32_MAX : (int)left);
    if (result > 0) return 0;
    if (result == 0) { errno = ETIMEDOUT; return -1; }
    if (errno != EINTR) return -1;
  }
}
static int dd_transfer(dd_socket *s, void *buffer, size_t length, int writing, int64_t deadline) {
  unsigned char *ptr = buffer;
  while (length) {
    if (dd_wait(s->fd, writing ? POLLOUT : POLLIN, deadline)) return -1;
    ssize_t n;
    if (writing) {
#ifdef MSG_NOSIGNAL
      n = send(s->fd, ptr, length, MSG_NOSIGNAL);
#else
      n = send(s->fd, ptr, length, 0);
#endif
    } else n = recv(s->fd, ptr, length, 0);
    if (n > 0) { ptr += n; length -= (size_t)n; }
    else if (n == 0) { errno = ECONNRESET; return -1; }
    else if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) return -1;
  }
  return 0;
}
static int dd_configure(int fd) {
  int nodelay = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
#ifdef SO_NOSIGPIPE
  int one = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one))) return -1;
#endif
  int flags = fcntl(fd, F_GETFL, 0);
  return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}
#endif

MOONBIT_FFI_EXPORT dd_socket *dd_tcp_open(moonbit_bytes_t host, int port, int server, int timeout, int limit) {
  dd_socket *s = dd_alloc(timeout, limit);
#if defined(_WIN32)
  s->error = ENOSYS;
#else
  char service[16];
  snprintf(service, sizeof(service), "%d", port);
  struct addrinfo hints; memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = server ? AI_PASSIVE : 0;
  struct addrinfo *addresses = NULL;
  int err = getaddrinfo((const char *)host, service, &hints, &addresses);
  if (err) { s->error = EINVAL; return s; }
  int64_t deadline = dd_now() + timeout;
  do {
    for (struct addrinfo *a = addresses; a; a = a->ai_next) {
      int fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
      if (fd < 0) { s->error = errno; continue; }
      if (dd_configure(fd)) { s->error = errno; close(fd); continue; }
      int result;
      if (server) {
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        result = bind(fd, a->ai_addr, a->ai_addrlen);
        if (!result) result = listen(fd, 128);
      } else {
        result = connect(fd, a->ai_addr, a->ai_addrlen);
        if (result && errno == EINPROGRESS) {
          result = dd_wait(fd, POLLOUT, deadline);
          if (!result) {
            int error = 0; socklen_t n = sizeof(error);
            result = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &n);
            if (!result && error) { errno = error; result = -1; }
          }
        }
      }
      if (!result) { s->fd = fd; s->error = 0; freeaddrinfo(addresses); return s; }
      s->error = errno; close(fd);
    }
    if (server || (s->error != ECONNREFUSED && s->error != EHOSTUNREACH && s->error != ENETUNREACH)) break;
    poll(NULL, 0, 10);
  } while (dd_now() < deadline);
  freeaddrinfo(addresses);
#endif
  return s;
}
MOONBIT_FFI_EXPORT dd_socket *dd_tcp_accept(dd_socket *listener) {
  dd_socket *s = dd_alloc(listener->timeout, listener->limit);
#if defined(_WIN32)
  s->error = ENOSYS;
#else
  if (listener->fd < 0) { s->error = EBADF; return s; }
  int64_t deadline = dd_now() + listener->timeout;
  for (;;) {
    if (dd_wait(listener->fd, POLLIN, deadline)) { s->error = errno; return s; }
    int fd = accept(listener->fd, NULL, NULL);
    if (fd >= 0) {
      if (dd_configure(fd)) { s->error = errno; close(fd); }
      else s->fd = fd;
      return s;
    }
    if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) { s->error = errno; return s; }
  }
#endif
  return s;
}
MOONBIT_FFI_EXPORT int dd_tcp_error(dd_socket *s) { return s->error; }
MOONBIT_FFI_EXPORT void dd_tcp_close(dd_socket *s) { dd_destroy(s); }
MOONBIT_FFI_EXPORT int dd_tcp_send(dd_socket *s, moonbit_bytes_t bytes) {
#if defined(_WIN32)
  dd_fail(s, ENOSYS); return -1;
#else
  if (s->fd < 0) { s->error = EBADF; return -1; }
  uint32_t length = Moonbit_array_length(bytes);
  if (length > (uint32_t)s->limit) { dd_fail(s, EMSGSIZE); return -1; }
  uint32_t header = htonl(length);
  int64_t deadline = dd_now() + s->timeout;
  if (dd_transfer(s, &header, sizeof(header), 1, deadline) || dd_transfer(s, bytes, length, 1, deadline)) {
    dd_fail(s, errno); return -1;
  }
  return 0;
#endif
}
MOONBIT_FFI_EXPORT moonbit_bytes_t dd_tcp_receive(dd_socket *s) {
#if defined(_WIN32)
  dd_fail(s, ENOSYS);
#else
  if (s->fd < 0) { s->error = EBADF; return moonbit_make_bytes(0, 0); }
  uint32_t header;
  int64_t deadline = dd_now() + s->timeout;
  if (dd_transfer(s, &header, sizeof(header), 0, deadline)) dd_fail(s, errno);
  else {
    uint32_t length = ntohl(header);
    if (length > (uint32_t)s->limit) dd_fail(s, EMSGSIZE);
    else {
      moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)length, 0);
      if (!dd_transfer(s, bytes, length, 0, deadline)) return bytes;
      moonbit_decref(bytes); dd_fail(s, errno);
    }
  }
#endif
  return moonbit_make_bytes(0, 0);
}
