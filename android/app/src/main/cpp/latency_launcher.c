#include <jni.h>
#include "latency_process.h"

JNIEXPORT jlong JNICALL Java_ru_honeyvpn_proxy_NativeLatencyLauncher_start(
    JNIEnv *env, jclass cls, jstring jbinary, jstring jconfig, jstring jdirectory)
{
    (void)cls;
    const char *binary = (*env)->GetStringUTFChars(env, jbinary, 0);
    const char *config = (*env)->GetStringUTFChars(env, jconfig, 0);
    const char *directory = (*env)->GetStringUTFChars(env, jdirectory, 0);
    const uint64_t id = binary && config && directory ?
        honeyproxy_latency_start(binary, config, directory) : 0;
    if (directory) (*env)->ReleaseStringUTFChars(env, jdirectory, directory);
    if (config) (*env)->ReleaseStringUTFChars(env, jconfig, config);
    if (binary) (*env)->ReleaseStringUTFChars(env, jbinary, binary);
    return (jlong)id;
}

JNIEXPORT jintArray JNICALL Java_ru_honeyvpn_proxy_NativeLatencyLauncher_status(
    JNIEnv *env, jclass cls, jlong id)
{
    (void)cls;
    int exited = 0, code = 0;
    const int error = honeyproxy_latency_status((uint64_t)id, &exited, &code);
    const jint values[] = {error, exited, code};
    jintArray result = (*env)->NewIntArray(env, 3);
    if (result) (*env)->SetIntArrayRegion(env, result, 0, 3, values);
    return result;
}

JNIEXPORT jint JNICALL Java_ru_honeyvpn_proxy_NativeLatencyLauncher_stop(
    JNIEnv *env, jclass cls, jlong id, jint timeout_ms)
{
    (void)env; (void)cls;
    return (jint)honeyproxy_latency_stop((uint64_t)id, timeout_ms);
}
