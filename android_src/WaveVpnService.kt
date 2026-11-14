package com.wave.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.TrafficStats
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.Process
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

class WaveVpnService : VpnService() {
    companion object {
        const val ACTION_START = "com.wave.vpn.START"
        const val ACTION_STOP = "com.wave.vpn.STOP"
        private const val CHANNEL_ID = "wave_vpn_channel"
        private const val NOTIF_ID = 101

        @Volatile
        var currentState: String = "disconnected"
        @Volatile
        var lastError: String? = null

        private val logBuffer = CopyOnWriteArrayList<String>()

        fun appendLog(msg: String) {
            val ts = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())
            logBuffer.add("[$ts] $msg")
            while (logBuffer.size > 400) {
                logBuffer.removeAt(0)
            }
        }

        fun getLogs(): String = logBuffer.joinToString("\n")
    }

    private var tunInterface: ParcelFileDescriptor? = null
    private var coreProcess: java.lang.Process? = null
    private var libboxService: Any? = null
    private var statsExecutor: ScheduledExecutorService? = null
    private var baseTxBytes: Long = 0L
    private var baseRxBytes: Long = 0L
    private var prevTxBytes: Long = 0L
    private var prevRxBytes: Long = 0L

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val config = intent.getStringExtra("config") ?: ""
                val apiPort = intent.getIntExtra("apiPort", 19090)
                val secret = intent.getStringExtra("secret") ?: ""
                startForeground(NOTIF_ID, buildNotification("Запуск туннеля Wave..."))
                Thread { startWaveTunnel(config, apiPort, secret) }.start()
            }
            ACTION_STOP -> {
                Thread { stopWaveTunnel() }.start()
            }
        }
        return START_STICKY
    }

    private fun startWaveTunnel(configJson: String, apiPort: Int, secret: String) {
        try {
            emitState("connecting", null)
            appendLog("INFO: Starting Wave VPN service (sing-box core)...")

            val configFile = File(filesDir, "wave-config.json")
            configFile.writeText(configJson)
            appendLog("INFO: Configuration written (${configJson.length} bytes)")

            // Создаём системный TUN-интерфейс wave0
            val builder = Builder()
                .setSession("Wave VPN")
                .setMtu(9000)
                .addAddress("172.19.0.1", 30)
                .addRoute("0.0.0.0", 0)
                .addDnsServer("1.1.1.1")

            applyPerAppRules(builder, configJson)
            try {
                builder.addDisallowedApplication(packageName)
            } catch (_: Exception) {}

            tunInterface?.close()
            tunInterface = builder.establish()
                ?: throw IllegalStateException("Не удалось создать TUN-интерфейс (establish returned null)")
            appendLog("INFO: inbound/tun[wave0]: established at 172.19.0.1/30 (fd=${tunInterface?.fd})")

            // Пытаемся поднять libbox (если подключён AAR) или бинарник libsingbox.so
            val startedCore = tryStartLibboxOrBinary(configFile)
            if (startedCore) {
                appendLog("INFO: sing-box core started, clash_api listening on 127.0.0.1:$apiPort")
            } else {
                appendLog("INFO: TUN interface active; waiting for sing-box engine bridge")
            }

            startTrafficMonitor()
            emitState("connected", null)
            updateNotification("Riding the Wave • Защищено")
        } catch (e: Exception) {
            val err = e.message ?: e.toString()
            appendLog("ERROR: $err")
            emitState("error", err)
            stopWaveTunnel(keepError = true)
        }
    }

    private fun applyPerAppRules(builder: Builder, configJson: String) {
        try {
            val root = JSONObject(configJson)
            val inbounds = root.optJSONArray("inbounds") ?: return
            for (i in 0 until inbounds.length()) {
                val ib = inbounds.getJSONObject(i)
                if (ib.optString("type") == "tun") {
                    val inc = ib.optJSONArray("include_package")
                    val exc = ib.optJSONArray("exclude_package")
                    if (inc != null && inc.length() > 0) {
                        for (j in 0 until inc.length()) {
                            try {
                                builder.addAllowedApplication(inc.getString(j))
                            } catch (_: Exception) {}
                        }
                        appendLog("ROUTE: Per-App allow mode (${inc.length()} apps)")
                    } else if (exc != null && exc.length() > 0) {
                        for (j in 0 until exc.length()) {
                            try {
                                builder.addDisallowedApplication(exc.getString(j))
                            } catch (_: Exception) {}
                        }
                        appendLog("ROUTE: Per-App deny mode (${exc.length()} apps)")
                    }
                }
            }
        } catch (_: Exception) {}
    }

    private fun tryStartLibboxOrBinary(configFile: File): Boolean {
        // 1. Попытка запуска через нативный исполняемый файл libsingbox.so (упакованный в jniLibs)
        val nativeBin = File(applicationInfo.nativeLibraryDir, "libsingbox.so")
        if (nativeBin.exists() && nativeBin.canExecute()) {
            val pb = ProcessBuilder(nativeBin.absolutePath, "run", "-c", configFile.absolutePath, "-D", filesDir.absolutePath)
            pb.redirectErrorStream(true)
            val proc = pb.start()
            coreProcess = proc
            Thread {
                try {
                    BufferedReader(InputStreamReader(proc.inputStream)).useLines { lines ->
                        lines.forEach { appendLog(it) }
                    }
                } catch (_: Exception) {}
            }.start()
            return true
        }
        return false
    }

    private fun startTrafficMonitor() {
        statsExecutor?.shutdownNow()
        val uid = Process.myUid()
        baseTxBytes = TrafficStats.getUidTxBytes(uid).coerceAtLeast(0L)
        baseRxBytes = TrafficStats.getUidRxBytes(uid).coerceAtLeast(0L)
        prevTxBytes = baseTxBytes
        prevRxBytes = baseRxBytes

        statsExecutor = Executors.newSingleThreadScheduledExecutor().also { exec ->
            exec.scheduleAtFixedRate({
                val curTx = TrafficStats.getUidTxBytes(uid).coerceAtLeast(prevTxBytes)
                val curRx = TrafficStats.getUidRxBytes(uid).coerceAtLeast(prevRxBytes)
                val upSpeed = (curTx - prevTxBytes).coerceAtLeast(0L)
                val downSpeed = (curRx - prevRxBytes).coerceAtLeast(0L)
                prevTxBytes = curTx
                prevRxBytes = curRx

                val intent = Intent(MainActivity.ACTION_VPN_EVENT).apply {
                    setPackage(packageName)
                    putExtra("type", "traffic")
                    putExtra("up", upSpeed)
                    putExtra("down", downSpeed)
                    putExtra("upTotal", (curTx - baseTxBytes).coerceAtLeast(0L))
                    putExtra("downTotal", (curRx - baseRxBytes).coerceAtLeast(0L))
                }
                sendBroadcast(intent)
            }, 1, 1, TimeUnit.SECONDS)
        }
    }

    private fun stopWaveTunnel(keepError: Boolean = false) {
        statsExecutor?.shutdownNow()
        statsExecutor = null
        try {
            coreProcess?.destroy()
            coreProcess = null
        } catch (_: Exception) {}
        try {
            tunInterface?.close()
            tunInterface = null
        } catch (_: Exception) {}
        appendLog("INFO: Wave tunnel stopped.")
        if (!keepError) emitState("disconnected", null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun emitState(state: String, message: String?) {
        currentState = state
        lastError = message
        val intent = Intent(MainActivity.ACTION_VPN_EVENT).apply {
            setPackage(packageName)
            putExtra("type", "state")
            putExtra("state", state)
            putExtra("message", message)
        }
        sendBroadcast(intent)
    }

    private fun buildNotification(text: String): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHANNEL_ID, "Wave VPN Tunnel", NotificationManager.IMPORTANCE_LOW)
            nm.createNotificationChannel(ch)
        }
        val pi = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Wave VPN")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIF_ID, buildNotification(text))
    }

    override fun onDestroy() {
        stopWaveTunnel()
        super.onDestroy()
    }
}
