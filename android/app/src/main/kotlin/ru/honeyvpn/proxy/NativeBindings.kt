package ru.honeyvpn.proxy

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.content.Intent
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.BinaryMessenger

class NativeBindings(
    private val context: Context,
    messenger: BinaryMessenger,
    private val requestVpnPermission: (callback: (Boolean) -> Unit) -> Unit,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methodChannel  = MethodChannel(messenger, "ru.honeyvpn.proxy/vpn")
    private val eventChannel   = EventChannel(messenger, "ru.honeyvpn.proxy/vpn_stats")
    private val nativeChannel  = MethodChannel(messenger, "ru.honeyvpn.proxy/native")
    private val deeplinkChannel = EventChannel(messenger, "ru.honeyvpn.proxy/deeplink")
    private var eventSink: EventChannel.EventSink? = null
    private var deeplinkSink: EventChannel.EventSink? = null

    companion object {
        private var instance: NativeBindings? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        fun onVpnStarted() = mainHandler.post {
            instance?.eventSink?.success(mapOf(
                "event" to "started",
                "uplink" to 0L, "downlink" to 0L,
                "uplinkTotal" to 0L, "downlinkTotal" to 0L, "duration" to 0L,
            ))
        }

        fun onVpnStopped() = mainHandler.post {
            instance?.eventSink?.success(mapOf("event" to "stopped"))
        }

        fun onVpnError(message: String) = mainHandler.post {
            instance?.eventSink?.success(mapOf("event" to "error", "message" to message))
        }

        @Volatile var pendingDeepLink: String? = null

        fun onDeepLink(url: String) = mainHandler.post {
            val sink = instance?.deeplinkSink
            if (sink != null) {
                sink.success(url)
            } else {
                pendingDeepLink = url
            }
        }

        fun pushStats(
            uplink: Long, downlink: Long,
            uplinkTotal: Long, downlinkTotal: Long,
            durationSeconds: Long,
        ) = mainHandler.post {
            instance?.eventSink?.success(mapOf(
                "event" to "stats",
                "uplink" to uplink,
                "downlink" to downlink,
                "uplinkTotal" to uplinkTotal,
                "downlinkTotal" to downlinkTotal,
                "duration" to durationSeconds,
            ))
        }
    }

    init {
        instance = this
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
        nativeChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getNativeLibDir" -> result.success(context.applicationInfo.nativeLibraryDir)
                else -> result.notImplemented()
            }
        }
        deeplinkChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                deeplinkSink = events
                pendingDeepLink?.let { url -> events?.success(url); pendingDeepLink = null }
            }
            override fun onCancel(arguments: Any?) { deeplinkSink = null }
        })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val config = call.argument<String>("config") ?: run {
                    result.error("INVALID_ARGS", "Missing config", null)
                    return
                }
                startVpn(config)
                result.success(null)
            }
            "stop" -> {
                stopVpn()
                result.success(null)
            }
            "requestPermission" -> {
                requestVpnPermission { granted -> result.success(granted) }
            }
            "checkStatus" -> {
                result.success(HoneyProxyVpnService.isRunning)
            }
            "getStats" -> {
                result.success(mapOf(
                    "uplink" to 0L, "downlink" to 0L,
                    "uplinkTotal" to 0L, "downlinkTotal" to 0L,
                    "duration" to 0L,
                ))
            }
            "pingHost" -> {
                val host = call.argument<String>("host") ?: run {
                    result.error("INVALID_ARGS", "Missing host", null); return
                }
                val timeout = call.argument<Int>("timeout") ?: 3000
                Thread {
                    try {
                        val addr = java.net.InetAddress.getByName(host)
                        val start = System.currentTimeMillis()
                        val reachable = addr.isReachable(timeout)
                        val elapsed = System.currentTimeMillis() - start
                        mainHandler.post { result.success(if (reachable) elapsed else -1L) }
                    } catch (e: Exception) {
                        mainHandler.post { result.success(-1L) }
                    }
                }.start()
            }
            else -> result.notImplemented()
        }
    }

    private fun startVpn(configJson: String) {
        val intent = Intent(context, HoneyProxyVpnService::class.java).apply {
            action = HoneyProxyVpnService.ACTION_START
            putExtra("config_json", configJson)
        }
        try {
            context.startForegroundService(intent)
        } catch (e: Exception) {
            // ForegroundServiceStartNotAllowedException (Android 12+) if the app
            // transitions to background at the exact moment the user taps connect.
            android.util.Log.e("NativeBindings", "startForegroundService failed: ${e.message}", e)
            onVpnError("Cannot start VPN: ${e.message}")
            onVpnStopped()
        }
    }

    private fun stopVpn() {
        val intent = Intent(context, HoneyProxyVpnService::class.java).apply {
            action = HoneyProxyVpnService.ACTION_STOP
        }
        context.startService(intent)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun destroy() {
        // Only clear the singleton if it still points to this instance.
        // Prevents a newly created instance from being nulled out during Activity recreation.
        if (instance === this) instance = null
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        nativeChannel.setMethodCallHandler(null)
        deeplinkChannel.setStreamHandler(null)
    }
}
