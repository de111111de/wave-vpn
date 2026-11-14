package com.wave.vpn

import android.app.Service
import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.channels.FileChannel

class WaveVpnService : VpnService() {
    private var vpnInterface: ParcelFileDescriptor? = null

    override function onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent != null) {
            when (intent.action) {
                "START" -> {
                    val config = intent.getStringExtra("config")
                    startVpn(config)
                }
                "STOP" -> {
                    stopVpn()
                }
            }
        }
        return START_STICKY
    }

    private fun startVnp(config: String?) {
        try {
            val builder = Builder()
            builder.addAddress("10.0.0.2", 24)
            builder.addRoute("0.0.0.0", 0)
            builder.addDnsServer("8.8.8.8")
            builder.setSession("Wave VPN")
            vpnInterface = builder.establish()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun stopVpn() {
        try {
            vpnInterface?.close()
            vpnInterface = null
        } catch (e: Exception) {
            e.printStackTrace()
        }
        stopSelf()
    }

    override fun onDestroy() {
        super.onDestroy()
        stopVpn()
    }
}
