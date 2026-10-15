#ifndef HONEYPROXY_OWNED_CHILD_H
#define HONEYPROXY_OWNED_CHILD_H

#include <sys/types.h>

/* Never signal a PID that waitpid does not identify as our direct child. */
int honeyproxy_terminate_owned_child(pid_t pid, int timeout_ms);

enum honeyproxy_child_kind {
    HONEY_CHILD_RUNNING = 1,
    HONEY_CHILD_EXITED = 2,
    HONEY_CHILD_SIGNALED = 3,
    HONEY_CHILD_UNKNOWN = 4,
    HONEY_CHILD_OWNER_LOST = 5
};

struct honeyproxy_child_status {
    int kind;
    int exit_code;
    int signal_number;
    int error_code;
};

/* Observe the exact direct child without reaping its zombie or releasing its
 * PID. Contention/error is UNKNOWN, never evidence that the child exited. */
struct honeyproxy_child_status honeyproxy_observe_owned_child(pid_t pid);

enum honeyproxy_launch_stage {
    HONEY_LAUNCH_FD = 1,
    HONEY_LAUNCH_STDIO = 2,
    HONEY_LAUNCH_EXEC = 3
};
/* Fixed stage/errno only; safe after fork, with no JNI, allocation or stdio. */
void honeyproxy_report_launch_failure(int output_fd, int stage, int error_code);

#ifdef HONEY_OWNED_CHILD_TESTING
int honeyproxy_test_hold_child_lock(void);
int honeyproxy_test_release_child_lock(void);
#endif

#endif
