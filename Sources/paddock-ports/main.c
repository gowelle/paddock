// paddock-ports: accepts connections on listening loopback TCP sockets and copies bytes to and
// from Paddock's two owner-only Unix sockets (http and https). The listening sockets come from
// launchd (`launchd` form, ports 80/443) or are bound here (`listen` form, development and tests).
// Everything after "these are the listening fds" is shared by both forms.
//
// Written in C because `launch_activate_socket` (<launch.h>) is not visible to Swift via Darwin.

#include <errno.h>
#include <fcntl.h>
#include <launch.h>
#include <limits.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

enum {
    EXIT_USAGE = 64,          // EX_USAGE
    EXIT_NO_LAUNCHD = 78,     // EX_CONFIG
    MAX_CONNECTIONS = 512,
    IDLE_SECONDS = 60,        // see `pump`
    BACKOFF_MICROSECONDS = 100 * 1000,
    BUFFER_SIZE = 64 * 1024,  // per direction; the only buffering, so memory stays bounded
    THREAD_STACK = 256 * 1024,
};

enum service { HTTP = 0, HTTPS = 1 };

struct listener {
    int fd;
    enum service service;
};

static const char *socket_paths[2];
static atomic_int active_connections;
// Fixed at MAX_CONNECTIONS and IDLE_SECONDS except in the `listen` form, whose hidden trailing
// arguments let tests use small values. Never read from the environment or a file.
static int max_connections = MAX_CONNECTIONS;
static int idle_seconds = IDLE_SECONDS;
static pthread_attr_t joinable_threads;  // the second direction of a connection
static pthread_attr_t detached_threads;  // one per connection

static _Noreturn void usage(void) {
    fputs("usage: paddock-ports launchd <http-socket-path> <https-socket-path>\n"
          "       paddock-ports listen <http-port> <https-port> <http-socket-path> <https-socket-path>\n",
          stderr);
    exit(EXIT_USAGE);
}

static _Noreturn void fatal(int status, const char *what, const char *detail) {
    fprintf(stderr, "paddock-ports: %s: %s\n", what, detail);
    exit(status);
}

static void set_option(int fd, int level, int name) {
    int on = 1;
    (void)setsockopt(fd, level, name, &on, sizeof on);
}

// MARK: - Copying

/// One direction of a connection. `discarding` means `to` can no longer take data; `done` means
/// this direction has finished. The two flags let either direction end the other's draining.
struct direction {
    int from, to;
    atomic_bool discarding, done;
    struct direction *other;
};

/// Writes everything; on failure returns false with `errno` set. With SO_SNDTIMEO, each `write`
/// waits at most the idle timeout for room, so EAGAIN means no progress for that long.
static bool write_all(int fd, const char *bytes, size_t count) {
    while (count > 0) {
        ssize_t n = write(fd, bytes, count);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        bytes += n;
        count -= (size_t)n;
    }
    return true;
}

/// Copies `from` to `to` with blocking I/O: while a write blocks, nothing more is read from
/// `from`, which is the back-pressure. Ends on EOF (propagated as a half-close) or on an error.
/// Reads wake every `idle_seconds`; once the other direction has ended, a read that waits that
/// long with no data ends this direction too, so a peer that never closes cannot hold a slot.
/// While both directions are open, idle reads are unlimited (a slow request is not cut off).
/// A write that makes no progress for `idle_seconds` means a dead or stuck peer at any time:
/// the whole connection is torn down.
static void pump(struct direction *d) {
    char buffer[BUFFER_SIZE];
    struct timeval idle = { .tv_sec = idle_seconds };
    (void)setsockopt(d->from, SOL_SOCKET, SO_RCVTIMEO, &idle, sizeof idle);
    (void)setsockopt(d->to, SOL_SOCKET, SO_SNDTIMEO, &idle, sizeof idle);
    for (;;) {
        ssize_t n = read(d->from, buffer, sizeof buffer);
        if (n > 0) {
            if (atomic_load(&d->discarding)) continue;
            if (write_all(d->to, buffer, (size_t)n)) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                // Stuck peer: end both directions; the other pump wakes on the shutdowns.
                shutdown(d->from, SHUT_RDWR);
                shutdown(d->to, SHUT_RDWR);
                break;
            }
            // `to` is gone. Keep draining `from` so its peer cannot block the other direction
            // (data `to` already sent us is still delivered there), unless that direction ended.
            atomic_store(&d->discarding, true);
            if (atomic_load(&d->other->done)) break;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (!atomic_load(&d->other->done)) continue;
            n = 0;  // idle after the other direction ended: finish as if `from` had closed
        }
        if (n == 0) {
            shutdown(d->to, SHUT_WR);
        } else {
            // `from` failed (reset): both sockets are finished; wake the other direction.
            shutdown(d->from, SHUT_RDWR);
            shutdown(d->to, SHUT_RDWR);
        }
        break;
    }
    atomic_store(&d->done, true);
    // The other direction drains a source nobody can receive: end it.
    if (atomic_load(&d->other->discarding)) shutdown(d->other->from, SHUT_RDWR);
}

static void *pump_thread(void *argument) {
    pump(argument);
    return NULL;
}

static int connect_upstream(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    set_option(fd, SOL_SOCKET, SO_NOSIGPIPE);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strlcpy(address.sun_path, path, sizeof address.sun_path);
    address.sun_len = (unsigned char)SUN_LEN(&address);
    if (connect(fd, (struct sockaddr *)&address, address.sun_len) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

struct connection {
    int client;
    enum service service;
};

static void *serve(void *argument) {
    struct connection *connection = argument;
    int client = connection->client;
    int upstream = connect_upstream(socket_paths[connection->service]);
    free(connection);

    if (upstream >= 0) {
        struct direction up = { .from = client, .to = upstream };
        struct direction down = { .from = upstream, .to = client };
        up.other = &down;
        down.other = &up;
        pthread_t thread;
        if (pthread_create(&thread, &joinable_threads, pump_thread, &up) == 0) {
            pump(&down);
            pthread_join(thread, NULL);
        }
        close(upstream);
    }
    close(client);
    atomic_fetch_sub(&active_connections, 1);
    return NULL;
}

// MARK: - Accepting

static void accept_one(const struct listener *listener) {
    int client = accept(listener->fd, NULL, NULL);
    if (client < 0) {
        // Out of descriptors or memory: wait a little instead of spinning on a ready listener.
        if (errno == EMFILE || errno == ENFILE || errno == ENOBUFS || errno == ENOMEM) usleep(BACKOFF_MICROSECONDS);
        return;
    }
    int flags = fcntl(client, F_GETFL);
    if (flags >= 0) (void)fcntl(client, F_SETFL, flags & ~O_NONBLOCK);
    set_option(client, SOL_SOCKET, SO_NOSIGPIPE);
    set_option(client, IPPROTO_TCP, TCP_NODELAY);

    if (atomic_fetch_add(&active_connections, 1) >= max_connections) goto refuse;
    struct connection *connection = malloc(sizeof *connection);
    if (connection == NULL) goto refuse;
    connection->client = client;
    connection->service = listener->service;
    pthread_t thread;
    if (pthread_create(&thread, &detached_threads, serve, connection) == 0) return;
    free(connection);
refuse:
    atomic_fetch_sub(&active_connections, 1);
    close(client);
}

static void serve_forever(const struct listener *listeners, int count) {
    struct pollfd *polled = calloc((size_t)count, sizeof *polled);
    if (polled == NULL) fatal(1, "startup", strerror(ENOMEM));
    for (int i = 0; i < count; i++) {
        int flags = fcntl(listeners[i].fd, F_GETFL);
        if (flags >= 0) (void)fcntl(listeners[i].fd, F_SETFL, flags | O_NONBLOCK);
        polled[i] = (struct pollfd){ .fd = listeners[i].fd, .events = POLLIN };
    }
    fprintf(stderr, "paddock-ports: forwarding %d listening sockets to %s and %s\n",
            count, socket_paths[HTTP], socket_paths[HTTPS]);
    for (;;) {
        if (poll(polled, (nfds_t)count, -1) < 0) {
            if (errno == EINTR) continue;
            // Darwin's poll can fail with EAGAIN transiently under memory pressure.
            if (errno == EAGAIN) { usleep(BACKOFF_MICROSECONDS); continue; }
            fatal(1, "poll", strerror(errno));
        }
        bool only_errors = false;
        for (int i = 0; i < count; i++) {
            short events = polled[i].revents;
            if (events & POLLNVAL) fatal(1, "listening socket", "closed unexpectedly");
            if (events & POLLIN) accept_one(&listeners[i]);
            else if (events & (POLLERR | POLLHUP)) only_errors = true;
        }
        // A listener in an error state stays "ready": wait instead of spinning on it.
        if (only_errors) usleep(BACKOFF_MICROSECONDS);
    }
}

// MARK: - Obtaining listening sockets

/// `launchd` form: the sockets launchd opened for the job's `http` and `https` entries.
static int launchd_listeners(struct listener **out) {
    static const char *names[2] = { "http", "https" };
    int *fds[2] = { NULL, NULL };
    size_t counts[2] = { 0, 0 };
    for (int s = HTTP; s <= HTTPS; s++) {
        int error = launch_activate_socket(names[s], &fds[s], &counts[s]);
        if (error != 0 || counts[s] == 0) {
            fprintf(stderr, "paddock-ports: launchd provided no \"%s\" sockets (%s); "
                    "this form only works as a launchd job\n", names[s], strerror(error ? error : ENOENT));
            exit(EXIT_NO_LAUNCHD);
        }
    }
    int total = (int)(counts[HTTP] + counts[HTTPS]);
    struct listener *listeners = calloc((size_t)total, sizeof *listeners);
    if (listeners == NULL) fatal(1, "startup", strerror(ENOMEM));
    int n = 0;
    for (int s = HTTP; s <= HTTPS; s++) {
        for (size_t i = 0; i < counts[s]; i++) listeners[n++] = (struct listener){ fds[s][i], (enum service)s };
        free(fds[s]);
    }
    *out = listeners;
    return total;
}

static int listen_on(int family, const char *address, int port) {
    int fd = socket(family, SOCK_STREAM, 0);
    int status = -1;
    int error = errno;
    if (fd >= 0) {
        set_option(fd, SOL_SOCKET, SO_REUSEADDR);
        if (family == AF_INET6) {
            set_option(fd, IPPROTO_IPV6, IPV6_V6ONLY);
            struct sockaddr_in6 sa = { .sin6_len = sizeof sa, .sin6_family = AF_INET6,
                                       .sin6_port = htons((in_port_t)port), .sin6_addr = in6addr_loopback };
            status = bind(fd, (struct sockaddr *)&sa, sizeof sa);
        } else {
            struct sockaddr_in sa = { .sin_len = sizeof sa, .sin_family = AF_INET,
                                      .sin_port = htons((in_port_t)port),
                                      .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
            status = bind(fd, (struct sockaddr *)&sa, sizeof sa);
        }
        if (status == 0) status = listen(fd, SOMAXCONN);
        error = errno;
    }
    if (status != 0) {
        char what[64];
        snprintf(what, sizeof what, "cannot listen on %s port %d", address, port);
        fatal(1, what, strerror(error));
    }
    return fd;
}

/// `listen` form: binds 127.0.0.1 and ::1 on both ports.
static int bound_listeners(const int ports[2], struct listener **out) {
    static struct listener listeners[4];
    int n = 0;
    for (int s = HTTP; s <= HTTPS; s++) {
        listeners[n++] = (struct listener){ listen_on(AF_INET, "127.0.0.1", ports[s]), (enum service)s };
        listeners[n++] = (struct listener){ listen_on(AF_INET6, "::1", ports[s]), (enum service)s };
    }
    *out = listeners;
    return n;
}

// MARK: - Startup

/// A decimal number in [minimum, maximum], or a usage error.
static int parse_number(const char *text, int minimum, int maximum) {
    if (*text == '\0' || strlen(text) > 5) usage();
    for (const char *c = text; *c; c++) if (*c < '0' || *c > '9') usage();
    int value = atoi(text);
    if (value < minimum || value > maximum) usage();
    return value;
}

static void check_socket_path(const char *path) {
    if (*path == '\0') usage();
    if (strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        fprintf(stderr, "paddock-ports: unix socket path too long (%zu bytes, limit %zu): %s\n",
                strlen(path), sizeof(((struct sockaddr_un *)0)->sun_path) - 1, path);
        exit(1);
    }
}

static void exit_on_sigterm(int signal) {
    (void)signal;
    _exit(0);
}

/// Each connection uses two descriptors; launchd jobs start with a soft limit of 256.
static void raise_descriptor_limit(void) {
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) != 0) return;
    rlim_t wanted = limit.rlim_max < OPEN_MAX ? limit.rlim_max : OPEN_MAX;
    if (limit.rlim_cur < wanted) {
        limit.rlim_cur = wanted;
        (void)setrlimit(RLIMIT_NOFILE, &limit);
    }
}

int main(int argc, char *argv[]) {
    bool from_launchd;
    int ports[2] = { 0, 0 };
    if (argc == 4 && strcmp(argv[1], "launchd") == 0) {
        from_launchd = true;
        socket_paths[HTTP] = argv[2];
        socket_paths[HTTPS] = argv[3];
    } else if (argc >= 6 && argc <= 8 && strcmp(argv[1], "listen") == 0) {
        from_launchd = false;
        ports[HTTP] = parse_number(argv[2], 1, 65535);
        ports[HTTPS] = parse_number(argv[3], 1, 65535);
        socket_paths[HTTP] = argv[4];
        socket_paths[HTTPS] = argv[5];
        // Hidden, for tests only: [idle-seconds [max-connections]], never above the defaults.
        if (argc >= 7) idle_seconds = parse_number(argv[6], 1, IDLE_SECONDS);
        if (argc == 8) max_connections = parse_number(argv[7], 1, MAX_CONNECTIONS);
    } else {
        usage();
    }
    check_socket_path(socket_paths[HTTP]);
    check_socket_path(socket_paths[HTTPS]);

    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, exit_on_sigterm);
    raise_descriptor_limit();
    pthread_attr_init(&joinable_threads);
    pthread_attr_setstacksize(&joinable_threads, THREAD_STACK);
    pthread_attr_init(&detached_threads);
    pthread_attr_setstacksize(&detached_threads, THREAD_STACK);
    pthread_attr_setdetachstate(&detached_threads, PTHREAD_CREATE_DETACHED);

    struct listener *listeners;
    int count = from_launchd ? launchd_listeners(&listeners) : bound_listeners(ports, &listeners);
    serve_forever(listeners, count);
    return 0;
}
