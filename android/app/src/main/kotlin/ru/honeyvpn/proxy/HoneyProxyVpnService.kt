package ru.honeyvpn.proxy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Handler
import android.os.Build
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.system.Os
import android.util.Log
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

class HoneyProxyVpnService : VpnService() {
    companion object {
        const val TAG = "HoneyVPN"
        const val ACTION_START = "ru.honeyvpn.proxy.START"
        const val ACTION_STOP = "ru.honeyvpn.proxy.STOP"
        const val CHANNEL_ID = "honeyvpn_vpn"
        const val NOTIFICATION_ID = 1001
        private const val CLASH_PORT = 9090
        // Sequence short native fork sections across service instances. JNI
        // changes CLOEXEC only in the child; the parent dup always stays private.
        private val nativeForkLock = Any()
        private val serviceOwnerLock = Any()
        // One component can be recreated before the old instance has finished
        // closing. Queue commands, while every cleanup still owns its snapshot.
        private val lifecycle = Executors.newSingleThreadExecutor { task ->
            Thread(task, "HoneyVPN-lifecycle").also { it.isDaemon = true }
        }
        private val retirements = ConfirmedSessionCleanup<Pair<HoneyProxyVpnService, Session>>()
        @Volatile var nativeState = "DISCONNECTED"
            private set
        @Volatile private var activeService: HoneyProxyVpnService? = null
        @Volatile var isRunning = false
            private set

        // Update only an existing notification; never creates a service or a
        // session and never turns a language change into a VPN command.
        fun setNotificationLocale(locale: String): Boolean {
            if (locale != "ru" && locale != "en") return false
            val owner = synchronized(serviceOwnerLock) { activeService } ?: return false
            owner.mainHandler.post {
                synchronized(serviceOwnerLock) {
                    if (activeService === owner && owner.notificationLocale != locale) {
                        owner.notificationLocale = locale
                        if (nativeState != "DISCONNECTED") {
                            try { owner.updateNotification(nativeState) } catch (_: Exception) {}
                        }
                    }
                }
            }
            return true
        }
    }

    private class Session(val directory: File) {
        val configuration = File(directory, "config.json")
        val controllerSecret = UUID.randomUUID().toString()
        var tun: ParcelFileDescriptor? = null
        var core: Process? = null
        var forwarderPid = -1
        var pipe: ParcelFileDescriptor? = null
        var statsThread: Thread? = null
        var watchdog: Thread? = null
        var statsConnection: HttpURLConnection? = null
        val startupFinished = CountDownLatch(1)
        val pipeReaderFinished = CountDownLatch(1)
        @Volatile var startupLaunched = false
        @Volatile var pipeReaderLaunched = false
        @Volatile var unpublishedCore: Process? = null
        @Volatile var unpublishedForwarder = -1
        @Volatile var ready = false
    }

    private val sessions = VpnSessionGate<Session>()
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var notificationLocale = "en"

    override fun onCreate() {
        super.onCreate()
        val previous = synchronized(serviceOwnerLock) {
            val old = activeService
            activeService = this
            isRunning = false
            if (nativeState != "DISCONNECTED") nativeState = "DISCONNECTING"
            old
        }
        if (previous != null && previous !== this) {
            val retirement = previous.sessions.command()
            lifecycle.execute { previous.finishRetirement(retirement, null, null, false) }
        }
    }

    private fun state(value: String) = synchronized(serviceOwnerLock) {
        if (activeService === this) { nativeState = value; isRunning = value == "CONNECTED"; HoneyDiagnostics.add(value) }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val retirement = sessions.command { if (nativeState != "DISCONNECTED") state("DISCONNECTING") }
        if (intent?.action == ACTION_START) {
            val configuration = intent.getStringExtra("config_json")
            notificationLocale = if (intent.getStringExtra("locale") == "ru") "ru" else "en"
            try { startForeground(NOTIFICATION_ID, buildNotification("CONNECTING")) }
            catch (_: Exception) {
                lifecycle.execute { finishRetirement(retirement, "Cannot start the Android VPN service", null, true) }
                return START_NOT_STICKY
            }
            lifecycle.execute {
                retirement.session?.let { retirements.retain(this to it) }
                if (!drainRetirements()) {
                    NativeBindings.onVpnError("VPN stop could not be confirmed", retiredDispatch(retirement))
                } else if (configuration != null) {
                    startTunnel(configuration, retirement.command)
                } else {
                    finishRetirement(retirement, "VPN configuration is missing", null, true)
                }
            }
        } else {
            val request = intent?.getStringExtra("stop_request_id")
            lifecycle.execute { finishRetirement(retirement, null, request, true) }
        }
        return START_NOT_STICKY
    }

    private fun startTunnel(configuration: String, command: Long) {
        val session = Session(File(cacheDir, "vpn-${UUID.randomUUID()}"))
        if (!sessions.begin(command, session,
                allowed = { synchronized(serviceOwnerLock) { activeService === this } }) { state("CONNECTING") }) return
        try {
            check(session.directory.mkdir()) { "Could not create the VPN session directory" }
            Os.chmod(session.directory.absolutePath, 0b111000000)
            val runtimeConfiguration = JSONObject(configuration)
            val experimental = runtimeConfiguration.optJSONObject("experimental") ?: JSONObject()
            val controller = experimental.optJSONObject("clash_api") ?: JSONObject()
            controller.put("external_controller", "127.0.0.1:$CLASH_PORT")
            controller.put("secret", session.controllerSecret)
            experimental.put("clash_api", controller)
            runtimeConfiguration.put("experimental", experimental)
            session.configuration.writeText(runtimeConfiguration.toString())
            Os.chmod(session.configuration.absolutePath, 0b110000000)
            socksPortFromConfig(configuration) // Validate before allocating the TUN.
            val builder = Builder()
                .setSession("HoneyProxyUtility")
                .addAddress("172.19.0.1", 30)
                .addAddress("fdfe:dcba:9876::1", 126)
                .addDnsServer("172.19.0.2")
                .addRoute("0.0.0.0", 0)
                .addRoute("::", 0)
                .setMtu(1500)
                .setBlocking(false)
            // Both executable cores share this UID and must bypass their own TUN.
            builder.addDisallowedApplication(packageName)
            val descriptor = builder.establish() ?: error("Failed to establish VPN interface")
            if (!sessions.update(session) { session.tun = descriptor }) {
                descriptor.close()
                return
            }
            val worker = Thread {
                try { launchCores(session, configuration) }
                finally { session.startupFinished.countDown() }
            }.also { it.isDaemon = true }
            session.startupLaunched = true
            try { worker.start() }
            catch (error: Throwable) { session.startupFinished.countDown(); throw error }
        } catch (error: Exception) {
            notifyError(session, error.message ?: "VPN startup failed")
        }
    }

    private fun remaining(deadline: Long): Long =
        TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime()).coerceAtLeast(0)

    /** Slow closure is outside the publication gate and the Android UI thread. */
    private fun cleanupResources(session: Session, deadline: Long): Boolean {
        session.ready = false
        try { session.statsConnection?.disconnect() } catch (_: Exception) {}
        session.statsThread?.interrupt()
        session.watchdog?.interrupt()
        try { session.pipe?.close(); session.pipe = null } catch (_: Exception) { return false }
        try { session.tun?.close(); session.tun = null } catch (_: Exception) { return false }
        session.core?.let {
            if (!killAndReap(it, remaining(deadline))) return false
            session.core = null
        }
        if (session.forwarderPid > 0) {
            if (!killAndReap(session.forwarderPid, remaining(deadline))) return false
            session.forwarderPid = -1
        }
        if (!session.startupLaunched) session.startupFinished.countDown()
        if (!session.startupFinished.await(remaining(deadline), TimeUnit.MILLISECONDS)) return false
        session.unpublishedCore?.let {
            if (!killAndReap(it, remaining(deadline))) return false
            session.unpublishedCore = null
        }
        if (session.unpublishedForwarder > 0) {
            if (!killAndReap(session.unpublishedForwarder, remaining(deadline))) return false
            session.unpublishedForwarder = -1
        }
        if (session.pipeReaderLaunched && !session.pipeReaderFinished.await(remaining(deadline), TimeUnit.MILLISECONDS)) return false
        for (thread in listOfNotNull(session.statsThread, session.watchdog)) {
            val timeout = remaining(deadline)
            if (thread.isAlive && timeout <= 0) return false
            if (thread.isAlive) thread.join(timeout)
            if (thread.isAlive) return false
        }
        return session.directory.deleteRecursively() || !session.directory.exists()
    }

    private fun killAndReap(process: Process, timeout: Long = 3500): Boolean =
        terminateJavaProcess(process, timeout)

    private fun killAndReap(pid: Int, timeout: Long = 3500): Boolean = try {
        NativeLauncher.terminateOwnedChild(pid, timeout.coerceIn(0, 5000).toInt()) == 0
    } catch (_: Exception) { false }

    private fun drainRetirements(): Boolean {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        return retirements.confirm { (owner, session) ->
            try { owner.cleanupResources(session, deadline) } catch (_: Exception) { false }
        }
    }

    private fun coreStatus(process: Process): OwnedChildStatus = try {
        val exit = process.exitValue()
        if (exit in 0..255) OwnedChildStatus(OwnedChildStatus.Kind.EXITED, exitCode = exit)
        else OwnedChildStatus.unknown()
    } catch (_: IllegalThreadStateException) {
        OwnedChildStatus(OwnedChildStatus.Kind.RUNNING)
    } catch (_: Exception) {
        OwnedChildStatus.unknown()
    }

    private fun coreAlive(process: Process): Boolean = coreStatus(process).running

    private fun forwarderStatus(pid: Int): OwnedChildStatus = try {
        OwnedChildStatus.fromNative(NativeLauncher.observeOwnedChild(pid))
    } catch (_: Exception) {
        OwnedChildStatus.unknown()
    }

    private fun childFailure(session: Session, role: String, status: OwnedChildStatus, startup: Boolean) {
        // Never include child arguments, profile/configuration, endpoint or path.
        HoneyDiagnostics.child(role, status)
        Log.e(TAG, status.diagnostic(role))
        notifyError(session, status.failureMessage(role, startup))
    }

    private fun launchCores(session: Session, configuration: String) {
        try {
            if (!sessions.isCurrent(session)) return
            val socksPort = socksPortFromConfig(configuration)
            if (!waitForPortFree(session, socksPort, 6_000)) {
                if (sessions.isCurrent(session)) notifyError(session, "VPN local port is still occupied")
                return
            }
            if (!sessions.isCurrent(session)) return
            val process = ProcessBuilder("${applicationInfo.nativeLibraryDir}/libsingbox.so", "run", "-c", session.configuration.absolutePath)
                .directory(session.directory).redirectErrorStream(true).start()
            if (!sessions.update(session) { session.core = process }) {
                session.unpublishedCore = process
                if (killAndReap(process)) session.unpublishedCore = null
                return
            }
            Thread {
                try { HoneyDiagnostics.drain(process.inputStream.bufferedReader()) }
                catch (_: Exception) {}
            }.also { it.isDaemon = true; it.start() }
            if (!waitForCoreReady(session, process, socksPort, 10_000)) {
                if (sessions.isCurrent(session)) {
                    val status = coreStatus(process)
                    if (!status.running) childFailure(session, "sing-box", status, true)
                    else notifyError(session, "sing-box did not become ready")
                }
                return
            }
            val readFd = IntArray(1) { -1 }
            val pid = synchronized(nativeForkLock) {
                // dup is an independently owned reference to the old TUN. Keep
                // it open until JNI fork returns; cancellation may close the
                // original without reusing this number for a newer TUN.
                val descriptor = sessions.read(session) {
                    ParcelFileDescriptor.dup(checkNotNull(session.tun).fileDescriptor)
                } ?: return
                descriptor.use {
                    NativeLauncher.forkExecTun2socks("${applicationInfo.nativeLibraryDir}/libtun2socks.so", it.fd, socksPort, readFd)
                }
            }
            if (pid <= 0) {
                if (readFd[0] >= 0) ParcelFileDescriptor.adoptFd(readFd[0]).close()
                notifyError(session, "VPN forwarder could not start")
                return
            }
            var pipe: ParcelFileDescriptor? = null
            try {
                if (readFd[0] >= 0) pipe = ParcelFileDescriptor.adoptFd(readFd[0])
            } catch (error: Exception) {
                session.unpublishedForwarder = pid
                if (killAndReap(pid)) session.unpublishedForwarder = -1
                throw error
            }
            if (!sessions.update(session) { session.forwarderPid = pid; session.pipe = pipe }) {
                try { pipe?.close() } catch (_: Exception) {}
                session.unpublishedForwarder = pid
                if (killAndReap(pid)) session.unpublishedForwarder = -1
                return
            }
            val outputPipe = pipe
            if (outputPipe != null) {
                session.pipeReaderLaunched = true
                val pipeReader = Thread {
                    try {
                        val readerPipe = sessions.read(session) { ParcelFileDescriptor.dup(outputPipe.fileDescriptor) }
                            ?: return@Thread
                        ParcelFileDescriptor.AutoCloseInputStream(readerPipe).bufferedReader().use { reader ->
                            HoneyDiagnostics.drain(reader)
                        }
                    }
                    catch (_: Exception) {
                        if (sessions.isCurrent(session)) Log.w(TAG, "VPN forwarder output is unavailable")
                    }
                    finally {
                        session.pipeReaderFinished.countDown()
                    }
                }.also { it.isDaemon = true }
                try { pipeReader.start() }
                catch (error: Throwable) { session.pipeReaderFinished.countDown(); throw error }
            }
            // fork success is not exec/readiness. Observe the children through
            // their startup window before announcing the session to the UI.
            val started = SystemClock.elapsedRealtime()
            val startupDeadline = started + 1_500
            val coreHealth = OwnedChildHealthWindow()
            val forwarderHealth = OwnedChildHealthWindow()
            var lastCore = OwnedChildStatus.unknown()
            var lastForwarder = OwnedChildStatus.unknown()
            var confirmed = false
            while (SystemClock.elapsedRealtime() < startupDeadline) {
                if (!sessions.isCurrent(session)) return
                val now = SystemClock.elapsedRealtime()
                lastCore = coreStatus(process)
                lastForwarder = forwarderStatus(pid)
                if (coreHealth.failed(lastCore, now)) {
                    childFailure(session, "sing-box", lastCore, true)
                    return
                }
                if (forwarderHealth.failed(lastForwarder, now)) {
                    childFailure(session, "forwarder", lastForwarder, true)
                    return
                }
                // EOF or a broken diagnostic reader says nothing about process
                // liveness. Both real child observations must be RUNNING.
                if (lastCore.running && lastForwarder.running && now - started >= 150) {
                    confirmed = true
                    break
                }
                Thread.sleep(25)
            }
            if (!confirmed) {
                if (!lastCore.running) childFailure(session, "sing-box", lastCore, true)
                else childFailure(session, "forwarder", lastForwarder, true)
                return
            }
            if (!sessions.update(session) { session.ready = true; state("CONNECTED") }) return
            mainHandler.post {
                sessions.update(session) { if (activeService === this) updateNotification("CONNECTED") }
            }
            NativeBindings.onVpnStarted { action -> sessions.update(session) { if (activeService === this) action() } }
            startWatchdog(session, process, pid)
            startStatsPolling(session)
        } catch (error: Throwable) {
            notifyError(session, "VPN startup failed")
            Log.e(TAG, "VPN child startup failed")
        }
    }

    private fun startWatchdog(session: Session, process: Process, pid: Int) {
        val thread = Thread {
            val coreHealth = OwnedChildHealthWindow()
            val forwarderHealth = OwnedChildHealthWindow()
            while (sessions.isCurrent(session)) {
                val now = SystemClock.elapsedRealtime()
                val core = coreStatus(process)
                val forwarder = forwarderStatus(pid)
                if (coreHealth.failed(core, now)) {
                    childFailure(session, "sing-box", core, false)
                    return@Thread
                }
                if (forwarderHealth.failed(forwarder, now)) {
                    childFailure(session, "forwarder", forwarder, false)
                    return@Thread
                }
                try { Thread.sleep(500) } catch (_: InterruptedException) { return@Thread }
            }
        }.also { it.isDaemon = true }
        if (sessions.update(session) { session.watchdog = thread }) thread.start()
    }

    private fun socksPortFromConfig(configuration: String): Int {
        val inbounds = JSONObject(configuration).getJSONArray("inbounds")
        for (index in 0 until inbounds.length()) {
            val inbound = inbounds.getJSONObject(index)
            if (inbound.optString("type") == "socks" && inbound.optString("tag") == "socks-in") {
                return inbound.getInt("listen_port").also { require(it in 1..65535) { "Invalid SOCKS port" } }
            }
        }
        throw IllegalArgumentException("Missing socks-in inbound")
    }

    private fun waitForCoreReady(session: Session, process: Process, port: Int, timeout: Long): Boolean {
        val deadline = SystemClock.elapsedRealtime() + timeout
        while (sessions.isCurrent(session) && coreAlive(process) && SystemClock.elapsedRealtime() < deadline) {
            try {
                Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 250) }
                if (CoreReadinessProbe.isReady(CLASH_PORT, session.controllerSecret) && coreAlive(process)) return true
                Thread.sleep(100)
            }
            catch (_: Exception) { Thread.sleep(100) }
        }
        return false
    }

    private fun waitForPortFree(session: Session, port: Int, timeout: Long): Boolean {
        val deadline = SystemClock.elapsedRealtime() + timeout
        while (sessions.isCurrent(session) && SystemClock.elapsedRealtime() < deadline) {
            try { Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 200) }; Thread.sleep(100) }
            catch (_: java.io.IOException) { return sessions.isCurrent(session) }
        }
        return false
    }

    private fun startStatsPolling(session: Session) {
        val thread = Thread {
            var totalUp = 0L
            var totalDown = 0L
            val started = SystemClock.elapsedRealtime()
            val connection = URL("http://127.0.0.1:$CLASH_PORT/traffic").openConnection() as HttpURLConnection
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            connection.setRequestProperty("Authorization", "Bearer ${session.controllerSecret}")
            if (!sessions.update(session) { session.statsConnection = connection }) {
                connection.disconnect()
                return@Thread
            }
            try {
                connection.inputStream.bufferedReader().use { reader ->
                    while (sessions.isCurrent(session)) {
                        val line = reader.readLine() ?: break
                        val json = JSONObject(line)
                        val up = json.optLong("up")
                        val down = json.optLong("down")
                        totalUp += up
                        totalDown += down
                        NativeBindings.pushStats(up, down, totalUp, totalDown, (SystemClock.elapsedRealtime() - started) / 1000) { action ->
                            sessions.update(session) { if (activeService === this) action() }
                        }
                    }
                }
            } catch (_: Exception) {
                if (sessions.isCurrent(session)) Log.w(TAG, "VPN traffic measurements are unavailable")
            } finally {
                connection.disconnect()
            }
        }.also { it.isDaemon = true }
        if (sessions.update(session) { session.statsThread = thread }) thread.start()
    }

    private fun retiredDispatch(retirement: VpnSessionGate.Retirement<Session>): ((() -> Unit) -> Unit) = { action ->
        sessions.ifRetired(retirement.revision) {
            synchronized(serviceOwnerLock) { if (activeService === this) action() }
        }
    }

    private fun finishRetirement(retirement: VpnSessionGate.Retirement<Session>, message: String?, request: String?, stopService: Boolean) {
        retirement.session?.let { retirements.retain(this to it) }
        val dispatch = retiredDispatch(retirement)
        NativeBindings.onVpnStopping { action -> dispatch { if (nativeState == "DISCONNECTING") action() } }
        val confirmed = drainRetirements()
        if (confirmed) {
            sessions.ifRetired(retirement.revision) { state("DISCONNECTED") }
            if (message != null) NativeBindings.onVpnError(message, dispatch)
            NativeBindings.onVpnStopped(dispatch)
        } else if (message != null) {
            NativeBindings.onVpnError("VPN stop could not be confirmed", dispatch)
        }
        if (request != null) NativeBindings.completeStop(request, if (confirmed) null else "VPN stop could not be confirmed") {
            var ownsStopped = false
            dispatch { ownsStopped = nativeState == "DISCONNECTED" }
            ownsStopped
        }
        // Complete the captured method before requesting service destruction;
        // onDestroy is a separate retirement and must not invalidate its reply.
        if (confirmed && stopService) mainHandler.post {
                sessions.ifRetired(retirement.revision) {
                    synchronized(serviceOwnerLock) {
                        if (activeService === this) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
                    }
                }
            }
    }

    private fun notifyError(session: Session, message: String) {
        sessions.retire(session, transition = { state("DISCONNECTING") }, scheduled = { retirement ->
            lifecycle.execute { finishRetirement(retirement, message, null, true) }
        })
    }

    override fun onRevoke() {
        super.onRevoke()
        val retirement = sessions.command { state("DISCONNECTING") }
        lifecycle.execute { finishRetirement(retirement, null, null, true) }
    }

    override fun onDestroy() {
        val retirement = sessions.command { if (nativeState != "DISCONNECTED") state("DISCONNECTING") }
        lifecycle.execute { finishRetirement(retirement, null, null, false) }
        super.onDestroy()
    }

    private fun buildNotification(status: String): Notification {
        val labels = VpnNotificationLabels.forLocale(notificationLocale)
        createNotificationChannel(labels)
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("HoneyProxyUtility").setContentText(labels.statusText(status))
            .setSmallIcon(R.drawable.ic_stat_honey).setContentIntent(pi)
            .setOngoing(true).setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun updateNotification(status: String) {
        getSystemService(NotificationManager::class.java)
            ?.notify(NOTIFICATION_ID, buildNotification(status))
    }

    private fun createNotificationChannel(labels: VpnNotificationLabels) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java) ?: return
        // Android preserves the user's channel preferences when the same ID
        // is registered again; name and description can follow the app language.
        nm.createNotificationChannel(NotificationChannel(
            CHANNEL_ID, labels.channelName, NotificationManager.IMPORTANCE_LOW
        ).apply { description = labels.channelDescription; setShowBadge(false) })
    }
}
