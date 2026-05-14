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
import java.util.concurrent.TimeUnit

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
    private var sbProcess: Process? = null
    private var t2sPid: Int = -1
    private var t2sPipePfd: ParcelFileDescriptor? = null
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
        val pfd = builder.establish() ?: run {
            Log.e(TAG, "Failed to establish VPN interface")
            stopSelf()
            return
        }
        tunFd = pfd
        val rawFd = pfd.fd
        Log.d(TAG, "TUN established: fd=$rawFd")

        isRunning = true
        Thread { launchSingboxAndTun2socks(configJson, rawFd) }.also { it.isDaemon = true; it.start() }
    }

    private fun launchSingboxAndTun2socks(configJson: String, tunRawFd: Int) {
        try {
            val cfgFile = File(cacheDir, "sbconfig.json")
            cfgFile.writeText(configJson)

            val sbPath = "${applicationInfo.nativeLibraryDir}/libsingbox.so"
            if (!File(sbPath).exists()) {
                Log.e(TAG, "sing-box binary not found"); notifyError("sing-box not found"); return
            }

            // 1. Wait for SOCKS port to be free (previous instance may still be shutting down)
            waitForPortFree("127.0.0.1", SOCKS_PORT, 5_000)

            // 2. Start sing-box (SOCKS5 only)
            val sbProc = ProcessBuilder(sbPath, "run", "-c", cfgFile.absolutePath)
                .redirectErrorStream(true).start()
            sbProcess = sbProc

            val sbOutput = StringBuilder()
            Thread {
                sbProc.inputStream.bufferedReader().forEachLine { line ->
                    Log.d(TAG, "sb: $line")
                    synchronized(sbOutput) { sbOutput.appendLine(line) }
                }
            }.also { it.isDaemon = true; it.start() }

            // 3. Wait for SOCKS5 port to be ready (up to 10s)
            if (!waitForPort("127.0.0.1", SOCKS_PORT, 10_000)) {
                val err = synchronized(sbOutput) { sbOutput.takeLast(500).toString().trim() }
                Log.e(TAG, "sing-box SOCKS5 not ready:\n$err")
                sbProc.destroyForcibly(); sbProcess = null
                isRunning = false; NativeBindings.onVpnStopped(); return
            }
            Log.d(TAG, "sing-box SOCKS5 ready on port $SOCKS_PORT")

            // 4. Start tun2socks via JNI fork+exec — bypasses Java's FD_CLOEXEC cleanup
            val t2sPath = "${applicationInfo.nativeLibraryDir}/libtun2socks.so"
            if (!File(t2sPath).exists()) {
                Log.e(TAG, "tun2socks not found"); notifyError("tun2socks not found")
                sbProc.destroyForcibly(); sbProcess = null
                isRunning = false; NativeBindings.onVpnStopped(); return
            }

            val readFdArr = IntArray(1) { -1 }
            val pid = NativeLauncher.forkExecTun2socks(t2sPath, tunRawFd, SOCKS_PORT, readFdArr)
            if (pid <= 0) {
                Log.e(TAG, "forkExecTun2socks failed (pid=$pid)")
                notifyError("tun2socks launch failed")
                sbProc.destroyForcibly(); sbProcess = null
                isRunning = false; NativeBindings.onVpnStopped(); return
            }
            t2sPid = pid
            Log.d(TAG, "tun2socks started PID=$pid: fd=$tunRawFd → socks5://127.0.0.1:$SOCKS_PORT")

            // 5. Read tun2socks output from pipe
            val readFd = readFdArr[0]
            if (readFd >= 0) {
                val pipePfd = ParcelFileDescriptor.adoptFd(readFd)
                t2sPipePfd = pipePfd
                Thread {
                    try {
                        java.io.FileInputStream(pipePfd.fileDescriptor).bufferedReader().forEachLine { line ->
                            Log.d(TAG, "t2s: $line")
                        }
                    } catch (_: Exception) {}
                    try { pipePfd.close() } catch (_: Exception) {}
                    if (t2sPipePfd === pipePfd) t2sPipePfd = null
                }.also { it.isDaemon = true; it.start() }
            }

            // 6. Watchdog
            watchdogThread = Thread {
                while (isRunning) {
                    val sbDead = try { sbProc.exitValue(); true } catch (_: IllegalThreadStateException) { false }
                    val t2sDead = pid > 0 && !File("/proc/$pid").exists()
                    if (sbDead || t2sDead) {
                        if (isRunning) {
                            val err = synchronized(sbOutput) { sbOutput.takeLast(500).toString().trim() }
                            Log.e(TAG, "Process died: sb=$sbDead t2s=$t2sDead\n$err")
                            isRunning = false; sbProcess = null; t2sPid = -1
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
            try { Socket().use { it.connect(InetSocketAddress(host, port), 500); return true } }
            catch (_: Exception) { Thread.sleep(200) }
        }
        return false
    }

    private fun waitForPortFree(host: String, port: Int, timeoutMs: Long) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            try {
                Socket().use { it.connect(InetSocketAddress(host, port), 200) }
                Thread.sleep(200)
            } catch (_: Exception) {
                return
            }
        }
        Log.w(TAG, "Port $port still busy after ${timeoutMs}ms, proceeding anyway")
    }

    private fun startStatsPolling() {
        statsPollThread = Thread {
            var totalUp = 0L; var totalDown = 0L
            val startMs = System.currentTimeMillis()
            try {
                val conn = URL("http://127.0.0.1:$CLASH_PORT/traffic").openConnection() as HttpURLConnection
                conn.connectTimeout = 5000; conn.readTimeout = 0; conn.connect()
                conn.inputStream.bufferedReader().forEachLine { line ->
                    if (!isRunning) return@forEachLine
                    try {
                        val j = JSONObject(line)
                        val up = j.optLong("up"); val dn = j.optLong("down")
                        totalUp += up; totalDown += dn
                        NativeBindings.pushStats(up, dn, totalUp, totalDown,
                            (System.currentTimeMillis() - startMs) / 1000)
                    } catch (_: Exception) {}
                }
            } catch (e: Exception) {
                Log.w(TAG, "Clash API unavailable: ${e.message}")
                val t0 = System.currentTimeMillis()
                while (isRunning) {
                    try {
                        NativeBindings.pushStats(0, 0, 0, 0, (System.currentTimeMillis() - t0) / 1000)
                        Thread.sleep(1000)
                    } catch (_: InterruptedException) { break }
                }
            }
        }.also { it.isDaemon = true; it.start() }
    }

    private fun stopTunnel() {
        Log.d(TAG, "Stopping VPN tunnel")
        isRunning = false

        // Kill tun2socks (forked via JNI, tracked by PID)
        val pid = t2sPid
        if (pid > 0) { android.os.Process.killProcess(pid); t2sPid = -1 }

        // Close pipe read end (unblocks the reader thread)
        val pipePfd = t2sPipePfd; t2sPipePfd = null
        try { pipePfd?.close() } catch (_: Exception) {}

        // Kill sing-box with SIGKILL and wait for it to exit (prevents port 2080 conflict on reconnect)
        val sb = sbProcess; sbProcess = null
        sb?.destroyForcibly()
        try { sb?.waitFor(3, TimeUnit.SECONDS) } catch (_: Exception) {}

        statsPollThread?.interrupt(); statsPollThread = null
        watchdogThread?.interrupt(); watchdogThread = null
        try { tunFd?.close(); tunFd = null } catch (_: Exception) {}

        NativeBindings.onVpnStopped()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun notifyError(msg: String) {
        isRunning = false; NativeBindings.onVpnStopped()
        stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
    }

    override fun onRevoke() { super.onRevoke(); stopTunnel() }
    override fun onDestroy() { stopTunnel(); super.onDestroy() }

    private fun buildNotification(status: String): Notification {
        createNotificationChannel()
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("HoneyProxyUtility").setContentText(status)
            .setSmallIcon(android.R.drawable.ic_lock_lock).setContentIntent(pi)
            .setOngoing(true).setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun updateNotification(status: String) {
        getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, buildNotification(status))
    }

    private fun createNotificationChannel() {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.createNotificationChannel(NotificationChannel(
            CHANNEL_ID, "HoneyProxyUtility VPN", NotificationManager.IMPORTANCE_LOW
        ).apply { description = "HoneyProxyUtility VPN connection status"; setShowBadge(false) })
    }
}
