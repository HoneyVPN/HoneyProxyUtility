package ru.honeyvpn.proxy

object NativeLauncher {
    external fun forkExecTun2socks(binaryPath: String, tunFd: Int, socksPort: Int, outReadFd: IntArray): Int
    /** Reaps the child process to prevent it becoming a zombie. Blocks until the process exits. */
    external fun waitForPid(pid: Int)
    init { System.loadLibrary("honeyvpn_launcher") }
}
