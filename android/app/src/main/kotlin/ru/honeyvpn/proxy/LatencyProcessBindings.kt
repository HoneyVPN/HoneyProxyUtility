package ru.honeyvpn.proxy

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.IdentityHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

internal object NativeLatencyLauncher {
    external fun start(binary: String, config: String, directory: String): Long
    external fun status(id: Long): IntArray
    external fun stop(id: Long, timeoutMs: Int): Int
    init { System.loadLibrary("honeyvpn_launcher") }
}

/** Independent read-only profile probes: no VPN permission, PFD or service. */
internal class LatencyProcessBindings(context: Context, messenger: BinaryMessenger) {
    companion object {
        private val ownerLock = Any()
        private val channelOwners = IdentityHashMap<BinaryMessenger, LatencyProcessBindings>()
    }
    private val messengerOwner = messenger
    private val app = context.applicationContext
    private val channel = MethodChannel(messenger, "ru.honeyvpn.proxy/latency")
    private val actor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val closed = AtomicBoolean(false)
    // Actor-owned IDs belong to this binding only. Destruction of an old
    // Activity can never retire probes created by its replacement Activity.
    private val owned = mutableSetOf<Long>()

    init {
        synchronized(ownerLock) { channelOwners[messengerOwner] = this }
        channel.setMethodCallHandler { call, result ->
            if (closed.get()) {
                result.error("probe_closed", "Latency probe is unavailable", null)
                return@setMethodCallHandler
            }
            actor.execute {
                if (closed.get()) {
                    main.post { result.error("probe_closed", "Latency probe is unavailable", null) }
                    return@execute
                }
                try {
                    when (call.method) {
                        "start" -> {
                            val configuration = call.argument<String>("configPath")
                                ?: throw IllegalArgumentException()
                            val working = call.argument<String>("directory")
                                ?: throw IllegalArgumentException()
                            val directory = File(working)
                            val config = File(configuration)
                            val cache = app.cacheDir.canonicalFile
                            // path_provider Android temporaryDirectory is app.cacheDir.
                            // Canonical-vs-absolute equality rejects symlink/junction
                            // components; the native launcher retains a read-only FD.
                            require(directory.isAbsolute && config.isAbsolute)
                            require(directory.parentFile?.canonicalFile == cache)
                            require(directory.canonicalFile == File(cache, directory.name))
                            require(config.canonicalFile == File(directory.canonicalFile, "config.json"))
                            require(directory.name.startsWith("honey-latency-"))
                            require(config == File(directory, "config.json") && config.isFile)
                            require(config.setReadable(false, false) && config.setWritable(false, false))
                            require(config.setReadable(true, true) && config.setWritable(true, true))
                            val binary = File(app.applicationInfo.nativeLibraryDir, "libsingbox.so")
                            require(binary.isFile)
                            val id = NativeLatencyLauncher.start(binary.absolutePath,
                                config.absolutePath, directory.absolutePath)
                            require(id > 0)
                            owned.add(id)
                            if (closed.get()) {
                                if (NativeLatencyLauncher.stop(id, 1500) == 0) owned.remove(id)
                                main.post { result.error("probe_closed", "Latency probe is unavailable", null) }
                            } else main.post { result.success(id) }
                        }
                        "status" -> {
                            val id = call.argument<Number>("id")?.toLong()
                                ?: throw IllegalArgumentException()
                            require(owned.contains(id))
                            val state = NativeLatencyLauncher.status(id)
                            require(state.size == 3 && state[0] == 0)
                            main.post { result.success(mapOf(
                                "exited" to (state[1] != 0), "exitCode" to state[2])) }
                        }
                        "stop" -> {
                            val id = call.argument<Number>("id")?.toLong()
                                ?: throw IllegalArgumentException()
                            require(owned.contains(id))
                            val stopped = NativeLatencyLauncher.stop(id, 1500) == 0
                            if (stopped) owned.remove(id)
                            main.post { result.success(stopped) }
                        }
                        else -> main.post { result.notImplemented() }
                    }
                } catch (_: Exception) {
                    main.post { result.error("probe_failed", "Latency probe is unavailable", null) }
                }
            }
        }
    }

    fun destroy() {
        if (!closed.compareAndSet(false, true)) return
        synchronized(ownerLock) {
            if (channelOwners[messengerOwner] === this) {
                channelOwners.remove(messengerOwner)
                channel.setMethodCallHandler(null)
            }
        }
        actor.execute {
            for (id in owned.toList()) {
                if (NativeLatencyLauncher.stop(id, 1500) == 0) owned.remove(id)
            }
            actor.shutdown()
        }
    }
}
