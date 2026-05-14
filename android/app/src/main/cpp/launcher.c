#include <jni.h>
#include <unistd.h>
#include <fcntl.h>
#include <android/log.h>

#define TAG "HoneyVPN"

JNIEXPORT jint JNICALL
Java_ru_honeyvpn_proxy_NativeLauncher_forkExecTun2socks(
    JNIEnv *env, jclass cls,
    jstring jPath, jint tunFd, jint socksPort)
{
    const char *path = (*env)->GetStringUTFChars(env, jPath, 0);

    /* clear FD_CLOEXEC so tunFd survives exec() */
    int flags = fcntl((int)tunFd, F_GETFD);
    if (flags >= 0) fcntl((int)tunFd, F_SETFD, flags & ~FD_CLOEXEC);

    char fd_arg[32], proxy_arg[64];
    __builtin_snprintf(fd_arg,    sizeof(fd_arg),    "fd://%d",                  (int)tunFd);
    __builtin_snprintf(proxy_arg, sizeof(proxy_arg), "socks5://127.0.0.1:%d",   (int)socksPort);

    __android_log_print(ANDROID_LOG_DEBUG, TAG,
        "native fork+exec: %s -device %s -proxy %s", path, fd_arg, proxy_arg);

    pid_t pid = fork();
    if (pid == 0) {
        execl(path, "libtun2socks.so",
              "-device", fd_arg,
              "-proxy",  proxy_arg,
              "-loglevel", "warn",
              (char *)0);
        __android_log_print(ANDROID_LOG_ERROR, TAG, "execl failed");
        _exit(127);
    }

    (*env)->ReleaseStringUTFChars(env, jPath, path);
    return (jint)pid;
}
