#include "owned_child.h"
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static pthread_mutex_t child_lock = PTHREAD_MUTEX_INITIALIZER;

struct honeyproxy_child_status honeyproxy_observe_owned_child(pid_t pid)
{
    struct honeyproxy_child_status result = {HONEY_CHILD_UNKNOWN, 0, 0, 0};
    /* P_PID with zero/negative values must never become a wildcard query. */
    if (pid <= 0) {
        result.kind = HONEY_CHILD_OWNER_LOST;
        result.error_code = ECHILD;
        return result;
    }
    const int locked = pthread_mutex_trylock(&child_lock);
    if (locked != 0) {
        result.error_code = locked;
        return result;
    }
    siginfo_t info = {0};
    int waited = -1;
    int error = 0;
    for (int attempt = 0; attempt < 3; ++attempt) {
        info = (siginfo_t){0};
        waited = waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT);
        if (waited == 0) break;
        error = errno;
        if (error != EINTR) break;
    }
    if (waited < 0) {
        result.kind = error == ECHILD ? HONEY_CHILD_OWNER_LOST : HONEY_CHILD_UNKNOWN;
        result.error_code = error;
    } else if (info.si_pid == 0) {
        result.kind = HONEY_CHILD_RUNNING;
    } else if (info.si_pid != pid || info.si_signo != SIGCHLD) {
        result.error_code = EPROTO;
    } else if (info.si_code == CLD_EXITED && info.si_status >= 0 && info.si_status <= 255) {
        result.kind = HONEY_CHILD_EXITED;
        result.exit_code = info.si_status;
    } else if ((info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED) &&
               info.si_status > 0 && info.si_status <= 128) {
        result.kind = HONEY_CHILD_SIGNALED;
        result.signal_number = info.si_status;
    } else {
        result.error_code = EPROTO;
    }
    const int unlocked = pthread_mutex_unlock(&child_lock);
    if (unlocked != 0) {
        result = (struct honeyproxy_child_status){HONEY_CHILD_UNKNOWN, 0, 0, unlocked};
    }
    return result;
}

void honeyproxy_report_launch_failure(int output_fd, int stage, int error_code)
{
    if (output_fd < 0) return;
    const char *prefix = stage == HONEY_LAUNCH_EXEC
        ? "HONEY_FORWARDER_FAILURE stage=exec errno="
        : stage == HONEY_LAUNCH_FD
        ? "HONEY_FORWARDER_FAILURE stage=fd errno="
        : "HONEY_FORWARDER_FAILURE stage=stdio errno=";
    char message[80];
    size_t length = 0;
    for (size_t i = 0; prefix[i] != '\0'; ++i) message[length++] = prefix[i];
    if (error_code <= 0 || error_code > 4095) error_code = EINVAL;
    char digits[4];
    size_t count = 0;
    do {
        digits[count++] = (char)('0' + error_code % 10);
        error_code /= 10;
    } while (error_code > 0);
    while (count > 0) message[length++] = digits[--count];
    message[length++] = '\n';
    size_t written = 0;
    for (int attempt = 0; written < length && attempt < 4; ++attempt) {
        const ssize_t n = write(output_fd, message + written, length - written);
        if (n > 0) written += (size_t)n;
        else if (n < 0 && errno == EINTR) continue;
        else break;
    }
}

#ifdef HONEY_OWNED_CHILD_TESTING
int honeyproxy_test_hold_child_lock(void) { return pthread_mutex_lock(&child_lock); }
int honeyproxy_test_release_child_lock(void) { return pthread_mutex_unlock(&child_lock); }
#endif

static pid_t wait_child(pid_t pid, int options)
{
    pid_t result;
    do { result = waitpid(pid, NULL, options); } while (result < 0 && errno == EINTR);
    return result;
}

static long long monotonic_ms(void)
{
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (long long)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

static void pause_wait(void)
{
    struct timespec delay = {0, 10000000};
    while (nanosleep(&delay, &delay) < 0 && errno == EINTR) {}
}

int honeyproxy_terminate_owned_child(pid_t pid, int timeout_ms)
{
    if (pid <= 0) return 0;
    if (timeout_ms <= 0) return ETIMEDOUT;
    const long long deadline = monotonic_ms() + timeout_ms;
    int locked;
    while ((locked = pthread_mutex_trylock(&child_lock)) != 0) {
        if (locked != EBUSY) return locked;
        if (monotonic_ms() >= deadline) return ETIMEDOUT;
        pause_wait();
    }
    const pid_t result = wait_child(pid, WNOHANG);
    int error = 0;
    if (result == 0) {
        /* A live direct child cannot have its PID reused while it is ours.
         * All native reaping uses this lock; an exited child stays a zombie
         * until the exact wait below, so a second cleanup never signals reuse.
         */
        if (kill(pid, SIGKILL) == 0 || errno == ESRCH) {
            while (1) {
                const pid_t exited = wait_child(pid, WNOHANG);
                if (exited == pid || (exited < 0 && errno == ECHILD)) break;
                if (exited < 0) { error = errno; break; }
                if (monotonic_ms() >= deadline) { error = ETIMEDOUT; break; }
                pause_wait();
            }
        } else {
            error = errno;
        }
    } else if (result < 0 && errno != ECHILD) {
        error = errno;
    }
    /* Already exited => reaped by WNOHANG; ECHILD => never signal that PID. */
    pthread_mutex_unlock(&child_lock);
    return error;
}
