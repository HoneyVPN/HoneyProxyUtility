package ru.honeyvpn.proxy

/** Presentation only: never changes a VPN command, state or session identity. */
internal class VpnNotificationLabels private constructor(private val russian: Boolean) {
    val channelName = "HoneyProxyUtility VPN"
    val channelDescription: String get() = if (russian)
        "Состояние VPN-подключения HoneyProxyUtility"
        else "HoneyProxyUtility VPN connection status"

    fun statusText(state: String): String = when (state) {
        "CONNECTED" -> if (russian) "Подключено" else "Connected"
        "CONNECTING" -> if (russian) "Подключение…" else "Connecting…"
        "DISCONNECTING" -> if (russian) "Отключение…" else "Disconnecting…"
        else -> if (russian) "Состояние VPN недоступно" else "VPN status unavailable"
    }

    companion object {
        fun forLocale(locale: String?) = VpnNotificationLabels(locale == "ru")
    }
}
