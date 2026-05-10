package ru.honeyvpn.proxy

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

class HoneyProxyVpnService : VpnService() {

    companion object {
        const val TAG = "HoneyVPN"
        const val ACTION_START = "ru.honeyvpn.proxy.START"
        const val ACTION_STOP  = "ru.honeyvpn.proxy.STOP"
        const val CHANNEL_ID   = "honeyvpn_vpn"
        const val NOTIFICATION_ID = 1001

        @Volatile
        var isRunning = false
            private set
    }

    private var tunFd: ParcelFileDescriptor? = null

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
        startForeground(NOTIFICATION_ID, buildNotification("Подключение..."))

        val builder = Builder()
            .setSession("HoneyProxyUtility")
            .addAddress("172.19.0.1", 30)
            .addAddress("fdfe:dcba:9876::1", 126)
            .addDnsServer("172.19.0.2")
            .addDnsServer("fdfe:dcba:9876::2")
            .addRoute("0.0.0.0", 0)
            .addRoute("::", 0)
            .setMtu(9000)
            .setBlocking(false)

        try { builder.addDisallowedApplication(packageName) } catch (_: Exception) {}

        tunFd?.close()
        tunFd = builder.establish() ?: run {
            Log.e(TAG, "Failed to establish VPN interface")
            stopSelf()
            return
        }

        isRunning = true
        updateNotification("Подключено")
        Log.d(TAG, "VPN tunnel started, fd=${tunFd!!.fd}")
        NativeBindings.onVpnStarted()
    }

    private fun stopTunnel() {
        Log.d(TAG, "Stopping VPN tunnel")
        isRunning = false
        try {
            tunFd?.close()
            tunFd = null
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping tunnel: ${e.message}")
        }
        NativeBindings.onVpnStopped()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onRevoke() { super.onRevoke(); stopTunnel() }
    override fun onDestroy() { stopTunnel(); super.onDestroy() }

    private fun buildNotification(status: String): Notification {
        createNotificationChannel()
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("HoneyProxyUtility")
            .setContentText(status)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pi)
            .setOngoing(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun updateNotification(status: String) {
        getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, buildNotification(status))
    }

    private fun createNotificationChannel() {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID, "HoneyProxyUtility VPN", NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "HoneyProxyUtility VPN connection status"
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }
}
