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
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL

class HoneyProxyVpnService : VpnService() {

    companion object {
        const val TAG = "HoneyVPN"
        const val ACTION_START = "ru.honeyvpn.proxy.START"
        const val ACTION_STOP  = "ru.honeyvpn.proxy.STOP"
        const val CHANNEL_ID   = "honeyvpn_vpn"
        const val NOTIFICATION_ID = 1001
        private const val CLASH_PORT = 9090
        private const val SOCKS_PORT = 2080

        @Volatile
        var isRunning = false
            private set
    }

    private var tunFd: ParcelFileDescriptor? = null
    private var tunFdDup: ParcelFileDescriptor? = null  // dup without CLOEXEC for tun2socks
    private var sbProcess: Process? = null
    private var t2sProcess: Process? = null
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
        tunFdDup?.close()
        val pfd = builder.establish() ?: run {
            Log.e(TAG, "Failed to establish VPN interface")
            stopSelf()
            return
        }
        tunFd = pfd

        // dup() creates a copy of the fd WITHOUT FD_CLOEXEC (POSIX: dup clears CLOEXEC).
        // This lets the tun2socks subprocess inherit the fd through exec().
        val dupPfd = try {
            pfd.dup()
        } catch (e: Exception) {
            Log.e(TAG, "dup() failed: ${e.message}")
            pfd.close()
            stopSelf()
            return
        }
        tunFdDup = dupPfd
        val rawFd = dupPfd.fd
        Log.d(TAG, "TUN established: fd=$rawFd (dup of ${pfd.fd})")

        isRunning = true
        Thread { launchSingboxAndTun2socks(configJson, rawFd) }.also { it.isDaemon = true; it.start() }
    }

    private fun launchSingboxAndTun2socks(configJson: String, tunRawFd: Int) {
        try {
            val cfgFile = File(cacheDir, "sbconfig.json")
            cfgFile.writeText(configJson)

            val sbPath = "${applicationInfo.nativeLibraryDir}/libsingbox.so"
            if (!File(sbPath).exists()) {
                Log.e(TAG, "sing-box binary not found: $sbPath")
                notifyError("sing-box binary not found")
                return
            }

            // 1. Start sing-box with SOCKS5 inbound only (no TUN inbound)
            val sbProc = ProcessBuilder(sbPath, "run", "-c", cfgFile.absolutePath)
                .redirectErrorStream(true)
                .start()
            sbProcess = sbProc

            val sbOutput = StringBuilder()
            Thread {
                sbProc.inputStream.bufferedReader().forEachLine { line ->
                    Log.d(TAG, "sb: $line")
                    synchronized(sbOutput) { sbOutput.appendLine(line) }
                }
            }.also { it.isDaemon = true; it.start() }

            // 2. Wait for sing-box SOCKS5 to be ready (up to 10s)
            val socksReady = waitForPort("127.0.0.1", SOCKS_PORT, timeoutMs = 10_000)
            if (!socksReady) {
                val errMsg = synchronized(sbOutput) { sbOutput.takeLast(500).toString().trim() }
                Log.e(TAG, "sing-box SOCKS5 not ready in 10s:\n$errMsg")
                sbProc.destroy()
                sbProcess = null
                isRunning = false
                NativeBindings.onVpnStopped()
                return
            }
            Log.d(TAG, "sing-box SOCKS5 ready on port $SOCKS_PORT")

            // 3. Start tun2socks: inherited fd → sing-box SOCKS5
            val t2sPath = "${applicationInfo.nativeLibraryDir}/libtun2socks.so"
            if (!File(t2sPath).exists()) {
                Log.e(TAG, "tun2socks binary not found: $t2sPath")
                notifyError("tun2socks binary not found")
                sbProc.destroy(); sbProcess = null
                isRunning = false
                NativeBindings.onVpnStopped()
                return
            }

            val t2sProc = ProcessBuilder(
                t2sPath,
                "-device", "fd://$tunRawFd",
                "-proxy", "socks5://127.0.0.1:$SOCKS_PORT",
                "-loglevel", "warn"
            ).redirectErrorStream(true).start()
            t2sProcess = t2sProc
            Log.d(TAG, "tun2socks started: fd=$tunRawFd → socks5://127.0.0.1:$SOCKS_PORT")

            Thread {
                t2sProc.inputStream.bufferedReader().forEachLine { line ->
                    Log.d(TAG, "t2s: $line")
                }
            }.also { it.isDaemon = true; it.start() }

            // 4. Watchdog: if either process dies, stop the tunnel
            watchdogThread = Thread {
                while (isRunning) {
                    val sbDead = try { sbProc.exitValue(); true } catch (_: IllegalThreadStateException) { false }
                    val t2sDead = try { t2sProc.exitValue(); true } catch (_: IllegalThreadStateException) { false }
                    if (sbDead || t2sDead) {
                        if (sbProcess == sbProc || t2sProcess == t2sProc) {
                            val errMsg = synchronized(sbOutput) { sbOutput.takeLast(500).toString().trim() }
                            Log.e(TAG, "Process exited unexpectedly: sb=$sbDead t2s=$t2sDead\n$errMsg")
                            sbProcess = null; t2sProcess = null
                            isRunning = false
                            NativeBindings.onVpnStopped()
                        }
                        return@Thread
                    }
                    Thread.sleep(500)
                }
            }.also { it.isDaemon = true; it.start() }

            updateNotification("Подключено")
            NativeBindings.onVpnStarted()
            startStatsPolling()

        } catch (e: Exception) {
            Log.e(TAG, "launchSingboxAndTun2socks error: ${e.message}", e)
            notifyError(e.message ?: "unknown error")
        }
    }

    private fun waitForPort(host: String, port: Int, timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            try {
                Socket().use { s -> s.connect(InetSocketAddress(host, port), 500); return true }
            } catch (_: Exception) {
                Thread.sleep(200)
            }
        }
        return false
    }

    private fun startStatsPolling() {
        statsPollThread = Thread {
            var totalUp = 0L; var totalDown = 0L
            val startMs = System.currentTimeMillis()
            try {
                val conn = URL("http://127.0.0.1:$CLASH_PORT/traffic").openConnection() as HttpURLConnection
                conn.connectTimeout = 5000; conn.readTimeout = 0; conn.connect()
                conn.inputStream.bufferedReader().forEachLine { line ->
                    if (!isRunning || sbProcess == null) return@forEachLine
                    try {
                        val json = JSONObject(line)
                        val up = json.optLong("up"); val down = json.optLong("down")
                        totalUp += up; totalDown += down
                        NativeBindings.pushStats(up, down, totalUp, totalDown,
                            (System.currentTimeMillis() - startMs) / 1000)
                    } catch (_: Exception) {}
                }
            } catch (e: Exception) {
                Log.w(TAG, "Clash API unavailable: ${e.message}")
                val fbStart = System.currentTimeMillis()
                while (isRunning && sbProcess != null) {
                    try {
                        NativeBindings.pushStats(0L, 0L, 0L, 0L,
                            (System.currentTimeMillis() - fbStart) / 1000)
                        Thread.sleep(1000)
                    } catch (_: InterruptedException) { break }
                }
            }
        }.also { it.isDaemon = true; it.start() }
    }

    private fun stopTunnel() {
        Log.d(TAG, "Stopping VPN tunnel")
        isRunning = false
        t2sProcess?.destroy(); t2sProcess = null
        sbProcess?.destroy(); sbProcess = null
        statsPollThread?.interrupt(); statsPollThread = null
        watchdogThread?.interrupt(); watchdogThread = null
        try { tunFdDup?.close(); tunFdDup = null } catch (_: Exception) {}
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
        nm.createNotificationChannel(NotificationChannel(
            CHANNEL_ID, "HoneyProxyUtility VPN", NotificationManager.IMPORTANCE_LOW
        ).apply { description = "HoneyProxyUtility VPN connection status"; setShowBadge(false) })
    }
}
