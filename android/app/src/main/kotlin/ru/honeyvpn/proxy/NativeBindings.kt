package ru.honeyvpn.proxy

import android.content.Context
import android.os.Handler
import android.os.Build
import android.os.Looper
import android.content.Intent
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.BinaryMessenger
import java.util.IdentityHashMap

class NativeBindings(
    private val context: Context,
    private val messenger: BinaryMessenger,
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
        private val stopRequests = NativeStopRequests()
        private val channelOwners = IdentityHashMap<BinaryMessenger, NativeBindings>()

        fun completeStop(requestId: String, error: String?, stillStopped: () -> Boolean = { true }) = mainHandler.post {
            stopRequests.complete(requestId, if (error == null && !stillStopped()) "VPN stop was superseded by a newer command" else error)
        }

        fun onVpnStopping(dispatch: (() -> Unit) -> Unit) = mainHandler.post {
            dispatch { instance?.eventSink?.success(mapOf("event" to "stopping")) }
        }

        fun onVpnStarted(dispatch: (() -> Unit) -> Unit = { it() }) = mainHandler.post {
            dispatch { instance?.eventSink?.success(mapOf(
                "event" to "started",
                "uplink" to 0L, "downlink" to 0L,
                "uplinkTotal" to 0L, "downlinkTotal" to 0L, "duration" to 0L,
            )) }
        }

        fun onVpnStopped(dispatch: (() -> Unit) -> Unit = { it() }) = mainHandler.post {
            dispatch { instance?.eventSink?.success(mapOf("event" to "stopped")) }
        }

        fun onVpnError(message: String, dispatch: (() -> Unit) -> Unit = { it() }) = mainHandler.post {
            dispatch { HoneyDiagnostics.add(message, true); instance?.eventSink?.success(mapOf("event" to "error", "message" to message)) }
        }

        @Volatile var pendingDeepLink: String? = null
        private var pendingDeepLinkError: Boolean = false

        fun onDeepLink(rawUri: String) = mainHandler.post {
            val sink = instance?.deeplinkSink
            if (rawUri.length > 65536 || rawUri.toByteArray(Charsets.UTF_8).size > 65536) {
                pendingDeepLink = null
                if (sink != null) sink.error("IMPORT_LINK_TOO_LONG", "Import link is too long", null)
                else pendingDeepLinkError = true
                return@post
            }
            pendingDeepLinkError = false
            if (sink != null) {
                sink.success(rawUri)
            } else {
                pendingDeepLink = rawUri
            }
        }

        fun pushStats(
            uplink: Long, downlink: Long,
            uplinkTotal: Long, downlinkTotal: Long,
            durationSeconds: Long,
            dispatch: (() -> Unit) -> Unit = { it() },
        ) = mainHandler.post {
            dispatch { instance?.eventSink?.success(mapOf(
                "event" to "stats",
                "uplink" to uplink,
                "downlink" to downlink,
                "uplinkTotal" to uplinkTotal,
                "downlinkTotal" to downlinkTotal,
                "duration" to durationSeconds,
            )) }
        }
    }

    init {
        instance = this
        synchronized(channelOwners) { channelOwners[messenger] = this }
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
                val pending = pendingDeepLink
                val failed = pendingDeepLinkError
                pendingDeepLink = null
                pendingDeepLinkError = false
                if (failed) events?.error("IMPORT_LINK_TOO_LONG", "Import link is too long", null)
                else pending?.let { events?.success(it) }
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
                val locale = if (call.argument<Any>("locale") == "ru") "ru" else "en"
                startVpn(config, locale, result)
            }
            "setLocale" -> {
                val locale = call.argument<Any>("locale") as? String
                if (locale != "ru" && locale != "en") {
                    result.error("INVALID_ARGS", "Unsupported application locale", null)
                    return
                }
                result.success(HoneyProxyVpnService.setNotificationLocale(locale))
            }
            "stop" -> {
                stopVpn(result)
            }
            "requestPermission" -> {
                requestVpnPermission { granted -> result.success(granted) }
            }
            "checkStatus" -> {
                result.success(HoneyProxyVpnService.isRunning)
            }
            "getDiagnostics" -> result.success(mapOf("state" to HoneyProxyVpnService.nativeState,
                "apiLevel" to Build.VERSION.SDK_INT, "droppedEvents" to HoneyDiagnostics.droppedCount(), "events" to HoneyDiagnostics.snapshot()))
            "getStatus" -> result.success(mapOf("state" to HoneyProxyVpnService.nativeState))
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

    private fun startVpn(configJson: String, locale: String, result: MethodChannel.Result) {
        val intent = Intent(context, HoneyProxyVpnService::class.java).apply {
            action = HoneyProxyVpnService.ACTION_START
            putExtra("config_json", configJson)
            putExtra("locale", locale)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
            else context.startService(intent)
        } catch (e: Exception) {
            // ForegroundServiceStartNotAllowedException (Android 12+) if the app
            // transitions to background at the exact moment the user taps connect.
            android.util.Log.e("NativeBindings", "startForegroundService failed: ${e.message}", e)
            result.error("START_FAILED", "Cannot start the Android VPN service", null)
            return
        }
        try { result.success(null) } catch (_: Exception) { /* Captured engine disposed. */ }
    }

    private fun stopVpn(result: MethodChannel.Result) {
        val requestId = stopRequests.register { error ->
            try {
                if (error == null) result.success(null)
                else result.error("STOP_FAILED", error, null)
            } catch (_: Exception) { /* The captured Flutter engine may already be disposed. */ }
        }
        mainHandler.postDelayed({ stopRequests.complete(requestId, "VPN stop could not be confirmed") }, 7000)
        val intent = Intent(context, HoneyProxyVpnService::class.java).apply {
            action = HoneyProxyVpnService.ACTION_STOP
            putExtra("stop_request_id", requestId)
        }
        try { context.startService(intent) }
        catch (_: Exception) { stopRequests.complete(requestId, "Cannot stop the Android VPN service") }
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
        synchronized(channelOwners) {
            // A recreated Activity can reuse its Flutter engine/messenger.
            // Its old binding must not remove the new binding's handlers.
            if (channelOwners[messenger] === this) {
                channelOwners.remove(messenger)
                methodChannel.setMethodCallHandler(null)
                eventChannel.setStreamHandler(null)
                nativeChannel.setMethodCallHandler(null)
                deeplinkChannel.setStreamHandler(null)
            }
        }
        eventSink = null
        deeplinkSink = null
    }
}
