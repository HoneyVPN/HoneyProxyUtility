#include "owned_child.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void *retire(void *argument)
{
    const pid_t pid = *(pid_t *)argument;
    assert(honeyproxy_terminate_owned_child(pid, 2000) == 0);
    return NULL;
}

static struct honeyproxy_child_status wait_observed_exit(pid_t pid)
{
    struct honeyproxy_child_status status = {HONEY_CHILD_UNKNOWN, 0, 0, 0};
    for (int attempt = 0; attempt < 2000; ++attempt) {
        status = honeyproxy_observe_owned_child(pid);
        if (status.kind == HONEY_CHILD_EXITED || status.kind == HONEY_CHILD_SIGNALED) return status;
        struct timespec delay = {0, 1000000};
        nanosleep(&delay, NULL);
    }
    return status;
}

static void check_nonreaping_observation(void)
{
    struct honeyproxy_child_status status = honeyproxy_observe_owned_child(-1);
    assert(status.kind == HONEY_CHILD_OWNER_LOST && status.error_code == ECHILD);
    status = honeyproxy_observe_owned_child(0);
    assert(status.kind == HONEY_CHILD_OWNER_LOST && status.error_code == ECHILD);
    status = honeyproxy_observe_owned_child(getpid());
    assert(status.kind == HONEY_CHILD_OWNER_LOST && status.error_code == ECHILD);

    pid_t alive = fork(); assert(alive >= 0);
    if (alive == 0) { for (;;) pause(); }
    status = honeyproxy_observe_owned_child(alive);
    assert(status.kind == HONEY_CHILD_RUNNING && status.exit_code == 0 && status.signal_number == 0 && status.error_code == 0);
#ifdef HONEY_OWNED_CHILD_TESTING
    assert(honeyproxy_test_hold_child_lock() == 0);
    status = honeyproxy_observe_owned_child(alive);
    assert(status.kind == HONEY_CHILD_UNKNOWN && status.error_code == EBUSY);
    assert(honeyproxy_test_release_child_lock() == 0);
    assert(honeyproxy_observe_owned_child(alive).kind == HONEY_CHILD_RUNNING);
#endif
    assert(honeyproxy_terminate_owned_child(alive, 2000) == 0);

    pid_t exited = fork(); assert(exited >= 0);
    if (exited == 0) _exit(37);
    status = wait_observed_exit(exited);
    assert(status.kind == HONEY_CHILD_EXITED && status.exit_code == 37);
    for (int attempt = 0; attempt < 3; ++attempt) {
        status = honeyproxy_observe_owned_child(exited);
        assert(status.kind == HONEY_CHILD_EXITED && status.exit_code == 37);
    }
    int raw;
    assert(waitpid(exited, &raw, WNOHANG) == exited && WIFEXITED(raw) && WEXITSTATUS(raw) == 37);
    status = honeyproxy_observe_owned_child(exited);
    assert(status.kind == HONEY_CHILD_OWNER_LOST && status.error_code == ECHILD);

    pid_t signaled = fork(); assert(signaled >= 0);
    if (signaled == 0) { for (;;) pause(); }
    assert(kill(signaled, SIGTERM) == 0);
    status = wait_observed_exit(signaled);
    assert(status.kind == HONEY_CHILD_SIGNALED && status.signal_number == SIGTERM);
    assert(honeyproxy_observe_owned_child(signaled).kind == HONEY_CHILD_SIGNALED);
    assert(honeyproxy_terminate_owned_child(signaled, 2000) == 0);
    assert(waitpid(signaled, NULL, WNOHANG) == -1 && errno == ECHILD);

    int output[2]; assert(pipe(output) == 0);
    pid_t failed_exec = fork(); assert(failed_exec >= 0);
    if (failed_exec == 0) {
        close(output[0]);
        execl("/honey-public-missing-executable-fixture", "fixture", (char *)NULL);
        const int error = errno;
        honeyproxy_report_launch_failure(output[1], HONEY_LAUNCH_EXEC, error);
        _exit(127);
    }
    close(output[1]);
    char text[80] = {0};
    assert(read(output[0], text, sizeof(text) - 1) > 0);
    assert(strcmp(text, "HONEY_FORWARDER_FAILURE stage=exec errno=2\n") == 0);
    assert(strstr(text, "honey-public-missing") == NULL);
    close(output[0]);
    status = wait_observed_exit(failed_exec);
    assert(status.kind == HONEY_CHILD_EXITED && status.exit_code == 127);
    assert(honeyproxy_terminate_owned_child(failed_exec, 2000) == 0);
    puts("PASS exact-child running/normal-exit/signal/owner-lost observation, repeated WNOWAIT preserves zombie, bounded mutex UNKNOWN and exec-errno-only reporting");
}

int main(void)
{
    check_nonreaping_observation();
    /* Never signal a live PID that is not our child (including ourselves). */
    assert(honeyproxy_terminate_owned_child(getpid(), 2000) == 0);
    assert(honeyproxy_terminate_owned_child(-1, 2000) == 0);
    pid_t bounded = fork();
    assert(bounded >= 0);
    if (bounded == 0) { for (;;) pause(); }
    assert(honeyproxy_terminate_owned_child(bounded, 0) == ETIMEDOUT);
    assert(waitpid(bounded, NULL, WNOHANG) == 0); /* Failure keeps ownership. */
    assert(honeyproxy_terminate_owned_child(bounded, 2000) == 0);
    for (int iteration = 0; iteration < 100; iteration++) {
        pid_t pid = fork();
        assert(pid >= 0);
        if (pid == 0) { for (;;) pause(); }
        pthread_t first, second;
        assert(pthread_create(&first, NULL, retire, &pid) == 0);
        assert(pthread_create(&second, NULL, retire, &pid) == 0);
        assert(pthread_join(first, NULL) == 0);
        assert(pthread_join(second, NULL) == 0);
        assert(waitpid(pid, NULL, WNOHANG) == -1 && errno == ECHILD);
    }
    /* Exited-but-unreaped children are reaped without signalling another PID. */
    pid_t exited = fork();
    assert(exited >= 0);
    if (exited == 0) _exit(0);
    siginfo_t info = {0};
    assert(waitid(P_PID, exited, &info, WEXITED | WNOWAIT) == 0);
    assert(honeyproxy_terminate_owned_child(exited, 2000) == 0);
    assert(waitpid(exited, NULL, WNOHANG) == -1 && errno == ECHILD);

    /* A real live grandchild is foreign to this helper, even with the same UID. */
    int report[2], finish[2];
    assert(pipe(report) == 0 && pipe(finish) == 0);
    pid_t owner = fork();
    assert(owner >= 0);
    if (owner == 0) {
        close(report[0]); close(finish[1]);
        pid_t foreign = fork();
        if (foreign == 0) { for (;;) pause(); }
        assert(foreign > 0);
        assert(write(report[1], &foreign, sizeof foreign) == sizeof foreign);
        char byte;
        assert(read(finish[0], &byte, 1) == 1);
        assert(kill(foreign, 0) == 0);
        assert(kill(foreign, SIGKILL) == 0);
        assert(waitpid(foreign, NULL, 0) == foreign);
        _exit(0);
    }
    close(report[1]); close(finish[0]);
    pid_t foreign;
    assert(read(report[0], &foreign, sizeof foreign) == sizeof foreign);
    assert(honeyproxy_observe_owned_child(foreign).kind == HONEY_CHILD_OWNER_LOST);
    assert(honeyproxy_terminate_owned_child(foreign, 2000) == 0);
    assert(kill(foreign, 0) == 0);
    assert(write(finish[1], "x", 1) == 1);
    int status;
    assert(waitpid(owner, &status, 0) == owner && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    close(report[0]); close(finish[1]);

    /* Actual dup/fork/exec contract: retiring the original and reusing its
     * number for a new session must not give the child that newer descriptor.
     */
    int previous[2], newer[2];
    assert(socketpair(AF_UNIX, SOCK_DGRAM, 0, previous) == 0);
    const int original = previous[0];
    const int owned_duplicate = dup(original);
    assert(owned_duplicate >= 0);
    assert(fcntl(owned_duplicate, F_SETFD, FD_CLOEXEC) == 0);
    assert(close(original) == 0);
    assert(socketpair(AF_UNIX, SOCK_DGRAM, 0, newer) == 0);
    assert(newer[0] == original);
    assert(fcntl(previous[1], F_SETFD, FD_CLOEXEC) == 0);
    assert(fcntl(newer[0], F_SETFD, FD_CLOEXEC) == 0);
    assert(fcntl(newer[1], F_SETFD, FD_CLOEXEC) == 0);
    char command[64];
    snprintf(command, sizeof command, "printf old >&%d", owned_duplicate);
    assert(fcntl(owned_duplicate, F_GETFD) == FD_CLOEXEC);
    pid_t writer = fork();
    assert(writer >= 0);
    if (writer == 0) {
        assert(fcntl(owned_duplicate, F_SETFD, 0) == 0);
        execl("/bin/sh", "sh", "-c", command, (char *)NULL);
        _exit(127);
    }
    assert(fcntl(owned_duplicate, F_GETFD) == FD_CLOEXEC);
    assert(close(owned_duplicate) == 0);
    char payload[8] = {0};
    assert(read(previous[1], payload, sizeof payload) == 3);
    assert(strcmp(payload, "old") == 0);
    assert(fcntl(newer[1], F_SETFL, O_NONBLOCK) == 0);
    assert(read(newer[1], payload, sizeof payload) == -1 && (errno == EAGAIN || errno == EWOULDBLOCK));
    assert(waitpid(writer, &status, 0) == writer && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    close(previous[1]); close(newer[0]); close(newer[1]);
    puts("Android owned-child/FD checks: 100 concurrent cleanups, bounded failure/retry, exited/foreign PIDs, parent CLOEXEC unchanged and dup held through fork/exec with FD-number reuse passed. No VPN/TUN was started.");
    return 0;
}
