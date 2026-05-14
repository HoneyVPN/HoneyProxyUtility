#include <jni.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <android/log.h>

#define TAG "HoneyVPN"
#define TUN_FIXED_FD 3   /* tun2socks will use fd://3 */

JNIEXPORT jint JNICALL
Java_ru_honeyvpn_proxy_NativeLauncher_forkExecTun2socks(
    JNIEnv *env, jclass cls,
    jstring jPath, jint tunFd, jint socksPort, jintArray jOutReadFd)
{
    const char *path = (*env)->GetStringUTFChars(env, jPath, 0);

    char proxy_arg[64];
    __builtin_snprintf(proxy_arg, sizeof(proxy_arg),
                       "socks5://127.0.0.1:%d", (int)socksPort);

    /* Pipe so parent can read tun2socks stderr */
    int pfd[2] = {-1, -1};
    if (pipe(pfd) < 0)
        __android_log_print(ANDROID_LOG_WARN, TAG, "pipe() failed: %d", errno);

    __android_log_print(ANDROID_LOG_DEBUG, TAG,
        "native fork+exec (dup2 approach): %s fd://3 proxy=%s tunFd=%d",
        path, proxy_arg, (int)tunFd);

    pid_t pid = fork();
    if (pid == 0) {
        /* ── child ── */

        /* Redirect stderr to write-end of pipe */
        if (pfd[1] >= 0) {
            dup2(pfd[1], STDERR_FILENO);
            dup2(pfd[1], STDOUT_FILENO);
            close(pfd[0]);
            close(pfd[1]);
        }

        /* Place TUN fd at fixed position 3; dup2 never sets CLOEXEC */
        if ((int)tunFd != TUN_FIXED_FD) {
            if (dup2((int)tunFd, TUN_FIXED_FD) < 0) {
                __android_log_print(ANDROID_LOG_ERROR, TAG,
                    "dup2(%d, 3) failed: %d", (int)tunFd, errno);
                _exit(126);
            }
            close((int)tunFd);
        }

        execl(path, "libtun2socks.so",
              "-device",   "fd://3",
              "-proxy",    proxy_arg,
              "-loglevel", "warn",
              (char *)0);

        __android_log_print(ANDROID_LOG_ERROR, TAG, "execl failed: %d", errno);
        _exit(127);
    }

    /* ── parent ── */
    if (pfd[1] >= 0) close(pfd[1]);   /* close write-end in parent */

    /* Pass read-end fd back to Kotlin */
    if (jOutReadFd != NULL) {
        jint readFd = (jint)pfd[0];
        (*env)->SetIntArrayRegion(env, jOutReadFd, 0, 1, &readFd);
    } else if (pfd[0] >= 0) {
        close(pfd[0]);
    }

    (*env)->ReleaseStringUTFChars(env, jPath, path);

    if (pid < 0)
        __android_log_print(ANDROID_LOG_ERROR, TAG, "fork() failed: %d", errno);

    return (jint)pid;
}
