package ru.honeyvpn.proxy

import java.io.StringReader

fun checkAndroidDiagnostics() {
    var checks = 0
    fun expect(value: Boolean) { check(value); checks++ }
    val sample = HoneyDiagnostics.summarize("ERROR tls handshake failed https://secret.example/abc short-secret alice p4ss")
    expect(sample == "error tls handshake failed")
    expect(HoneyDiagnostics.summarize("ERROR handshake failed https://tls.error.example/tcp/http private") == "error handshake failed")
    expect(HoneyDiagnostics.summarize("WARN dial failed /home/tls/secret/info error") == "warn dial failed error")
    expect(HoneyDiagnostics.summarize("ERROR dial failed 127.0.0.1:8443 certificate") == "error dial failed certificate")
    expect(HoneyDiagnostics.summarize("WARN failed C:\\tls\\info.error ready") == "warn failed ready")
    for (private in listOf("vless://secret@server.example:443", "C:\\Users\\alice\\settings.json", "/home/alice/secret", "192.0.2.10", "unknown-short-password")) {
        expect(!HoneyDiagnostics.summarize(private).contains(private))
    }
    expect(HoneyDiagnostics.summarize("a".repeat(5000)) == "core output exceeded line limit")
    HoneyDiagnostics.child("sing-box", OwnedChildStatus(OwnedChildStatus.Kind.EXITED, exitCode = 1))
    expect(HoneyDiagnostics.snapshot().last()["message"].toString().contains("exit=1"))
    HoneyDiagnostics.drain(StringReader("error handshake failed\n" + "private".repeat(10000) + "\ninfo ready\n"))
    expect(HoneyDiagnostics.snapshot().last()["message"] == "info ready")
    expect(HoneyDiagnostics.snapshot().any { it["error"] == true })
    for (index in 0..150) HoneyDiagnostics.add("info ready")
    expect(HoneyDiagnostics.snapshot().size == 128)
    expect(HoneyDiagnostics.droppedCount() > 0)
    expect(HoneyDiagnostics.snapshot().all { it["message"].toString().length <= 4096 })
    println("PASS $checks bounded Android own-core diagnostics, secret omission, child exit metadata, oversized reader line and ring quota checks; no Android/VPN action")
}
