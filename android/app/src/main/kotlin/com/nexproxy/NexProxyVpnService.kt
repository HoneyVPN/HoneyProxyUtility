package com.nexproxy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * NexProxy VPN Service — wraps sing-box (libbox) via JNI.
 *
 * Communication with Flutter:
 * - Start: ACTION_START intent with "config_json" extra
 * - Stop:  ACTION_STOP  intent
 * - Stats: EventChannel "com.nexproxy/vpn_stats" via NativeBindings
 */
class NexProxyVpnService : VpnService() {

    companion object {
        const val TAG = "NexProxyVPN"
        const val ACTION_START = "com.nexproxy.START"
        const val ACTION_STOP  = "com.nexproxy.STOP"
        const val CHANNEL_ID   = "nexproxy_vpn"
        const val NOTIFICATION_ID = 1001

        @Volatile
        var isRunning = false
            private set
    }

    private var tunFd: ParcelFileDescriptor? = null
    private var libboxService: Any? = null  // LibboxServiceProtocol once libbox is integrated

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val configJson = intent.getStringExtra("config_json") ?: return START_NOT_STICKY
                startTunnel(configJson)
            }
            ACTION_STOP -> stopTunnel()
        }
        return START_REDELIVER_INTENT
    }

    private fun startTunnel(configJson: String) {
        Log.d(TAG, "Starting VPN tunnel")

        startForeground(NOTIFICATION_ID, buildNotification("Connecting..."))

        // Build TUN interface
        val builder = Builder()
            .setSession("NexProxy")
            .addAddress("172.19.0.1", 30)
            .addAddress("fdfe:dcba:9876::1", 126)
            .addDnsServer("172.19.0.2")      // FakeIP gateway
            .addDnsServer("fdfe:dcba:9876::2")
            .addRoute("0.0.0.0", 0)
            .addRoute("::", 0)
            .setMtu(9000)
            .setBlocking(false)

        // Exclude self to prevent loops
        try { builder.addDisallowedApplication(packageName) } catch (_: Exception) {}

        tunFd?.close()
        tunFd = builder.establish() ?: run {
            Log.e(TAG, "Failed to establish VPN interface")
            stopSelf()
            return
        }

        isRunning = true

        // TODO: Pass configJson and tunFd.fd to libbox once JNI is integrated
        // libboxService = LibboxNewService(configJson, this)
        // libboxService.setTunFd(tunFd!!.detachFd())
        // libboxService.start()

        updateNotification("Connected")
        Log.d(TAG, "VPN tunnel started, fd=${tunFd!!.fd}")

        // Notify Flutter via EventSink
        NativeBindings.onVpnStarted()
    }

    private fun stopTunnel() {
        Log.d(TAG, "Stopping VPN tunnel")
        isRunning = false
        try {
            // libboxService?.close()
            tunFd?.close()
            tunFd = null
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping tunnel: ${e.message}")
        }
        NativeBindings.onVpnStopped()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onRevoke() {
        super.onRevoke()
        stopTunnel()
    }

    override fun onDestroy() {
        stopTunnel()
        super.onDestroy()
    }

    private fun buildNotification(status: String): Notification {
        createNotificationChannel()
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("NexProxy")
            .setContentText(status)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pi)
            .setOngoing(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun updateNotification(status: String) {
        val nm = getSystemService(NotificationManager::class.java)
        nm?.notify(NOTIFICATION_ID, buildNotification(status))
    }

    private fun createNotificationChannel() {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID, "VPN Status", NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "NexProxy VPN connection status"
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }
}
