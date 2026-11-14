package com.wave.vpn

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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

class MainActivity : FlutterActivity() {
    companion object {
        private const val VPN_REQ_CODE = 7001
        private const val NOTIF_REQ_CODE = 7002
        const val ACTION_VPN_EVENT = "com.wave.vpn.EVENT"
    }

    private var methodChannel: MethodChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var pendingPrepareResult: MethodChannel.Result? = null
    private var initialDeepLink: String? = null

    private val vpnEventReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != ACTION_VPN_EVENT) return
            val type = intent.getStringExtra("type") ?: return
            if (type == "traffic") {
                eventSink?.success(
                    mapOf(
                        "type" to "traffic",
                        "up" to intent.getLongExtra("up", 0L),
                        "down" to intent.getLongExtra("down", 0L),
                        "upTotal" to intent.getLongExtra("upTotal", 0L),
                        "downTotal" to intent.getLongExtra("downTotal", 0L),
                    )
                )
            } else if (type == "state") {
                eventSink?.success(
                    mapOf(
                        "type" to "state",
                        "state" to (intent.getStringExtra("state") ?: "disconnected"),
                        "message" to intent.getStringExtra("message"),
                    )
                )
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initialDeepLink = intent?.dataString
        val filter = IntentFilter(ACTION_VPN_EVENT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(vpnEventReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(vpnEventReceiver, filter)
        }
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(vpnEventReceiver)
        } catch (_: Exception) {}
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = intent.dataString
        if (!link.isNullOrBlank()) {
            methodChannel?.invokeMethod("onLink", link)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.wave.vpn/core").also { ch ->
            ch.setMethodCallHandler { call, result -> handleMethodCall(call, result) }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.wave.vpn/stats").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    events?.success(
                        mapOf(
                            "type" to "state",
                            "state" to WaveVpnService.currentState,
                            "message" to WaveVpnService.lastError,
                        )
                    )
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            }
        )
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> {
                val intent = VpnService.prepare(this)
                if (intent == null) {
                    result.success(true)
                } else {
                    pendingPrepareResult = result
                    startActivityForResult(intent, VPN_REQ_CODE)
                }
            }
            "requestNotifications" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                        != PackageManager.PERMISSION_GRANTED
                    ) {
                        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIF_REQ_CODE)
                    }
                }
                result.success(null)
            }
            "start" -> {
                val config = call.argument<String>("config") ?: ""
                val apiPort = call.argument<Int>("apiPort") ?: 19090
                val secret = call.argument<String>("secret") ?: ""
                val srvIntent = Intent(this, WaveVpnService::class.java).apply {
                    action = WaveVpnService.ACTION_START
                    putExtra("config", config)
                    putExtra("apiPort", apiPort)
                    putExtra("secret", secret)
                }
                ContextCompat.startForegroundService(this, srvIntent)
                result.success(null)
            }
            "stop" -> {
                val srvIntent = Intent(this, WaveVpnService::class.java).apply {
                    action = WaveVpnService.ACTION_STOP
                }
                startService(srvIntent)
                result.success(null)
            }
            "logs" -> {
                result.success(WaveVpnService.getLogs())
            }
            "initialLink" -> {
                val link = initialDeepLink
                initialDeepLink = null
                result.success(link)
            }
            "installedApps" -> {
                Thread {
                    val pm = packageManager
                    val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)
                        .filter { it.packageName != packageName }
                        .map { app ->
                            val isSys = (app.flags and ApplicationInfo.FLAG_SYSTEM) != 0
                            mapOf(
                                "name" to pm.getApplicationLabel(app).toString(),
                                "package" to app.packageName,
                                "system" to isSys,
                            )
                        }
                        .sortedBy { (it["name"] as String).lowercase() }
                    runOnUiThread { result.success(apps) }
                }.start()
            }
            "appIcon" -> {
                val pkg = call.argument<String>("package")
                if (pkg == null) {
                    result.success(null)
                    return
                }
                try {
                    val drawable = packageManager.getApplicationIcon(pkg)
                    val bmp = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888)
                    val canvas = Canvas(bmp)
                    drawable.setBounds(0, 0, canvas.width, canvas.height)
                    drawable.draw(canvas)
                    val out = ByteArrayOutputStream()
                    bmp.compress(Bitmap.CompressFormat.PNG, 90, out)
                    result.success(out.toByteArray())
                } catch (_: Exception) {
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VPN_REQ_CODE) {
            val res = pendingPrepareResult
            pendingPrepareResult = null
            res?.success(resultCode == Activity.RESULT_OK)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
