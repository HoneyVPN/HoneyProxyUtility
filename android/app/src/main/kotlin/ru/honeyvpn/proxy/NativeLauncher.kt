package ru.honeyvpn.proxy

object NativeLauncher {
    external fun forkExecTun2socks(binaryPath: String, tunFd: Int, socksPort: Int, outReadFd: IntArray): Int
    /** Bounded exact-child termination/reaping; zero confirms closure, otherwise errno. */
    external fun terminateOwnedChild(pid: Int, timeoutMs: Int): Int
    /** [kind, exitCode, signal, errno]; observes without reaping the owned PID. */
    external fun observeOwnedChild(pid: Int): IntArray
    init { System.loadLibrary("honeyvpn_launcher") }
}
