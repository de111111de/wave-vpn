package com.wave.vpn

import android.Manifest
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        const val REQ_VPN = 4001
        const val REQ_NOTIF = 4002
    }

    private var pendingPrepare: MethodChannel.Result? = null
    private var channel: MethodChannel? = null
    private var initialLink: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initialLink = linkOf(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        linkOf(intent)?.let { channel?.invokeMethod("onLink", it) }
    }

    private fun linkOf(i: Intent?): String? = if (i?.action == Intent.ACTION_VIEW) i.dataString else null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EventChannel(messenger, "com.wave.vpn/stats").setStreamHandler(VpnBridge)
        channel = MethodChannel(messenger, "com.wave.vpn/core").also {
            it.setMethodCallHandler { call, result -> onCall(call, result) }
        }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> {
                val i = VpnService.prepare(this)
                if (i == null) {
                    result.success(true)
                } else {
                    pendingPrepare?.success(false)
                    pendingPrepare = result
                    startActivityForResult(i, REQ_VPN)
                }
            }
            "start" -> {
                val cfg = call.argument<String>("config")
                if (cfg.isNullOrEmpty()) return result.error("ARG", "empty config", null)
                // config goes through a private file: Binder transactions are capped at ~1 MB
                val f = File(filesDir, "sing-box/config.json")
                f.parentFile?.mkdirs()
                f.writeText(cfg)
                val i = Intent(this, WaveVpnService::class.java)
                    .setAction(WaveVpnService.ACTION_START)
                    .putExtra(WaveVpnService.EXTRA_CONFIG_PATH, f.path)
                    .putExtra(WaveVpnService.EXTRA_API_PORT, call.argument<Int>("apiPort") ?: 19090)
                    .putExtra(WaveVpnService.EXTRA_SECRET, call.argument<String>("secret") ?: "")
                ContextCompat.startForegroundService(this, i)
                result.success(null)
            }
            "stop" -> {
                startService(Intent(this, WaveVpnService::class.java).setAction(WaveVpnService.ACTION_STOP))
                result.success(null)
            }
            "state" -> result.success(VpnBridge.state)
            "logs" -> result.success(VpnBridge.dumpLogs())
            "initialLink" -> {
                result.success(initialLink)
                initialLink = null
            }
            "requestNotifications" -> {
                if (Build.VERSION.SDK_INT >= 33 &&
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                ) {
                    ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIF)
                }
                result.success(null)
            }
            "installedApps" -> Thread {
                try {
                    val pm = packageManager
                    val list = pm.getInstalledApplications(0).map {
                        mapOf(
                            "name" to pm.getApplicationLabel(it).toString(),
                            "package" to it.packageName,
                            "system" to ((it.flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                        )
                    }.sortedBy { (it["name"] as String).lowercase() }
                    runOnUiThread { result.success(list) }
                } catch (t: Throwable) {
                    runOnUiThread { result.error("APPS", t.message, null) }
                }
            }.start()
            "appIcon" -> Thread {
                try {
                    val pkg = call.argument<String>("package") ?: throw IllegalArgumentException("package")
                    val d = packageManager.getApplicationIcon(pkg)
                    val bmp = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
                    d.setBounds(0, 0, 96, 96)
                    d.draw(Canvas(bmp))
                    val out = ByteArrayOutputStream()
                    bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
                    runOnUiThread { result.success(out.toByteArray()) }
                } catch (t: Throwable) {
                    runOnUiThread { result.success(null) }
                }
            }.start()
            else -> result.notImplemented()
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_VPN) {
            pendingPrepare?.success(resultCode == RESULT_OK)
            pendingPrepare = null
        }
    }
}
