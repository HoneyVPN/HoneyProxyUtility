#include <jni.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <android/log.h>

#define TAG "HoneyVPN"

JNIEXPORT jint JNICALL
Java_ru_honeyvpn_proxy_NativeLauncher_forkExecTun2socks(
    JNIEnv *env, jclass cls,
    jstring jPath, jint tunFd, jint socksPort, jintArray jOutReadFd)
{
    const char *path = (*env)->GetStringUTFChars(env, jPath, 0);

    /* Clear CLOEXEC on TUN fd so it survives exec() */
    int flags = fcntl((int)tunFd, F_GETFD);
    if (flags >= 0) fcntl((int)tunFd, F_SETFD, flags & ~FD_CLOEXEC);

    char fd_arg[32], proxy_arg[64];
    __builtin_snprintf(fd_arg,    sizeof(fd_arg),    "fd://%d",               (int)tunFd);
    __builtin_snprintf(proxy_arg, sizeof(proxy_arg), "socks5://127.0.0.1:%d", (int)socksPort);

    /* Pipe for capturing tun2socks output */
    int pfd[2] = {-1, -1};
    if (pipe(pfd) < 0)
        __android_log_print(ANDROID_LOG_WARN, TAG, "pipe() failed: %d", errno);

    __android_log_print(ANDROID_LOG_DEBUG, TAG,
        "native fork+exec: %s %s %s", path, fd_arg, proxy_arg);

    pid_t pid = fork();
    if (pid == 0) {
        /* child: redirect stdout/stderr to pipe write-end */
        if (pfd[1] >= 0) {
            dup2(pfd[1], STDERR_FILENO);
            dup2(pfd[1], STDOUT_FILENO);
            close(pfd[0]);
            close(pfd[1]);
        }
        execl(path, "libtun2socks.so",
              "-device",   fd_arg,
              "-proxy",    proxy_arg,
              "-loglevel", "warn",
              (char *)0);
        _exit(127);
    }

    /* parent */
    if (pfd[1] >= 0) close(pfd[1]);
    if (jOutReadFd != NULL) {
        jint readFd = (jint)pfd[0];
        (*env)->SetIntArrayRegion(env, jOutReadFd, 0, 1, &readFd);
    } else if (pfd[0] >= 0) {
        close(pfd[0]);
    }

    (*env)->ReleaseStringUTFChars(env, jPath, path);
    return (jint)pid;
}
