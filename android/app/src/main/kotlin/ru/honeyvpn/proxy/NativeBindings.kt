package ru.honeyvpn.proxy

import android.content.Context
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

    private val methodChannel = MethodChannel(messenger, "ru.honeyvpn.proxy/vpn")
    private val eventChannel  = EventChannel(messenger, "ru.honeyvpn.proxy/vpn_stats")
    private val nativeChannel = MethodChannel(messenger, "ru.honeyvpn.proxy/native")
    private var eventSink: EventChannel.EventSink? = null

    companion object {
        private var instance: NativeBindings? = null

        fun onVpnStarted() = instance?.eventSink?.success(mapOf(
            "event" to "started",
            "uplink" to 0, "downlink" to 0,
            "uplinkTotal" to 0, "downlinkTotal" to 0, "duration" to 0,
        ))

        fun onVpnStopped() = instance?.eventSink?.success(mapOf("event" to "stopped"))

        fun pushStats(
            uplink: Long, downlink: Long,
            uplinkTotal: Long, downlinkTotal: Long,
            durationSeconds: Long,
        ) = instance?.eventSink?.success(mapOf(
            "event" to "stats",
            "uplink" to uplink,
            "downlink" to downlink,
            "uplinkTotal" to uplinkTotal,
            "downlinkTotal" to downlinkTotal,
            "duration" to durationSeconds,
        ))
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
            "getStats" -> {
                result.success(mapOf(
                    "uplink" to 0L, "downlink" to 0L,
                    "uplinkTotal" to 0L, "downlinkTotal" to 0L,
                    "duration" to 0L,
                ))
            }
            else -> result.notImplemented()
        }
    }

    private fun startVpn(configJson: String) {
        val intent = Intent(context, HoneyProxyVpnService::class.java).apply {
            action = HoneyProxyVpnService.ACTION_START
            putExtra("config_json", configJson)
        }
        context.startForegroundService(intent)
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
        instance = null
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        nativeChannel.setMethodCallHandler(null)
    }
}
