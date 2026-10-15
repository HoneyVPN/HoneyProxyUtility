#define _GNU_SOURCE
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#include "latency_process.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/prctl.h>
#include <sys/syscall.h>
#endif

typedef struct {
    uint64_t id;
    pid_t pid;
    int exited;
    int exit_code;
} latency_child;

static pthread_mutex_t registry_lock = PTHREAD_MUTEX_INITIALIZER;
static latency_child children[4];
static uint64_t next_id;

static long long now_ms(void)
{
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (long long)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

static void pause_poll(void)
{
    struct timespec delay = {0, 10000000};
    while (nanosleep(&delay, &delay) < 0 && errno == EINTR) {}
}

static latency_child *find(uint64_t id)
{
    if (id == 0) return NULL;
    for (unsigned i = 0; i < 4; i++) if (children[i].id == id) return &children[i];
    return NULL;
}

static int refresh(latency_child *child)
{
    if (child->exited) return 0;
    int status;
    pid_t result;
    do { result = waitpid(child->pid, &status, WNOHANG); }
    while (result < 0 && errno == EINTR);
    if (result == 0) return 0;
    if (result < 0) return errno;
    child->exited = 1;
    child->exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    // Clear the PID in the same lock as reaping. A late opaque-ID stop cannot
    // signal a later child that happened to receive the recycled numeric PID.
    child->pid = 0;
    return 0;
}

static void close_other_fds(int keep, unsigned maximum)
{
#if defined(__linux__) && defined(SYS_close_range)
    if ((keep <= 3 || syscall(SYS_close_range, 3u, (unsigned)keep - 1u, 0u) == 0) &&
        syscall(SYS_close_range, (unsigned)keep + 1u, ~0u, 0u) == 0) return;
#endif
    for (unsigned fd = 3; fd < maximum; fd++) if ((int)fd != keep) close((int)fd);
}

uint64_t honeyproxy_latency_start(const char *binary, const char *config, const char *directory)
{
    if (binary == NULL || config == NULL || directory == NULL) return 0;
    pthread_mutex_lock(&registry_lock);
    latency_child *slot = NULL;
    for (unsigned i = 0; i < 4; i++) if (children[i].id == 0) { slot = &children[i]; break; }
    if (slot == NULL) { pthread_mutex_unlock(&registry_lock); return 0; }
    const int config_fd = open(config, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    struct stat attributes;
    if (config_fd < 0 || fstat(config_fd, &attributes) != 0 || !S_ISREG(attributes.st_mode)) {
        if (config_fd >= 0) close(config_fd);
        pthread_mutex_unlock(&registry_lock);
        return 0;
    }
    const int null_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (null_fd < 0) { close(config_fd); pthread_mutex_unlock(&registry_lock); return 0; }
    char owned_config[64];
#if defined(__linux__)
    snprintf(owned_config, sizeof(owned_config), "/proc/self/fd/%d", config_fd);
#else
    snprintf(owned_config, sizeof(owned_config), "/dev/fd/%d", config_fd);
#endif
    struct rlimit limit;
    unsigned max_fd = 65536;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur < 1048576)
        max_fd = (unsigned)limit.rlim_cur;
    const pid_t parent = getpid();
    const pid_t pid = fork();
    if (pid == 0) {
#if defined(__linux__)
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != parent) _exit(126);
#else
        (void)parent;
#endif
        if (dup2(null_fd, STDIN_FILENO) < 0 || dup2(null_fd, STDOUT_FILENO) < 0 ||
            dup2(null_fd, STDERR_FILENO) < 0 || chdir(directory) < 0 ||
            fcntl(config_fd, F_SETFD, 0) < 0) _exit(126);
        close_other_fds(config_fd, max_fd);
        execl(binary, "libsingbox.so", "run", "-c", owned_config, (char *)NULL);
        _exit(127);
    }
    close(config_fd);
    close(null_fd);
    uint64_t id = 0;
    if (pid > 0) {
        id = ++next_id;
        if (id == 0) id = ++next_id;
        *slot = (latency_child){id, pid, 0, 0};
    }
    pthread_mutex_unlock(&registry_lock);
    return id;
}

int honeyproxy_latency_status(uint64_t id, int *exited, int *exit_code)
{
    pthread_mutex_lock(&registry_lock);
    latency_child *child = find(id);
    int result = child == NULL ? ENOENT : refresh(child);
    if (result == 0) {
        *exited = child->exited;
        *exit_code = child->exit_code;
    }
    pthread_mutex_unlock(&registry_lock);
    return result;
}

int honeyproxy_latency_stop(uint64_t id, int timeout_ms)
{
    if (timeout_ms <= 0) return ETIMEDOUT;
    const long long deadline = now_ms() + timeout_ms;
    int locked;
    while ((locked = pthread_mutex_trylock(&registry_lock)) != 0) {
        if (locked != EBUSY) return locked;
        if (now_ms() >= deadline) return ETIMEDOUT;
        pause_poll();
    }
    latency_child *child = find(id);
    int result = child == NULL ? ENOENT : refresh(child);
    if (result == 0 && !child->exited) {
        // The registry's unreaped direct child retains this PID until the exact
        // wait below. Every status and stop for these children holds this lock.
        if (kill(child->pid, SIGKILL) != 0 && errno != ESRCH) result = errno;
        while (result == 0 && !child->exited) {
            result = refresh(child);
            if (result != 0 || child->exited) break;
            if (now_ms() >= deadline) { result = ETIMEDOUT; break; }
            pause_poll();
        }
    }
    if (result == 0) *child = (latency_child){0};
    pthread_mutex_unlock(&registry_lock);
    return result;
}
