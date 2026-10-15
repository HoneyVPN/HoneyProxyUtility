#ifndef HONEYPROXY_LATENCY_PROCESS_H
#define HONEYPROXY_LATENCY_PROCESS_H

#include <stdint.h>

/* This registry owns spawning, status and reaping. Never hand its children to
 * Dart Process or Java Process: their independent reapers invalidate PID scope. */
uint64_t honeyproxy_latency_start(const char *binary, const char *config, const char *directory);
int honeyproxy_latency_status(uint64_t id, int *exited, int *exit_code);
int honeyproxy_latency_stop(uint64_t id, int timeout_ms);

#endif
