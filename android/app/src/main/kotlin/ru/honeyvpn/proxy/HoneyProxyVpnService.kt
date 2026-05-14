package ru.honeyvpn.proxy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

class HoneyProxyVpnService : VpnService() {

    companion object {
        const val TAG = "HoneyVPN"
        const val ACTION_START = "ru.honeyvpn.proxy.START"
        const val ACTION_STOP  = "ru.honeyvpn.proxy.STOP"
        const val CHANNEL_ID   = "honeyvpn_vpn"
        const val NOTIFICATION_ID = 1001
        private const val CLASH_PORT = 9090

        @Volatile
        var isRunning = false
            private set
    }

    private var tunFd: ParcelFileDescriptor? = null
    private var sbProcess: Process? = null
    private var statsPollThread: Thread? = null
    private var watchdogThread: Thread? = null

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
        val fd = builder.establish() ?: run {
            Log.e(TAG, "Failed to establish VPN interface")
            stopSelf()
            return
        }
        tunFd = fd

        // Try to clear O_CLOEXEC so sing-box inherits the fd; hidden API so use reflection.
        // Non-fatal: on Android the fd is inherited anyway even if this fails.
        try {
            val fcntl = Class.forName("android.system.Os").getMethod(
                "fcntl", java.io.FileDescriptor::class.java,
                Int::class.javaPrimitiveType!!, Int::class.javaPrimitiveType!!
            )
            fcntl.invoke(null, fd.fileDescriptor, 2 /* F_SETFD */, 0)
            Log.d(TAG, "CLOEXEC cleared on TUN fd")
        } catch (e: Exception) {
            Log.w(TAG, "fcntl CLOEXEC skipped: ${e.message}")
        }

        val rawFd = fd.fd
        Log.d(TAG, "TUN established, fd=$rawFd")

        isRunning = true
        Thread { launchSingbox(configJson, rawFd) }.also { it.isDaemon = true; it.start() }
    }

    private fun launchSingbox(configJson: String, rawFd: Int) {
        try {
            val cfg = JSONObject(configJson)
            val inbounds = cfg.getJSONArray("inbounds")
            for (i in 0 until inbounds.length()) {
                val inb = inbounds.getJSONObject(i)
                if (inb.optString("type") == "tun") {
                    inb.put("fd", rawFd)
                    break
                }
            }

            val cfgFile = File(cacheDir, "sbconfig.json")
            cfgFile.writeText(cfg.toString())

            val sbPath = "${applicationInfo.nativeLibraryDir}/libsingbox.so"
            if (!File(sbPath).exists()) {
                Log.e(TAG, "sing-box binary not found: $sbPath")
                notifyError("sing-box binary not found")
                return
            }

            val proc = ProcessBuilder(sbPath, "run", "-c", cfgFile.absolutePath)
                .redirectErrorStream(true)
                .start()
            sbProcess = proc

            val logFile = File(cacheDir, "singbox.log")
            val sbOutput = StringBuilder()
            Thread {
                proc.inputStream.bufferedReader().forEachLine { line ->
                    Log.d(TAG, "sb: $line")
                    synchronized(sbOutput) { sbOutput.appendLine(line) }
                }
                try { logFile.writeText(sbOutput.toString()) } catch (_: Exception) {}
            }.also { it.isDaemon = true; it.start() }

            watchdogThread = Thread {
                val code = proc.waitFor()
                if (sbProcess == proc) {
                    val errMsg = synchronized(sbOutput) { sbOutput.takeLast(500).toString().trim() }
                    Log.e(TAG, "sing-box exited unexpectedly: code=$code\n$errMsg")
                    try { logFile.writeText(sbOutput.toString()) } catch (_: Exception) {}
                    sbProcess = null
                    isRunning = false
                    NativeBindings.onVpnStopped()
                }
            }.also { it.isDaemon = true; it.start() }

            Thread.sleep(1500)
            if (sbProcess == null) {
                val errMsg = synchronized(sbOutput) { sbOutput.takeLast(500).toString().trim() }
                Log.e(TAG, "sing-box exited during startup:\n$errMsg")
                return
            }

            updateNotification("Подключено")
            NativeBindings.onVpnStarted()
            startStatsPolling()

        } catch (e: Exception) {
            Log.e(TAG, "launchSingbox error: ${e.message}", e)
            notifyError(e.message ?: "unknown error")
        }
    }

    private fun startStatsPolling() {
        statsPollThread = Thread {
            var totalUp = 0L
            var totalDown = 0L
            val startMs = System.currentTimeMillis()
            try {
                val conn = URL("http://127.0.0.1:$CLASH_PORT/traffic")
                    .openConnection() as HttpURLConnection
                conn.connectTimeout = 5000
                conn.readTimeout = 0
                conn.connect()
                conn.inputStream.bufferedReader().forEachLine { line ->
                    if (!isRunning || sbProcess == null) return@forEachLine
                    try {
                        val json = JSONObject(line)
                        val up = json.optLong("up")
                        val down = json.optLong("down")
                        totalUp += up
                        totalDown += down
                        val duration = (System.currentTimeMillis() - startMs) / 1000
                        NativeBindings.pushStats(up, down, totalUp, totalDown, duration)
                    } catch (_: Exception) {}
                }
            } catch (e: Exception) {
                Log.w(TAG, "Clash API unavailable, fallback timer: ${e.message}")
                val fbStart = System.currentTimeMillis()
                while (isRunning && sbProcess != null) {
                    try {
                        val duration = (System.currentTimeMillis() - fbStart) / 1000
                        NativeBindings.pushStats(0L, 0L, 0L, 0L, duration)
                        Thread.sleep(1000)
                    } catch (_: InterruptedException) { break }
                }
            }
        }.also { it.isDaemon = true; it.start() }
    }

    private fun stopTunnel() {
        Log.d(TAG, "Stopping VPN tunnel")
        isRunning = false
        sbProcess?.destroy()
        sbProcess = null
        statsPollThread?.interrupt()
        statsPollThread = null
        watchdogThread?.interrupt()
        watchdogThread = null
        try { tunFd?.close(); tunFd = null } catch (e: Exception) {
            Log.e(TAG, "Error closing TUN: ${e.message}")
        }
        NativeBindings.onVpnStopped()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun notifyError(msg: String) {
        isRunning = false
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
        getSystemService(NotificationManager::class.java)
            ?.notify(NOTIFICATION_ID, buildNotification(status))
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
