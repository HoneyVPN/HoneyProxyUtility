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
    private var latencyBindings: LatencyProcessBindings? = null

    companion object {
        private const val VPN_PERMISSION_REQUEST = 1001
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) handleDeepLinkIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleDeepLinkIntent(intent)
    }

    private fun handleDeepLinkIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val uri = intent?.data ?: return
        if (uri.scheme.equals("honeyvpn", ignoreCase = true)) {
            // Dart validates the entire envelope; never extract/redecode its URL here.
            NativeBindings.onDeepLink(uri.toString())
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeBindings = NativeBindings(
            context = applicationContext,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
            requestVpnPermission = ::requestVpnPermission,
        )
        latencyBindings = LatencyProcessBindings(applicationContext,
            flutterEngine.dartExecutor.binaryMessenger)
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
        latencyBindings?.destroy()
        nativeBindings?.destroy()
        super.onDestroy()
    }
}
