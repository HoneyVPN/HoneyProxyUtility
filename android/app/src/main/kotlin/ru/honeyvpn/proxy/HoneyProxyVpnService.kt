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
    @Volatile private var statsConnection: HttpURLConnection? = null

    // Incremented on every start/stop. Each background thread captures its generation at launch
    // and exits silently if it no longer matches — prevents stale threads from corrupting
    // state when a new connection starts before the old one fully tears down.
    @Volatile private var generation = 0

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val configJson = intent.getStringExtra("config_json") ?: return START_NOT_STICKY
                startTunnel(configJson)
                return START_STICKY
            }
            ACTION_STOP -> {
                stopTunnel()
                return START_NOT_STICKY
            }
        }
        return START_NOT_STICKY
    }

    private fun startTunnel(configJson: String) {
        // Increment generation BEFORE cleanup so old background threads see the new value
        // immediately and exit without touching shared state.
        if (isRunning || sbProcess != null || t2sPid > 0) {
            Log.d(TAG, "Cleaning up existing session before restart")
            generation++
            cleanupResources()
        }

        val myGen = ++generation
        Log.d(TAG, "Starting VPN tunnel (gen=$myGen)")

        try {
        startForeground(NOTIFICATION_ID, buildNotification("Подключение..."))

        val builder = Builder()
            .setSession("HoneyProxyUtility")
            .addAddress("172.19.0.1", 30)
            .addAddress("fdfe:dcba:9876::1", 126)
            .addDnsServer("172.19.0.2")
            .addRoute("0.0.0.0", 0)
            .addRoute("::", 0)
            .setMtu(1500)
            .setBlocking(false)

        try { builder.addDisallowedApplication(packageName) } catch (_: Exception) {}

        tunFd?.close()
        val pfd = builder.establish() ?: run {
            Log.e(TAG, "Failed to establish VPN interface")
            notifyError("Failed to establish VPN interface", myGen)
            return
        }
        tunFd = pfd
        val rawFd = pfd.fd
        Log.d(TAG, "TUN established: fd=$rawFd")

        isRunning = true
        Thread { launchSingboxAndTun2socks(configJson, rawFd, myGen) }
            .also { it.isDaemon = true; it.start() }
        } catch (e: Exception) {
            Log.e(TAG, "startTunnel error: ${e.message}", e)
            if (generation == myGen) notifyError(e.message ?: "startup error", myGen)
        }
    }

    /** Kills all running child processes and releases resources. Does not affect service lifecycle. */
    private fun cleanupResources() {
        isRunning = false

        try { statsConnection?.disconnect() } catch (_: Exception) {}
        statsConnection = null

        val pid = t2sPid
        if (pid > 0) {
            android.os.Process.killProcess(pid)
            Thread { NativeLauncher.waitForPid(pid) }.also { it.isDaemon = true; it.start() }
            t2sPid = -1
        }

        val pipePfd = t2sPipePfd; t2sPipePfd = null
        try { pipePfd?.close() } catch (_: Exception) {}

        val sb = sbProcess; sbProcess = null
        sb?.destroyForcibly()
        if (sb != null) {
            Thread { try { sb.waitFor(5, TimeUnit.SECONDS) } catch (_: Exception) {} }
                .also { it.isDaemon = true; it.start() }
        }

        statsPollThread?.interrupt(); statsPollThread = null
        watchdogThread?.interrupt(); watchdogThread = null
        val tunSnapshot = tunFd; tunFd = null
        try { tunSnapshot?.close() } catch (_: Exception) {}
    }

    private fun launchSingboxAndTun2socks(configJson: String, tunRawFd: Int, gen: Int) {
        try {
            if (generation != gen) { Log.d(TAG, "gen=$gen superseded, abort"); return }

            val cfgFile = File(cacheDir, "sbconfig.json")
            cfgFile.writeText(configJson)

            val sbPath = "${applicationInfo.nativeLibraryDir}/libsingbox.so"
            if (!File(sbPath).exists()) {
                if (generation == gen) notifyError("sing-box not found", gen)
                return
            }

            // Wait for port 2080 to be free from previous session
            waitForPortFree("127.0.0.1", SOCKS_PORT, 6_000)
            if (generation != gen) return

            val sbProc = ProcessBuilder(sbPath, "run", "-c", cfgFile.absolutePath)
                .redirectErrorStream(true).start()
            if (generation != gen) { sbProc.destroyForcibly(); return }
            sbProcess = sbProc

            val sbOutput = StringBuilder()
            Thread {
                sbProc.inputStream.bufferedReader().forEachLine { line ->
                    Log.d(TAG, "sb: $line")
                    synchronized(sbOutput) { sbOutput.appendLine(line) }
                }
            }.also { it.isDaemon = true; it.start() }

            if (!waitForPort("127.0.0.1", SOCKS_PORT, 10_000)) {
                if (generation != gen) return
                val err = synchronized(sbOutput) { sbOutput.takeLast(500).toString().trim() }
                Log.e(TAG, "sing-box not ready:\n$err")
                sbProc.destroyForcibly(); sbProcess = null; isRunning = false
                notifyError("sing-box failed: $err", gen)
                return
            }
            if (generation != gen) return
            Log.d(TAG, "sing-box SOCKS5 ready on port $SOCKS_PORT")

            val t2sPath = "${applicationInfo.nativeLibraryDir}/libtun2socks.so"
            if (!File(t2sPath).exists()) {
                if (generation == gen) notifyError("tun2socks not found", gen)
                sbProc.destroyForcibly(); sbProcess = null; isRunning = false
                return
            }

            val readFdArr = IntArray(1) { -1 }
            val pid = NativeLauncher.forkExecTun2socks(t2sPath, tunRawFd, SOCKS_PORT, readFdArr)
            if (generation != gen) {
                if (pid > 0) {
                    android.os.Process.killProcess(pid)
                    Thread { NativeLauncher.waitForPid(pid) }.also { it.isDaemon = true; it.start() }
                }
                sbProc.destroyForcibly(); sbProcess = null
                return
            }
            if (pid <= 0) {
                notifyError("tun2socks launch failed", gen)
                sbProc.destroyForcibly(); sbProcess = null; isRunning = false
                return
            }
            t2sPid = pid
            Log.d(TAG, "tun2socks started PID=$pid: fd=$tunRawFd → socks5://127.0.0.1:$SOCKS_PORT")

            // Pipe for capturing tun2socks output
            val t2sExited = java.util.concurrent.atomic.AtomicBoolean(false)
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
                    t2sExited.set(true)
                    try { pipePfd.close() } catch (_: Exception) {}
                    if (t2sPipePfd === pipePfd) t2sPipePfd = null
                }.also { it.isDaemon = true; it.start() }
            }

            // Watchdog: monitors both processes for unexpected death.
            // Guards on generation so it exits silently if a newer connection takes over.
            watchdogThread = Thread {
                while (isRunning && generation == gen) {
                    val sbDead = try { sbProc.exitValue(); true } catch (_: IllegalThreadStateException) { false }
                    val t2sDead = if (readFd >= 0) t2sExited.get()
                                  else (pid > 0 && !File("/proc/$pid").exists())
                    if (sbDead || t2sDead) {
                        if (isRunning && generation == gen) {
                            val err = synchronized(sbOutput) { sbOutput.takeLast(500).toString().trim() }
                            Log.e(TAG, "Process died unexpectedly: sb=$sbDead t2s=$t2sDead\n$err")
                            if (!sbDead) sbProc.destroyForcibly()
                            if (t2sDead && pid > 0) NativeLauncher.waitForPid(pid)
                            isRunning = false; sbProcess = null; t2sPid = -1
                            // Close TUN fd that would otherwise leak until GC
                            val tunSnapshot = tunFd; tunFd = null
                            try { tunSnapshot?.close() } catch (_: Exception) {}
                            NativeBindings.onVpnStopped()
                            // Stop the zombie foreground service — without this the notification
                            // stays visible ("Подключено") even though VPN is dead.
                            stopForeground(STOP_FOREGROUND_REMOVE)
                            stopSelf()
                        }
                        return@Thread
                    }
                    try { Thread.sleep(500) } catch (_: InterruptedException) { return@Thread }
                }
            }.also { it.isDaemon = true; it.start() }

            if (generation != gen) return
            updateNotification("Подключено")
            NativeBindings.onVpnStarted()
            startStatsPolling(gen)

        } catch (e: Exception) {
            if (generation == gen) {
                Log.e(TAG, "launchSingboxAndTun2socks error: ${e.message}", e)
                notifyError(e.message ?: "unknown error", gen)
            }
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

    private fun startStatsPolling(gen: Int) {
        statsPollThread = Thread {
            var totalUp = 0L; var totalDown = 0L
            val startMs = System.currentTimeMillis()
            try {
                val conn = URL("http://127.0.0.1:$CLASH_PORT/traffic").openConnection() as HttpURLConnection
                conn.connectTimeout = 5000; conn.readTimeout = 0
                statsConnection = conn
                conn.connect()
                conn.inputStream.bufferedReader().use { reader ->
                    var line = reader.readLine()
                    while (line != null && isRunning && generation == gen) {
                        try {
                            val j = JSONObject(line)
                            val up = j.optLong("up"); val dn = j.optLong("down")
                            totalUp += up; totalDown += dn
                            NativeBindings.pushStats(up, dn, totalUp, totalDown,
                                (System.currentTimeMillis() - startMs) / 1000)
                        } catch (_: Exception) {}
                        line = reader.readLine()
                    }
                }
            } catch (e: Exception) {
                if (isRunning && generation == gen) Log.w(TAG, "Clash API: ${e.message}")
                val t0 = System.currentTimeMillis()
                while (isRunning && generation == gen) {
                    try {
                        NativeBindings.pushStats(0, 0, 0, 0, (System.currentTimeMillis() - t0) / 1000)
                        Thread.sleep(1000)
                    } catch (_: InterruptedException) { break }
                }
            } finally {
                statsConnection = null
            }
        }.also { it.isDaemon = true; it.start() }
    }

    private fun stopTunnel() {
        val nothingToKill = !isRunning && sbProcess == null && t2sPid < 0
        if (nothingToKill) {
            // Watchdog already cleaned up processes — service might still be a foreground
            // zombie. Ensure it stops so the notification disappears.
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }
        Log.d(TAG, "Stopping VPN tunnel")
        generation++  // invalidate all background threads from previous connections
        cleanupResources()
        NativeBindings.onVpnStopped()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun notifyError(msg: String, gen: Int) {
        if (generation != gen) return  // superseded — don't clobber a newer session
        isRunning = false
        NativeBindings.onVpnError(msg)
        NativeBindings.onVpnStopped()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onRevoke() { super.onRevoke(); stopTunnel() }

    override fun onDestroy() {
        val wasActive = isRunning || sbProcess != null || t2sPid > 0
        generation++
        cleanupResources()
        if (wasActive) try { NativeBindings.onVpnStopped() } catch (ignored: Exception) {}
        super.onDestroy()
    }

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
