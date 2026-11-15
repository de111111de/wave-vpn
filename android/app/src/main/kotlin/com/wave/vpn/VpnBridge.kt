package com.wave.vpn

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/** Process-wide hub between WaveVpnService and the Flutter EventChannel "com.wave.vpn/stats". */
object VpnBridge : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var sink: EventChannel.EventSink? = null
    @Volatile var state: String = "disconnected"
        private set
    private val logs = mutableListOf<String>()

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        emitState(state, null)
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(map: Map<String, Any?>) {
        main.post { sink?.success(map) }
    }

    fun emitState(s: String, message: String?) {
        state = s
        emit(mapOf("type" to "state", "state" to s, "message" to message))
    }

    fun emitTraffic(up: Long, down: Long, upTotal: Long, downTotal: Long) {
        emit(mapOf("type" to "traffic", "up" to up, "down" to down, "upTotal" to upTotal, "downTotal" to downTotal))
    }

    @Synchronized
    fun log(line: String?) {
        if (line == null) return
        if (logs.size >= 400) logs.removeAt(0)
        logs.add(line)
    }

    @Synchronized
    fun dumpLogs(): String = logs.joinToString("\n")
}
