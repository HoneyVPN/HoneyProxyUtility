package ru.honeyvpn.proxy

object NativeLauncher {
    external fun forkExecTun2socks(binaryPath: String, tunFd: Int, socksPort: Int): Int
    init { System.loadLibrary("honeyvpn_launcher") }
}
