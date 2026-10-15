package ru.honeyvpn.proxy

/** Only bounded numeric process metadata is accepted from the JNI observer. */
internal data class OwnedChildStatus(
    val kind: Kind,
    val exitCode: Int = 0,
    val signal: Int = 0,
    val errno: Int = 0,
) {
    enum class Kind { RUNNING, EXITED, SIGNALED, UNKNOWN, OWNER_LOST }
    val running: Boolean get() = kind == Kind.RUNNING
    val terminal: Boolean get() = kind == Kind.EXITED || kind == Kind.SIGNALED || kind == Kind.OWNER_LOST

    fun diagnostic(role: String): String {
        val safeRole = if (role == "sing-box") "sing-box" else "forwarder"
        return "VPN child role=$safeRole kind=${kind.name} exit=$exitCode signal=$signal errno=$errno"
    }

    fun failureMessage(role: String, startup: Boolean): String {
        val name = if (role == "sing-box") "sing-box" else "VPN forwarder"
        val phase = if (startup) "during startup" else "unexpectedly"
        return when (kind) {
            Kind.EXITED -> "$name stopped $phase (exit=$exitCode)"
            Kind.SIGNALED -> "$name stopped $phase (signal=$signal)"
            Kind.OWNER_LOST -> "$name ownership could not be confirmed"
            else -> "$name status could not be confirmed"
        }
    }

    companion object {
        fun unknown() = OwnedChildStatus(Kind.UNKNOWN)
        fun fromNative(reply: IntArray): OwnedChildStatus {
            if (reply.size != 4) return unknown()
            val (kind, exit, signal, error) = reply
            return when {
                kind == 1 && exit == 0 && signal == 0 && error == 0 -> OwnedChildStatus(Kind.RUNNING)
                kind == 2 && exit in 0..255 && signal == 0 && error == 0 -> OwnedChildStatus(Kind.EXITED, exitCode = exit)
                kind == 3 && exit == 0 && signal in 1..128 && error == 0 -> OwnedChildStatus(Kind.SIGNALED, signal = signal)
                kind == 4 && exit == 0 && signal == 0 && error in 1..4095 -> OwnedChildStatus(Kind.UNKNOWN, errno = error)
                kind == 5 && exit == 0 && signal == 0 && error in 1..4095 -> OwnedChildStatus(Kind.OWNER_LOST, errno = error)
                else -> unknown()
            }
        }
    }
}

/** Shared startup/watchdog policy: unavailable observation can be retried for
 * a bounded window but is never proof that a child is ready or has exited. */
internal class OwnedChildHealthWindow(private val unknownTimeoutMs: Long = 1_500) {
    private var unknownSince: Long? = null
    fun failed(status: OwnedChildStatus, elapsedMs: Long): Boolean {
        if (status.terminal) return true
        if (status.running) {
            unknownSince = null
            return false
        }
        val first = unknownSince ?: elapsedMs.also { unknownSince = it }
        return elapsedMs - first >= unknownTimeoutMs
    }
}
