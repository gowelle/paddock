// A stand-in service for Paddock's service framework tests. Not shipped.
//
//   paddock-fake-service init <data> [--fail MSG] [--ignore-term] [--sleep S] [--grandchild]
//       Writes <data>/initialised, or prints MSG and exits 3. --ignore-term ignores SIGTERM; --sleep waits
//       S seconds first; --grandchild leaves a child holding stdout for 60 seconds. Never reads stdin.
//   paddock-fake-service serve <data> [--port N]... [--socket PATH] [--delay MS] [--no-listen] [--any-address]
//       Records its arguments in <data>/args (one per line), its environment in <data>/env and its working
//       directory in <data>/cwd, then after
//       --delay milliseconds listens on 127.0.0.1 (0.0.0.0 with --any-address) on every --port (and on the
//       Unix socket, if a non-empty path is given). Answers any connection with "HTTP/1.0 200 OK" and closes
//       it. Exits 0 on SIGTERM or SIGINT, writing <data>/stopped.
//       More serve options: --fork-child (a child in the same group serves too, and stays when the leader
//       dies); --poison-data (writes <data>/poison); --refuse-poison (exits 4 at once if <data>/poison exists);
//       --late-listen PORT --late-delay MS (after MS milliseconds also listens on 0.0.0.0:PORT).
//   paddock-fake-service action <data> <value>
//       Like createdb: creates <data>/made-<value> and prints "made <value>"; if it is there already, prints
//       `"<value>" already exists` and exits 1. Also records its working directory in <data>/action-cwd.
//   paddock-fake-service spawn-orphan <program> [args...]
//       Starts <program> as the leader of a new session and exits at once, printing its pid: an orphan of
//       launchd, like a service whose daemon died.

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static volatile sig_atomic_t stop_requested = 0;

static void on_stop(int sig) {
    (void)sig;
    stop_requested = 1;
}

static int write_file(const char *dir, const char *name, const char *text) {
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    fputs(text, f);
    fclose(f);
    return 0;
}

extern char **environ;
static int any_address = 0;

static int listen_tcp(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_len = sizeof addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    addr.sin_addr.s_addr = any_address ? htonl(INADDR_ANY) : inet_addr("127.0.0.1");
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(fd, 16) != 0) {
        fprintf(stderr, "fake-service: cannot listen on 127.0.0.1:%d: %s\n", port, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static int listen_unix(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof addr.sun_path) { close(fd); return -1; }
    strcpy(addr.sun_path, path);
    unlink(path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(fd, 16) != 0) {
        fprintf(stderr, "fake-service: cannot listen on %s: %s\n", path, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static int serve(int argc, char **argv) {
    const char *data = argv[2];
    int ports[8];
    int nports = 0;
    const char *socket_path = NULL;
    int delay_ms = 0;
    int no_listen = 0;
    int fork_child = 0, poison = 0, refuse_poison = 0, late_port = 0, late_delay = 0;
    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc && nports < 8) ports[nports++] = atoi(argv[++i]);
        else if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) socket_path = argv[++i];
        else if (strcmp(argv[i], "--delay") == 0 && i + 1 < argc) delay_ms = atoi(argv[++i]);
        else if (strcmp(argv[i], "--no-listen") == 0) no_listen = 1;
        else if (strcmp(argv[i], "--any-address") == 0) any_address = 1;
        else if (strcmp(argv[i], "--fork-child") == 0) fork_child = 1;
        else if (strcmp(argv[i], "--poison-data") == 0) poison = 1;
        else if (strcmp(argv[i], "--refuse-poison") == 0) refuse_poison = 1;
        else if (strcmp(argv[i], "--late-listen") == 0 && i + 1 < argc) late_port = atoi(argv[++i]);
        else if (strcmp(argv[i], "--late-delay") == 0 && i + 1 < argc) late_delay = atoi(argv[++i]);
    }
    if (refuse_poison) {
        char marker[4096];
        snprintf(marker, sizeof marker, "%s/poison", data);
        if (access(marker, F_OK) == 0) {
            printf("fake-service: refusing data poisoned by a newer version\n");
            return 4;
        }
    }
    if (poison) write_file(data, "poison", "yes\n");

    char args[16384] = "";
    for (int i = 0; i < argc; i++) {
        strlcat(args, argv[i], sizeof args);
        strlcat(args, "\n", sizeof args);
    }
    write_file(data, "args", args);
    char env[16384] = "";
    for (char **e = environ; *e; e++) {
        strlcat(env, *e, sizeof env);
        strlcat(env, "\n", sizeof env);
    }
    write_file(data, "env", env);
    char cwd[4096];
    if (getcwd(cwd, sizeof cwd)) write_file(data, "cwd", cwd);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_stop;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    printf("fake-service: starting (pid %d)\n", getpid());
    fflush(stdout);
    for (int waited = 0; waited < delay_ms && !stop_requested; waited += 10) usleep(10000);

    struct pollfd fds[9];
    int nfds = 0;
    if (!no_listen) {
        for (int i = 0; i < nports; i++) {
            int fd = listen_tcp(ports[i]);
            if (fd < 0) return 2;
            fds[nfds++] = (struct pollfd){ .fd = fd, .events = POLLIN };
        }
        if (socket_path && socket_path[0]) {
            int fd = listen_unix(socket_path);
            if (fd < 0) return 2;
            fds[nfds++] = (struct pollfd){ .fd = fd, .events = POLLIN };
        }
        printf("fake-service: ready\n");
        fflush(stdout);
    }
    if (fork_child && fork() == 0) {
        printf("fake-service: child %d serving\n", getpid());
        fflush(stdout);
    }
    int late_fd = -1;
    struct timespec started;
    clock_gettime(CLOCK_MONOTONIC, &started);

    while (!stop_requested) {
        if (late_port && late_fd < 0) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            long elapsed = (now.tv_sec - started.tv_sec) * 1000 + (now.tv_nsec - started.tv_nsec) / 1000000;
            if (elapsed >= late_delay) {
                any_address = 1;
                late_fd = listen_tcp(late_port);
                if (late_fd >= 0) fds[nfds++] = (struct pollfd){ .fd = late_fd, .events = POLLIN };
            }
        }
        int n = poll(fds, (nfds_t)nfds, 100);
        if (n <= 0) continue;
        for (int i = 0; i < nfds; i++) {
            if (!(fds[i].revents & POLLIN)) continue;
            int client = accept(fds[i].fd, NULL, NULL);
            if (client < 0) continue;
            const char *reply = "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok";
            write(client, reply, strlen(reply));
            close(client);
        }
    }
    if (socket_path && socket_path[0]) unlink(socket_path);
    write_file(data, "stopped", "yes\n");
    printf("fake-service: stopped\n");
    return 0;
}

static int init(int argc, char **argv) {
    const char *fail = NULL;
    int sleep_seconds = 0;
    int grandchild = 0;
    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--fail") == 0 && i + 1 < argc) fail = argv[++i];
        else if (strcmp(argv[i], "--ignore-term") == 0) signal(SIGTERM, SIG_IGN);
        else if (strcmp(argv[i], "--sleep") == 0 && i + 1 < argc) sleep_seconds = atoi(argv[++i]);
        else if (strcmp(argv[i], "--grandchild") == 0) grandchild = 1;
    }
    printf("fake-service: initialising\n");
    fflush(stdout);
    if (grandchild && fork() == 0) {
        sleep(60); // keeps stdout open
        _exit(0);
    }
    if (sleep_seconds > 0) sleep((unsigned)sleep_seconds);
    if (fail) {
        printf("%s\n", fail);
        return 3;
    }
    return write_file(argv[2], "initialised", "yes\n") == 0 ? 0 : 1;
}

static int action(char **argv) {
    char name[4096];
    snprintf(name, sizeof name, "made-%s", argv[3]);
    char path[8192];
    snprintf(path, sizeof path, "%s/%s", argv[2], name);
    char cwd[4096];
    if (getcwd(cwd, sizeof cwd)) write_file(argv[2], "action-cwd", cwd);
    if (access(path, F_OK) == 0) {
        printf("\"%s\" already exists\n", argv[3]);
        return 1;
    }
    if (write_file(argv[2], name, "yes\n") != 0) return 2;
    printf("made %s\n", argv[3]);
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 4 && strcmp(argv[1], "action") == 0) return action(argv);
    if (argc >= 3 && strcmp(argv[1], "init") == 0) return init(argc, argv);
    if (argc >= 3 && strcmp(argv[1], "serve") == 0) return serve(argc, argv);
    if (argc >= 3 && strcmp(argv[1], "spawn-orphan") == 0) {
        pid_t child = fork();
        if (child == 0) {
            setsid();
            int null = open("/dev/null", O_RDWR);
            dup2(null, 0); dup2(null, 1); dup2(null, 2);
            execv(argv[2], argv + 2);
            _exit(127);
        }
        printf("%d\n", child);
        return child > 0 ? 0 : 1;
    }
    fprintf(stderr, "usage: paddock-fake-service init|serve <data> ...\n");
    return 64;
}
