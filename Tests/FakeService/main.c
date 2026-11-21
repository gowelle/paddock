// A stand-in service for Paddock's service framework tests. Not shipped.
//
//   paddock-fake-service init <data> [fail-message]
//       Writes <data>/initialised, or prints fail-message and exits 3.
//   paddock-fake-service serve <data> [--port N]... [--socket PATH] [--delay MS] [--no-listen]
//       Records its arguments in <data>/args (one per line), then after --delay milliseconds listens on
//       127.0.0.1 on every --port (and on the Unix socket, if a non-empty path is given). Answers any
//       connection with "HTTP/1.0 200 OK" and closes it. Exits 0 on SIGTERM or SIGINT, writing
//       <data>/stopped.

#include <arpa/inet.h>
#include <errno.h>
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

static int listen_tcp(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_len = sizeof addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
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
    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc && nports < 8) ports[nports++] = atoi(argv[++i]);
        else if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) socket_path = argv[++i];
        else if (strcmp(argv[i], "--delay") == 0 && i + 1 < argc) delay_ms = atoi(argv[++i]);
        else if (strcmp(argv[i], "--no-listen") == 0) no_listen = 1;
    }

    char args[16384] = "";
    for (int i = 0; i < argc; i++) {
        strlcat(args, argv[i], sizeof args);
        strlcat(args, "\n", sizeof args);
    }
    write_file(data, "args", args);

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

    while (!stop_requested) {
        int n = poll(fds, (nfds_t)nfds, 200);
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

int main(int argc, char **argv) {
    if (argc >= 3 && strcmp(argv[1], "init") == 0) {
        if (argc >= 4) {
            printf("%s\n", argv[3]);
            return 3;
        }
        return write_file(argv[2], "initialised", "yes\n") == 0 ? 0 : 1;
    }
    if (argc >= 3 && strcmp(argv[1], "serve") == 0) return serve(argc, argv);
    fprintf(stderr, "usage: paddock-fake-service init|serve <data> ...\n");
    return 64;
}
