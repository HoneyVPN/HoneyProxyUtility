#define _GNU_SOURCE
#include <jni.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/wait.h>
#include <android/log.h>
#include "owned_child.h"

#define TAG "HoneyVPN"

JNIEXPORT jint JNICALL
Java_ru_honeyvpn_proxy_NativeLauncher_forkExecTun2socks(
    JNIEnv *env, jclass cls,
    jstring jPath, jint tunFd, jint socksPort, jintArray jOutReadFd)
{
    const char *path = (*env)->GetStringUTFChars(env, jPath, 0);

    if (path == NULL) return -1;
    /* Validate the owned dup in the parent, but never change its CLOEXEC flag.
     * Other Java/native forks must not inherit this VPN descriptor. */
    const int flags = fcntl((int)tunFd, F_GETFD);
    if (flags < 0) {
        (*env)->ReleaseStringUTFChars(env, jPath, path);
        return -1;
    }

    char fd_arg[32], proxy_arg[64];
    __builtin_snprintf(fd_arg,    sizeof(fd_arg),    "fd://%d",               (int)tunFd);
    __builtin_snprintf(proxy_arg, sizeof(proxy_arg), "socks5://127.0.0.1:%d", (int)socksPort);

    /* Pipe for capturing tun2socks output */
    int pfd[2] = {-1, -1};
    if (pipe2(pfd, O_CLOEXEC) < 0)
        __android_log_print(ANDROID_LOG_WARN, TAG, "pipe() failed: %d", errno);

    __android_log_print(ANDROID_LOG_DEBUG, TAG, "VPN forwarder fork requested");

    pid_t pid = fork();
    if (pid == 0) {
        /* Only this child may retain the dup across exec. fcntl is safe here. */
        if (fcntl((int)tunFd, F_SETFD, flags & ~FD_CLOEXEC) < 0) {
            const int error = errno;
            honeyproxy_report_launch_failure(pfd[1], HONEY_LAUNCH_FD, error);
            _exit(126);
        }
        /* child: redirect stdout/stderr to pipe write-end */
        if (pfd[1] >= 0) {
            if (dup2(pfd[1], STDERR_FILENO) < 0 || dup2(pfd[1], STDOUT_FILENO) < 0) {
                const int error = errno;
                honeyproxy_report_launch_failure(pfd[1], HONEY_LAUNCH_STDIO, error);
                _exit(125);
            }
            close(pfd[0]);
            close(pfd[1]);
        }
        execl(path, "libtun2socks.so",
              "--device",   fd_arg,
              "--proxy",    proxy_arg,
              "--loglevel", "warn",
              (char *)0);
        const int error = errno;
        honeyproxy_report_launch_failure(STDERR_FILENO, HONEY_LAUNCH_EXEC, error);
        _exit(127);
    }

    /* parent */
    if (pfd[1] >= 0) close(pfd[1]);
    if (pid < 0 && pfd[0] >= 0) {
        close(pfd[0]);
        pfd[0] = -1;
    }
    if (jOutReadFd != NULL) {
        jint readFd = (jint)pfd[0];
        (*env)->SetIntArrayRegion(env, jOutReadFd, 0, 1, &readFd);
    } else if (pfd[0] >= 0) {
        close(pfd[0]);
    }

    (*env)->ReleaseStringUTFChars(env, jPath, path);
    return (jint)pid;
}

JNIEXPORT jintArray JNICALL
Java_ru_honeyvpn_proxy_NativeLauncher_observeOwnedChild(
    JNIEnv *env, jclass cls, jint pid)
{
    (void)cls;
    const struct honeyproxy_child_status status = honeyproxy_observe_owned_child((pid_t)pid);
    const jint values[4] = {status.kind, status.exit_code, status.signal_number, status.error_code};
    jintArray reply = (*env)->NewIntArray(env, 4);
    if (reply != NULL) (*env)->SetIntArrayRegion(env, reply, 0, 4, values);
    return reply;
}

/* Retire only an exact owned child, outside the Android UI thread. */
JNIEXPORT jint JNICALL
Java_ru_honeyvpn_proxy_NativeLauncher_terminateOwnedChild(
    JNIEnv *env, jclass cls, jint pid, jint timeout_ms)
{
    return (jint)honeyproxy_terminate_owned_child((pid_t)pid, (int)timeout_ms);
}
