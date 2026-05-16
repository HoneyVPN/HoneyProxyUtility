package ru.honeyvpn.proxy

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var vpnPermissionCallback: ((Boolean) -> Unit)? = null
    private var nativeBindings: NativeBindings? = null

    companion object {
        private const val VPN_PERMISSION_REQUEST = 1001
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleDeepLinkIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleDeepLinkIntent(intent)
    }

    private fun handleDeepLinkIntent(intent: Intent?) {
        val uri = intent?.data ?: return
        if (uri.scheme == "honeyvpn" && uri.host == "import") {
            val url = uri.getQueryParameter("url") ?: return
            NativeBindings.onDeepLink(url)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeBindings = NativeBindings(
            context = applicationContext,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
            requestVpnPermission = ::requestVpnPermission,
        )
    }

    private fun requestVpnPermission(callback: (Boolean) -> Unit) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            // Already granted
            callback(true)
            return
        }
        vpnPermissionCallback = callback
        startActivityForResult(intent, VPN_PERMISSION_REQUEST)
    }

    @Deprecated("Needed for VPN permission result")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_PERMISSION_REQUEST) {
            vpnPermissionCallback?.invoke(resultCode == Activity.RESULT_OK)
            vpnPermissionCallback = null
        }
    }

    override fun onDestroy() {
        nativeBindings?.destroy()
        super.onDestroy()
    }
}
