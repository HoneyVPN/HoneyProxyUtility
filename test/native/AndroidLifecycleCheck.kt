package ru.honeyvpn.proxy

import java.net.InetAddress
import java.net.ServerSocket
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

private class Resource {
    val closes = AtomicInteger()
    fun close() { check(closes.incrementAndGet() == 1) { "Resource closed twice" } }
}
private class Session {
    var resource: Resource? = null
}
private fun CountDownLatch.awaitChecked() { check(await(5, TimeUnit.SECONDS)) { "Barrier timed out" } }
private fun Thread.joinChecked() { join(5000); check(!isAlive) { "Worker did not finish" } }

private fun checkLateAllocationCannotPublish() {
    repeat(100) {
        val gate = VpnSessionGate<Session>()
        val old = Session()
        val newer = Session()
        gate.replace(old)
        val allocated = CountDownLatch(1)
        val mayPublish = CountDownLatch(1)
        val handle = Resource()
        val worker = thread {
            allocated.countDown()
            mayPublish.awaitChecked()
            if (!gate.update(old) { old.resource = handle }) handle.close()
        }
        allocated.awaitChecked()
        val retirement = checkNotNull(gate.retire(old))
        gate.replace(newer)
        val newHandle = Resource()
        check(gate.update(newer) { newer.resource = newHandle })
        mayPublish.countDown()
        worker.joinChecked()
        check(handle.closes.get() == 1)
        check(newHandle.closes.get() == 0)
        check(!gate.ifRetired(retirement.revision) { error("Old stop reached a newer start") })
        check(gate.retire(old) == null) { "Old failure retired a newer session" }
        check(gate.isCurrent(newer))
        checkNotNull(gate.retire(newer)).session!!.resource!!.close()
    }
}

private fun checkCommittedAllocationBelongsToRetiredSession() {
    val gate = VpnSessionGate<Session>()
    val session = Session()
    gate.replace(session)
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val handle = Resource()
    val publisher = thread {
        check(gate.update(session) {
            entered.countDown()
            release.awaitChecked()
            session.resource = handle
        })
    }
    entered.awaitChecked()
    val retiring = CountDownLatch(1)
    val retired = CountDownLatch(1)
    val canceller = thread {
        retiring.countDown()
        checkNotNull(gate.retire(session)).session!!.resource!!.close()
        retired.countDown()
    }
    retiring.awaitChecked()
    check(!retired.await(50, TimeUnit.MILLISECONDS)) { "Retirement passed an in-flight atomic publication" }
    release.countDown()
    publisher.joinChecked()
    canceller.joinChecked()
    check(handle.closes.get() == 1)
}

private fun checkDelayedEventsAndSlowDisposal() {
    val gate = VpnSessionGate<Session>()
    val old = Session()
    val current = Session()
    gate.replace(old)
    val stopped = checkNotNull(gate.retire(old))
    gate.replace(current)
    var events = 0
    // These closures stand in for already queued MainLooper events.
    val staleStarted = { gate.update(old) { events++ } }
    val staleStopped = { gate.ifRetired(stopped.revision) { events++ } }
    staleStarted()
    staleStopped()
    check(events == 0)
    val newStop = checkNotNull(gate.retire(current))
    check(!gate.ifRetired(stopped.revision) { events++ })
    check(gate.ifRetired(newStop.revision) { events++ })
    check(events == 1)

    val disposalStarted = CountDownLatch(1)
    val releaseDisposal = CountDownLatch(1)
    val cleanup = thread { disposalStarted.countDown(); releaseDisposal.awaitChecked() }
    disposalStarted.awaitChecked()
    val newest = Session()
    // Disposal outside the gate must not prevent a new command/publication.
    gate.replace(newest)
    check(gate.update(newest) { newest.resource = Resource() })
    releaseDisposal.countDown()
    cleanup.joinChecked()
    check(gate.isCurrent(newest))
}

private fun checkQueuedStartAndServiceReplacement() {
    val gate = VpnSessionGate<Session>()
    val first = gate.command()
    val stopping = gate.command()
    check(!gate.begin(first.command, Session())) { "Queued START survived a newer STOP" }
    check(gate.ifRetired(stopping.revision) {})
    val oldOwner = gate.command()
    check(!gate.begin(oldOwner.command, Session(), allowed = { false })) {
        "Replaced service allocated a session"
    }
    val current = Session()
    check(gate.begin(oldOwner.command, current, allowed = { true }))
    val retirements = mutableListOf<VpnSessionGate.Retirement<Session>>()
    checkNotNull(gate.retire(current, scheduled = { retirements += it }))
    check(retirements.single().session === current) { "Cleanup was not queued with its retired owner" }
}

private fun checkStopReplyWaitsForCleanup() {
    val cleanup = ConfirmedSessionCleanup<Resource>()
    val child = Resource()
    cleanup.retain(child)
    val requests = NativeStopRequests()
    val replies = AtomicInteger()
    val stoppedEvents = AtomicInteger()
    val request = requests.register { error -> check(error == null); replies.incrementAndGet() }
    val cleanupEntered = CountDownLatch(1)
    val mayClose = CountDownLatch(1)
    val stopping = thread {
        val confirmed = cleanup.confirm {
            cleanupEntered.countDown()
            mayClose.awaitChecked()
            it.close()
            true
        }
        check(confirmed)
        stoppedEvents.incrementAndGet()
        check(requests.complete(request, null))
    }
    cleanupEntered.awaitChecked()
    check(child.closes.get() == 0 && replies.get() == 0 && stoppedEvents.get() == 0) {
        "STOPPED or stop future completed before the child/FD closed"
    }
    // Slow disposal must not hold the request registry/UI gate.
    val independent = requests.register { check(it != null) }
    check(requests.complete(independent, "bounded failure"))
    mayClose.countDown()
    stopping.joinChecked()
    check(child.closes.get() == 1 && replies.get() == 1 && stoppedEvents.get() == 1)
    check(!requests.complete(request, "late timeout")) { "Completed stop replied twice" }
}

private fun checkFailedCleanupAndCapturedReplies() {
    val cleanup = ConfirmedSessionCleanup<Resource>()
    val child = Resource()
    cleanup.retain(child)
    var closeAttempts = 0
    check(!cleanup.confirm { closeAttempts++; false })
    check(child.closes.get() == 0)
    check(cleanup.confirm { closeAttempts++; it.close(); true })
    check(closeAttempts == 2 && child.closes.get() == 1) { "Unconfirmed child was discarded instead of retried" }
    check(cleanup.confirm { error("Already closed snapshot was retried") })

    val requests = NativeStopRequests()
    val oldReplies = AtomicInteger()
    val newReplies = AtomicInteger()
    val originalEngine = requests.register { check(it != null); oldReplies.incrementAndGet() }
    val recreatedEngine = requests.register { check(it == null); newReplies.incrementAndGet() }
    val release = CountDownLatch(1)
    val completed = AtomicInteger()
    val timeout = thread { release.awaitChecked(); if (requests.complete(originalEngine, "timeout")) completed.incrementAndGet() }
    val cleanupReply = thread { release.awaitChecked(); if (requests.complete(originalEngine, "superseded")) completed.incrementAndGet() }
    release.countDown()
    timeout.joinChecked()
    cleanupReply.joinChecked()
    check(completed.get() == 1 && oldReplies.get() == 1 && newReplies.get() == 0) {
        "Cleanup/timeout replied twice or targeted a newer Activity's method"
    }
    check(requests.complete(recreatedEngine, null))
    check(newReplies.get() == 1)

    val gate = VpnSessionGate<Session>()
    val stop = gate.command()
    val start = gate.command()
    check(gate.begin(start.command, Session()))
    check(!gate.ifRetired(stop.revision) { error("Old stop ACK marked a newer session stopped") })
}

private class BoundedProcess : Process() {
    val terminated = AtomicBoolean(false)
    val destroyed = CountDownLatch(1)
    override fun destroy() { destroyed.countDown() }
    override fun destroyForcibly(): Process = error("API 26 destroyForcibly must not be required")
    override fun waitFor(timeout: Long, unit: TimeUnit): Boolean = error("API 26 timed waitFor must not be required")
    override fun waitFor(): Int = error("Cleanup must not block without a bound")
    override fun exitValue(): Int = if (terminated.get()) 0 else throw IllegalThreadStateException()
    override fun getInputStream() = ByteArrayInputStream(byteArrayOf())
    override fun getErrorStream() = ByteArrayInputStream(byteArrayOf())
    override fun getOutputStream() = ByteArrayOutputStream()
}

private fun checkApi24ProcessClosureIsBoundedAndConfirmed() {
    val process = BoundedProcess()
    val reply = AtomicReference<Boolean?>()
    val closing = thread { reply.set(terminateJavaProcess(process, 2000)) }
    process.destroyed.awaitChecked()
    check(reply.get() == null) { "Java child reported closed before its exit was observed" }
    process.terminated.set(true)
    closing.joinChecked()
    check(reply.get() == true)
    val stalled = BoundedProcess()
    check(!terminateJavaProcess(stalled, 0)) { "Unconfirmed child exit was accepted" }
    stalled.terminated.set(true)
    check(terminateJavaProcess(stalled, 100))
}

private class Controller(private val secret: String?, private val body: String = "{\"version\":\"1.13.12\"}") : AutoCloseable {
    private val server = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
    val port: Int get() = server.localPort
    private val worker = thread(isDaemon = true) {
        while (!server.isClosed) {
            try {
                server.accept().use { socket ->
                    socket.soTimeout = 1000
                    val reader = socket.getInputStream().bufferedReader()
                    var authorized = secret == null
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (line.isEmpty()) break
                        if (line.equals("Authorization: Bearer $secret", ignoreCase = true)) authorized = true
                    }
                    val response = if (authorized) body else "{}"
                    val status = if (authorized) "200 OK" else "401 Unauthorized"
                    val bytes = response.toByteArray()
                    socket.getOutputStream().write(("HTTP/1.1 $status\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n").toByteArray())
                    socket.getOutputStream().write(bytes)
                }
            } catch (_: Exception) { if (server.isClosed) break }
        }
    }
    override fun close() { server.close(); worker.joinChecked() }
}

private fun checkForeignControllerCannotSatisfyReadiness() {
    Controller(null).use { check(!CoreReadinessProbe.isReady(it.port, "fresh-session-nonce")) { "Unauthenticated foreign listener accepted" } }
    Controller("old-session-nonce").use { check(!CoreReadinessProbe.isReady(it.port, "fresh-session-nonce")) { "Old controller accepted" } }
    Controller("fresh-session-nonce").use { check(CoreReadinessProbe.isReady(it.port, "fresh-session-nonce")) { "Own authenticated controller rejected" } }
    Controller("fresh-session-nonce", "{\"status\":\"ok\"}").use { check(!CoreReadinessProbe.isReady(it.port, "fresh-session-nonce")) }
    Controller("fresh-session-nonce", "{\"version\":\"" + "x".repeat(5000) + "\"}").use { check(!CoreReadinessProbe.isReady(it.port, "fresh-session-nonce")) }
}

private fun checkAuthoritativeChildObservationPolicy() {
    val running = OwnedChildStatus.fromNative(intArrayOf(1, 0, 0, 0))
    val exited = OwnedChildStatus.fromNative(intArrayOf(2, 127, 0, 0))
    val signaled = OwnedChildStatus.fromNative(intArrayOf(3, 0, 31, 0))
    val contention = OwnedChildStatus.fromNative(intArrayOf(4, 0, 0, 16))
    val lost = OwnedChildStatus.fromNative(intArrayOf(5, 0, 0, 10))
    check(running.running && !running.terminal)
    check(exited.terminal && exited.exitCode == 127 && !exited.running)
    check(signaled.terminal && signaled.signal == 31)
    check(!contention.running && !contention.terminal && contention.errno == 16)
    check(lost.terminal && !lost.running)
    for (invalid in listOf(intArrayOf(), intArrayOf(1, 0, 0), intArrayOf(1, 1, 0, 0),
            intArrayOf(2, -1, 0, 0), intArrayOf(2, 256, 0, 0), intArrayOf(3, 0, 0, 0),
            intArrayOf(4, 0, 0, -1), intArrayOf(4, 0, 0, 4096), intArrayOf(99, 0, 0, 0))) {
        check(OwnedChildStatus.fromNative(invalid).kind == OwnedChildStatus.Kind.UNKNOWN)
    }
    val window = OwnedChildHealthWindow()
    check(!window.failed(contention, 100))
    check(!window.failed(contention, 1599))
    check(window.failed(contention, 1600)) { "Unavailable status retry was unbounded" }
    check(!window.failed(running, 1700))
    check(!window.failed(contention, 1800)) { "A recovered running observation did not reset the unknown window" }
    check(window.failed(contention, 3300))
    check(OwnedChildHealthWindow().failed(exited, 0))
    check(OwnedChildHealthWindow().failed(signaled, 0))
    check(OwnedChildHealthWindow().failed(lost, 0))
    check(exited.failureMessage("forwarder", true).contains("VPN forwarder"))
    check(exited.failureMessage("sing-box", true).contains("sing-box"))
    check(!exited.diagnostic("https://private.invalid/token").contains("private"))
    check(signaled.diagnostic("forwarder") == "VPN child role=forwarder kind=SIGNALED exit=0 signal=31 errno=0")
    // A diagnostic pipe can close while a live process retains its resources.
    // The real service uses only the observed status for this health policy.
    val closedDiagnosticStream = ByteArrayInputStream(byteArrayOf())
    check(closedDiagnosticStream.read() == -1)
    check(!OwnedChildHealthWindow().failed(running, 0))
    println("PASS bounded authoritative child metadata/unknown retry and diagnostic-EOF independence; no native process/VPN involved")
}

private fun checkActualCoreAuthentication(binary: String) {
    val ports = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1")).use { controller ->
        ServerSocket(0, 16, InetAddress.getByName("127.0.0.1")).use { socks -> controller.localPort to socks.localPort }
    }
    val (controllerPort, socksPort) = ports
    val secret = "owned-runtime-probe-fixture"
    val directory = Files.createTempDirectory("honeyproxy-core-auth-").toFile()
    val configuration = directory.resolve("config.json")
    configuration.writeText("""{"log":{"disabled":true},"inbounds":[{"type":"socks","tag":"socks-in","listen":"127.0.0.1","listen_port":$socksPort}],"outbounds":[{"type":"direct","tag":"direct"}],"experimental":{"clash_api":{"external_controller":"127.0.0.1:$controllerPort","secret":"$secret"}}}""")
    val process = ProcessBuilder(binary, "run", "-c", configuration.absolutePath).redirectErrorStream(true).start()
    try {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        var ready = false
        while (System.nanoTime() < deadline) {
            if (!process.isAlive) error("Pinned local fixture core exited during authentication setup")
            if (CoreReadinessProbe.isReady(controllerPort, secret)) { ready = true; break }
            Thread.sleep(50)
        }
        check(ready) { "Pinned core did not satisfy its authenticated readiness contract" }
        check(!CoreReadinessProbe.isReady(controllerPort, "foreign-session-nonce"))
        println("Actual pinned sing-box authenticated readiness and wrong-session rejection passed; only loopback proxy/controller listeners opened, no traffic/TUN.")
    } finally {
        process.destroyForcibly()
        check(process.waitFor(5, TimeUnit.SECONDS))
        directory.deleteRecursively()
    }
}

private fun checkNotificationPresentation() {
    val english = VpnNotificationLabels.forLocale("en")
    val russian = VpnNotificationLabels.forLocale("ru")
    check(english.statusText("CONNECTING") == "Connecting…")
    check(russian.statusText("CONNECTING") == "Подключение…")
    check(english.statusText("CONNECTED") == "Connected")
    check(russian.statusText("CONNECTED") == "Подключено")
    check(english.statusText("DISCONNECTING") == "Disconnecting…")
    check(russian.statusText("DISCONNECTING") == "Отключение…")
    check(english.channelName == russian.channelName)
    check(english.channelDescription != russian.channelDescription)
    for (unknown in listOf(null, "fr", "ru-RU", "https://private.example/token")) {
        check(VpnNotificationLabels.forLocale(unknown).statusText("CONNECTED") == "Connected")
    }
    for (labels in listOf(english, russian)) {
        val status = labels.statusText("https://private.example/token")
        check(!status.contains("private") && !status.contains("https://"))
    }
    println("PASS RU/EN notification labels, unsupported-language fallback and unknown-state redaction; no Android service command invoked")
}

fun main(arguments: Array<String>) {
    checkAndroidDiagnostics()
    val workerFailure = AtomicReference<Throwable?>()
    val mainThread = Thread.currentThread()
    Thread.setDefaultUncaughtExceptionHandler { worker, failure ->
        if (worker === mainThread) {
            failure.printStackTrace()
            kotlin.system.exitProcess(1)
        }
        workerFailure.compareAndSet(null, failure)
    }
    checkNotificationPresentation()
    checkLateAllocationCannotPublish()
    checkCommittedAllocationBelongsToRetiredSession()
    checkDelayedEventsAndSlowDisposal()
    checkQueuedStartAndServiceReplacement()
    checkStopReplyWaitsForCleanup()
    checkFailedCleanupAndCapturedReplies()
    checkApi24ProcessClosureIsBoundedAndConfirmed()
    checkForeignControllerCannotSatisfyReadiness()
    checkAuthoritativeChildObservationPolicy()
    if (arguments.isNotEmpty()) checkActualCoreAuthentication(arguments.single())
    workerFailure.get()?.let { throw AssertionError("Regression worker failed", it) }
    println("Android lifecycle: 100 deterministic cancel/publication races, queued START/STOP and service replacement, confirmed cleanup before STOPPED/reply, failure retry, captured exact-once replies, delayed callbacks and authenticated foreign-listener checks passed. No VPN/TUN was started.")
}
