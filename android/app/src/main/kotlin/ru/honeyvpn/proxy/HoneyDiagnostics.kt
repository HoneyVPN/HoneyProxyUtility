package ru.honeyvpn.proxy

import java.io.Reader
import java.util.ArrayDeque

/** Only this app's own events, never logcat or another application's output.
 * Core output may contain arbitrary short secrets: keep technical words only.
 */
internal object HoneyDiagnostics {
    private var dropped = 0
    private val events = ArrayDeque<Map<String, Any>>()
    private val vocabulary = setOf("error", "warn", "warning", "fatal", "panic", "debug", "info", "trace",
        "failed", "failure", "timeout", "deadline", "refused", "reset", "closed", "unexpected", "eof",
        "invalid", "unsupported", "unavailable", "denied", "permission", "certificate", "handshake", "tls",
        "reality", "vless", "hysteria", "hysteria2", "quic", "wireguard", "amnezia", "xhttp", "grpc",
        "websocket", "tcp", "udp", "dns", "tun", "socket", "route", "connect", "connection", "dial",
        "read", "write", "listen", "bind", "resolve", "start", "startup", "stop", "stopped", "exit",
        "exited", "signal", "core", "forwarder", "sing-box", "tun2socks", "occupied", "running", "ready",
        "cleanup", "confirmed", "unconfirmed", "configuration", "exceeded", "line", "limit", "output", "omitted", "connected", "connecting", "disconnecting", "disconnected")
    private val words = Regex("[a-zA-Z][a-zA-Z0-9-]*")
    private val sensitive = Regex("""(?i)[a-z][a-z0-9+.-]*://[^\s]+|[a-z]:[\\/][^\s]+|/(?:[^\s/]+/)*[^\s]+|(?:[0-9]{1,3}\.){3}[0-9]{1,3}|(?:[a-z0-9_-]+\.)+[a-z]{2,}""")
    fun summarize(raw: String): String {
        if (raw.length > 4096) return "core output exceeded line limit"
        val safe = sensitive.replace(raw, " ")
        val kept = words.findAll(safe).map { it.value.lowercase(java.util.Locale.ROOT) }
            .filter { vocabulary.contains(it) }.take(40).toList()
        return if (kept.isEmpty()) "core output omitted" else kept.joinToString(" ")
    }
    @Synchronized fun add(raw: String, error: Boolean = false) {
        events.addLast(mapOf("time" to System.currentTimeMillis(), "message" to summarize(raw), "error" to error))
        while (events.size > 128) { events.removeFirst(); if (dropped < Int.MAX_VALUE) dropped++ }
    }
    /** Constructed solely from a captured child status, no process arguments. */
    @Synchronized fun child(role: String, status: OwnedChildStatus) {
        val safeRole = if (role == "sing-box") "sing-box" else "forwarder"
        val safe = status.diagnostic(safeRole).take(256)
        events.addLast(mapOf("time" to System.currentTimeMillis(), "message" to safe, "error" to true))
        while (events.size > 128) { events.removeFirst(); if (dropped < Int.MAX_VALUE) dropped++ }
    }
    @Synchronized fun droppedCount(): Int = dropped
    @Synchronized fun snapshot(): List<Map<String, Any>> = events.toList()
    /** Never allocate an unbounded line from a hostile native process. */
    fun drain(reader: Reader) {
        val line = StringBuilder(512)
        var oversized = false
        while (true) {
            val c = reader.read()
            if (c < 0) { if (line.isNotEmpty() || oversized) add(if (oversized) "core output exceeded line limit" else line.toString()); return }
            if (c == 10) {
                val raw = if (oversized) "core output exceeded line limit" else line.toString()
                add(raw, words.findAll(raw).any { it.value.lowercase(java.util.Locale.ROOT) in setOf("error", "fatal", "panic", "failed") })
                line.setLength(0); oversized = false
            } else if (line.length < 4096 && !oversized) line.append(c.toChar()) else oversized = true
        }
    }
}
