#define _GNU_SOURCE
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#include "latency_process.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#include <poll.h>
#endif

static void write_config(const char *path, const char *mode)
{
    FILE *file = fopen(path, "w"); assert(file);
    assert(fputs(mode, file) >= 0);
    assert(fclose(file) == 0);
}

static void *stop_concurrently(void *value)
{
    const uint64_t id = *(uint64_t *)value;
    const int error = honeyproxy_latency_stop(id, 1000);
    assert(error == 0 || error == ENOENT);
    return NULL;
}

int main(int argc, char **argv)
{
    if (argc == 4 && strcmp(argv[1], "run") == 0) {
        FILE *config = fopen(argv[3], "r");
        if (config == NULL) return 80;
        char mode[64];
        if (fgets(mode, sizeof(mode), config) == NULL) return 81;
        fclose(config);
        if (strncmp(mode, "quick", 5) == 0) return 7;
        if (strncmp(mode, "fd:", 3) == 0) {
            const int fd = atoi(mode + 3);
            return fcntl(fd, F_GETFD) == -1 && errno == EBADF ? 8 : 82;
        }
        if (strncmp(mode, "hang-pid", 8) == 0) {
            FILE *marker = fopen("child.pid", "w");
            if (marker == NULL) return 83;
            fprintf(marker, "%d", getpid());
            fclose(marker);
        }
        for (;;) pause();
    }
    char binary[4096]; assert(realpath(argv[0], binary));
    char root[] = "/tmp/honey-latency-native-XXXXXX"; assert(mkdtemp(root));
    char path[4096]; snprintf(path, sizeof(path), "%s/config.json", root);
    write_config(path, "hang");
    const pid_t foreign = fork(); assert(foreign >= 0);
    if (foreign == 0) { for (;;) pause(); }
    for (int cycle = 0; cycle < 100; cycle++) {
        const uint64_t id = honeyproxy_latency_start(binary, path, root); assert(id);
        int exited, code;
        assert(honeyproxy_latency_status(id, &exited, &code) == 0);
        assert(!exited);
        pthread_t one, two;
        assert(pthread_create(&one, NULL, stop_concurrently, (void *)&id) == 0);
        assert(pthread_create(&two, NULL, stop_concurrently, (void *)&id) == 0);
        assert(pthread_join(one, NULL) == 0 && pthread_join(two, NULL) == 0);
        assert(honeyproxy_latency_status(id, &exited, &code) == ENOENT);
        assert(kill(foreign, 0) == 0);
    }
    puts("PASS 100 concurrent opaque-ID retirements; foreign child survives");
    write_config(path, "quick");
    for (int cycle = 0; cycle < 100; cycle++) {
        const uint64_t id = honeyproxy_latency_start(binary, path, root); assert(id);
        int exited = 0, code;
        for (int attempt = 0; !exited && attempt < 3000; attempt++) {
            assert(honeyproxy_latency_status(id, &exited, &code) == 0);
            if (!exited) usleep(1000);
        }
        assert(exited && code == 7);
        assert(honeyproxy_latency_stop(id, 1000) == 0);
        assert(kill(foreign, 0) == 0);
    }
    puts("PASS 100 natural exits; reaped PID cleared before late cleanup");
    const int parent_fd = open(path, O_RDONLY); assert(parent_fd >= 3);
    const int sentinel = fcntl(parent_fd, F_DUPFD, 100); assert(sentinel >= 100);
    char mode[64]; snprintf(mode, sizeof(mode), "fd:%d", sentinel);
    write_config(path, mode);
    const uint64_t fd_id = honeyproxy_latency_start(binary, path, root); assert(fd_id);
    int exited = 0, code;
    for (int attempt = 0; !exited && attempt < 3000; attempt++) {
        assert(honeyproxy_latency_status(fd_id, &exited, &code) == 0);
        if (!exited) usleep(1000);
    }
    assert(exited && code == 8);
    assert(fcntl(sentinel, F_GETFD) >= 0); // Child-only closure preserves parent's FD.
    assert(honeyproxy_latency_stop(fd_id, 1000) == 0);
    close(sentinel); close(parent_fd);
    puts("PASS child cannot inherit unrelated parent/TUN-like descriptor");
    write_config(path, "hang");
    uint64_t ids[4];
    for (int i = 0; i < 4; i++) { ids[i] = honeyproxy_latency_start(binary, path, root); assert(ids[i]); }
    assert(honeyproxy_latency_start(binary, path, root) == 0);
    for (int i = 0; i < 4; i++) assert(honeyproxy_latency_stop(ids[i], 1000) == 0);
    assert(honeyproxy_latency_stop(99999999, 1000) == ENOENT);
    puts("PASS native cap four and unknown-ID rejection");
#if defined(__linux__) && defined(SYS_pidfd_open)
    write_config(path, "hang-pid");
    char child_marker[4096], leave_marker[4096];
    snprintf(child_marker, sizeof(child_marker), "%s/child.pid", root);
    snprintf(leave_marker, sizeof(leave_marker), "%s/leave", root);
    const pid_t helper = fork(); assert(helper >= 0);
    if (helper == 0) {
        assert(honeyproxy_latency_start(binary, path, root));
        for (int i = 0; access(leave_marker, F_OK) != 0 && i < 5000; i++) usleep(1000);
        _exit(0); // No destructor/cleanup: the kernel's PDEATHSIG must retire core.
    }
    pid_t owned_pid = 0;
    for (int i = 0; owned_pid == 0 && i < 5000; i++) {
        FILE *marker = fopen(child_marker, "r");
        if (marker != NULL) { if (fscanf(marker, "%d", &owned_pid) != 1) owned_pid = 0; fclose(marker); }
        if (owned_pid == 0) usleep(1000);
    }
    assert(owned_pid > 0);
    const int observer = (int)syscall(SYS_pidfd_open, owned_pid, 0);
    write_config(leave_marker, "exit");
    assert(waitpid(helper, NULL, 0) == helper);
    if (observer >= 0) {
        struct pollfd observed = {observer, POLLIN, 0};
        assert(poll(&observed, 1, 3000) == 1 && (observed.revents & POLLIN));
        close(observer);
        puts("PASS abrupt parent death retires native core via PDEATHSIG");
    } else puts("SKIP pidfd observer unavailable; parent-death regression requires modern host kernel");
    unlink(child_marker); unlink(leave_marker);
#endif
    kill(foreign, SIGKILL); assert(waitpid(foreign, NULL, 0) == foreign);
    unlink(path); rmdir(root);
    return 0;
}
