package ru.honeyvpn.proxy

import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit
import java.util.UUID

/** A listening port alone cannot identify this session's verified core. */
internal object CoreReadinessProbe {
    private const val MAX_RESPONSE = 4096
    private val versionField = Regex("\"version\"\\s*:\\s*\"[^\"\\r\\n]{1,128}\"")

    fun isReady(port: Int, secret: String): Boolean {
        return try {
            // An old unauthenticated controller would accept both requests.
            // An old authenticated one cannot know this session's fresh nonce.
            if (request(port, UUID.randomUUID().toString()).first != 401) return false
            val (status, body) = request(port, secret)
            status == 200 && body.trim().startsWith("{") && body.trim().endsWith("}") && versionField.containsMatchIn(body)
        } catch (_: Exception) { false }
    }

    private fun request(port: Int, token: String): Pair<Int, String> {
        val connection = URL("http://127.0.0.1:$port/version").openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = false
        connection.connectTimeout = 300
        connection.readTimeout = 300
        connection.setRequestProperty("Authorization", "Bearer $token")
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(900)
        try {
            val status = connection.responseCode
            if (status != 200) return status to ""
            val body = StringBuilder()
            connection.inputStream.bufferedReader().use { reader ->
                val buffer = CharArray(512)
                while (body.length <= MAX_RESPONSE && System.nanoTime() < deadline) {
                    val count = reader.read(buffer, 0, minOf(buffer.size, MAX_RESPONSE + 1 - body.length))
                    if (count < 0) return status to body.toString()
                    body.append(buffer, 0, count)
                }
            }
            return status to "" // Oversized, stalled or incomplete response.
        } finally {
            connection.disconnect()
        }
    }
}
