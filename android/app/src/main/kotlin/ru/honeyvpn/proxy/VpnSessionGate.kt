package ru.honeyvpn.proxy

/**
 * One owner for asynchronous allocations and delayed callbacks. Slow allocation
 * and disposal happen outside this gate; publishing is conditional and atomic.
 */
internal class VpnSessionGate<S : Any> {
    data class Retirement<S>(val session: S?, val revision: Long, val command: Long = 0)

    private val lock = Any()
    private var current: S? = null
    private var revision = 0L
    private var command = 0L

    fun command(transition: () -> Unit = {}): Retirement<S> = synchronized(lock) {
        val previous = current
        current = null
        revision++
        command++
        transition()
        Retirement(previous, revision, command)
    }

    fun begin(expectedCommand: Long, session: S, allowed: () -> Boolean = { true }, transition: () -> Unit = {}): Boolean = synchronized(lock) {
        if (command != expectedCommand || current != null || !allowed()) return@synchronized false
        current = session
        revision++
        transition()
        true
    }

    fun replace(session: S, transition: () -> Unit = {}): S? = synchronized(lock) {
        val previous = current
        current = session
        revision++
        transition()
        previous
    }

    fun isCurrent(session: S): Boolean = synchronized(lock) { current === session }

    fun update(session: S, action: () -> Unit): Boolean = synchronized(lock) {
        if (current !== session) return@synchronized false
        action()
        true
    }

    fun <R : Any> read(session: S, action: () -> R): R? = synchronized(lock) {
        if (current !== session) null else action()
    }

    fun retire(expected: S? = null, transition: () -> Unit = {},
               scheduled: (Retirement<S>) -> Unit = {}): Retirement<S>? = synchronized(lock) {
        if (expected != null && current !== expected) return@synchronized null
        val previous = current
        current = null
        revision++
        transition()
        Retirement(previous, revision).also(scheduled)
    }

    /** Also guards delayed stopped/error notifications after a newer start. */
    fun ifRetired(expectedRevision: Long, action: () -> Unit): Boolean = synchronized(lock) {
        if (current != null || revision != expectedRevision) return@synchronized false
        action()
        true
    }
}
