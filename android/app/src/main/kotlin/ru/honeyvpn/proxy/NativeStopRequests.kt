package ru.honeyvpn.proxy

import java.util.UUID
import java.util.concurrent.TimeUnit

/** API 24-compatible bounded process closure: API 26 methods are not required. */
internal fun terminateJavaProcess(process: Process, timeoutMs: Long): Boolean = try {
    process.destroy()
    val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs.coerceAtLeast(0))
    var exited = false
    while (true) {
        try { process.exitValue(); exited = true; break }
        catch (_: IllegalThreadStateException) { /* Still our live process. */ }
        val remaining = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
        if (remaining <= 0) break
        Thread.sleep(remaining.coerceAtMost(10))
    }
    exited
} catch (_: Exception) { false }

/** Captured method replies; a new Activity/binding cannot replace an old reply. */
internal class NativeStopRequests {
    private val lock = Any()
    private val requests = mutableMapOf<String, (String?) -> Unit>()

    fun register(reply: (String?) -> Unit): String = synchronized(lock) {
        UUID.randomUUID().toString().also { requests[it] = reply }
    }

    fun complete(id: String, error: String?): Boolean {
        val reply = synchronized(lock) { requests.remove(id) } ?: return false
        reply(error)
        return true
    }
}

/** Keep failed retirement snapshots until closure is actually confirmed. */
internal class ConfirmedSessionCleanup<S : Any> {
    private val lock = Any()
    private val pending = linkedSetOf<S>()
    fun retain(session: S) = synchronized(lock) { pending.add(session) }
    fun confirm(close: (S) -> Boolean): Boolean {
        val snapshot = synchronized(lock) { pending.toList() }
        for (session in snapshot) {
            if (!close(session)) return false
            synchronized(lock) { pending.remove(session) }
        }
        return synchronized(lock) { pending.isEmpty() }
    }
}
